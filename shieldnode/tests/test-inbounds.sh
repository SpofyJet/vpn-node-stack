#!/bin/bash
# shieldnode — тест детектора инбаундов (v1.2.0, DIAGNOSIS P0-1).
# Прод: apply брал в protected_udp ВСЕ UNCONN-сокеты rw-core — ~35 эфемерных портов исходящих
# UDP-потоков клиентов (DNS/QUIC), health вечно флапал. Теперь: источник правды — конфиг
# Xray через API (`api lsi`), без API — консервативная эвристика. Фикстуры: реальный формат
# `rw-core api lsi` (remnanode 2.x / Xray 26.x) и `ss` с 60 эфемерными UDP-сокетами.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/sys/net/ipv4" "$OUT/remnanode"
export SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_CONFIG="$OUT/c" SHIELD_EXCLUDE="$OUT/none"
export SHIELD_UFW_DIR="$OUT/no-ufw" SHIELD_PROC_SYS="$OUT/sys" SHIELD_REMNANODE_DIR="$OUT/remnanode" SSH_CONNECTION=""
export SHIELD_DETECT_STABLE_DELAY=0 SS_STATE="$OUT/ss.n"
: > "$OUT/log"; printf 'SSH_PORT=22\n' > "$OUT/c"
echo "10240	65535" > "$OUT/sys/net/ipv4/ip_local_port_range"
echo "30500" > "$OUT/sys/net/ipv4/ip_local_reserved_ports"

# --- ss: реальные инбаунды + rw-node + 60 эфемерных UDP (разные в двух замерах) ---
cat > "$OUT/bin/ss" <<'EOS'
#!/bin/bash
n=$(cat "$SS_STATE" 2>/dev/null || echo 0)
mode="${SS_MODE:-up}"
case "$*" in
  *-u*l*|*-ul*)
    [ "$mode" = down ] && exit 0
    echo "UNCONN 0 0 *:8388 *:* users:((\"rw-core\",pid=77,fd=10))"
    echo "UNCONN 0 0 *:5000 *:* users:((\"rw-core\",pid=77,fd=11))"      # вне эфемерного диапазона
    echo "UNCONN 0 0 *:30500 *:* users:((\"rw-core\",pid=77,fd=12))"     # в ip_local_reserved_ports
    # эфемерные: в первом замере 60 портов, во втором — другие (кроме 3 «долгих»)
    for i in $(seq 1 60); do p=$(( 20000 + i * 97 + n * 13 )); echo "UNCONN 0 0 *:$p *:* users:((\"rw-core\",pid=77,fd=$((20+i))))"; done
    for p in 41000 41001 41002; do echo "UNCONN 0 0 *:$p *:* users:((\"rw-core\",pid=77,fd=99))"; done   # стабильные эфемерные (долгий QUIC)
    echo $((n + 1)) > "$SS_STATE" ;;
  *-t*l*|*-tl*)
    echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))"
    [ "$mode" = down ] && exit 0
    echo "LISTEN 0 4096 *:443 *:* users:((\"rw-core\",pid=77,fd=4))"
    echo "LISTEN 0 4096 *:8388 *:* users:((\"rw-core\",pid=77,fd=7))"
    echo "LISTEN 0 4096 127.0.0.1:10085 0.0.0.0:* users:((\"rw-core\",pid=77,fd=8))"
    echo "LISTEN 0 511 *:2222 *:* users:((\"rw-node\",pid=66,fd=21))" ;;
  *-x*) : ;;
esac
exit 0
EOS
chmod +x "$OUT/bin/ss"; export PATH="$OUT/bin:$PATH"

