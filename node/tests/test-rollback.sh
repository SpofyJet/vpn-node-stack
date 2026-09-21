#!/bin/bash
# node — тест: rollback.sh восстанавливает файлы из backup-set и удаляет свои без backup.
# Запуск: bash tests/test-rollback.sh  (root не обязателен: используются только tmp-пути)
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-test-rollback/state
export NODE_DIAG_DIR=/tmp/node-test-rollback/diag
export NODE_PROFILE_DIR=/tmp/node-test-rollback/profile.d
export NODE_LOG=/tmp/node-test-rollback/node.log
export DRY_RUN=0
LOG_LEVEL=info

rm -rf /tmp/node-test-rollback
mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR" /tmp/node-test-rollback/fake-etc

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/persist.sh"
source "$NODE_DIR/rollback.sh"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

TS=20240101-000000

# --- сценарий 1: файл с backup → восстановление содержимого ---
F1=/tmp/node-test-rollback/fake-etc/80-node-base.conf
echo "ORIGINAL" > "$F1"
cp -a "$F1" "$F1.pre-node-$TS"          # имитация backup() от предыдущего прогона
echo "MODIFIED" > "$F1"                 # «применённое» состояние
echo "$F1" >> "$NODE_STATE_DIR/applied-files.txt"

# --- сценарий 2: свой файл без backup → удаление ---
F2=/tmp/node-test-rollback/fake-etc/90-orphan.conf
echo "ORPHAN" > "$F2"
echo "$F2" >> "$NODE_STATE_DIR/applied-files.txt"

node_rollback "$TS"

t "файл с backup восстановлен (содержимое ORIGINAL)" bash -c "grep -qx ORIGINAL '$F1'"
t "backup-файл сохранился" test -f "$F1.pre-node-$TS"
t "orphan-файл удалён" bash -c "! test -e '$F2'"
t "манифест очищен" bash -c "! test -s '$NODE_STATE_DIR/applied-files.txt'"

# --- сценарий 3: откат без ts (удаление всех своих файлов) ---
F3=/tmp/node-test-rollback/fake-etc/81-node-datapath.conf
echo "X" > "$F3"
echo "$F3" > "$NODE_STATE_DIR/applied-files.txt"
node_rollback ""
t "без ts: свой файл удалён" bash -c "! test -e '$F3'"

# --- сценарий 4: re-apply — исходное значение в реестре не перезаписывается ---
export NODE_RT_TWEAKS="$NODE_STATE_DIR/runtime-tweaks.tsv"
: > "$NODE_RT_TWEAKS"
node_rt_record "eth0" offload "gro" "on"     # первый apply: исходное on
node_rt_record "eth0" offload "gro" "off"    # re-apply: уже подкручено — должно проигнорироваться
t "re-apply: исходное значение сохранено (on, а не off)" bash -c "grep -q 'eth0	offload	gro	on' '$NODE_RT_TWEAKS' && test \$(wc -l < '$NODE_RT_TWEAKS') = 1"
node_rt_record "eth0" rps "rx-0" "0"         # другой параметр — записывается
t "re-apply: другой параметр записывается" bash -c "test \$(wc -l < '$NODE_RT_TWEAKS') = 2"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rollback (7/7)"; else echo "FAILED: $fails проверок"; exit 1; fi
