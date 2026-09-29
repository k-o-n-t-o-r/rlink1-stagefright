# TomTom Factory Data Tree (FDT)

## Overview

TomTom uses a custom "Factory Data Tree" (FDT) -- NOT a standard Linux device tree (DTB),
but a blob that uses the same flattened device tree format. It stores per-unit factory
calibration, hardware variant information, and feature flags. On the real hardware, the
bootloader loads this from a dedicated flash region and passes its physical address to the
kernel via the custom ATAG_FACTORYDATA (tag 0x5441000A).

The kernel driver `fdtexport` (arch/arm/plat-tomtom/fdtexport.c) reserves the FDT memory
at boot and exposes it as `/dev/fdtexport` (read-only) and `/dev/fdtraw` (raw access).
Userspace tools like `fdtquery` read properties from it.

## FDT Structure

The blob uses standard DTB format (magic 0xd00dfeed). The property tree:

```
/ {
    features/ {
        device-class        -- u32: 0=production, 1=development
        hardware-version    -- u32: board revision (default 4)
        has-bluetooth       -- u32: 0 or 1
        screen-rotation     -- u32: 0 or 1 (180 degree rotation)
        tft                 -- string: LCD panel model (e.g. "g070y2l01")
        device-serial       -- string: unit serial number
        hardware-name       -- string: board name
        project-name        -- string: project codename
        automotive/ {
            supplier-number
            part-number
            manu-id-code
            hw-sw-ref-rsa
            hw-sw-ref-dai
            diag-id-code
            basic-part-list-idx
        }
    }
    options/ {
        audio/ {
            has-booster     -- u32: 0, 1, or 2
        }
        sound/ {
            i2s-bus-num     -- u32: McBSP bus index
        }
        gps/ {
            type            -- string: GPS receiver type
            ephemeris       -- string: ephemeris source
        }
        touchscreen/ {
            xmin, xmax, ymin, ymax  -- u32: calibration values
        }
        battery/ {
            VminADC, VmaxADC, VminEXT, VmaxEXT, etc.  -- u32: battery params
        }
        gprs/               -- GPRS modem configuration
    }
}
```

## Properties Read by the Kernel

| Path | Property | Default | Used by |
|------|----------|---------|---------|
| /features | device-class | 0 | board-strasbourg-a2.c: selects production/development mode |
| /features | hardware-version | 4 | board-strasbourg-a2.c: board variant selection |
| /features | has-bluetooth | 0 | board-strasbourg-a2.c: enables BT hardware |
| /features | screen-rotation | 0 | board-strasbourg-a2.c: display rotation |
| /features | tft | "g070y2l01" | Display driver: panel selection |
| /options/audio | has-booster | 2 | Audio codec configuration |
| /options/sound | i2s-bus-num | 0 | McBSP bus selection |
| /options/touchscreen | xmin/xmax/ymin/ymax | varies | Touch calibration |

## Properties Read by Userspace

| Path | Property | Read by |
|------|----------|---------|
| /features | device-class | load_fdt -> ro.fdt.deviceclass |
| /features | screen-rotation | load_fdt -> ro.fdt.screenrotation |
| /features | device-serial | ttdaemon, data/ttcontent/device-serial |
| /features | hardware-name | ttdaemon |
| /features/automotive | * | eoltool, diagnostics |
| /options/gps | type, ephemeris | gpsd configuration |

## QEMU FDT Blob

The file `rlink.dtb` is compiled from `rlink.dts`:

```dts
/dts-v1/;
/ {
    features {
        device-class = <1>;          // development mode (enables console)
        hardware-version = <4>;
        has-bluetooth = <1>;
        screen-rotation = <0>;
        tft = "g070y2l01";
        device-serial = "QEMU000000000001";
        hardware-name = "strasbourg";
        project-name = "strasbourg";
        automotive {
            supplier-number = "0";
            part-number = "0";
            manu-id-code = "0";
            hw-sw-ref-rsa = "0";
            hw-sw-ref-dai = "0";
            diag-id-code = "0";
            basic-part-list-idx = "0";
        };
    };
    options {
        audio { has-booster = <2>; };
        sound { i2s-bus-num = <0>; };
        gps { type = "none"; ephemeris = "none"; };
    };
};
```

Build reproducibly with `./mkdtb.sh` (equivalent to
`dtc -I dts -O dtb -o rlink.dtb rlink.dts`). The Strasbourg TSC2007 path does
not use the optional FDT touchscreen rectangle: `/system/bin/readcal` reads its
seven affine coefficients from factory EEPROM offset `0x1250`, which the QEMU
EEPROM model supplies.

## FDT Kernel API (arch/arm/plat-tomtom/libfdt.c)

```c
// Get a string property (returns defvalue if not found)
const char *fdt_get_string(const char *vpath, const char *pname, const char *defvalue);

// Get an unsigned long property (big-endian in blob, converted)
unsigned long fdt_get_ulong(const char *vpath, const char *pname, unsigned long defvalue);

// Find a node by virtual path (e.g. "/features/automotive")
unsigned long fdt_find_node(const char *vpath);

// Check FDT magic (0xd00dfeed)
int fdt_check_magic(void);

// Get total size of FDT blob
size_t fdt_totalsize(void);
```

All property values are stored big-endian in the blob (standard DTB format) and converted
by `fdt32_to_cpu()` on read.
