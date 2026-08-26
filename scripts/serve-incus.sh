#!/bin/bash
# scripts/serve-incus.sh — One-click deploy of the self-hosted Incus image server.
#
# Incus pulls images over the simple-streams protocol. This script stands up a
# static simple-streams server (nginx in Docker) so any Incus host on the network
# can `incus launch alpine-base:alpine/3.24` straight from your machine.
#
# It automatically obtains the image tree (in order of preference):
#   1. an existing incus-server/www/streams/v1/index.json  (already prepared)
#   2. a local build in output/incus/                       (run build-incus.sh)
#   3. the incus-streams.tar.gz asset from the rolling `continuous` release
#      (downloaded over the public URL — no login needed for a public repo)
#
# Usage:
#   ./scripts/serve-incus.sh            # deploy or update (idempotent)
#   ./scripts/serve-incus.sh --download # force re-download from `continuous`
#   ./scripts/serve-incus.sh --download --release-tag v1.0.0
#   ./scripts/serve-incus.sh --stop     # stop the server
#
# After it is up, on any Incus host:
#   incus remote add alpine-base http://<this-host>:8080 --protocol=simplestreams
#   incus launch alpine-base:alpine/3.24 my-instance

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PORT=8080
REMOTE_NAME=alpine-base
OWNER_REPO="podcctv/alpine-base"
WWW_DIR="incus-server/www"
RELEASE_TAG="${ALPINE_BASE_RELEASE_TAG:-continuous}"

STOP=0
FORCE_DOWNLOAD=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stop)     STOP=1 ;;
    --download) FORCE_DOWNLOAD=1 ;;
    --release-tag)
      [ "$#" -ge 2 ] || { echo "ERROR: --release-tag requires a value"; exit 1; }
      RELEASE_TAG="$2"
      shift
      ;;
    -h|--help)  tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
  esac
  shift
done

case "$RELEASE_TAG" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: invalid release tag '$RELEASE_TAG'"
    exit 1
    ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not found."; exit 1; }; }

# --- Resolve docker compose (v2 plugin preferred, v1 fallback) ---
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  DC=""
fi

echo "=========================================="
echo " Incus image server (simple-streams)"
echo "=========================================="

# --- Stop mode ---
if [ "$STOP" = 1 ]; then
  if [ -n "$DC" ]; then
    echo "Stopping Incus image server..."
    (cd "$REPO_ROOT/incus-server" && $DC down) || true
  else
    echo "docker compose not found; nothing to stop."
  fi
  exit 0
fi

# --- Ensure the simple-streams tree exists ---
ensure_streams() {
  # `www` is gitignored, so it may not exist on a fresh clone — create it first
  # so the download/extract and local-generate steps can write into it.
  mkdir -p "$WWW_DIR"
  if [ "$FORCE_DOWNLOAD" = 0 ] && [ -f "$WWW_DIR/streams/v1/index.json" ]; then
    echo "[streams] using existing tree at $WWW_DIR"
    return
  fi
  if [ "$FORCE_DOWNLOAD" = 0 ] \
     && [ -f output/incus/incus.tar.xz ] && [ -f output/incus/rootfs.squashfs ]; then
    echo "[streams] generating from output/incus ..."
    need python3
    python3 scripts/generate-streams.py \
      --input-dir output/incus \
      --output-dir "$WWW_DIR"
    return
  fi
  echo "[streams] downloading incus-streams.tar.gz from release '$RELEASE_TAG' ..."
  TMP="$(mktemp -d)"
  ASSET="incus-streams.tar.gz"
  # `continuous` is rebuilt from every main push.  GitHub's `/latest/` endpoint
  # deliberately ignores prereleases, so using it here would silently serve an
  # older stable build instead of the just-built rolling image.
  ASSET_URL="https://github.com/$OWNER_REPO/releases/download/$RELEASE_TAG/$ASSET"
  if command -v curl >/dev/null 2>&1; then
    curl --retry 3 --retry-all-errors -fSL "$ASSET_URL" -o "$TMP/$ASSET" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP/$ASSET" "$ASSET_URL" || true
  fi
  # Fallback to gh only if the public download did not produce a file
  #    (e.g. private repo, or the asset name changed).
  if [ ! -s "$TMP/$ASSET" ]; then
    echo "[streams] public download failed, retrying with 'gh' ..."
    need gh
    gh release download "$RELEASE_TAG" --repo "$OWNER_REPO" --pattern "$ASSET" --dir "$TMP" \
      || { echo "ERROR: failed to download $ASSET (need network + 'gh' auth for private repos)."; rm -rf "$TMP"; exit 1; }
  fi

  # Validate in a temporary directory before replacing live metadata.  This
  # prevents a partial/corrupt download from taking a healthy mirror offline.
  need python3
  mkdir -p "$TMP/tree"
  tar -xzf "$TMP/$ASSET" -C "$TMP/tree"
  python3 - "$TMP/tree" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
index_path = root / "streams/v1/index.json"
images_path = root / "streams/v1/images.json"
with index_path.open(encoding="utf-8") as fh:
    index = json.load(fh)
with images_path.open(encoding="utf-8") as fh:
    images = json.load(fh)
if index.get("datatype") != "index:1.0" or index.get("format") != "simplestreams:1.0":
    raise SystemExit("ERROR: invalid simplestreams index.json")
if "streams/v1/images.json" not in index.get("index", {}):
    raise SystemExit("ERROR: index.json does not reference images.json")
for product in images.get("products", {}).values():
    for version in product.get("versions", {}).values():
        for item in version.get("items", {}).values():
            rel = item.get("path", "")
            candidate = (root / rel).resolve()
            if root not in candidate.parents or not candidate.is_file():
                raise SystemExit(f"ERROR: missing or unsafe image path: {rel}")
PY
  cp -a "$TMP/tree/." "$WWW_DIR/"
  rm -rf "$TMP"
  echo "[streams] validated and extracted to $WWW_DIR"
}

ensure_streams

# --- Docker prerequisite ---
if [ -z "$DC" ]; then
  echo ""
  echo "ERROR: docker compose not found. Install Docker Desktop (or docker-compose),"
  echo "       or serve the tree manually, e.g.:"
  echo "         python3 -m http.server $PORT --directory $WWW_DIR"
  exit 1
fi

# --- Build + start ---
echo ""
echo "[docker] building + starting on :$PORT ..."
(cd "$REPO_ROOT/incus-server" && $DC up -d --build --force-recreate)

# --- Health check ---
echo "[health] waiting for http://localhost:$PORT/streams/v1/index.json ..."
OK=0
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:$PORT/streams/v1/index.json" >/dev/null 2>&1; then
    echo "[health] OK — endpoint reachable"
    OK=1
    break
  fi
  sleep 1
done
[ "$OK" = 1 ] || { echo "ERROR: endpoint not reachable after 30s. Check 'docker logs'."; exit 1; }

# --- Detect a LAN address for the client command ---
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "$HOST_IP" ]; then
  HOST_IP="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
fi
[ -z "$HOST_IP" ] && HOST_IP="<host-ip>"

echo ""
echo "=== Incus image server is running ==="
echo "  Local:  http://localhost:$PORT/streams/v1/index.json"
echo "  LAN:    http://$HOST_IP:$PORT/streams/v1/index.json"
echo ""
echo "On any Incus host, add this remote and launch:"
echo "  incus remote add $REMOTE_NAME http://$HOST_IP:$PORT --protocol=simplestreams"
echo "  incus launch $REMOTE_NAME:alpine/3.24 my-instance"
