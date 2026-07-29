#!/bin/sh
set -eu

ROOTFS=${1:-}
CONFIG_FILE=${2:-}

if [ -z "${ROOTFS}" ] || [ "${ROOTFS}" = "/" ]; then
    echo "Usage: $0 ROOTFS CONFIG_FILE" >&2
    exit 2
fi

if [ ! -r "${CONFIG_FILE}" ]; then
    echo "USB management config is not readable: ${CONFIG_FILE}" >&2
    exit 2
fi

# This is a trusted, repository-owned file containing shell assignments.
# shellcheck source=/dev/null
. "${CONFIG_FILE}"

: "${USB_INTERFACE:?USB_INTERFACE is required}"
: "${USB_DEVICE_ADDRESS:?USB_DEVICE_ADDRESS is required}"
: "${USB_PREFIX:?USB_PREFIX is required}"
: "${USB_HOST_ADDRESS:?USB_HOST_ADDRESS is required}"
: "${USB_NETMASK:?USB_NETMASK is required}"
: "${USB_DHCP_LEASE:?USB_DHCP_LEASE is required}"

validate_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    exit 1
                }
            }
        }
    '
}

case "${USB_INTERFACE}" in
    *[!a-zA-Z0-9_.-]*)
        echo "Invalid USB_INTERFACE: ${USB_INTERFACE}" >&2
        exit 2
        ;;
esac

case "${USB_PREFIX}" in
    ''|*[!0-9]*)
        echo "USB_PREFIX must be numeric" >&2
        exit 2
        ;;
esac

if [ "${USB_PREFIX}" -lt 1 ] || [ "${USB_PREFIX}" -gt 30 ]; then
    echo "USB_PREFIX must be between 1 and 30" >&2
    exit 2
fi

for address in "${USB_DEVICE_ADDRESS}" "${USB_HOST_ADDRESS}" "${USB_NETMASK}"; do
    if ! validate_ipv4 "${address}"; then
        echo "Invalid IPv4 address or netmask: ${address}" >&2
        exit 2
    fi
done

expected_netmask=$(awk -v prefix="${USB_PREFIX}" 'BEGIN {
    for (i = 0; i < 4; i++) {
        bits = prefix - (i * 8)
        if (bits >= 8) {
            octet = 255
        } else if (bits <= 0) {
            octet = 0
        } else {
            octet = 256 - (2 ^ (8 - bits))
        }
        printf "%s%d", (i ? "." : ""), octet
    }
}')

if [ "${USB_NETMASK}" != "${expected_netmask}" ]; then
    echo "USB_NETMASK does not match USB_PREFIX (${expected_netmask})" >&2
    exit 2
fi

if [ "${USB_DEVICE_ADDRESS}" = "${USB_HOST_ADDRESS}" ]; then
    echo "USB device and host addresses must differ" >&2
    exit 2
fi

if ! awk \
    -v device="${USB_DEVICE_ADDRESS}" \
    -v host="${USB_HOST_ADDRESS}" \
    -v prefix="${USB_PREFIX}" '
    function ipv4_to_integer(address, octets) {
        split(address, octets, ".")
        return (((octets[1] * 256) + octets[2]) * 256 + octets[3]) * 256 + octets[4]
    }
    BEGIN {
        device_integer = ipv4_to_integer(device)
        host_integer = ipv4_to_integer(host)
        block_size = 2 ^ (32 - prefix)
        network = int(device_integer / block_size) * block_size
        broadcast = network + block_size - 1

        if (host_integer < network || host_integer > broadcast ||
            device_integer == network || device_integer == broadcast ||
            host_integer == network || host_integer == broadcast) {
            exit 1
        }
    }
'; then
    echo "USB device and host must be usable addresses in the same subnet" >&2
    exit 2
fi

install -d -m 0755 \
    "${ROOTFS}/etc/NetworkManager/system-connections" \
    "${ROOTFS}/etc/openstick" \
    "${ROOTFS}/etc/ssh/sshd_config.d" \
    "${ROOTFS}/etc/udev/rules.d"

cat > "${ROOTFS}/etc/NetworkManager/system-connections/usb-management.nmconnection" << EOF
[connection]
id=usb-management
uuid=6d73d069-b482-41ec-bbc2-f769089700cb
type=ethernet
interface-name=${USB_INTERFACE}
autoconnect=true
autoconnect-priority=100

[ethernet]

[ipv4]
address1=${USB_DEVICE_ADDRESS}/${USB_PREFIX}
method=manual
never-default=true
ignore-auto-dns=true
may-fail=false

[ipv6]
method=disabled

[proxy]
EOF
chmod 0600 "${ROOTFS}/etc/NetworkManager/system-connections/usb-management.nmconnection"

cat > "${ROOTFS}/etc/openstick/usb-dhcp.conf" << EOF
# DHCP only: DNS is disabled and neither a router nor a DNS server is sent.
port=0
interface=${USB_INTERFACE}
bind-dynamic
no-resolv
no-hosts

dhcp-authoritative
dhcp-lease-max=1
dhcp-range=${USB_HOST_ADDRESS},${USB_HOST_ADDRESS},${USB_NETMASK},${USB_DHCP_LEASE}
dhcp-option=option:router
dhcp-option=option:dns-server
dhcp-leasefile=/var/lib/misc/openstick-usb-dhcp.leases
EOF
chmod 0644 "${ROOTFS}/etc/openstick/usb-dhcp.conf"

cat > "${ROOTFS}/etc/ssh/sshd_config.d/00-openstick-usb-root.conf" << EOF
# Preserve root public-key access elsewhere, but allow its initial password
# only when the connection is addressed to the USB management endpoint.
PermitEmptyPasswords no
PermitRootLogin prohibit-password

Match User root LocalAddress ${USB_DEVICE_ADDRESS}
    PermitRootLogin yes
    PasswordAuthentication yes

Match all
EOF
chmod 0644 "${ROOTFS}/etc/ssh/sshd_config.d/00-openstick-usb-root.conf"

cat > "${ROOTFS}/etc/udev/rules.d/99-nm-usb-management.rules" << EOF
SUBSYSTEM=="net", ACTION=="add|change|move", KERNEL=="${USB_INTERFACE}", ENV{NM_UNMANAGED}="0"
EOF
chmod 0644 "${ROOTFS}/etc/udev/rules.d/99-nm-usb-management.rules"
