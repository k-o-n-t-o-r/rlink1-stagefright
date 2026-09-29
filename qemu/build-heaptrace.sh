#!/usr/bin/env bash
# Rebuild the optional ARM/Froyo mediaserver heap tracer.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
source_file="$QEMU_DIR/diagnostics/heaptrace.c"
output=${1:-$QEMU_DIR/overlay/lib/libq.so}

if [[ -n ${ANDROID_NDK_ROOT:-} ]]; then
    ndk=$ANDROID_NDK_ROOT
else
    ndk=$(find /opt/android-sdk/ndk -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort -V | tail -1)
fi
[[ -n ${ndk:-} && -d "$ndk" ]] || {
    printf 'error: Android NDK not found; set ANDROID_NDK_ROOT\n' >&2
    exit 1
}

toolchain="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
cc="$toolchain/armv7a-linux-androideabi21-clang"
strip="$toolchain/llvm-strip"
[[ -x "$cc" && -x "$strip" ]] || {
    printf 'error: ARM clang toolchain missing under %s\n' "$toolchain" >&2
    exit 1
}

temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
mkdir -p "$(dirname "$output")"

"$cc" -Os -fPIC -fno-stack-protector -shared -nostdlib \
    -Wl,--build-id=none -Wl,-soname,libq.so -Wl,--hash-style=sysv \
    -Wl,--no-rosegment -Wl,-z,lazy -Wl,-z,norelro \
    -Wl,--unresolved-symbols=ignore-all -Wl,--no-as-needed \
    -L"$QEMU_DIR/../temp/rootfs/lib" -l:libc.so \
    -o "$temporary" "$source_file"
# Modern LLVM sets EF_ARM_DYNSYMSUSESEGIDX, which Froyo's 2010 linker does not
# understand. Match the firmware DSOs' ARM EABI flags exactly.
python3 - "$temporary" <<'PY'
from pathlib import Path
import struct
import sys
path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
struct.pack_into("<I", data, 0x24, 0x05000002)
path.write_bytes(data)
PY
"$strip" --strip-unneeded "$temporary"

file "$temporary" | grep -q 'ELF 32-bit LSB shared object, ARM' 
readelf -Ws "$temporary" | grep -q ' __libc_malloc_dispatch$'
readelf -d "$temporary" | grep -q 'libc.so'
chmod 0644 "$temporary"
mv -f -- "$temporary" "$output"
trap - EXIT
sha256sum "$output"
