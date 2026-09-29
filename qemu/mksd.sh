#!/usr/bin/env bash
# Build the raw emulated eMMC image without loop devices or root privileges.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

for command in truncate sfdisk mkfs.fat mke2fs stat dd; do
    need_cmd "$command"
done
need_file "$QEMU_DIR/staging/p2/rootfs.img"
need_file "$QEMU_DIR/staging/p2/rootfs.img.rw"

if command -v docker >/dev/null 2>&1 && container_running; then
    die "container $NAME is running; stop it before replacing sd.img"
fi

size=$EMMC_SIZE
out="$QEMU_DIR/sd.img"
tmp=$(mktemp "$QEMU_DIR/.sd.img.XXXXXX")
p1_tmp="$tmp.p1"
trap 'rm -f "$tmp" "$p1_tmp"' EXIT
truncate -s "$size" "$tmp"

bytes=$(stat -c %s "$tmp")
(( bytes % 512 == 0 )) || die "EMMC_SIZE must be a multiple of 512 bytes"
total_sectors=$((bytes / 512))
p1_start=2048
p1_sectors=131072
p2_start=$((p1_start + p1_sectors))
p2_sectors=$((total_sectors - p2_start))
(( p2_sectors > 0 && p2_sectors % 8 == 0 )) || die "EMMC_SIZE is too small or misaligned"

note "partitioning $size eMMC image"
printf 'label: dos\nstart=%d, size=%d, type=c\nstart=%d, size=%d, type=83\n' \
    "$p1_start" "$p1_sectors" "$p2_start" "$p2_sectors" | sfdisk -q "$tmp"

# Format p1 separately so mkfs.fat cannot mistake the rest of the disk for its
# partition. One-sector clusters keep this small FAT32 volume standards-compliant.
truncate -s "$((p1_sectors * 512))" "$p1_tmp"
mkfs.fat -F 32 -s 1 -n RLINKBOOT "$p1_tmp" >/dev/null
dd if="$p1_tmp" of="$tmp" bs=512 seek="$p1_start" conv=notrunc,sparse status=none

# mke2fs gets an explicit 4 KiB block count and writes at the p2 byte offset.
mke2fs -q -F -t ext3 -b 4096 -L internalstorage -m 0 \
    -O '^64bit,^metadata_csum' -E "offset=$((p2_start * 512))" \
    -d "$QEMU_DIR/staging/p2" "$tmp" "$((p2_sectors / 8))"

chmod 0644 "$tmp"
mv -f "$tmp" "$out"
rm -f "$p1_tmp"
trap - EXIT
note "built $out"
ls -lh "$out"
du -h "$out"
