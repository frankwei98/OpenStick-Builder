#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openstick-output-test.XXXXXX")
TEST_ROOT=$(cd -P "${TEST_ROOT}" && pwd -P)
trap 'rm -r "${TEST_ROOT}"' EXIT HUP INT TERM

BUILD_REPO="${TEST_ROOT}/repo"
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p \
    "${BUILD_REPO}/scripts" \
    "${BUILD_REPO}/configs/templates" \
    "${BUILD_REPO}/src/qhypstub" \
    "${BUILD_REPO}/src/lk2nd/project" \
    "${BUILD_REPO}/src/lk2nd/lk2nd/scripts" \
    "${BUILD_REPO}/src/qtestsign" \
    "${BUILD_REPO}/src/libusbgx" \
    "${BUILD_REPO}/src/gt/source" \
    "${STUB_BIN}"

cp "${REPO_ROOT}/build.sh" "${BUILD_REPO}/build.sh"
cp "${REPO_ROOT}/scripts/build_hyp_aboot.sh" \
    "${BUILD_REPO}/scripts/build_hyp_aboot.sh"
cp "${REPO_ROOT}/scripts/build_gt.sh" \
    "${BUILD_REPO}/scripts/build_gt.sh"
cp "${REPO_ROOT}/scripts/build-host.sh" \
    "${BUILD_REPO}/scripts/build-host.sh"
cp "${REPO_ROOT}/scripts/openstick-board-profile.sh" \
    "${BUILD_REPO}/scripts/openstick-board-profile.sh"

cat > "${BUILD_REPO}/configs/openstick-board-profiles" <<'EOF'
ufi003|ufi003.dtb|test,ufi003|UFI003
uz801|uz801.dtb|test,uz801|UZ801
EOF

cat > "${BUILD_REPO}/src/qhypstub/Makefile" <<'EOF'
.PHONY: all clean
all: qhypstub.elf
qhypstub.elf:
	printf 'hyp\n' > $@
clean:
	rm -f qhypstub.elf
EOF

cat > "${BUILD_REPO}/src/lk2nd/makefile" <<'EOF'
.PHONY: spotless lk1st-msm8916
spotless:
	rm -rf build-*
lk1st-msm8916:
	grep -q '^DEFINES += USE_TARGET_HS200_CAPS=1$$' project/lk1st-msm8916.mk
	test "$(LK2ND_VERSION)" = test-lk2nd-version
	mkdir -p build-lk1st-msm8916
	printf '%s|%s\n' "$(LK2ND_COMPATIBLE)" "$(LK2ND_VERSION)" \
		> build-lk1st-msm8916/emmc_appsboot.mbn
EOF
printf 'TARGET := msm8916\n' \
    > "${BUILD_REPO}/src/lk2nd/project/lk1st-msm8916.mk"
cat > "${BUILD_REPO}/src/lk2nd/lk2nd/scripts/describe-version.sh" <<'EOF'
#!/bin/sh
printf 'test-lk2nd-version\n'
EOF
chmod 0755 "${BUILD_REPO}/src/lk2nd/lk2nd/scripts/describe-version.sh"

cat > "${BUILD_REPO}/src/qtestsign/qtestsign.py" <<'EOF'
#!/bin/sh
cp "$2" "$4"
EOF
chmod 0755 "${BUILD_REPO}/src/qtestsign/qtestsign.py"

LK2ND_SOURCE_HASH=$(sha256sum \
    "${BUILD_REPO}/src/lk2nd/project/lk1st-msm8916.mk")
LK2ND_SOURCE_HASH=${LK2ND_SOURCE_HASH%% *}

build_firmware() {
    board=$1
    (
        cd "${BUILD_REPO}"
        OPENSTICK_BOARD=${board} \
        OPENSTICK_BOARD_PROFILES=configs/openstick-board-profiles \
            scripts/build_hyp_aboot.sh >/dev/null
    )
}

