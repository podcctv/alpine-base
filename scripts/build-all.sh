#!/bin/bash
# scripts/build-all.sh — Build both Incus and Podman images
#
# Usage: ./scripts/build-all.sh
# Builds Incus first, then Podman. Stops on first failure.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "##############################################"
echo "#  Flanker Alpine Base — Build All           #"
echo "##############################################"
echo ""

echo "--- [1/2] Building Incus image ---"
"$REPO_ROOT/scripts/build-incus.sh"

echo ""
echo "--- [2/2] Building Podman image ---"
"$REPO_ROOT/scripts/build-podman.sh"

echo ""
echo "##############################################"
echo "#  All builds complete                       #"
echo "##############################################"
echo ""
echo "Next: run ./scripts/test-ssh.sh to verify"
