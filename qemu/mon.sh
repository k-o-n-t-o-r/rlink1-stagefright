#!/usr/bin/env bash
# Send one command to the QEMU human monitor over its host Unix socket.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

(($#)) || die 'usage: ./mon.sh "info registers"'
socket="$QEMU_DIR/$NAME.mon.sock"
command=$*

python3 - "$socket" "$command" "${MONITOR_TIMEOUT:-5}" <<'PY'
from __future__ import annotations

import os
import re
import socket
import sys
import time

path, command, timeout_text = sys.argv[1:]
timeout = float(timeout_text)
deadline = time.monotonic() + timeout

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
while True:
    try:
        client.connect(path)
        break
    except (FileNotFoundError, ConnectionRefusedError) as error:
        if time.monotonic() >= deadline:
            raise SystemExit(f"monitor unavailable at {path}: {error}")
        time.sleep(0.1)
client.settimeout(0.25)


def receive_prompt() -> bytes:
    data = bytearray()
    while time.monotonic() < deadline:
        try:
            chunk = client.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        data.extend(chunk)
        if data.rstrip().endswith(b"(qemu)"):
            break
    return bytes(data)


receive_prompt()  # banner and initial prompt
deadline = time.monotonic() + timeout
client.sendall(command.encode("utf-8") + b"\n")
raw = receive_prompt().decode("utf-8", "replace")
client.close()
# Readline redraws the whole command after every byte. Everything before the
# first CRLF is terminal echo, not monitor output.
lines = re.split(r"\r\n|\n", raw)
if lines:
    lines.pop(0)
clean = []
for line in lines:
    line = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", line)
    line = line.replace("(qemu) ", "", 1).replace("\r", "")
    if line.strip() in {"(qemu)", command}:
        continue
    clean.append(line.rstrip())
while clean and not clean[-1]:
    clean.pop()
if clean:
    print("\n".join(clean))
PY
