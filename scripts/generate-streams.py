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
    ap.add_argument("--input-dir", default="output/incus/alpine",
                    help="Legacy single-image input directory")
    ap.add_argument("--image", action="append", default=[], metavar="OS:RELEASE:DIR",
                    help="Image to publish; repeat for multiple OS releases")
    ap.add_argument("--output-dir", default="incus-server/www",
                    help="Web root; simple-streams tree is written under <out>/streams/v1")
    ap.add_argument("--version", default=None,
                    help="Alpine release, e.g. 3.24 (defaults to VERSION file)")
    ap.add_argument("--arch", default=DEFAULT_ARCH)
    ap.add_argument("--variant", default=DEFAULT_VARIANT)
    ap.add_argument("--build-id", default=None,
                    help="Unique build id (default: UTC YYYYMMDD_HHMMSS)")
    ap.add_argument("--clean", action="store_true",
                    help="Remove generated streams/ and images/ before writing")
    args = ap.parse_args()

    # Release assets are served with immutable cache headers, so every rebuild
    # must use a new URL even when multiple main pushes happen on the same day.
    # The first eight characters stay YYYYMMDD because Incus parses them as the
    # image creation date.
    build_id = args.build_id or datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    out_root = os.path.abspath(args.output_dir)
    streams_dir = os.path.join(out_root, "streams", "v1")
    if args.clean:
        for generated in (os.path.join(out_root, "streams"), os.path.join(out_root, "images")):
            shutil.rmtree(generated, ignore_errors=True)
    # Image files live at the web root (out_root/images/...), NOT under
    # streams/v1/, so the path in images.json (images/<os>/...) resolves
    # correctly to <base-url>/images/<os>/....
    os.makedirs(streams_dir, exist_ok=True)
    updated = now_iso()

    specs = args.image
    if not specs:
        version = args.version
        if not version:
            ver_file = os.path.join(os.path.dirname(__file__), "..", "VERSION")
            version = open(ver_file, encoding="utf-8").read().strip() if os.path.isfile(ver_file) else "3.24"
        specs = [f"{DEFAULT_OS}:{version}:{args.input_dir}"]

    products = {}
    for spec in specs:
        try:
            os_name, version, in_dir = spec.split(":", 2)
        except ValueError:
            sys.exit(f"ERROR: --image must be OS:RELEASE:DIR, got {spec!r}")
        os_name, version = os_name.strip().lower(), version.strip().lstrip("v")
        if not os_name or not version:
            sys.exit(f"ERROR: invalid --image {spec!r}")
        in_dir = os.path.abspath(in_dir)
        meta_tar, rootfs = os.path.join(in_dir, "incus.tar.xz"), os.path.join(in_dir, "rootfs.squashfs")
        for path in (meta_tar, rootfs):
            if not os.path.isfile(path):
                sys.exit(f"ERROR: missing {path} — build {os_name} Incus image first")

        arch, variant = args.arch, args.variant
        product = f"{os_name}:{version}:{arch}:{variant}"
        if product in products:
            sys.exit(f"ERROR: duplicate simple-streams product {product}")
        version_key = f"{build_id}_{os_name}_{arch}"
        images_dir = os.path.join(out_root, "images", os_name, arch, variant, version_key)
        os.makedirs(images_dir, exist_ok=True)
        meta_dst, rootfs_dst = os.path.join(images_dir, "incus.tar.xz"), os.path.join(images_dir, "rootfs.squashfs")
        shutil.copyfile(meta_tar, meta_dst)
        shutil.copyfile(rootfs, rootfs_dst)
        meta_hash, rootfs_hash = sha256_of(meta_dst), sha256_of(rootfs_dst)
        meta_size, rootfs_size = os.path.getsize(meta_dst), os.path.getsize(rootfs_dst)
        combined_hash = sha256_concat(meta_dst, rootfs_dst)
        products[product] = {
            "arch": arch, "os": os_name.capitalize(), "release": version, "release_title": version,
            "aliases": ",".join([f"{os_name}/{version}", f"{os_name}/{version}/{variant}", os_name]),
            "variant": variant,
            "versions": {version_key: {"items": {
                "incus.tar.xz": {
                    "path": f"images/{os_name}/{arch}/{variant}/{version_key}/incus.tar.xz",
                    "sha256": meta_hash, "combined_squashfs_sha256": combined_hash,
                    "size": meta_size, "ftype": "incus.tar.xz"},
                "lxd.tar.xz": {
                    "path": f"images/{os_name}/{arch}/{variant}/{version_key}/incus.tar.xz",
                    "sha256": meta_hash, "combined_squashfs_sha256": combined_hash,
                    "size": meta_size, "ftype": "lxd.tar.xz"},
                "root.squashfs": {
                    "path": f"images/{os_name}/{arch}/{variant}/{version_key}/rootfs.squashfs",
                    "sha256": rootfs_hash, "size": rootfs_size, "ftype": "squashfs"},
            }, "pubname": f"{os_name}-{version}-{arch}-{variant}-{build_id}_0000", "label": variant}},
        }

    images = {
        "datatype": "image-downloads",
        "format": "products:1.0",
        "updated": updated,
        "products": products,
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
                "products": sorted(products),
            }
        },
    }

    with open(os.path.join(streams_dir, "index.json"), "w") as fh:
        json.dump(index, fh, indent=2)
    with open(os.path.join(streams_dir, "images.json"), "w") as fh:
        json.dump(images, fh, indent=2)

    print(f"=== simple-streams tree generated ===")
    print(f"  Products: {', '.join(sorted(products))}")
    print(f"  Output  : {streams_dir}")
    print(f"  Serve   : <base-url>/streams/v1/index.json must be reachable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
