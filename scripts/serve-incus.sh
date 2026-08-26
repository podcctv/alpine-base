#!/bin/bash
# scripts/serve-incus.sh — Generate the simple-streams tree and launch the
# self-hosted Incus image server with Docker.
#
# Prerequisites:
#   - A built Incus image in output/incus/ (incus.tar.xz + rootfs.squashfs)
#     produced by ./scripts/build-incus.sh
#   - Docker + docker compose available
#
# What it does:
#   1. ./scripts/generate-streams.py  -> incus-server/www/streams/v1/...
#   2. docker compose up -d           -> serves on http://0.0.0.0:8080
#
# After it is up, on any Incus host:
#   incus remote add alpine-base http://<this-host>:8080 --protocol=simplestreams
#   incus launch alpine-base:alpine/3.24 my-instance

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo " Incus image server (simple-streams)"
echo "=========================================="

if [ ! -f output/incus/incus.tar.xz ] || [ ! -f output/incus/rootfs.squashfs ]; then
    echo "ERROR: output/incus/incus.tar.xz + rootfs.squashfs not found."
    echo "       Run './scripts/build-incus.sh' first (or download the"
    echo "       'alpine-3.24-incus' artifact from CI / GitHub Release)."
    exit 1
fi

echo "[1/2] Generating simple-streams tree -> incus-server/www ..."
python3 scripts/generate-streams.py \
    --input-dir output/incus \
    --output-dir incus-server/www

echo "[2/2] Starting Docker image server on :8080 ..."
cd incus-server
if command -v docker >/dev/null 2>&1; then
    docker compose up -d --build
else
    echo "ERROR: docker not found. Install Docker, or serve incus-server/www"
    echo "       with any static web server (e.g. 'python3 -m http.server 8080')."
    exit 1
fi

echo ""
echo "=== Server is up ==="
echo "Verify:  curl -s http://localhost:8080/streams/v1/index.json | head"
echo "Client: incus remote add alpine-base http://<host>:8080 --protocol=simplestreams"
