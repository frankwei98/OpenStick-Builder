#!/bin/sh

# The OPENSTICK_PROFILE_* variables are outputs consumed by scripts that source
# this library.
# shellcheck disable=SC2034

: "${OPENSTICK_BOARD_PROFILES:=/usr/local/share/openstick/board-profiles}"

openstick_profile_load() {
    openstick_requested_profile=$1
    OPENSTICK_PROFILE_ID=
    OPENSTICK_PROFILE_DTB=
    OPENSTICK_PROFILE_COMPATIBLE=
    OPENSTICK_PROFILE_LABEL=

    if [ ! -r "${OPENSTICK_BOARD_PROFILES}" ]; then
        printf 'Board profile database is not readable: %s\n' \
            "${OPENSTICK_BOARD_PROFILES}" >&2
        return 1
    fi

    while IFS='|' read -r openstick_profile_id openstick_profile_dtb \
        openstick_profile_compatible openstick_profile_label; do
        case "${openstick_profile_id}" in
            ""|\#*) continue ;;
        esac

        if [ "${openstick_profile_id}" = "${openstick_requested_profile}" ]; then
            OPENSTICK_PROFILE_ID=${openstick_profile_id}
            OPENSTICK_PROFILE_DTB=${openstick_profile_dtb}
            OPENSTICK_PROFILE_COMPATIBLE=${openstick_profile_compatible}
            OPENSTICK_PROFILE_LABEL=${openstick_profile_label}
            return 0
        fi
    done < "${OPENSTICK_BOARD_PROFILES}"

    printf 'Unknown OpenStick board profile: %s\n' \
        "${openstick_requested_profile}" >&2
    return 1
}

openstick_build_profile_load() {
    openstick_requested_build_profile=${1:-generic}
    case "${openstick_requested_build_profile}" in
        generic)
            # A generic image needs a real DTB/compatible to reach userspace.
            # UZ801 is the historical fallback and also boots UFI003 far enough
            # for the user to select the correct profile after flashing.
            openstick_profile_load uz801 || return 1
            OPENSTICK_BUILD_PROFILE=generic
            ;;
        *)
            openstick_profile_load "${openstick_requested_build_profile}" ||
                return 1
            OPENSTICK_BUILD_PROFILE=${OPENSTICK_PROFILE_ID}
            ;;
    esac
}

openstick_profile_list() {
    while IFS='|' read -r openstick_profile_id openstick_profile_dtb \
        openstick_profile_compatible openstick_profile_label; do
        case "${openstick_profile_id}" in
            ""|\#*) continue ;;
        esac
        printf '%-10s %s (%s)\n' \
            "${openstick_profile_id}" \
            "${openstick_profile_label}" \
            "${openstick_profile_dtb}"
    done < "${OPENSTICK_BOARD_PROFILES}"
}
