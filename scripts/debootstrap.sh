#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
RELEASE=${RELEASE=trixie}
DEBOOTSTRAP_KEYRING=${DEBOOTSTRAP_KEYRING=$(pwd)/build/debian-archive-keyring.gpg}
HOST_NAME=${HOST_NAME=openstick-debian}
OPENSTICK_BOARD_PROFILES=${OPENSTICK_BOARD_PROFILES:-configs/openstick-board-profiles}
export OPENSTICK_BOARD_PROFILES

# shellcheck disable=SC1091
. scripts/build-host.sh
# shellcheck disable=SC1091
. scripts/openstick-board-profile.sh

openstick_build_profile_load "${OPENSTICK_BOARD:-generic}"

BUILD_HOST_ARCHITECTURE=$(detect_build_host_architecture)
require_supported_build_host_architecture "${BUILD_HOST_ARCHITECTURE}"
ROOTFS_BOOTSTRAP_MODE=$(build_host_rootfs_mode "${BUILD_HOST_ARCHITECTURE}")

printf 'Build host architecture: %s (%s rootfs bootstrap)\n' \
    "${BUILD_HOST_ARCHITECTURE}" "${ROOTFS_BOOTSTRAP_MODE}"

invalid_chroot() {
    echo "Refusing unsafe CHROOT: ${CHROOT:-<empty>}" >&2
    exit 2
}

physical_directory() (
    CDPATH=
    export CDPATH
    cd -P -- "$1" 2>/dev/null && pwd -P
)

if [ -z "${CHROOT}" ] || [ -L "${CHROOT}" ]; then
    invalid_chroot
fi

