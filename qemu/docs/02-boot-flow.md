# Boot Flow: Initramfs to Android Init

## Overview

The R-LINK boot is unusual: the kernel has an embedded initramfs (cpio archive built into the
kernel binary at compile time) that performs hardware checks and system updates before switching
to the Android rootfs. This is NOT a standard Android boot with a separate ramdisk image.

## Initramfs Contents

The embedded initramfs contains:
- `/init` -- statically linked ARM Thumb binary (84,900 bytes), the main boot logic
- `/bin/e2fsck` -- filesystem check tool (257,540 bytes)
- Device nodes: `/dev/console`, `/dev/null`, `/dev/zero`, `/dev/tty0-4`, `/dev/fb0`,
  `/dev/fdtexport`, `/dev/watchdog`, `/dev/loop0`, `/dev/mmcblk0`, `/dev/mmcblk0p1-p7`,
  `/dev/mmcblk1`, `/dev/mmcblk1p1-p7`
- Directories: `/mnt/rootfs`, `/mnt/flash`, `/data`, `/internalstorage`, `/proc`, `/sys`, `/tmp`

## Initramfs Init Flow (reverse engineered from binary)

### Phase 1: Early Setup
1. Prints `[APTS InitRamFS]` banner with compile timestamp
2. Mounts `/proc` and `/sys`
3. Opens watchdog device, starts feeding it
4. Reads `sysboot_mode` from kernel cmdline (cold/warm/factory/recovery/update)
5. Prints `BOOTMODE: <mode>`

### Phase 2: CAN Microcontroller Check
1. Forks `/system/bin/can_firmware_tool -x DoCanMicroVersionCheck`
   - Communicates with the CAN micro via `/dev/ttyspibuf` (SPI)
   - Exit 0 = firmware matches, exit 1 = needs update, exit 2 = unknown/error
2. If firmware needs update: shows splash screen, forks `can_firmware_tool -x ReProgramCanMicro`
3. Simultaneously forks `/system/bin/eols.configured` (EOL settings check)
   - Exit 0 = unconfigured, exit 1 = configured
4. Waits for both processes, handles crashes and signals

**In QEMU**: `can_firmware_tool` is replaced with a stub that exits 2 ("unknown"), and
`eols.configured` is replaced with a stub that exits 1 ("configured"). This skips the
hardware-dependent SPI and NOR flash checks. It does not replace Android's EOL settings
stack: later, SystemServices reads the modeled 24C64 on I2C3 and obtains the configured
`MmiLanguage` byte through the stock native HAL.

### Phase 3: Module Loading
1. Loads kernel modules listed in `/system/etc/modules` (sound codecs, video drivers,
   MTD/NOR flash, USB gadget, sensors, touchscreen)
2. Each module loaded with `insmod`, using parameters from the modules file

### Phase 4: Storage Mount
1. Parses `root=` from kernel cmdline to find the root block device (`/dev/mmcblk0p2`)
2. Waits for block device to appear
3. Mounts the block device on `/internalstorage` as ext3
4. Changes to `/internalstorage`

### Phase 5: Rootfs Image Selection and Mount
1. Checks for `/internalstorage/rootfs.img.rw` (writable, no signature check)
   - If present: uses it via plain loop device (read-write capable)
2. Falls back to `/internalstorage/rootfs.img` (read-only, signature checked)
   - Uses signedloop: sets up `/dev/loop0`, the kernel's signedloop driver verifies
     DSA signatures and SHA1 hashes block-by-block
3. Mounts loop device on `/mnt/rootfs` as ext3

**In QEMU**: `rootfs.img.rw` is always present (built by `mkrw.sh`), so the signedloop
path is never taken. The kernel's DSA verification is also neutralized as a safety net.

### Phase 6: Root Switch
1. Creates basic directories under `/mnt/rootfs`: `/mnt/rootfs/system`, `/mnt/rootfs/proc`, etc.
2. Moves `/proc` and `/sys` mounts into the new root
3. Checks for system updates (new `rootfs.img.new` files)
4. Prints `starting init`
5. `chdir("/mnt/rootfs")` then `mount -o move . /` (pivot root)
6. `exec /system/xbin/init` (Android init, statically linked)

### Phase 7: Android Init
1. Reads `/system/default.prop` (ro properties)
2. Reads `/system/init.rc` and `/system/init.strasbourg.rc`
3. Creates directories, sets permissions per init.rc
4. Starts `factory_reset` service (checks for factory reset flag, exits immediately if absent)
5. On `factory_reset` stopped: `class_start default` -- starts all default-class services:
   - `servicemanager`, `vold`, `netd`, `debuggerd`, `installd`, `keystore`
   - `console` (root shell on /dev/console, if not disabled)
   - `load_modules` (reloads modules), `busybox --install`
   - `dbus-daemon`, `bthfaudiodaemon`
6. On `load_modules` stopped: starts `media` (mediaserver)
7. On `diversity` (product diversity script) stopped: starts `zygote`
8. Zygote forks `system_server`, which starts the Android framework
9. TomTom SystemServices reads the factory/EOL EEPROM; the default emulated
   `MmiLanguage=3` is mapped to `de_DE` and applied through ActivityManager
10. On `dev.bootcomplete=1`: starts `coldboot` for late device enumeration

## Android Services (from init.strasbourg.rc)

| Service | Binary | Purpose |
|---------|--------|---------|
| gpsd | /system/xbin/gpsd | GPS daemon (SiRFstarIV) |
| vehicle_daemon | /system/ttdaemon/vehicledaemon | CAN bus vehicle data |
| fortytwo | /system/bin/fortytwo | TomTom "42" services framework |
| load_fdt | /system/bin/load_fdt | Reads FDT and sets ro.fdt.* properties |
| copycal | /system/bin/copycal | Copies calibration data |
| digital_radio | /system/xbin/cdc_ecm | Digital radio (DAB) interface |
| baseimage | /system/bin/cexec.out | Loads DSP firmware |

## Timing (in QEMU)

| Event | Time |
|-------|------|
| Kernel start | 0.0s |
| Kernel init complete, Freeing init memory | ~1.1s |
| eMMC partition mounted | ~1.1s |
| Loop rootfs mounted | ~1.1s |
| Android init: enabling adb | ~31s |
| Zygote and system_server start | ~35s |
| SurfaceFlinger software framebuffer | ~36s |
| Android/TomTom framework boot complete | ~45-70s |
| EOL locale applied (`de_DE` by default) | ~50-80s |
| Delayed TomTom Home UI ready | ~100-140s |

The ~30s gap between rootfs mount and Android init is the initramfs waiting for the
CAN firmware tool and EOL check (the stubs exit immediately but the initramfs has
built-in timeouts and a structured handshake). Software graphics then allows the
framework to complete instead of entering the former zygote restart loop.
