#!/bin/bash
# node — install.sh: entrypoint (wrapper over main.sh).
# Usage: bash install.sh [--dry-run] [apply|status|rollback|detect]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/main.sh" "$@"
