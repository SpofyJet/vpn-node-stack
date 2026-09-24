#!/bin/bash
# node — тест: shellcheck уровня error по всем .sh проекта (без shellcheck — SKIP).
# 2026-09-23 (v1.1.5): висячая директива `# shellcheck source=...` в конце
# lib/common.sh давала SC1072 (parse error) — shellcheck не анализировал файл вовсе.
set -euo pipefail
command -v shellcheck >/dev/null 2>&1 || { echo "SKIP: нет shellcheck (apt install shellcheck)"; exit 77; }
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
t "lib/common.sh: парсится (нет SC1072)" "shellcheck -S error '$NODE_DIR/lib/common.sh'"
# по одному файлу и без -x: с -x shellcheck на main.sh/status.sh и тестах с
# множеством source — >500 МБ RSS (OOM на 2 ГБ VPS); parse-ошибки -x не нужен
t "все .sh проекта: 0 диагностик уровня error" "cd '$NODE_DIR' && for f in \$(find . -name '*.sh' | sort); do shellcheck -S error \"\$f\" || exit 1; done"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: shellcheck (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
