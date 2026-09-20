# First-boot administrator setup

Fresh images expose a single setup page at `http://172.30.255.1:8080` on the
point-to-point USB link. The first successful submission sets the password for
`openstick`. The HTTP and account-writing services then exit. EDL and fastboot
still write the same images; they do not inject user credentials.

## Trust and scope

This is unauthenticated first possession over a trusted USB connection. Anyone
who can reach the allowed USB endpoint before setup can claim the device. HTTP
does not encrypt the password. Browser origin checks prevent unrelated websites
from submitting the form; they do not authenticate the physical owner.

The image has a locked `openstick` password, locked root password, no root SSH,
and no serial auto-login. `/etc/nologin` gates PAM login and sshd until completion.
`openstick` has password-required sudo. SSH password authentication is enabled
only for `openstick` using the configured USB source/destination pair. The
firewall also rejects non-USB traffic to that SSH destination, preventing a
forged source on another interface from selecting the password policy. Other
SSH interfaces retain public-key authentication.

This is not an in-place migration for old installations. Do not deploy the
initialization services onto an already owned system without a separate migration.
Reset requires reflashing the rootfs, including its state; normal reboot and
service restart never reset ownership. Reflashing destroys the previous system.

## Components

- Native HTML/CSS/JavaScript, embedded using Go `embed`; no external assets.
- Go `net/http`, with no third-party modules. The Linux ARM64 binary is built
  with CGO disabled and installed at `/usr/libexec/openstick-setup`.
- `openstick-setup-web.service` runs `serve` as the locked system user
  `openstick-setup`, without capabilities or write access to the system.
- `openstick-setup-apply.service` runs `apply` as root. It accepts only ready and
  fixed-account password operations on `/run/openstick-setup/apply.sock`.
  Socket permissions and Linux `SO_PEERCRED` restrict clients to the web user.
- `/usr/sbin/chpasswd` consumes the password via stdin, using Debian's PAM
  password stack. No password goes in shell strings, arguments or environment.
  Subprocess output is discarded, and core dumps are disabled.
- systemd starts both services at boot. The helper also runs after completion
  to reconcile a power loss between committing ownership and opening login,
  then immediately exits. The web unit skips a configured device. Both helper
  and web handlers reject later password changes even before shutdown.

The compiler is pinned and checksum verified by `scripts/install-go.sh` under
`build/go`. `scripts/install_deps.sh` installs it; `scripts/build_setup.sh` embeds
and installs the binary before `rootfs.tgz` is created. CI uses the same compiler
version. Update both compiler checksums and workflow versions for security updates.

## Network and HTTP

`configs/usb-management.conf` generates `setup.json`, `setup-network.conf`, SSH,
DHCP and NetworkManager configuration together. The web service binds only the
configured IPv4 address, port 8080, never a wildcard. Firewall installation must
succeed before HTTP or sshd starts. INPUT drops other traffic to port 8080 and
only accepts the USB interface/source/destination tuple. Rules remain after setup.

Routes:

| Route | Behavior |
| --- | --- |
| `GET /`, `/style.css`, `/app.js` | Embedded setup UI |
| `GET /api/session` | Ready check, 15-minute session and CSRF token |
| `POST /api/setup` | JSON `password` and `confirmation`, max 4 KiB |

All requests require the configured Host and USB peer. POST additionally requires
an exact same-origin Origin, JSON content type, matching session cookie and
`X-CSRF-Token`. Cookies are HttpOnly and SameSite=Strict; they intentionally cannot
be Secure over this HTTP-only link. No CORS is enabled. Responses use no-store,
frame denial, restrictive CSP and no-referrer. Sessions are memory-only, bounded
to 32 and expire after 15 minutes. POST is limited to once per second across
sessions. Connections, header/body sizes and read/write durations are bounded.

Passwords are 12–128 Unicode characters, allow spaces without trimming, and
reject control characters. Client checks are repeated by both HTTP and root
helper code. Backend failure does not return command output or echoed input.
HTTP 409 means another submission already configured the device; the UI must not
claim that the current submission changed its password. Lost responses do not
cause automatic resubmission: the page directs the user to test SSH or reboot.

## Persistent state and power-loss recovery

`/var/lib/openstick-setup` is root-owned mode 0700. A lifetime flock excludes
multiple helpers. A mutex serializes submissions. Marker files are mode 0600
and contain only the format version, never passwords or password hashes.

1. No marker and the exact factory shadow lock `!`: unconfigured.
2. Write and fsync a temporary marker; rename to `applying`; fsync the directory.
3. Call chpasswd. Verify that the shadow entry is a supported nonempty crypt hash.
4. Fsync shadow and its parent directory.
5. Rename `applying` to `configured`; fsync the state directory.
6. Remove the factory `/etc/nologin` message and fsync `/etc`.
7. Return success; gracefully stop HTTP and helper processes.

On boot, before opening the socket:

| State | Recovery |
| --- | --- |
| No marker, exact factory lock | Accept initialization |
| Applying, exact factory lock | Remove applying marker durably; allow retry |
| Applying, password hash present | Preserve password; complete commit and open login |
| Configured | Reconcile the factory login gate; exit |
| Missing marker with existing password | Refuse initialization |
| Invalid marker, conflicting markers, unexpected shadow state | Fail closed |

After any uncertain mutation, the running helper rejects further submissions;
recovery requires restart. A configured marker is never reverted. A later
administrator-created maintenance nologin file is preserved. The code remains
installed for auditable recovery; there is no self-deleting script.

Durability relies on the filesystem and storage honoring fsync and atomic rename.
Tests inject failures around transitions, but do not certify physical eMMC power
loss behavior. Hardware USB enumeration and actual power-cut trials require a device.

## Validation

`tests/test-first-boot-setup.sh` runs race-enabled Go tests with fake account
storage and cross-compiles Linux ARM64. The repository's shell suite checks
rendered image configuration. `tests/test-build-setup.sh` verifies that root,
root-equivalent and missing rootfs paths are rejected before compilation while a
prepared temporary rootfs reaches the compiler. Privileged integration must run
inside a disposable Linux VM/container, never against the developer's real
accounts. Validate PAM, Unix peer credentials, sudo, service hardening and
packaged image contents there.

```sh
tests/test-first-boot-setup.sh
tests/test-build-setup.sh
tests/test-image-configuration.sh
```

With Playwright and Chromium available, `node tests/setup-ui.test.cjs` exercises
the real static UI against controlled API responses, including failed connections,
validation, success, a competing submission, and 320px layouts. It does not
replace the real helper test.

Only in a fresh disposable Debian 13 VM with Go, systemd, curl, iptables and
iproute2 installed, run:

```sh
sudo env OPENSTICK_DISPOSABLE_VM=1 PATH="$PATH" tests/integration-first-boot-setup.sh
```

That test provisions real accounts, creates a veth pair and a network namespace
to represent USB, and uses the production service units. It deliberately leaves
the VM configured; delete the entire VM afterward. Never run it on a normal host.

The privileged test checks the effective systemd hardening properties before
testing password setup. Orb, LXC and similar container environments may install
global service drop-ins that override `NoNewPrivileges`, `ProtectSystem` or
`PrivateDevices`. Such a mismatch is a failed validation: do not report the run
as passed and do not weaken the production units to accommodate the container.
Remove the disposable environment's override for the validation run, or use a VM
that preserves the unit's effective protections.
