# QEMU Patches for R-LINK Emulation

## Base

[dougg3/qemu-linaro-beagleboard](https://github.com/dougg3/qemu-linaro-beagleboard),
branch `beagleboard_fixes`. QEMU version 2.3.50 with Linaro's OMAP3 support. Provides the
`beaglexm` machine: OMAP3630 (DM3730 compatible) with 512 MB RAM, TWL4030 PMIC, MMC,
OMAP UARTs, GPMC, EHCI USB host, MUSB peripheral, I2C, DSS display.

Built inside Docker (`rlink-qemu-build:18.04`, Ubuntu 18.04, gcc-7) to avoid polluting the
host system. `build-qemu.sh` checks out pinned commit
`5475f0b82def09e4c4d810efc3f13b3759a41c70`, applies
`patches/rlink-qemu.patch`, and writes the binary under
`.build/qemu-linaro/arm-softmmu/qemu-system-arm`.

## Patch 1: Direct Kernel Boot with TomTom ATAGs

**Files**: `include/hw/arm/arm.h`, `hw/arm/boot.c`, `hw/arm/beagle.c`

The TomTom kernel expects two non-standard ATAGs from the bootloader:

### ATAG_FACTORYDATA (0x5441000A)

Carries the address and size of the TomTom FDT (Factory Data Tree) blob in RAM.
The kernel's `parse_tag_fdtdata()` (in `arch/arm/kernel/setup.c`) stores this in
`fdt_buffer_info`, which the `fdtexport` driver later exposes as `/dev/fdtexport`
and `/dev/fdtraw`.

Structure (from `arch/arm/include/asm/setup.h`):
```c
struct tag_factorydata {
    u32 address;  // physical address of the FDT blob
    u32 size;     // size in bytes
};
```

### ATAG_REVISION (0x54410007)

Passes `system_rev` which the kernel uses for board variant detection via
`get_mfd_rev()`. Different revisions (B1=0x0011, B2=0x0012, Rennes A1=0x0013,
Rennes B1=0x0014, Stuttgart B1=0x0015) select different GPIO configurations,
USB power settings, and pad multiplexing.

### Implementation

Three fields added to `struct arm_boot_info`:
```c
hwaddr rlink_fdt_addr;
uint32_t rlink_fdt_size;
uint32_t rlink_sysrev;
```

In `set_kernel_args()` (boot.c), after ATAG_CMDLINE and before ATAG_BOARD:
- If `rlink_fdt_size > 0`: writes ATAG_FACTORYDATA with address and size
- If `rlink_sysrev > 0`: writes ATAG_REVISION

In `beagle_common_init()` (beagle.c), when `-kernel` is specified:
- Loads the FDT blob file (from `RLINK_FDT` env var) into guest RAM
- Default FDT address: top of RAM minus 16 MB (overridable via `RLINK_FDT_ADDR`)
- Machine ID from `RLINK_MACHID` env var (default 0x60a for beaglexm, set to 3186 for Strasbourg A2)

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| RLINK_FDT | (none) | Path to the TomTom FDT blob (.dtb file) |
| RLINK_FDT_ADDR | RAM_BASE + RAM_SIZE - 16MB | Physical load address for FDT |
| RLINK_MACHID | 0x60a | ARM machine type ID (3186 for Strasbourg A2) |
| RLINK_SYSREV | 0 | system_rev / board revision |
| RLINK_KERNEL_OFFSET | 0x10000 (zImage) | Kernel load offset from RAM base; set to 0x8000 for raw Image |
| RLINK_EEPROM_MMI_LANGUAGE | (disabled) | Enable the R-LINK 24C64 model and expose this factory language byte; `run.sh` derives it from `EOL_MMI_LANGUAGE` (default 3/German) |
| RLINK_EEPROM_ANDROID_AUTO | 0 | Set bit 6 of the factory `Ecu` byte; `run.sh` derives it from `EOL_ANDROID_AUTO` |
| RLINK_TOUCHSCREEN | (disabled) | Instantiate the R-LINK TSC2007 and route absolute VNC pointer input to it; `run.sh` enables it when `TOUCHSCREEN=1` (default) |

Runtime USB cards use the `rlink-cid` device property rather than an environment
variable. `sd-card.sh` validates and passes `SD_CID`; the committed default is
synthetic, and licensed media requires an authorized card's CID in ignored
`config.env`.

## Patch 2: GPMC CS0 Reset Fix

**File**: `hw/arm/beagle.c`

### Problem

QEMU's GPMC reset sets CS0 as CSVALID with base address 0 and mask 0xf (16 MB).
When booting with `-kernel` (no bootloader), the kernel's `gpmc_mem_init()` tries to
`request_resource()` for this region, which fails because address 0 overlaps
`BOOT_ROM_SPACE`. With `CONFIG_BUG=y`, this triggers `BUG()` and an infinite loop.

### Fix

Two-part fix:
1. NAND is only attached when a MTD drive image is provided OR when not using direct
   kernel boot. Without NAND, GPMC CS0 has no device, so `omap_gpmc_cs_map()` skips
   it even with CSVALID set.
2. A `qemu_register_reset()` callback writes 0xf00 (CSVALID cleared) to GPMC_CONFIG7_0
   (0x6e000078), ensuring the kernel sees no configured chip selects.

## Patch 3: PRCM/DPLL Programming

**File**: `hw/arm/beagle.c`

### Problem

The OMAP3630 has five DPLLs (Phase-Locked Loops) that must be programmed by the bootloader
before the kernel boots. QEMU's reset leaves them in bypass/stop mode. The kernel assumes
they are locked and polls `CM_IDLEST_CKGEN` for up to 1,000,000 iterations per DPLL enable.
Without proper programming, DPLL4 (peripheral clock) never locks, causing every peripheral
clock enable to spin for ~1 second and print "clock: dpll4_ck failed transition to 'locked'".

### Fix

The reset callback programs all five DPLLs using the OMAP36xx parameters for a 26 MHz
system clock (matching U-Boot's `prcm_init()` for the BeagleBoard-xM):

| DPLL | Purpose | M | N | M2 | Output |
|------|---------|---|---|----|--------|
| DPLL1 (MPU) | CPU clock | 300 | 12 | 1 | 600 MHz |
| DPLL2 (IVA2) | DSP clock | 10 | 0 | 1 | 260 MHz |
| DPLL3 (Core) | L3/L4 buses | 200 | 12 | 1 | 400 MHz |
| DPLL4 (Per) | Peripheral clocks | 432 | 12 | 9 | 864 MHz (divided) |
| DPLL5 (Per2) | USB/120MHz clocks | 443 | 11 | 8 | 120 MHz |

Additional divider settings: L3=/2 (200 MHz), L4=/2 (100 MHz), SSI=/3, SGX=/5.

The programming is done via `cm_rmw()`, a helper that reads-modifies-writes Clock Module
registers through `ldl_le_phys`/`stl_le_phys` directly into the guest's MMIO space.

## Patch 4: EHCI ULPI Viewport Stub

**File**: `hw/arm/beagle.c`

### Problem

The OMAP3 EHCI driver writes to INSNREG05 (offset 0xa4 from EHCI base 0x48064800) to
perform ULPI register accesses on the USB PHY. It sets bit 31 (control) and polls until
the bit clears. QEMU's generic sysbus-EHCI does not implement OMAP-specific INSNREG
registers, so the bit never clears and the driver calls `BUG()`.

### Fix

A 32-byte I/O region mapped at 0x48064890 (covering INSNREG00-05) that returns 0 for all
reads and ignores all writes. This makes the ULPI viewport appear to complete instantly
with empty data, which satisfies the driver.

Additionally, an Exynos4210-compatible sysbus EHCI is mapped at 0x48064800 with IRQ 77,
providing basic EHCI capability registers that the driver can enumerate.

## Patch 5: All Four UARTs Mapped

**File**: `hw/arm/beagle.c`

### Original

Only UART3 (ttyO2) was connected to `serial_hds[0]`; UART1/2/4 were NULL.

### Fix

```c
s->cpu = omap3_mpu_init(sysmem, cpu_model, ram_size,
                        serial_hds[1], serial_hds[2],
                        serial_hds[0], serial_hds[3]);
```

Mapping: first `-serial` arg = ttyO2 (console), second = ttyO0 (normally GPS),
third = ttyO1 (Bluetooth), and fourth = the kernel-unused UART4. The runner logs
the first backend to `rlinkq.serial.log` and exposes the second as the loopback-only
TCP root shell; the guest redirects its absent GPS receiver to `/dev/null`.

## Patch 6: Configurable Kernel Load Offset

**File**: `hw/arm/boot.c`

The default kernel load offset is 0x10000 (for zImage, which self-relocates). Raw ARM
Image files must be loaded at PHYS_OFFSET + 0x8000. The `RLINK_KERNEL_OFFSET` environment
variable overrides the default.

## Patch 7: Quiet handled OMAP access-width fallbacks

**File**: `include/hw/arm/omap.h`

The firmware repeatedly performs wide accesses to several legacy OMAP registers.
QEMU's fallback already splits and handles these accesses, but `TCMI_VERBOSE`
printed every poll to stderr. Long runs grew Docker's JSON log by hundreds of
megabytes. The dedicated R-LINK build disables that compile-time diagnostic;
actual unimplemented-device failures remain visible.

## Patch 8: R-LINK factory/EOL EEPROM

**File**: `hw/i2c/ddc.c`

The Strasbourg kernel registers I2C3 address `0x50` as an 8 KiB 24C64 EEPROM.
TomTom's native EOL settings HAL reads the one-byte `MmiLanguage` signal at
EEPROM offset `0x103`; value 3 means German. The upstream Beagle machine instead
placed a 128-byte, one-byte-addressed monitor DDC device at the same address, so
the kernel saw shifted/repeated EDID bytes and interpreted the language as
unsupported.

When `RLINK_EEPROM_MMI_LANGUAGE` is present, the patched device implements
16-bit 24C64 addressing and writable 8 KiB storage. Its initial contents preserve
the bytes formerly visible through the DDC model, then set the selected language
byte and the firmware's known touchscreen calibration block at offset `0x1250`.
Without that environment variable it retains the original Beagle DDC behavior.
`run.sh` always supplies the validated decimal byte from `EOL_MMI_LANGUAGE`,
whose default is `3` (German).

The same model can set Android Auto's production EOL gate. Reverse engineering
`eoltool` established that `EcuAndroidAutoFeature` is bit 6, and a before/after
raw-I2C dump established that the `Ecu` byte is EEPROM offset `0x112` (`0x80`
becomes `0xc0`). `EOL_ANDROID_AUTO=1` passes
`RLINK_EEPROM_ANDROID_AUTO=1` and sets that bit during EEPROM initialization, so
it survives every QEMU process restart and is consumed by the unmodified EOL
cache path.

These are hardware-level inputs: the unmodified `libeols.default.so`,
`EolSettingsSource`, and `DatabaseHelper` read them, cache the values, map the
language to `de_DE`, and expose `EcuAndroidAutoFeature=true`. No application,
locale resource, or settings-provider code is patched.

## Patch 9: TSC2007 touchscreen and VNC input

**Files**: `hw/input/tsc2007.c`, `hw/input/Makefile.objs`, `hw/arm/beagle.c`

When `RLINK_TOUCHSCREEN` is present, the Beagle machine creates a TSC2007 at
I2C2 address `0x48` and connects its active-low PENIRQ output to OMAP GPIO54,
matching Strasbourg's board data. The model registers an absolute QEMU pointer
handler, so VNC button and motion messages update its touch state. It implements
the SMBus word transactions used by the production Linux driver for X, Y, Z1,
Z2, temperature, auxiliary input, and power-down commands.

VNC's 0..32767 absolute coordinates are transformed into calibrated 12-bit ADC
samples by inverting the factory affine transform. The driver therefore exposes
`TSC2007 Touchscreen` as a normal Linux input device, and Android receives touch
events without framework changes. The model is single-touch, as is the physical
resistive panel. `TOUCHSCREEN=0` omits it for diagnostics.

## Patch 10: Navigation SD CID

**Files**: `hw/usb/dev-storage.c`, `hw/scsi/scsi-bus.c`,
`hw/scsi/scsi-disk.c`

TomTom binds navigation media to the physical SD CID. A plain QEMU USB disk
reported `CID (null)`, so Vold could assemble the `TOMTOM.000` container but the
navigation stack still rejected its map. USB storage now accepts a validated
32-digit `rlink-cid` property and identifies that instance as the Strasbourg
SMSC `0424:4040` reader. It emulates the reader's private six-byte SCSI CDB
`cf 18 00 00 60 00`, returning the configured 16 CID bytes. Generic USB disks
remain unchanged, and malformed/unknown CDB groups are rejected instead of
reaching the old QEMU fork's negative-length copy bug.

Vold now reports the CID on both the FAT partition and device-mapper container,
and `Environment.getExternalStorageCardId()` follows the production path. No
physical card CID is committed.

## Patch 11: Android USB gadget passthrough stability

**File**: `hw/usb/host-libusb.c`

Android phones change addresses and VID/PID while entering Android Open
Accessory mode. The old libusb used by this QEMU fork retained stale enumeration
state, while mirroring the guest EHCI reset and a redundant
`SET_CONFIGURATION(1)` onto the physical gadget caused a hard disconnect before
the first bulk transfer.

The patch recreates a stale libusb context only while all configured host
objects are disconnected, refreshes it before the first `usb-host` object, and
adds a per-device `suppress-reset` property. For that property, guest bus resets
are acknowledged virtually and an already-active physical configuration is not
reapplied. `usb-phone.sh` enables the property only for the forwarded phone and
continues matching by stable physical `hostport`; unrelated USB devices retain
upstream behavior.

USBmon confirmed the progression from zero bulk packets to a stable AOA
session, AA protocol 1.7, TLS 1.2, service discovery, and all projection
channels. Raw captures and device identifiers are intentionally not versioned.

## Building

The complete build is reproducible from this directory:

```sh
./build-qemu.sh
```

The script fingerprints `docker/Dockerfile` and rebuilds the toolchain image
when it changes, validates the exact upstream commit, applies the checked patch
idempotently, and always reruns configuration inside the container so host or
stale-image include paths
cannot leak into `config-host.mak`. It configures only `arm-softmmu` and compiles
as the calling host uid. Set `QEMU_SRC` or `JOBS` as needed; `REBUILD_IMAGE=1`
forces an uncached toolchain-image rebuild.
