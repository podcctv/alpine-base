#!/bin/bash
# scripts/build-podman.sh — Build Podman OCI image
#
# Usage: ./scripts/build-podman.sh [tag]
# Default tag: localhost/alpine-base:3.24-test

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
CONTAINERFILE="$REPO_ROOT/podman/Containerfile"
TAG="${1:-localhost/alpine-base:${VERSION}-test}"

echo "=========================================="
echo " Building Podman OCI image — Alpine $VERSION"
echo "=========================================="
echo " Containerfile: $CONTAINERFILE"
echo " Tag:           $TAG"
echo ""

# Build
podman build -t "$TAG" -f "$CONTAINERFILE" "$REPO_ROOT"

echo ""
echo "=== Podman build complete ==="
podman images "$TAG"

echo ""
echo "To test with password login:"
echo "  printf '%%s' 'YourStrongPassword' > /tmp/root_password"
echo "  podman secret create alpine_root_password /tmp/root_password"
echo "  podman run -d --name alpine-test -p 2222:22 --secret alpine_root_password,target=root_password $TAG"
echo "  ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no root@127.0.0.1"
