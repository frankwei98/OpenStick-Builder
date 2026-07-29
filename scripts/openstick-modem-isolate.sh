#!/bin/bash
set -Eeuo pipefail

CONFIG_FILE=${CONFIG_FILE:-/etc/default/openstick-modem-isolation}
SYS_CLASS_NET=${SYS_CLASS_NET:-/sys/class/net}
IP_COMMAND=${IP_COMMAND:-/usr/sbin/ip}
FLOCK_COMMAND=${FLOCK_COMMAND:-/usr/bin/flock}
RUN_DIR=${RUN_DIR:-/run/openstick-modem-isolation}

ENABLED=0
DRIVER="bam-dmux"
PRIMARY_DEV_PORTS="0"
AUXILIARY_DEV_PORTS="1 2 3 4 5 6 7"
NAMESPACE="openstick-modem-aux"
EVENT_INTERFACE=""

log() {
    printf 'openstick-modem-isolate: %s\n' "$*" >&2
}

die() {
    log "error: $*"
    exit 1
}

contains_port() {
    local port=$1
    local ports=$2

    [[ " ${ports} " == *" ${port} "* ]]
}

validate_port_list() {
    local name=$1
    local ports=$2
    local port

    for port in ${ports}; do
        [[ "${port}" =~ ^[0-9]+$ ]] ||
            die "${name} contains a non-numeric dev_port: ${port}"
    done
}

load_config() {
    if [[ -r "${CONFIG_FILE}" ]]; then
        # The file is installed root-owned and contains shell assignments.
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    fi

    [[ "${ENABLED}" == "0" || "${ENABLED}" == "1" ]] ||
        die "ENABLED must be 0 or 1"
    [[ "${DRIVER}" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
        die "DRIVER contains invalid characters"
    [[ "${NAMESPACE}" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
        die "NAMESPACE contains invalid characters"
    validate_port_list PRIMARY_DEV_PORTS "${PRIMARY_DEV_PORTS}"
    validate_port_list AUXILIARY_DEV_PORTS "${AUXILIARY_DEV_PORTS}"

    local port
    for port in ${PRIMARY_DEV_PORTS}; do
        contains_port "${port}" "${AUXILIARY_DEV_PORTS}" &&
            die "dev_port ${port} is both primary and auxiliary"
    done

    return 0
}

parse_arguments() {
    case "${1:-}" in
        "")
            ;;
        --event-interface)
            [[ $# -eq 2 ]] || die "--event-interface requires one value"
            EVENT_INTERFACE=$2
            ;;
        *)
            die "Usage: $0 [--event-interface INTERFACE]"
            ;;
    esac
}

interface_dev_port() {
    local net_path=$1
    local driver_target
    local dev_port

    [[ -L "${net_path}/device/driver" ]] || return 1
    driver_target=$(readlink "${net_path}/device/driver")
    [[ "${driver_target##*/}" == "${DRIVER}" ]] || return 1
    [[ -r "${net_path}/dev_port" ]] || return 1
    read -r dev_port < "${net_path}/dev_port"
    [[ "${dev_port}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${dev_port}"
}

interface_is_protected() {
    local interface=$1
    local routes
    local addresses

    routes=$("${IP_COMMAND}" route show default dev "${interface}" 2>/dev/null || true)
    if [[ -n "${routes}" ]]; then
        log "keeping ${interface}: it carries a default route"
        return 0
    fi

    addresses=$("${IP_COMMAND}" -o address show dev "${interface}" scope global 2>/dev/null || true)
    if [[ -n "${addresses}" ]]; then
        log "keeping ${interface}: it has a global address"
        return 0
    fi

    return 1
}

namespace_exists() {
    local listing
    local line

    listing=$("${IP_COMMAND}" netns list 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ "${line%% *}" == "${NAMESPACE}" ]] && return 0
    done <<< "${listing}"
    return 1
}

isolate_interfaces() {
    local net_path
    local interface
    local dev_port
    local primary_found=0
    local failures=0
    local moved=0
    local -a auxiliary_interfaces=()

    [[ -d "${SYS_CLASS_NET}" ]] || {
        log "network sysfs is unavailable; skipping"
        return 0
    }

    for net_path in "${SYS_CLASS_NET}"/*; do
        [[ -e "${net_path}" || -L "${net_path}" ]] || continue
        dev_port=$(interface_dev_port "${net_path}" 2>/dev/null) || continue
        if contains_port "${dev_port}" "${PRIMARY_DEV_PORTS}"; then
            primary_found=1
            log "found primary channel ${net_path##*/} (dev_port ${dev_port})"
        fi
    done

    if [[ "${primary_found}" != "1" ]]; then
        log "no primary ${DRIVER} channel is present; moving nothing"
        return 0
    fi

    for net_path in "${SYS_CLASS_NET}"/*; do
        [[ -e "${net_path}" || -L "${net_path}" ]] || continue
        interface=${net_path##*/}
        dev_port=$(interface_dev_port "${net_path}" 2>/dev/null) || continue

        contains_port "${dev_port}" "${AUXILIARY_DEV_PORTS}" || continue
        if interface_is_protected "${interface}"; then
            continue
        fi

        auxiliary_interfaces+=("${interface}:${dev_port}")
    done

    if [[ ${#auxiliary_interfaces[@]} -eq 0 ]]; then
        log "no eligible auxiliary channels are present"
        return 0
    fi

    if ! namespace_exists; then
        if ! "${IP_COMMAND}" netns add "${NAMESPACE}"; then
            log "error: failed to create namespace ${NAMESPACE}"
            return 1
        fi
        log "created namespace ${NAMESPACE}"
    fi

    local entry
    for entry in "${auxiliary_interfaces[@]}"; do
        interface=${entry%%:*}
        dev_port=${entry##*:}

        if ! "${IP_COMMAND}" link set dev "${interface}" netns "${NAMESPACE}"; then
            log "warning: failed to move ${interface} (dev_port ${dev_port})"
            failures=$((failures + 1))
            continue
        fi

        if ! "${IP_COMMAND}" -n "${NAMESPACE}" link set dev "${interface}" down; then
            log "warning: moved ${interface}, but could not set it down"
            failures=$((failures + 1))
        fi

        moved=$((moved + 1))
        log "moved ${interface} (dev_port ${dev_port}) to ${NAMESPACE}"
    done

    log "completed: moved=${moved} failures=${failures}"
    [[ "${failures}" -eq 0 ]]
}

parse_arguments "$@"
load_config

if [[ "${ENABLED}" != "1" ]]; then
    log "disabled"
    exit 0
fi

if [[ -n "${EVENT_INTERFACE}" ]]; then
    log "handling netdev event for ${EVENT_INTERFACE}"
fi

install -d -m 0755 "${RUN_DIR}"
exec 9> "${RUN_DIR}/isolation.lock"
"${FLOCK_COMMAND}" 9

isolate_interfaces
