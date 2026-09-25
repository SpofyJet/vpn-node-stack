#!/bin/bash
# shieldnode — тест: защищаемые порты берутся и из UFW, и от VPN-ядра под новыми именами.
# 2026-09-24 (v1.1.6): на живой ноде protected_tcp = [22] при открытых в UFW 80/443/2222:
# авто-детект видел только порты, которые В МОМЕНТ apply слушали процессы xray|remnanode
# (не запущен контейнер; API ноды 2222 слушает процесс node; в образе remnawave/node
# Xray называется rw-core). Ещё: -tulnp складывал UDP-порты xray в protected_tcp, а
# опечатка в PROTECTED_*_EXTRA роняла весь ruleset в nft -c.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/ufw"
cat > "$OUT/bin/ss" <<'EOS'
#!/bin/bash
ssh='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
core_t='LISTEN 0 4096 *:8443 *:* users:(("rw-core",pid=77,fd=7))'
api_t='LISTEN 0 4096 127.0.0.1:61000 0.0.0.0:* users:(("rw-core",pid=77,fd=8))'
core_u='UNCONN 0 0 0.0.0.0:36712 0.0.0.0:* users:(("hysteria",pid=78,fd=9))'
case "$*" in
  "-tulnp") echo 'Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
            echo "tcp $ssh"; echo "tcp $core_t"; echo "udp $core_u" ;;
  "-ulnp")  echo 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'; echo "$core_u" ;;
  "-tlnp")  echo 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'; echo "$ssh"; echo "$core_t"; echo "$api_t" ;;
  *) echo 'Recv-Q Send-Q Local Address:Port Peer Address:Port Process' ;;