cat > "$OUT/lsi.json" <<'EOJ'
{"inbounds": [
 {"tag": "REMNAWAVE_API_INBOUND", "receiverSettings": {"_TypedMessage_": "xray.app.proxyman.ReceiverConfig", "listen": "@xtls-api-AbC123"},
  "proxySettings": {"_TypedMessage_": "xray.proxy.dokodemo.Config", "allowedNetworks": ["TCP"]}},
 {"tag": "VLESS_REALITY", "receiverSettings": {"_TypedMessage_": "x", "listen": "0.0.0.0", "portList": 443, "streamSettings": {"protocolName": "tcp"}},
  "proxySettings": {"_TypedMessage_": "xray.proxy.vless.inbound.Config", "users": [{"id": "SECRET-UUID"}]}},
 {"tag": "SS_UDP", "receiverSettings": {"_TypedMessage_": "x", "listen": "0.0.0.0", "portList": 8388},
  "proxySettings": {"_TypedMessage_": "xray.proxy.shadowsocks.ServerConfig", "network": ["TCP", "UDP"], "users": [{"password": "SECRET"}]}},
 {"tag": "HY2", "receiverSettings": {"_TypedMessage_": "x", "listen": "::", "portList": 36712},
  "proxySettings": {"_TypedMessage_": "xray.proxy.hysteria.ServerConfig"}},
 {"tag": "KCP", "receiverSettings": {"_TypedMessage_": "x", "portList": 9000, "streamSettings": {"protocolName": "mkcp"}},
  "proxySettings": {"_TypedMessage_": "xray.proxy.vmess.inbound.Config"}},
 {"tag": "XHTTP_RANGE", "receiverSettings": {"_TypedMessage_": "x", "portList": "20000-20010", "streamSettings": {"protocolName": "splithttp"}},
  "proxySettings": {"_TypedMessage_": "xray.proxy.vless.inbound.Config"}},
 {"tag": "DICT_RANGE", "receiverSettings": {"_TypedMessage_": "x", "portList": {"range": [{"From": 7000, "To": 7001}]}},
  "proxySettings": {"_TypedMessage_": "xray.proxy.trojan.ServerConfig"}},
 {"tag": "LOCAL_API", "receiverSettings": {"_TypedMessage_": "x", "listen": "127.0.0.1", "portList": 10085},
  "proxySettings": {"_TypedMessage_": "xray.proxy.dokodemo.Config"}}
]}
EOJ

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
det() { # det [env...] -> "SRC|TCP|UDP|API"
    env "$@" bash -c 'source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1
        source "$SHIELD_DIR/detect.sh"; SH_IB_DONE=0; shield_detect_inbounds
        echo "$SH_IB_SOURCE|$SH_IB_TCP|$SH_IB_UDP|$SH_IB_API_PORT"' 2>/dev/null || echo "missing|||"; }
resolve() {
    env "$@" bash -c 'source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1
        source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/limits.sh"; shield_limits_resolve >/dev/null 2>&1
        echo "TCP=[$SH_F_PROTECTED_TCP] UDP=[$SH_F_PROTECTED_UDP]"' 2>/dev/null || echo "resolve-failed"; }

# ---------- 1. источник правды: конфиг Xray (api lsi) ----------
r="$(det SHIELD_XRAY_LSI_FILE="$OUT/lsi.json")"; echo "  (api: $r)"
t "api: источник — конфиг Xray" "[[ '$r' == api\|* ]]"
t "api: TCP = 443 7000-7001 8388 20000-20010 (порты инбаундов, диапазоны как есть)" "[[ '$r' == 'api|443 7000-7001 8388 20000-20010|'* ]]"
t "api: UDP = 8388 (SS tcp,udp) 9000 (mkcp) 36712 (hysteria) — и ничего больше" "[[ '$r' == *'|8388 9000 36712|'* ]]"
t "api: ни одного эфемерного UDP-порта из ss (60 сокетов 20097…)" "! grep -qE '\|[^|]*(20[0-9]{3}|41000)[^|]*\|[^|]*$' <<<'$r'"
t "api: loopback-инбаунд 10085 и внутренний @xtls-api — не в списке" "[[ '$r' != *10085* ]]"
t "api: порт API ноды — rw-node 2222" "[[ '$r' == *'|2222' ]]"
t "api: пользователи/секреты из вывода API не попали в лог" "! grep -qE 'SECRET|UUID' '$OUT/log'"

r="$(resolve SHIELD_XRAY_LSI_FILE="$OUT/lsi.json")"; echo "  ($r)"
t "apply: protected_tcp = SSH + инбаунды + API ноды" "[[ '$r' == 'TCP=[22 443 2222 7000-7001 8388 20000-20010]'* ]]"
t "apply: protected_udp = только реальные UDP-инбаунды" "[[ '$r' == *'UDP=[8388 9000 36712]' ]]"

# ---------- 2. без API: консервативная эвристика ----------
echo 0 > "$SS_STATE"
r="$(det SHIELD_XRAY_LSI_FILE=/nonexistent)"; echo "  (heuristic: $r)"
t "эвристика: источник heuristic" "[[ '$r' == heuristic\|* ]]"
t "эвристика: TCP — слушатели ядра (443 8388), без loopback 10085" "[[ '$r' == 'heuristic|443 8388|'* ]]"
t "эвристика: UDP 8388 (есть TCP-слушатель), 5000 (вне диапазона), 30500 (зарезервирован)" "[[ '$r' == *'|5000 8388 30500|'* ]]"
t "эвристика: 60 меняющихся эфемерных + 3 стабильных в диапазоне — НЕ взяты" "[[ '$r' != *2009* && '$r' != *41000* ]]"

# ---------- 3. ядро не запущено: keep-last-good (только тогда) ----------
resolve SHIELD_XRAY_LSI_FILE="$OUT/lsi.json" >/dev/null
r="$(resolve SHIELD_XRAY_LSI_FILE=/nonexistent SS_MODE=down)"; echo "  (down: $r)"
t "ядро лежит: UDP-инбаунды из последнего состояния" "[[ '$r' == *'UDP=[8388 9000 36712]' ]]"
t "ядро лежит: TCP-инбаунды из последнего состояния" "[[ '$r' == *443* && '$r' == *8388* ]]"
printf '8388 12345 23456 34567\n' > "$OUT/state/protected-ports-udp.txt"      # файл v1.3.0 с мусором
rm -f "$OUT/state/protected-ports-udp.v2.txt"
r="$(resolve SHIELD_XRAY_LSI_FILE=/nonexistent SS_MODE=down)"
t "апгрейд: «загрязнённый» файл состояния v1.3.0 не воскрешается" "[[ '$r' != *12345* ]]"

# ---------- 4. порт API ноды, когда remnanode ещё не запущен ----------
printf 'NODE_PORT=2233\nSECRET_KEY=abc\n' > "$OUT/remnanode/.env"
r="$(det SHIELD_XRAY_LSI_FILE=/nonexistent SS_MODE=down)"
t "API ноды из .env remnanode (NODE_PORT), процесс ещё не слушает" "[[ '$r' == *'|2233' ]]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: inbounds (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
