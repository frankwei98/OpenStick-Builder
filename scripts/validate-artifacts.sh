#!/bin/sh
set -eu

ARTIFACT_DIR=${ARTIFACT_DIR:-files}
EXPECTED_ARTIFACTS="
aboot.mbn
boot.bin
gpt_both0.bin
hyp.mbn
rootfs.bin
rpm.mbn
sbl1.mbn
tz.mbn
"

if [ ! -d "${ARTIFACT_DIR}" ]; then
    echo "Artifact directory does not exist: ${ARTIFACT_DIR}" >&2
    exit 1
fi

rm -f -- "${ARTIFACT_DIR}/SHA256SUMS" \
    "${ARTIFACT_DIR}/SHA256SUMS.tmp"

printf '%s\n' "${EXPECTED_ARTIFACTS}" |
    while IFS= read -r artifact_name; do
        [ -n "${artifact_name}" ] || continue
        if [ ! -s "${ARTIFACT_DIR}/${artifact_name}" ]; then
            echo "Missing or empty build artifact: ${artifact_name}" >&2
            exit 1
        fi
    done

for artifact_path in "${ARTIFACT_DIR}"/*; do
    [ -e "${artifact_path}" ] || continue
    artifact_name=${artifact_path##*/}
    case "${artifact_name}" in
        aboot.mbn|boot.bin|gpt_both0.bin|hyp.mbn|rootfs.bin|rpm.mbn|sbl1.mbn|tz.mbn)
            ;;
        *)
            echo "Unexpected build artifact: ${artifact_name}" >&2
            exit 1
            ;;
    esac
done

(
    cd "${ARTIFACT_DIR}"
    sha256sum \
        aboot.mbn \
        boot.bin \
        gpt_both0.bin \
        hyp.mbn \
        rootfs.bin \
        rpm.mbn \
        sbl1.mbn \
        tz.mbn > SHA256SUMS.tmp
    mv SHA256SUMS.tmp SHA256SUMS
)
