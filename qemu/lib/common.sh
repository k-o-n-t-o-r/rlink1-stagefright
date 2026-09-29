#!/usr/bin/env bash
# Shared configuration for the R-LINK QEMU scripts.

if [[ -z ${QEMU_DIR:-} ]]; then
    QEMU_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

readonly DEFAULT_CMDLINE="root=/dev/mmcblk0p2 console=ttyO2,115200 androidboot.console=ttyO2 sysboot_mode=cold init=/init videoout=omap24xxvout vram=0x300000,0x83000000 lpj=2334720 brick=0"

# Local overrides are intentionally not committed. The file is sourced as shell.
if [[ -f "$QEMU_DIR/config.env" ]]; then
    # shellcheck source=/dev/null
    source "$QEMU_DIR/config.env"
fi

: "${QEMU_SRC:=$QEMU_DIR/.build/qemu-linaro}"
: "${BUILD_IMAGE:=rlink-qemu-build:18.04}"
: "${NAME:=rlinkq}"
: "${SHELL_PORT:=2323}"
: "${VNC_PORT:=5900}"
: "${GDB_PORT:=0}"
: "${PERSIST:=0}"
: "${RLINK_MACHID:=3186}"
: "${RLINK_SYSREV:=}"
: "${EOL_MMI_LANGUAGE:=3}"
: "${EOL_ANDROID_AUTO:=0}"
: "${TOUCHSCREEN:=1}"
: "${USB_PASSTHROUGH:=0}"
: "${USB_PHONE_BUS:=}"
: "${USB_PHONE_PORT:=}"
: "${USB_PHONE_GUEST_BUS:=usb-bus.2}"
: "${QEMU_BIN:=/work/qemu-linaro/arm-softmmu/qemu-system-arm}"
: "${BOOT_TIMEOUT:=240}"
: "${SMOKE_STABILITY_SECONDS:=130}"
: "${EMMC_SIZE:=2G}"
: "${SD_IMAGE:=$QEMU_DIR/removable.img}"
: "${SD_SIZE:=1G}"
: "${SD_LABEL:=RLINKSD}"
: "${SD_CID:=00000000000000000000000000000000}"
: "${SD_TIMEOUT:=60}"
: "${CMDLINE_EXTRA:=}"
: "${CMDLINE:=$DEFAULT_CMDLINE${CMDLINE_EXTRA:+ $CMDLINE_EXTRA}}"

note() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

need_file() {
    [[ -f "$1" ]] || die "required file not found: $1"
}

container_exists() {
    docker container inspect "$NAME" >/dev/null 2>&1
}

container_running() {
    [[ $(docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true) == true ]]
}

find_rootfs_source() {
    local candidate
    if [[ -n ${ROOTFS_SOURCE:-} ]]; then
        printf '%s\n' "$ROOTFS_SOURCE"
        return
    fi
    for candidate in \
        "$QEMU_DIR/../temp/ttpkg/system-update_3064886_all_data/rootfs.img.new" \
        "$QEMU_DIR/../system-update_3064886_all_data/rootfs.img.new"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    return 1
}
