# shellcheck shell=sh

case $- in
    *i*)
        openstick_status_command=${OPENSTICK_STATUS_COMMAND:-/usr/local/sbin/openstick-board}
        if [ -x "${openstick_status_command}" ]; then
            timeout 8 "${openstick_status_command}" status ||
                printf '[OpenStick] Status unavailable\n'
        fi
        unset openstick_status_command
        ;;
esac
