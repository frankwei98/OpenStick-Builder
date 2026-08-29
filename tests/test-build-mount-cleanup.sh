#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-mount-test.XXXXXX")
TEST_ROOT=$(cd -P "${TEST_ROOT}" && pwd -P)
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

STUB_BIN="${TEST_ROOT}/bin"
COMMAND_LOG="${TEST_ROOT}/commands.log"
TEST_CHROOT="${TEST_ROOT}/rootfs"
mkdir -p "${STUB_BIN}"

cat > "${STUB_BIN}/findmnt" <<'EOF'
#!/bin/sh
if [ -n "${FINDMNT_OUTPUT:-}" ]; then
    printf '%s\n' "${FINDMNT_OUTPUT}"
fi
exit 0
EOF

cat > "${STUB_BIN}/rm" <<'EOF'
#!/bin/sh
printf 'rm:%s\n' "$*" >> "${COMMAND_LOG}"
case " $* " in
    *" --one-file-system "*)
        for argument do
            target=${argument}
        done
        exec /bin/rm -rf -- "${target}"
        ;;
esac
exec /bin/rm "$@"
EOF

cat > "${STUB_BIN}/debootstrap" <<'EOF'
#!/bin/sh
for argument do
    target=${argument}
done
mkdir -p \
    "${target}/proc" \
    "${target}/sys" \
    "${target}/dev/pts" \
    "${target}/run" \
    "${target}/etc/apt"
EOF

cat > "${STUB_BIN}/mount" <<'EOF'
#!/bin/sh
printf 'mount:%s\n' "$*" >> "${COMMAND_LOG}"
for argument do
    target=${argument}
done
if [ -n "${MOUNT_FAIL_TARGET:-}" ] && [ "${target}" = "${MOUNT_FAIL_TARGET}" ]; then
    exit 55
fi
EOF

cat > "${STUB_BIN}/umount" <<'EOF'
#!/bin/sh
printf 'umount:%s\n' "$*" >> "${COMMAND_LOG}"
EOF

cat > "${STUB_BIN}/chroot" <<'EOF'
#!/bin/sh
printf 'chroot:%s\n' "$*" >> "${COMMAND_LOG}"
if [ "${CHROOT_SIGNAL:-}" = TERM ]; then
    kill -TERM "${PPID}"
    exit 0
fi
exit 42
EOF

cat > "${STUB_BIN}/truncate" <<'EOF'
#!/bin/sh
for argument do
    target=${argument}
done
: > "${target}"
EOF

for command_name in mkfs.ext2 mkfs.ext4 img2simg; do
    cat > "${STUB_BIN}/${command_name}" <<'EOF'
#!/bin/sh
exit 0
EOF
done

cat > "${STUB_BIN}/tar" <<'EOF'
#!/bin/sh
exit 23
EOF

