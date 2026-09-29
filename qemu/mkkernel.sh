#!/usr/bin/env bash
# Extract the raw ARM Image from zImage and apply the debug security patches.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

check=0
if [[ ${1:-} == --check ]]; then
    check=1
    shift
fi

src=${1:-$QEMU_DIR/zImage}
image=${2:-$QEMU_DIR/Image}
debug=${3:-$QEMU_DIR/Image-debug}
need_file "$src"

python3 - "$src" "$image" "$debug" "$check" <<'PY'
from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import os
import zlib

src, image_path, debug_path = map(Path, sys.argv[1:4])
check = sys.argv[4] == "1"
EXPECTED_ZIMAGE = "cf5333cadce30b4e2ce6a10cc17305cdacbbe4594320d47d9fafee8257be0f17"
EXPECTED_IMAGE = "d116743ff9c6d06555cde05889babef4a4ac15550765e63ca45656a15bce9611"
EXPECTED_DEBUG = "b1c74c2106b9e4973bdc3c0d3b52b5c08af8bd4bd042ae8deb1ba5ad93b46fa1"
BASE = 0xC0008000
MOV_R0_0 = 0xE3A00000
BX_LR = 0xE12FFF1E
PATCHES = {
    0xC022A3C8: ([0xE92D41F0, 0xE3A01001], [MOV_R0_0, BX_LR]),
    0xC0229DB0: ([0xE92D4010], [BX_LR]),
    0xC0229DA8: ([0xE3E00000, BX_LR], [MOV_R0_0, BX_LR]),
    0xC01A4AB0: ([0xE92D4FF0, 0xE24DDFD9], [MOV_R0_0, BX_LR]),
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_zimage(data: bytes) -> bytes:
    # The ARM decompressor is followed by one gzip member and a short trailer.
    start = 0
    while True:
        start = data.find(b"\x1f\x8b\x08", start)
        if start < 0:
            raise ValueError("no valid gzip-compressed kernel found in zImage")
        try:
            stream = zlib.decompressobj(16 + zlib.MAX_WBITS)
            result = stream.decompress(data[start:]) + stream.flush()
            if len(result) > 5_000_000 and b"Linux version 2.6.32.9" in result:
                return result
        except zlib.error:
            pass
        start += 1


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


zimage = src.read_bytes()
if sha(zimage) != EXPECTED_ZIMAGE:
    raise SystemExit(
        f"unsupported zImage sha256={sha(zimage)}; expected {EXPECTED_ZIMAGE}"
    )
image = extract_zimage(zimage)
if sha(image) != EXPECTED_IMAGE:
    raise SystemExit(
        f"extracted Image sha256={sha(image)}; expected {EXPECTED_IMAGE}"
    )

patched = bytearray(image)
for address, (expected_words, replacement_words) in PATCHES.items():
    offset = address - BASE
    expected = struct.pack("<" + "I" * len(expected_words), *expected_words)
    actual = bytes(patched[offset : offset + len(expected)])
    if actual != expected:
        raise SystemExit(
            f"unexpected kernel bytes at 0x{address:08x}: {actual.hex()} "
            f"(expected {expected.hex()})"
        )
    replacement = struct.pack("<" + "I" * len(replacement_words), *replacement_words)
    patched[offset : offset + len(replacement)] = replacement
patched = bytes(patched)
if sha(patched) != EXPECTED_DEBUG:
    raise SystemExit("internal error: patched Image hash does not match")

if check:
    for path, expected in ((image_path, EXPECTED_IMAGE), (debug_path, EXPECTED_DEBUG)):
        if not path.is_file():
            raise SystemExit(f"missing {path}")
        actual = sha(path.read_bytes())
        if actual != expected:
            raise SystemExit(f"bad sha256 for {path}: {actual}, expected {expected}")
    print(f"kernel artifacts verified: {image_path}, {debug_path}")
else:
    write_atomic(image_path, image)
    write_atomic(debug_path, patched)
    print(f"wrote {image_path} ({len(image)} bytes)")
    print(f"wrote {debug_path} ({len(patched)} bytes)")
PY
