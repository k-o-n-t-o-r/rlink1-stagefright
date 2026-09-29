#!/usr/bin/env bash
# Control the opt-in mediaserver dlmalloc tracer.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: ./heap-trace.sh <start|arm|disarm|stop|show|clear|status>

Start the traced mediaserver first, then arm immediately before the parser
request. The tracer records a dlmalloc walk around each armed zero/single-byte
allocation and raw headers for the first 64 subsequent frees. Output is stored at:
  /data/local/tmp/mediaserver-heaptrace.log

Tracing perturbs process startup and should be used only for diagnostics.
EOF
}

guest() {
    python3 "$QEMU_DIR/guest-exec.py" --port "$SHELL_PORT" --timeout 30 -- "$1"
}

operation=${1:-}
case $operation in
    start)
        container_running || die "container $NAME is not running"
        note "starting traced mediaserver"
        guest 'stop media-trace; stop media; rm /data/local/tmp/mediaserver-heaptrace.arm 2>/dev/null || true; rm /data/local/tmp/mediaserver-heaptrace.log 2>/dev/null || true; : > /data/local/tmp/mediaserver-heaptrace.log; chown media.system /data/local/tmp/mediaserver-heaptrace.log; chmod 0666 /data/local/tmp/mediaserver-heaptrace.log; start media-trace; i=0; while [ "$i" -lt 20 ]; do pid=$(pidof mediaserver-trace); if [ -n "$pid" ] && grep -q "/system/lib/libq.so" /proc/$pid/maps; then break; fi; sleep 1; i=$((i + 1)); done; pid=$(pidof mediaserver-trace); [ -n "$pid" ] || exit 1; grep -q "/system/lib/libq.so" /proc/$pid/maps; echo pid=$pid'
        note "arm before the parser request: ./rlink-qemu heap-trace-arm"
        note "trace log: ./rlink-qemu heap-trace-show"
        ;;
    arm)
        container_running || die "container $NAME is not running"
        guest ': > /data/local/tmp/mediaserver-heaptrace.arm; chown media.system /data/local/tmp/mediaserver-heaptrace.arm; chmod 0666 /data/local/tmp/mediaserver-heaptrace.arm'
        note "heap tracer armed"
        ;;
    disarm)
        container_running || die "container $NAME is not running"
        guest 'rm /data/local/tmp/mediaserver-heaptrace.arm 2>/dev/null || true'
        note "heap tracer disarmed"
        ;;
    stop)
        container_running || die "container $NAME is not running"
        note "restoring normal mediaserver"
        guest 'stop media-trace; stop media; start media; i=0; while [ -z "$(pidof mediaserver)" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done; pid=$(pidof mediaserver); [ -n "$pid" ] || exit 1; echo pid=$pid'
        ;;
    show)
        container_running || die "container $NAME is not running"
        guest 'cat /data/local/tmp/mediaserver-heaptrace.log'
        ;;
    clear)
        container_running || die "container $NAME is not running"
        guest ': > /data/local/tmp/mediaserver-heaptrace.log; chmod 0666 /data/local/tmp/mediaserver-heaptrace.log'
        ;;
    status)
        container_running || die "container $NAME is not running"
        guest 'pid=$(pidof mediaserver-trace); [ -n "$pid" ] || pid=$(pidof mediaserver); echo pid=$pid; if [ -n "$pid" ]; then grep "/system/lib/libq.so" /proc/$pid/maps || true; fi; ls -l /data/local/tmp/mediaserver-heaptrace.log 2>/dev/null || true'
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
