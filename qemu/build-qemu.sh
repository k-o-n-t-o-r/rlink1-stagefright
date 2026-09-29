#!/usr/bin/env bash
# Fetch, patch, and build the pinned qemu-linaro fork used by R-LINK.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

readonly QEMU_REPO=${QEMU_REPO:-https://github.com/dougg3/qemu-linaro-beagleboard.git}
readonly QEMU_COMMIT=${QEMU_COMMIT:-5475f0b82def09e4c4d810efc3f13b3759a41c70}
readonly PATCH_FILE="$QEMU_DIR/patches/rlink-qemu.patch"

need_cmd docker
need_cmd git
need_cmd sha256sum
need_file "$PATCH_FILE"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

if [[ ! -d "$QEMU_SRC/.git" ]]; then
    [[ ! -e "$QEMU_SRC" ]] || die "$QEMU_SRC exists but is not a git checkout"
    note "cloning qemu-linaro into $QEMU_SRC"
    mkdir -p "$(dirname "$QEMU_SRC")"
    git clone --branch beagleboard_fixes --single-branch "$QEMU_REPO" "$QEMU_SRC"
    git -C "$QEMU_SRC" checkout --detach "$QEMU_COMMIT"
fi

actual_commit=$(git -C "$QEMU_SRC" rev-parse HEAD)
if [[ "$actual_commit" != "$QEMU_COMMIT" ]]; then
    if [[ ${RESET_QEMU:-0} == 1 ]]; then
        note "resetting qemu-linaro to $QEMU_COMMIT"
        git -C "$QEMU_SRC" fetch origin "$QEMU_COMMIT"
        git -C "$QEMU_SRC" reset --hard
        git -C "$QEMU_SRC" checkout --detach "$QEMU_COMMIT"
    else
        die "QEMU_SRC is at $actual_commit, expected $QEMU_COMMIT (set RESET_QEMU=1 to reset)"
    fi
fi

if git -C "$QEMU_SRC" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    note "R-LINK QEMU patch is already applied"
elif git -C "$QEMU_SRC" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    note "applying $PATCH_FILE"
    git -C "$QEMU_SRC" apply "$PATCH_FILE"
else
    die "QEMU checkout has conflicting changes; cannot apply $PATCH_FILE"
fi

toolchain_label=org.rlink.qemu.dockerfile-sha256
toolchain_fingerprint=$(sha256sum "$QEMU_DIR/docker/Dockerfile" | awk '{print $1}')
installed_fingerprint=$(docker image inspect \
    -f "{{ index .Config.Labels \"$toolchain_label\" }}" "$BUILD_IMAGE" 2>/dev/null || true)
if [[ ${REBUILD_IMAGE:-0} == 1 || "$installed_fingerprint" != "$toolchain_fingerprint" ]]; then
    note "building toolchain image $BUILD_IMAGE"
    docker_build_args=(-t "$BUILD_IMAGE" --label "$toolchain_label=$toolchain_fingerprint")
    if [[ ${REBUILD_IMAGE:-0} == 1 ]]; then
        docker_build_args=(--no-cache "${docker_build_args[@]}")
    fi
    docker build "${docker_build_args[@]}" "$QEMU_DIR/docker"
else
    note "using current toolchain image $BUILD_IMAGE"
fi

jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')}
# Always configure inside the build container. Reusing config-host.mak from a
# different host/image can leave include and linker flags for missing packages.
configure='./configure --target-list=arm-softmmu \
  --disable-werror --disable-sdl --disable-gtk --disable-docs \
  --disable-xen --disable-vhost-net --enable-fdt --enable-libusb --python=/usr/bin/python
make -j"${JOBS}"'

note "building qemu-system-arm ($jobs jobs)"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e JOBS="$jobs" \
    -v "$QEMU_SRC:/work/qemu-linaro" \
    -w /work/qemu-linaro \
    "$BUILD_IMAGE" bash -eu -c "$configure"

binary="$QEMU_SRC/arm-softmmu/qemu-system-arm"
[[ -x "$binary" ]] || die "build completed without $binary"
note "ready: $binary"
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$QEMU_SRC:/work/qemu-linaro:ro" \
    "$BUILD_IMAGE" /work/qemu-linaro/arm-softmmu/qemu-system-arm --version \
    | head -n 1
