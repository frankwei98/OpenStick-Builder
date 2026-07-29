#!/bin/bash
set -Eeuo pipefail

CONFIG_FILE=${CONFIG_FILE:-/etc/default/openstick-usb-gadget}
CONFIGFS_ROOT=${CONFIGFS_ROOT:-/sys/kernel/config}
UDC_ROOT=${UDC_ROOT:-/sys/class/udc}
GADGET_NAME=${GADGET_NAME:-openstick}
GADGET_PATH="${CONFIGFS_ROOT}/usb_gadget/${GADGET_NAME}"
STATE_DIR=${STATE_DIR:-/var/lib/openstick-usb-gadget}

ENABLE_RNDIS=1
ENABLE_ACM=1
ENABLE_UMS=1
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
UMS_READONLY=0
UDC_DEVICE=""

log() {
    printf 'openstick-usb-gadget: %s\n' "$*" >&2
}

die() {
    log "error: $*"
    exit 1
}

validate_boolean() {
    local name=$1
    local value=$2

    [[ "${value}" == "0" || "${value}" == "1" ]] ||
        die "${name} must be 0 or 1"
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
    local image_dir
    local image_type
    local temporary_image

    [[ "${UMS_IMAGE_SIZE_MB}" =~ ^[1-9][0-9]*$ ]] ||
        die "UMS_IMAGE_SIZE_MB must be a positive integer"
    [[ "${UMS_READONLY}" == "0" || "${UMS_READONLY}" == "1" ]] ||
        die "UMS_READONLY must be 0 or 1"

    if [[ -e "${UMS_IMAGE}" ]]; then
        [[ -f "${UMS_IMAGE}" ]] || die "existing UMS image is not a regular file: ${UMS_IMAGE}"
        image_type=$(blkid -p -s TYPE -o value "${UMS_IMAGE}" 2>/dev/null || true)
        if [[ "${image_type}" != "exfat" ]]; then
            log "warning: preserving existing UMS image with filesystem '${image_type:-unknown}'"
        fi
        return
    fi

    command -v mkfs.exfat >/dev/null 2>&1 ||
        die "mkfs.exfat is required to create the UMS image"

    image_dir=$(dirname "${UMS_IMAGE}")
    mkdir -p "${image_dir}"
    temporary_image="${UMS_IMAGE}.new.$$"
    umask 077

    if ! truncate -s "${UMS_IMAGE_SIZE_MB}M" "${temporary_image}" ||
        ! mkfs.exfat -L "${UMS_LABEL}" "${temporary_image}"; then
        rm -f -- "${temporary_image}"
        die "failed to create exFAT UMS image"
    fi

    if ! chmod 0600 "${temporary_image}" ||
        ! mv -T "${temporary_image}" "${UMS_IMAGE}"; then
        rm -f -- "${temporary_image}"
        die "failed to install UMS image"
    fi

    log "created ${UMS_IMAGE_SIZE_MB} MiB exFAT UMS image at ${UMS_IMAGE}"
}

write_gadget_identity() {
    local serial=$1
    local configuration=""

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
    [[ "${ENABLE_RNDIS}" == "1" ]] && configuration="${configuration}RNDIS + "
    [[ "${ENABLE_ACM}" == "1" ]] && configuration="${configuration}serial + "
    [[ "${ENABLE_UMS}" == "1" ]] && configuration="${configuration}storage + "
    printf '%s\n' "${configuration% + }" > "${GADGET_PATH}/configs/c.1/strings/0x409/configuration"
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
    printf '1\n' > "${function_path}/lun.0/removable"
    printf '%s\n' "${UMS_READONLY}" > "${function_path}/lun.0/ro"
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
    [[ ! -e "${GADGET_PATH}" ]] ||
        die "gadget already exists: ${GADGET_NAME}"
    validate_boolean ENABLE_RNDIS "${ENABLE_RNDIS}"
    validate_boolean ENABLE_ACM "${ENABLE_ACM}"
    validate_boolean ENABLE_UMS "${ENABLE_UMS}"
    [[ "${ENABLE_RNDIS}" == "1" || "${ENABLE_ACM}" == "1" || "${ENABLE_UMS}" == "1" ]] ||
        die "at least one USB function must be enabled"

    serial=$(read_or_create_serial)
    controller=$(choose_udc)

    mkdir "${GADGET_PATH}"
    trap cleanup_failed_start ERR
    write_gadget_identity "${serial}"
    [[ "${ENABLE_RNDIS}" == "1" ]] && add_rndis "${serial}"
    [[ "${ENABLE_ACM}" == "1" ]] && add_acm
    [[ "${ENABLE_UMS}" == "1" ]] && add_ums
    printf '%s\n' "${controller}" > "${GADGET_PATH}/UDC"
    trap - ERR

    log "bound ${GADGET_NAME} to ${controller}"
}

stop_gadget() {
    local link

    [[ -d "${GADGET_PATH}" ]] || return 0

    printf '\n' > "${GADGET_PATH}/UDC" 2>/dev/null || true
    if [[ -e "${GADGET_PATH}/functions/mass_storage.0/lun.0/file" ]]; then
        printf '\n' > "${GADGET_PATH}/functions/mass_storage.0/lun.0/file" 2>/dev/null || true
    fi

    for link in "${GADGET_PATH}"/configs/c.1/*; do
        [[ -L "${link}" ]] && rm -f -- "${link}"
    done
    [[ -L "${GADGET_PATH}/os_desc/c.1" ]] && rm -f -- "${GADGET_PATH}/os_desc/c.1"

    rmdir "${GADGET_PATH}"/functions/* 2>/dev/null || true
    rmdir "${GADGET_PATH}/configs/c.1/strings/0x409" 2>/dev/null || true
    rmdir "${GADGET_PATH}/configs/c.1" 2>/dev/null || true
    rmdir "${GADGET_PATH}/strings/0x409" 2>/dev/null || true

    if ! rmdir "${GADGET_PATH}"; then
        die "failed to remove gadget; configfs still contains active objects"
    fi

    log "removed ${GADGET_NAME}"
}

cleanup_failed_start() {
    local status=$?

    trap - ERR
    log "start failed; removing partially configured gadget"
    stop_gadget || true
    exit "${status}"
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
