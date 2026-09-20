#!/bin/bash
set -Eeuo pipefail

CURRENT_STAGE='startup'

report_error() {
    local status=$1
    local line=$2

    trap - ERR
    printf 'integration failed: stage=%s line=%s status=%s\n' \
        "${CURRENT_STAGE}" "${line}" "${status}" >&2
    exit "${status}"
}

stage() {
    CURRENT_STAGE=$1
    printf '==> %s\n' "${CURRENT_STAGE}"
}

trap 'report_error "$?" "$LINENO"' ERR

# This test intentionally provisions the host and is only safe in a disposable
# Debian 13 VM. The VM, rather than this script, is responsible for cleanup.
stage 'preflight safety checks'
if [ "$(id -u)" -ne 0 ]; then
    echo 'integration test must run as root' >&2
    exit 2
fi
if [ "${OPENSTICK_DISPOSABLE_VM:-}" != 1 ]; then
    echo 'refusing to modify this host without OPENSTICK_DISPOSABLE_VM=1' >&2
    exit 2
fi
. /etc/os-release
if [ "${ID:-}" != debian ] || [ "${VERSION_ID:-}" != 13 ]; then
    echo 'integration test requires a disposable Debian 13 VM' >&2
    exit 2
fi

for command_name in \
    go systemctl useradd runuser curl timeout sudo iptables ip \
    getent awk sed grep cut seq stat ps tr visudo install; do
    command -v "${command_name}" >/dev/null || {
        echo "required command is unavailable: ${command_name}" >&2
        exit 2
    }
done
if [ "$(ps -p 1 -o comm=)" != systemd ]; then
    echo 'integration test requires a systemd-based disposable VM' >&2
    exit 2
fi
if getent passwd openstick >/dev/null || getent passwd openstick-setup >/dev/null; then
    echo 'refusing a VM that already has OpenStick accounts' >&2
    exit 2
fi
for path in \
    /var/lib/openstick-setup \
    /run/openstick-setup \
    /etc/openstick \
    /etc/nologin \
    /etc/sudoers.d/openstick \
    /usr/libexec/openstick-setup \
    /etc/systemd/system/openstick-setup-apply.service \
    /etc/systemd/system/openstick-setup-firewall.service \
    /etc/systemd/system/openstick-setup-web.service; do
    if [ -e "${path}" ]; then
        echo "refusing a VM with existing OpenStick state: ${path}" >&2
        exit 2
    fi
done
if ip link show usb0 >/dev/null 2>&1; then
    echo 'refusing a VM that already has a usb0 interface' >&2
    exit 2
fi
if ip netns list | awk '$1 == "openstick-test-host" { found = 1 } END { exit !found }'; then
    echo 'refusing a VM with an existing openstick-test-host namespace' >&2
    exit 2
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/openstick-system-integration.XXXXXX)
PASSWORD='OpenStick disposable VM 2026!'
SECOND_PASSWORD='This password must never replace it!'

stage 'build and install disposable fixture'
export GOCACHE="${TEST_ROOT}/go-cache"
export GOTMPDIR="${TEST_ROOT}/go-tmp"
mkdir -p "${GOCACHE}" "${GOTMPDIR}" "${TEST_ROOT}/rendered/etc"
(
    cd "${REPO_ROOT}/src/openstick-setup"
    CGO_ENABLED=0 GOTOOLCHAIN=local go build -trimpath -buildvcs=false \
        -o "${TEST_ROOT}/openstick-setup" .
)
"${REPO_ROOT}/scripts/render-usb-management.sh" \
    "${TEST_ROOT}/rendered" "${REPO_ROOT}/configs/usb-management.conf"

useradd --create-home --shell /bin/bash --password '!' openstick
useradd --system --user-group --no-create-home --shell /usr/sbin/nologin openstick-setup
printf 'openstick ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/openstick
chmod 0440 /etc/sudoers.d/openstick
visudo -cf /etc/sudoers.d/openstick >/dev/null
printf 'Complete OpenStick setup over USB before logging in.\n' > /etc/nologin
chmod 0644 /etc/nologin
for pam_service in login sshd; do
    if [ -f "/etc/pam.d/${pam_service}" ] && \
        ! grep -Fqx 'account requisite pam_nologin.so' "/etc/pam.d/${pam_service}"; then
        sed -i '1i account requisite pam_nologin.so' "/etc/pam.d/${pam_service}"
    fi
