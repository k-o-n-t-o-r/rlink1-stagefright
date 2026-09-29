#!/usr/bin/env bash
# End-to-end health check for a running debug VM.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

timeout=${1:-$BOOT_TIMEOUT}
"$QEMU_DIR/wait.sh" "$timeout"

note "checking guest identity and services"
identity=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 10 -- id)
grep -q 'uid=0(root)' <<<"$identity" || die "UART shell is not root: $identity"

properties=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
    'getprop ro.product.model; getprop init.svc.zygote; getprop dev.bootcomplete')
grep -q 'TomTom Strasbourg' <<<"$properties" || die "unexpected product properties"
grep -q '^running$' <<<"$properties" || die "zygote is not running"
grep -q '^1$' <<<"$properties" || die "Android did not report boot completion"

note "checking factory/EOL language"
eeprom_mmi=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
    '/system/bin/busybox od -An -tu1 -j 259 -N 1 /sys/devices/platform/i2c_omap.3/i2c-3/3-0050/eeprom')
eeprom_mmi=${eeprom_mmi//[[:space:]]/}
expected_mmi=$((10#$EOL_MMI_LANGUAGE))
[[ "$eeprom_mmi" == "$expected_mmi" ]] \
    || die "EEPROM MmiLanguage is $eeprom_mmi, expected $expected_mmi"
if (( expected_mmi == 3 )); then
    locale_state=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
        'getprop persist.sys.language; getprop persist.sys.country; dumpsys activity | grep "mConfiguration:" | head -1')
    grep -q '^de$' <<<"$locale_state" || die "Android language is not German: $locale_state"
    grep -q '^DE$' <<<"$locale_state" || die "Android country is not Germany: $locale_state"
    grep -q 'loc=de_DE' <<<"$locale_state" \
        || die "active Android configuration is not de_DE: $locale_state"
fi

if [[ "$TOUCHSCREEN" == 1 ]]; then
    note "checking TSC2007 touchscreen"
    touchscreen_state=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
        'cat /proc/bus/input/devices; cat /data/misc/touchscreen/pointercal; echo')
    grep -q 'Name="TSC2007 Touchscreen"' <<<"$touchscreen_state" \
        || die "TSC2007 input device is missing: $touchscreen_state"
    grep -q -- '-13517 26 53414312 44 -8383 32074952 65536' \
        <<<"$touchscreen_state" \
        || die "factory touchscreen calibration is missing: $touchscreen_state"
fi

assert_home_ui() {
    local state
    state=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
        'echo ready=$(getprop qemu.ui.ready); dumpsys activity activities | grep mResumedActivity')
    grep -q '^ready=1$' <<<"$state" || die "QEMU UI setup did not complete: $state"
    grep -q 'mResumedActivity:.*com.tomtom.focus.client/com.tomtom.home.HomeActivity' \
        <<<"$state" || die "TomTom home activity is not in front: $state"
}

assert_home_ui
if [[ "$TOUCHSCREEN" == 1 && "$VNC_PORT" != 0 ]]; then
    note "checking VNC-to-touchscreen input path"
    touch_irq_before=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
        'grep tsc2007 /proc/interrupts' | awk '{print $2}')
    [[ "$touch_irq_before" =~ ^[0-9]+$ ]] \
        || die "could not read the TSC2007 IRQ count: $touch_irq_before"
    python3 "$QEMU_DIR/vnc-tap.py" --port "$VNC_PORT" 344 240 >/dev/null
    sleep 1
    touch_irq_after=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
        'grep tsc2007 /proc/interrupts' | awk '{print $2}')
    [[ "$touch_irq_after" =~ ^[0-9]+$ ]] \
        || die "could not read the updated TSC2007 IRQ count: $touch_irq_after"
    (( touch_irq_after > touch_irq_before )) \
        || die "VNC tap did not trigger TSC2007 PENIRQ ($touch_irq_before -> $touch_irq_after)"
    assert_home_ui
fi
serial="$QEMU_DIR/$NAME.serial.log"
grep -q 'Machine: Strasbourg A2' "$serial" || die "kernel did not select Strasbourg A2"
! grep -q 'Kernel panic' "$serial" || die "kernel panic found in serial log"

