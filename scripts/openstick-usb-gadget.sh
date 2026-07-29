#!/bin/bash
set -Eeuo pipefail

CONFIG_FILE=${CONFIG_FILE:-/etc/default/openstick-usb-gadget}
CONFIGFS_ROOT=${CONFIGFS_ROOT:-/sys/kernel/config}
UDC_ROOT=${UDC_ROOT:-/sys/class/udc}
GADGET_NAME=${GADGET_NAME:-openstick}
GADGET_PATH="${CONFIGFS_ROOT}/usb_gadget/${GADGET_NAME}"
STATE_DIR=${STATE_DIR:-/var/lib/openstick-usb-gadget}

USB_VENDOR_ID="0x1d6b"
USB_PRODUCT_ID="0x0104"
USB_DEVICE_VERSION="0x0100"
USB_MANUFACTURER="OpenStick"
USB_PRODUCT="OpenStick Development Board"
USB_SERIAL=""
RNDIS_HOST_MAC=""
RNDIS_DEVICE_MAC=""
UMS_IMAGE="${STATE_DIR}/storage.img"
UMS_IMAGE_SIZE_MB=100
UMS_LABEL="OPENSTICK"
UDC_DEVICE=""

log() {
    printf 'openstick-usb-gadget: %s\n' "$*" >&2
}

die() {
    log "error: $*"
    return 1
}

load_config() {
    if [[ -r "${CONFIG_FILE}" ]]; then
        # The file is installed root-owned and contains shell assignments.
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    fi
}

read_or_create_serial() {
    local serial_file="${STATE_DIR}/serial"
    local serial=""

    if [[ -n "${USB_SERIAL}" ]]; then
        printf '%s' "${USB_SERIAL}"
        return
    fi

    if [[ -s "${serial_file}" ]]; then
        serial=$(tr -d '\000\r\n ' < "${serial_file}")
        if [[ -n "${serial}" ]]; then
            printf '%s' "${serial}"
            return
        fi
    fi

    if [[ -s /etc/machine-id ]]; then
        serial=$(tr -d '\000\r\n ' < /etc/machine-id)
    elif [[ -r /proc/device-tree/serial-number ]]; then
        serial=$(tr -d '\000\r\n ' < /proc/device-tree/serial-number)
    fi

    if [[ -z "${serial}" ]]; then
        serial=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    fi

    mkdir -p "${STATE_DIR}"
    umask 077
    printf '%s\n' "${serial}" > "${serial_file}"
    printf '%s' "${serial}"
}

mac_from_seed() {
    local seed=$1
    local digest

    digest=$(printf '%s' "${seed}" | sha256sum)
    digest=${digest%% *}
    printf '02:%s:%s:%s:%s:%s' \
        "${digest:2:2}" "${digest:4:2}" "${digest:6:2}" \
        "${digest:8:2}" "${digest:10:2}"
}

prepare_ums_image() {
    local command_name
    local expected_size
    local image_dir
    local temporary_image

    [[ "${UMS_IMAGE_SIZE_MB}" =~ ^[1-9][0-9]*$ ]] ||
        die "UMS_IMAGE_SIZE_MB must be a positive integer"
    expected_size=$((UMS_IMAGE_SIZE_MB * 1024 * 1024))
    image_dir=$(dirname "${UMS_IMAGE}")
    mkdir -p "${image_dir}"

    for command_name in blkid fsck.exfat stat; do
        command -v "${command_name}" >/dev/null 2>&1 ||
            die "${command_name} is required to validate the UMS image"
    done

    [[ ! -L "${UMS_IMAGE}" ]] ||
        die "refusing symlink as UMS image: ${UMS_IMAGE}"

    if [[ -e "${UMS_IMAGE}" ]]; then
        [[ -f "${UMS_IMAGE}" ]] || die "existing UMS image is not a regular file: ${UMS_IMAGE}"
        if ! validate_ums_image "${UMS_IMAGE}" "${expected_size}"; then
            die "existing UMS image is invalid and was preserved unchanged"
        fi
        return
    fi

    for command_name in mkfs.exfat truncate; do
        command -v "${command_name}" >/dev/null 2>&1 ||
            die "${command_name} is required to create the UMS image"
    done

    temporary_image=$(mktemp "${UMS_IMAGE}.new.XXXXXX")
    umask 077

    if ! truncate -s "${expected_size}" "${temporary_image}" ||
        ! mkfs.exfat -L "${UMS_LABEL}" "${temporary_image}"; then
        rm -f -- "${temporary_image}"
        die "failed to create exFAT UMS image"
    fi

    if ! validate_ums_image "${temporary_image}" "${expected_size}"; then
        rm -f -- "${temporary_image}"
        die "new UMS image failed validation"
    fi

    if [[ -e "${UMS_IMAGE}" || -L "${UMS_IMAGE}" ]]; then
        rm -f -- "${temporary_image}"
        die "UMS image appeared while a new image was being created"
    fi

    if ! chmod 0600 "${temporary_image}" ||
        ! mv -T "${temporary_image}" "${UMS_IMAGE}"; then
        rm -f -- "${temporary_image}"
        die "failed to install UMS image"
    fi

    log "created ${UMS_IMAGE_SIZE_MB} MiB exFAT UMS image at ${UMS_IMAGE}"
}

