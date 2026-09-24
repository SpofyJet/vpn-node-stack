#!/bin/bash
# node — тест: datapath-pack 2 (lib/datapath.sh) без root.
# Запуск: bash tests/test-datapath.sh
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-dp-test/state
export NODE_DIAG_DIR=/tmp/node-dp-test/diag
export NODE_PROFILE_DIR=/tmp/node-dp-test/profile.d
export NODE_LOG=/tmp/node-dp-test/node.log
export DRY_RUN=1
LOG_LEVEL=info

rm -rf /tmp/node-dp-test
mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR"
# 2026-09-25 (v1.1.8): netdev_budget_usecs зависит от HZ ядра — фиксируем (1000, как Ubuntu generic)
printf 'CONFIG_HZ=1000\n' > /tmp/node-dp-test/kconfig; export NODE_KERNEL_CONFIG=/tmp/node-dp-test/kconfig

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/lib/sysctl.sh"
source "$NODE_DIR/lib/datapath.sh"

# минимальный CONFIG_CACHE из defaults (как в test-services.sh)
CONFIG_CACHE="$(mktemp)"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf" > "$CONFIG_CACHE"
export CONFIG_CACHE

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

replan() { node_sysctl_plan_init; node_datapath_plan; PLAN="$NODE_PLAN_FILE"; }
replan

# ожидаемые значения из реального /proc/meminfo
kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
pages=$(( kb / 4 )); memp=$(( pages * 25 / 100 ))
exp_tcp_mem="$((memp*3/4)) $((memp*7/8)) $memp"
tier_mb=$(( kb / 1024 ))
if [ "$tier_mb" -le 2048 ]; then exp_rd=262144
elif [ "$tier_mb" -le 4096 ]; then exp_rd=2097152
else exp_rd=8388608; fi

t "plan: netdev_budget=600" bash -c "grep -q 'net.core.netdev_budget	600' '$PLAN'"
t "plan (HZ=1000): netdev_budget_usecs=4000 (4 jiffy, пропорционально budget 600)" bash -c "grep -q 'net.core.netdev_budget_usecs	4000' '$PLAN'"
# HZ=250 (XanMod): 4000 = 1 jiffy < минимума ядра 8000 (EINVAL на 6.18) -> ключ не пишем, дефолт ядра
printf 'CONFIG_HZ=250\n' > "$NODE_KERNEL_CONFIG"; replan
t "plan (HZ=250): netdev_budget_usecs НЕ пишется (дефолт ядра = минимум 8000 = 2 jiffy)" bash -c "! grep -q 'net.core.netdev_budget_usecs' '$PLAN' && grep -q 'net.core.netdev_budget	600' '$PLAN'"
printf 'CONFIG_HZ=100\n' > "$NODE_KERNEL_CONFIG"; replan
t "plan (HZ=100): не пишется (минимум 20000)" bash -c "! grep -q 'net.core.netdev_budget_usecs' '$PLAN'"
: > "$NODE_KERNEL_CONFIG"; replan
t "plan (HZ неизвестен): не пишется" bash -c "! grep -q 'net.core.netdev_budget_usecs' '$PLAN'"
# живое ядро: план с НАСТОЯЩИМ /boot/config — значение должно приниматься ядром (4000 на 6.18/HZ=250
# давал EINVAL и ронял apply). Ключ глобальный (не netns) — пишем на миг и сразу возвращаем исходное.
if [ "$(id -u)" -eq 0 ] && [ -w /proc/sys/net/core/netdev_budget_usecs ]; then
    ( unset NODE_KERNEL_CONFIG; replan; cp "$PLAN" /tmp/node-dp-test/plan.live )
    live_v="$(awk -F'\t' '$1 == "net.core.netdev_budget_usecs" {print $2}' /tmp/node-dp-test/plan.live)"
    if [ -n "$live_v" ]; then
        orig_v="$(sysctl -n net.core.netdev_budget_usecs)"
        if sysctl -qw "net.core.netdev_budget_usecs=$live_v" 2>/dev/null; then acc=1; else acc=0; fi
        sysctl -qw "net.core.netdev_budget_usecs=$orig_v" 2>/dev/null || true
        t "живое ядро $(uname -r): план netdev_budget_usecs=$live_v принимается" test "$acc" = 1
    else
        t "живое ядро $(uname -r): netdev_budget_usecs не пишется (дефолт ядра)" true
    fi
