# Debugging Guide

## Connecting to the Guest

### Interactive Root Shell (primary method)

```sh
./rlink-qemu wait
./rlink-qemu shell
# or: nc 127.0.0.1 2323
```

This connects to `qemu-shell` on UART1 (ttyO0). The guest redirects the absent
GPS receiver to `/dev/null`, so its SiRF binary stream cannot corrupt shell
commands. Kernel logs remain on the separate UART3 console. The shell port is
published on host loopback only. Non-interactive commands do
not need netcat:

```sh
./rlink-qemu exec 'getprop ro.product.model'
```

### Serial Console Log

```sh
tail -f qemu/rlinkq.serial.log
```

This is UART3 (ttyO2), the kernel console. Shows kernel messages (dmesg), Android init
output, and the console service's shell (but mixed with kernel messages, so the TCP
shell on port 2323 is better for interaction).

### QEMU Monitor

```sh
./mon.sh "info registers"    # CPU state
./mon.sh "info cpus"         # CPU halted state
./mon.sh "x/16wx 0x80000000" # read guest physical memory
./mon.sh "pmemsave 0x80000000 0x1000000 rlink/dump.bin"  # dump 16 MB RAM
```

### LCD, VNC, and screenshots

The software-rendered 800x480 LCD is available at `vnc://127.0.0.1:5900`.
VNC pointer input drives the modeled TSC2007, so clicks and drags operate the
Android UI. A tap can also be sent without a viewer, using LCD coordinates:

```sh
./rlink-qemu tap 64 450
./rlink-qemu screenshot screenshot.png
```

The first command taps the Home screen's lower-left Menu button. Set
`TOUCHSCREEN=0` in `config.env` only when diagnosing the original no-device
path.

### Kernel Log (dmesg from RAM)

```sh
./rlink-qemu dmesg
```

Dumps the first 16 MB of guest RAM and extracts the kernel printk ring buffer.
Works even when the serial console is quiet (e.g., after loglevel changes).

### Fast Stagefright reset

Avoid a full Android boot between ordinary media-parser attempts:

```sh
./rlink-qemu exploit-reset
```

The helper detaches hotplug devices, refuses active GPS/local.prop staging,
restarts mediaserver, removes only known transient exploit tools, and opens the
Home UI. Tombstones and `/data/log` are preserved. It is intentionally narrower
than a VM snapshot and does not undo EEPROM or database writes.

QEMU internal `savevm/loadvm` was tested and rejected for this machine. The old
OMAP3 model lacks migration state for timers, clocks, the interrupt controller,
and several peripherals, so restored Android freezes in WFI even after RAM
blocks are made snapshot-identifiable. Do not use monitor snapshots as an
exploit baseline.

### Runtime removable media

Create and hotplug a FAT32 card without restarting the guest:

```sh
./rlink-qemu sd-create --size 1G --label RLINKSD removable.img
./rlink-qemu sd-attach removable.img
./rlink-qemu exec 'vdc volume list; mount | grep /mnt/sdcard'
```

QEMU presents the image on `usb-bus.2`; the kernel detects `/dev/sda`, and Vold
mounts a normal FAT volume at `/mnt/sdcard`. A split TomTom map container is
assembled as `/dev/dm-*` and mounted at its UUID path under `/mnt/`; the first
extent scan may take several minutes. The modeled SMSC reader reports `SD_CID`
to Vold, which is required for licensed navigation media. After the inner map
mount appears, `sd-attach` requests a navigation-service rescan so late hotplug
works without rebooting Android. The image must be beneath `qemu/`, because
that is the host directory available inside the running container. Writes bypass
the main QEMU snapshot and persist in the card image.

Unmount before touching the image from the host:

```sh
./rlink-qemu sd-detach
```

The command refuses to unplug if it cannot confirm a guest unmount. Use
`sd-detach --force` only for recovery. Do not use monitor `eject sd0` or
`change sd0 ...`: `sd0` is the active boot/internal-storage disk.

## Running Commands in the Guest

Via nc:
```sh
echo 'getprop ro.product.model' | nc -w 5 localhost 2323
```

Via a script:
```sh
{
  printf '\r\n'
  sleep 1
  printf 'ls -la /system/bin/\r\n'
  sleep 3
  printf 'cat /proc/meminfo\r\n'
  sleep 2
} | nc -w 10 localhost 2323
```

Note: nc closes when the connection drops. For long sessions, use `ncat` or `socat`:
```sh
socat - TCP:localhost:2323
```

## GDB Remote Debugging

Set `GDB_PORT=1234` in `config.env` (and optionally `GDB_WAIT=1` in the
environment), then start the VM and connect:

```sh
gdb-multiarch -ex 'target remote :1234' -ex 'file /path/to/Image.elf'
```

The port is forwarded on host loopback only.

This gives kernel-level debugging with symbols recovered from kallsyms.

For userspace debugging with the patched kernel (ptrace enabled):
```sh
# On the guest:
strace -p <pid>         # trace syscalls
strace -f -e open ls    # trace a command
```

## Process Inspection

