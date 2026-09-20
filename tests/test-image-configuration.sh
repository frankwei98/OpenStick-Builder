#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-image-test.XXXXXX")
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

ROOTFS="${TEST_ROOT}/rootfs"
install -d "${ROOTFS}/etc"

"${REPO_ROOT}/scripts/render-usb-management.sh" \
    "${ROOTFS}" \
    "${REPO_ROOT}/configs/usb-management.conf"

NM_PROFILE="${ROOTFS}/etc/NetworkManager/system-connections/usb-management.nmconnection"
DHCP_CONFIG="${ROOTFS}/etc/openstick/usb-dhcp.conf"
SSH_CONFIG="${ROOTFS}/etc/ssh/sshd_config.d/00-openstick-usb-root.conf"
SETUP_CONFIG="${ROOTFS}/etc/openstick/setup.json"
SETUP_NETWORK_CONFIG="${ROOTFS}/etc/openstick/setup-network.conf"
MASS_STORAGE_TEMPLATE="${REPO_ROOT}/configs/templates/mass.scheme"

if grep -q '/home/user/' "${MASS_STORAGE_TEMPLATE}"; then
    echo "mass-storage template references the removed user account" >&2
    exit 1
fi
test "$(grep -c '^[[:space:]]*file = "";' "${MASS_STORAGE_TEMPLATE}")" -eq 2

grep -qx 'address1=172.30.255.1/30' "${NM_PROFILE}"
grep -qx 'method=manual' "${NM_PROFILE}"
grep -qx 'never-default=true' "${NM_PROFILE}"
if grep -q 'method=shared' "${NM_PROFILE}"; then
    echo "USB profile unexpectedly enables NetworkManager sharing" >&2
    exit 1
fi

grep -qx 'port=0' "${DHCP_CONFIG}"
grep -qx 'dhcp-range=172.30.255.2,172.30.255.2,255.255.255.252,12h' "${DHCP_CONFIG}"
grep -qx 'dhcp-option=option:router' "${DHCP_CONFIG}"
grep -qx 'dhcp-option=option:dns-server' "${DHCP_CONFIG}"

grep -qx 'PermitEmptyPasswords no' "${SSH_CONFIG}"
grep -qx 'PermitRootLogin no' "${SSH_CONFIG}"
grep -qx 'PasswordAuthentication no' "${SSH_CONFIG}"
grep -qx 'KbdInteractiveAuthentication no' "${SSH_CONFIG}"
grep -qx 'Match User openstick Address 172.30.255.2 LocalAddress 172.30.255.1' "${SSH_CONFIG}"
grep -A1 -x 'Match User openstick Address 172.30.255.2 LocalAddress 172.30.255.1' "${SSH_CONFIG}" |
    grep -qx '    PasswordAuthentication yes'

grep -qx '{"address":"172.30.255.1","peer":"172.30.255.2"}' "${SETUP_CONFIG}"
grep -qx 'USB_INTERFACE="usb0"' "${SETUP_NETWORK_CONFIG}"
grep -qx 'USB_DEVICE_ADDRESS="172.30.255.1"' "${SETUP_NETWORK_CONFIG}"
grep -qx 'USB_HOST_ADDRESS="172.30.255.2"' "${SETUP_NETWORK_CONFIG}"