assert_single_boot() {
    local count
    count=$(grep -c '^\[    0\.000000\] Linux version' "$serial" || true)
    (( count == 1 )) || die "guest rebooted during the test ($count kernel boots in the serial log)"
    if grep -q 'Watchdog\$PipeMonitor' "$serial"; then
        die "Android FIFO watchdog reboot found; rebuild sd.img with the current overlay"
    fi
}

assert_single_boot
if (( SMOKE_STABILITY_SECONDS > 0 )); then
    note "checking stability through $SMOKE_STABILITY_SECONDS seconds of guest uptime"
    deadline=$((SECONDS + timeout))
    while :; do
        assert_single_boot
        uptime_output=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 10 -- \
            'cat /proc/uptime')
        uptime_token=${uptime_output%%[[:space:]]*}
        guest_seconds=${uptime_token%%.*}
        [[ "$guest_seconds" =~ ^[0-9]+$ ]] || die "could not parse guest uptime: $uptime_output"
        (( guest_seconds >= SMOKE_STABILITY_SECONDS )) && break
        (( SECONDS < deadline )) \
            || die "guest did not reach the stability threshold before timeout"
        sleep 5
    done
    properties=$(python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 15 -- \
        'getprop init.svc.zygote; getprop dev.bootcomplete')
    grep -q '^running$' <<<"$properties" || die "zygote stopped during stability check"
    grep -q '^1$' <<<"$properties" || die "boot completion was lost during stability check"
    assert_home_ui
fi

note "checking QEMU monitor and LCD"
"$QEMU_DIR/mon.sh" 'info status' | grep -q 'running' || die "QEMU CPUs are not running"
temporary=$(mktemp "$QEMU_DIR/.smoke.XXXXXX.png")
trap 'rm -f "$temporary"' EXIT
"$QEMU_DIR/screenshot.sh" "$temporary" >/dev/null
python3 - "$temporary" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

data = Path(sys.argv[1]).read_bytes()
if not data.startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit("screenshot is not PNG")
width, height, depth, color_type = struct.unpack(">IIBB", data[16:26])
if (width, height) != (800, 480):
    raise SystemExit(f"unexpected LCD size: {width}x{height}")

idat = bytearray()
pos = 8
while pos < len(data):
    length = struct.unpack(">I", data[pos:pos + 4])[0]
    kind = data[pos + 4:pos + 8]
    payload = data[pos + 8:pos + 8 + length]
    if kind == b"IDAT":
        idat.extend(payload)
    pos += 12 + length
channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
if depth != 8 or channels is None:
    raise SystemExit(f"unsupported screenshot PNG format: depth={depth}, type={color_type}")
raw = zlib.decompress(idat)
row_bytes = width * channels
if len(raw) != height * (row_bytes + 1):
    raise SystemExit("malformed screenshot PNG data")
def paeth(a, b, c):
    estimate = a + b - c
    distances = (abs(estimate - a), abs(estimate - b), abs(estimate - c))
    return (a, b, c)[distances.index(min(distances))]

previous = bytearray(row_bytes)
non_black = False
for y in range(height):
    offset = y * (row_bytes + 1)
    method = raw[offset]
    filtered = raw[offset + 1:offset + 1 + row_bytes]
    row = bytearray(row_bytes)
    for i, value in enumerate(filtered):
        left = row[i - channels] if i >= channels else 0
        above = previous[i]
        upper_left = previous[i - channels] if i >= channels else 0
        if method == 0:
            predictor = 0
        elif method == 1:
            predictor = left
        elif method == 2:
            predictor = above
        elif method == 3:
            predictor = (left + above) // 2
        elif method == 4:
            predictor = paeth(left, above, upper_left)
        else:
            raise SystemExit(f"unknown PNG filter method: {method}")
        row[i] = (value + predictor) & 0xff
    if color_type in (0, 4):
        non_black |= any(row[0::channels])
    else:
        non_black |= any(
            row[p] or row[p + 1] or row[p + 2]
            for p in range(0, row_bytes, channels)
        )
    previous = row
if not non_black:
    raise SystemExit("LCD is a solid black frame")
PY

rm -f "$temporary"
trap - EXIT
note "smoke test passed: factory locale, touchscreen, stable Android framework, root shell, and visible 800x480 home UI"
