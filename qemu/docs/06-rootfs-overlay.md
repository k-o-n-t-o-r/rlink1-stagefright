# Rootfs Overlay System

## How It Works

The TomTom initramfs init has a built-in bypass: when `rootfs.img.rw` exists alongside
`rootfs.img` on the internalstorage partition, it mounts `rootfs.img.rw` through a plain
loop device (read-write, no signature verification) instead of `rootfs.img` (read-only,
signedloop with DSA verification).

The `mkrw.sh` script exploits this by:
1. Copying the pristine signed `rootfs.img.new` to both `rootfs.img` and `rootfs.img.rw`
2. Deriving patched init/default configuration from the user-supplied image
3. Generating the software-graphics replacements from pristine firmware files
4. Using `debugfs -w` to inject files without root privileges
5. Applying explicit mode/uid/gid values from `overlay.manifest`
6. Preserving replaced files as `<name>.orig` (hardlinked before replacement)
7. Running `e2fsck` before publishing the image atomically

## Overlay Files

### overlay/bin/can_firmware_tool

```sh
#!/system/bin/sh
# QEMU stub: no CAN microcontroller in the emulator. Exit 2 = "UNKNOWN", initramfs continues.
exit 2
```

**Why**: The real `can_firmware_tool` communicates with a CAN bus microcontroller via
`/dev/ttyspibuf` (SPI port). In QEMU there is no SPI or CAN hardware. Exit code 2 means
"firmware version unknown", which the initramfs treats as "continue booting" (it only
blocks on exit code 1 = "firmware mismatch, needs update").

### overlay/bin/eols.configured

```sh
#!/system/bin/sh
# QEMU stub: report EOL settings as CONFIGURED (exit 1) so the initramfs does not wait for vehicledaemon.
exit 1
```

**Why**: The real `eols.configured` checks the NOR flash (GPMC CS0) for End-Of-Line
production settings. Exit 0 = "unconfigured" (triggers a VehicleDaemon + interactive shell
loop for factory programming). Exit 1 = "configured" (normal boot path). QEMU has no NOR flash.

### Generated default.prop

`patch_firmware_files.py` copies the user's firmware file and adds development
mode, ADB-at-boot, and debuggable properties. The derived file exists only in
the ignored build staging directory. These values would normally be set by
`load_fdt`; that path requires `/dev/fdtexport`, while the ATAG-based FDT is for
kernel-internal use.

### overlay/etc/watchdogs

An empty emulator-specific watchdog list. Production firmware monitors heartbeat
FIFOs for `vehicledaemon` and `navigation`; without the physical vehicle
peripherals those heartbeats can stall, causing `system_server` to reboot the
whole guest after roughly 115 seconds with
`com.android.server.Watchdog$PipeMonitor`. The services still run, but QEMU does
not arm these production liveness checks.

### overlay/xbin/qemu-guest-config

Creates the firmware's built-in `nocan` and `displayon` markers for the vehicle
state package before zygote starts. These enable its no-CAN simulation path and
keep the physical display output enabled, but do not synthesize the final frontend
wake event; `qemu-ui` handles that separately. The script also selects the
firmware's file-based temperature test source at 25 C: the absent ADC otherwise
returns an error that is interpreted as 110 C and enters thermal display-off.
It also removes any cached `pointercal` before Android starts, so the stock
`copycal` service regenerates the affine transform from the modeled EEPROM;
this migrates persistent disks created before touchscreen emulation existed.

### overlay/xbin/qemu-ui

After Android reports boot completion and startup services have settled, starts
the normal `com.tomtom.home.HomeActivity`. The production state manager cannot
make that transition by itself without a CAN wake event, so it otherwise leaves
its intentionally black `SystemStateUserPerceivedOff` activity in front. The
delay avoids triggering Froyo service-ANR kills during the initial startup burst.

### Generated init.rc

`patch_firmware_files.py` applies the following changes to the user's extracted
`/init.rc` during the build; the vendor file and derived result are not
versioned:

1. **Reliable root shell**: Replaces the stock `console` service with
   `qemu-shell`, whose explicit ttyO0 redirection works reliably with this old init.
   QEMU exposes this UART on the loopback-only TCP shell port.

2. **ADB enabled at boot**: Changed `setprop persist.service.adb.enable 0` to
   `setprop persist.service.adb.enable 1`.

3. **QEMU guest configuration**: Runs `qemu-guest-config` before Android services
   so the no-CAN wake/display/temperature files have the package's expected ownership.

4. **Visible UI startup**: Runs `qemu-ui` after `dev.bootcomplete=1`; it waits
   for startup load to settle, opens the TomTom home activity, and verifies that
   the activity remains in front before reporting UI readiness.

### Generated init.strasbourg.rc

The build derives this from the user's extracted file and redirects
`/dev/ttyGPS` to `/dev/null`. No physical GPS receiver is modeled, and this
reserves UART1 for the root shell without SiRF binary traffic corrupting its
command stream.

### overlay/xbin/qemu-shell

Explicitly redirects an interactive root shell to ttyO0, which QEMU exposes as
loopback-only TCP port 2323. Kernel output remains separately logged on ttyO2.

### Optional mediaserver heap diagnostics

`lib/libq.so`, `bin/mediaserver-trace`, and
`xbin/qemu-mediaserver-trace` implement the disabled-by-default `media-trace`
service. The diagnostic executable differs from stock mediaserver only by one
additional `DT_NEEDED` entry. Its library swaps Bionic's exported malloc dispatch
table after process startup and records bounded dlmalloc walks/free headers.
`rlink-qemu heap-trace-*` controls it; normal boots continue using the untouched
`/system/bin/mediaserver`. See [09-mediaserver-heap-diagnostics.md](09-mediaserver-heap-diagnostics.md).

### overlay/lib/egl/egl.cfg

Selects only `libGLES_android.so`. The PowerVR EGL libraries cannot initialize
without an SGX530.

### Generated graphics replacements

`mkrw.sh` copies the firmware's generic `gralloc.default.so` over
`gralloc.omap3.so` and applies the checked `patch-pixelflinger.py` compatibility
patch. Together these keep SurfaceFlinger and system_server running. See
[08-software-graphics.md](08-software-graphics.md).

## Adding New Overlay Files

Do not copy vendor files into `overlay/`; derive modifications from the ignored
firmware extraction in `scripts/patch_firmware_files.py` instead. For
project-owned files:

1. Place the file in `overlay/` at the path it should have inside `/system/`
   (e.g., `overlay/bin/mytool` becomes `/system/bin/mytool`).
2. Add its guest path, mode, uid, and gid to `overlay.manifest`.
3. Run `./mkrw.sh && ./mksd.sh` (or `./rlink-qemu prepare`).
4. Restart QEMU.

Unlisted files fall back to mode 0755 for scripts and 0644 otherwise, but the
build emits a warning so permissions are never silently broadened.

## SD Image Structure

Built by `mksd.sh`:

```
sd.img (2 GiB, MBR partitioned)
  p1: FAT32 (64 MiB, offset 1 MiB) -- unused, mirrors real boot partition layout
  p2: ext3 "internalstorage" (remainder) -- contains:
      rootfs.img     -- original signed rootfs (fallback, used with signedloop)
      rootfs.img.rw  -- patched rootfs (preferred by initramfs, no signature check)
      data/          -- empty, becomes /data after boot
      cache/         -- empty, becomes /cache after boot
```

The ext3 partition is created with `mke2fs -d` which populates it from `staging/p2/`.
