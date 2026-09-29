#!/usr/bin/env bash
# Compatibility wrapper for the recommended debug boot.
set -euo pipefail
QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$QEMU_DIR/run.sh" --debug -- "$@"
