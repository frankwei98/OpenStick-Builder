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
grep -qx 'PermitRootLogin prohibit-password' "${SSH_CONFIG}"
grep -qx 'Match User root Address 172.30.255.2 LocalAddress 172.30.255.1' "${SSH_CONFIG}"

if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -q -t ed25519 -N '' -f "${TEST_ROOT}/host-key"
    {
        printf 'HostKey %s\n' "${TEST_ROOT}/host-key"
        cat "${SSH_CONFIG}"
    } > "${TEST_ROOT}/sshd_config"

    usb_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=root,addr=172.30.255.2,laddr=172.30.255.1,lport=22)
    wifi_source_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=root,addr=192.168.4.2,laddr=172.30.255.1,lport=22)
    wifi_target_policy=$(sshd -T -f "${TEST_ROOT}/sshd_config" \
        -C user=root,addr=192.168.4.2,laddr=192.168.4.1,lport=22)

    grep -qx 'permitrootlogin yes' <<< "${usb_policy}"
    grep -qx 'permitemptypasswords no' <<< "${usb_policy}"
    grep -qx 'permitrootlogin prohibit-password' <<< "${wifi_source_policy}"
    grep -qx 'permitrootlogin prohibit-password' <<< "${wifi_target_policy}"
fi

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
