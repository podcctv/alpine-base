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
#   3. the incus-streams.tar.gz asset from the latest GitHub release
#      (downloaded over the public URL — no login needed for a public repo)
#
# Usage:
#   ./scripts/serve-incus.sh            # deploy or update (idempotent)
#   ./scripts/serve-incus.sh --download # force re-download from the release
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

STOP=0
FORCE_DOWNLOAD=0
for a in "$@"; do
  case "$a" in
    --stop)     STOP=1 ;;
    --download) FORCE_DOWNLOAD=1 ;;
    -h|--help)  tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (use --help)"; exit 1 ;;
  esac
done

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
  echo "[streams] downloading incus-streams.tar.gz from the latest release ..."
  TMP="$(mktemp -d)"
  ASSET="incus-streams.tar.gz"
  # Public repos serve release assets over a public URL — no login required.
  # 1) Try the 'latest' download alias.
  ASSET_URL="https://github.com/$OWNER_REPO/releases/latest/download/$ASSET"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL "$ASSET_URL" -o "$TMP/$ASSET" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP/$ASSET" "$ASSET_URL" || true
  fi
  # 2) Some environments don't resolve the 'latest' alias; resolve the tag via
  #    the public API and retry the explicit (tagged) download URL.
  if [ ! -s "$TMP/$ASSET" ]; then
    echo "[streams] 'latest' alias unresolved, querying latest tag via API ..."
    TAG=$(curl -fsSL -H "User-Agent: serve-incus.sh" \
            "https://api.github.com/repos/$OWNER_REPO/releases/latest" \
            | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [ -n "$TAG" ]; then
      ASSET_URL="https://github.com/$OWNER_REPO/releases/download/$TAG/$ASSET"
      if command -v curl >/dev/null 2>&1; then
        curl -fSL "$ASSET_URL" -o "$TMP/$ASSET" || true
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TMP/$ASSET" "$ASSET_URL" || true
      fi
    fi
  fi
  # 3) Fallback to gh only if the public download did not produce a file
  #    (e.g. private repo, or the asset name changed).
  if [ ! -s "$TMP/$ASSET" ]; then
    echo "[streams] public download failed, retrying with 'gh' ..."
    need gh
    gh release download --repo "$OWNER_REPO" --pattern "$ASSET" --dir "$TMP" \
      || { echo "ERROR: failed to download $ASSET (need network + 'gh' auth for private repos)."; rm -rf "$TMP"; exit 1; }
  fi
  tar -xzf "$TMP/$ASSET" -C "$WWW_DIR"
  rm -rf "$TMP"
  echo "[streams] extracted to $WWW_DIR"
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
