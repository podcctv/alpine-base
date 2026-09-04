#!/bin/bash
# scripts/build-all.sh — Build both Incus and Podman images
#
# Usage: ./scripts/build-all.sh
# Builds Incus first, then Podman. Stops on first failure.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "##############################################"
echo "#  Custom Base — Build Alpine + Debian          #"
echo "##############################################"
echo ""

echo "--- [1/4] Building Alpine Incus image ---"
"$REPO_ROOT/scripts/build-incus.sh" alpine

echo ""
echo "--- [2/4] Building Alpine Podman image ---"
"$REPO_ROOT/scripts/build-podman.sh" alpine

echo "--- [3/4] Building Debian Incus image ---"
"$REPO_ROOT/scripts/build-incus.sh" debian

echo "--- [4/4] Building Debian Podman image ---"
"$REPO_ROOT/scripts/build-podman.sh" debian

echo ""
echo "##############################################"
echo "#  All builds complete                       #"
echo "##############################################"
echo ""
echo "Next: run ./scripts/test-ssh.sh to verify"
