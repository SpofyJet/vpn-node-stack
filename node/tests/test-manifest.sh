#!/bin/bash
# node — тест: (1) манифест applied-files.txt НЕПУСТ после реального persist-пути
# apply (регрессия: lib/sysctl.sh перекрывал node_persist из apply.sh версией
# без node_manifest_record → rollback/uninstall не работали);
# (2) fallback node_persist из persist.sh (без apply.sh);
# (3) node_sysctl_write удаляет устаревшие 99-z*-node-*.conf, которых нет в плане;
# (4) rt-reapply в DRY_RUN=1 проходит (persist.sh source + conntrack_plan).
# Запуск: bash tests/test-manifest.sh (root не обязателен)
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
SBX=/tmp/node-manifest-test
export NODE_STATE_DIR="$SBX/state"
export NODE_DIAG_DIR="$SBX/diag"
export NODE_PROFILE_DIR="$SBX/profile.d"
export NODE_LOG="$SBX/node.log"
export DRY_RUN=0
LOG_LEVEL=info

rm -rf "$SBX"
mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR"
touch "$NODE_LOG"

fails=0
# eval в ТЕКУЩЕМ шелле: bash -c не видит неэкспортированные функции
t() { local name="$1"; shift
    if eval "$*" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# порядок source — как в main.sh (режим apply): persist.sh ДО apply.sh,
# sysctl.sh — ВНУТРИ node_apply (т.е. ПОСЛЕ apply.sh). Именно этот порядок
# раньше убивал манифест: sysctl.sh переопределял node_persist без делегата.
source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
node_load_config >/dev/null 2>&1 || true
source "$NODE_DIR/persist.sh"
source "$NODE_DIR/apply.sh"
source "$NODE_DIR/lib/sysctl.sh"

# делегат apply.sh выжил после source sysctl.sh (иначе манифест будет пуст)
t "node_persist — делегат в node_persist_stream (sysctl.sh не перекрыл)" \
    'declare -f node_persist | grep -q node_persist_stream'

# --- реальный persist-путь: план -> запись sysctl-файла в sandbox ---
FAKE_ETC="$SBX/etc/sysctl.d"
mkdir -p "$FAKE_ETC"
NODE_SYSCTL_BASE="$FAKE_ETC/99-z0-node-base.conf"
NODE_SYSCTL_DATAPATH="$FAKE_ETC/99-z1-node-datapath.conf"
NODE_SYSCTL_CONNTRACK="$FAKE_ETC/99-z2-node-conntrack.conf"
NODE_SYSCTL_IPV6="$FAKE_ETC/99-z3-node-ipv6.conf"
NODE_SYSCTL_MEM="$FAKE_ETC/99-z4-node-vm.conf"
NODE_SYSCTL_FILES=("$NODE_SYSCTL_BASE" "$NODE_SYSCTL_DATAPATH" "$NODE_SYSCTL_CONNTRACK" "$NODE_SYSCTL_IPV6" "$NODE_SYSCTL_MEM")

node_sysctl_plan_init
node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn 16384
node_sysctl_write

t "sysctl-файл записан" test -s "$NODE_SYSCTL_BASE"
t "КРИТ-регрессия: манифест НЕПУСТ после persist-пути" test -s "$NODE_STATE_DIR/applied-files.txt"
t "манифест содержит записанный файл" grep -qxF "$NODE_SYSCTL_BASE" "$NODE_STATE_DIR/applied-files.txt"

# --- устаревший файл (фича выключена оператором): удаляется с backup ---
echo "net.ipv6.conf.all.disable_ipv6 = 1" > "$NODE_SYSCTL_IPV6"
node_sysctl_plan_init                       # план без ipv6-ключей
node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn 16384
node_sysctl_write
t "устаревший 99-z3-node-ipv6.conf удалён (нет в плане)" "test ! -e \"$NODE_SYSCTL_IPV6\""
t "перед удалением сделан backup" "ls \"$NODE_SYSCTL_IPV6\".pre-node-* >/dev/null 2>&1"

# --- fallback node_persist в persist.sh (контекст без apply.sh) ---
t "persist.sh: fallback node_persist без apply.sh" bash -c '
    export NODE_STATE_DIR=/tmp/node-manifest-test/state2 NODE_LOG=/dev/null DRY_RUN=0
    mkdir -p "$NODE_STATE_DIR"
    source "'"$NODE_DIR"'/lib/common.sh"
    source "'"$NODE_DIR"'/config.sh"
    source "'"$NODE_DIR"'/persist.sh"
    declare -F node_persist >/dev/null &&
    echo x | node_persist /tmp/node-manifest-test/state2/probe.conf &&
    grep -qxF /tmp/node-manifest-test/state2/probe.conf "$NODE_STATE_DIR/applied-files.txt"'

# --- rt-reapply в DRY_RUN=1: раньше падал (node_persist_stream: command not found
#     + NODE_CONNTRACK_HASHSIZE unbound). Прогон через боевой диспетчер.
t "rt-reapply DRY_RUN=1: rc=0" bash -c 'DRY_RUN=1 bash "'"$NODE_DIR"'/main.sh" rt-reapply >/dev/null 2>&1'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: manifest (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