if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -q -t ed25519 -N '' -f "${TEST_ROOT}/host-key"
    {
        printf 'HostKey %s\n' "${TEST_ROOT}/host-key"
        cat "${SSH_CONFIG}"
    } > "${TEST_ROOT}/sshd_config"

    root_usb_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=root,addr=172.30.255.2,laddr=172.30.255.1,lport=22)
    root_other_source_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=root,addr=192.168.4.2,laddr=172.30.255.1,lport=22)
    root_other_target_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=root,addr=192.168.4.2,laddr=192.168.4.1,lport=22)
    openstick_usb_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=openstick,addr=172.30.255.2,laddr=172.30.255.1,lport=22)
    openstick_other_source_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=openstick,addr=192.168.4.2,laddr=172.30.255.1,lport=22)
    openstick_other_target_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=openstick,addr=172.30.255.2,laddr=192.168.4.1,lport=22)

    grep -qx 'permitrootlogin no' <<< "${root_usb_policy}"
    grep -qx 'passwordauthentication no' <<< "${root_usb_policy}"
    grep -qx 'kbdinteractiveauthentication no' <<< "${root_usb_policy}"
    grep -qx 'permitemptypasswords no' <<< "${root_usb_policy}"
    grep -qx 'permitrootlogin no' <<< "${root_other_source_policy}"
    grep -qx 'passwordauthentication no' <<< "${root_other_source_policy}"
    grep -qx 'kbdinteractiveauthentication no' <<< "${root_other_source_policy}"
    grep -qx 'permitrootlogin no' <<< "${root_other_target_policy}"
    grep -qx 'passwordauthentication no' <<< "${root_other_target_policy}"
    grep -qx 'kbdinteractiveauthentication no' <<< "${root_other_target_policy}"

    grep -qx 'passwordauthentication yes' <<< "${openstick_usb_policy}"
    grep -qx 'kbdinteractiveauthentication no' <<< "${openstick_usb_policy}"
    grep -qx 'pubkeyauthentication yes' <<< "${openstick_usb_policy}"
    grep -qx 'passwordauthentication no' <<< "${openstick_other_source_policy}"
    grep -qx 'kbdinteractiveauthentication no' <<< "${openstick_other_source_policy}"
    grep -qx 'pubkeyauthentication yes' <<< "${openstick_other_source_policy}"
    grep -qx 'passwordauthentication no' <<< "${openstick_other_target_policy}"
    grep -qx 'kbdinteractiveauthentication no' <<< "${openstick_other_target_policy}"
    grep -qx 'pubkeyauthentication yes' <<< "${openstick_other_target_policy}"
fi

CUSTOM_ROOTFS="${TEST_ROOT}/custom-rootfs"
CUSTOM_CONFIG="${TEST_ROOT}/custom-usb-management.conf"
cat > "${CUSTOM_CONFIG}" <<'EOF'
USB_INTERFACE="setup-test0"
USB_DEVICE_ADDRESS="192.0.2.1"
USB_PREFIX="30"
USB_HOST_ADDRESS="192.0.2.2"
USB_NETMASK="255.255.255.252"
USB_DHCP_LEASE="30m"
EOF
install -d "${CUSTOM_ROOTFS}/etc"
"${REPO_ROOT}/scripts/render-usb-management.sh" \
    "${CUSTOM_ROOTFS}" "${CUSTOM_CONFIG}"
grep -qx 'address1=192.0.2.1/30' \
    "${CUSTOM_ROOTFS}/etc/NetworkManager/system-connections/usb-management.nmconnection"
grep -qx 'dhcp-range=192.0.2.2,192.0.2.2,255.255.255.252,30m' \
    "${CUSTOM_ROOTFS}/etc/openstick/usb-dhcp.conf"
grep -qx 'Match User openstick Address 192.0.2.2 LocalAddress 192.0.2.1' \
    "${CUSTOM_ROOTFS}/etc/ssh/sshd_config.d/00-openstick-usb-root.conf"
grep -qx '{"address":"192.0.2.1","peer":"192.0.2.2"}' \
    "${CUSTOM_ROOTFS}/etc/openstick/setup.json"
grep -qx 'USB_INTERFACE="setup-test0"' \
    "${CUSTOM_ROOTFS}/etc/openstick/setup-network.conf"
grep -qx 'USB_DEVICE_ADDRESS="192.0.2.1"' \
    "${CUSTOM_ROOTFS}/etc/openstick/setup-network.conf"
grep -qx 'USB_HOST_ADDRESS="192.0.2.2"' \
    "${CUSTOM_ROOTFS}/etc/openstick/setup-network.conf"

ssh-keygen -q -t ed25519 -N '' -f "${ROOTFS}/etc/ssh/ssh_host_ed25519_key"
dd if=/dev/urandom of="${ROOTFS}/etc/machine-id" bs=16 count=1 2>/dev/null
install -d "${ROOTFS}/var/lib/dbus"
cp "${ROOTFS}/etc/machine-id" "${ROOTFS}/var/lib/dbus/machine-id"

"${REPO_ROOT}/scripts/deidentify-rootfs.sh" "${ROOTFS}"
"${REPO_ROOT}/scripts/deidentify-rootfs.sh" "${ROOTFS}"

test ! -e "${ROOTFS}/etc/ssh/ssh_host_ed25519_key"
test ! -e "${ROOTFS}/etc/ssh/ssh_host_ed25519_key.pub"
test ! -s "${ROOTFS}/etc/machine-id"
test "$(readlink "${ROOTFS}/var/lib/dbus/machine-id")" = "/etc/machine-id"

printf 'openstick image configuration tests passed\n'
