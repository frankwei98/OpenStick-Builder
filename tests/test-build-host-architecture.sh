#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=../scripts/build-host.sh
. "${REPO_ROOT}/scripts/build-host.sh"

test "$(BUILD_HOST_ARCHITECTURE=amd64 detect_build_host_architecture)" = "amd64"
test "$(BUILD_HOST_ARCHITECTURE=arm64 detect_build_host_architecture)" = "arm64"

amd64_packages=" $(build_host_extra_packages amd64) "
case "${amd64_packages}" in
    *" gcc-aarch64-linux-gnu "*) ;;
    *) echo "amd64 build dependencies lost the AArch64 C toolchain" >&2; exit 1 ;;
esac
case "${amd64_packages}" in
    *" g++-aarch64-linux-gnu "*) ;;
    *) echo "amd64 build dependencies lost the AArch64 C++ toolchain" >&2; exit 1 ;;
esac
case "${amd64_packages}" in
    *" qemu-user-static "*) ;;
    *) echo "amd64 build dependencies lost QEMU" >&2; exit 1 ;;
esac

arm64_packages=" $(build_host_extra_packages arm64) "
case "${arm64_packages}" in
    *" gcc-aarch64-linux-gnu "*) ;;
    *) echo "arm64 build dependencies lack the proven AArch64 C toolchain" >&2; exit 1 ;;
esac
case "${arm64_packages}" in
    *" g++-aarch64-linux-gnu "*) ;;
    *) echo "arm64 build dependencies lack the proven AArch64 C++ toolchain" >&2; exit 1 ;;
esac
case "${arm64_packages}" in
    *" qemu-user-static "*|*" binfmt-support "*)
        echo "arm64 native build dependencies unexpectedly require emulation" >&2
        exit 1
        ;;
esac

test "$(build_host_rootfs_mode amd64)" = "foreign"
test "$(build_host_rootfs_mode arm64)" = "native"

if require_supported_build_host_architecture riscv64 2>/dev/null; then
    echo "unsupported build host architecture was accepted" >&2
    exit 1
fi

printf 'build host architecture tests passed\n'
