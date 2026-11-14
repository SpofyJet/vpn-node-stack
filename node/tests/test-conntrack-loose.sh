#!/bin/bash
# node — тест: nf_conntrack_tcp_loose и ранний фильтр (v1.2.12).
# Ранний фильтр (shieldnode: spofy-guard) в отбросе держит loose=0. Если CONNTRACK_TCP_LOOSE не задан, а отметка
# фильтра «настройки ядра включены» есть, node планирует 0, а не свой обычный 1: иначе на сервере без
# /etc/node/node.conf каждый apply возвращал бы 1 до ближайшего тика фильтра. Заданное значение — главнее.
# sysctl — заглушка по файлу: настоящие ключи сервера тест не читает и не пишет.
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/sysctl.d" "$OUT/guard"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
: > "$NODE_CONFIG"

# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_sysctl_install "$OUT/bin" "$OUT/mock"   # SYSDB, SYSCALLS
export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
CONFIG_CACHE="$OUT/config.cache"; export CONFIG_CACHE
cfg() { { printf '%s\n' "$@"; grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"; }
cfg
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/sysctl.sh"; source "$NODE_DIR/lib/conntrack.sh"
NODE_SYSCTL_CONNTRACK="$OUT/sysctl.d/99-z2-node-conntrack.conf"
NODE_SYSCTL_FILES=("$NODE_SYSCTL_CONNTRACK")
export _NODE_MEMTOTAL_MB=2000
MARK="$OUT/guard/sysctl.on"; export NODE_EARLYFILTER_SYSCTL_MARK="$MARK"

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
db() {
    printf '%s\n' net.netfilter.nf_conntrack_max=262144 net.netfilter.nf_conntrack_tcp_timeout_established=432000 \
        net.netfilter.nf_conntrack_tcp_timeout_time_wait=120 net.netfilter.nf_conntrack_tcp_timeout_close_wait=60 \
        net.netfilter.nf_conntrack_tcp_timeout_fin_wait=120 net.netfilter.nf_conntrack_tcp_timeout_last_ack=30 \
        net.netfilter.nf_conntrack_generic_timeout=600 net.netfilter.nf_conntrack_tcp_loose=0 \
        net.netfilter.nf_conntrack_tcp_be_liberal=0 > "$SYSDB"; : > "$SYSCALLS"
}
loose() { awk -F'\t' '$1 == "net.netfilter.nf_conntrack_tcp_loose" { print $2 }' "$NODE_PLAN_FILE"; }
plan() { db; node_sysctl_plan_init; node_conntrack_plan >/dev/null 2>&1; }

rm -f "$MARK"; cfg; plan
t "фильтра нет, значение не задано: loose=1 (как раньше)" '[ "$(loose)" = 1 ]'
: > "$MARK"; cfg; plan
t "отметка раннего фильтра есть, значение не задано: loose=0" '[ "$(loose)" = 0 ]'
t "…ровно одна строка в плане" '[ "$(loose | wc -l)" = 1 ]'
cfg CONNTRACK_TCP_LOOSE=1; plan
t "отметка есть, но задано CONNTRACK_TCP_LOOSE=1: заданное главнее" '[ "$(loose)" = 1 ]'
rm -f "$MARK"; cfg CONNTRACK_TCP_LOOSE=0; plan
t "фильтра нет, задано CONNTRACK_TCP_LOOSE=0: 0" '[ "$(loose)" = 0 ]'
: > "$MARK"; cfg CONNTRACK_TCP_LOOSE=0; plan
t "отметка есть и задано 0: 0" '[ "$(loose)" = 0 ]'
# проверка записываемости ключа не меняет значение ядра (пишет текущее)
: > "$MARK"; cfg; plan
t "план не меняет значение в ядре" '[ "$(awk -F= "\$1 == \"net.netfilter.nf_conntrack_tcp_loose\" { print \$2 }" "$SYSDB")" = 0 ]'
# путь отметки по умолчанию — тот, что пишет сам фильтр
t "путь отметки по умолчанию — /var/lib/spofy-guard/sysctl.on" 'grep -q "NODE_EARLYFILTER_SYSCTL_MARK:-/var/lib/spofy-guard/sysctl.on" "$NODE_DIR/lib/conntrack.sh"'
G="$NODE_DIR/../shieldnode/spofy-guard"
if [ -f "$G" ]; then
    t "фильтр пишет отметку именно туда (каталог состояния и имя файла)" 'grep -q "GUARD_STATE:-/var/lib/spofy-guard" "$G" && grep -q "touch \"\$STATE/sysctl.on\"" "$G"'
else
    echo "skip - shieldnode/spofy-guard нет в этом дереве"
fi

echo
if [ "$fails" = 0 ]; then echo "PASS: test-conntrack-loose"; else echo "FAIL: test-conntrack-loose ($fails)"; exit 1; fi
