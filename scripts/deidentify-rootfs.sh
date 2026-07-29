#!/bin/sh
set -eu

ROOTFS=${1:-}

if [ -z "${ROOTFS}" ] || [ "${ROOTFS}" = "/" ] || [ ! -d "${ROOTFS}/etc" ]; then
    echo "Usage: $0 ROOTFS" >&2
    exit 2
fi

install -d -m 0755 "${ROOTFS}/etc/ssh" "${ROOTFS}/var/lib/dbus"

# Package installation can create these inside the build chroot. A cloned
# image must not carry either a host identity or host private keys.
find "${ROOTFS}/etc/ssh" -mindepth 1 -maxdepth 1 \
    -name 'ssh_host_*' \( -type f -o -type l \) -delete

rm -f "${ROOTFS}/etc/machine-id"
: > "${ROOTFS}/etc/machine-id"
chmod 0444 "${ROOTFS}/etc/machine-id"

if [ -e "${ROOTFS}/var/lib/dbus/machine-id" ] &&
    [ ! -f "${ROOTFS}/var/lib/dbus/machine-id" ] &&
    [ ! -L "${ROOTFS}/var/lib/dbus/machine-id" ]; then
    echo "Refusing to replace unexpected D-Bus machine-id object" >&2
    exit 1
fi

rm -f "${ROOTFS}/var/lib/dbus/machine-id"
ln -s /etc/machine-id "${ROOTFS}/var/lib/dbus/machine-id"

if find "${ROOTFS}/etc/ssh" -mindepth 1 -maxdepth 1 \
    -name 'ssh_host_*' -print -quit | grep -q .; then
    echo "SSH host keys remain in the root filesystem" >&2
    exit 1
fi

if [ -s "${ROOTFS}/etc/machine-id" ]; then
    echo "machine-id was not cleared" >&2
    exit 1
fi

if [ "$(readlink "${ROOTFS}/var/lib/dbus/machine-id")" != "/etc/machine-id" ]; then
    echo "D-Bus machine-id does not reference /etc/machine-id" >&2
    exit 1
fi
