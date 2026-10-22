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
GADGET_TEMPLATES="${REPO_ROOT}/configs/templates"
MASS_STORAGE_TEMPLATE="${GADGET_TEMPLATES}/mass.scheme"

if grep -R -n 'file = "/home/' "${GADGET_TEMPLATES}"; then
    echo "gadget template contains an account-specific backing-file path" >&2
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

# Exercise the gadget's configfs writes with the same generated configuration.
# Real configfs creates these attributes when the RNDIS function is created.
assert_rndis_interface() (
    local rootfs=$1
    local expected_interface=$2
    export USB_NETWORK_CONFIG="${rootfs}/etc/openstick/setup-network.conf"
    export CONFIG_FILE=/dev/null
    export CONFIGFS_ROOT="${rootfs}/configfs"

    mkdir -p "${CONFIGFS_ROOT}/usb_gadget/openstick"
    # The status command only reads configuration and the fixture gadget.
    # shellcheck source=scripts/openstick-usb-gadget.sh
    source "${REPO_ROOT}/scripts/openstick-usb-gadget.sh" status >/dev/null
    mkdir -p "${GADGET_PATH}/functions/rndis.usb0/os_desc/interface.rndis" \
        "${GADGET_PATH}/configs/c.1" "${GADGET_PATH}/os_desc"
    add_rndis fixture-serial
    test -L "${GADGET_PATH}/configs/c.1/rndis.usb0"

    # Simulate the kernel registering usb0 on UDC bind and reflecting ip rename.
    printf 'usb0\n' > "${GADGET_PATH}/functions/rndis.usb0/ifname"
    ip() {
        test "$*" = "link set dev usb0 name ${expected_interface}"
        printf '%s\n' "${expected_interface}" > "${GADGET_PATH}/functions/rndis.usb0/ifname"
        printf '%s\n' "$*" > "${rootfs}/ip.log"
    }
    rename_rndis_interface
    test "$(cat "${GADGET_PATH}/functions/rndis.usb0/ifname")" = "${expected_interface}"
    if [ "${expected_interface}" = usb0 ]; then
        test ! -e "${rootfs}/ip.log"
    else
        grep -Fxq "link set dev usb0 name ${expected_interface}" "${rootfs}/ip.log"
    fi

    # Reject a bound interface that does not match the generated network rules.
    printf 'fixture-controller\n' > "${GADGET_PATH}/UDC"
    printf 'wrong0\n' > "${GADGET_PATH}/functions/rndis.usb0/ifname"
    if (validate_bound_gadget fixture-controller) > "${rootfs}/validation.log" 2>&1; then
        echo 'gadget accepted an unexpected RNDIS interface name' >&2
        exit 1
    fi
    grep -Fq "expected ${expected_interface}" "${rootfs}/validation.log"
)
assert_rndis_interface "${ROOTFS}" usb0
assert_rndis_interface "${CUSTOM_ROOTFS}" setup-test0

# Reject names that the kernel cannot use before generating any network rules.
for invalid_interface in . .. this-name-is-too-long; do
    sed "s/USB_INTERFACE=.*/USB_INTERFACE=\"${invalid_interface}\"/" \
        "${CUSTOM_CONFIG}" > "${TEST_ROOT}/invalid-usb.conf"
    if "${REPO_ROOT}/scripts/render-usb-management.sh" \
        "${TEST_ROOT}/invalid-rootfs" "${TEST_ROOT}/invalid-usb.conf" \
        > "${TEST_ROOT}/invalid-usb.log" 2>&1; then
        echo "renderer accepted invalid interface: ${invalid_interface}" >&2
        exit 1
    fi
    test ! -e "${TEST_ROOT}/invalid-rootfs"
done

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