validate_ums_image() {
    local image=$1
    local expected_size=$2
    local actual_size
    local image_label
    local image_type

    actual_size=$(stat -c '%s' "${image}") ||
        {
            log "error: cannot read UMS image size: ${image}"
            return 1
        }
    if [[ "${actual_size}" != "${expected_size}" ]]; then
        log "error: UMS image size is ${actual_size}; expected ${expected_size}"
        return 1
    fi

    image_type=$(blkid -p -s TYPE -o value "${image}" 2>/dev/null || true)
    if [[ "${image_type}" != "exfat" ]]; then
        log "error: UMS filesystem is '${image_type:-unknown}', expected exfat"
        return 1
    fi

    image_label=$(blkid -p -s LABEL -o value "${image}" 2>/dev/null || true)
    if [[ "${image_label}" != "${UMS_LABEL}" ]]; then
        log "error: UMS label is '${image_label:-none}', expected ${UMS_LABEL}"
        return 1
    fi

    if ! fsck.exfat -n "${image}" >/dev/null; then
        log "error: UMS image failed read-only exFAT validation"
        return 1
    fi

    return 0
}

write_gadget_identity() {
    local serial=$1

    printf '%s\n' "${USB_VENDOR_ID}" > "${GADGET_PATH}/idVendor"
    printf '%s\n' "${USB_PRODUCT_ID}" > "${GADGET_PATH}/idProduct"
    printf '%s\n' "${USB_DEVICE_VERSION}" > "${GADGET_PATH}/bcdDevice"
    printf '0x0200\n' > "${GADGET_PATH}/bcdUSB"
    printf '0xef\n' > "${GADGET_PATH}/bDeviceClass"
    printf '0x02\n' > "${GADGET_PATH}/bDeviceSubClass"
    printf '0x01\n' > "${GADGET_PATH}/bDeviceProtocol"

    mkdir -p "${GADGET_PATH}/strings/0x409"
    printf '%s\n' "${serial}" > "${GADGET_PATH}/strings/0x409/serialnumber"
    printf '%s\n' "${USB_MANUFACTURER}" > "${GADGET_PATH}/strings/0x409/manufacturer"
    printf '%s\n' "${USB_PRODUCT}" > "${GADGET_PATH}/strings/0x409/product"

    mkdir -p "${GADGET_PATH}/configs/c.1/strings/0x409"
    printf 'RNDIS + serial + storage\n' > "${GADGET_PATH}/configs/c.1/strings/0x409/configuration"
    printf '250\n' > "${GADGET_PATH}/configs/c.1/MaxPower"
}

