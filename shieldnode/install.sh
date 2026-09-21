#!/bin/bash
# shieldnode — install.sh: тонкий вход (TZ §4). Вся логика в main.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/main.sh" "$@"