```sh
# Process list
ps

# Process details
cat /proc/<pid>/status
cat /proc/<pid>/maps
cat /proc/<pid>/cmdline | tr '\0' ' '

# Open file descriptors
ls -la /proc/<pid>/fd/

# System properties (Android)
getprop
getprop ro.product.model
setprop debug.myapp.trace 1
```

## Filesystem Inspection

```sh
# Mount points
mount

# Disk usage
df

# The rootfs is on loop0
losetup

# List the system partition
ls -la /system/
ls -la /system/bin/
ls -la /system/app/
ls -la /system/framework/

# TomTom-specific directories
ls -la /system/ttdaemon/
ls -la /data/ttcontent/
ls -la /data/vddata/
```

## Kernel Module Information

```sh
lsmod                           # loaded modules
cat /proc/modules               # with addresses
cat /sys/module/*/parameters/*  # module parameters
```

## Android Framework

```sh
# Logcat (if logcat is available in /system/bin/)
logcat -v threadtime

# Service list
service list

# Activity manager
am start -n com.package/.Activity
am broadcast -a android.intent.action.BOOT_COMPLETED

# Package manager
pm list packages
pm path com.tomtom.platform
```

## Common Issues

### Zygote or system_server restarts

The default overlay now keeps both processes stable by selecting software EGL,
using generic framebuffer gralloc, and making pixelflinger's generated scanlines
executable. A five-second restart loop usually means an old `rootfs.img.rw` is
still in `sd.img`.

Rebuild and verify the current overlay:

```sh
./rlink-qemu stop
./rlink-qemu prepare
./rlink-qemu start
./rlink-qemu smoke
```

### No network

**Symptom**: No `ifconfig` output, no route table.

**Cause**: The beaglexm machine has no Ethernet NIC. The guest has USB gadget networking
(g_ether, usb0) and CDC-EEM, but these need a USB host connection that doesn't exist in QEMU.

**Workaround**: For transferring files, modify the rootfs overlay (rebuild with mkrw.sh).
For network-dependent debugging, consider adding a QEMU virtio-net device (requires a
kernel driver, which the stock kernel does not have).

### ttyO0 shell doesn't respond

**Symptom**: `nc localhost 2323` connects but no prompt or output.

**Cause**: The `qemu-shell` service may not have started yet, or the rootfs lacks
the GPS UART redirect. These files are derived from the local firmware during
`prepare`; inspect the generated image:
```sh
debugfs -R 'cat /init.rc' qemu/staging/p2/rootfs.img.rw 2>/dev/null | grep qemu-shell
debugfs -R 'cat /init.strasbourg.rc' qemu/staging/p2/rootfs.img.rw 2>/dev/null | grep ttyGPS
tail -n 20 qemu/rlinkq.serial.log
```

### Watchdog resets

`omap_wdt: Unexpected close, not stopping!` during boot is harmless. An actual
reboot containing this line is not:

```
Restarting system with command 'System reboot triggered because of: com.android.server.Watchdog$PipeMonitor'.
```

That is Android's production heartbeat monitor waiting on vehicle/navigation
FIFOs, not a slow CPU. The current overlay disables those hardware-dependent
checks. If it occurs, the eMMC contains an old overlay; run:

```sh
./rlink-qemu stop
./rlink-qemu prepare
./rlink-qemu start
```

Count boot attempts with
`grep -c '^\[    0\.000000\] Linux version' rlinkq.serial.log`. One is expected.

## Modifying the Guest at Runtime

Since signedloop is neutralized, you can write to the rootfs:
```sh
mount -o remount,rw /                    # if mounted read-only
echo '#!/system/bin/sh' > /system/bin/test_script.sh
chmod 755 /system/bin/test_script.sh
```

For persistent changes, modify the overlay, add metadata to `overlay.manifest`,
and rebuild:

```sh
# On the host, from qemu/:
printf '#!/system/bin/sh\necho hello\n' > overlay/bin/myscript
printf '/bin/myscript 0755 0 2000\n' >> overlay.manifest
./rlink-qemu stop
./rlink-qemu prepare
```

## Performance Notes

- QEMU emulates the Cortex-A8 with single-threaded TCG, but normal boot should
  reach the shell at about 32 seconds and `dev.bootcomplete=1` shortly after.
  `rlink-qemu wait` returns near two minutes because `qemu-ui` deliberately lets
  startup services settle before opening Home; twenty minutes still indicates a
  wait or reboot loop, not normal emulation cost.
- Low host CPU is normal while the guest executes WFI and waits for emulated
  timers or absent peripherals. Total-system CPU percentages can also hide one
  busy QEMU thread on a many-core host.
- Check real progress with `./rlink-qemu exec 'cat /proc/uptime; getprop
  dev.bootcomplete'` and inspect the serial log for repeated `Linux version`
  headers.
- The software framebuffer is functional but slower than the original SGX530.
- Snapshot mode protects the base eMMC by default; set `PERSIST=1` to retain writes.
- Use `./rlink-qemu wait` rather than a fixed sleep in automation.
