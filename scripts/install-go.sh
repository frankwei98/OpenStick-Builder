#!/bin/sh
set -eu

# Keep the compiler pinned and checksum-verified. It lives only in disposable
# build output, never in the target rootfs or a host-wide installation.
GO_VERSION=1.27.1
case "$(uname -m)" in
    x86_64|amd64) go_arch=amd64; go_sha=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445 ;;
    aarch64|arm64) go_arch=arm64; go_sha=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec ;;
    *) echo 'Unsupported Go build host' >&2; exit 2 ;;
esac
[ "$(uname -s)" = Linux ] || { echo 'Install the build compiler on Linux' >&2; exit 2; }
mkdir -p build
if [ -x build/go/bin/go ] && [ "$(build/go/bin/go version)" = "go version go${GO_VERSION} linux/${go_arch}" ]; then
    exit 0
fi
go_stage=$(mktemp -d "$(pwd)/build/go-download.XXXXXX")
trap 'rm -rf "${go_stage}"' EXIT HUP INT TERM
wget -q -O "${go_stage}/go.tar.gz" "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
printf '%s  %s\n' "${go_sha}" "${go_stage}/go.tar.gz" | sha256sum -c -
tar -xzf "${go_stage}/go.tar.gz" -C "${go_stage}"
rm -rf build/go
mv "${go_stage}/go" build/go
