#!/bin/bash
# scripts/release.sh — Promote a tested image to stable
#
# Usage: ./scripts/release.sh <version> [image-fingerprint-or-tag]
# Example:
#   ./scripts/release.sh v1.0.0              # tags Git + updates both Incus alias and Podman tag
#   ./scripts/release.sh v1.0.0 <fingerprint> # Incus fingerprint override
#
# Workflow:
#   1. Run test-ssh.sh — must pass all P0
#   2. Tag Git version
#   3. Update Incus stable alias
#   4. Tag Podman OCI stable

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: $0 <version> [fingerprint]}"
FP_OR_TAG="${2:-}"

ALPINE_VER="$(cat "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
INCUS_ALIAS="flanker-alpine/${ALPINE_VER}"
INCUS_TEST_ALIAS="flanker-alpine/${ALPINE_VER}-test"
PODMAN_TEST="localhost/flanker-alpine-base:${ALPINE_VER}-test"
PODMAN_STABLE="localhost/flanker-alpine-base:${ALPINE_VER}"
GHCR_STABLE="ghcr.io/podcctv/flanker-alpine-base:${ALPINE_VER}"
GHCR_IMMUTABLE="ghcr.io/podcctv/flanker-alpine-base:${ALPINE_VER}-${VERSION}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "##############################################"
echo "#  Release: $VERSION (Alpine $ALPINE_VER)    #"
echo "##############################################"
echo ""

# Step 1: Run SSH gate
echo "--- [1/4] Running SSH verification gate ---"
if [ -x "$REPO_ROOT/scripts/test-ssh.sh" ]; then
    echo "NOTE: test-ssh.sh requires a running instance."
    echo "Run manually: ./scripts/test-ssh.sh incus <instance> <password>"
    echo "This script assumes you have already verified."
    read -p "Have all P0 SSH checks passed? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${RED}Release aborted — P0 checks not confirmed${NC}"
        exit 1
    fi
fi

# Step 2: Git tag
echo ""
echo "--- [2/4] Tagging Git $VERSION ---"
git tag -a "$VERSION" -m "Flanker Alpine Base $ALPINE_VER $VERSION"
git push origin "$VERSION"
echo -e "${GREEN}Git tag $VERSION pushed${NC}"

# Step 3: Incus stable alias
echo ""
echo "--- [3/4] Updating Incus stable alias ---"
if command -v incus >/dev/null 2>&1; then
    # Get fingerprint from test alias or use provided
    if [ -z "$FP_OR_TAG" ]; then
        FP=$(incus image info "$INCUS_TEST_ALIAS" 2>/dev/null | grep 'Fingerprint:' | awk '{print $2}')
    else
        FP="$FP_OR_TAG"
    fi

    if [ -n "$FP" ]; then
        # Remove old stable alias if exists
        incus image alias delete "$INCUS_ALIAS" 2>/dev/null || true
        # Create new stable alias
        incus image alias create "$INCUS_ALIAS" "$FP"
        echo -e "${GREEN}Incus stable alias -> $FP${NC}"
    else
        echo -e "${RED}Could not determine fingerprint for $INCUS_TEST_ALIAS${NC}"
        echo "Pass fingerprint as second argument: $0 $VERSION <fingerprint>"
        exit 1
    fi
else
    echo "incus not found — skipping Incus alias"
fi

# Step 4: Podman stable tag
echo ""
echo "--- [4/4] Tagging Podman stable ---"
if command -v podman >/dev/null 2>&1; then
    # Tag local stable
    podman tag "$PODMAN_TEST" "$PODMAN_STABLE" 2>/dev/null || true
    echo -e "${GREEN}Podman local stable: $PODMAN_STABLE${NC}"

    # Tag GHCR immutable + stable
    echo "To push to GHCR:"
    echo "  podman tag $PODMAN_TEST $GHCR_IMMUTABLE"
    echo "  podman push $GHCR_IMMUTABLE"
    echo "  podman tag $PODMAN_TEST $GHCR_STABLE"
    echo "  podman push $GHCR_STABLE"
else
    echo "podman not found — skipping Podman tag"
fi

echo ""
echo -e "${GREEN}##############################################${NC}"
echo -e "${GREEN}  Release $VERSION complete!                  ${NC}"
echo -e "${GREEN}##############################################${NC}"
