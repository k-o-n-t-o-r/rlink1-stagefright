#!/usr/bin/env bash
# Wait until the debug shell and Android framework are usable.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

timeout=${1:-$BOOT_TIMEOUT}
[[ "$timeout" =~ ^[0-9]+$ ]] || die "timeout must be an integer number of seconds"
need_cmd docker
container_running || die "container $NAME is not running"

deadline=$((SECONDS + timeout))
log="$QEMU_DIR/$NAME.serial.log"
note "waiting for the debug shell"
while ((SECONDS < deadline)); do
    if [[ -f "$log" ]] && grep -q 'enabling adb' "$log"; then
        if python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 5 \
            'test "$(getprop init.svc.qemu-shell)" = running' >/dev/null 2>&1; then
            break
        fi
    fi
    container_running || die "container $NAME stopped during boot"
    sleep 1
done
((SECONDS < deadline)) || die "timed out waiting for the debug shell after ${timeout}s"

note "waiting for Android boot completion"
while ((SECONDS < deadline)); do
    if python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 8 \
        'test "$(getprop dev.bootcomplete)" = 1 && test "$(getprop init.svc.zygote)" = running' \
        >/dev/null 2>&1; then
        break
    fi
    container_running || die "container $NAME stopped during boot"
    sleep 2
done
((SECONDS < deadline)) || {
    warn "last serial messages:"
    tail -n 20 "$log" >&2 || true
    die "timed out waiting for Android boot completion after ${timeout}s"
}

note "waiting for the TomTom home UI"
while ((SECONDS < deadline)); do
    if python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 8 \
        'test "$(getprop qemu.ui.ready)" = 1' >/dev/null 2>&1; then
        note "Android framework and TomTom UI are ready"
        exit 0
    fi
    container_running || die "container $NAME stopped while starting the UI"
    sleep 2
done

die "timed out waiting for the TomTom home UI after ${timeout}s"