fi
printf 'CONFIG_HZ=1000\n' > "$NODE_KERNEL_CONFIG"; replan
t "plan: tcp_max_tw_buckets=524288" bash -c "grep -q 'net.ipv4.tcp_max_tw_buckets	524288' '$PLAN'"
t "plan: tcp_mem по формуле 25% RAM" bash -c "grep -q \"net.ipv4.tcp_mem	$exp_tcp_mem\" '$PLAN'"
# 2026-09-24 (v1.1.7): ревизия тюнинга — rmem/wmem_default по умолчанию НЕ пишутся (дефолт ядра)
t "plan: rmem_default/wmem_default по умолчанию не трогаются" bash -c "! grep -qE 'net.core.[rw]mem_default' '$PLAN'"
t "plan: dirty_background_bytes=64MB" bash -c "grep -q 'vm.dirty_background_bytes	67108864' '$PLAN'"
t "plan: dirty_bytes=256MB" bash -c "grep -q 'vm.dirty_bytes	268435456' '$PLAN'"
t "plan: dirty_ratio ОТСУТСТВУЮТ (bytes перекрывают ratio)" bash -c "! grep -qE 'vm.dirty_background_ratio|vm.dirty_ratio	' '$PLAN'"
t "plan: dirty_bytes идут в MEM-файл (84)" bash -c "grep -q \"vm.dirty_bytes	268435456	$NODE_SYSCTL_MEM\" '$PLAN'"
# 2026-09-24 (v1.1.7): ревизия тюнинга — tcp_plb_enabled (нужен PLB-capable CC, IPv4 no-op) и overcommit_memory убраны
t "plan: tcp_plb_enabled отсутствует" bash -c "! grep -q 'tcp_plb_enabled' '$PLAN'"
t "plan: overcommit_memory не ставится (любой tier)" bash -c "! grep -q 'vm.overcommit_memory' '$PLAN'"
t "plan: busy_poll НЕТ по умолчанию" bash -c "! grep -q 'busy_poll' '$PLAN'"

# --- ENABLE_DATAPATH=0 гасит всё ---
sed -i 's/^ENABLE_DATAPATH=1$/ENABLE_DATAPATH=0/' "$CONFIG_CACHE"
replan
t "мастер-выключатель: план пуст" bash -c "test ! -s '$PLAN' || ! grep -qE 'netdev_budget|tcp_max_tw|dirty_bytes|rmem_default' '$PLAN'"
sed -i 's/^ENABLE_DATAPATH=0$/ENABLE_DATAPATH=1/' "$CONFIG_CACHE"

# --- busy_poll opt-in ---
sed -i 's/^ENABLE_BUSY_POLL=.*/ENABLE_BUSY_POLL=1/' "$CONFIG_CACHE"
replan
t "busy_poll opt-in: poll/read=50" bash -c "grep -q 'net.core.busy_poll	50' '$PLAN' && grep -q 'net.core.busy_read	50' '$PLAN'"
sed -i 's/^ENABLE_BUSY_POLL=.*/ENABLE_BUSY_POLL=0/' "$CONFIG_CACHE"

