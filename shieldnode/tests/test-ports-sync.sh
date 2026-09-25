#!/bin/bash
# shieldnode — тест ports-sync на настоящем nft (v1.2.0, DIAGNOSIS P0-2).
# Прод: порты определялись только на apply — remnanode, настроенный панелью позже, новый инбаунд,
# новые правила UFW оставались без защиты (E3). Теперь ports-sync сверяет наборы с реальностью.
# Плюс ограничение API ноды панелью — живыми TCP-соединениями из клиентского netns.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 && command -v ip >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "SKIP: нет nft/ip/python3"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /run /etc/node-profile.d; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-ports; rm -rf "$OUT"; mkdir -p "$OUT/state" "$OUT/ufw" "$OUT/sys/net/ipv4" "$OUT/rn" "$OUT/bin"
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_LOCK=/run/shieldnode/shieldnode.lock
export SHIELD_CONFIG="$OUT/c" SHIELD_EXCLUDE="$OUT/none" SHIELD_UFW_DIR="$OUT/ufw" SHIELD_PROC_SYS="$OUT/sys" SHIELD_REMNANODE_DIR="$OUT/rn"
export SHIELD_NFT_PERSIST="$OUT/shieldnode.conf" SHIELD_XRAY_LSI_FILE="$OUT/lsi.json" SHIELD_DETECT_STABLE_DELAY=0
export SHIELD_NODE_INSTALL="$OUT/bin/node-install" SSH_CONNECTION=""
mkdir -p /run/shieldnode; : > "$OUT/log"
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nENABLE_BLOCKLISTS=0\n' > "$OUT/c"
echo "10240 65535" > "$OUT/sys/net/ipv4/ip_local_port_range"; : > "$OUT/sys/net/ipv4/ip_local_reserved_ports"
printf 'NODE_PORT=2222\n' > "$OUT/rn/.env"
printf '#!/bin/sh\necho "$*" >> %s/node-calls\n' "$OUT" > "$OUT/bin/node-install"; chmod +x "$OUT/bin/node-install"
echo 'ENABLED=yes' > "$OUT/ufw/ufw.conf"; : > "$OUT/ufw/user6.rules"
lsi() { # lsi "<tag:port:tcp|udp|both>..."
    python3 - "$@" > "$OUT/lsi.json" <<'PY'
import json, sys
ib = []
for spec in sys.argv[1:]:
    tag, port, tr = spec.split(":")
    ps = {"_TypedMessage_": "xray.proxy.shadowsocks.ServerConfig", "network": ["TCP", "UDP"]} if tr == "both" else \
         ({"_TypedMessage_": "xray.proxy.hysteria.ServerConfig"} if tr == "udp" else {"_TypedMessage_": "xray.proxy.vless.inbound.Config"})
    ib.append({"tag": tag, "receiverSettings": {"listen": "0.0.0.0", "portList": int(port)}, "proxySettings": ps})
print(json.dumps({"inbounds": ib}))
PY
}
ufw_rules() { printf '%s\n' "$@" > "$OUT/ufw/user.rules"; }
sync() { bash "$SHIELD_DIR/main.sh" ports-sync >/dev/null 2>&1 || true; }
el() { nft -n list set inet shieldnode "$1" | awk '/elements = \{/{f=1; sub(/.*elements = \{/,"")} f{l=$0; e=sub(/\}.*/,"",l); print l; if(e) f=0}' | tr ',\t\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

# клиентский netns: 10.79.0.2 (панель) и 10.79.0.3 (чужой)
C=sps$$; ip netns add "$C"; LISTENER=""
trap '[ -n "$LISTENER" ] && kill $LISTENER 2>/dev/null; ip netns del "$C" 2>/dev/null || true' EXIT
ip link add pa$$ type veth peer name pb$$; ip link set pb$$ netns "$C"
ip link set lo up; ip -n "$C" link set lo up
ip addr add 10.79.0.1/24 dev pa$$; ip -n "$C" addr add 10.79.0.2/24 dev pb$$; ip -n "$C" addr add 10.79.0.3/24 dev pb$$
ip link set pa$$ up; ip -n "$C" link set pb$$ up
python3 -c 'import socket,time
ss=[]
for p in (22,2222):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",p)); s.listen(64); ss.append(s)
time.sleep(600)' & LISTENER=$!
sleep 0.5
conn() { ip netns exec "$C" python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(2); s.bind((sys.argv[1],0))
try: s.connect(("10.79.0.1", int(sys.argv[2]))); print("open")
except Exception: print("closed")' "$1" "$2"; }

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

# 1) исходное состояние: VLESS 443, UFW 80; API ноды без источников -> не ограничен
lsi VLESS:443:tcp; ufw_rules '-A ufw-user-input -p tcp --dport 80 -j ACCEPT' '-A ufw-user-input -p tcp --dport 2222 -j ACCEPT'
( source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1
  source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/limits.sh"; source "$SHIELD_DIR/lib/nft.sh"
  shield_limits_resolve >/dev/null 2>&1; shield_nft_build_ruleset ) > "$SHIELD_NFT_PERSIST"
t "ruleset загружен" "nft -f $SHIELD_NFT_PERSIST"
t "старт: protected_tcp = 22 80 443 2222" "[ \"\$(el protected_tcp)\" = '22, 80, 443, 2222' ] || [ \"\$(el protected_tcp)\" = '22 80 443 2222' ]"
t "API ноды без известных источников — открыт (панель не отрезана), набор порта пуст" "[ -z \"\$(el node_api_port)\" ] && [ \"\$(conn 10.79.0.3 2222)\" = open ]"

# 2) панель добавила инбаунды (SS tcp+udp 8388, hysteria udp 36712) — без apply
lsi VLESS:443:tcp SS:8388:both HY2:36712:udp; sync
t "sync: новый TCP-инбаунд 8388 защищён" "grep -qw 8388 <<<\"\$(el protected_tcp)\""
t "sync: UDP 8388 и 36712 защищены" "[ \"\$(el protected_udp | tr -d ,)\" = '8388 36712' ]"
t "sync: сохранённый ruleset (boot) обновлён и проходит nft -c" "grep -q 'elements = { 8388,36712 }' $SHIELD_NFT_PERSIST && nft -c -f $SHIELD_NFT_PERSIST"
t "sync: node reserve-ports вызван" "grep -qx reserve-ports $OUT/node-calls"
t "sync: контракт для node — inbound_udp=8388 36712" "grep -qx 'inbound_udp=8388 36712' /etc/node-profile.d/stack.conf"
t "sync: изменение залогировано" "grep -q 'защищаемые порты обновлены' $OUT/log"

# 3) повтор без изменений — тишина
: > "$OUT/log"; : > "$OUT/node-calls"; sync
t "повтор без изменений: ни лога, ни вызова node" "! grep -q 'обновлены' $OUT/log && [ ! -s $OUT/node-calls ]"

# 4) оператор ограничил API ноды в UFW (allow from панели) -> только панель
ufw_rules '-A ufw-user-input -p tcp --dport 80 -j ACCEPT' '-A ufw-user-input -p tcp --dport 2222 -s 10.79.0.2 -j ACCEPT'; sync
t "API ноды: разрешён только 10.79.0.2 (из UFW allow from)" "[ \"\$(el node_api_allow_v4)\" = '10.79.0.2' ] && [ \"\$(el node_api_port)\" = '2222' ]"
t "API ноды: панель 10.79.0.2 подключается" "[ \"\$(conn 10.79.0.2 2222)\" = open ]"
t "API ноды: чужой 10.79.0.3 — отброшен" "[ \"\$(conn 10.79.0.3 2222)\" = closed ]"
t "SSH 22 с чужого адреса по-прежнему открыт (ограничен только API)" "[ \"\$(conn 10.79.0.3 22)\" = open ]"
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nENABLE_BLOCKLISTS=0\nTRUSTED_IPS="10.79.0.3"\n' > "$OUT/c"; sync
t "TRUSTED_IPS добавил 10.79.0.3 — и он подключается" "[ \"\$(conn 10.79.0.3 2222)\" = open ]"

# 5) инбаунд удалён в панели — уходит из защиты; ядро лежит — порты остаются
lsi VLESS:443:tcp; sync
t "инбаунд удалён: 8388/36712 сняты" "[ -z \"\$(el protected_udp)\" ] && ! grep -qw 8388 <<<\"\$(el protected_tcp)\""
rm -f "$OUT/lsi.json"; SHIELD_XRAY_LSI_FILE=/nonexistent bash "$SHIELD_DIR/main.sh" ports-sync >/dev/null 2>&1 || true
t "ядро не запущено: последние известные порты сохранены (443)" "grep -qw 443 <<<\"\$(el protected_tcp)\""

nft list ruleset > "$SHIELD_NFT_PERSIST.bak-verify"
# 5b) verify на НАСТОЯЩЕМ nft (v1.2.0: на лабе verify ложно падал — «nft list chains <таблица>»
# синтаксически неверен в nft 1.0.9, проверка хуков всегда давала пусто)
vfy() { ( source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config >/dev/null 2>&1
          source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/lib/ports.sh"; shield_verify ) > "$OUT/verify.out" 2>&1; }
vrc=0; vfy || vrc=$?
t "verify: полный ruleset — rc 0, ни одного ✘" "[ $vrc = 0 ] && ! grep -q '✘' $OUT/verify.out"
t "verify: хуки prerouting и v6_output найдены" "grep -q '✔ цепочка prerouting подключена' $OUT/verify.out && grep -q '✔ IPv6 fail-safe на выходе' $OUT/verify.out"
nft delete chain inet shieldnode v6_output; vfy || true
t "verify: удалённая цепочка v6_output -> ✘ (негативный контроль)" "grep -q '✘ нет цепочки v6_output' $OUT/verify.out"
{ echo "flush ruleset"; cat "$SHIELD_NFT_PERSIST.bak-verify"; } | nft -f - 2>/dev/null || true

# 6) аварийный режим — sync ничего не трогает
lsi VLESS:443:tcp SS:8388:both; touch /run/shieldnode/emergency; sync
t "emergency: sync пропущен" "! grep -qw 8388 <<<\"\$(el protected_tcp)\""
rm -f /run/shieldnode/emergency

echo
if [ "$fails" -eq 0 ]; then echo "PASS: ports-sync (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
