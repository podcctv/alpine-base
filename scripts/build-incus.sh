#!/bin/bash
# scripts/build-incus.sh — Build Incus system container image using distrobuilder
#
# Usage: ./scripts/build-incus.sh
#
# Prerequisites:
#   - distrobuilder installed (snap or from source)
#   - Alpine 3.24 source reachable
#
# Output: output/incus/ (incus.tar.xz + rootfs.squashfs)

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
IMAGE_YAML="$REPO_ROOT/incus/image.yaml"
OUTPUT_DIR="$REPO_ROOT/output/incus"

echo "=========================================="
echo " Building Incus image — Alpine $VERSION"
echo "=========================================="
echo " YAML:   $IMAGE_YAML"
echo " Output: $OUTPUT_DIR"
echo ""

# Clean previous output
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build
sudo distrobuilder build-incus "$IMAGE_YAML" "$OUTPUT_DIR"

echo ""
echo "=== Incus build complete ==="
ls -lh "$OUTPUT_DIR"

# Show import hint
echo ""
echo "To import into Incus Image Store:"
echo "  incus image import $OUTPUT_DIR/incus.tar.xz $OUTPUT_DIR/rootfs.squashfs --alias alpine/${VERSION}-test"
