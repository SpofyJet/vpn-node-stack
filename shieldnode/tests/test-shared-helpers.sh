#!/bin/bash
# Тест дрейфа общих хелперов node <-> shieldnode (v1.1.2, 2026-09-23).
# Копии backup/scrub/log/... уже расходились (4-символьный префикс в scrub,
# валидация BACKUP_KEEP). Архивы ставятся независимо, поэтому общий файл-сниппет
# не вводим; вместо этого — детектор дрейфа, ФАЙЛ ИДЕНТИЧЕН в обоих проектах:
#  1) pin: sha256 нормализованных тел общих функций ЭТОГО проекта = PIN
#     (работает и в одиночном архиве; PIN одинаков в обеих копиях теста);
#  2) если рядом лежит второй проект (раскладка репозитория) — тела сравниваются
#     напрямую; atomic_write — единственное известное расхождение (параметр mode).
# Нормализация: префиксы проекта (NODE_/SHIELD_, node_/shield_conf_get,
# pre-node/pre-shieldnode, .node-write/.shieldnode-write), строки-комментарии.
set -euo pipefail
PIN="9d42e692caf9dae0"
SHARED="scrub log die warn ok require_root acquire_lock backup _route_kw _ss_local_ports"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(basename "$ROOT")" in node) OTHER=shieldnode ;; shieldnode) OTHER=node ;; *) echo "SKIP: неизвестный проект"; exit 77 ;; esac
body() { awk -v f="$2" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p{print} p && /^}/{exit}' "$1" | { grep -vE '^[[:space:]]*#' || true; } \
    | sed -E 's/(NODE|SHIELD)_(LOG|LOCK)/X_\2/g; s/(node|shield)_conf_get/x_conf_get/g; s/pre-(node|shieldnode)/pre-X/g; s/\.(node|shieldnode)-write/.X-write/g; s/(node|shieldnode) instance/X instance/g'; }
# atomic_write без параметра mode (единственное известное расхождение)
aw() { body "$1" atomic_write | sed -e 's/ mode="${2:-0644}"//' -e 's/chmod "$mode"/chmod 0644/' -e 's/ (mode $mode)//'; }
all() { local fn; for fn in $SHARED; do echo "== $fn"; body "$1" "$fn"; done; }
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
got="$(all "$ROOT/lib/common.sh" | sha256sum | cut -c1-16)"
t "pin: общие хелперы $(basename "$ROOT") совпадают с эталоном ($got)" '[ "$got" = "$PIN" ]'
for fn in $SHARED; do t "$fn: определён" '[ -n "$(body "$ROOT/lib/common.sh" "$fn")" ]'; done
O="$(dirname "$ROOT")/$OTHER/lib/common.sh"
if [ -f "$O" ]; then
    for fn in $SHARED; do t "$fn: идентичен в $OTHER" '[ "$(body "$ROOT/lib/common.sh" "$fn")" = "$(body "$O" "$fn")" ]'; done
    t "atomic_write: расходится ТОЛЬКО параметром mode" '[ "$(aw "$ROOT/lib/common.sh")" = "$(aw "$O")" ]'
else
    echo "skip - сравнение с $OTHER (архив распакован отдельно; pin выше всё равно проверен)"
fi
echo
if [ "$fails" -eq 0 ]; then echo "PASS: shared-helpers (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