done

install -D -m 0755 "${TEST_ROOT}/openstick-setup" /usr/libexec/openstick-setup
install -D -m 0755 "${REPO_ROOT}/scripts/openstick-setup-firewall.sh" \
    /usr/sbin/openstick-setup-firewall
install -D -m 0644 "${TEST_ROOT}/rendered/etc/openstick/setup.json" \
    /etc/openstick/setup.json
install -D -m 0644 "${TEST_ROOT}/rendered/etc/openstick/setup-network.conf" \
    /etc/openstick/setup-network.conf
install -D -m 0644 "${TEST_ROOT}/rendered/etc/ssh/sshd_config.d/00-openstick-usb-root.conf" \
    /etc/ssh/sshd_config.d/00-openstick-usb-root.conf
for service in openstick-setup-firewall openstick-setup-apply openstick-setup-web; do
    install -D -m 0644 "${REPO_ROOT}/configs/system/${service}.service" \
        "/etc/systemd/system/${service}.service"
done
install -D -m 0644 "${REPO_ROOT}/configs/system/ssh.service.d/openstick.conf" \
    /etc/systemd/system/ssh.service.d/openstick.conf
install -D -m 0644 "${REPO_ROOT}/configs/system/ssh.socket.d/openstick.conf" \
    /etc/systemd/system/ssh.socket.d/openstick.conf

stage 'start isolated USB services'
ip netns add openstick-test-host
ip link add usb0 type veth peer name setup-host0
ip link set setup-host0 netns openstick-test-host
ip address add 172.30.255.1/30 dev usb0
ip link set usb0 up
ip -n openstick-test-host address add 172.30.255.2/30 dev setup-host0
ip -n openstick-test-host link set setup-host0 up
ip -n openstick-test-host link set lo up
systemctl daemon-reload
systemctl start openstick-setup-firewall.service
systemctl start openstick-setup-apply.service

stage 'verify helper hardening and peer access'
for _ in $(seq 1 50); do
    [ -S /run/openstick-setup/apply.sock ] && break
    sleep 0.1
done
test -S /run/openstick-setup/apply.sock
test "$(stat -c '%a' /run/openstick-setup/apply.sock)" = 660
test "$(stat -c '%G' /run/openstick-setup/apply.sock)" = openstick-setup

test "$(systemctl show openstick-setup-apply.service -p NoNewPrivileges --value)" = yes
test "$(systemctl show openstick-setup-apply.service -p ProtectSystem --value)" = strict
test "$(systemctl show openstick-setup-apply.service -p PrivateDevices --value)" = yes

# The socket admits only the unprivileged web-service account. A root client
# must be disconnected before HTTP is processed.
if timeout 2 curl --silent --show-error --fail \
    --unix-socket /run/openstick-setup/apply.sock http://helper/ready \
    >/dev/null 2>&1; then
    echo 'helper accepted a client with the wrong Unix peer credential' >&2
    report_error 1 "${LINENO}"
fi