esac
EOS
chmod +x "$OUT/bin/ss"
echo 'ENABLED=yes' > "$OUT/ufw/ufw.conf"
cat > "$OUT/ufw/user.rules" <<'EOS'
### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in
-A ufw-user-input -p tcp --dport 80 -j ACCEPT
-A ufw-user-input -p tcp --dport 443 -j ACCEPT
-A ufw-user-input -p tcp --dport 2222 -s 213.165.55.166 -j ACCEPT
-A ufw-user-input -p tcp --dport 22 -j ufw-user-limit
-A ufw-user-input -p udp --dport 20000:20100 -j ACCEPT
-A ufw-user-input -p tcp -m multiport --dports 7000,7001 -j ACCEPT
-A ufw-user-input -p tcp --dport 9999 -j DROP
-A ufw-user-input -s 10.0.0.5 -j ACCEPT
-A ufw-user-output -p tcp --dport 25 -j ACCEPT
EOS
cat > "$OUT/ufw/user6.rules" <<'EOS'
-A ufw6-user-input -p udp --dport 4443 -j ACCEPT
EOS
export PATH="$OUT/bin:$PATH" SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log"
export SHIELD_CONFIG="$OUT/c" SHIELD_EXCLUDE="$OUT/none" SSH_CONNECTION="" SHIELD_UFW_DIR="$OUT/ufw"
mkdir -p "$OUT/sys/net/ipv4"; echo "10240 65535" > "$OUT/sys/net/ipv4/ip_local_port_range"; : > "$OUT/sys/net/ipv4/ip_local_reserved_ports"
export SHIELD_XRAY_LSI_FILE=/nonexistent SHIELD_PROC_SYS="$OUT/sys" SHIELD_DETECT_STABLE_DELAY=0 SHIELD_REMNANODE_DIR="$OUT/no-rn"
: > "$OUT/log"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
resolve() { printf '%b' "$1" > "$OUT/c"
    bash -c 'source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
    source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/limits.sh"; shield_limits_resolve >/dev/null 2>&1
    echo "TCP=[$SH_F_PROTECTED_TCP] UDP=[$SH_F_PROTECTED_UDP]"'; }

r="$(resolve 'SSH_PORT=22\n')"; echo "  ($r)"
t "UFW tcp: 80, 443, 2222 (allow from IP), 22 (limit), multiport 7000,7001" "[[ '$r' == 'TCP=[22 80 443 2222 7000 7001 8443]'* ]]"
t "UFW udp: диапазон 20000:20100 -> 20000-20100, v6-правило 4443" "[[ '$r' == *'UDP=[4443 20000-20100]' ]]"
t "UFW: DROP, output-цепочка и правило без порта — не берутся" "[[ '$r' != *9999* && '$r' != *' 25 '* && '$r' != *25]* ]]"
t "rw-core (Xray в remnawave/node) — tcp 8443 защищён" "[[ '$r' == *8443* ]]"
t "loopback-API ядра (127.0.0.1:61000) не защищается" "[[ '$r' != *61000* ]]"
# v1.2.0: UDP-сокет без API (hysteria-процесс, в эфемерном диапазоне, без TCP-двойника) не угадывается —
# неотличим от эфемерного; реальный UDP-инбаунд за UFW (default deny) всё равно открыт в UFW -> берётся оттуда
t "hysteria 36712/udp без API и без UFW-правила — не угадывается; и не в protected_tcp" "[[ '$r' != *36712* ]]"

r="$(resolve 'SSH_PORT=22\nPROTECTED_FROM_UFW=0\n')"
t "PROTECTED_FROM_UFW=0: из UFW ничего" "[[ '$r' == 'TCP=[22 8443] UDP=[]' ]]"
echo 'ENABLED=no' > "$OUT/ufw/ufw.conf"; r="$(resolve 'SSH_PORT=22\n')"
t "UFW выключен (ENABLED=no): из UFW ничего" "[[ '$r' == 'TCP=[22 8443] UDP=[]' ]]"
echo 'ENABLED=yes' > "$OUT/ufw/ufw.conf"

r="$(resolve 'SSH_PORT=22\nPROTECTED_FROM_UFW=0\nPROTECTED_TCP_EXTRA="9443 abc 70000 30000-30010 5-3"\nPROTECTED_UDP_EXTRA="x 5000"\n')"
t "EXTRA: валидные порт/диапазон приняты" "[[ '$r' == *9443* && '$r' == *30000-30010* && '$r' == *5000* ]]"
t "EXTRA: мусор (abc, 70000, 5-3, x) отброшен, а не отправлен в nft" "[[ '$r' != *abc* && '$r' != *70000* && '$r' != *5-3* && '$r' != *x* ]]"
t "EXTRA: warn о пропущенном значении" "grep -q \"'abc' — не порт\" $OUT/log"

# whitelist (TRUSTED_IPS / exclude.conf): только валидные адреса/CIDR с разумной маской
wl() { printf '%b' "$1" > "$OUT/c"; printf '%b' "${2:-}" > "$OUT/excl"
    SHIELD_EXCLUDE="$OUT/excl" bash -c 'source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
    source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/limits.sh"; shield_limits_resolve >/dev/null 2>&1
    echo "V4=[$SH_F_EXCL_V4] V6=[$SH_F_EXCL_V6]"'; }
: > "$OUT/log"
r="$(wl 'SSH_PORT=22\nTRUSTED_IPS="1.2.3.4 10.0.0.0/8 0.0.0.0/0 1.2.3.4} 999.1.1.1 2001:db8::/32 ::/0"\n' 'IP 5.6.7.0/24\nIP 1.1.1.1;\nIP6 2001:db8:1::/48\nIP 0.0.0.0/1\n')"; echo "  ($r)"
t "whitelist: валидные адреса/CIDR приняты" "[[ '$r' == *'5.6.7.0/24'* && '$r' == *'1.2.3.4'* && '$r' == *'10.0.0.0/8'* && '$r' == *'2001:db8::/32'* && '$r' == *'2001:db8:1::/48'* ]]"
t "whitelist: 0.0.0.0/0, ::/0, /1 — отвергнуты (весь интернет без защиты)" "[[ '$r' != *'[0.0.0.0/'* && '$r' != *' 0.0.0.0/'* && '$r' != *'::/0'* ]]"
t "whitelist: мусор с nft-синтаксисом (}, ;) и 999.x — отвергнут" "[[ '$r' != *'}'* && '$r' != *';'* && '$r' != *999* ]]"
t "whitelist: warn в логе" "grep -q 'TRUSTED_IPS: .0.0.0.0/0.' $OUT/log && grep -q 'exclude' $OUT/log"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: protected-ufw (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
