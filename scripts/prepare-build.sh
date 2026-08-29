#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
CURRENT_DIR=$(pwd -P)

if [ "${CURRENT_DIR}" != "${REPO_ROOT}" ] || \
    [ ! -f "${REPO_ROOT}/build.sh" ] || \
    [ ! -d "${REPO_ROOT}/scripts" ]; then
    echo "Build preparation must run from the repository root" >&2
    exit 1
fi
if ! command -v findmnt >/dev/null 2>&1; then
    echo "Unable to verify build output mounts: findmnt is unavailable" >&2
    exit 2
fi
if ! ACTIVE_MOUNTS=$(findmnt -rn -o TARGET 2>/dev/null); then
    echo "Unable to inspect active mounts" >&2
    exit 2
fi

for output_name in build dist files mnt rootfs; do
    output_path="${REPO_ROOT}/${output_name}"
    if printf '%s\n' "${ACTIVE_MOUNTS}" |
        awk -v output_path="${output_path}" '
            $0 == output_path || index($0, output_path "/") == 1 {
                found = 1
            }
            END { exit !found }
        '; then
        echo "Refusing to clean output with an active mount: ${output_path}" >&2
        exit 2
    fi
done

rm -rf -- \
    "${REPO_ROOT:?}/build" \
    "${REPO_ROOT:?}/dist" \
    "${REPO_ROOT:?}/files" \
    "${REPO_ROOT:?}/mnt" \
    "${REPO_ROOT:?}/rootfs"
rm -f -- \
    "${REPO_ROOT}/boot.raw" \
    "${REPO_ROOT}/rootfs.raw" \
    "${REPO_ROOT}/rootfs.tgz"