add_rndis() {
    local serial=$1
    local host_mac="${RNDIS_HOST_MAC}"
    local device_mac="${RNDIS_DEVICE_MAC}"
    local function_path="${GADGET_PATH}/functions/rndis.usb0"

    [[ -n "${host_mac}" ]] || host_mac=$(mac_from_seed "${serial}:host")
    [[ -n "${device_mac}" ]] || device_mac=$(mac_from_seed "${serial}:device")
    [[ "${host_mac}" != "${device_mac}" ]] ||
        die "RNDIS host and device MAC addresses must differ"

    mkdir -p "${function_path}"
    printf '%s\n' "${host_mac}" > "${function_path}/host_addr"
    printf '%s\n' "${device_mac}" > "${function_path}/dev_addr"

    printf '1\n' > "${GADGET_PATH}/os_desc/use"
    printf '0xcd\n' > "${GADGET_PATH}/os_desc/b_vendor_code"
    printf 'MSFT100\n' > "${GADGET_PATH}/os_desc/qw_sign"
    printf 'RNDIS\n' > "${function_path}/os_desc/interface.rndis/compatible_id"
    printf '5162001\n' > "${function_path}/os_desc/interface.rndis/sub_compatible_id"
    ln -s "${function_path}" "${GADGET_PATH}/configs/c.1/rndis.usb0"
    ln -s "${GADGET_PATH}/configs/c.1" "${GADGET_PATH}/os_desc/c.1"
}

add_acm() {
    local function_path="${GADGET_PATH}/functions/acm.GS0"

    mkdir -p "${function_path}"
    ln -s "${function_path}" "${GADGET_PATH}/configs/c.1/acm.GS0"
}

add_ums() {
    local function_path="${GADGET_PATH}/functions/mass_storage.0"

    prepare_ums_image
    mkdir -p "${function_path}"
    printf '1\n' > "${function_path}/stall"
    printf '1\n' > "${function_path}/lun.0/removable"
    printf '0\n' > "${function_path}/lun.0/ro"
    printf '0\n' > "${function_path}/lun.0/cdrom"
    printf '0\n' > "${function_path}/lun.0/nofua"
    printf '%s\n' "${UMS_IMAGE}" > "${function_path}/lun.0/file"
    ln -s "${function_path}" "${GADGET_PATH}/configs/c.1/mass_storage.0"
}

