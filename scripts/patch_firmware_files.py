#!/usr/bin/env python3
"""Create project-specific text files from a user-supplied firmware extraction."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import tempfile


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected exactly one {label} marker, found {text.count(old)}")
    return text.replace(old, new)


def patch_init_rc(text: str) -> str:
    text = replace_once(
        text,
        "    setprop persist.service.adb.enable 0",
        "    setprop persist.service.adb.enable 1",
        "ADB default",
    )
    text = replace_once(
        text,
        "    on property:init.svc.factory_reset=stopped\n        class_start default",
        """    on property:init.svc.factory_reset=stopped
        start qemu-config

    on property:init.svc.qemu-config=stopped
        class_start default

    on property:dev.bootcomplete=1
        start qemu-ui""",
        "factory-reset trigger",
    )

    console_start = text.index("# start console")
    console_end = text.index("# load kernel modules", console_start)
    text = (
        text[:console_start]
        + """# The stock console service is replaced by qemu-shell below. Explicit ttyO2
# redirection is reliable with this old init implementation.
    service console /system/bin/sh
        console
        disabled

"""
        + text[console_end:]
    )

    text = replace_once(
        text,
        "    service servicemanager /system/bin/servicemanager",
        """    # Seed emulator-only vehicle/display state before Android services start.
    service qemu-config /system/xbin/qemu-guest-config
        user root
        group root
        disabled
        oneshot

    service qemu-ui /system/xbin/qemu-ui
        user root
        group root
        disabled
        oneshot

    service servicemanager /system/bin/servicemanager""",
        "servicemanager service",
    )
    text = replace_once(
        text,
        "    service bootanim /system/bin/bootanimation",
        """    # Opt-in allocator diagnostics. This must never run with the normal media
    # service because both register the same Binder services.
    service media-trace /system/xbin/qemu-mediaserver-trace
        user media
        disabled
        group system audio camera graphics inet net_bt net_bt_admin net_raw
        ioprio rt 4

    service bootanim /system/bin/bootanimation""",
        "boot animation service",
    )
    separator = "\n###############################################################################\n"
    if not text.endswith(separator):
        raise ValueError("unsupported init.rc: final separator is missing")
    return text + """
# QEMU: explicit root shell on UART1; the absent GPS is redirected to null
    service qemu-shell /system/xbin/qemu-shell
        user root
"""


def patch_init_strasbourg(text: str) -> str:
    text = replace_once(
        text,
        "# symlink GPS to uart 0",
        "# QEMU: no GPS receiver exists; reserve UART1 for the root shell",
        "GPS comment",
    )
    return replace_once(
        text,
        "symlink /dev/ttyO0 /dev/ttyGPS",
        "symlink /dev/null /dev/ttyGPS",
        "GPS UART link",
    )


def patch_default_prop(text: str) -> str:
    if "ro.allow.mock.location=0" not in text:
        raise ValueError("unsupported default.prop: mock-location marker is missing")
    additions = (
        "ro.fdt.deviceclass=1\n"
        "persist.service.adb.enable=1\n"
        "ro.debuggable=1\n"
    )
    if any(line in text for line in additions.splitlines()):
        raise ValueError("default.prop already contains QEMU development properties")
    return text.rstrip("\n") + "\n" + additions


def patch_glconfig(text: str) -> str:
    text = replace_once(
        text,
        'arp-cbee-cbeegen-app-path="/system/bin/cbee_gen"',
        'arp-cbee-cbeegen-app-path="/system/bin/sh"',
        "CBEE executable",
    )
    return replace_once(
        text,
        'arp-cbee-cbeegen-app-param="-debug -ln=/data/gps/log/cbee_gen_log.txt"',
        'arp-cbee-cbeegen-app-param="/data/rlink-gps/root_canary.sh"',
        "CBEE argument",
    )


PATCHERS = {
    "init-rc": patch_init_rc,
    "init-strasbourg": patch_init_strasbourg,
    "default-prop": patch_default_prop,
    "glconfig": patch_glconfig,
}


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=PATCHERS)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    source = args.source.read_text(encoding="utf-8")
    write_atomic(args.output, PATCHERS[args.kind](source))
    print(args.output)


if __name__ == "__main__":
    main()
