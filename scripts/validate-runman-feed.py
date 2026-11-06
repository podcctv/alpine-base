#!/usr/bin/env python3
"""Validate the static image feed consumed by Runman Agent."""

import hashlib
import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise ValueError(message)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <runman-feed-dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1]).resolve()
    manifest_path = root / "images.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read {manifest_path}: {exc}")
    if not isinstance(manifest, dict) or manifest.get("format") != "runman-images:1":
        fail("images.json must declare format runman-images:1")
    entries = manifest.get("images")
    if not isinstance(entries, list) or len(entries) != 2:
        fail("Runman feed must contain exactly the Alpine amd64 and arm64 images")

    by_arch = {}
    for item in entries:
        if not isinstance(item, dict) or item.get("id") != "alpine":
            fail("only Alpine images are allowed in this production feed")
        arch = item.get("arch")
        if not isinstance(arch, str) or arch not in {"amd64", "arm64"} or arch in by_arch:
            fail(f"invalid or duplicate architecture: {arch!r}")
        by_arch[arch] = item
        serial = item.get("serial")
        if not isinstance(serial, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", serial):
            fail(f"invalid serial for {arch}")
        if item.get("stop_signal") != "SIGUSR2":
            fail(f"Alpine {arch} stop_signal must be SIGUSR2")
        filename = item.get("file")
        expected_name = f"rootfs-alpine-{arch}-{serial}.tar.zst"
        if filename != expected_name or pathlib.PurePosixPath(filename).name != filename:
            fail(f"invalid {arch} archive name: {filename!r}")
        size = item.get("size")
        digest = item.get("sha256")
        if type(size) is not int or size <= 0:
            fail(f"invalid archive size for {arch}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            fail(f"invalid SHA-256 for {arch}")
        archive = root / filename
        if not archive.is_file() or archive.is_symlink():
            fail(f"archive is missing or is a symlink: {archive}")
        if archive.stat().st_size != size:
            fail(f"size mismatch for {filename}")
        if sha256(archive) != digest:
            fail(f"SHA-256 mismatch for {filename}")

    if set(by_arch) != {"amd64", "arm64"}:
        fail("Runman feed is missing an architecture")
    if by_arch["amd64"]["serial"] != by_arch["arm64"]["serial"]:
        fail("amd64 and arm64 serials must identify the same release")
    print(
        "Runman feed valid: "
        + ", ".join(f"{arch}={by_arch[arch]['serial']}" for arch in ("amd64", "arm64"))
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
