#!/bin/bash
# node — тест: apply.sh вызывает только те node_* функции, что определены
# в подключённых им (напрямую или через main.sh) файлах. Статическая проверка:
# отлавливает «command not found» в apply-пути без root (баг 2026-09-22:
# node_nic_diag/node_irq_*/node_cpu_check не были засурсены — apply падал
# на боевой ноде после sysctl/services).
# Запуск: bash tests/test-apply-deps.sh
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$NODE_DIR"

fails=0

# --- набор файлов, доступных apply-пути: apply.sh + то, что main.sh
#     всегда подключаает (common/config/persist) + то, что apply.sh
#     засурсивает сам (source "$NODE_DIR/..." внутри apply.sh) ---
dep_files=(apply.sh main.sh lib/common.sh config.sh persist.sh)
while IFS= read -r f; do
    dep_files+=("$f")
done < <(grep -oE 'source "\$NODE_DIR/[^"]+"' apply.sh | sed -E 's/source "\$NODE_DIR\/(.*)"/\1/' | sort -u)

# уникальность
mapfile -t dep_files < <(printf '%s\n' "${dep_files[@]}" | sort -u)

is_defined() { # $1=fn — определена ли в доступных файлах
    local fn="$1" f
    for f in "${dep_files[@]}"; do
        [ -f "$f" ] || continue
        # определение может быть с отступом (fn, объявленная внутри другой fn,
        # напр. node_run_step внутри node_apply)
        grep -qE "^[[:space:]]*${fn}\(\)|^[[:space:]]*function ${fn}\b" "$f" && return 0
    done
    return 1
}

# все node_* вызовы в apply.sh (командная позиция: начало строк после пробелов)
checks=0
for fn in $(grep -oE '(^|[[:space:]]+)node_[a-z0-9_]+' apply.sh | grep -oE 'node_[a-z0-9_]+' | grep -vE '_$' | sort -u); do
    # определение самой функции в apply.sh — это не вызов; но мы матчим
    # и заголовки «name() {» — фильтруем: вызовы = token Н в строке-определении
    if grep -qE "^[[:space:]]*${fn}\(\)" apply.sh; then
        continue   # это определение, не вызов
    fi
    checks=$((checks + 1))
    if is_defined "$fn"; then
        echo "ok   - $fn определена в доступных apply-файлах"
    else
        echo "FAIL - $fn НЕ определена ни в одном доступном apply-файле"
        fails=$((fails + 1))
    fi
done

echo "проверено вызовов: $checks"
if [ "$fails" -eq 0 ]; then
    echo "PASS: apply-deps (all checks)"
else
    echo "FAILED: $fails проверок"
    exit 1
fi
