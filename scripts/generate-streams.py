#!/usr/bin/env python3
"""Generate an Incus/LXD simple-streams image server tree.

Turns the distrobuilder output (incus.tar.xz + rootfs.squashfs) into the
static "simple-streams" layout that `incus remote add ... --protocol=simplestreams`
understands, so the image can be served over plain HTTP(S) by any static
web server (e.g. the bundled nginx Docker image).

Layout produced under --output-dir (web root):
    streams/v1/index.json
    streams/v1/images.json
    images/<os>/<arch>/<variant>/<build-id>/incus.tar.xz
    images/<os>/<arch>/<variant>/<build-id>/rootfs.squashfs

Note: image files live under <out>/images/ (web root), which MUST match the
`path` field written into images.json (`images/...`). The simplestreams client
(and our install.sh) resolve that `path` relative to the base URL, so the files
must be reachable as <base-url>/images/<os>/..., not under streams/v1/.

Usage:
    ./scripts/generate-streams.py \
        --input-dir output/incus \
        --output-dir incus-server/www \
        --version 3.24

Then point a static server at <output-dir> so that
<base-url>/streams/v1/index.json is reachable, and run on the client:

    incus remote add myrepo <base-url> --protocol=simplestreams
    incus launch myrepo:alpine/3.24 my-instance
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone

DEFAULT_OS = "alpine"
DEFAULT_ARCH = "amd64"
DEFAULT_VARIANT = "default"


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_concat(*paths: str) -> str:
    """Return the Incus fingerprint for a split image.

    Incus fingerprints are the SHA-256 of the metadata and rootfs files
    concatenated byte-for-byte in that order.
    """
    h = hashlib.sha256()
    for path in paths:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-dir", default="output/incus",
                    help="Directory containing incus.tar.xz + rootfs.squashfs")
    ap.add_argument("--output-dir", default="incus-server/www",
                    help="Web root; simple-streams tree is written under <out>/streams/v1")
    ap.add_argument("--version", default=None,
                    help="Alpine release, e.g. 3.24 (defaults to VERSION file)")
    ap.add_argument("--arch", default=DEFAULT_ARCH)
    ap.add_argument("--variant", default=DEFAULT_VARIANT)
    ap.add_argument("--build-id", default=None,
                    help="Unique build id (default: YYYYMMDD)")
    args = ap.parse_args()

    # Resolve Alpine version
    version = args.version
    if not version:
        ver_file = os.path.join(os.path.dirname(__file__), "..", "VERSION")
        try:
            with open(ver_file) as fh:
                version = fh.read().strip()
        except FileNotFoundError:
            version = "3.24"
    version = version.lstrip("v")

    in_dir = os.path.abspath(args.input_dir)
    meta_tar = os.path.join(in_dir, "incus.tar.xz")
    rootfs = os.path.join(in_dir, "rootfs.squashfs")
    for p in (meta_tar, rootfs):
        if not os.path.isfile(p):
            sys.exit(f"ERROR: missing {p} — run ./scripts/build-incus.sh first")

    build_id = args.build_id or datetime.now(timezone.utc).strftime("%Y%m%d")
    os_name = DEFAULT_OS
    arch = args.arch
    variant = args.variant
    product = f"{os_name}:{version}:{arch}:{variant}"
    version_key = f"{build_id}_{os_name}_{arch}"

    out_root = os.path.abspath(args.output_dir)
    streams_dir = os.path.join(out_root, "streams", "v1")
    # Image files live at the web root (out_root/images/...), NOT under
    # streams/v1/, so the path in images.json (images/<os>/...) resolves
    # correctly to <base-url>/images/<os>/....
    images_dir = os.path.join(out_root, "images", os_name, arch, variant, version_key)
    os.makedirs(streams_dir, exist_ok=True)
    os.makedirs(images_dir, exist_ok=True)

    # Incus 6.x discovers split images by ftype=incus.tar.xz. The LXD
    # compatibility item below points to the same metadata file, matching the
    # public images.linuxcontainers.org stream layout.
    meta_dst = os.path.join(images_dir, "incus.tar.xz")
    rootfs_dst = os.path.join(images_dir, "rootfs.squashfs")
    shutil.copyfile(meta_tar, meta_dst)
    shutil.copyfile(rootfs, rootfs_dst)

    meta_hash = sha256_of(meta_dst)
    rootfs_hash = sha256_of(rootfs_dst)
    meta_size = os.path.getsize(meta_dst)
    rootfs_size = os.path.getsize(rootfs_dst)
    combined_hash = sha256_concat(meta_dst, rootfs_dst)

    updated = now_iso()

    # images.json —— 真正的 products 清单（datatype=image-downloads, format=products:1.0）
    images = {
        "datatype": "image-downloads",
        "format": "products:1.0",
        "updated": updated,
        "products": {
            product: {
                "arch": arch,
                "os": os_name.capitalize(),
                "release": version,
                "release_title": version,
                "aliases": ",".join([
                    f"{os_name}/{version}",
                    f"{os_name}/{version}/{variant}",
                    f"{os_name}",
                ]),
                "variant": variant,
                "versions": {
                    version_key: {
                        "items": {
                            "incus.tar.xz": {
                                "path": f"images/{os_name}/{arch}/{variant}/{version_key}/incus.tar.xz",
                                "sha256": meta_hash,
                                "combined_squashfs_sha256": combined_hash,
                                "size": meta_size,
                                "ftype": "incus.tar.xz",
                            },
                            "lxd.tar.xz": {
                                "path": f"images/{os_name}/{arch}/{variant}/{version_key}/incus.tar.xz",
                                "sha256": meta_hash,
                                "combined_squashfs_sha256": combined_hash,
                                "size": meta_size,
                                "ftype": "lxd.tar.xz",
                            },
                            "root.squashfs": {
                                "path": f"images/{os_name}/{arch}/{variant}/{version_key}/rootfs.squashfs",
                                "sha256": rootfs_hash,
                                "size": rootfs_size,
                                "ftype": "squashfs",
                            },
                        },
                        "pubname": f"{os_name}-{version}-{arch}-{variant}-{build_id}_0000",
                        "label": variant,
                    }
                },
            }
        },
    }

    # index.json —— simplestreams 索引文件（datatype=index:1.0, format=simplestreams:1.0）。
    # 注意：索引文件必须指向 products 清单的路径（streams/v1/images.json），
    # 之前误把 image-downloads 内容写进了 index.json，导致 `incus remote add
    # --protocol=simplestreams` 客户端找不到合法索引而失败。
    index = {
        "format": "index:1.0",
        "updated": updated,
        "index": {
            "images": {
                "datatype": "image-downloads",
                "path": "streams/v1/images.json",
                "format": "products:1.0",
                "products": [product],
            }
        },
    }

    with open(os.path.join(streams_dir, "index.json"), "w") as fh:
        json.dump(index, fh, indent=2)
    with open(os.path.join(streams_dir, "images.json"), "w") as fh:
        json.dump(images, fh, indent=2)

    print(f"=== simple-streams tree generated ===")
    print(f"  Product : {product}")
    print(f"  Alias   : {os_name}/{version}")
    print(f"  Version : {version_key}")
    print(f"  Output  : {streams_dir}")
    print(f"  Serve   : <base-url>/streams/v1/index.json must be reachable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
