# TomTom Signedloop Security Model

## Overview

The R-LINK kernel includes a custom Linux Security Module (LSM) called "signedloop" that
enforces a chain-of-trust from the bootloader through the kernel to userspace. It was built
by TomTom to prevent unauthorized firmware modifications on the in-car head unit.

## Components

### 1. Signed Root Filesystem (rootfs.img)

The rootfs.img file has a special layout beyond the ext3 filesystem:

```
|    data blocks      | level 0 hashes  | l1h  .n|sig|
```

- **Data section**: Standard ext3 filesystem data (4 KB blocks)
- **Level 0 hashes**: SHA1 hash of each 4 KB data block, packed 204 per L0 page
- **Level 1 hashes**: SHA1 hashes of the L0 hash pages
- **DSA signature**: Digital Signature Algorithm signature over the L1 hashes

The number of data blocks is stored in the last 4 bytes of the last full page.

For the 344 firmware: 109,493 data pages, 537 L0 pages, 3 L1 pages.

### 2. Kernel Driver (drivers/block/signedloop.c)

The signedloop driver hooks into the kernel at two levels:

**Loop device transfer function** (`signedloop_transfer`):
- Intercepts every block read from a loop device
- Checks the SHA1 hash of the requested block against the pre-computed hash
- Verifies L0 hash pages against their L1 hashes (cached after first verification)
- Returns an I/O error if any hash check fails

**LSM security hooks** (`signedloop_sec_ops`):
- `sb_mount` -- intercepts every `mount()` syscall:
  - If the device is a loop device (LOOP_MAJOR) and MS_NOEXEC is not set:
    forces `LO_FLAGS_READ_ONLY`, activates signedloop hash checking
  - The rootfs loop is always mounted read-only when signedloop is active
- `sb_post_addmount` / `sb_post_remount` -- after any mount:
  - If the device is NOT a loop device with signedloop active:
    forces `MNT_NOEXEC | MNT_NOSUID | MNT_NODEV` flags
  - This means: only the signed rootfs can execute binaries; all other
    filesystems (data partitions, SD cards, USB) are noexec
- `ptrace_traceme` -- unconditionally returns `-EPERM`:
  - Blocks all ptrace (no debugging, no strace, no gdb)

### 3. DSA Key Verification (drivers/crypto/dsa_verify.c)

Two DSA public keys are hardcoded in the kernel:
- `ROOTFS_KEY` (key 0): Used for the root filesystem (`rootfs.img`)
- `LOOPFS_PROD_KEY` / `LOOPFS_DEV_KEY`: Used for other loop-mounted images

The verification function `dsa_verify_hash()` at kernel address `0xc01a4ab0` checks
the DSA signature over the SHA1 hash of the L1 hash pages.

### 4. Rootfs.img.rw Bypass

The initramfs init has a deliberate bypass: if `rootfs.img.rw` exists alongside
`rootfs.img`, it uses `rootfs.img.rw` through a **plain** loop device (no signedloop,
read-write capable). This is presumably used during factory provisioning.

**In QEMU**: We exploit this bypass by providing `rootfs.img.rw` (a copy of the original
rootfs with overlaid modifications). Even so, the signedloop LSM hooks would still force
noexec on all mounts and block ptrace, which is why we also patch the kernel.

### 5. CONFIG_TOMTOM_DEBUG

The kernel config has `CONFIG_TOMTOM_DEBUG` which, when enabled, skips the
`register_security()` call in `signedloop_mod_init()`. The production firmware
does NOT have this enabled.

## Kernel Binary Patches (Image-debug)

Four functions are patched to `mov r0, #0; bx lr` (return 0 / success):

| Virtual Address | Function | Original Instruction | Effect of Patch |
|-----------------|----------|---------------------|-----------------|
| 0xc022a3c8 | `signedloop_sb_mount` | `push {r4-r8, lr}` | Loop mounts are no longer forced read-only; signedloop hash checking is not activated |
| 0xc0229db0 | `signedloop_verify_mntflags` | `push {r4, lr}` | Non-loop mounts are no longer forced noexec/nosuid/nodev |
| 0xc0229da8 | `signedloop_ptrace` | `mvn r0, #0` (return -1) | ptrace is allowed (enables strace, gdb) |
| 0xc01a4ab0 | `dsa_verify_hash` | `push {r0-r11, lr}` | DSA signature verification always returns success |

### How to reproduce the patches

```python
import struct, shutil

SRC = "path/to/Image"        # decompressed kernel (from zImage)
DST = "path/to/Image-debug"
BASE = 0xc0008000

MOV_R0_0  = 0xe3a00000  # mov r0, #0
BX_LR     = 0xe12fff1e  # bx lr

patches = {
    0xc022a3c8: [MOV_R0_0, BX_LR],  # signedloop_sb_mount
    0xc0229db0: [BX_LR],             # signedloop_verify_mntflags
    0xc0229da8: [MOV_R0_0, BX_LR],  # signedloop_ptrace
    0xc01a4ab0: [MOV_R0_0, BX_LR],  # dsa_verify_hash
}

shutil.copy2(SRC, DST)
with open(DST, 'r+b') as f:
    for va, insns in patches.items():
        f.seek(va - BASE)
        for insn in insns:
            f.write(struct.pack('<I', insn))
```

### Symbol recovery

The kernel symbols were recovered using `vmlinux-to-elf` (converts raw ARM Image to
ELF using the embedded kallsyms table). The ELF is stored at
`scratchpad/kernel/Image.elf` and can be used with `arm-linux-gnueabi-nm` or
`arm-linux-gnueabi-objdump`.

## Implications for QEMU Debugging

With all four patches applied:
- **strace works**: Attach to any process to trace syscalls
- **gdb works**: Attach to processes, set breakpoints (gdb-multiarch over QEMU's gdbstub)
- **Binaries execute from any mount**: /data, SD card, USB -- all writable and executable
- **Loop mounts are read-write**: The rootfs can be modified at runtime
- **No signature checks**: Modified rootfs images boot without errors
