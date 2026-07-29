#!/bin/sh
set -eu

STATE_DIR=${STATE_DIR:-/var/lib/openstick/first-boot}
MARKER_FILE="${STATE_DIR}/rootfs-resized"
LOCK_FILE="${STATE_DIR}/rootfs-resize.lock"

log() {
    printf 'openstick-resize-rootfs: %s\n' "$*" >&2
}

if [ -e "${MARKER_FILE}" ]; then
    log "already completed"
    exit 0
fi

install -d -m 0755 "${STATE_DIR}"
exec 9> "${LOCK_FILE}"
flock 9

if [ -e "${MARKER_FILE}" ]; then
    log "already completed"
    exit 0
fi

root_device=$(findmnt -nro SOURCE -T /)
root_fstype=$(findmnt -nro FSTYPE -T /)
resolved_device=$(readlink -f "${root_device}" 2>/dev/null || true)

if [ -n "${resolved_device}" ]; then
    root_device=${resolved_device}
fi

if [ "${root_fstype}" != "ext4" ]; then
    log "error: root filesystem is ${root_fstype:-unknown}, expected ext4"
    exit 1
fi

if [ ! -b "${root_device}" ]; then
    log "error: root source is not a block device: ${root_device:-unknown}"
    exit 1
fi

log "expanding ${root_device} to the partition size"
resize2fs "${root_device}"

temporary_marker=$(mktemp "${STATE_DIR}/.rootfs-resized.XXXXXX")
trap 'rm -f "${temporary_marker}"' EXIT HUP INT TERM
{
    printf 'device=%s\n' "${root_device}"
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${temporary_marker}"
chmod 0644 "${temporary_marker}"
mv -T "${temporary_marker}" "${MARKER_FILE}"
trap - EXIT HUP INT TERM

log "completed"
