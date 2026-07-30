#!/bin/sh

detect_build_host_architecture() {
    if [ -n "${BUILD_HOST_ARCHITECTURE:-}" ]; then
        printf '%s\n' "${BUILD_HOST_ARCHITECTURE}"
        return
    fi

    if ! command -v dpkg >/dev/null 2>&1; then
        echo "Unable to detect build host architecture: dpkg is unavailable" >&2
        return 1
    fi

    dpkg --print-architecture
}

require_supported_build_host_architecture() {
    case "$1" in
        amd64|arm64) ;;
        *)
            echo "Unsupported build host architecture: $1" >&2
            return 1
            ;;
    esac
}

build_host_extra_packages() {
    require_supported_build_host_architecture "$1" || return

    case "$1" in
        amd64)
            printf '%s\n' \
                "binfmt-support g++-aarch64-linux-gnu gcc-aarch64-linux-gnu qemu-user-static"
            ;;
        arm64)
            printf '%s\n' \
                "g++-aarch64-linux-gnu gcc-aarch64-linux-gnu"
            ;;
    esac
}

build_host_rootfs_mode() {
    require_supported_build_host_architecture "$1" || return

    case "$1" in
        amd64) printf '%s\n' foreign ;;
        arm64) printf '%s\n' native ;;
    esac
}
