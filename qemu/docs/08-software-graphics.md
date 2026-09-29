# Software Graphics and LCD Output

## Why the original userspace crashes

The firmware selects TI's `gralloc.omap3.so` and the PowerVR SGX530 EGL
libraries. QEMU has no SGX model, so the kernel driver reports a DDK validation
failure. SurfaceFlinger then follows an error path that calls an invalid EGL
function pointer, killing `system_server`; init restarts zygote every five
seconds.

Selecting only `libGLES_android.so` is not sufficient. Two additional firmware
assumptions must be addressed:

- `gralloc.omap3.so` still depends on the PowerVR stack. The generic Froyo
  framebuffer HAL (`gralloc.default.so`) must be used instead.
- Froyo pixelflinger generates optimized ARM scanline routines into memory
  returned by `malloc()`. The R-LINK production kernel marks that heap NX.
  Execution faults at the first generated instruction even though cache flushes
  succeed.

## Rootfs changes

`mkrw.sh` creates all graphics replacements from the pristine firmware at build
time:

1. `overlay/lib/egl/egl.cfg` selects only the Android software implementation.
2. `/lib/hw/gralloc.default.so` is copied over `/lib/hw/gralloc.omap3.so`.
   The original is retained as `gralloc.omap3.so.orig`.
3. `patch-pixelflinger.py` patches `/lib/libpixelflinger.so`; the original is
   retained as `libpixelflinger.so.orig`.

The patch is tied to SHA-256
`cc02c60b993fb7504e98aa242daaae559d790f81f2d15dbc1269d3398bb679e1`.
It refuses unknown binaries and verifies the output hash.

### Pixelflinger trampoline

Both `android::Assembly::Assembly(size_t)` constructor variants originally call
`malloc` directly. They are redirected to a 34-byte Thumb trampoline placed in
the test-only `ggl_test_codegen` function. The trampoline:

1. calls the original `malloc@plt`;
2. aligns the returned pointer down to a page boundary;
3. invokes ARM Linux `mprotect` syscall 125 with `PROT_READ|PROT_WRITE|PROT_EXEC`;
4. returns the original allocation.

Only the pages containing pixelflinger's small code-cache allocations are made
RWX. This is a debug-emulation compatibility patch, not a production hardening
change.

## Result

With these changes:

- SurfaceFlinger uses `/dev/graphics/fb0` through generic gralloc;
- the generated scanline pipelines execute successfully;
- zygote and `system_server` remain running;
- `dev.bootcomplete=1` is reached and TomTom applications launch;
- QEMU's OMAP DSS console exposes the 800x480 framebuffer.

The launch scripts publish that console as VNC on `127.0.0.1:5900`. The
modeled TSC2007 registers an absolute pointer handler, making the VNC display
interactive. A lossless capture is available with:

```sh
./rlink-qemu screenshot output.png
```

## Remaining limitations

- Rendering is software-only and substantially slower than the SGX530.
- Touch input is single-touch, matching the physical resistive TSC2007 panel;
  multi-touch gestures are unavailable.
- Vehicle CAN data is unavailable; `qemu-guest-config` supplies safe hardware
  state and `qemu-ui` opens the normal home activity instead of leaving the
  black user-off activity in front.
- Audio uses Android's generic no-output emulation path.
