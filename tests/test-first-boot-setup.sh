#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-first-boot-test.XXXXXX")
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

GO_COMMAND=${GO_COMMAND:-$(command -v go)}
export GOCACHE="${TEST_ROOT}/go-cache"
export GOTMPDIR="${TEST_ROOT}/go-tmp"
mkdir -p "${GOCACHE}" "${GOTMPDIR}"

(
    cd "${REPO_ROOT}/src/openstick-setup"
    "${GO_COMMAND}" test -race ./...
)

SETUP_BINARY="${TEST_ROOT}/openstick-setup-linux-arm64"
(
    cd "${REPO_ROOT}/src/openstick-setup"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local \
        "${GO_COMMAND}" build -trimpath -buildvcs=false \
            -o "${SETUP_BINARY}" .
)
test -s "${SETUP_BINARY}"
"${GO_COMMAND}" version -m "${SETUP_BINARY}" |
    grep -Fq 'path	openstick.local/setup'

printf 'openstick first-boot setup tests passed\n'
