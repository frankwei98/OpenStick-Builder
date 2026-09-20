#!/bin/sh
set -eu

# Trusted root-owned configuration generated from usb-management.conf.
# shellcheck source=/dev/null
. /etc/openstick/setup-network.conf
: "${USB_INTERFACE:?}"
: "${USB_DEVICE_ADDRESS:?}"
: "${USB_HOST_ADDRESS:?}"

# Install a deny rule FIRST, then the one permitted path. Leave rules in place
# after setup exits. Never flush existing rules or allow an established-flow
# rule elsewhere in INPUT to bypass the interface restriction.
iptables -w -C INPUT -p tcp --dport 8080 -j DROP 2>/dev/null ||
    iptables -w -I INPUT 1 -p tcp --dport 8080 -j DROP
iptables -w -C INPUT -i "${USB_INTERFACE}" -s "${USB_HOST_ADDRESS}" \
    -d "${USB_DEVICE_ADDRESS}" -p tcp --dport 8080 -j ACCEPT 2>/dev/null ||
    iptables -w -I INPUT 1 -i "${USB_INTERFACE}" -s "${USB_HOST_ADDRESS}" \
        -d "${USB_DEVICE_ADDRESS}" -p tcp --dport 8080 -j ACCEPT
# A forged USB source on another interface must not enable SSH password auth.
iptables -w -C INPUT ! -i "${USB_INTERFACE}" -d "${USB_DEVICE_ADDRESS}" \
    -p tcp --dport 22 -j DROP 2>/dev/null ||
    iptables -w -I INPUT 1 ! -i "${USB_INTERFACE}" -d "${USB_DEVICE_ADDRESS}" \
        -p tcp --dport 22 -j DROP
