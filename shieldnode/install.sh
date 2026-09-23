#!/bin/bash
# shieldnode — install.sh: тонкий вход (TZ §4). Вся логика в main.sh.
set -euo pipefail
# readlink -f: install.sh может быть вызван через symlink (в т.ч. исторический
# /usr/local/sbin/guard на старых установках) — без резолва SCRIPT_DIR указывал
# бы на каталог symlink'а и main.sh не находился
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec bash "$SCRIPT_DIR/main.sh" "$@"
