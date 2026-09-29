#!/usr/bin/env python3
"""Find dlmalloc chunks containing selected addresses in a QHEAP trace."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

RECORD = re.compile(
    r"^QHEAP (?P<tag>USED|FREE) "
    r"a=(?P<chunk>0x[0-9a-f]+) b=(?P<chunklen>0x[0-9a-f]+) "
    r"c=(?P<user>0x[0-9a-f]+) d=(?P<userlen>0x[0-9a-f]+) "
    r"e=(?P<head>0x[0-9a-f]+)$"
)


def number(text: str) -> int:
    return int(text, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("addresses", nargs="+", type=number)
    args = parser.parse_args()

    records: list[tuple[str, int, int, int, int, int]] = []
    for line in args.trace.read_text(errors="replace").splitlines():
        match = RECORD.match(line)
        if match:
            records.append(
                (
                    match["tag"],
                    number(match["chunk"]),
                    number(match["chunklen"]),
                    number(match["user"]),
                    number(match["userlen"]),
                    number(match["head"]),
                )
            )

    status = 0
    for address in args.addresses:
        matches = [
            record
            for record in records
            if record[1] <= address < record[1] + record[2]
        ]
        print(f"{address:#010x}:")
        if not matches:
            print("  no containing chunk in captured windows")
            status = 1
            continue
        for tag, chunk, chunklen, user, userlen, head in matches:
            relation = (
                f"user+{address - user:#x}"
                if user and user <= address < user + userlen
                else f"chunk+{address - chunk:#x}"
            )
            print(
                f"  {tag:<4} chunk={chunk:#010x} size={chunklen:#x} "
                f"user={user:#010x} usable={userlen:#x} head={head:#x} "
                f"({relation})"
            )
    return status


if __name__ == "__main__":
    raise SystemExit(main())