chmod 0755 "${STUB_BIN}"/*

# A stale descendant mount must stop the script before the recursive removal.
: > "${COMMAND_LOG}"
if FINDMNT_OUTPUT="${TEST_CHROOT}/dev" \
    COMMAND_LOG="${COMMAND_LOG}" \
    PATH="${STUB_BIN}:${PATH}" \
    CHROOT="${TEST_CHROOT}" \
    BUILD_HOST_ARCHITECTURE=arm64 \
        "${REPO_ROOT}/scripts/debootstrap.sh" \
        >"${TEST_ROOT}/debootstrap-output" 2>&1; then
    echo "debootstrap unexpectedly accepted a rootfs with a stale mount" >&2
    exit 1
else
    stale_mount_status=$?
fi
test "${stale_mount_status}" -eq 2
if grep -q '^rm:' "${COMMAND_LOG}"; then
    echo "debootstrap removed a rootfs that still had a descendant mount" >&2
    exit 1
fi

# Failure during the mount sequence must only unwind mounts that succeeded.
: > "${COMMAND_LOG}"
if FINDMNT_OUTPUT='' \
    MOUNT_FAIL_TARGET="${TEST_CHROOT}/dev/pts/" \
    COMMAND_LOG="${COMMAND_LOG}" \
    PATH="${STUB_BIN}:${PATH}" \
    CHROOT="${TEST_CHROOT}" \
    BUILD_HOST_ARCHITECTURE=arm64 \
        "${REPO_ROOT}/scripts/debootstrap.sh" \
        >"${TEST_ROOT}/debootstrap-output" 2>&1; then
    echo "injected partial mount failure unexpectedly succeeded" >&2
    exit 1
else
    partial_mount_status=$?
fi
test "${partial_mount_status}" -eq 55
cat > "${TEST_ROOT}/expected-partial-umounts" <<EOF
umount:${TEST_CHROOT}/dev
umount:${TEST_CHROOT}/sys
umount:${TEST_CHROOT}/proc
EOF
grep '^umount:' "${COMMAND_LOG}" > "${TEST_ROOT}/actual-umounts" || true
diff -u "${TEST_ROOT}/expected-partial-umounts" \
    "${TEST_ROOT}/actual-umounts"

# A failure after all mounts must unmount only successful mounts in reverse order.
: > "${COMMAND_LOG}"
if FINDMNT_OUTPUT='' \
    COMMAND_LOG="${COMMAND_LOG}" \
    PATH="${STUB_BIN}:${PATH}" \
    CHROOT="${TEST_CHROOT}" \
    BUILD_HOST_ARCHITECTURE=arm64 \
        "${REPO_ROOT}/scripts/debootstrap.sh" \
        >"${TEST_ROOT}/debootstrap-output" 2>&1; then
    echo "injected chroot failure unexpectedly succeeded" >&2
    exit 1
else
    chroot_failure_status=$?
fi
test "${chroot_failure_status}" -eq 42

cat > "${TEST_ROOT}/expected-umounts" <<EOF
umount:${TEST_CHROOT}/run
umount:${TEST_CHROOT}/dev/pts
umount:${TEST_CHROOT}/dev
umount:${TEST_CHROOT}/sys
umount:${TEST_CHROOT}/proc
EOF
grep '^umount:' "${COMMAND_LOG}" > "${TEST_ROOT}/actual-umounts" || true
if ! diff -u "${TEST_ROOT}/expected-umounts" "${TEST_ROOT}/actual-umounts"; then
    cat "${TEST_ROOT}/debootstrap-output" >&2
    echo "debootstrap did not clean mounts in reverse order" >&2
    exit 1
fi

# Signal exits preserve the conventional status and use the same LIFO cleanup.
: > "${COMMAND_LOG}"
if FINDMNT_OUTPUT='' \
    CHROOT_SIGNAL=TERM \
    COMMAND_LOG="${COMMAND_LOG}" \
    PATH="${STUB_BIN}:${PATH}" \
    CHROOT="${TEST_CHROOT}" \
    BUILD_HOST_ARCHITECTURE=arm64 \
        "${REPO_ROOT}/scripts/debootstrap.sh" \
        >"${TEST_ROOT}/debootstrap-output" 2>&1; then
    echo "injected TERM unexpectedly succeeded" >&2
    exit 1
else
    signal_status=$?
fi
test "${signal_status}" -eq 143
grep '^umount:' "${COMMAND_LOG}" > "${TEST_ROOT}/actual-umounts" || true
diff -u "${TEST_ROOT}/expected-umounts" "${TEST_ROOT}/actual-umounts"

# Image mounts need the same cleanup guarantee when tar or a later step fails.
IMAGE_ROOT="${TEST_ROOT}/image-build"
mkdir -p "${IMAGE_ROOT}/dist"
: > "${IMAGE_ROOT}/rootfs.tgz"
: > "${COMMAND_LOG}"
if (
    cd "${IMAGE_ROOT}"
    FINDMNT_OUTPUT="${IMAGE_ROOT}/mnt/nested" \
    COMMAND_LOG="${COMMAND_LOG}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/build_images.sh" >/dev/null 2>&1
); then
    echo "build_images accepted a descendant mount" >&2
    exit 1
else
    image_mount_status=$?
fi
test "${image_mount_status}" -eq 2
if grep -q '^mount:' "${COMMAND_LOG}"; then
    echo "build_images mounted over a directory containing a child mount" >&2
    exit 1
fi

: > "${COMMAND_LOG}"
if (
    cd "${IMAGE_ROOT}"
    FINDMNT_OUTPUT='' \
    COMMAND_LOG="${COMMAND_LOG}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/build_images.sh" >/dev/null 2>&1
); then
    echo "injected image tar failure unexpectedly succeeded" >&2
    exit 1
else
    image_failure_status=$?
fi
test "${image_failure_status}" -eq 23
if ! grep -Fqx "umount:${IMAGE_ROOT}/mnt" "${COMMAND_LOG}"; then
    echo "build_images did not unmount its image after failure" >&2
    exit 1
fi

printf 'build mount cleanup tests passed\n'
