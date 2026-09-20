#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-build-setup-test.XXXXXX")
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

WORK_ROOT="${TEST_ROOT}/work"
FAKE_GO="${TEST_ROOT}/fake-go"
GO_LOG="${TEST_ROOT}/go-called"
mkdir -p "${WORK_ROOT}/src/openstick-setup"

cat > "${FAKE_GO}" <<'EOF'
#!/bin/sh
printf 'called\n' >> "${GO_LOG}"
exit 77
EOF
chmod 0755 "${FAKE_GO}"

expect_rootfs_rejected() {
    local name=$1
    local chroot=$2
    local status

    rm -f "${GO_LOG}"
    if (
        cd "${WORK_ROOT}"
        CHROOT="${chroot}" GO_BIN="${FAKE_GO}" GO_LOG="${GO_LOG}" \
            "${REPO_ROOT}/scripts/build_setup.sh"
    ) > "${TEST_ROOT}/${name}.output" 2>&1; then
        echo "build_setup accepted unsafe rootfs: ${chroot}" >&2
        exit 1
    else
        status=$?
    fi
    if [ "${status}" -ne 2 ]; then
        cat "${TEST_ROOT}/${name}.output" >&2
        echo "build_setup returned ${status} for ${chroot}; expected 2" >&2
        exit 1
    fi
    if [ -e "${GO_LOG}" ]; then
        echo "build_setup called the compiler for rejected rootfs: ${chroot}" >&2
        exit 1
    fi
}

ln -s / "${TEST_ROOT}/root-link"
expect_rootfs_rejected root /
expect_rootfs_rejected normalized-root /./
expect_rootfs_rejected root-symlink "${TEST_ROOT}/root-link"
expect_rootfs_rejected missing-rootfs "${TEST_ROOT}/missing-rootfs"

VALID_ROOTFS="${TEST_ROOT}/valid-rootfs"
mkdir -p "${VALID_ROOTFS}/etc"
rm -f "${GO_LOG}"
if (
    cd "${WORK_ROOT}"
    CHROOT="${VALID_ROOTFS}" GO_BIN="${FAKE_GO}" GO_LOG="${GO_LOG}" \
        "${REPO_ROOT}/scripts/build_setup.sh"
) > "${TEST_ROOT}/valid-rootfs.output" 2>&1; then
    echo 'build_setup unexpectedly completed with the fake compiler' >&2
    exit 1
else
    valid_status=$?
fi
if [ "${valid_status}" -ne 77 ]; then
    cat "${TEST_ROOT}/valid-rootfs.output" >&2
    echo "build_setup returned ${valid_status} for a valid rootfs; expected 77" >&2
    exit 1
fi
if [ "$(wc -l < "${GO_LOG}")" -ne 1 ]; then
    echo 'build_setup did not call the fake compiler exactly once' >&2
    exit 1
fi

printf 'build setup safety tests passed\n'
