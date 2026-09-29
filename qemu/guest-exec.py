#!/usr/bin/env python3
"""Run one command through the debug UART shell and return its exit status."""

from __future__ import annotations

import argparse
import re
import secrets
import socket
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="+", help="shell command")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2323)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()

    command = " ".join(args.command)
    nonce = secrets.token_hex(8)
    begin = f"__RLINK_BEGIN_{nonce}__"
    end = f"__RLINK_END_{nonce}__"
    payload = (
        f"\r\necho {begin}; {command}; __rlink_rc=$?; "
        f"echo {end}:$__rlink_rc\r\n"
    ).encode()

    deadline = time.monotonic() + args.timeout
    try:
        client = socket.create_connection((args.host, args.port), min(args.timeout, 5.0))
    except OSError as error:
        print(f"guest shell unavailable at {args.host}:{args.port}: {error}", file=sys.stderr)
        return 125

    client.settimeout(0.25)
    client.sendall(payload)
    data = bytearray()
    end_pattern = re.compile(rb"__RLINK_END_" + nonce.encode() + rb"__:(\d+)")
    status: int | None = None
    while time.monotonic() < deadline:
        try:
            chunk = client.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        data.extend(chunk)
        matches = list(end_pattern.finditer(data))
        if matches:
            status = int(matches[-1].group(1))
            break
    client.close()

    text = data.decode("utf-8", "replace").replace("\r", "")
    lines = text.splitlines()
    start_index = None
    end_index = None
    for index, line in enumerate(lines):
        normalized = re.sub(r"^(?:#\s*)+", "", line).strip()
        if start_index is None and normalized == begin:
            start_index = index + 1
            continue
        if start_index is not None and re.fullmatch(re.escape(end) + r":\d+", normalized):
            end_index = index
            break

    if start_index is not None:
        selected = lines[start_index:end_index]
        while selected and re.fullmatch(r"(?:#\s*)+", selected[-1]):
            selected.pop()
        if selected:
            print("\n".join(selected))
    elif status is None:
        print(text, end="" if text.endswith("\n") else "\n", file=sys.stderr)

    if status is None:
        print(f"guest command timed out after {args.timeout:g}s", file=sys.stderr)
        return 124
    return status


if __name__ == "__main__":
    raise SystemExit(main())