choose_udc() {
    local controller="${UDC_DEVICE}"
    local controller_path

    if [[ -n "${controller}" ]]; then
        [[ -d "${UDC_ROOT}/${controller}" ]] ||
            die "configured UDC does not exist: ${controller}"
        printf '%s' "${controller}"
        return
    fi

    for controller_path in "${UDC_ROOT}"/*; do
        [[ -e "${controller_path}" || -L "${controller_path}" ]] || continue
        basename "${controller_path}"
        return
    done

    die "no USB device controller is available"
}

start_gadget() {
    local serial
    local controller

    [[ -d "${CONFIGFS_ROOT}/usb_gadget" ]] ||
        die "USB gadget configfs is not mounted"
    if [[ -d "${GADGET_PATH}" ]]; then
        log "removing existing gadget before reconfiguration"
        stop_gadget || die "existing gadget could not be removed"
    elif [[ -e "${GADGET_PATH}" ]]; then
        die "gadget path exists and is not a directory: ${GADGET_PATH}"
    fi
    serial=$(read_or_create_serial)
    controller=$(choose_udc)

    mkdir "${GADGET_PATH}"
    trap cleanup_failed_start ERR
    write_gadget_identity "${serial}"
    add_rndis "${serial}"
    add_acm
    add_ums
    printf '%s\n' "${controller}" > "${GADGET_PATH}/UDC"
    validate_bound_gadget "${controller}"
    trap - ERR

    log "bound ${GADGET_NAME} to ${controller}"
}

stop_gadget() {
    [[ -d "${GADGET_PATH}" ]] || return 0

    if ! printf '\n' > "${GADGET_PATH}/UDC"; then
        log "error: failed to unbind gadget"
        return 1
    fi
    if [[ -e "${GADGET_PATH}/functions/mass_storage.0/lun.0/file" ]]; then
        if ! printf '\n' > "${GADGET_PATH}/functions/mass_storage.0/lun.0/file"; then
            log "error: failed to detach UMS backing file"
            return 1
        fi
    fi

    local object
    for object in mass_storage.0 acm.GS0 rndis.usb0; do
        remove_config_link "${GADGET_PATH}/configs/c.1/${object}" || return 1
    done
    remove_config_link "${GADGET_PATH}/os_desc/c.1" || return 1

    for object in mass_storage.0 acm.GS0 rndis.usb0; do
        remove_config_directory "${GADGET_PATH}/functions/${object}" || return 1
    done
    remove_config_directory "${GADGET_PATH}/configs/c.1/strings/0x409" || return 1
    remove_config_directory "${GADGET_PATH}/configs/c.1" || return 1
    remove_config_directory "${GADGET_PATH}/strings/0x409" || return 1

    if ! rmdir "${GADGET_PATH}"; then
        log "error: failed to remove gadget; configfs still contains active objects"
        return 1
    fi

    log "removed ${GADGET_NAME}"
}

remove_config_link() {
    local path=$1

    if [[ -L "${path}" ]]; then
        if ! rm -f -- "${path}"; then
            log "error: failed to remove configfs link ${path}"
            return 1
        fi
    elif [[ -e "${path}" ]]; then
        log "error: expected a symlink at ${path}"
        return 1
    fi
}

remove_config_directory() {
    local path=$1

    [[ -d "${path}" ]] || return 0
    if ! rmdir "${path}"; then
        log "error: failed to remove configfs directory ${path}"
        return 1
    fi
}

validate_bound_gadget() {
    local controller=$1
    local attempt
    local rndis_interface

    [[ "$(< "${GADGET_PATH}/UDC")" == "${controller}" ]] ||
        die "UDC binding did not persist"

    [[ -L "${GADGET_PATH}/configs/c.1/rndis.usb0" ]] ||
        die "RNDIS function is not linked"
    rndis_interface=$(< "${GADGET_PATH}/functions/rndis.usb0/ifname")
    [[ "${rndis_interface}" == "usb0" ]] ||
        die "RNDIS interface is ${rndis_interface:-missing}, expected usb0"

    [[ -L "${GADGET_PATH}/configs/c.1/acm.GS0" ]] ||
        die "ACM function is not linked"
    attempt=0
    while [[ "${attempt}" -lt 30 ]]; do
        [[ -c /dev/ttyGS0 ]] && break
        sleep 0.1
        attempt=$((attempt + 1))
    done
    [[ -c /dev/ttyGS0 ]] || die "ACM device /dev/ttyGS0 did not appear"

    [[ -L "${GADGET_PATH}/configs/c.1/mass_storage.0" ]] ||
        die "UMS function is not linked"
    [[ "$(< "${GADGET_PATH}/functions/mass_storage.0/lun.0/file")" == "${UMS_IMAGE}" ]] ||
        die "UMS backing file does not match the configured image"
    [[ "$(< "${GADGET_PATH}/functions/mass_storage.0/lun.0/ro")" == "0" ]] ||
        die "UMS backing file unexpectedly became read-only"
}

cleanup_failed_start() {
    local status=$?

    trap - ERR
    log "start failed; removing partially configured gadget"
    stop_gadget || true
    exit "${status}"
}

acquire_lock() {
    install -d -m 0700 "${STATE_DIR}"
    exec 9> "${STATE_DIR}/gadget.lock"
    /usr/bin/flock 9
}

show_status() {
    if [[ -d "${GADGET_PATH}" ]]; then
        printf 'configured'
        if [[ -r "${GADGET_PATH}/UDC" ]] && [[ -n "$(< "${GADGET_PATH}/UDC")" ]]; then
            printf ' and bound to %s' "$(< "${GADGET_PATH}/UDC")"
        fi
        printf '\n'
    else
        printf 'not configured\n'
        return 3
    fi
}

load_config

case "${1:-}" in
    start|stop|restart)
        acquire_lock
        ;;
esac

case "${1:-}" in
    start)
        start_gadget
        ;;
    stop)
        stop_gadget
        ;;
    restart)
        stop_gadget
        start_gadget
        ;;
    status)
        show_status
        ;;
    *)
        printf 'Usage: %s {start|stop|restart|status}\n' "$0" >&2
        exit 2
        ;;
esac
