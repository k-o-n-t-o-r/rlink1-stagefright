# R-LINK 1 Hardware and Firmware Reference

## Hardware Platform

- **Product**: Renault R-LINK 1 (infotainment head unit, 2012-2015 Renaults)
- **Internal codename**: TomTom "Strasbourg" / "Strasbourg A2"
- **SoC**: Texas Instruments DM3730 (OMAP3630 variant)
  - CPU: ARM Cortex-A8, ARMv7, single-core
  - GPU: PowerVR SGX530 (Imagination Technologies)
  - DSP: TI C64x+ (for audio/media processing)
  - Clock: 26 MHz crystal, MPU at 600-800 MHz
- **RAM**: 512 MB DDR (mapped at physical 0x80000000-0x9FFFFFFF)
- **Storage**: 1.86 GiB eMMC (internal, /dev/mmcblk0)
  - p1: boot partition (X-Loader + U-Boot)
  - p2: "internalstorage" ext3 partition containing rootfs.img and data
- **Display**: 7" TFT LCD (g070y2l01), connected via OMAP DSS/DPI
- **PMIC**: TWL4030 (on I2C bus 1)
- **Touchscreen**: TSC2007 (I2C bus 2, addr 0x48)
- **Sensors**: LIS3DH accelerometer (I2C bus 3, addr 0x18), I3G4250D gyroscope (I2C bus 3, addr 0x68)
- **Factory/EOL EEPROM**: 8 KiB 24C64 (I2C bus 3, addr 0x50); `MmiLanguage` is at offset `0x103`
- **GPS**: SiRFstarIV via UART1 (ttyO0)
- **Bluetooth**: CSR BlueCore via UART2 (ttyO1)
- **Console**: UART3 (ttyO2) at 115200 baud
- **USB**: EHCI host + MUSB peripheral (OTG)
- **CAN**: Microprocessor connected via SPI (/dev/ttyspibuf)
- **NOR Flash**: On GPMC CS0, used by the early EOL configured-state check
- **Video input**: TVP5150 (composite video decoder, I2C)
- **Audio**: TWL4030 codec + UDA1334 DAC + BC6 codec (on McBSP buses)

## Firmware Build

- **OS**: Android 2.2.1 "Froyo" (API level 8)
- **Kernel**: Linux 2.6.32.9, PREEMPT
- **Toolchain**: TomTom CipherWizardry 2009q1 (gcc 4.3.3)
- **Build version**: 3064886 (firmware version 11.344 / 11.347)
- **Build date**: July 10, 2018
- **Build host**: nlsrvup-bua25.ttg.global

## ARM Machine Type

The kernel uses MACH_TYPE 3186 ("Strasbourg A2"). The machine descriptor is at kernel virtual address 0xc0027bac with:
- `.phys_io = 0x48000000` (L4 interconnect base)
- `.boot_params = 0x80000100` (ATAG list location in RAM)

There is also an older MACH_TYPE 3123 ("Strasbourg") at 0xc0027b78, but the production firmware uses 3186.

## Boot Chain

1. **TI X-Loader 1.41** (in eMMC boot area) -- initializes SDRAM, loads U-Boot from eMMC
2. **U-Boot 1.3.4** -- programs DPLLs, loads kernel + FDT from eMMC partition 2, passes ATAGs
3. **Kernel 2.6.32.9** (zImage) -- decompresses, inits SoC, unpacks built-in initramfs
4. **TomTom initramfs** (embedded in kernel) -- hardware checks, mounts rootfs on loop
5. **Android init** (/system/xbin/init) -- starts services, zygote, system_server

## Key System Properties

| Property | Value | Purpose |
|----------|-------|---------|
| ro.product.model | TomTom Strasbourg | Device identification |
| ro.product.device | strasbourg | Device codename |
| ro.board.platform | omap3 | Platform for HAL loading |
| ro.build.version.sdk | 8 | Android API level (Froyo) |
| ro.build.version.release | 8.8 | TomTom version string |
| ro.fdt.deviceclass | 0/1 | 0=production, 1=development (enables console) |
| ro.kernel.qemu | unset | Deliberately unset so TomTom reads `/dev/fdtexport` instead of a missing `/data/emulator-fdt.txt` |

## Kernel Command Line (production)

```
root=/dev/mmcblk0p2 console=ttyO2,115200 androidboot.console=ttyO2
sysboot_mode=cold init=/init videoout=omap24xxvout
vram=0x300000,0x83000000 lpj=2334720 brick=0
```

## Memory Map (physical)

| Range | Size | Usage |
|-------|------|-------|
| 0x40200000-0x4020FFFF | 64 KB | OMAP3 SRAM |
| 0x48000000-0x4900FFFF | ~1 MB | L4 interconnect (UART, I2C, MMC, etc.) |
| 0x49020000 | UART3 | Console serial port (ttyO2) |
| 0x4806A000 | UART1 | GPS (ttyO0) |
| 0x4806C000 | UART2 | Bluetooth (ttyO1) |
| 0x48064800 | EHCI | USB host controller |
| 0x6E000000 | GPMC | General-Purpose Memory Controller |
| 0x80000000-0x9FFFFFFF | 512 MB | SDRAM |
| 0x80000100 | - | ATAG list (boot parameters) |
| 0x80008000 | - | Kernel text start (PHYS_OFFSET + TEXT_OFFSET) |
| 0x83000000 | 3 MB | VRAM (video memory, reserved by kernel) |
| 0x9FFFC000 | 16 KB | RAM console (persistent dmesg across reboots) |
