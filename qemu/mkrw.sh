#!/usr/bin/env bash
# Build the pristine and writable rootfs images with the QEMU overlay applied.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

need_cmd debugfs
need_cmd e2fsck
need_cmd python3
need_cmd sha256sum
need_file "$QEMU_DIR/overlay.manifest"
need_file "$QEMU_DIR/patch-pixelflinger.py"
need_file "$QEMU_DIR/patch-mediaserver-trace.py"
need_file "$QEMU_DIR/../scripts/patch_firmware_files.py"
need_file "$QEMU_DIR/diagnostics/heaptrace.c"
need_file "$QEMU_DIR/diagnostics/heaptrace.sha256"
(cd "$QEMU_DIR" && sha256sum -c diagnostics/heaptrace.sha256 >/dev/null) \
    || die "heap tracer source or binary failed checksum verification"

src=${1:-$(find_rootfs_source || true)}
[[ -n "$src" ]] || die "cannot find rootfs.img.new; pass its path or set ROOTFS_SOURCE"
need_file "$src"

out_dir="$QEMU_DIR/staging/p2"
out="$out_dir/rootfs.img.rw"
pristine="$out_dir/rootfs.img"
mkdir -p "$out_dir" "$out_dir/data" "$out_dir/cache"

tmp=$(mktemp -d "$QEMU_DIR/staging/.mkrw.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
work="$tmp/rootfs.img.rw"
pristine_tmp="$tmp/rootfs.img"
overlay_tmp="$tmp/overlay"
mkdir -p "$overlay_tmp"

note "copying pristine rootfs"
cp --reflink=auto --sparse=always "$src" "$work"
cp --reflink=auto --sparse=always "$src" "$pristine_tmp"
cp -a "$QEMU_DIR/overlay/." "$overlay_tmp/"

fsck_image() {
    local rc
    set +e
    e2fsck -pf "$1" >/dev/null 2>&1
    rc=$?
    set -e
    (( rc == 0 || rc == 1 )) || die "e2fsck failed for $1 (status $rc)"
}

fs_exists() {
    debugfs -R "stat $1" "$work" 2>/dev/null | grep -q '^Inode:'
}

debugfs_run() {
    local output
    if ! output=$(debugfs -w -R "$1" "$work" 2>&1); then
        printf '%s\n' "$output" >&2
        die "debugfs command failed: $1"
    fi
    if grep -Eq 'File not found|Could not allocate|already exists|Usage:|Command not found' <<<"$output"; then
        printf '%s\n' "$output" >&2
        die "debugfs command failed: $1"
    fi
}

make_guest_parents() {
    local guest=$1 current= part
    local parent=${guest%/*}
    IFS='/' read -r -a parts <<<"${parent#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        current="$current/$part"
        fs_exists "$current" || debugfs_run "mkdir $current"
    done
}

inject_file() {
    local host=$1 guest=$2 mode=$3 uid=$4 gid=$5
    [[ "$guest" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || die "unsupported guest path: $guest"
    make_guest_parents "$guest"
    if fs_exists "$guest"; then
        if ! fs_exists "$guest.orig"; then
            debugfs_run "ln $guest $guest.orig"
        fi
        debugfs_run "unlink $guest"
    fi
    debugfs_run "write $host $guest"
    debugfs_run "sif $guest mode 010$mode"
    debugfs_run "sif $guest uid $uid"
    debugfs_run "sif $guest gid $gid"
    printf 'overlay: %-36s mode=%s uid=%s gid=%s\n' "$guest" "$mode" "$uid" "$gid"
}

fsck_image "$work"

note "deriving QEMU configuration from the supplied firmware"
for spec in \
    "init-rc:/init.rc:init.rc" \
    "init-strasbourg:/init.strasbourg.rc:init.strasbourg.rc" \
    "default-prop:/default.prop:default.prop"; do
    IFS=: read -r kind guest output <<<"$spec"
    debugfs -R "dump $guest $tmp/$output" "$work" >/dev/null 2>&1 \
        || die "failed to extract $guest from the source rootfs"
    python3 "$QEMU_DIR/../scripts/patch_firmware_files.py" \
        "$kind" "$tmp/$output" "$overlay_tmp/$output" >/dev/null
done

if [[ ${SOFTWARE_GRAPHICS:-1} == 1 ]]; then
    note "building software graphics replacements"
    mkdir -p "$overlay_tmp/lib/hw" "$overlay_tmp/lib"
    debugfs -R "dump /lib/hw/gralloc.default.so $overlay_tmp/lib/hw/gralloc.omap3.so" \
        "$work" >/dev/null 2>&1 \
        || die "failed to extract gralloc.default.so"
    [[ -s "$overlay_tmp/lib/hw/gralloc.omap3.so" ]] \
        || die "gralloc.default.so is missing from the source rootfs"
    debugfs -R "dump /lib/libpixelflinger.so $tmp/libpixelflinger.orig.so" \
        "$work" >/dev/null 2>&1 \
        || die "failed to extract libpixelflinger.so"
    [[ -s "$tmp/libpixelflinger.orig.so" ]] \
        || die "libpixelflinger.so is missing from the source rootfs"
    python3 "$QEMU_DIR/patch-pixelflinger.py" \
        "$tmp/libpixelflinger.orig.so" "$overlay_tmp/lib/libpixelflinger.so" >/dev/null
fi

note "building optional mediaserver diagnostic launcher"
mkdir -p "$overlay_tmp/bin"
debugfs -R "dump /bin/mediaserver $tmp/mediaserver.orig" \
    "$work" >/dev/null 2>&1 \
    || die "failed to extract mediaserver"
[[ -s "$tmp/mediaserver.orig" ]] || die "mediaserver is missing from source rootfs"
python3 "$QEMU_DIR/patch-mediaserver-trace.py" \
    "$tmp/mediaserver.orig" "$overlay_tmp/bin/mediaserver-trace" >/dev/null

while IFS= read -r -d '' host; do
    rel=${host#"$overlay_tmp/"}
    guest="/$rel"
    metadata=$(awk -v path="$guest" '$1 == path { print $2, $3, $4; found=1 } END { exit !found }' \
        "$QEMU_DIR/overlay.manifest" 2>/dev/null || true)
    if [[ -n "$metadata" ]]; then
        read -r mode uid gid <<<"$metadata"
    else
        uid=0
        gid=0
        if [[ -x "$host" ]] || head -c 2 "$host" 2>/dev/null | grep -q '^#!'; then
            mode=0755
        else
            mode=0644
        fi
        warn "$guest is not in overlay.manifest; using mode=$mode uid=0 gid=0"
    fi
    inject_file "$host" "$guest" "$mode" "$uid" "$gid"
done < <(find "$overlay_tmp" -type f -print0 | sort -z)

fsck_image "$work"
mv -f "$pristine_tmp" "$pristine"
mv -f "$work" "$out"
trap - EXIT
rm -rf "$tmp"

note "rootfs images ready"
ls -lh "$pristine" "$out"
