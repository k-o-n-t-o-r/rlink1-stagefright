#!/usr/bin/env bash
# Create and hotplug removable media through QEMU's modeled EHCI controller.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

readonly SD_DRIVE_ID=extsd
readonly SD_DEVICE_ID=extsddev
readonly SD_USB_BUS=usb-bus.2

usage() {
    cat <<'EOF'
Usage:
  ./rlink-qemu sd-create [--size SIZE] [--label LABEL] [--force] [image]
  ./rlink-qemu sd-attach [image]
  ./rlink-qemu sd-detach [--force]

Defaults come from SD_IMAGE, SD_SIZE, SD_LABEL, SD_CID, and SD_TIMEOUT in config.env.
The image must be inside qemu/ because that directory is mounted into QEMU.
EOF
}

resolve_image() {
    local input=$1 resolved
    if [[ "$input" != /* ]]; then
        input="$QEMU_DIR/$input"
    fi
    resolved=$(realpath -m -- "$input") || die "cannot resolve SD image path: $input"
    case $resolved in
        "$QEMU_DIR"/*) ;;
        *) die "SD image must be inside $QEMU_DIR: $resolved" ;;
    esac
    printf '%s\n' "$resolved"
}

container_image_path() {
    local host_path=$1 relative
    relative=${host_path#"$QEMU_DIR"/}
    [[ "$relative" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "SD image path contains characters unsupported by the QEMU monitor: $relative"
    printf '/work/rlink/%s\n' "$relative"
}

monitor_output() {
    "$QEMU_DIR/mon.sh" "$1"
}

block_attached() {
    monitor_output 'info block' | grep -q "^${SD_DRIVE_ID}:"
}

device_attached() {
    monitor_output 'info qtree' | grep -q "id \"${SD_DEVICE_ID}\""
}

create_card() {
    local image=$SD_IMAGE size=$SD_SIZE label=$SD_LABEL force=0
    local positional=0 argument parent base temporary bytes

    while (($#)); do
        argument=$1
        shift
        case $argument in
            --size)
                (($#)) || die "--size requires a value"
                size=$1
                shift
                ;;
            --label)
                (($#)) || die "--label requires a value"
                label=$1
                shift
                ;;
            --force)
                force=1
                ;;
            --help|-h)
                usage
                return 0
                ;;
            --)
                (($# <= 1)) || die "sd-create accepts only one image path"
                if (($#)); then
                    image=$1
                    positional=1
                    shift
                fi
                ;;
            -*)
                die "unknown sd-create option: $argument"
                ;;
            *)
                (( positional == 0 )) || die "sd-create accepts only one image path"
                image=$argument
                positional=1
                ;;
        esac
    done

    [[ "$size" =~ ^[1-9][0-9]*[A-Za-z]{0,3}$ ]] \
        || die "invalid SD size: $size (examples: 256M, 1G, 2GiB)"
    [[ "$label" =~ ^[A-Za-z0-9_-]{1,11}$ ]] \
        || die "invalid FAT label: use 1-11 letters, digits, '_' or '-'"

    need_cmd realpath
    need_cmd truncate
    need_cmd mkfs.fat
    need_cmd fsck.fat
    need_cmd stat

    image=$(resolve_image "$image")
    container_image_path "$image" >/dev/null
    [[ "$image" != "$(realpath -m -- "$QEMU_DIR/sd.img")" ]] \
        || die "refusing to replace the emulator boot disk: $image"
    parent=$(dirname "$image")
    base=$(basename "$image")
    [[ -d "$parent" ]] || die "SD image directory does not exist: $parent"

    if [[ -e "$image" || -L "$image" ]]; then
        (( force == 1 )) || die "SD image already exists: $image (use --force to replace it)"
        if command -v docker >/dev/null 2>&1 && container_running && block_attached; then
            die "detach the current removable card before replacing an image"
        fi
    fi

    umask 077
    temporary=$(mktemp "$parent/.${base}.sd-create.XXXXXX")
    trap 'rm -f -- "$temporary"' EXIT
    truncate -s "$size" -- "$temporary"
    bytes=$(stat -c '%s' -- "$temporary")
    (( bytes >= 64 * 1024 * 1024 )) \
        || die "FAT32 image must be at least 64 MiB (requested $size)"
    (( bytes % 512 == 0 )) || die "SD image size must be a multiple of 512 bytes"

    mkfs.fat -F 32 -n "$label" "$temporary" >/dev/null
    fsck.fat -n "$temporary" >/dev/null
    chmod 0600 "$temporary"

    if (( force == 0 )) && [[ -e "$image" || -L "$image" ]]; then
        die "SD image appeared while it was being created: $image"
    fi
    mv -f -- "$temporary" "$image"
    trap - EXIT

    note "created FAT32 removable card: $image"
    printf '    size:  %s bytes\n' "$bytes"
    printf '    label: %s\n' "$label"
}

attach_card() {
    local image=$SD_IMAGE host_image container_image result qtree cid
    local drive_added=0 device_added=0 deadline state mounted=0
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        usage
        return 0
    fi
    [[ ${1:-} != -- ]] || shift
    (($# <= 1)) || die "usage: ./rlink-qemu sd-attach [image]"
    if (($#)); then
        [[ "$1" != -* ]] || die "unknown sd-attach option: $1"
        image=$1
    fi

    need_cmd docker
    need_cmd python3
    need_cmd realpath
    need_cmd stat
    container_running || die "container $NAME is not running"
    monitor_output 'info status' >/dev/null
    [[ "$SD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "SD_TIMEOUT must be a positive integer"
    [[ "$SD_CID" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "SD_CID must contain exactly 32 hexadecimal characters"
    cid=${SD_CID^^}

    host_image=$(resolve_image "$image")
    need_file "$host_image"
    [[ -w "$host_image" ]] || die "SD image is not writable: $host_image"
    [[ "$host_image" != "$(realpath -m -- "$QEMU_DIR/sd.img")" ]] \
        || die "refusing to attach the emulator boot disk as removable media"
    if [[ -e "$QEMU_DIR/sd.img" && "$host_image" -ef "$QEMU_DIR/sd.img" ]]; then
        die "refusing to attach a hard link to the emulator boot disk"
    fi
    local image_bytes
    image_bytes=$(stat -c '%s' -- "$host_image")
    (( image_bytes >= 512 && image_bytes % 512 == 0 )) \
        || die "SD image must be non-empty and sector-aligned: $host_image"
    container_image=$(container_image_path "$host_image")

    block_attached && die "a removable SD image is already attached; run sd-detach first"
    device_attached && die "USB removable device $SD_DEVICE_ID already exists"
    qtree=$(monitor_output 'info qtree')
    grep -q "bus: ${SD_USB_BUS}" <<<"$qtree" \
        || die "QEMU USB bus $SD_USB_BUS is unavailable"

    cleanup_failed_attach() {
        if (( device_added == 1 )); then
            monitor_output "device_del $SD_DEVICE_ID" >/dev/null 2>&1 || true
            sleep 1
        fi
        if (( drive_added == 1 )) && block_attached; then
            monitor_output "drive_del $SD_DRIVE_ID" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup_failed_attach EXIT

    result=$(monitor_output \
        "drive_add 0 if=none,id=$SD_DRIVE_ID,file=$container_image,format=raw")
    [[ "$result" == *OK* ]] || die "QEMU rejected the SD image: ${result:-no response}"
    drive_added=1

    result=$(monitor_output \
        "device_add usb-storage,id=$SD_DEVICE_ID,drive=$SD_DRIVE_ID,bus=$SD_USB_BUS,rlink-cid=$cid")
    device_added=1
    [[ -z "$result" || "$result" == *OK* ]] \
        || die "QEMU rejected the USB device: $result"

    deadline=$((SECONDS + SD_TIMEOUT))
    while (( SECONDS < deadline )); do
        if block_attached && device_attached; then
            break
        fi
        sleep 1
    done
    block_attached || die "QEMU did not retain block backend $SD_DRIVE_ID"
    device_attached || die "QEMU did not create USB device $SD_DEVICE_ID"

    trap - EXIT
    note "attached removable card: $host_image"
    printf '    guest device: USB mass storage (normally /dev/sda)\n'
    printf '    emulated CID: %s\n' "$cid"

    deadline=$((SECONDS + SD_TIMEOUT))
    while (( SECONDS < deadline )); do
        state=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 3 -- \
            'mounted=$(grep "^/dev/block/vold/.* /mnt/" /proc/mounts | grep -v " /mnt/secure/staging " || true); if [ -n "$mounted" ]; then echo __RLINK_SD_MOUNTED__; echo "$mounted"; elif grep -q " sda$" /proc/partitions; then echo __RLINK_SD_DETECTED__; fi' \
            2>/dev/null || true)
        if grep -q '^__RLINK_SD_MOUNTED__$' <<<"$state"; then
            mounted=1
            break
        fi
        sleep 1
    done
    if (( mounted == 1 )); then
        note "guest mounted the card or TomTom container under /mnt"
        if grep -q '^/dev/block/vold/254:' <<<"$state"; then
            # The Froyo navigation process does not reliably rescan maps that
            # appear after it starts. ActivityManager restarts its requested
            # services after SIGKILL, now with the mounted map available.
            python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 10 -- \
                'pid=$(pidof com.tomtom.navigation); if [ -n "$pid" ]; then kill -9 "$pid"; fi' \
                >/dev/null 2>&1 || warn "could not request navigation media rescan"
            note "requested navigation service rescan"
        fi
    else
        warn "card is attached, but a final guest mount was not confirmed within ${SD_TIMEOUT}s"
        printf '    TomTom containers can take several minutes to map; check later with:\n'
        printf '    ./rlink-qemu exec '\''vdc volume list; mount | grep /mnt/'\''\n'
    fi
}

detach_card() {
    local force=0 result deadline guest_status=0
    while (($#)); do
        case $1 in
            --force) force=1 ;;
            --help|-h) usage; return 0 ;;
            *) die "usage: ./rlink-qemu sd-detach [--force]" ;;
        esac
        shift
    done

    need_cmd docker
    need_cmd python3
    container_running || die "container $NAME is not running"
    monitor_output 'info status' >/dev/null
    [[ "$SD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "SD_TIMEOUT must be a positive integer"

    if ! block_attached && ! device_attached; then
        note "no removable card is attached"
        return 0
    fi

    set +e
    python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout "$SD_TIMEOUT" -- \
        'mountpoints=$(grep "^/dev/block/vold/.* /mnt/" /proc/mounts | cut -d " " -f 2); for mountpoint in $mountpoints; do sync; vdc volume unmount "$mountpoint" force || exit $?; done; i=0; while grep -q "^/dev/block/vold/.* /mnt/" /proc/mounts && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done; ! grep -q "^/dev/block/vold/.* /mnt/" /proc/mounts' \
        >/dev/null 2>&1
    guest_status=$?
    set -e
    if (( guest_status != 0 )); then
        if (( force == 0 )); then
            die "could not confirm a clean guest unmount; retry or use sd-detach --force"
        fi
        warn "proceeding without a confirmed guest unmount"
    fi

    if device_attached; then
        result=$(monitor_output "device_del $SD_DEVICE_ID")
        [[ -z "$result" ]] || warn "QEMU device_del response: $result"
        deadline=$((SECONDS + SD_TIMEOUT))
        while (( SECONDS < deadline )); do
            device_attached || break
            sleep 1
        done
        device_attached && die "QEMU did not remove USB device $SD_DEVICE_ID"
    fi

    if block_attached; then
        result=$(monitor_output "drive_del $SD_DRIVE_ID")
        [[ -z "$result" || "$result" == *OK* ]] \
            || warn "QEMU drive_del response: $result"
        deadline=$((SECONDS + SD_TIMEOUT))
        while (( SECONDS < deadline )); do
            block_attached || break
            sleep 1
        done
        block_attached && die "QEMU did not remove block backend $SD_DRIVE_ID"
    fi

    note "detached removable card"
}

(($#)) || { usage >&2; exit 1; }
operation=$1
shift
case $operation in
    create) create_card "$@" ;;
    attach) attach_card "$@" ;;
    detach) detach_card "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "unknown SD operation: $operation" ;;
esac
