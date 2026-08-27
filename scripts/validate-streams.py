#!/usr/bin/env python3
"""Validate an Incus simple-streams tree, including file fingerprints."""

import argparse
import hashlib
import json
import pathlib


def sha256_files(*paths: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for path in paths:
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
    return digest.hexdigest()


def resolve_path(root: pathlib.Path, rel: str) -> pathlib.Path:
    candidate = (root / rel).resolve()
    if root != candidate and root not in candidate.parents:
        raise ValueError(f"unsafe image path: {rel}")
    if not candidate.is_file():
        raise ValueError(f"missing image file: {rel}")
    return candidate


def resolve_item(root: pathlib.Path, item: dict) -> pathlib.Path:
    rel = item.get("path", "")
    candidate = resolve_path(root, rel)
    if item.get("size") != candidate.stat().st_size:
        raise ValueError(f"size mismatch: {rel}")
    expected = item.get("sha256", "")
    actual = sha256_files(candidate)
    if expected != actual:
        raise ValueError(f"sha256 mismatch: {rel}")
    return candidate


def validate(root: pathlib.Path) -> int:
    root = root.resolve()
    with (root / "streams/v1/index.json").open(encoding="utf-8") as fh:
        index = json.load(fh)

    if index.get("format") != "index:1.0":
        raise ValueError("invalid simplestreams index.json")
    entry = next(
        (value for value in index.get("index", {}).values()
         if value.get("datatype") == "image-downloads"),
        None,
    )
    if entry is None or entry.get("format") != "products:1.0":
        raise ValueError("index.json does not reference a products:1.0 image list")
    product_names = entry.get("products")
    if not isinstance(product_names, list) or not product_names:
        raise ValueError("index.json has no image products")
    images_path = resolve_path(root, entry.get("path", ""))
    with images_path.open(encoding="utf-8") as fh:
        images = json.load(fh)
    if images.get("datatype") != "image-downloads" or images.get("format") != "products:1.0":
        raise ValueError("invalid images.json header")
    missing_products = set(product_names) - set(images.get("products", {}))
    if missing_products:
        raise ValueError(f"index.json references missing products: {sorted(missing_products)}")

    validated = 0
    for product_name, product in images.get("products", {}).items():
        if not isinstance(product.get("arch"), str) or not product["arch"]:
            raise ValueError(f"product {product_name} has no Incus-compatible arch field")
        if not isinstance(product.get("aliases"), str) or not product["aliases"]:
            raise ValueError(f"product {product_name} aliases must be a comma-separated string")
        for version_name, version in product.get("versions", {}).items():
            items = version.get("items", {})
            meta_item = next((item for item in items.values() if item.get("ftype") == "incus.tar.xz"), None)
            root_item = next((item for item in items.values() if item.get("ftype") == "squashfs"), None)
            if meta_item is None or root_item is None:
                raise ValueError(f"{product_name}/{version_name} is missing incus.tar.xz or squashfs")
            meta_path = resolve_item(root, meta_item)
            root_path = resolve_item(root, root_item)
            combined = sha256_files(meta_path, root_path)
            if meta_item.get("combined_squashfs_sha256") != combined:
                raise ValueError(f"combined fingerprint mismatch: {product_name}/{version_name}")
            for item in items.values():
                resolve_item(root, item)
            validated += 1

    if validated == 0:
        raise ValueError("no usable Incus images found")
    print(f"simple-streams validation OK: {validated} image version(s)")
    return validated


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", help="simple-streams web root")
    args = parser.parse_args()
    validate(pathlib.Path(args.root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
