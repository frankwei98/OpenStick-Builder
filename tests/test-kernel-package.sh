#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-kernel-test.XXXXXX")
TEST_ROOT=$(cd -P "${TEST_ROOT}" && pwd -P)
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

PACKAGE_ROOT="${TEST_ROOT}/package"
PACKAGE_FILE="${TEST_ROOT}/kernel.apk"
ROOTFS="${TEST_ROOT}/rootfs"
WGET_LOG="${TEST_ROOT}/wget.log"
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p \
    "${PACKAGE_ROOT}/boot/dtbs/qcom" \
    "${PACKAGE_ROOT}/lib/modules/6.12.1-msm8916" \
    "${ROOTFS}/usr/lib" \
    "${STUB_BIN}"
ln -s usr/lib "${ROOTFS}/lib"

printf 'kernel\n' > "${PACKAGE_ROOT}/boot/vmlinuz"
printf 'ufi003 dtb\n' \
    > "${PACKAGE_ROOT}/boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb"
printf 'uz801 dtb\n' \
    > "${PACKAGE_ROOT}/boot/dtbs/qcom/msm8916-yiming-uz801v3.dtb"
printf 'module\n' > "${PACKAGE_ROOT}/lib/modules/6.12.1-msm8916/modules.dep"
printf 'metadata\n' > "${PACKAGE_ROOT}/.PKGINFO"
printf 'signature\n' > "${PACKAGE_ROOT}/.SIGN.RSA.test"
tar -czf "${PACKAGE_FILE}" -C "${PACKAGE_ROOT}" .
PACKAGE_SHA256=$(sha256sum "${PACKAGE_FILE}")
PACKAGE_SHA256=${PACKAGE_SHA256%% *}

cat > "${STUB_BIN}/wget" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${WGET_LOG}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O)
            output=$2
            shift 2
            ;;
        *) shift ;;
    esac
done
cp "${FAKE_KERNEL_PACKAGE}" "${output}"
EOF
chmod 0755 "${STUB_BIN}/wget"

