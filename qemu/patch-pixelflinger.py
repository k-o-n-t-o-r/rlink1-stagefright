#!/usr/bin/env python3
"""Make Froyo pixelflinger's generated ARM scanlines executable.

The production kernel deliberately gives malloc-backed heap pages NX permission.
Froyo's software renderer writes generated scanline functions into malloc memory
and then jumps to them, so forcing software EGL otherwise crashes SurfaceFlinger.

This firmware-specific patch redirects both Assembly constructors through a tiny
Thumb trampoline. The trampoline calls malloc and marks the allocation's pages
RWX with mprotect(2). It occupies the test-only ggl_test_codegen function, which
is not used by Android at runtime. Input bytes and whole-file hashes are checked
so this can never be silently applied to another build.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile

ORIGINAL_SHA256 = "cc02c60b993fb7504e98aa242daaae559d790f81f2d15dbc1269d3398bb679e1"
PATCHED_SHA256 = "41d0beac3d0a76818177d9ae3f4e6079f9a526a585f31b70faa3f21c5aaf7182"

# File offsets equal ELF virtual addresses for this shared object.
PATCHES = {
    # Test-only ggl_test_codegen -> exec_malloc trampoline.
    0xC0A4: (
        bytes.fromhex(
            "f0452de94bdf4de20040a0e1490f8de20170a0e10260a0e103a0a0e10df6ffeb2400"
        ),
        bytes.fromhex(
            "b0b50446fcf78aea054640b1214640f6ff731944030b180307227d2700df2846b0bd"
        ),
    ),
    # Assembly::Assembly(size_t), C1 and C2 variants -> trampoline.
    0xF368: (bytes.fromhex("f9f72ae9"), bytes.fromhex("fcf79cfe")),
    0xF3A4: (bytes.fromhex("f9f70ce9"), bytes.fromhex("fcf77efe")),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(data: bytes) -> bytes:
    current = digest(data)
    if current == PATCHED_SHA256:
        return data
    if current != ORIGINAL_SHA256:
        raise ValueError(
            "unsupported libpixelflinger.so: "
            f"sha256={current}, expected {ORIGINAL_SHA256}"
        )

    result = bytearray(data)
    for offset, (expected, replacement) in PATCHES.items():
        actual = bytes(result[offset : offset + len(expected)])
        if actual != expected:
            raise ValueError(
                f"unexpected bytes at 0x{offset:x}: {actual.hex()} "
                f"(expected {expected.hex()})"
            )
        result[offset : offset + len(replacement)] = replacement

    output = bytes(result)
    if digest(output) != PATCHED_SHA256:
        raise AssertionError("internal error: patched file hash does not match")
    return output


def atomic_write(path: Path, data: bytes, mode_from: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        shutil.copymode(mode_from, temporary)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument(
        "--check", action="store_true", help="only identify the input as original or patched"
    )
    args = parser.parse_args()

    data = args.input.read_bytes()
    current = digest(data)
    if args.check:
        if current == ORIGINAL_SHA256:
            print(f"original  {current}  {args.input}")
            return 0
        if current == PATCHED_SHA256:
            print(f"patched   {current}  {args.input}")
            return 0
        print(f"unknown   {current}  {args.input}", file=sys.stderr)
        return 1

    if args.output is None:
        parser.error("output is required unless --check is used")
    output = patch(data)
    atomic_write(args.output, output, args.input)
    print(f"patched libpixelflinger: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
