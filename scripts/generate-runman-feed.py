#!/usr/bin/env python3
"""Build a Runman Agent image feed from the Alpine rootfs build artifacts."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True, help="Alpine release, e.g. 3.24")
    parser.add_argument("--serial", required=True, help="Unique serial for this exact image build")
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.serial):
        parser.error("serial may contain only letters, digits, '.', '_' and '-'")
    if not re.fullmatch(r"[0-9]+\.[0-9]+", args.version):
        parser.error("version must be an Alpine major.minor release")
    if not args.input_dir.is_dir():
        parser.error(f"input directory does not exist: {args.input_dir}")

    args.output_dir.mkdir(parents=True, exist_ok=True)

    entries = []
    for arch in ("amd64", "arm64"):
        name = f"rootfs-alpine-{arch}-{args.serial}.tar.zst"
        source = args.input_dir / name
        if not source.is_file() or source.is_symlink() or source.stat().st_size == 0:
            parser.error(f"missing or invalid {arch} archive: {source}")

        # Check that the payload is a readable tar.zst and contains the runtime
        # components Runman expects before publishing the manifest that points
        # to it.
        listing = subprocess.run(
            ["tar", "--zstd", "-tf", str(source)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        normalized = {item.lstrip("./") for item in listing}
        for required in ("etc/ssh/sshd_config", "etc/init.d/sshd", "sbin/openrc"):
            if required not in normalized:
                parser.error(f"{arch} archive is missing required path {required}")

        target = args.output_dir / name
        if target.is_symlink():
            parser.error(f"refusing to replace or reuse symlink: {target}")
        if source.resolve() != target.resolve():
            if target.exists():
                if sha256(source) != sha256(target):
                    parser.error(
                        f"serial {args.serial} already exists with different {arch} bytes"
                    )
            else:
                temp = target.with_name(f".{target.name}.tmp")
                shutil.copyfile(source, temp)
                os.replace(temp, target)
        entries.append(
            {
                "id": "alpine",
                "name": f"Alpine Linux {args.version}",
                "serial": args.serial,
                "stop_signal": "SIGUSR2",
                "arch": arch,
                "file": name,
                "sha256": sha256(target),
                "size": target.stat().st_size,
            }
        )

    manifest = {"format": "runman-images:1", "images": entries}
    manifest_path = args.output_dir / "images.json"
    temp_manifest = manifest_path.with_suffix(".json.tmp")
    temp_manifest.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temp_manifest, manifest_path)
    print(f"Runman feed ready: {manifest_path}")
    for entry in entries:
        print(
            f"  {entry['id']} {entry['arch']} serial={entry['serial']} "
            f"size={entry['size']} sha256={entry['sha256']}"
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(f"archive validation failed: {exc}", file=sys.stderr)
        raise SystemExit(exc.returncode)
