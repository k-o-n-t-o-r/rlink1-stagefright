# R-LINK 1 QEMU environment

This directory boots Renault/TomTom R-LINK 1 firmware on a patched OMAP3
QEMU. The debug profile provides a root UART, a stable Android framework, an
interactive 800x480 software-rendered display over VNC, and a factory/EOL EEPROM
selecting German by default.

## First-time setup

Vendor firmware, kernels, rootfs images, and configuration files are not
bundled. From the repository root, drop `R-LINK_11.344.zip` into ignored
`firmware/` and extract it:

```sh
python3 scripts/extract_firmware.py firmware/R-LINK_11.344.zip
cd qemu
./build-qemu.sh                  # pinned checkout + reproducible QEMU patch
./rlink-qemu prepare             # DTB, debug kernel, rootfs overlay, sd.img
./rlink-qemu doctor
```

The extractor creates ignored `temp/ttpkg/`, `temp/rootfs/`, and `qemu/zImage`.
`prepare` derives patched init configuration from those user-supplied files at
build time; no vendor init files are stored in Git. `ROOTFS_SOURCE` can point to
an existing `rootfs.img.new` instead.

## Daily use

```sh
./rlink-qemu start               # safe, non-persistent debug boot
./rlink-qemu wait                # wait for Android + visible TomTom home UI
./rlink-qemu shell               # interactive root shell
./rlink-qemu exec 'getprop'      # one non-interactive command
./rlink-qemu screenshot          # PNG under screenshots/
./rlink-qemu tap 64 450          # headless VNC touchscreen tap
./rlink-qemu heap-trace-start    # optional mediaserver allocator tracing
./rlink-qemu smoke               # end-to-end health check
./rlink-qemu stop
```

Open `vnc://127.0.0.1:5900` to view and operate the LCD. The modeled TSC2007
turns VNC pointer presses, releases, and drags into native Android touch events.
The VNC and root-shell ports are bound to loopback only. For headless automation,
`./rlink-qemu tap 64 450` sends a tap at an LCD coordinate.

Guest disk writes use QEMU snapshot mode by default. Set `PERSIST=1` in
`config.env` to modify `sd.img` directly. The modeled 8 KiB I2C EEPROM reports
`MmiLanguage=3`, causing TomTom's own EOL settings path to select `de_DE`; change
`EOL_MMI_LANGUAGE` to emulate another factory language byte. Set
`EOL_ANDROID_AUTO=1` to set bit 6 of the factory `Ecu` byte at EEPROM offset
`0x112`, enabling the production Android Auto feature gate across QEMU restarts.
See [`config.env.example`](config.env.example) for ports, board revision, GDB,
internal eMMC size, removable-media defaults, and source-tree overrides.

### Fast exploit iteration without reboot

This old OMAP3 model does not implement migration state for its interrupt
controller, clocks, timers, and several USB/UART devices, so QEMU `savevm/loadvm`
cannot restore a live Android session safely: a test restore leaves the CPU
waiting for interrupts that will never arrive. Use the targeted reset instead:

```sh
./rlink-qemu exploit-reset
```

It normally completes in seconds. It detaches the removable card and phone,
restarts mediaserver, removes only known transient tools under
`/data/local/tmp`, and returns to the TomTom Home UI. It deliberately preserves
tombstones and `/data/log` evidence. It refuses rather than pretending to be a
snapshot if `/data/local.prop`, `/data/rlink-gps`, or an in-memory GPS config
path is active. It also does not undo EEPROM or SQLite writes; those still
require the documented rollback or a real restart.

A true whole-process memory checkpoint would require host-level CRIU/Docker
checkpointing, which this project does not configure.

## Runtime removable card

A FAT32 image can be created and hotplugged without restarting QEMU:

```sh
./rlink-qemu sd-create                         # removable.img, 1 GiB
./rlink-qemu sd-create --size 4G media.img    # alternate image
./rlink-qemu sd-attach media.img
./rlink-qemu exec 'vdc volume list'
./rlink-qemu sd-detach
```

A physical Android phone can be forwarded through the emulated EHCI controller
when QEMU was built with libusb and `USB_PASSTHROUGH=1` is set before startup:

```sh
./rlink-qemu usb-status
./rlink-qemu usb-attach 1 1     # host bus + stable physical port from lsusb -t
./rlink-qemu usb-detach
```

The helper matches the physical port rather than VID/PID or device address, so a
phone can disconnect and re-enumerate in Android Accessory/Android Auto mode.
Its `suppress-reset` option acknowledges guest enumeration resets and redundant
`SET_CONFIGURATION(1)` requests without restarting Android's already configured
physical gadget. Host usbfs is exposed to the otherwise unprivileged QEMU
container only when the explicit opt-in is enabled. Stop the host adb server
before attachment if it has claimed the phone; `usb-attach` does this
automatically.

### Android Auto validation result

A compatible Android test phone was switched to AOA v2 and forwarded
successfully. The production SPCX/HUM L stack negotiated AA protocol 1.7,
completed TLS 1.2 with the Renault certificate, passed phone
authorization/preflight, opened channels 0 through 9, and reached
`PREFLIGHT->CONNECTED` plus `onVideoReady()`.

Native QEMU video stops at the expected hardware boundary: the firmware selects
`OMX.TI.Video.Decoder`, whose LCML DSP allocation returns `-14` because QEMU does
not emulate the OMAP IVA/DSP. The real projected phone surfaces (800x400 content plus an 800x80 facet-bar
display; the H.264 capture is padded to 128 lines) were captured and composited
into QEMU's 800x480 framebuffer for a clearly labeled
supervisor-assisted visual check. Raw capture sessions and device identifiers
are intentionally not versioned.

The modeled removable-card device is USB mass storage and is detected as `/dev/sda`. Ordinary
FAT cards mount at `/mnt/sdcard`. Media containing split `TOMTOM.000` containers
is mapped through device-mapper and its inner ext3 filesystem mounts at a UUID
path under `/mnt/`; first-time extent mapping can take several minutes. The USB
reader supplies `SD_CID` so licensed navigation content can follow the
physical-card validation path. Set it in ignored `config.env` to the matching
physical card CID; the repository default is synthetic. Once a TomTom container mounts, the helper restarts the navigation
services so a late hotplug is immediately rescanned. Card-image writes are
persistent even when the main boot disk
uses snapshot mode. Always
detach before accessing the image from
the host. `sd-detach --force` is available only when a clean guest unmount cannot
be confirmed. Monitor device `sd0` is the running boot disk and stays attached.

## What makes graphics work

The PowerVR SGX530 cannot be emulated. `mkrw.sh` therefore:

1. selects Android's software EGL implementation;
2. substitutes the generic framebuffer gralloc HAL for `gralloc.omap3.so`;
3. applies a checked patch to `libpixelflinger.so` so its generated ARM
   scanlines can execute with the production kernel's NX heap policy.

This lets SurfaceFlinger, `system_server`, and the TomTom applications remain
running instead of entering the former five-second zygote crash loop.

For architecture and reverse-engineering details, start with
[`docs/README.md`](docs/README.md). The opt-in mediaserver allocator tracer is
documented in [`docs/09-mediaserver-heap-diagnostics.md`](docs/09-mediaserver-heap-diagnostics.md).
