#!/usr/bin/env python3
"""Add the optional libq.so heap tracer to a copy of mediaserver."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct

EXPECTED_SHA256 = "56e3e4c90de9d0709101faa720e6238b29282eace9d0046b19ea67f10fc2e756"
STRING_FILE_OFFSET = 0x718
STRING_VADDR = 0x8718
STRTAB_VADDR = 0x835C
DYNAMIC_NULL_FILE_OFFSET = 0x10EC
LIBRARY = b"libq.so\0"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = bytearray(args.source.read_bytes())
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit(
            f"unexpected mediaserver SHA-256 {digest}; expected {EXPECTED_SHA256}"
        )
    if data[STRING_FILE_OFFSET : STRING_FILE_OFFSET + len(LIBRARY)] != bytes(
        len(LIBRARY)
    ):
        raise SystemExit("mediaserver string padding is not empty")
    if struct.unpack_from("<II", data, DYNAMIC_NULL_FILE_OFFSET) != (0, 0):
        raise SystemExit("expected DT_NULL entry is missing")
    if struct.unpack_from("<II", data, DYNAMIC_NULL_FILE_OFFSET + 8) != (0, 0):
        raise SystemExit("no spare dynamic entry remains for DT_NULL")

    data[STRING_FILE_OFFSET : STRING_FILE_OFFSET + len(LIBRARY)] = LIBRARY
    struct.pack_into(
        "<II",
        data,
        DYNAMIC_NULL_FILE_OFFSET,
        1,  # DT_NEEDED
        STRING_VADDR - STRTAB_VADDR,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(hashlib.sha256(data).hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
