#!/bin/bash
# scripts/build-incus.sh — Build Incus system container image using distrobuilder
#
# Usage: ./scripts/build-incus.sh [alpine|debian] [amd64|arm64]
#
# Prerequisites:
#   - distrobuilder installed (snap or from source)
#   - Alpine 3.24 source reachable
#
# Output: output/incus/ (incus.tar.xz + rootfs.squashfs)

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO="${1:-alpine}"
HOST_MACHINE="$(uname -m)"
case "$HOST_MACHINE" in
    x86_64|amd64) NATIVE_ARCH=amd64 ;;
    aarch64|arm64) NATIVE_ARCH=arm64 ;;
    *)
        echo "ERROR: unsupported native architecture '$HOST_MACHINE'" >&2
        exit 2
        ;;
esac
ARCH="${2:-$NATIVE_ARCH}"
case "$ARCH" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
esac
case "$ARCH" in
    amd64|arm64) ;;
    *)
        echo "Usage: $0 [alpine|debian] [amd64|arm64]" >&2
        exit 2
        ;;
esac
if [ "$ARCH" != "$NATIVE_ARCH" ]; then
    echo "ERROR: requested $ARCH on native $NATIVE_ARCH host." >&2
    echo "Use a native $ARCH runner so the image contents match its architecture." >&2
    exit 2
fi
case "$DISTRO" in
    alpine)
        VERSION="$(cat "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
        IMAGE_YAML="$REPO_ROOT/incus/image.yaml"
        ;;
    debian)
        VERSION="$(cat "$REPO_ROOT/debian/VERSION" | tr -d '[:space:]')"
        IMAGE_YAML="$REPO_ROOT/debian/incus.yaml"
        ;;
    *)
        echo "Usage: $0 [alpine|debian] [amd64|arm64]" >&2
        exit 2
        ;;
esac
OUTPUT_DIR="$REPO_ROOT/output/incus/$DISTRO/$ARCH"

echo "=========================================="
echo " Building Incus image — $DISTRO $VERSION ($ARCH)"
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
echo "  incus image import $OUTPUT_DIR/incus.tar.xz $OUTPUT_DIR/rootfs.squashfs --alias ${DISTRO}/${VERSION}-test"