for board_and_compatible in \
    'ufi003:test,ufi003' \
    'uz801:test,uz801' \
    'generic:test,uz801'; do
    board=${board_and_compatible%%:*}
    compatible=${board_and_compatible#*:}
    build_firmware "${board}"
    test "$(cat "${BUILD_REPO}/files/aboot.mbn")" = \
        "${compatible}|test-lk2nd-version"
    test -s "${BUILD_REPO}/files/hyp.mbn"
    current_hash=$(sha256sum \
        "${BUILD_REPO}/src/lk2nd/project/lk1st-msm8916.mk")
    current_hash=${current_hash%% *}
    if [ "${current_hash}" != "${LK2ND_SOURCE_HASH}" ]; then
        echo "firmware build modified the lk2nd source tree" >&2
        exit 1
    fi
done

# Gadget-tool installation must start with empty stage-specific build and dist
# directories so removed files cannot survive a later build.
cat > "${BUILD_REPO}/src/libusbgx/configure" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${BUILD_REPO}/src/libusbgx/configure"
printf 'template\n' > "${BUILD_REPO}/configs/templates/example"

cat > "${STUB_BIN}/autoreconf" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${STUB_BIN}/chroot" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${STUB_BIN}/cmake" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -B ]; then
        mkdir -p "$2"
        exit 0
    fi
    shift
done
exit 1
EOF
cat > "${STUB_BIN}/make" <<'EOF'
#!/bin/sh
build_dir=
dest_dir=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -C)
            build_dir=$2
            shift 2
            ;;
        DESTDIR=*)
            dest_dir=${1#DESTDIR=}
            shift
            ;;
        *) shift ;;
    esac
done
[ -n "${dest_dir}" ] || exit 0
case "${build_dir}" in
    */libusbgx)
        mkdir -p "${dest_dir}/usr/lib/pkgconfig" "${dest_dir}/usr/include"
        printf 'library\n' > "${dest_dir}/usr/lib/libusbgx.so.2.0.0"
        ;;
    */gt)
        mkdir -p "${dest_dir}/usr/bin"
        printf 'gadget tool\n' > "${dest_dir}/usr/bin/gt"
        ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "${STUB_BIN}/autoreconf" "${STUB_BIN}/chroot" \
    "${STUB_BIN}/cmake" "${STUB_BIN}/make"

mkdir -p \
    "${BUILD_REPO}/rootfs/usr/lib/aarch64-linux-gnu" \
    "${BUILD_REPO}/dist" \
    "${BUILD_REPO}/build/gadget-tools"
printf 'stale\n' > "${BUILD_REPO}/dist/removed-by-new-build"
printf 'stale\n' > "${BUILD_REPO}/build/gadget-tools/removed-by-new-build"
(
    cd "${BUILD_REPO}"
    BUILD_HOST_ARCHITECTURE=arm64 PATH="${STUB_BIN}:${PATH}" \
        scripts/build_gt.sh >/dev/null
)
test ! -e "${BUILD_REPO}/dist/removed-by-new-build"
test ! -e "${BUILD_REPO}/build/gadget-tools/removed-by-new-build"
test -s "${BUILD_REPO}/dist/usr/bin/gt"
test -s "${BUILD_REPO}/dist/usr/lib/libusbgx.so.2.0.0"

# A complete build starts clean, while an active mount anywhere below a
# disposable output directory blocks cleanup.
cp "${REPO_ROOT}/scripts/prepare-build.sh" \
    "${BUILD_REPO}/scripts/prepare-build.sh"
cat > "${STUB_BIN}/findmnt" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_ACTIVE_MOUNT:-}" ]; then
    printf '%s\n' "${FAKE_ACTIVE_MOUNT}"
fi
EOF
cat > "${STUB_BIN}/rm" <<'EOF'
#!/bin/sh
printf 'rm:%s\n' "$*" >> "${RM_LOG}"
recursive=0
set -- "$@"
filtered=
for argument do
    case "${argument}" in
        -rf) recursive=1 ;;
        --one-file-system|--preserve-root=all|--) ;;
        *) filtered="${filtered}
${argument}" ;;
    esac
done
set --
while IFS= read -r argument; do
    [ -n "${argument}" ] || continue
    set -- "$@" "${argument}"
done <<EOF_ARGS
${filtered}
EOF_ARGS
if [ "${recursive}" -eq 1 ]; then
    exec /bin/rm -rf -- "$@"
fi
exec /bin/rm -f -- "$@"
EOF
chmod 0755 "${STUB_BIN}/findmnt" "${STUB_BIN}/rm"

RM_LOG="${TEST_ROOT}/rm.log"
: > "${RM_LOG}"

for output_path in build dist files mnt rootfs; do
    mkdir -p "${BUILD_REPO}/${output_path}"
    printf 'stale\n' > "${BUILD_REPO}/${output_path}/stale"
