#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT_DIR="${1:-$ROOT/output/incus}"
OUTPUT_DIR="${2:-$ROOT/incus-server/www/runman}"
SERIAL="${3:-local_$(date -u +%Y%m%d%H%M%S)_$$}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

[[ "$SERIAL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid serial: $SERIAL" >&2; exit 2; }
for command_name in unsquashfs zstd tar python3; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "'$command_name' is required to build the local Runman feed" >&2
        exit 1
    }
done

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || { echo "run as root or install sudo" >&2; exit 1; }
        sudo "$@"
    fi
}

WORK="$(mktemp -d)"
cleanup() {
    run_root rm -rf -- "$WORK"
}
trap cleanup EXIT
mkdir -p "$OUTPUT_DIR"
ARCHIVES="$WORK/runman"
mkdir -p "$ARCHIVES"

for arch in amd64 arm64; do
    squashfs="$INPUT_DIR/alpine/$arch/rootfs.squashfs"
    [ -s "$squashfs" ] || {
        echo "missing Alpine $arch Incus rootfs: $squashfs" >&2
        exit 1
    }
    rootfs="$WORK/rootfs-$arch"
    run_root unsquashfs -no-progress -xattrs -d "$rootfs" "$squashfs" >/dev/null
    installed=$(awk '
        /^P:openssh-server$/ { wanted=1; next }
        wanted && /^V:/ { sub(/^V:/, ""); print; exit }
        wanted && /^[A-Z]:/ { wanted=0 }
    ' "$rootfs/lib/apk/db/installed")
    expected="${ALPINE_OPENSSH_FIXED_VERSION:-$installed}"
    run_root bash "$ROOT/scripts/package-runman-rootfs.sh" "$rootfs" "$arch" "$SERIAL" \
        "$expected" "$ARCHIVES"
done

python3 "$ROOT/scripts/generate-runman-feed.py" \
    --input-dir "$ARCHIVES" --output-dir "$OUTPUT_DIR" \
    --version "$VERSION" --serial "$SERIAL"
python3 "$ROOT/scripts/validate-runman-feed.py" "$OUTPUT_DIR"
