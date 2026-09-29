# R-LINK QEMU emulation documentation

These documents contain everything needed to understand, operate, and extend the QEMU-based
emulation of the Renault R-LINK 1 (TomTom Strasbourg) infotainment head unit.

## Documents

| # | File | Contents |
|---|------|----------|
| 1 | [01-hardware-and-firmware.md](01-hardware-and-firmware.md) | SoC specs, peripherals, memory map, boot chain, system properties |
| 2 | [02-boot-flow.md](02-boot-flow.md) | Initramfs phases, CAN/EOL checks, rootfs mount, Android init sequence |
| 3 | [03-security-model.md](03-security-model.md) | Signedloop LSM, DSA verification, rootfs.img.rw bypass, kernel patches |
| 4 | [04-qemu-patches.md](04-qemu-patches.md) | Reproducible QEMU patch: ATAGs, GPMC, clocks, EHCI, UARTs, logging |
| 5 | [05-tomtom-fdt.md](05-tomtom-fdt.md) | Factory Data Tree structure, property inventory, QEMU FDT blob |
| 6 | [06-rootfs-overlay.md](06-rootfs-overlay.md) | Overlay system, stub scripts, init.rc patches, SD image layout |
| 7 | [07-debugging-guide.md](07-debugging-guide.md) | Shell access, GDB, strace, process inspection, common issues |
| 8 | [08-software-graphics.md](08-software-graphics.md) | Software EGL/gralloc, pixelflinger NX patch, LCD and VNC |
| 9 | [09-mediaserver-heap-diagnostics.md](09-mediaserver-heap-diagnostics.md) | Opt-in dlmalloc chunk tracing around media parser corruption |

## Quick start

```sh
cd qemu/
./rlink-qemu start          # start a safe snapshot boot
./rlink-qemu wait           # wait for Android and the visible home UI
./rlink-qemu shell          # interactive root shell
./rlink-qemu screenshot     # capture the 800x480 LCD
./rlink-qemu stop
```

For a fresh checkout, run `./build-qemu.sh` and `./rlink-qemu prepare` first.

To modify the guest filesystem, edit files under `overlay/`, then run
`./mkrw.sh && ./mksd.sh` and restart QEMU.

## Key Facts

- **Guest OS**: Android 2.2 Froyo, kernel 2.6.32.9, ARM Cortex-A8
- **Machine ID**: 3186 (Strasbourg A2)
- **Shell port**: TCP 2323 (ttyO0/UART1; absent GPS redirected to `/dev/null`)
- **Console log**: `rlinkq.serial.log` (ttyO2/UART3 kernel console)
- **Removable media**: runtime `/dev/sda` hotplug via `rlink-qemu sd-*`
- **Monitor**: `./mon.sh "command"` (QEMU monitor via Unix socket)
- **Display/input**: software-rendered 800x480 LCD with TSC2007 touch at `vnc://127.0.0.1:5900`
- **Framework**: zygote/system_server stable; `dev.bootcomplete=1` reached
- **Heap diagnostics**: opt-in `rlink-qemu heap-trace-*`; normal mediaserver remains unmodified
- **Kernel source mirror**: https://github.com/wangyx0055/R-Link_kernel (board-strasbourg-a2.c)
- **QEMU fork**: https://github.com/dougg3/qemu-linaro-beagleboard (beaglexm machine)
