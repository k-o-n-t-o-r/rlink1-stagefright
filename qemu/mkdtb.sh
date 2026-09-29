#!/usr/bin/env bash
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

need_cmd dtc
need_file "$QEMU_DIR/rlink.dts"

temporary=$(mktemp "$QEMU_DIR/.rlink.dtb.XXXXXX")
trap 'rm -f "$temporary"' EXIT
dtc -q -I dts -O dtb -o "$temporary" "$QEMU_DIR/rlink.dts"
chmod 0644 "$temporary"
mv -f "$temporary" "$QEMU_DIR/rlink.dtb"
trap - EXIT
note "built $QEMU_DIR/rlink.dtb ($(stat -c %s "$QEMU_DIR/rlink.dtb") bytes)"
