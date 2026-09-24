#!/bin/bash
# node — тест: rollback.sh восстанавливает файлы из backup-set и удаляет свои без backup.
# Запуск: bash tests/test-rollback.sh  (root не обязателен: используются только tmp-пути)
set -euo pipefail

# 2026-09-24 (v1.1.5): node_rollback безусловно делает `systemctl disable --now
# node-rt-tweaks.service`, `rm -f /usr/local/sbin/node-rt-tweaks.sh
# /etc/udev/rules.d/99-node-rt-hotplug.rules` и daemon-reload — под root тест
# сносил их на живой ноде. Изоляция: свой mount ns, tmpfs поверх этих путей и /run
# (без /run systemctl/udevadm не достучатся до PID1/udevd — безвредный отказ).
if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
if [ "${NODE_TEST_IN_NS:-0}" = "1" ]; then
    for d in /usr/local/sbin /etc/udev/rules.d /etc/systemd/system /run; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
fi
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
touch "$NODE_LOG"   # log() пишет в файл только если он уже writable

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/persist.sh"
source "$NODE_DIR/rollback.sh"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

TS=20240101-000000

# --- сценарий 1: файл с backup → восстановление содержимого ---
F1=/tmp/node-test-rollback/fake-etc/99-z0-node-base.conf
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
F3=/tmp/node-test-rollback/fake-etc/99-z1-node-datapath.conf
echo "X" > "$F3"
echo "$F3" > "$NODE_STATE_DIR/applied-files.txt"
node_rollback ""
t "без ts: свой файл удалён" bash -c "! test -e '$F3'"

# --- сценарий 3a: откат без ts, но бэкап есть -> ВОССТАНОВЛЕНИЕ, не rm ---
# (регрессия: раньше rm -f стирал чужие pre-existing файлы, напр. /etc/fstab)
F4=/tmp/node-test-rollback/fake-etc/fstab
echo "PREEXISTING" > "$F4.pre-node-$TS"   # бэкап от apply: файл был до node
echo "NODE-VERSION" > "$F4"
echo "$F4" > "$NODE_STATE_DIR/applied-files.txt"
node_rollback ""
t "без ts + бэкап: файл ВОССТАНОВЛЕН (не удалён)" bash -c "grep -qx PREEXISTING '$F4'"

# --- сценарий 3b: ts задан, точного бэкапа набора нет -> fallback newest + warn ---
F5=/tmp/node-test-rollback/fake-etc/99-z4-node-vm.conf
echo "NEWER" > "$F5.pre-node-20240202-000000"   # бэкап из ДРУГОГО набора
echo "MODIFIED" > "$F5"
echo "$F5" > "$NODE_STATE_DIR/applied-files.txt"
node_rollback "$TS"   # набора $TS для F5 не существует
t "ts без точного бэкапа: restore из newest" bash -c "grep -qx NEWER '$F5'"
t "ts fallback залогирован как warn" bash -c "grep -q 'нет бэкапа набора' '$NODE_LOG'"

# --- сценарий 3c: свой drop-in файл (limits) удаляется вместе с каталогом ---
DOWND=/tmp/node-test-rollback/fake-etc   # sandbox: проверяем только свои каталоги
F6="$DOWND/xray.service.d/10-node-limits.conf"
mkdir -p "$DOWND/xray.service.d"
echo "[Service]" > "$F6"
echo "$F6" > "$NODE_STATE_DIR/applied-files.txt"
node_rollback ""
t "свой drop-in файл удалён" bash -c "! test -e '$F6'"

# --- сценарий 4: re-apply — исходное значение в реестре не перезаписывается ---
export NODE_RT_TWEAKS="$NODE_STATE_DIR/runtime-tweaks.tsv"
: > "$NODE_RT_TWEAKS"
node_rt_record "eth0" offload "gro" "on"     # первый apply: исходное on
node_rt_record "eth0" offload "gro" "off"    # re-apply: уже подкручено — должно проигнорироваться
t "re-apply: исходное значение сохранено (on, а не off)" bash -c "grep -q 'eth0	offload	gro	on' '$NODE_RT_TWEAKS' && test \$(wc -l < '$NODE_RT_TWEAKS') = 1"
node_rt_record "eth0" rps "rx-0" "0"         # другой параметр — записывается
t "re-apply: другой параметр записывается" bash -c "test \$(wc -l < '$NODE_RT_TWEAKS') = 2"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rollback (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
