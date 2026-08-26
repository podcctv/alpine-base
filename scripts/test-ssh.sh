#!/bin/bash
# scripts/test-ssh.sh — SSH password login release gate
#
# All P0 items must pass before promoting to stable.
# Usage:
#   ./scripts/test-ssh.sh incus <instance-name> [password]
#   ./scripts/test-ssh.sh podman <container-name> [password]
#   ./scripts/test-ssh.sh local (run checks inside current shell)
#
# Exit 0 = all P0 passed; non-zero = failure.

set -eu

MODE="${1:-}"
NAME="${2:-}"
PASS="${3:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1 (P1)"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# Helper to run command inside the target
run_in() {
    if [ "$MODE" = "incus" ]; then
        incus exec "$NAME" -- "$@"
    elif [ "$MODE" = "podman" ]; then
        podman exec "$NAME" -- "$@"
    elif [ "$MODE" = "local" ]; then
        "$@"
    else
        echo "Usage: $0 {incus|podman|local} [name] [password]"
        exit 1
    fi
}

# Helper to run SSH test
do_ssh_login() {
    local ip="$1"
    local password="$2"
    sshpass -p "$password" ssh \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "root@$ip" \
        'echo SSH_LOGIN_OK && hostname' 2>/dev/null
}

echo "============================================"
echo "  SSH Password Login — Release Gate"
echo "  Mode: $MODE  Target: ${NAME:-local}"
echo "============================================"
echo ""

# --- P0 Checks ---

# 1. sshd config syntax
echo "Checking sshd -t..."
if run_in /usr/sbin/sshd -t 2>/dev/null; then
    log_pass "sshd config syntax valid"
else
    log_fail "sshd config syntax invalid"
fi

# 2. permitrootlogin yes
echo "Checking permitrootlogin..."
RESULT=$(run_in /usr/sbin/sshd -T 2>/dev/null | grep '^permitrootlogin ' || echo "")
if echo "$RESULT" | grep -q 'yes'; then
    log_pass "PermitRootLogin yes"
else
    log_fail "PermitRootLogin is not yes (got: $RESULT)"
fi

# 3. passwordauthentication yes
echo "Checking passwordauthentication..."
RESULT=$(run_in /usr/sbin/sshd -T 2>/dev/null | grep '^passwordauthentication ' || echo "")
if echo "$RESULT" | grep -q 'yes'; then
    log_pass "PasswordAuthentication yes"
else
    log_fail "PasswordAuthentication is not yes (got: $RESULT)"
fi

# 4. pubkeyauthentication yes (P1)
echo "Checking pubkeyauthentication..."
RESULT=$(run_in /usr/sbin/sshd -T 2>/dev/null | grep '^pubkeyauthentication ' || echo "")
if echo "$RESULT" | grep -q 'yes'; then
    log_skip "PubkeyAuthentication yes"
else
    log_skip "PubkeyAuthentication is not yes (got: $RESULT)"
fi

# 5. root not locked
echo "Checking root password status..."
SHADOW=$(run_in awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null || echo "")
if [ -n "$SHADOW" ] && [ "$SHADOW" != "!" ] && [ "$SHADOW" != "*" ] && [ "$SHADOW" != "!!" ]; then
    log_pass "root has valid password (not locked)"
else
    log_fail "root is locked or has no password (shadow: $SHADOW)"
fi

# 6. sshd in OpenRC
if [ "$MODE" = "incus" ]; then
    echo "Checking sshd in OpenRC..."
    if run_in rc-status 2>/dev/null | grep -q sshd; then
        log_pass "sshd in OpenRC service list"
    else
        log_fail "sshd not in OpenRC services"
    fi
else
    log_skip "OpenRC check (only for Incus)"
fi

# 7. TCP/22 listening
echo "Checking port 22..."
if run_in sh -c 'ss -lntp 2>/dev/null || netstat -tlnp 2>/dev/null' | grep -q ':22 '; then
    log_pass "Port 22 listening"
else
    log_fail "Port 22 not listening"
fi

# 8. Real password SSH login (requires IP and password)
if [ -n "$PASS" ] && [ "$MODE" != "local" ]; then
    echo "Checking real SSH login..."
    # Get IP address
    if [ "$MODE" = "incus" ]; then
        IP=$(incus list "$NAME" --format csv -c 4 | head -1 | awk -F' ' '{print $1}')
    elif [ "$MODE" = "podman" ]; then
        IP="127.0.0.1"
        # Try to get mapped port
        PORT=$(podman port "$NAME" 22 2>/dev/null | head -1 | awk -F: '{print $2}')
        PORT="${PORT:-22}"
    fi

    SSH_PORT="${PORT:-22}"
    if [ -n "$IP" ] && SSH_RESULT=$(do_ssh_login "$IP" "$PASS" 2>/dev/null); then
        if echo "$SSH_RESULT" | grep -q "SSH_LOGIN_OK"; then
            log_pass "Real password SSH login successful"
        else
            log_fail "SSH login returned unexpected output"
        fi
    else
        log_fail "Real password SSH login failed"
    fi
else
    log_skip "Real SSH login (no password provided)"
fi

# 9. Reboot + SSH (Incus only)
if [ "$MODE" = "incus" ] && [ -n "$PASS" ]; then
    echo "Checking reboot persistence..."
    incus restart "$NAME" 2>/dev/null
    sleep 3
    if run_in rc-service sshd status 2>/dev/null | grep -q started; then
        # Try SSH again after reboot
        IP=$(incus list "$NAME" --format csv -c 4 | head -1 | awk -F' ' '{print $1}')
        if [ -n "$IP" ] && do_ssh_login "$IP" "$PASS" 2>/dev/null | grep -q "SSH_LOGIN_OK"; then
            log_pass "SSH works after reboot"
        else
            log_fail "SSH failed after reboot"
        fi
    else
        log_fail "sshd not started after reboot"
    fi
else
    log_skip "Reboot SSH test (Incus + password required)"
fi

# 10. Host key uniqueness (needs two instances — informational)
log_skip "Host key uniqueness (requires two instances, manual check)"

# 11. No empty passwords
echo "Checking PermitEmptyPasswords..."
if run_in grep -q '^PermitEmptyPasswords no' /etc/ssh/sshd_config 2>/dev/null; then
    log_pass "PermitEmptyPasswords no"
else
    log_fail "PermitEmptyPasswords not set to no"
fi

# 12. DNS (P1)
echo "Checking DNS..."
if run_in nslookup github.com 2>/dev/null | grep -q 'Address'; then
    log_skip "DNS resolution works"
else
    log_skip "DNS resolution failed (P1)"
fi

# 13. HTTPS (P1)
echo "Checking HTTPS..."
if run_in curl -fsSI https://github.com 2>/dev/null | head -1 | grep -q 'HTTP'; then
    log_skip "HTTPS works"
else
    log_skip "HTTPS failed (P1)"
fi

# 14. APK (P1)
echo "Checking apk..."
if run_in apk update 2>/dev/null | grep -q 'OK'; then
    log_skip "APK update works"
else
    log_skip "APK update failed (P1)"
fi

echo ""
echo "============================================"
echo "  Results: ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, ${YELLOW}$SKIP_COUNT skipped${NC}"
echo "============================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}P0 checks failed — DO NOT promote to stable${NC}"
    exit 1
fi

echo -e "${GREEN}All P0 checks passed — safe to promote to stable${NC}"
exit 0
