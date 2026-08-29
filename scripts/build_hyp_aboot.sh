#!/bin/sh -e

OPENSTICK_BOARD_PROFILES=${OPENSTICK_BOARD_PROFILES:-configs/openstick-board-profiles}
export OPENSTICK_BOARD_PROFILES
# shellcheck source=scripts/openstick-board-profile.sh
. scripts/openstick-board-profile.sh

openstick_build_profile_load "${OPENSTICK_BOARD:-generic}"

FIRMWARE_BUILD_DIR="$(pwd)/build/firmware/${OPENSTICK_BUILD_PROFILE}"
QHYPSTUB_BUILD_DIR="${FIRMWARE_BUILD_DIR}/qhypstub"
LK2ND_BUILD_DIR="${FIRMWARE_BUILD_DIR}/lk2nd"
HS200_DEFINE='DEFINES += USE_TARGET_HS200_CAPS=1'

# Build from fresh per-profile copies. This retains intentional source changes
# in the submodules without putting generated files or patches back into them.
rm -rf -- "${FIRMWARE_BUILD_DIR}"
mkdir -p "${QHYPSTUB_BUILD_DIR}" "${LK2ND_BUILD_DIR}" files
cp -a src/qhypstub/. "${QHYPSTUB_BUILD_DIR}/"
cp -a src/lk2nd/. "${LK2ND_BUILD_DIR}/"
rm -f -- files/hyp.mbn files/aboot.mbn

make -C "${QHYPSTUB_BUILD_DIR}" clean
make -C "${QHYPSTUB_BUILD_DIR}" CROSS_COMPILE=aarch64-linux-gnu-

# patch to reduce mmc speed as some boards have intermittent failures when
# inititalizing the mmc (maybe due to using old/recycled flash chips)
make -C "${LK2ND_BUILD_DIR}" spotless
if ! grep -Fqx "${HS200_DEFINE}" \
    "${LK2ND_BUILD_DIR}/project/lk1st-msm8916.mk"; then
    printf '%s\n' "${HS200_DEFINE}" \
        >> "${LK2ND_BUILD_DIR}/project/lk1st-msm8916.mk"
fi

make -C "${LK2ND_BUILD_DIR}" LK2ND_BUNDLE_DTB="msm8916-512mb-mtp.dtb" \
    LK2ND_COMPATIBLE="${OPENSTICK_PROFILE_COMPATIBLE}" \
    TOOLCHAIN_PREFIX=arm-none-eabi- lk1st-msm8916

# test sign
src/qtestsign/qtestsign.py hyp "${QHYPSTUB_BUILD_DIR}/qhypstub.elf" \
    -o "${FIRMWARE_BUILD_DIR}/hyp.mbn"
src/qtestsign/qtestsign.py aboot \
    "${LK2ND_BUILD_DIR}/build-lk1st-msm8916/emmc_appsboot.mbn" \
    -o "${FIRMWARE_BUILD_DIR}/aboot.mbn"
install -m 0644 "${FIRMWARE_BUILD_DIR}/hyp.mbn" files/hyp.mbn
install -m 0644 "${FIRMWARE_BUILD_DIR}/aboot.mbn" files/aboot.mbn
