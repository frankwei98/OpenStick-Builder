#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-board-test.XXXXXX")
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

ROOTFS="${TEST_ROOT}/rootfs"
EXTLINUX_CONFIG="${ROOTFS}/boot/extlinux/extlinux.conf"
MMCLI_STUB="${TEST_ROOT}/mmcli"
NMCLI_STUB="${TEST_ROOT}/nmcli"
MMCLI_LOG="${TEST_ROOT}/mmcli.log"

if ! grep -qx 'fdt /dtbs/qcom/msm8916-yiming-uz801v3.dtb' \
    "${REPO_ROOT}/configs/extlinux.conf"; then
    echo "generic image lost its bootable UZ801 fallback DTB" >&2
    exit 1
fi
if grep -q '@OPENSTICK_DTB@' "${REPO_ROOT}/configs/extlinux.conf"; then
    echo "generic image contains an unbootable DTB placeholder" >&2
    exit 1
fi

OPENSTICK_BOARD_PROFILES="${REPO_ROOT}/configs/openstick-board-profiles"
export OPENSTICK_BOARD_PROFILES
# shellcheck disable=SC1091
. "${REPO_ROOT}/scripts/openstick-board-profile.sh"
openstick_build_profile_load generic
test "${OPENSTICK_BUILD_PROFILE}" = generic
test "${OPENSTICK_PROFILE_ID}" = uz801
test "${OPENSTICK_PROFILE_COMPATIBLE}" = 'yiming,uz801-v3'
openstick_profile_load ufi003
test "${OPENSTICK_PROFILE_COMPATIBLE}" = 'thwc,ufi001c'
openstick_profile_load uz801
test "${OPENSTICK_PROFILE_COMPATIBLE}" = 'yiming,uz801-v3'

install -d \
    "${ROOTFS}/boot/extlinux" \
    "${ROOTFS}/boot/dtbs/qcom" \
    "${ROOTFS}/etc" \
    "${ROOTFS}/proc/device-tree"
cp "${REPO_ROOT}/configs/extlinux.conf" "${EXTLINUX_CONFIG}"
touch \
    "${ROOTFS}/boot/dtbs/qcom/msm8916-thwc-ufi001c.dtb" \
    "${ROOTFS}/boot/dtbs/qcom/msm8916-yiming-uz801v3.dtb"

cat > "${MMCLI_STUB}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MMCLI_LOG}"

case "$*" in
    "-L")
        printf '    /org/freedesktop/ModemManager1/Modem/7 [test] modem\n'
        ;;
    "-m 7 --output-keyvalue")
        cat <<'OUTPUT'
modem.generic.state                             : registered
modem.generic.access-technologies.length        : 1
modem.generic.access-technologies.value[1]      : lte
modem.generic.signal-quality.value              : 59
modem.generic.signal-quality.recent             : yes
modem.3gpp.registration-state                   : roaming
modem.generic.sim                               : /org/freedesktop/ModemManager1/SIM/7
OUTPUT
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod 0755 "${MMCLI_STUB}"

cat > "${NMCLI_STUB}" <<'EOF'
#!/bin/sh
case "$*" in
    "-t -f TYPE connection show --active")
        printf '802-11-wireless\n'
        ;;
    "-t -f DEVICE,TYPE,STATE device status")
        printf 'wlan0:wifi:connected\n'
        ;;
    "-g IP4.ADDRESS device show wlan0")
        printf '192.168.29.203/22\n'
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod 0755 "${NMCLI_STUB}"

run_board() {
    OPENSTICK_ROOT="${ROOTFS}" \
    OPENSTICK_BOARD_LIB="${REPO_ROOT}/scripts/openstick-board-profile.sh" \
    OPENSTICK_BOARD_PROFILES="${REPO_ROOT}/configs/openstick-board-profiles" \
    OPENSTICK_MMCLI="${MMCLI_STUB}" \
    OPENSTICK_NMCLI="${NMCLI_STUB}" \
    MMCLI_LOG="${MMCLI_LOG}" \
        "${REPO_ROOT}/scripts/openstick-board" "$@"
}

