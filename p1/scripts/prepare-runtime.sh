#!/usr/bin/env bash
#
# Generate the join secret on the L1 host before Vagrant copies the project
# into the L2 guests. The file is gitignored and intentionally never printed,
# written back from a guest, or included in evidence.

set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../.runtime"
TOKEN_FILE="$RUNTIME_DIR/k3s-token"

mkdir -p "$RUNTIME_DIR"

if [ ! -s "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
fi

chmod 600 "$TOKEN_FILE"
echo "Prepared runtime-only P1 token file: $TOKEN_FILE"
