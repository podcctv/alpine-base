#!/bin/sh
# podman/entrypoint.sh — OCI container entrypoint
# 1. Create /run/sshd
# 2. Generate per-instance host keys
# 3. Set root password from secret (if provided)
# 4. Validate sshd config
# 5. Run sshd in foreground

set -eu

echo "=== entrypoint: starting ==="

# Ensure /run/sshd exists
mkdir -p /run/sshd

# Generate host keys (image ships without them)
echo "=== entrypoint: generating host keys ==="
ssh-keygen -A

# Set root password from secret file if mounted
# Note: do NOT delete /run/secrets/* files — the tmpfs mount is managed by
# the container runtime and "rm" can fail with "Resource busy".
if [ -f /run/secrets/root_password ]; then
    echo "=== entrypoint: setting root password from secret ==="
    PASS=$(cat /run/secrets/root_password)
    printf 'root:%s\n' "$PASS" | chpasswd
elif [ -n "${ROOT_PASSWORD:-}" ]; then
    echo "=== entrypoint: setting root password from env ==="
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
else
    echo "WARNING: No root password provided. SSH password login will not work."
    echo "Mount a secret named 'root_password' or set ROOT_PASSWORD env."
fi

# Validate sshd configuration
echo "=== entrypoint: validating sshd config ==="
/usr/sbin/sshd -t

# Run sshd in foreground with logging to stderr
echo "=== entrypoint: starting sshd ==="
exec /usr/sbin/sshd -D -e