write_config() {
    config_path=$1
    package_url=$2
    package_sha256=$3
    package_filename=${package_url##*/}
    package_version=${package_filename%.apk}
    cat > "${config_path}" <<EOF
POSTMARKETOS_KERNEL_BRANCH="test"
POSTMARKETOS_KERNEL_VERSION="${package_version}"
POSTMARKETOS_KERNEL_URL="${package_url}"
POSTMARKETOS_KERNEL_SHA256="${package_sha256}"
POSTMARKETOS_KERNEL_REQUIRED_FILES="
boot/vmlinuz
boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb
boot/dtbs/qcom/msm8916-yiming-uz801v3.dtb
"
EOF
}

VALID_CONFIG="${TEST_ROOT}/valid.conf"
write_config "${VALID_CONFIG}" \
    'https://mirror.postmarketos.org/test/kernel.apk' \
    "${PACKAGE_SHA256}"

WGET_LOG="${WGET_LOG}" \
FAKE_KERNEL_PACKAGE="${PACKAGE_FILE}" \
PATH="${STUB_BIN}:${PATH}" \
    "${REPO_ROOT}/scripts/install-kernel.sh" \
        "${ROOTFS}" "${VALID_CONFIG}"

test -f "${ROOTFS}/boot/vmlinuz"
test -f "${ROOTFS}/boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb"
test -f "${ROOTFS}/boot/dtbs/qcom/msm8916-yiming-uz801v3.dtb"
test -f "${ROOTFS}/lib/modules/6.12.1-msm8916/modules.dep"
test -L "${ROOTFS}/lib"
test "$(readlink "${ROOTFS}/lib")" = usr/lib
test ! -e "${ROOTFS}/.PKGINFO"
test ! -e "${ROOTFS}/.SIGN.RSA.test"

# An invalid digest must fail before anything is copied into the rootfs.
BAD_HASH_ROOTFS="${TEST_ROOT}/bad-hash-rootfs"
BAD_HASH_CONFIG="${TEST_ROOT}/bad-hash.conf"
mkdir -p "${BAD_HASH_ROOTFS}"
write_config "${BAD_HASH_CONFIG}" \
    'https://mirror.postmarketos.org/test/kernel.apk' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if WGET_LOG="${WGET_LOG}" \
    FAKE_KERNEL_PACKAGE="${PACKAGE_FILE}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/install-kernel.sh" \
            "${BAD_HASH_ROOTFS}" "${BAD_HASH_CONFIG}" >/dev/null 2>&1; then
    echo "kernel installer accepted an invalid SHA256" >&2
    exit 1
fi
test -z "$(find "${BAD_HASH_ROOTFS}" -mindepth 1 -print -quit)"

# Plain HTTP must be rejected even when the package hash is otherwise valid.
HTTP_ROOTFS="${TEST_ROOT}/http-rootfs"
HTTP_CONFIG="${TEST_ROOT}/http.conf"
mkdir -p "${HTTP_ROOTFS}"
write_config "${HTTP_CONFIG}" \
    'http://mirror.postmarketos.org/test/kernel.apk' \
    "${PACKAGE_SHA256}"
: > "${WGET_LOG}"
if WGET_LOG="${WGET_LOG}" \
    FAKE_KERNEL_PACKAGE="${PACKAGE_FILE}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/install-kernel.sh" \
            "${HTTP_ROOTFS}" "${HTTP_CONFIG}" >/dev/null 2>&1; then
    echo "kernel installer accepted a plain HTTP source" >&2
    exit 1
fi
test ! -s "${WGET_LOG}"
test -z "$(find "${HTTP_ROOTFS}" -mindepth 1 -print -quit)"

# Human-readable branch and version pins must agree with the package URL.
DRIFT_ROOTFS="${TEST_ROOT}/drift-rootfs"
DRIFT_CONFIG="${TEST_ROOT}/drift.conf"
mkdir -p "${DRIFT_ROOTFS}"
cp "${VALID_CONFIG}" "${DRIFT_CONFIG}"
cat >> "${DRIFT_CONFIG}" <<'EOF'
POSTMARKETOS_KERNEL_BRANCH="wrong-branch"
POSTMARKETOS_KERNEL_VERSION="wrong-version"
EOF
: > "${WGET_LOG}"
if WGET_LOG="${WGET_LOG}" \
    FAKE_KERNEL_PACKAGE="${PACKAGE_FILE}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/install-kernel.sh" \
            "${DRIFT_ROOTFS}" "${DRIFT_CONFIG}" >/dev/null 2>&1; then
    echo "kernel installer accepted branch/version drift" >&2
    exit 1
fi
test ! -s "${WGET_LOG}"
test -z "$(find "${DRIFT_ROOTFS}" -mindepth 1 -print -quit)"

# A merged-/usr link may only resolve inside the target rootfs. Validate all
# top-level entries before copying so a bad link cannot cause a partial install.
ESCAPE_ROOTFS="${TEST_ROOT}/escape-rootfs"
ESCAPE_TARGET="${TEST_ROOT}/outside-rootfs"
mkdir -p "${ESCAPE_ROOTFS}" "${ESCAPE_TARGET}"
ln -s "${ESCAPE_TARGET}" "${ESCAPE_ROOTFS}/lib"
if WGET_LOG="${WGET_LOG}" \
    FAKE_KERNEL_PACKAGE="${PACKAGE_FILE}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/install-kernel.sh" \
            "${ESCAPE_ROOTFS}" "${VALID_CONFIG}" >/dev/null 2>&1; then
    echo "kernel installer followed a rootfs link to an external directory" >&2
    exit 1
fi
test -z "$(find "${ESCAPE_TARGET}" -mindepth 1 -print -quit)"
test ! -e "${ESCAPE_ROOTFS}/boot"

# Existing links below a valid top-level directory must not redirect a package
# file outside the rootfs during the recursive merge.
NESTED_ESCAPE_ROOTFS="${TEST_ROOT}/nested-escape-rootfs"
NESTED_ESCAPE_TARGET="${TEST_ROOT}/nested-outside-vmlinuz"
NESTED_ESCAPE_OUTPUT="${TEST_ROOT}/nested-escape-output"
mkdir -p "${NESTED_ESCAPE_ROOTFS}/boot"
printf 'outside kernel\n' > "${NESTED_ESCAPE_TARGET}"
ln -s "${NESTED_ESCAPE_TARGET}" "${NESTED_ESCAPE_ROOTFS}/boot/vmlinuz"
if WGET_LOG="${WGET_LOG}" \
    FAKE_KERNEL_PACKAGE="${PACKAGE_FILE}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/install-kernel.sh" \
            "${NESTED_ESCAPE_ROOTFS}" "${VALID_CONFIG}" \
            >"${NESTED_ESCAPE_OUTPUT}" 2>&1; then
    echo "kernel installer followed a nested rootfs link" >&2
    exit 1
fi
grep -Fq 'Kernel package file conflicts with rootfs path: boot/vmlinuz' \
    "${NESTED_ESCAPE_OUTPUT}"
test "$(cat "${NESTED_ESCAPE_TARGET}")" = 'outside kernel'
test -L "${NESTED_ESCAPE_ROOTFS}/boot/vmlinuz"
test ! -e "${NESTED_ESCAPE_ROOTFS}/boot/dtbs"
test ! -e "${NESTED_ESCAPE_ROOTFS}/lib"

# A digest-valid package that lacks a supported board DTB must not be installed.
INCOMPLETE_PACKAGE_ROOT="${TEST_ROOT}/incomplete-package"
INCOMPLETE_PACKAGE_FILE="${TEST_ROOT}/incomplete-kernel.apk"
INCOMPLETE_ROOTFS="${TEST_ROOT}/incomplete-rootfs"
INCOMPLETE_CONFIG="${TEST_ROOT}/incomplete.conf"
cp -a "${PACKAGE_ROOT}" "${INCOMPLETE_PACKAGE_ROOT}"
rm "${INCOMPLETE_PACKAGE_ROOT}/boot/dtbs/qcom/msm8916-yiming-uz801v3.dtb"
tar -czf "${INCOMPLETE_PACKAGE_FILE}" -C "${INCOMPLETE_PACKAGE_ROOT}" .
INCOMPLETE_SHA256=$(sha256sum "${INCOMPLETE_PACKAGE_FILE}")
INCOMPLETE_SHA256=${INCOMPLETE_SHA256%% *}
mkdir -p "${INCOMPLETE_ROOTFS}"
write_config "${INCOMPLETE_CONFIG}" \
    'https://mirror.postmarketos.org/test/incomplete-kernel.apk' \
    "${INCOMPLETE_SHA256}"
if WGET_LOG="${WGET_LOG}" \
    FAKE_KERNEL_PACKAGE="${INCOMPLETE_PACKAGE_FILE}" \
    PATH="${STUB_BIN}:${PATH}" \
        "${REPO_ROOT}/scripts/install-kernel.sh" \
            "${INCOMPLETE_ROOTFS}" "${INCOMPLETE_CONFIG}" >/dev/null 2>&1; then
    echo "kernel installer accepted a package without every board DTB" >&2
    exit 1
fi
test -z "$(find "${INCOMPLETE_ROOTFS}" -mindepth 1 -print -quit)"

printf 'kernel package verification tests passed\n'
