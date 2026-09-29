#!/usr/bin/env bash
# Capture the emulated 800x480 LCD through QEMU's graphics console.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

if (($# > 1)); then
    die "usage: ./screenshot.sh [output.png|output.ppm]"
fi
output=${1:-$QEMU_DIR/screenshots/rlink-$(date +%Y%m%d-%H%M%S).png}
mkdir -p "$(dirname "$output")"
tmp_name=".$NAME.screenshot.$$.ppm"
tmp="$QEMU_DIR/$tmp_name"
trap 'rm -f "$tmp"' EXIT
rm -f "$tmp"
"$QEMU_DIR/mon.sh" "screendump /work/rlink/$tmp_name" >/dev/null
[[ -s "$tmp" ]] || die "QEMU did not produce a screenshot"

case ${output##*.} in
    ppm|PPM)
        mv -f "$tmp" "$output"
        ;;
    png|PNG)
        python3 - "$tmp" "$output" <<'PY'
from pathlib import Path
import binascii
import struct
import sys
import zlib

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
if not data.startswith(b"P6"):
    raise SystemExit("unsupported screendump format")

# Tokenize the small PPM header while respecting comments.
pos = 2
tokens = []
while len(tokens) < 3:
    while pos < len(data) and data[pos] in b" \t\r\n":
        pos += 1
    if pos < len(data) and data[pos] == ord("#"):
        pos = data.find(b"\n", pos) + 1
        continue
    end = pos
    while end < len(data) and data[end] not in b" \t\r\n":
        end += 1
    tokens.append(int(data[pos:end]))
    pos = end
if data[pos : pos + 2] == b"\r\n":
    pos += 2
elif pos < len(data) and data[pos] in b" \t\r\n":
    pos += 1
else:
    raise SystemExit("invalid PPM header")
width, height, maximum = tokens
if maximum != 255 or len(data) - pos != width * height * 3:
    raise SystemExit("invalid PPM screendump")
pixels = data[pos:]
rows = b"".join(b"\0" + pixels[y * width * 3 : (y + 1) * width * 3] for y in range(height))


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows, 9))
png += chunk(b"IEND", b"")
destination.write_bytes(png)
PY
        ;;
    *)
        die "output extension must be .png or .ppm"
        ;;
esac
trap - EXIT
rm -f "$tmp"
note "captured $output"
file "$output" 2>/dev/null || true
