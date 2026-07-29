#!/bin/bash
set -Eeuo pipefail

CONFIG_FILE=${CONFIG_FILE:-/etc/default/openstick-modem-isolation}
SYS_CLASS_NET=${SYS_CLASS_NET:-/sys/class/net}
IP_COMMAND=${IP_COMMAND:-/usr/sbin/ip}
NMCLI_COMMAND=${NMCLI_COMMAND:-/usr/bin/nmcli}
FLOCK_COMMAND=${FLOCK_COMMAND:-/usr/bin/flock}
REALPATH_COMMAND=${REALPATH_COMMAND:-realpath}
RUN_DIR=${RUN_DIR:-/run/openstick-modem-isolation}

ENABLED=0
PRIMARY_DEV_PORTS="0"
AUXILIARY_DEV_PORTS="1 2 3 4 5 6 7"
NAMESPACE="openstick-modem-aux"
EVENT_INTERFACE=""
SUPPORTED_DRIVER="bam-dmux"

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

contains_value() {
    local needle=$1
    local value

    shift
    for value in "$@"; do
        [[ "${value}" == "${needle}" ]] && return 0
    done
    return 1
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
    [[ "${driver_target##*/}" == "${SUPPORTED_DRIVER}" ]] || return 1
    [[ -r "${net_path}/dev_port" ]] || return 1
    read -r dev_port < "${net_path}/dev_port"
    [[ "${dev_port}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${dev_port}"
}

interface_parent() {
    local net_path=$1
    local parent

    parent=$("${REALPATH_COMMAND}" "${net_path}/device" 2>/dev/null) || return 1
    [[ -n "${parent}" ]] || return 1
    printf '%s' "${parent}"
}

interface_is_protected() {
    local interface=$1
    local nm_state
    local routes
    local addresses
    local route

    routes=$("${IP_COMMAND}" -4 route show table all dev "${interface}" 2>/dev/null || true)
    if [[ -n "${routes}" ]]; then
        log "keeping ${interface}: it carries an IPv4 route"
        return 0
    fi

    routes=$("${IP_COMMAND}" -6 route show table all dev "${interface}" 2>/dev/null || true)
    while IFS= read -r route; do
        [[ -n "${route}" ]] || continue
        case "${route%% *}" in
            fe80::*|ff00::*)
                continue
                ;;
        esac
        log "keeping ${interface}: it carries an IPv6 route"
        return 0
    done <<< "${routes}"

    addresses=$("${IP_COMMAND}" -o address show dev "${interface}" scope global 2>/dev/null || true)
    if [[ -n "${addresses}" ]]; then
        log "keeping ${interface}: it has a global address"
        return 0
    fi

    nm_state=$("${NMCLI_COMMAND}" -g GENERAL.STATE device show "${interface}" 2>/dev/null || true)
    case "${nm_state}" in
        100|100\ *|*\(connected\)*)
            log "keeping ${interface}: NetworkManager reports it connected"
            return 0
            ;;
    esac

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
    local parent
    local current_dev_port
    local current_parent
    local event_dev_port=""
    local event_parent=""
    local failures=0
    local moved=0
    local namespace_ready=0
    local record
    local -a interface_records=()
    local -a auxiliary_records=()
    local -a primary_parents=()

    [[ -d "${SYS_CLASS_NET}" ]] || {
        log "network sysfs is unavailable; skipping"
        return 0
    }

    for net_path in "${SYS_CLASS_NET}"/*; do
        [[ -e "${net_path}" || -L "${net_path}" ]] || continue
        dev_port=$(interface_dev_port "${net_path}" 2>/dev/null) || continue
        parent=$(interface_parent "${net_path}" 2>/dev/null) || continue
        interface=${net_path##*/}
        interface_records+=("${interface}"$'\t'"${dev_port}"$'\t'"${parent}")
        if contains_port "${dev_port}" "${PRIMARY_DEV_PORTS}"; then
            if [[ ${#primary_parents[@]} -eq 0 ]] ||
                ! contains_value "${parent}" "${primary_parents[@]}"; then
                primary_parents+=("${parent}")
            fi
            log "found primary channel ${interface} (dev_port ${dev_port})"
        fi
    done

    if [[ ${#primary_parents[@]} -eq 0 ]]; then
        log "no primary ${SUPPORTED_DRIVER} channel is present; moving nothing"
        return 0
    fi

    if [[ -n "${EVENT_INTERFACE}" ]]; then
        for record in "${interface_records[@]}"; do
            IFS=$'\t' read -r interface dev_port parent <<< "${record}"
            [[ "${interface}" == "${EVENT_INTERFACE}" ]] || continue
            event_dev_port=${dev_port}
            event_parent=${parent}
            break
        done
        if [[ -z "${event_parent}" ]]; then
            log "event interface is no longer an eligible ${SUPPORTED_DRIVER} channel"
            return 0
        fi
    fi

    for record in "${interface_records[@]}"; do
        IFS=$'\t' read -r interface dev_port parent <<< "${record}"
        contains_port "${dev_port}" "${AUXILIARY_DEV_PORTS}" || continue
        contains_value "${parent}" "${primary_parents[@]}" || {
            log "keeping ${interface}: its physical modem has no primary channel"
            continue
        }

        if [[ -n "${EVENT_INTERFACE}" ]]; then
            if contains_port "${event_dev_port}" "${AUXILIARY_DEV_PORTS}"; then
                [[ "${interface}" == "${EVENT_INTERFACE}" ]] || continue
            elif contains_port "${event_dev_port}" "${PRIMARY_DEV_PORTS}"; then
                [[ "${parent}" == "${event_parent}" ]] || continue
            else
                return 0
            fi
        fi

        if interface_is_protected "${interface}"; then
            continue
        fi

        auxiliary_records+=("${record}")
    done

    if [[ ${#auxiliary_records[@]} -eq 0 ]]; then
        log "no eligible auxiliary channels are present"
        return 0
    fi

    for record in "${auxiliary_records[@]}"; do
        IFS=$'\t' read -r interface dev_port parent <<< "${record}"

        current_dev_port=$(interface_dev_port "${SYS_CLASS_NET}/${interface}" 2>/dev/null) || {
            log "keeping ${interface}: it disappeared before isolation"
            continue
        }
        current_parent=$(interface_parent "${SYS_CLASS_NET}/${interface}" 2>/dev/null) || {
            log "keeping ${interface}: its physical parent became ambiguous"
            continue
        }
        if [[ "${current_dev_port}" != "${dev_port}" || "${current_parent}" != "${parent}" ]]; then
            log "keeping ${interface}: its hardware identity changed"
            continue
        fi
        if interface_is_protected "${interface}"; then
            continue
        fi

        if [[ "${namespace_ready}" != "1" ]]; then
            if ! namespace_exists; then
                if ! "${IP_COMMAND}" netns add "${NAMESPACE}"; then
                    log "error: failed to create namespace ${NAMESPACE}"
                    return 1
                fi
                log "created namespace ${NAMESPACE}"
            fi
            namespace_ready=1
        fi

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
