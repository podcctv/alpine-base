#!/bin/sh
# common/setup-base.sh — 基础初始化与镜像清理
# 安装基础包、复制 sshd_config、启用 OpenRC sshd、清理镜像特征。
# 镜像中不设置固定 root 密码。

set -eu

PACKAGES_FILE="/tmp/packages.txt"
SSHD_CONFIG_SRC="/tmp/sshd_config"

echo "=== Installing base packages ==="
apk update
if [ -f "$PACKAGES_FILE" ]; then
    apk add --no-cache $(cat "$PACKAGES_FILE" | grep -v '^#' | xargs)
else
    apk add --no-cache openssh-server openssh-client-default ca-certificates bash
fi

echo "=== Configuring sshd ==="
mkdir -p /etc/ssh
if [ -f "$SSHD_CONFIG_SRC" ]; then
    cp "$SSHD_CONFIG_SRC" /etc/ssh/sshd_config
fi
mkdir -p /run/sshd

echo "=== Enabling sshd on OpenRC ==="
rc-update add sshd default 2>/dev/null || true

echo "=== Cleaning image fingerprints ==="
# Remove SSH host keys — each instance generates its own on first boot
rm -f /etc/ssh/ssh_host_*

# Remove machine-id — each instance gets a unique one
rm -f /etc/machine-id

# Clear shell history
rm -f /root/.bash_history /root/.ash_history 2>/dev/null || true

# Clear apk cache
rm -rf /var/cache/apk/*

# Remove temporary files
rm -rf /tmp/* 2>/dev/null || true

echo "=== setup-base.sh complete ==="
