#!/bin/bash
# node — тест: status сравнивает многозначные sysctl без ложного ✗.
# 2026-09-24 (v1.1.5): `sysctl -n` печатает многозначные ключи (ip_local_port_range,
# tcp_mem, udp_mem) через TAB, план хранит через пробел — на живой ноде status
# показывал ✗ для совпадающих значений. Мок sysctl через PATH; status read-only.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-status-mv
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
REAL_SYSCTL="$(command -v sysctl || true)"
[ -n "$REAL_SYSCTL" ] || { echo "SKIP: нет sysctl"; exit 77; }
# ip_local_port_range — ровно плановое значение (дефолт "10240 65535"), но через TAB,
# как печатает ядро; прочие ключи — настоящий sysctl
cat > "$OUT/bin/sysctl" <<EOF
#!/bin/bash
if [ "\$1" = -n ] && [ "\$2" = net.ipv4.ip_local_port_range ]; then printf '10240\t65535\n'; exit 0; fi
exec "$REAL_SYSCTL" "\$@"
EOF
chmod +x "$OUT/bin/sysctl"
: > "$OUT/node.conf"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
PATH="$OUT/bin:$PATH" NODE_CONFIG="$OUT/node.conf" NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diag" \
  NODE_LOG="$OUT/node.log" NODE_PROFILE_DIR="$OUT/profile.d" NO_COLOR=1 \
  bash "$NODE_DIR/main.sh" status > "$OUT/status.out" 2>&1 || true
t "status: строка ip_local_port_range выведена" "grep -q '^net.ipv4.ip_local_port_range ' $OUT/status.out"
t "status: TAB vs пробел — совпадение даёт ✓, не ✗" "grep '^net.ipv4.ip_local_port_range ' $OUT/status.out | grep -q '✓\$'"
# 2026-09-24 (v1.1.6): status «без root» — perf-baseline.txt (0600 root) нечитаем: awk fatal
# ронял status (rc 2) и оставлял mktemp-файл в /tmp (найдено: vpn-node-setup status от nobody)
if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
    PB="$(mktemp -d)"; chmod 0755 "$PB"; echo "ts=1" > "$PB/perf-baseline.txt"; chmod 0600 "$PB/perf-baseline.txt"
    mkdir -p "$OUT/nb-tmp"; chmod 0777 "$OUT/nb-tmp"; chmod 0755 "$OUT"
    # код — в читаемую nobody копию (дерево теста может лежать в 0700-каталоге)
    cp -r "$NODE_DIR" "$PB/node"; chmod -R a+rX "$PB/node"
    rc=0; runuser -u nobody -- env TMPDIR="$OUT/nb-tmp" NODE_DIR="$PB/node" NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null bash -c \
        'set -euo pipefail; source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; source "$NODE_DIR/lib/datapath.sh"; node_perf_report '"$PB"'/perf-baseline.txt' \
        > "$OUT/nb.out" 2>&1 || rc=$?
    t "perf-report без root: нечитаемый baseline -> понятная строка, rc 0" "[ $rc = 0 ] && grep -q 'baseline' $OUT/nb.out"
    t "perf-report без root: временный файл не оставлен" "[ -z \"\$(ls -A $OUT/nb-tmp)\" ]"
    rm -rf "$PB"
else
    echo "skip - perf-report без root (нужен root + runuser)"
fi
echo
if [ "$fails" -eq 0 ]; then echo "PASS: status-multivalue (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