# --- оверрайды (sed in-place: первое совпадение в cache выигрывает) ---
sed -i -e 's/^NETDEV_BUDGET=.*/NETDEV_BUDGET=900/'        -e 's/^TCP_MAX_TW_BUCKETS=.*/TCP_MAX_TW_BUCKETS=1048576/'        -e 's/^TCP_MEM_PCT=.*/TCP_MEM_PCT=30/' "$CONFIG_CACHE"
replan
t "оверрайд: NETDEV_BUDGET=900" bash -c "grep -q 'net.core.netdev_budget	900' '$PLAN'"
t "оверрайд: usecs следует за budget 900 -> 6000" bash -c "grep -q 'net.core.netdev_budget_usecs	6000' '$PLAN'"
t "оверрайд: TW_BUCKETS=1048576" bash -c "grep -q 'net.ipv4.tcp_max_tw_buckets	1048576' '$PLAN'"
m30=$(( pages * 30 / 100 ))
exp30="$((m30*3/4)) $((m30*7/8)) $m30"
t "оверрайд: TCP_MEM_PCT=30 пересчитан" bash -c "grep -q \"net.ipv4.tcp_mem	$exp30\" '$PLAN'"

# --- fq tune: эмиссия юнита (DRY_RUN) ---
OUT=/tmp/node-dp-test/persist
BIN=/tmp/node-dp-test/bin; mkdir -p "$BIN"
cat > "$BIN/tc" <<'EOF'
#!/bin/bash
# fake tc: show — два fq-инстанса (root + mq-child); change — логирует
if [ "$1" = "qdisc" ] && [ "$2" = "show" ]; then
    echo 'qdisc fq 0: dev eth0 root refcnt 2 limit 10000p flow_limit 100p buckets 1024'
    echo 'qdisc fq 10: dev eth0 parent 1:1 limit 10000p flow_limit 100p buckets 1024'
    exit 0
fi
if [ "$1" = "qdisc" ] && [ "$2" = "change" ]; then
    echo "$*" >> "$FAKE_TC_LOG"
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/tc"
PATH="$BIN:$PATH"
node_persist() { local dst="$1"   # persist sysctl.sh DRY_RUN-aware — подменяем
    mkdir -p "$OUT$(dirname "$dst")"; cat > "$OUT$dst"; }
node_fq_tune_apply
t "fq: юнит эмитирован" test -f "$OUT/etc/systemd/system/node-fq-tune.service"
t "fq: скрипт эмитирован и валиден" bash -n "$OUT/usr/local/sbin/node-fq-tune.sh"
t "fq: значения по умолчанию в скрипте" bash -c "grep -q '^LIM=100000' '$OUT/usr/local/sbin/node-fq-tune.sh' && grep -qx 'FL=100' '$OUT/usr/local/sbin/node-fq-tune.sh' && grep -q '^BKT=32768' '$OUT/usr/local/sbin/node-fq-tune.sh'"
t "fq: парсер root и child fq-инстансов" bash -c "grep -q 'parent' '$OUT/usr/local/sbin/node-fq-tune.sh' && grep -q 'root' '$OUT/usr/local/sbin/node-fq-tune.sh'"
t "fq: юнит ссылается на production-путь скрипта" grep -q "ExecStart=/usr/local/sbin/node-fq-tune.sh" "$OUT/etc/systemd/system/node-fq-tune.service"

# --- fq tune против фейкового tc (live-путь логики скрипта) ---
: > /tmp/node-dp-test/tc.log
FAKE_TC_LOG=/tmp/node-dp-test/tc.log PATH="$BIN:$PATH" bash "$OUT/usr/local/sbin/node-fq-tune.sh"
t "fq: root-инстанс изменён (limit/buckets)" bash -c "grep -q 'dev eth0 root fq limit 100000 flow_limit 100 buckets 32768' /tmp/node-dp-test/tc.log"
t "fq: mq-child изменён через parent/handle" bash -c "grep -q 'dev eth0 parent 1:1 handle 10: fq limit 100000 flow_limit 100 buckets 32768' /tmp/node-dp-test/tc.log"

# --- fq tune: ENABLE_FQ_TUNE=0 гасит эмиссию ---
sed -i 's/^ENABLE_FQ_TUNE=.*/ENABLE_FQ_TUNE=0/' "$CONFIG_CACHE"
rm -rf "$OUT"
node_fq_tune_apply
t "fq: выключатель = файлы не эмитятся" bash -c "test ! -e '$OUT/etc/systemd/system/node-fq-tune.service'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: datapath (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
