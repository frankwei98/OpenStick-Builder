#!/bin/sh -e

CHROOT=${CHROOT-"$(pwd)/rootfs"}
SRCDIR="$(pwd)/src"
BUILD_ROOT="$(pwd)/build/gadget-tools"
LIBUSBGX_BUILD_DIR="${BUILD_ROOT}/libusbgx"
GT_BUILD_DIR="${BUILD_ROOT}/gt"
DIST_DIR="$(pwd)/dist"
TARGET_LIBDIR="${CHROOT}/usr/lib/aarch64-linux-gnu"
TARGET_CFLAGS="--sysroot=${CHROOT} -B${TARGET_LIBDIR}/"
TARGET_PKG_CONFIG_LIBDIR="${TARGET_LIBDIR}/pkgconfig:${CHROOT}/usr/lib/pkgconfig:${CHROOT}/usr/share/pkgconfig"

. scripts/build-host.sh

BUILD_HOST_ARCHITECTURE=$(detect_build_host_architecture)
require_supported_build_host_architecture "${BUILD_HOST_ARCHITECTURE}"
ROOTFS_CHROOT_MODE=$(build_host_rootfs_mode "${BUILD_HOST_ARCHITECTURE}")

printf 'Build host architecture: %s (%s rootfs chroot)\n' \
    "${BUILD_HOST_ARCHITECTURE}" "${ROOTFS_CHROOT_MODE}"

# install gt dependencies
case "${ROOTFS_CHROOT_MODE}" in
    foreign)
        chroot "${CHROOT}" qemu-aarch64-static /bin/sh \
            -c "apt update; apt install libc6-dev libconfig-dev -y"
        ;;
    native)
        chroot "${CHROOT}" /bin/sh \
            -c "apt update; apt install libc6-dev libconfig-dev -y"
        ;;
esac

# build and install gt
rm -rf -- "${BUILD_ROOT}" "${DIST_DIR}"
mkdir -p "${LIBUSBGX_BUILD_DIR}" "${GT_BUILD_DIR}" "${DIST_DIR}"
(
cd src/libusbgx/
autoreconf -i
)

(
cd "${LIBUSBGX_BUILD_DIR}"
CC=aarch64-linux-gnu-gcc \
CFLAGS="${TARGET_CFLAGS}" \
PKG_CONFIG_PATH='' \
PKG_CONFIG_LIBDIR="${TARGET_PKG_CONFIG_LIBDIR}" \
    "${SRCDIR}/libusbgx/configure" \
        --host aarch64-linux-gnu \
        --prefix=/usr \
        --with-sysroot="${CHROOT}"
)
make -C "${LIBUSBGX_BUILD_DIR}" "DESTDIR=${DIST_DIR}" install

PKG_CONFIG_PATH='' \
PKG_CONFIG_LIBDIR="${DIST_DIR}/usr/lib/pkgconfig:${TARGET_PKG_CONFIG_LIBDIR}" \
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_C_FLAGS="-B${TARGET_LIBDIR}/ -I${DIST_DIR}/usr/include -L${DIST_DIR}/usr/lib" \
        -DCMAKE_CXX_FLAGS="-B${TARGET_LIBDIR}/ -I${DIST_DIR}/usr/include -L${DIST_DIR}/usr/lib" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_SYSROOT="${CHROOT}" \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -S "${SRCDIR}/gt/source" \
        -B "${GT_BUILD_DIR}"

make -C "${GT_BUILD_DIR}" "DESTDIR=${DIST_DIR}" install

rm -rf "${DIST_DIR:?}/usr/share" "${DIST_DIR:?}/usr/lib/cmake" \
    "${DIST_DIR:?}/usr/lib/pkgconfig" "${DIST_DIR:?}"/usr/lib/*a \
    "${DIST_DIR:?}"/usr/bin/ga* "${DIST_DIR:?}"/usr/bin/s* \
    "${DIST_DIR:?}/usr/include"

mkdir -p "${DIST_DIR}/etc"
cp -a configs/templates "${DIST_DIR}/etc/gt"
