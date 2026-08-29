#!/bin/sh -e

OPENSTICK_BOARD_PROFILES=${OPENSTICK_BOARD_PROFILES:-configs/openstick-board-profiles}
export OPENSTICK_BOARD_PROFILES
# shellcheck source=scripts/openstick-board-profile.sh
. scripts/openstick-board-profile.sh

OPENSTICK_BOARD=${OPENSTICK_BOARD:-generic}
openstick_build_profile_load "${OPENSTICK_BOARD}"
OPENSTICK_BOARD=${OPENSTICK_BUILD_PROFILE}
export OPENSTICK_BOARD

if [ "${OPENSTICK_BOARD}" = generic ]; then
    printf 'Building generic image (board selected after flashing)\n\n'
else
    printf 'Building preconfigured image for %s\n\n' \
        "${OPENSTICK_PROFILE_LABEL}"
fi

printf 'Prepare clean build workspace\n\n'
scripts/prepare-build.sh

printf 'Install dependencies\n\n'
scripts/install_deps.sh

printf '\nBuild hyp and aboot firmware\n\n'
scripts/build_hyp_aboot.sh

printf '\nExtract MSM8916 firmware\n\n'
scripts/extract_fw.sh

printf '\nCreate rootfs\n\n'
scripts/debootstrap.sh

printf '\nBuild gadget-tools\n\n'
scripts/build_gt.sh

printf '\nCreate images\n\n'
scripts/build_images.sh

printf '\nValidate artifacts\n\n'
scripts/validate-artifacts.sh