printf 'yiming,uz801-v3\0qcom,msm8916\0' \
    > "${ROOTFS}/proc/device-tree/compatible"
generic_status=$(run_board status)
grep -Fqx 'Board profile : UNCONFIGURED' <<< "${generic_status}"
grep -Fqx \
    'Warning       : select ufi003 or uz801, then reboot if requested' \
    <<< "${generic_status}"
test ! -e "${ROOTFS}/etc/openstick-board"

run_board initialize ufi003
grep -qx 'fdt /dtbs/qcom/msm8916-thwc-ufi001c.dtb' \
    "${EXTLINUX_CONFIG}"
grep -qx 'ufi003' "${ROOTFS}/etc/openstick-board"

run_board select uz801 >/dev/null
grep -qx 'fdt /dtbs/qcom/msm8916-yiming-uz801v3.dtb' \
    "${EXTLINUX_CONFIG}"
grep -qx 'uz801' "${ROOTFS}/etc/openstick-board"

run_board rollback >/dev/null
grep -qx 'fdt /dtbs/qcom/msm8916-thwc-ufi001c.dtb' \
    "${EXTLINUX_CONFIG}"
grep -qx 'ufi003' "${ROOTFS}/etc/openstick-board"

cp "${EXTLINUX_CONFIG}" "${EXTLINUX_CONFIG}.before-ufi-sim"
sed -i.bak \
    's/msm8916-thwc-ufi001c.dtb/msm8916-yiming-uz801v3.dtb/' \
    "${EXTLINUX_CONFIG}.before-ufi-sim"
rm -f \
    "${EXTLINUX_CONFIG}.before-ufi-sim.bak" \
    "${EXTLINUX_CONFIG}.openstick-board-backup" \
    "${ROOTFS}/etc/openstick-board.openstick-board-backup" \
    "${ROOTFS}/etc/openstick-board.openstick-board-backup.missing"
run_board rollback >/dev/null
grep -qx 'fdt /dtbs/qcom/msm8916-yiming-uz801v3.dtb' \
    "${EXTLINUX_CONFIG}"
test ! -e "${ROOTFS}/etc/openstick-board"
run_board initialize ufi003 >/dev/null

if run_board select unknown-board 2>/dev/null; then
    echo "unknown board profile was accepted" >&2
    exit 1
fi
grep -qx 'fdt /dtbs/qcom/msm8916-thwc-ufi001c.dtb' \
    "${EXTLINUX_CONFIG}"

printf 'thwc,ufi001c\0qcom,msm8916\0' \
    > "${ROOTFS}/proc/device-tree/compatible"

status=$(run_board status)
grep -Fqx '[OpenStick]' <<< "${status}"
grep -Fqx 'Board profile : UFI003' <<< "${status}"
grep -Fqx 'DTB           : msm8916-thwc-ufi001c.dtb' <<< "${status}"
grep -Fqx 'SIM           : present' <<< "${status}"
grep -Fqx 'Network       : registered / LTE / signal 59%' <<< "${status}"
grep -Fqx 'Cellular data : disabled' <<< "${status}"
grep -Fqx 'Wi-Fi         : connected / 192.168.29.203' <<< "${status}"
grep -qx -- '-m 7 --output-keyvalue' "${MMCLI_LOG}"

sim_status=$(run_board sim-status)
grep -Fqx 'Modem         : 7' <<< "${sim_status}"
grep -Fqx 'SIM           : present' <<< "${sim_status}"
grep -Fqx 'Registration  : registered' <<< "${sim_status}"

PROFILE_SCRIPT="${REPO_ROOT}/configs/profile.d/openstick-status.sh"
noninteractive_output=$(
    OPENSTICK_STATUS_COMMAND=/bin/echo \
        /bin/sh -c '. "$1"' sh "${PROFILE_SCRIPT}"
)
test -z "${noninteractive_output}"

interactive_output=$(
    OPENSTICK_STATUS_COMMAND=/bin/echo \
        /bin/bash --noprofile --norc -ic '. "$1"' bash "${PROFILE_SCRIPT}" \
        2>/dev/null
)
test -n "${interactive_output}"

printf 'openstick board tests passed\n'