ready_response=$(runuser -u openstick-setup -- \
    curl --silent --show-error --fail \
        --unix-socket /run/openstick-setup/apply.sock http://helper/ready)
grep -Fq '"status":"ready"' <<< "${ready_response}"

stage 'verify web boundary and provision account'
systemctl start openstick-setup-web.service
test "$(systemctl show openstick-setup-web.service -p User --value)" = openstick-setup
test "$(systemctl show openstick-setup-web.service -p Group --value)" = openstick-setup
test "$(systemctl show openstick-setup-web.service -p NoNewPrivileges --value)" = yes
test "$(systemctl show openstick-setup-web.service -p CapabilityBoundingSet --value)" = ''
web_pid=$(systemctl show openstick-setup-web.service -p MainPID --value)
test "${web_pid}" -gt 1
test "$(ps -o user= -p "${web_pid}" | tr -d ' ')" = openstick-setup

for _ in $(seq 1 50); do
    if ip netns exec openstick-test-host curl --silent --show-error --fail \
        --noproxy '*' \
        --connect-timeout 1 --max-time 2 \
        http://172.30.255.1:8080/ > "${TEST_ROOT}/setup-page"; then
        break
    fi
    sleep 0.1
done
grep -Fq '<title>OpenStick · 首次设置</title>' "${TEST_ROOT}/setup-page"
session_response=$(ip netns exec openstick-test-host \
    curl --silent --show-error --fail \
        --noproxy '*' \
        --connect-timeout 2 --max-time 5 \
        --cookie-jar "${TEST_ROOT}/cookies" \
        http://172.30.255.1:8080/api/session)
token=$(sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p' <<< "${session_response}")
test "${#token}" -eq 64
apply_body=$(printf '{"password":"%s","confirmation":"%s"}' \
    "${PASSWORD}" "${PASSWORD}")
forged_origin_response=$(ip netns exec openstick-test-host \
    curl --silent --show-error \
        --noproxy '*' \
        --connect-timeout 2 --max-time 5 \
        --cookie "${TEST_ROOT}/cookies" \
        -H 'Origin: http://example.invalid' \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: ${token}" \
        --data-binary "${apply_body}" \
        --write-out $'\n%{http_code}' \
        http://172.30.255.1:8080/api/setup)
test "${forged_origin_response##*$'\n'}" = 403
test ! -e /var/lib/openstick-setup/configured
apply_response=$(ip netns exec openstick-test-host \
    curl --silent --show-error --fail \
        --noproxy '*' \
        --connect-timeout 2 --max-time 5 \
        --cookie "${TEST_ROOT}/cookies" \
        -H 'Origin: http://172.30.255.1:8080' \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: ${token}" \
        --data-binary "${apply_body}" \
        http://172.30.255.1:8080/api/setup)
grep -Fq '"status":"configured"' <<< "${apply_response}"

stage 'verify committed account rejects replacement'
test -f /var/lib/openstick-setup/configured
test ! -e /var/lib/openstick-setup/applying
test ! -e /etc/nologin
shadow_value=$(getent shadow openstick | cut -d: -f2)
test -n "${shadow_value}"
test "${shadow_value}" != '!'
test "${shadow_value}" != '*'
second_apply_body=$(printf '{"password":"%s","confirmation":"%s"}' \
    "${SECOND_PASSWORD}" "${SECOND_PASSWORD}")
repeat_response=$(runuser -u openstick-setup -- \
    curl --silent --show-error \
        --unix-socket /run/openstick-setup/apply.sock \
        -H 'Content-Type: application/json' \
        --data-binary "${second_apply_body}" \
        --write-out $'\n%{http_code}' http://helper/apply)
test "${repeat_response##*$'\n'}" = 409
grep -Fq '"status":"configured"' <<< "${repeat_response%$'\n'*}"
test "$(getent shadow openstick | cut -d: -f2)" = "${shadow_value}"

runuser -u openstick -- sudo -K
test "$(printf '%s\n' "${PASSWORD}" | runuser -u openstick -- \
    sudo -S -p '' id -u)" = 0

# A completed helper exits and a later invocation reconciles the gate without
# reopening registration or accepting another password.
stage 'verify completed setup remains closed'
for _ in $(seq 1 100); do
    systemctl is-active --quiet openstick-setup-apply.service || break
    sleep 0.1
done
systemctl start openstick-setup-apply.service
for _ in $(seq 1 50); do
    systemctl is-active --quiet openstick-setup-apply.service || break
    sleep 0.1
done
test ! -S /run/openstick-setup/apply.sock
runuser -u openstick -- sudo -K
if printf '%s\n' "${SECOND_PASSWORD}" | runuser -u openstick -- \
    sudo -S -p '' true >/dev/null 2>&1; then
    echo 'completed setup accepted a replacement password' >&2
    report_error 1 "${LINENO}"
fi
runuser -u openstick -- sudo -K
test "$(printf '%s\n' "${PASSWORD}" | runuser -u openstick -- \
    sudo -S -p '' id -u)" = 0

stage 'integration complete'
printf 'OpenStick disposable-VM first-boot integration passed\n'
printf 'Delete this VM now; the test intentionally leaves its accounts and system configuration in place.\n'
