#!/usr/bin/env bash
# Compatibility entry point for scripts and installations using the former path.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/omarchy-backup" "$@"
