#!/usr/bin/env python3
"""Send one absolute left-button tap to the local R-LINK VNC display."""

from __future__ import annotations

import argparse
import socket
import struct
import time

POINTER_TYPE_CHANGE = -257


def read_exact(client: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = client.recv(size - len(data))
        if not chunk:
            raise RuntimeError("VNC server closed the connection")
        data.extend(chunk)
    return bytes(data)


def negotiate(client: socket.socket) -> tuple[int, int]:
    version = read_exact(client, 12)
    if not version.startswith(b"RFB 003."):
        raise RuntimeError(f"unsupported VNC banner: {version!r}")
    client.sendall(version)
    minor = int(version[8:11])

    if minor >= 7:
        count = read_exact(client, 1)[0]
        if count == 0:
            length = struct.unpack(">I", read_exact(client, 4))[0]
            reason = read_exact(client, length).decode("utf-8", "replace")
            raise RuntimeError(f"VNC security negotiation failed: {reason}")
        security_types = read_exact(client, count)
        if 1 not in security_types:
            raise RuntimeError("VNC server does not offer unauthenticated local access")
        client.sendall(b"\x01")
        result = struct.unpack(">I", read_exact(client, 4))[0]
        if result:
            raise RuntimeError(f"VNC security handshake failed with status {result}")
    else:
        security_type = struct.unpack(">I", read_exact(client, 4))[0]
        if security_type != 1:
            raise RuntimeError(f"unsupported VNC security type: {security_type}")

    client.sendall(b"\x01")  # shared ClientInit
    server_init = read_exact(client, 24)
    width, height = struct.unpack(">HH", server_init[:4])
    name_length = struct.unpack(">I", server_init[20:24])[0]
    read_exact(client, name_length)

    # QEMU otherwise treats a bare RFB client's coordinates as relative. This
    # pseudo-encoding switches VNC to the absolute mode used by touchscreens.
    client.sendall(struct.pack(">BBHi", 2, 0, 1, POINTER_TYPE_CHANGE))
    time.sleep(0.05)
    return width, height


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("x", type=int, help="LCD X coordinate")
    parser.add_argument("y", type=int, help="LCD Y coordinate")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5900)
    parser.add_argument("--hold", type=float, default=0.12,
                        help="button hold time in seconds (default: 0.12)")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    if args.hold < 0:
        parser.error("--hold cannot be negative")

    with socket.create_connection((args.host, args.port), args.timeout) as client:
        client.settimeout(args.timeout)
        width, height = negotiate(client)
        if not (0 <= args.x < width and 0 <= args.y < height):
            parser.error(
                f"coordinates {args.x},{args.y} are outside {width}x{height}"
            )
        pointer = struct.Struct(">BBHH")
        client.sendall(pointer.pack(5, 1, args.x, args.y))
        time.sleep(args.hold)
        client.sendall(pointer.pack(5, 0, args.x, args.y))
        time.sleep(0.02)

    print(f"tapped {args.x},{args.y} on {width}x{height}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
