#!/usr/bin/env bash
# Hotplug one physical Android phone through QEMU's libusb host backend.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

readonly DEVICE_ID=androidphone
readonly DEFAULT_GUEST_BUS=${USB_PHONE_GUEST_BUS:-usb-bus.2}

usage() {
    cat <<'EOF'
Usage:
  ./rlink-qemu usb-attach [HOST_BUS HOST_PORT]
  ./rlink-qemu usb-detach
  ./rlink-qemu usb-status

HOST_PORT is the stable physical libusb path (for example 5.4), not the
changing USB device address. Defaults may be set with USB_PHONE_BUS and
USB_PHONE_PORT in config.env.
EOF
}

monitor_output() {
    "$QEMU_DIR/mon.sh" "$1"
}

device_attached() {
    monitor_output 'info qtree' | grep -q "id \"$DEVICE_ID\""
}

resolve_location() {
    local bus=${1:-${USB_PHONE_BUS:-}} port=${2:-${USB_PHONE_PORT:-}}
    [[ -n "$bus" && -n "$port" ]] \
        || die "specify HOST_BUS HOST_PORT or set USB_PHONE_BUS/USB_PHONE_PORT"
    [[ "$bus" =~ ^[0-9]+$ ]] || die "invalid USB host bus: $bus"
    [[ "$port" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "invalid USB physical port: $port"
    printf '%s %s\n' "$bus" "$port"
}

host_device_summary() {
    local bus=$1 port=$2 dir vendor product
    for dir in /sys/bus/usb/devices/*; do
        [[ -f "$dir/busnum" && -f "$dir/devpath" ]] || continue
        [[ $(<"$dir/busnum") == "$bus" && $(<"$dir/devpath") == "$port" ]] || continue
        vendor=$(<"$dir/idVendor")
        product=$(<"$dir/idProduct")
        printf '%s:%s at bus %s port %s (%s)\n' "$vendor" "$product" "$bus" "$port" "${dir##*/}"
        return 0
    done
    return 1
}

attach_phone() {
    local bus port result deadline
    read -r bus port < <(resolve_location "$@")
    container_running || die "container $NAME is not running"
    [[ "$USB_PASSTHROUGH" == 1 ]] \
        || die "USB passthrough is disabled; set USB_PASSTHROUGH=1 and restart QEMU"
    [[ -d /dev/bus/usb ]] || die "/dev/bus/usb is unavailable"

    if ! host_device_summary "$bus" "$port"; then
        die "no host USB device is present at bus $bus port $port"
    fi
    if monitor_output 'info usbhost' | grep -q 'not supported'; then
        die "this QEMU build has no libusb host backend; rebuild with ./build-qemu.sh"
    fi
    if device_attached; then
        die "$DEVICE_ID is already attached (run usb-detach first)"
    fi

    # The host adb server can retain the ADB interface and make libusb claim
    # fail. It restarts automatically the next time adb is used.
    command -v adb >/dev/null 2>&1 && adb kill-server >/dev/null 2>&1 || true

    # Android's accessory gadget performs a hard disconnect/re-enumeration
    # for a physical USB reset.  Do not mirror the guest controller's normal
    # enumeration reset onto the already-enumerated host device, or the guest
    # loses the phone before its first Android Auto bulk transfer.
    result=$(monitor_output \
        "device_add usb-host,id=$DEVICE_ID,bus=$DEFAULT_GUEST_BUS,hostbus=$bus,hostport=$port,suppress-reset=on")
    [[ -z "$result" || "$result" == *OK* ]] \
        || die "QEMU rejected the phone: $result"

    deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        device_attached && break
        sleep 1
    done
    device_attached || die "QEMU did not retain $DEVICE_ID"

    note "forwarding physical USB bus $bus port $port to $DEFAULT_GUEST_BUS"
    printf '    re-enumeration is matched by physical port, so Android Accessory mode can reconnect\n'
}

detach_phone() {
    local result deadline
    container_running || die "container $NAME is not running"
    if ! device_attached; then
        note "no Android phone is attached"
        return 0
    fi
    result=$(monitor_output "device_del $DEVICE_ID")
    [[ -z "$result" || "$result" == *OK* ]] \
        || warn "QEMU device_del response: $result"
    deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        device_attached || break
        sleep 1
    done
    device_attached && die "QEMU did not remove $DEVICE_ID"
    note "detached Android phone"
}

status_phone() {
    local bus port
    container_running || die "container $NAME is not running"
    if [[ -n ${USB_PHONE_BUS:-} && -n ${USB_PHONE_PORT:-} ]]; then
        bus=$USB_PHONE_BUS
        port=$USB_PHONE_PORT
        printf 'Configured host device: '
        host_device_summary "$bus" "$port" || printf 'not currently present (bus %s port %s)\n' "$bus" "$port"
    fi
    if device_attached; then
        printf 'QEMU device %s: attached\n' "$DEVICE_ID"
    else
        printf 'QEMU device %s: detached\n' "$DEVICE_ID"
    fi
    monitor_output 'info usb'
}

(($#)) || { usage >&2; exit 1; }
operation=$1
shift
case $operation in
    attach) (($# == 0 || $# == 2)) || die "usb-attach accepts either zero or two arguments"; attach_phone "$@" ;;
    detach) (($# == 0)) || die "usb-detach accepts no arguments"; detach_phone ;;
    status) (($# == 0)) || die "usb-status accepts no arguments"; status_phone ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "unknown USB phone operation: $operation" ;;
esac
