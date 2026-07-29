#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-modem-test.XXXXXX")
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

SYSFS_ROOT="${TEST_ROOT}/sys/class/net"
DRIVER_ROOT="${TEST_ROOT}/drivers"
DEVICE_ROOT="${TEST_ROOT}/devices"
RUN_ROOT="${TEST_ROOT}/run"
IP_LOG="${TEST_ROOT}/ip.log"
IP_STATE="${TEST_ROOT}/namespace-created"
CONFIG_FILE_PATH="${TEST_ROOT}/modem.conf"
IP_STUB="${TEST_ROOT}/ip"

install -d \
    "${SYSFS_ROOT}" \
    "${DRIVER_ROOT}/bam-dmux" \
    "${DRIVER_ROOT}/other" \
    "${DEVICE_ROOT}"

cat > "${IP_STUB}" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${IP_LOG}"

case "$*" in
    "-4 route show table all dev channel-route")
        printf '198.51.100.0/24 dev channel-route table 100\n'
        ;;
    "-6 route show table all dev channel-v6")
        printf '2001:db8::/64 dev channel-v6\n'
        ;;
    "-4 route show table all dev channel-race")
        count=0
        if [ -r "${TEST_ROOT}/race-count" ]; then
            read -r count < "${TEST_ROOT}/race-count"
        fi
        count=$((count + 1))
        printf '%s\n' "${count}" > "${TEST_ROOT}/race-count"
        if [ "${count}" -ge 2 ]; then
            printf '203.0.113.0/24 dev channel-race\n'
        fi
        ;;
    "-o address show dev channel-address scope global")
        printf '1: channel-address inet 192.0.2.2/24 scope global\n'
        ;;
    "netns list")
        if [ -e "${IP_STATE}" ]; then
            printf 'openstick-modem-aux\n'
        fi
        ;;
    "netns add openstick-modem-aux")
        install -m 0644 /dev/null "${IP_STATE}"
        ;;
    "link set dev channel-fail netns openstick-modem-aux")
        exit 1
        ;;
    "link set dev "*" netns openstick-modem-aux")
        interface=$4
        rm -r "${SYS_CLASS_NET}/${interface}"
        ;;
esac
EOF
chmod 0755 "${IP_STUB}"

add_interface() {
    local interface=$1
    local dev_port=$2
    local driver=${3:-bam-dmux}
    local parent=${4:-modem-a}

    install -d "${SYSFS_ROOT}/${interface}" "${DEVICE_ROOT}/${parent}"
    if [ ! -e "${DEVICE_ROOT}/${parent}/driver" ]; then
        ln -s "${DRIVER_ROOT}/${driver}" "${DEVICE_ROOT}/${parent}/driver"
    fi
    ln -s "${DEVICE_ROOT}/${parent}" "${SYSFS_ROOT}/${interface}/device"
    printf '%s\n' "${dev_port}" > "${SYSFS_ROOT}/${interface}/dev_port"
}

write_config() {
    local enabled=$1

    cat > "${CONFIG_FILE_PATH}" << EOF
ENABLED=${enabled}
PRIMARY_DEV_PORTS="0"
AUXILIARY_DEV_PORTS="1 2 3 4 5 6 7"
NAMESPACE="openstick-modem-aux"
EOF
}

run_isolator() {
    CONFIG_FILE="${CONFIG_FILE_PATH}" \
    SYS_CLASS_NET="${SYSFS_ROOT}" \
    IP_COMMAND="${IP_STUB}" \
    NMCLI_COMMAND="/usr/bin/false" \
    FLOCK_COMMAND="/usr/bin/true" \
    REALPATH_COMMAND="/bin/realpath" \
    IP_LOG="${IP_LOG}" \
    IP_STATE="${IP_STATE}" \
    TEST_ROOT="${TEST_ROOT}" \
    RUN_DIR="${RUN_ROOT}" \
        "${REPO_ROOT}/scripts/openstick-modem-isolate.sh" "$@"
}

assert_not_logged() {
    local pattern=$1

    if grep -q "${pattern}" "${IP_LOG}"; then
        echo "unexpected ip command matching: ${pattern}" >&2
        exit 1
    fi
}

write_config 0
run_isolator
test ! -s "${IP_LOG}"

write_config 1
add_interface arbitrary-primary-name 0
add_interface channel-ok 1
add_interface channel-route 2
add_interface channel-address 3
add_interface channel-other-driver 4 other modem-other
add_interface channel-v6 5
add_interface channel-race 6
add_interface other-modem-aux 1 bam-dmux modem-b

run_isolator
grep -q '^netns add openstick-modem-aux$' "${IP_LOG}"
grep -q '^link set dev channel-ok netns openstick-modem-aux$' "${IP_LOG}"
assert_not_logged 'link set dev arbitrary-primary-name netns'
assert_not_logged 'link set dev channel-route netns'
assert_not_logged 'link set dev channel-address netns'
assert_not_logged 'link set dev channel-other-driver netns'
assert_not_logged 'link set dev channel-v6 netns'
assert_not_logged 'link set dev channel-race netns'
assert_not_logged 'link set dev other-modem-aux netns'
test ! -e "${SYSFS_ROOT}/channel-ok"

# A failed move is reported, but later eligible channels are still processed.
: > "${IP_LOG}"
add_interface channel-fail 4
add_interface channel-success-after-failure 7
if run_isolator; then
    echo "expected an individual move failure" >&2
    exit 1
fi
grep -q '^link set dev channel-fail netns openstick-modem-aux$' "${IP_LOG}"
grep -q '^link set dev channel-success-after-failure netns openstick-modem-aux$' "${IP_LOG}"
test ! -e "${SYSFS_ROOT}/channel-success-after-failure"

# A primary-channel event is scoped to auxiliary links on the same modem.
: > "${IP_LOG}"
add_interface event-primary 0 bam-dmux modem-c
add_interface event-auxiliary 1 bam-dmux modem-c
add_interface unrelated-new-auxiliary 2 bam-dmux modem-a
run_isolator --event-interface event-primary
grep -q '^link set dev event-auxiliary netns openstick-modem-aux$' "${IP_LOG}"
assert_not_logged 'link set dev unrelated-new-auxiliary netns'
assert_not_logged 'link set dev channel-fail netns'

# Without the primary dev_port, fail closed and do not move an auxiliary link.
: > "${IP_LOG}"
rm -r "${SYSFS_ROOT}/arbitrary-primary-name"
rm -r "${SYSFS_ROOT}/event-primary"
add_interface late-auxiliary 6
run_isolator
assert_not_logged 'link set dev late-auxiliary netns'

printf 'openstick modem isolation tests passed\n'
