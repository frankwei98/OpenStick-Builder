#!/bin/sh -e

DEBIAN_ARCHIVE_KEYRING_VERSION=2025.1
DEBIAN_ARCHIVE_KEYRING_SHA256=9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac
DEBOOTSTRAP_KEYRING=${DEBOOTSTRAP_KEYRING=$(pwd)/build/debian-archive-keyring.gpg}

apt update
apt install -y \
    android-sdk-libsparse-utils \
    autoconf \
    automake \
    binfmt-support \
    cmake \
    debootstrap \
    device-tree-compiler \
    fdisk \
    g++-aarch64-linux-gnu \
    gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi \
    libtool \
    make \
    pkg-config \
    python3-cryptography \
    python3-pyasn1-modules \
    python3-pycryptodome \
    qemu-user-static \
    unzip \
    wget

KEYRING_TEMP_DIR=$(mktemp -d)
KEYRING_PACKAGE="${KEYRING_TEMP_DIR}/debian-archive-keyring.deb"
KEYRING_EXTRACT_DIR="${KEYRING_TEMP_DIR}/extract"

cleanup_keyring_package() {
    cleanup_status=$1
    trap - EXIT HUP INT TERM
    rm -rf "${KEYRING_TEMP_DIR}" || :
    exit "${cleanup_status}"
}

trap 'cleanup_keyring_package $?' EXIT
trap 'cleanup_keyring_package 129' HUP
trap 'cleanup_keyring_package 130' INT
trap 'cleanup_keyring_package 143' TERM

wget -O "${KEYRING_PACKAGE}" \
    "https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_${DEBIAN_ARCHIVE_KEYRING_VERSION}_all.deb"
echo "${DEBIAN_ARCHIVE_KEYRING_SHA256}  ${KEYRING_PACKAGE}" | sha256sum -c -
mkdir -p "${KEYRING_EXTRACT_DIR}"
dpkg-deb -x "${KEYRING_PACKAGE}" "${KEYRING_EXTRACT_DIR}"
install -D -m 0644 \
    "${KEYRING_EXTRACT_DIR}/usr/share/keyrings/debian-archive-keyring.pgp" \
    "${DEBOOTSTRAP_KEYRING}"
