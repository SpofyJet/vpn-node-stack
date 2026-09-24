#!/bin/bash
# node — тест: свои файлы в каталогах «читаются все файлы» (logrotate.d, apt.conf.d)
# без рядом-лежащих .pre-node-* бэкапов.
# 2026-09-24 (v1.1.5): logrotate читает ВСЕ файлы /etc/logrotate.d — бэкапы своего конфига
# давали «duplicate log entry», пропуск файлов и rc=1 (logrotate -d на живой ноде);
# apt на каждый запуск печатал «N: Ignoring file ...». Исходное состояние своих
# (created) файлов — «отсутствует» (реестр происхождения), rollback их удаляет.
# Под root: `unshare -m` + tmpfs поверх /etc/logrotate.d и /etc/apt/apt.conf.d.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: unshare -m недоступен"; exit 77; }
    TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
for d in /etc/logrotate.d /etc/apt/apt.conf.d; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export NODE_DIR="$D" SHIELD_DIR="$D" NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" SHIELD_LOG="$OUT/log" NODE_CONFIG="$OUT/c" SHIELD_CONFIG="$OUT/c" DRY_RUN=0
mkdir -p "$OUT/state"; : > "$OUT/c"
source "$D/lib/common.sh"; source "$D/config.sh"; node_load_config >/dev/null 2>&1 || true; source "$D/persist.sh"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
for f in /etc/logrotate.d/node /etc/apt/apt.conf.d/99-node-no-unattended; do
    touch "$f.pre-node-20260101-000000"            # «старый» бэкап от прежних версий
    echo v1 | node_persist_stream "$f" >/dev/null 2>&1; sleep 1
    echo v2 | node_persist_stream "$f" >/dev/null 2>&1
    t "$f: свой файл перезаписан без .pre-node-* рядом (и старые убраны)" "[ \"\$(cat $f)\" = v2 ] && ! ls $f.pre-node-* >/dev/null 2>&1"
done
echo foreign > /etc/logrotate.d/zz-foreign
echo mine | node_persist_stream /etc/logrotate.d/zz-foreign >/dev/null 2>&1
t "чужой (существовавший до нас) файл: бэкап перед перезаписью по-прежнему делается" "ls /etc/logrotate.d/zz-foreign.pre-node-* >/dev/null 2>&1"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: own-backups (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
