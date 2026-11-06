#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WWW_DIR="$ROOT/incus-server/www"
RELEASE_TAG="${ALPINE_BASE_RELEASE_TAG:-continuous}"
RELEASE_URL="https://github.com/podcctv/alpine-base/releases/download/$RELEASE_TAG/runman-feed.tar.gz"
PUBLIC_BASE="https://alpine-incus-base.428048.xyz/runman"
PUBLIC_URL="$PUBLIC_BASE/images.json"

[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "invalid release tag: $RELEASE_TAG" >&2
    exit 2
}
[[ -d "$WWW_DIR" ]] || {
    echo "image web root is missing: $WWW_DIR" >&2
    exit 1
}
for command_name in curl tar python3 grep awk df; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "'$command_name' is required" >&2
        exit 1
    }
done

WORK="$(mktemp -d)"
STAGE=""
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OLD="$WWW_DIR/runman.before-$STAMP"
FAILED="$WWW_DIR/runman.failed-$STAMP"
SWAPPED=0
HAD_OLD=0
cleanup() {
    [ -z "$STAGE" ] || rm -rf -- "$STAGE"
    rm -rf -- "$WORK"
}
rollback() {
    if [ "$SWAPPED" = 1 ]; then
        if [ -e "$WWW_DIR/runman" ]; then
            mv -- "$WWW_DIR/runman" "$FAILED"
        fi
        if [ "$HAD_OLD" = 1 ] && [ -d "$OLD" ]; then
            mv -- "$OLD" "$WWW_DIR/runman"
            echo "restored prior feed from $OLD" >&2
        fi
    fi
}
on_signal() {
    rollback
    exit 1
}
trap cleanup EXIT
trap 'rollback' ERR
trap 'on_signal' HUP INT TERM

for path in "$WWW_DIR" "$WORK"; do
    available_mib=$(df -Pm "$path" | awk 'NR == 2 {print $4}')
    [[ "$available_mib" =~ ^[0-9]+$ ]] || {
        echo "cannot determine free space for $path" >&2
        exit 1
    }
    [ "$available_mib" -ge 200 ] || {
        echo "only $available_mib MiB is free on the filesystem containing $path; need at least 200 MiB" >&2
        exit 1
    }
done

ARCHIVE="$WORK/runman-feed.tar.gz"
curl -fSL --retry 3 --connect-timeout 20 --max-time 300 \
    -o "$ARCHIVE" "$RELEASE_URL"
if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "release archive contains an unsafe path" >&2
    exit 1
fi

STAGE="$(mktemp -d "$WWW_DIR/.runman-stage.XXXXXXXX")"
tar -xzf "$ARCHIVE" -C "$STAGE" --no-same-owner --no-same-permissions
python3 "$ROOT/scripts/validate-runman-feed.py" "$STAGE"

if [ -L "$WWW_DIR/runman" ]; then
    echo "refusing to replace symlink: $WWW_DIR/runman" >&2
    exit 1
fi
if [ -e "$WWW_DIR/runman" ]; then
    [ ! -e "$OLD" ] || { echo "refusing to overwrite rollback directory: $OLD" >&2; exit 1; }
    mv -- "$WWW_DIR/runman" "$OLD"
    HAD_OLD=1
fi
SWAPPED=1
mv -- "$STAGE" "$WWW_DIR/runman"
STAGE=""

curl -fsS --retry 2 --connect-timeout 5 --max-time 20 \
    http://127.0.0.1:8080/runman/images.json >/dev/null
curl -fsS --retry 2 --connect-timeout 10 --max-time 30 \
    "$PUBLIC_URL" -o "$WORK/live-images.json"
python3 - "$WORK/live-images.json" "$WWW_DIR/runman/images.json" <<'PY'
import json
import pathlib
import sys

live, local = (json.loads(pathlib.Path(path).read_text(encoding="utf-8")) for path in sys.argv[1:])
if live != local:
    raise SystemExit("public Runman manifest does not match the deployed feed")
PY
while IFS= read -r file; do
    curl -fsS --range 0-0 --retry 2 --connect-timeout 10 --max-time 30 \
        -o /dev/null "$PUBLIC_BASE/$file"
done < <(python3 - "$WWW_DIR/runman/images.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for entry in manifest["images"]:
    print(entry["file"])
PY
)

SWAPPED=0
echo "Runman Alpine feed deployed and verified: $PUBLIC_URL"
if [ "$HAD_OLD" = 1 ]; then
    echo "Previous feed retained at: $OLD"
else
    echo "No previous Runman feed existed to back up."
fi
