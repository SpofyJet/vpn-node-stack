#!/bin/bash
# тест: цвет warn/error — только на TTY, с уважением NO_COLOR (backlog #9).
# 2026-09-24 (node v1.1.5 / shieldnode v1.1.4): C_RED/C_YEL задавались безусловно — в пайпе/журнале systemd/файле
# warn-строки приходили с ANSI-мусором (\033[1;33m...). Лог-ФАЙЛ всегда был чистым.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v script >/dev/null 2>&1 || { echo "SKIP: нет script (util-linux)"; exit 77; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
DRV="$OUT/drv.sh"
cat > "$DRV" <<EOF
set -euo pipefail
export NODE_LOG=/dev/null SHIELD_LOG=/dev/null LOG_LEVEL=info NODE_STATE_DIR="$OUT/st" SHIELD_STATE_DIR="$OUT/st"
source "$ROOT/lib/common.sh"
warn "t" "warn-line"; log error "t" "error-line"
EOF
env -u NO_COLOR bash "$DRV" > /dev/null 2> "$OUT/pipe.err" || true
t "не-TTY (stderr в файл): warn/error без ANSI" "grep -q warn-line $OUT/pipe.err && ! grep -q \$'\\033' $OUT/pipe.err"
env -u NO_COLOR script -qec "bash $DRV" /dev/null > "$OUT/tty.out" 2>&1 || true
t "TTY: warn/error в цвете (как раньше)" "grep -q warn-line $OUT/tty.out && grep -q \$'\\033\\[1;33m' $OUT/tty.out"
NO_COLOR=1 script -qec "bash $DRV" /dev/null > "$OUT/nocolor.out" 2>&1 || true
t "TTY + NO_COLOR: без ANSI" "grep -q warn-line $OUT/nocolor.out && ! grep -q \$'\\033\\[' $OUT/nocolor.out"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: log-color (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
