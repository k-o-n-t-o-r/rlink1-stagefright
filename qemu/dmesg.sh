#!/usr/bin/env bash
# Recover the guest printk buffer directly from RAM (also works before Android init).
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

dump="$QEMU_DIR/$NAME.mem.bin"
rm -f "$dump"
trap 'rm -f "$dump"' EXIT
"$QEMU_DIR/mon.sh" "pmemsave 0x80000000 0x1000000 \"/work/rlink/$NAME.mem.bin\"" >/dev/null
need_file "$dump"

python3 - "$dump" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
# Match timestamped printk records, not the same format strings embedded in
# the kernel text earlier in RAM.
markers = (
    b"<6>[    0.000000] Initializing cgroup subsys cpu",
    b"<5>[    0.000000] Linux version 2.6.32.9",
)
start = next((offset for marker in markers if (offset := data.find(marker)) >= 0), -1)
if start < 0:
    raise SystemExit("no R-LINK printk buffer found in the first 16 MiB of RAM")
buffer = data[start : start + 256 * 1024]
end = buffer.find(b"\0\0\0\0")
if end >= 0:
    buffer = buffer[:end]
sys.stdout.write(buffer.decode("latin-1", "replace").rstrip("\0") + "\n")
PY
