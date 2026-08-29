#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

#package rootfs
rm -f rootfs.raw boot.raw
mkdir -p files mnt

MOUNT_DIR=$(CDPATH='' cd -P mnt && pwd -P)
if ! command -v findmnt >/dev/null 2>&1; then
    echo "Unable to verify image mounts: findmnt is unavailable" >&2
    exit 2
fi
if ! ACTIVE_MOUNTS=$(findmnt -rn -o TARGET 2>/dev/null); then
    echo "Unable to inspect active mounts" >&2
    exit 2
fi
if printf '%s\n' "${ACTIVE_MOUNTS}" |
    awk -v mount_dir="${MOUNT_DIR}" \
        '$0 == mount_dir { found = 1 } END { exit !found }'; then
    echo "Refusing to reuse mounted image directory: ${MOUNT_DIR}" >&2
    exit 2
fi

IMAGE_MOUNTED=0

cleanup_image_mount() {
    cleanup_status=$1
    trap - EXIT HUP INT TERM

    if [ "${IMAGE_MOUNTED}" -eq 1 ] && ! umount "${MOUNT_DIR}"; then
        if [ "${cleanup_status}" -eq 0 ]; then
            cleanup_status=1
        fi
    fi
    exit "${cleanup_status}"
}

unmount_image() {
    umount "${MOUNT_DIR}"
    IMAGE_MOUNTED=0
}

trap 'cleanup_image_mount $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# create boot
truncate -s 67108864 boot.raw
mkfs.ext2 boot.raw
mount boot.raw "${MOUNT_DIR}"
IMAGE_MOUNTED=1
tar xf rootfs.tgz -C "${MOUNT_DIR}" ./boot --exclude='./boot/linux.efi' --strip-components=2
unmount_image

# create root img
truncate -s 1610612736 rootfs.raw
mkfs.ext4 rootfs.raw
mount rootfs.raw "${MOUNT_DIR}"
IMAGE_MOUNTED=1
tar xpf rootfs.tgz -C "${MOUNT_DIR}" --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

# install gt
cp -a dist/* "${MOUNT_DIR}"

unmount_image

# create sparse android images 
img2simg rootfs.raw files/rootfs.bin
img2simg boot.raw files/boot.bin
