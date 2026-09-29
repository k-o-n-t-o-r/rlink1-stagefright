#!/usr/bin/env bash
# Start the R-LINK firmware in the patched qemu-linaro container.
set -euo pipefail

QEMU_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$QEMU_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: ./run.sh [--debug|--stock] [--] [extra QEMU arguments...]

  --debug  Patched raw kernel, root shell on SHELL_PORT (recommended)
  --stock  Original zImage for production-kernel diagnostics

Configuration is read from config.env; see config.env.example.
EOF
}

mode=stock
extra=()
while (($#)); do
    case $1 in
        --debug) mode=debug ;;
        --stock) mode=stock ;;
        --help|-h) usage; exit 0 ;;
        --) shift; extra+=("$@"); break ;;
        *) extra+=("$1") ;;
    esac
    shift
done

need_cmd docker
need_file "$QEMU_DIR/rlink.dtb"
need_file "$QEMU_DIR/sd.img"
[[ "$EOL_MMI_LANGUAGE" =~ ^[0-9]+$ ]] \
    && (( 10#$EOL_MMI_LANGUAGE <= 255 )) \
    || die "EOL_MMI_LANGUAGE must be a decimal byte (0-255): $EOL_MMI_LANGUAGE"
eol_mmi_language=$((10#$EOL_MMI_LANGUAGE))
eol_language_name=
if (( eol_mmi_language == 3 )); then
    eol_language_name=' (German)'
fi
[[ "$EOL_ANDROID_AUTO" == 0 || "$EOL_ANDROID_AUTO" == 1 ]] \
    || die "EOL_ANDROID_AUTO must be 0 or 1: $EOL_ANDROID_AUTO"
[[ "$TOUCHSCREEN" == 0 || "$TOUCHSCREEN" == 1 ]] \
    || die "TOUCHSCREEN must be 0 or 1: $TOUCHSCREEN"
[[ "$USB_PASSTHROUGH" == 0 || "$USB_PASSTHROUGH" == 1 ]] \
    || die "USB_PASSTHROUGH must be 0 or 1: $USB_PASSTHROUGH"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1 \
    || die "Docker image $BUILD_IMAGE is missing; run ./build-qemu.sh"

if [[ "$QEMU_BIN" == /work/qemu-linaro/* ]]; then
    host_binary="$QEMU_SRC/${QEMU_BIN#/work/qemu-linaro/}"
    [[ -x "$host_binary" ]] \
        || die "QEMU binary is missing: $host_binary (run ./build-qemu.sh or set QEMU_SRC)"
fi
[[ -d "$QEMU_SRC" ]] || die "QEMU source directory is missing: $QEMU_SRC"

case $mode in
    debug)
        kernel=Image-debug
        kernel_offset=0x8000
        need_file "$QEMU_DIR/$kernel"
        ;;
    stock)
        kernel=zImage
        kernel_offset=
        need_file "$QEMU_DIR/$kernel"
        ;;
esac

if container_exists; then
    note "removing existing container $NAME"
    docker rm -f "$NAME" >/dev/null
fi
rm -f "$QEMU_DIR/$NAME.serial.log" "$QEMU_DIR/$NAME.mon.sock" "$QEMU_DIR/$NAME.mem.bin"

docker_args=(
    run -d --name "$NAME" --init
    --user "$(id -u):$(id -g)"
    --cap-drop ALL
    --label io.rlink.emulator=true
    -w /work
    -v "$QEMU_SRC:/work/qemu-linaro:ro"
    -v "$QEMU_DIR:/work/rlink"
    -e RLINK_FDT=/work/rlink/rlink.dtb
    -e "RLINK_MACHID=$RLINK_MACHID"
    -e "RLINK_EEPROM_MMI_LANGUAGE=$eol_mmi_language"
    -e "RLINK_EEPROM_ANDROID_AUTO=$EOL_ANDROID_AUTO"
)
if [[ "$USB_PASSTHROUGH" == 1 ]]; then
    [[ -d /dev/bus/usb ]] || die "USB_PASSTHROUGH=1 but /dev/bus/usb is absent"
    docker_args+=(
        --mount type=bind,src=/dev/bus/usb,dst=/dev/bus/usb
        --device-cgroup-rule 'c 189:* rwm'
    )
fi
[[ -n "$kernel_offset" ]] && docker_args+=(-e "RLINK_KERNEL_OFFSET=$kernel_offset")
[[ "$TOUCHSCREEN" == 1 ]] && docker_args+=(-e RLINK_TOUCHSCREEN=1)
[[ -n "$RLINK_SYSREV" ]] && docker_args+=(-e "RLINK_SYSREV=$RLINK_SYSREV")
[[ -n ${RLINK_FDT_ADDR:-} ]] && docker_args+=(-e "RLINK_FDT_ADDR=$RLINK_FDT_ADDR")

qemu_args=(
    -name "R-LINK 1 ($mode)"
    -M beaglexm
    -kernel "/work/rlink/$kernel"
    -drive "file=/work/rlink/sd.img,if=sd,format=raw"
    -append "$CMDLINE"
    -serial "file:/work/rlink/$NAME.serial.log"
    -display none
    -monitor "unix:/work/rlink/$NAME.mon.sock,server,nowait"
)

if [[ "$mode" == debug ]]; then
    [[ "$SHELL_PORT" =~ ^[0-9]+$ ]] && ((SHELL_PORT > 0 && SHELL_PORT < 65536)) \
        || die "invalid SHELL_PORT: $SHELL_PORT"
    docker_args+=(-p "127.0.0.1:$SHELL_PORT:$SHELL_PORT")
    qemu_args+=(-serial "tcp:0.0.0.0:$SHELL_PORT,server,nowait")
fi

if [[ "$VNC_PORT" != 0 ]]; then
    [[ "$VNC_PORT" =~ ^[0-9]+$ ]] && ((VNC_PORT > 0 && VNC_PORT < 65536)) \
        || die "invalid VNC_PORT: $VNC_PORT"
    docker_args+=(-p "127.0.0.1:$VNC_PORT:5900")
    qemu_args+=(-vnc :0)
fi

if [[ "$GDB_PORT" != 0 ]]; then
    [[ "$GDB_PORT" =~ ^[0-9]+$ ]] && ((GDB_PORT > 0 && GDB_PORT < 65536)) \
        || die "invalid GDB_PORT: $GDB_PORT"
    docker_args+=(-p "127.0.0.1:$GDB_PORT:$GDB_PORT")
    qemu_args+=(-gdb "tcp:0.0.0.0:$GDB_PORT")
    [[ ${GDB_WAIT:-0} == 1 ]] && qemu_args+=(-S)
fi

[[ "$PERSIST" == 1 ]] || qemu_args+=(-snapshot)
qemu_args+=("${extra[@]}")

container_id=$(docker "${docker_args[@]}" "$BUILD_IMAGE" "$QEMU_BIN" "${qemu_args[@]}")
note "started $NAME (${container_id:0:12}) in $mode mode"
printf '    serial log: %s\n' "$QEMU_DIR/$NAME.serial.log"
printf '    EOL locale: MmiLanguage=%s%s\n' "$eol_mmi_language" "$eol_language_name"
[[ "$EOL_ANDROID_AUTO" == 1 ]] && printf '    EOL feature: Android Auto enabled\n'
[[ "$TOUCHSCREEN" == 1 ]] && printf '    touch:      VNC pointer input enabled\n'
[[ "$USB_PASSTHROUGH" == 1 ]] && printf '    usb:        host passthrough enabled\n'
if [[ "$mode" == debug ]]; then
    printf '    root shell: nc 127.0.0.1 %s\n' "$SHELL_PORT"
fi
if [[ "$VNC_PORT" != 0 ]]; then
    printf '    display:    vnc://127.0.0.1:%s\n' "$VNC_PORT"
fi
printf '    monitor:    %s/mon.sh "info registers"\n' "$QEMU_DIR"
[[ "$PERSIST" == 1 ]] || printf '    storage:    snapshot (set PERSIST=1 to retain guest writes)\n'
