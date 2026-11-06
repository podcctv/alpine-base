#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <rootfs-dir> <amd64|arm64> <serial> <openssh-version> <output-dir>" >&2
    exit 2
fi

ROOTFS=$(realpath "$1")
ARCH=$2
SERIAL=$3
EXPECTED_OPENSSH=$4
OUT=$5

case "$ARCH" in amd64|arm64) ;; *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;; esac
[[ "$SERIAL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid serial: $SERIAL" >&2; exit 2; }
[[ "$EXPECTED_OPENSSH" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo "invalid OpenSSH version" >&2; exit 2; }
[ -d "$ROOTFS" ] || { echo "rootfs directory does not exist: $ROOTFS" >&2; exit 1; }

DB="$ROOTFS/lib/apk/db/installed"
[ -s "$DB" ] || { echo "Alpine package database is missing" >&2; exit 1; }
OPENSSH=$(awk '
    /^P:openssh-server$/ { wanted=1; next }
    wanted && /^V:/ { sub(/^V:/, ""); print; exit }
    wanted && /^[A-Z]:/ { wanted=0 }
' "$DB")
[ "$OPENSSH" = "$EXPECTED_OPENSSH" ] || {
    echo "OpenSSH package version is '$OPENSSH'; expected '$EXPECTED_OPENSSH'" >&2
    exit 1
}
[ -x "$ROOTFS/sbin/openrc" ] || { echo "OpenRC is missing from rootfs" >&2; exit 1; }
[ -x "$ROOTFS/etc/init.d/sshd" ] || { echo "OpenRC sshd service is missing from rootfs" >&2; exit 1; }
[ -s "$ROOTFS/etc/ssh/sshd_config" ] || { echo "sshd_config is missing from rootfs" >&2; exit 1; }
if compgen -G "$ROOTFS/etc/ssh/ssh_host_*" >/dev/null; then
    echo "refusing to publish rootfs containing SSH host keys" >&2
    exit 1
fi

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
NAME="rootfs-alpine-${ARCH}-${SERIAL}.tar.zst"
TMP="$OUT/.${NAME}.tmp"
[ ! -e "$OUT/$NAME" ] || {
    echo "refusing to replace existing versioned Runman archive: $OUT/$NAME" >&2
    exit 1
}
trap 'rm -f -- "$TMP"' EXIT

tar --numeric-owner --xattrs --xattrs-include='*' -C "$ROOTFS" -cf - . \
    | zstd -q -19 -T0 -f -o "$TMP"
[ -s "$TMP" ] || { echo "Runman rootfs archive is empty" >&2; exit 1; }
mv -f -- "$TMP" "$OUT/$NAME"
trap - EXIT
printf 'Packaged %s (%s bytes) with openssh-server %s\n' \
    "$OUT/$NAME" "$(stat -c %s "$OUT/$NAME")" "$OPENSSH"
