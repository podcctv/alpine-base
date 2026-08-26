# Versioning & Release Rules

## Version Naming

| Type | Example | Description |
|------|---------|-------------|
| Alpine stable | `3.24` | Rolling stable alias/tag; points to current verified build |
| Immutable Incus | `3.24-v1.0.0` | Once published, never modified; rollback baseline |
| Git Tag | `v1.0.0` | Corresponds to immutable image version; source traceable |
| Podman OCI (immutable) | `ghcr.io/podcctv/flanker-alpine-base:3.24-v1.0.0` | Immutable image tag |
| Podman OCI (stable) | `ghcr.io/podcctv/flanker-alpine-base:3.24` | Rolling stable tag |

## Release Gate

**All P0 items in SSH verification must pass** before promoting to stable. Specifically:

1. `sshd -t` passes with exit code 0
2. `PermitRootLogin yes` in `sshd -T` output
3. `PasswordAuthentication yes` in `sshd -T` output
4. root not locked (`/etc/shadow` password field is not `!`, `*`, or `!!`)
5. sshd in OpenRC service list
6. TCP/22 listening
7. Real password-only SSH login succeeds
8. SSH works after reboot
9. Host Key unique across instances
10. `PermitEmptyPasswords no`

> The most critical check is: `sshd -T` final values correct + real password-only client login + reboot persistence.

## Release Flow

```
1. Build test image          → ./scripts/build-all.sh
2. Launch test instance      → incus launch flanker-alpine/3.24-test alpine-ssh-test
3. Set root password         → printf 'root:%s\n' "$PASS" | incus exec alpine-ssh-test -- chpasswd
4. Generate host keys        → incus exec alpine-ssh-test -- ssh-keygen -A
5. Run SSH verification      → ./scripts/test-ssh.sh incus alpine-ssh-test "$PASS"
6. If all P0 pass:
   a. Tag Git                → git tag -a v1.0.0 -m '...'
   b. Update Incus alias     → incus image alias create flanker-alpine/3.24 <fingerprint>
   c. Tag & push Podman      → podman tag + podman push (GHCR)
```

## Maintenance Cycle

| Task | Frequency | Notes |
|------|------------|-------|
| Package update + rebuild | Monthly | Check Alpine security advisories |
| High-risk CVE | Immediately | Rebuild + full SSH gate + release patch |
| Alpine minor version (3.24.x) | As needed | VERSION stays `3.24`; full SSH gate still required |
| Alpine major version (3.25) | New branch | Create independent stable alias; do not overwrite 3.24 |

## Rollback

### Incus

```
# Point 3.24 alias back to previous fingerprint
incus image alias delete flanker-alpine/3.24
incus image alias create flanker-alpine/3.24 <old-fingerprint>
```

Existing running instances are not affected by alias changes.

### Podman

```
# Pull the known-good immutable tag
podman pull ghcr.io/podcctv/flanker-alpine-base:3.24-v1.0.0
```

`latest` is a rolling tag updated on every successful `main` build. It is convenient for testing, but production deployments should pin an immutable tag like `3.24-v1.0.0` to avoid surprises.

## Backup

| Object | Method | Notes |
|--------|--------|-------|
| Source code | GitHub | Git is the single source of truth; enable 2FA |
| Incus image | `incus image export` | Fast recovery / offline copy; not a source replacement |
