#!/bin/bash
# node — тест: PMTU-проба различает «gw не отвечает на ICMP» и «DF-пакет не прошёл».
# 2026-09-24 (v1.1.5): на живой ноде gw 172.31.1.1 (on-link, виртуальный) не отвечает
# ни на какой ping, а DF 1500 до интернета проходит — apply писал ложный
# «PMTU probe 1500B to gw: FAIL». Мок ping через PATH; ничего не пишет.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state"
# ping-мок: поведение из $PING_MODE; «big» = есть -M do, иначе «small»
cat > "$OUT/bin/ping" <<'EOF'
#!/bin/bash
big=0; dst="${@: -1}"; for a in "$@"; do [ "$a" = do ] && big=1; done
echo "$dst big=$big" >> "$PING_LOG"
case "$PING_MODE" in
  gw_silent)   [ "$dst" = 10.0.0.1 ] && exit 1; exit 0 ;;          # gw молчит, интернет ок (DF проходит)
  gw_silent_mtu) [ "$dst" = 10.0.0.1 ] && exit 1; [ $big = 1 ] && exit 1; exit 0 ;;
  mtu_bad)     [ $big = 1 ] && exit 1; exit 0 ;;                    # мелкий ok, DF не проходит
  ok)          exit 0 ;;
esac
EOF
chmod +x "$OUT/bin/ping"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
run() { # run <mode> -> вывод node_network_mtu_diag
    : > "$OUT/ping.log"
    NODE_DIR="$NODE_DIR" PING_MODE="$1" PING_LOG="$OUT/ping.log" PATH="$OUT/bin:$PATH" NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" \
    NODE_CONFIG="$OUT/node.conf" NO_COLOR=1 bash -c '
        source "'"$NODE_DIR"'/lib/common.sh"; source "'"$NODE_DIR"'/config.sh"; node_load_config >/dev/null 2>&1 || true
        source "'"$NODE_DIR"'/lib/network.sh"
        node_default_iface() { echo eth0; }; node_default_gw() { echo 10.0.0.1; }
        cat() { if [ "$1" = /sys/class/net/eth0/mtu ]; then echo 1500; else command cat "$@"; fi; }
        node_network_mtu_diag' 2>&1 || true
}
: > "$OUT/node.conf"
run gw_silent > "$OUT/o1"
t "gw молчит на ICMP, DF до внешнего хоста проходит -> без ложного FAIL" "! grep -q 'FAIL' $OUT/o1 && grep -q 'PMTU probe 1500B .*OK' $OUT/o1"
run gw_silent_mtu > "$OUT/o2"
t "gw молчит, DF до внешнего хоста НЕ проходит -> FAIL (по внешнему хосту)" "grep -q 'PMTU probe 1500B .*FAIL' $OUT/o2"
run mtu_bad > "$OUT/o3"
t "gw отвечает на мелкий ping, DF не проходит -> FAIL" "grep -q 'PMTU probe 1500B to gw: FAIL' $OUT/o3"
run ok > "$OUT/o4"
t "всё проходит -> OK" "grep -q 'PMTU probe 1500B to gw: OK' $OUT/o4 && ! grep -q FAIL $OUT/o4"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: pmtu-probe (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
