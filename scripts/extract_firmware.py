#!/usr/bin/env python3
"""Extract an authorized R-LINK 11.344 update into the ignored local layout."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

EXPECTED_ZIP_SHA256 = "42d80f7c7c3407b82c1340aeae2ed288e2c15f6a3340cda3dcf0139facd3c699"
TTPKG_GUEST_PATH = "/device/inbox/system-update_3064886_all.ttpkg"
CHUNK_SIZE = 102400
JUNK_SIZE = 20


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_command(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"required command not found: {name}")


def run(*args: str | Path, cwd: Path | None = None) -> None:
    subprocess.run([str(arg) for arg in args], cwd=cwd, check=True)


def extract_tomtom_image(archive: Path, output: Path) -> None:
    with zipfile.ZipFile(archive) as source:
        matches = [name for name in source.namelist() if Path(name).name == "TOMTOM.000"]
        if len(matches) != 1:
            raise RuntimeError(f"expected one TOMTOM.000 in {archive}, found {len(matches)}")
        with source.open(matches[0]) as src, output.open("wb") as dst:
            shutil.copyfileobj(src, dst, 1024 * 1024)


def payload_chunks(path: Path):
    with path.open("rb") as stream:
        if stream.read(4) != b"6X\x05\x1b":
            raise RuntimeError("invalid TTPKG magic")
        stream.seek(8)
        while True:
            stream.seek(JUNK_SIZE, os.SEEK_CUR)
            chunk = stream.read(CHUNK_SIZE)
            if not chunk:
                return
            yield chunk


def extract_ttpkg(path: Path, destination: Path) -> None:
    chunks = payload_chunks(path)
    try:
        first = next(chunks)
    except StopIteration as error:
        raise RuntimeError("empty TTPKG payload") from error

    metadata_size = int.from_bytes(first[4:8], "little")
    if metadata_size > len(first) - 8:
        raise RuntimeError("invalid TTPKG metadata length")
    metadata = first[8 : 8 + metadata_size].replace(b"\0", b" ").decode(errors="replace")
    print(f"package metadata: {metadata.strip()}")

    process = subprocess.Popen(
        ["tar", "xf", "-", "-C", str(destination)], stdin=subprocess.PIPE
    )
    assert process.stdin is not None
    try:
        process.stdin.write(first[8 + metadata_size :])
        for chunk in chunks:
            process.stdin.write(chunk)
        process.stdin.close()
    except BaseException:
        process.kill()
        process.wait()
        raise
    if process.wait() != 0:
        raise RuntimeError("tar failed while extracting TTPKG")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "archive",
        nargs="?",
        type=Path,
        help="authorized R-LINK_11.344.zip (default: firmware/R-LINK_11.344.zip)",
    )
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[1]
    archive = (args.archive or repo / "firmware/R-LINK_11.344.zip").resolve()
    if not archive.is_file():
        parser.error(f"firmware ZIP not found: {archive}")
    for command in ("debugfs", "tar"):
        require_command(command)

    actual_hash = sha256(archive)
    if actual_hash != EXPECTED_ZIP_SHA256:
        raise RuntimeError(
            f"unsupported firmware ZIP SHA-256 {actual_hash}; "
            f"expected R-LINK 11.344 {EXPECTED_ZIP_SHA256}"
        )

    temp_root = repo / "temp"
    package_output = temp_root / "ttpkg"
    rootfs_output = temp_root / "rootfs"
    kernel_output = repo / "qemu/zImage"
    existing = [path for path in (package_output, rootfs_output, kernel_output) if path.exists()]
    if existing:
        joined = "\n  ".join(str(path) for path in existing)
        raise RuntimeError(
            "refusing to overwrite an existing firmware extraction:\n  " + joined
        )

    temp_root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".extract-firmware.", dir=temp_root))
    created: list[Path] = []
    try:
        tomtom = work / "TOMTOM.000"
        package = work / "update.ttpkg"
        unpacked = work / "ttpkg"
        extracted_rootfs = work / "rootfs"
        unpacked.mkdir()
        extracted_rootfs.mkdir()

        print("extracting TOMTOM.000")
        extract_tomtom_image(archive, tomtom)
        print("extracting update package from TOMTOM.000")
        run("debugfs", "-R", f"dump {TTPKG_GUEST_PATH} update.ttpkg", "TOMTOM.000", cwd=work)
        if not package.is_file():
            raise RuntimeError(f"debugfs did not extract {TTPKG_GUEST_PATH}")

        print("extracting TTPKG")
        extract_ttpkg(package, unpacked)
        images = list(unpacked.glob("system-update_*_all_data/rootfs.img.new"))
        kernels = list(unpacked.glob("system-update_*_all_data/zImage"))
        if len(images) != 1 or len(kernels) != 1:
            raise RuntimeError("TTPKG does not contain exactly one rootfs.img.new and zImage")

        print("extracting root filesystem")
        run("debugfs", "-R", "rdump / rootfs", images[0], cwd=work)
        if not (extracted_rootfs / "bin/linker").is_file():
            raise RuntimeError("rootfs extraction is incomplete: bin/linker is missing")

        kernel_temporary = repo / "qemu/.zImage.extracting"
        shutil.copy2(kernels[0], kernel_temporary)
        os.replace(unpacked, package_output)
        created.append(package_output)
        os.replace(extracted_rootfs, rootfs_output)
        created.append(rootfs_output)
        os.replace(kernel_temporary, kernel_output)
        created.append(kernel_output)
    except BaseException:
        for path in reversed(created):
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
        (repo / "qemu/.zImage.extracting").unlink(missing_ok=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print("firmware extraction ready:")
    print(f"  {package_output}")
    print(f"  {rootfs_output}")
    print(f"  {kernel_output}")
    print("next: qemu/rlink-qemu prepare")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
