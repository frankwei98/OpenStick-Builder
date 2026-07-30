#!/bin/sh -e

CHROOT=${CHROOT-"$(pwd)/rootfs"}
SRCDIR="$(pwd)/src"
TARGET_LIBDIR="${CHROOT}/usr/lib/aarch64-linux-gnu"
TARGET_CFLAGS="--sysroot=${CHROOT} -B${TARGET_LIBDIR}/"
TARGET_PKG_CONFIG_LIBDIR="${TARGET_LIBDIR}/pkgconfig:${CHROOT}/usr/lib/pkgconfig:${CHROOT}/usr/share/pkgconfig"

# install gt dependencies
chroot "${CHROOT}" qemu-aarch64-static /bin/sh \
    -c " apt update; apt install libc6-dev libconfig-dev -y"

# build and install gt
(
cd src/libusbgx/
autoreconf -i
)

mkdir -p build
(
cd build
CC=aarch64-linux-gnu-gcc \
CFLAGS="${TARGET_CFLAGS}" \
PKG_CONFIG_PATH='' \
PKG_CONFIG_LIBDIR="${TARGET_PKG_CONFIG_LIBDIR}" \
    "${SRCDIR}/libusbgx/configure" \
        --host aarch64-linux-gnu \
        --prefix=/usr \
        --with-sysroot="${CHROOT}"
)
make -C build "DESTDIR=$(pwd)/dist" install

rm -rf build/*
PKG_CONFIG_PATH='' \
PKG_CONFIG_LIBDIR="$(pwd)/dist/usr/lib/pkgconfig:${TARGET_PKG_CONFIG_LIBDIR}" \
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_C_FLAGS="-B${TARGET_LIBDIR}/ -I$(pwd)/dist/usr/include -L$(pwd)/dist/usr/lib" \
        -DCMAKE_CXX_FLAGS="-B${TARGET_LIBDIR}/ -I$(pwd)/dist/usr/include -L$(pwd)/dist/usr/lib" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_SYSROOT="${CHROOT}" \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -S "${SRCDIR}/gt/source" \
        -B build

make -C build "DESTDIR=$(pwd)/dist" install

rm -rf dist/usr/share dist/usr/lib/cmake dist/usr/lib/pkgconfig \
    dist/usr/lib/*a dist/usr/bin/ga* dist/usr/bin/s* dist/usr/include

cp -a configs/templates dist/etc/gt
