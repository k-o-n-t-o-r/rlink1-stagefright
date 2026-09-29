#!/usr/bin/env bash
# Validate the host, build tree, and generated boot artifacts.
set -uo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

errors=0
warnings=0
ok() { printf '[ ok ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; errors=$((errors + 1)); }
caution() { printf '[warn] %s\n' "$*"; warnings=$((warnings + 1)); }

printf 'R-LINK QEMU doctor\n\n'

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        ok "Docker daemon"
    else
        fail "Docker is installed but the daemon is unavailable"
    fi
else
    fail "Docker is not installed"
fi

if command -v docker >/dev/null 2>&1 && docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1; then
    ok "toolchain image: $BUILD_IMAGE"
else
    fail "toolchain image missing: $BUILD_IMAGE (run ./build-qemu.sh)"
fi

host_binary="$QEMU_SRC/arm-softmmu/qemu-system-arm"
if [[ -x "$host_binary" ]]; then
    version=$(docker run --rm --user "$(id -u):$(id -g)" \
        -v "$QEMU_SRC:/work/qemu-linaro:ro" "$BUILD_IMAGE" \
        /work/qemu-linaro/arm-softmmu/qemu-system-arm --version 2>/dev/null \
        | head -n 1)
    if [[ -n "$version" ]]; then
        ok "QEMU binary: $version"
    else
        fail "QEMU binary exists but does not run in $BUILD_IMAGE"
    fi
    if grep -a -q 'RLINK_EEPROM_MMI_LANGUAGE' "$host_binary"; then
        ok "QEMU factory/EOL EEPROM support"
    else
        fail "QEMU binary predates the factory/EOL EEPROM patch (run ./build-qemu.sh)"
    fi
    if grep -a -q 'QEMU R-LINK TSC2007 Touchscreen' "$host_binary"; then
        ok "QEMU VNC touchscreen support"
    else
        fail "QEMU binary predates the TSC2007 patch (run ./build-qemu.sh)"
    fi
    if grep -a -q 'rlink-cid' "$host_binary"; then
        ok "QEMU SMSC SD-CID support"
    else
        fail "QEMU binary predates the SD-CID patch (run ./build-qemu.sh)"
    fi
else
    fail "patched QEMU binary missing: $host_binary"
fi

if [[ "$EOL_MMI_LANGUAGE" =~ ^[0-9]+$ ]] \
    && (( 10#$EOL_MMI_LANGUAGE <= 255 )); then
    ok "factory MmiLanguage: $((10#$EOL_MMI_LANGUAGE))"
else
    fail "EOL_MMI_LANGUAGE must be a decimal byte (0-255): $EOL_MMI_LANGUAGE"
fi

if [[ "$TOUCHSCREEN" == 0 || "$TOUCHSCREEN" == 1 ]]; then
    ok "VNC touchscreen: $([[ "$TOUCHSCREEN" == 1 ]] && printf enabled || printf disabled)"
else
    fail "TOUCHSCREEN must be 0 or 1: $TOUCHSCREEN"
fi

if [[ "$SD_CID" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    ok "emulated SD CID: ${SD_CID^^}"
else
    fail "SD_CID must contain exactly 32 hexadecimal characters"
fi

if [[ -s "$QEMU_DIR/zImage" ]]; then
    ok "zImage ($(du -h "$QEMU_DIR/zImage" | awk '{print $1}'))"
else
    fail "zImage is missing (run scripts/extract_firmware.py from the repository root)"
fi
for artifact in Image-debug rlink.dtb sd.img; do
    if [[ -s "$QEMU_DIR/$artifact" ]]; then
        ok "$artifact ($(du -h "$QEMU_DIR/$artifact" | awk '{print $1}'))"
    else
        fail "$artifact is missing (run ./rlink-qemu prepare)"
    fi
done

if [[ -s "$QEMU_DIR/Image" && -s "$QEMU_DIR/Image-debug" ]]; then
    if "$QEMU_DIR/mkkernel.sh" --check >/dev/null 2>&1; then
        ok "kernel hashes and binary patches"
    else
        fail "kernel artifacts failed verification (run ./mkkernel.sh)"
    fi
else
    caution "raw Image is absent; run ./mkkernel.sh to make kernel builds reproducible"
fi

if (cd "$QEMU_DIR" && sha256sum -c diagnostics/heaptrace.sha256 >/dev/null 2>&1); then
    ok "mediaserver heap-tracer source and binary"
else
    fail "mediaserver heap-tracer checksums failed (run ./build-heaptrace.sh)"
fi

if command -v dtc >/dev/null 2>&1 && [[ -s "$QEMU_DIR/rlink.dtb" ]]; then
    temporary=$(mktemp)
    if dtc -q -I dts -O dtb -o "$temporary" "$QEMU_DIR/rlink.dts" \
        && cmp -s "$temporary" "$QEMU_DIR/rlink.dtb"; then
        ok "rlink.dtb matches rlink.dts"
    else
        fail "rlink.dtb is stale (run ./mkdtb.sh)"
    fi
    rm -f "$temporary"
else
    caution "dtc is unavailable; cannot verify rlink.dtb"
fi

rootfs=$(find_rootfs_source 2>/dev/null || true)
if [[ -n "$rootfs" && -f "$rootfs" ]]; then
    ok "source rootfs: $rootfs"
else
    fail "source rootfs.img.new not found (run scripts/extract_firmware.py)"
fi

for artifact in staging/p2/rootfs.img staging/p2/rootfs.img.rw; do
    if [[ -s "$QEMU_DIR/$artifact" ]]; then
        ok "$artifact"
    else
        fail "$artifact is missing (run ./mkrw.sh)"
    fi
done

if command -v sfdisk >/dev/null 2>&1 && [[ -s "$QEMU_DIR/sd.img" ]]; then
    if sfdisk -d "$QEMU_DIR/sd.img" 2>/dev/null | grep -q 'start= *133120'; then
        ok "sd.img partition table"
    else
        fail "sd.img has an unexpected partition table"
    fi
fi

if [[ -f "$QEMU_DIR/vnc-tap.py" ]] \
    && python3 "$QEMU_DIR/vnc-tap.py" --help >/dev/null 2>&1; then
    ok "VNC tap client"
else
    fail "vnc-tap.py is missing or invalid"
fi

runtime_tools=(python3)
build_tools=(git debugfs e2fsck fsck.fat sfdisk mkfs.fat mke2fs dtc)
for command in "${runtime_tools[@]}"; do
    command -v "$command" >/dev/null 2>&1 && ok "host command: $command" || fail "host command missing: $command"
done
for command in "${build_tools[@]}"; do
    command -v "$command" >/dev/null 2>&1 && ok "build command: $command" || caution "build command missing: $command"
done

if container_running 2>/dev/null; then
    ok "container $NAME is running"
elif container_exists 2>/dev/null; then
    caution "container $NAME exists but is stopped"
else
    ok "container name $NAME is available"
fi

printf '\n%d error(s), %d warning(s)\n' "$errors" "$warnings"
((errors == 0))
