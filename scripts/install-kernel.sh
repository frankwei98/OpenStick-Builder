#!/bin/sh
set -eu

ROOTFS=${1:-}
KERNEL_CONFIG=${2:-}

if [ -z "${ROOTFS}" ] || [ ! -d "${ROOTFS}" ]; then
    echo "Kernel install rootfs is not a directory: ${ROOTFS}" >&2
    exit 1
fi
ROOTFS_REAL=$(cd -P "${ROOTFS}" && pwd -P)
if [ "${ROOTFS_REAL}" = / ]; then
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

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    TAR_IS_GNU=1
else
    TAR_IS_GNU=0
fi

list_kernel_package() {
    if [ "${TAR_IS_GNU}" -eq 1 ]; then
        tar --warning=no-unknown-keyword -tzf "${PACKAGE_FILE}"
    else
        tar -tzf "${PACKAGE_FILE}"
    fi
}

extract_kernel_package() {
    if [ "${TAR_IS_GNU}" -eq 1 ]; then
        tar --warning=no-unknown-keyword -xzf "${PACKAGE_FILE}" \
            -C "${STAGING_DIR}" \
            --exclude=.PKGINFO --exclude='./.PKGINFO' \
            --exclude='.SIGN*' --exclude='./.SIGN*'
    else
        tar -xzf "${PACKAGE_FILE}" -C "${STAGING_DIR}" \
            --exclude=.PKGINFO --exclude='./.PKGINFO' \
            --exclude='.SIGN*' --exclude='./.SIGN*'
    fi
}

validate_staged_entry() {
    target_path="${ROOTFS_REAL}/$2"

    if [ -d "$1" ] && [ ! -L "$1" ]; then
        if [ -e "${target_path}" ] || [ -L "${target_path}" ]; then
            if [ ! -d "${target_path}" ]; then
                echo "Kernel package directory conflicts with rootfs path: $2" >&2
                return 1
            fi
            if ! target_real=$(CDPATH='' cd -P "${target_path}" && pwd -P); then
                echo "Unable to resolve rootfs directory: $2" >&2
                return 1
            fi
            case "${target_real}" in
                "${ROOTFS_REAL}"|"${ROOTFS_REAL}"/*) ;;
                *)
                    echo "Rootfs directory escapes through a symlink: $2" >&2
                    return 1
                    ;;
            esac
        fi

        for child_path in \
            "$1"/* \
            "$1"/.[!.]* \
            "$1"/..?*; do
            [ -e "${child_path}" ] || [ -L "${child_path}" ] || continue
            child_name=${child_path##*/}
            validate_staged_entry "${child_path}" "$2/${child_name}"
        done
    elif [ -e "${target_path}" ] || [ -L "${target_path}" ]; then
        if [ -L "${target_path}" ] || [ ! -f "${target_path}" ]; then
            echo "Kernel package file conflicts with rootfs path: $2" >&2
            return 1
        fi
    fi
}

merge_staged_entry() {
    staged_path=$1
    entry_name=${staged_path##*/}
    target_path="${ROOTFS_REAL}/${entry_name}"

    if [ -d "${staged_path}" ] && [ ! -L "${staged_path}" ] && \
        { [ -e "${target_path}" ] || [ -L "${target_path}" ]; }; then
        target_real=$(CDPATH='' cd -P "${target_path}" && pwd -P)
        cp -a "${staged_path}/." "${target_real}/"
    else
        cp -a "${staged_path}" "${ROOTFS_REAL}/"
    fi
}

wget -O "${PACKAGE_FILE}" "${POSTMARKETOS_KERNEL_URL}"
printf '%s  %s\n' "${POSTMARKETOS_KERNEL_SHA256}" "${PACKAGE_FILE}" \
    | sha256sum -c -

# Validate the complete archive before copying any file into the rootfs. Strip
# harmless leading ./ components so required-file checks are format agnostic.
list_kernel_package | sed 's|^\./||' > "${PACKAGE_LIST}"
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
extract_kernel_package

# Debian uses merged-/usr symlinks such as /lib -> usr/lib, while the Alpine
# APK contains real top-level directories. Validate every merge destination
# before copying anything, then merge directory contents through safe links.
for staged_path in \
    "${STAGING_DIR}"/* \
    "${STAGING_DIR}"/.[!.]* \
    "${STAGING_DIR}"/..?*; do
    [ -e "${staged_path}" ] || [ -L "${staged_path}" ] || continue
    validate_staged_entry "${staged_path}" "${staged_path##*/}"
done
for staged_path in \
    "${STAGING_DIR}"/* \
    "${STAGING_DIR}"/.[!.]* \
    "${STAGING_DIR}"/..?*; do
    [ -e "${staged_path}" ] || [ -L "${staged_path}" ] || continue
    merge_staged_entry "${staged_path}"
done
