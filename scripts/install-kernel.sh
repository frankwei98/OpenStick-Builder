#!/bin/sh
set -eu

ROOTFS=${1:-}
KERNEL_CONFIG=${2:-}

if [ -z "${ROOTFS}" ] || [ ! -d "${ROOTFS}" ]; then
    echo "Kernel install rootfs is not a directory: ${ROOTFS}" >&2
    exit 1
fi
if [ "$(cd -P "${ROOTFS}" && pwd -P)" = / ]; then
    echo "Refusing to install a kernel into /" >&2
    exit 1
fi
if [ -z "${KERNEL_CONFIG}" ] || [ ! -r "${KERNEL_CONFIG}" ]; then
    echo "Kernel package config is not readable: ${KERNEL_CONFIG}" >&2
    exit 1
fi

# This repository-owned file pins the package URL, digest, and required files.
# The caller supplies its path so tests can exercise invalid configurations.
# shellcheck disable=SC1090
. "${KERNEL_CONFIG}"

: "${POSTMARKETOS_KERNEL_URL:?Missing POSTMARKETOS_KERNEL_URL}"
: "${POSTMARKETOS_KERNEL_SHA256:?Missing POSTMARKETOS_KERNEL_SHA256}"
: "${POSTMARKETOS_KERNEL_REQUIRED_FILES:?Missing POSTMARKETOS_KERNEL_REQUIRED_FILES}"

case "${POSTMARKETOS_KERNEL_URL}" in
    https://*) ;;
    *)
        echo "Kernel package URL must use HTTPS" >&2
        exit 1
        ;;
esac

if [ "${#POSTMARKETOS_KERNEL_SHA256}" -ne 64 ]; then
    echo "Kernel package SHA256 must contain 64 hexadecimal characters" >&2
    exit 1
fi
case "${POSTMARKETOS_KERNEL_SHA256}" in
    *[!0-9a-fA-F]*)
        echo "Kernel package SHA256 contains a non-hexadecimal character" >&2
        exit 1
        ;;
esac

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openstick-kernel.XXXXXX")
PACKAGE_FILE="${WORK_DIR}/kernel.apk"
PACKAGE_LIST="${WORK_DIR}/contents"
STAGING_DIR="${WORK_DIR}/staging"

cleanup_kernel_install() {
    status=$1
    trap - EXIT HUP INT TERM
    rm -rf -- "${WORK_DIR}"
    exit "${status}"
}

trap 'cleanup_kernel_install $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

wget -O "${PACKAGE_FILE}" "${POSTMARKETOS_KERNEL_URL}"
printf '%s  %s\n' "${POSTMARKETOS_KERNEL_SHA256}" "${PACKAGE_FILE}" \
    | sha256sum -c -

# Validate the complete archive before copying any file into the rootfs. Strip
# harmless leading ./ components so required-file checks are format agnostic.
tar -tzf "${PACKAGE_FILE}" | sed 's|^\./||' > "${PACKAGE_LIST}"
while IFS= read -r archive_path; do
    case "${archive_path}" in
        /*|..|../*|*/../*|*/..)
            echo "Kernel package contains an unsafe path: ${archive_path}" >&2
            exit 1
            ;;
    esac
done < "${PACKAGE_LIST}"

printf '%s\n' "${POSTMARKETOS_KERNEL_REQUIRED_FILES}" \
    | while IFS= read -r required_path; do
        [ -n "${required_path}" ] || continue
        if ! grep -Fqx -- "${required_path}" "${PACKAGE_LIST}"; then
            echo "Kernel package is missing required file: ${required_path}" >&2
            exit 1
        fi
    done

mkdir -p "${STAGING_DIR}"
tar -xzf "${PACKAGE_FILE}" -C "${STAGING_DIR}" \
    --exclude=.PKGINFO --exclude='./.PKGINFO' \
    --exclude='.SIGN*' --exclude='./.SIGN*'
cp -a "${STAGING_DIR}/." "${ROOTFS}/"