done
touch "${BUILD_REPO}/rootfs.tgz" \
    "${BUILD_REPO}/rootfs.raw" "${BUILD_REPO}/boot.raw"
(
    cd "${BUILD_REPO}"
    RM_LOG="${RM_LOG}" PATH="${STUB_BIN}:${PATH}" scripts/prepare-build.sh
)
grep -q -- '--one-file-system' "${RM_LOG}"
grep -q -- '--preserve-root=all' "${RM_LOG}"
for output_path in build dist files mnt rootfs; do
    test ! -e "${BUILD_REPO}/${output_path}"
done
test ! -e "${BUILD_REPO}/rootfs.tgz"
test ! -e "${BUILD_REPO}/rootfs.raw"
test ! -e "${BUILD_REPO}/boot.raw"

mkdir -p "${BUILD_REPO}/files/mounted"
printf 'keep\n' > "${BUILD_REPO}/files/mounted/data"
if (
    cd "${BUILD_REPO}"
    FAKE_ACTIVE_MOUNT="${BUILD_REPO}/files/mounted" \
    RM_LOG="${RM_LOG}" PATH="${STUB_BIN}:${PATH}" \
        scripts/prepare-build.sh >/dev/null 2>&1
); then
    echo "build preparation removed an output directory with an active mount" >&2
    exit 1
fi
test -f "${BUILD_REPO}/files/mounted/data"

# The artifact gate rejects extra files, then creates checksums for the exact
# expected output set once all producers have succeeded.
cp "${REPO_ROOT}/scripts/validate-artifacts.sh" \
    "${BUILD_REPO}/scripts/validate-artifacts.sh"
rm -rf "${BUILD_REPO}/files"
mkdir -p "${BUILD_REPO}/files"
for artifact in \
    aboot.mbn boot.bin gpt_both0.bin hyp.mbn rootfs.bin rpm.mbn sbl1.mbn tz.mbn; do
    printf '%s\n' "${artifact}" > "${BUILD_REPO}/files/${artifact}"
done

mv "${BUILD_REPO}/files/boot.bin" "${TEST_ROOT}/missing-boot.bin"
if (cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null 2>&1); then
    echo "artifact validation accepted a missing output" >&2
    exit 1
fi
mv "${TEST_ROOT}/missing-boot.bin" "${BUILD_REPO}/files/boot.bin"

: > "${BUILD_REPO}/files/rootfs.bin"
if (cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null 2>&1); then
    echo "artifact validation accepted an empty output" >&2
    exit 1
fi
printf 'rootfs.bin\n' > "${BUILD_REPO}/files/rootfs.bin"

printf 'metadata\n' > "${BUILD_REPO}/files/.DS_Store"
if (cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null 2>&1); then
    echo "artifact validation accepted a hidden extra output" >&2
    exit 1
fi
rm "${BUILD_REPO}/files/.DS_Store"

printf 'stale\n' > "${BUILD_REPO}/files/unexpected.bin"
if (cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null 2>&1); then
    echo "artifact validation accepted a stale output" >&2
    exit 1
fi
rm "${BUILD_REPO}/files/unexpected.bin"

# Artifact names must identify regular files produced inside files/. A symlink
# to an external file must not satisfy a required artifact, and an unexpected
# dangling symlink must not disappear from the exact-set check.
mv "${BUILD_REPO}/files/aboot.mbn" "${TEST_ROOT}/external-aboot.mbn"
ln -s "${TEST_ROOT}/external-aboot.mbn" \
    "${BUILD_REPO}/files/aboot.mbn"
if (cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null 2>&1); then
    echo "artifact validation accepted a symlink as a build artifact" >&2
    exit 1
fi
rm "${BUILD_REPO}/files/aboot.mbn"
mv "${TEST_ROOT}/external-aboot.mbn" "${BUILD_REPO}/files/aboot.mbn"

ln -s "${TEST_ROOT}/missing-artifact" \
    "${BUILD_REPO}/files/unexpected-dangling"
if (cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null 2>&1); then
    echo "artifact validation ignored an unexpected dangling symlink" >&2
    exit 1
fi
rm "${BUILD_REPO}/files/unexpected-dangling"

(cd "${BUILD_REPO}" && scripts/validate-artifacts.sh >/dev/null)
test -s "${BUILD_REPO}/files/SHA256SUMS"
test "$(wc -l < "${BUILD_REPO}/files/SHA256SUMS" | tr -d ' ')" -eq 8

printf 'build output isolation tests passed\n'