case "${CHROOT}" in
    /*) ;;
    *) CHROOT="$(pwd)/${CHROOT}" ;;
esac

if [ -d "${CHROOT}" ]; then
    CHROOT=$(physical_directory "${CHROOT}") || invalid_chroot
elif [ -e "${CHROOT}" ]; then
    invalid_chroot
else
    CHROOT_BASENAME=${CHROOT##*/}
    CHROOT_PARENT=${CHROOT%/*}
    case "${CHROOT_BASENAME}" in
        ""|"."|"..") invalid_chroot ;;
    esac
    CHROOT_PARENT=$(physical_directory "${CHROOT_PARENT}") ||
        invalid_chroot
    CHROOT="${CHROOT_PARENT}/${CHROOT_BASENAME}"
fi

[ "${CHROOT}" != "/" ] || invalid_chroot

BUILD_ROOT=$(physical_directory "$(pwd)") || invalid_chroot
case "${CHROOT}" in
    *[!/]*) ;;
    *) invalid_chroot ;;
esac
case "${BUILD_ROOT}/" in
    "${CHROOT}/"*) invalid_chroot ;;
esac

if ! command -v findmnt >/dev/null 2>&1; then
    echo "Unable to verify CHROOT mounts: findmnt is unavailable" >&2
    exit 2
fi

if ! ACTIVE_MOUNTS=$(findmnt -rn -o TARGET 2>/dev/null); then
    echo "Unable to inspect active mounts" >&2
    exit 2
fi
CHROOT_MOUNTS=$(printf '%s\n' "${ACTIVE_MOUNTS}" |
    awk -v chroot="${CHROOT}" \
        '$0 == chroot || index($0, chroot "/") == 1')
if [ -n "${CHROOT_MOUNTS}" ]; then
    printf 'Refusing to remove CHROOT with active mounts:\n%s\n' \
        "${CHROOT_MOUNTS}" >&2
    exit 2
fi

rm -rf --one-file-system --preserve-root=all -- "${CHROOT}"

case "${ROOTFS_BOOTSTRAP_MODE}" in
    foreign)
        debootstrap --foreign --arch arm64 \
            --keyring "${DEBOOTSTRAP_KEYRING}" "${RELEASE}" "${CHROOT}"
        cp "$(command -v qemu-aarch64-static)" "${CHROOT}/usr/bin"
        chroot "${CHROOT}" qemu-aarch64-static \
            /bin/bash /debootstrap/debootstrap --second-stage
        ;;
    native)
        debootstrap --arch arm64 \
            --keyring "${DEBOOTSTRAP_KEYRING}" "${RELEASE}" "${CHROOT}"
        ;;
esac

cat << EOF > "${CHROOT}/etc/apt/sources.list"
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

CHROOT_PROC_MOUNTED=0
CHROOT_SYS_MOUNTED=0
CHROOT_DEV_MOUNTED=0
CHROOT_DEV_PTS_MOUNTED=0
CHROOT_RUN_MOUNTED=0

cleanup_chroot_mounts() {
    cleanup_status=$1
    cleanup_failed=0
    trap - EXIT HUP INT TERM

    if [ "${CHROOT_RUN_MOUNTED}" -eq 1 ]; then
        umount "${CHROOT}/run" || cleanup_failed=1
    fi
    if [ "${CHROOT_DEV_PTS_MOUNTED}" -eq 1 ]; then
        umount "${CHROOT}/dev/pts" || cleanup_failed=1
    fi
    if [ "${CHROOT_DEV_MOUNTED}" -eq 1 ]; then
        umount "${CHROOT}/dev" || cleanup_failed=1
    fi
    if [ "${CHROOT_SYS_MOUNTED}" -eq 1 ]; then
        umount "${CHROOT}/sys" || cleanup_failed=1
    fi
    if [ "${CHROOT_PROC_MOUNTED}" -eq 1 ]; then
        umount "${CHROOT}/proc" || cleanup_failed=1
    fi

    if [ "${cleanup_status}" -eq 0 ] && [ "${cleanup_failed}" -ne 0 ]; then
        cleanup_status=1
    fi
    exit "${cleanup_status}"
}

unmount_chroot_filesystems() {
    umount "${CHROOT}/run"
    CHROOT_RUN_MOUNTED=0
    umount "${CHROOT}/dev/pts"
    CHROOT_DEV_PTS_MOUNTED=0
    umount "${CHROOT}/dev"
    CHROOT_DEV_MOUNTED=0
    umount "${CHROOT}/sys"
    CHROOT_SYS_MOUNTED=0
    umount "${CHROOT}/proc"
    CHROOT_PROC_MOUNTED=0
}

trap 'cleanup_chroot_mounts $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mount -t proc proc "${CHROOT}/proc/"
CHROOT_PROC_MOUNTED=1
mount -t sysfs sys "${CHROOT}/sys/"
CHROOT_SYS_MOUNTED=1
mount -o bind /dev/ "${CHROOT}/dev/"
CHROOT_DEV_MOUNTED=1
mount -o bind /dev/pts/ "${CHROOT}/dev/pts/"
CHROOT_DEV_PTS_MOUNTED=1
mount -o bind /run "${CHROOT}/run/"
CHROOT_RUN_MOUNTED=1

cp scripts/setup.sh "${CHROOT}"
case "${ROOTFS_BOOTSTRAP_MODE}" in
    foreign)
        chroot "${CHROOT}" qemu-aarch64-static /bin/sh -c /setup.sh
        ;;
    native)
        chroot "${CHROOT}" /bin/sh -c /setup.sh
        ;;
esac

# cleanup
unmount_chroot_filesystems

rm -f "${CHROOT}/setup.sh"
: > "${CHROOT}/root/.bash_history"

echo "${HOST_NAME}" > "${CHROOT}/etc/hostname"
sed -i "/localhost/ s/$/ ${HOST_NAME}/" "${CHROOT}/etc/hosts"

# setup systemd services
cp -a configs/system/* "${CHROOT}/etc/systemd/system"

cp -a scripts/msm-firmware-loader.sh "${CHROOT}/usr/sbin"
install -D -m 0755 scripts/openstick-usb-gadget.sh \
    "${CHROOT}/usr/sbin/openstick-usb-gadget"
install -D -m 0644 configs/openstick-usb-gadget.conf \
    "${CHROOT}/etc/default/openstick-usb-gadget"
install -D -m 0755 scripts/openstick-resize-rootfs.sh \
    "${CHROOT}/usr/sbin/openstick-resize-rootfs"
install -D -m 0644 configs/logind.conf.d/50-openstick-power-key.conf \
    "${CHROOT}/etc/systemd/logind.conf.d/50-openstick-power-key.conf"
install -D -m 0755 scripts/openstick-modem-isolate.sh \
    "${CHROOT}/usr/sbin/openstick-modem-isolate"
install -D -m 0644 configs/openstick-modem-isolation.conf \
    "${CHROOT}/etc/default/openstick-modem-isolation"
install -D -m 0644 configs/udev/80-openstick-modem-isolation.rules \
    "${CHROOT}/etc/udev/rules.d/80-openstick-modem-isolation.rules"
install -D -m 0755 scripts/openstick-board \
    "${CHROOT}/usr/local/sbin/openstick-board"
install -D -m 0644 scripts/openstick-board-profile.sh \
    "${CHROOT}/usr/local/lib/openstick/board-profile.sh"
install -D -m 0644 configs/openstick-board-profiles \
    "${CHROOT}/usr/local/share/openstick/board-profiles"
install -D -m 0644 configs/profile.d/openstick-status.sh \
    "${CHROOT}/etc/profile.d/openstick-status.sh"

mkdir -p \
    "${CHROOT}/etc/systemd/system/multi-user.target.wants" \
    "${CHROOT}/etc/systemd/system/usb-gadget.target.wants"
ln -sf /etc/systemd/system/openstick-usb-gadget.service \
    "${CHROOT}/etc/systemd/system/usb-gadget.target.wants/openstick-usb-gadget.service"
ln -sf /etc/systemd/system/getty@ttyGS0.service \
    "${CHROOT}/etc/systemd/system/usb-gadget.target.wants/getty@ttyGS0.service"
ln -sf /etc/systemd/system/openstick-usb-dhcp.service \
    "${CHROOT}/etc/systemd/system/usb-gadget.target.wants/openstick-usb-dhcp.service"
ln -sf /etc/systemd/system/openstick-resize-rootfs.service \
    "${CHROOT}/etc/systemd/system/multi-user.target.wants/openstick-resize-rootfs.service"

# setup NetworkManager
cp configs/*.nmconnection "${CHROOT}/etc/NetworkManager/system-connections"
scripts/render-usb-management.sh "${CHROOT}" configs/usb-management.conf
chmod 0600 "${CHROOT}/etc/NetworkManager/system-connections/"*

# The package service reads the system-wide dnsmasq configuration. Mask it so
# only the explicitly DHCP-only OpenStick instance can start.
rm -f "${CHROOT}/etc/systemd/system/multi-user.target.wants/dnsmasq.service"
ln -sf /dev/null "${CHROOT}/etc/systemd/system/dnsmasq.service"

# install kernel
wget -O - http://mirror.postmarketos.org/postmarketos/v24.06/aarch64/linux-postmarketos-qcom-msm8916-6.6-r5.apk \
    | tar xkzf - -C "${CHROOT}" --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null

mkdir -p "${CHROOT}/boot/extlinux"
cp configs/extlinux.conf "${CHROOT}/boot/extlinux"

# copy custom dtb's
cp dtbs/* "${CHROOT}/boot/dtbs/qcom"

if [ "${OPENSTICK_BUILD_PROFILE}" = generic ]; then
    printf 'Leaving board profile unconfigured for post-flash selection\n'
else
    OPENSTICK_ROOT="${CHROOT}" \
    OPENSTICK_BOARD_LIB=scripts/openstick-board-profile.sh \
    OPENSTICK_BOARD_PROFILES=configs/openstick-board-profiles \
        scripts/openstick-board initialize "${OPENSTICK_BUILD_PROFILE}"
fi

# create missing directory
mkdir -p "${CHROOT}/lib/firmware/msm-firmware-loader"

# update fstab
printf 'PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46\t/boot\text2\tdefaults\t0 2\n' > "${CHROOT}/etc/fstab"

# Remove build-time identity immediately before packaging the cloneable image.
scripts/deidentify-rootfs.sh "${CHROOT}"

# backup rootfs
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C "${CHROOT}" .
