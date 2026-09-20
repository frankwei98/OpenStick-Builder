#!/bin/sh
set -eu

CHROOT=${CHROOT:-"$(pwd)/rootfs"}
GO_BIN=${GO_BIN:-"$(pwd)/build/go/bin/go"}
CHROOT=$(CDPATH='' cd -P -- "${CHROOT}" 2>/dev/null && pwd -P) || {
    echo 'A prepared target rootfs is required' >&2
    exit 2
}
if [ ! -d "${CHROOT}/etc" ] || [ "${CHROOT}" = / ]; then
    echo 'A prepared target rootfs is required' >&2
    exit 2
fi
[ -x "${GO_BIN}" ] || { echo 'Run scripts/install-go.sh first' >&2; exit 2; }
output_dir="$(pwd)/build/setup"
mkdir -p "${output_dir}"
(
    cd src/openstick-setup
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local \
        "${GO_BIN}" build -trimpath -buildvcs=false -ldflags='-s -w' \
            -o "${output_dir}/openstick-setup" .
)
install -D -m 0755 "${output_dir}/openstick-setup" \
    "${CHROOT}/usr/libexec/openstick-setup"
