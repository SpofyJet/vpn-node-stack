#!/bin/bash
# node — тест: reality-check (v1.2.2, v1.2.4) — dest из `api lsi` (фикстура), замер через curl-заглушку.
# Проверяем: dest и SNI извлекаются (голый порт, host без порта, unix-сокет selfsteal); замер идёт к
# адресу dest С SNI из serverNames (как REALITY) — selfsteal отвечает только на свой домен; приватный
# ключ/UUID из API в вывод не попадают; совет «сменить dest» — при выигрыше >= 20 мс и только с HTTP/2.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" NODE_XRAY_LSI_FILE="$OUT/lsi.json"
: > "$OUT/log"
cat > "$OUT/lsi.json" <<'EOF'
{"inbounds": [
 {"tag": "VLESS_REALITY", "receiverSettings": [{"streamSettings": {"securitySettings": [{"_TypedMessage_": "xray.transport.internet.reality.Config",
   "dest": "far.example:443", "privateKey": [169, 159, 8, 147], "serverNames": ["far.example"]}]}}],
  "proxySettings": {"clients": [{"id": "0f5d1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b", "email": "user1"}]}},
 {"tag": "SELFSTEAL_TCP", "receiverSettings": [{"streamSettings": {"securitySettings": [{"_TypedMessage_": "xray.transport.internet.reality.Config",
   "dest": "8443", "serverNames": ["cdn.x", "www.cdn.x"]}]}}]},
 {"tag": "SELFSTEAL_UNIX", "receiverSettings": [{"streamSettings": {"securitySettings": [{"_TypedMessage_": "xray.transport.internet.reality.Config",
   "dest": "/dev/shm/s.sock", "serverNames": ["cdn.x"]}]}}]},
 {"tag": "SS", "receiverSettings": [{"port": 8388}]}
]}
EOF
# curl-заглушка: «namelookup appconnect http_version». Ключ — куда и с каким SNI идёт соединение;
# selfsteal (127.0.0.1:8443, сокет) отвечает только на SNI cdn.x, иначе TLS не договаривается
cat > "$OUT/bin/curl" <<'EOF'
#!/bin/bash
sock=""; ct=""; url="${@: -1}"
while [ $# -gt 0 ]; do case "$1" in --unix-socket) sock="$2"; shift ;; --connect-to) ct="$2"; shift ;; esac; shift; done
sni="${url#https://}"; sni="${sni%%/*}"; sni="${sni%%:*}"
if [ -n "$sock" ]; then key="sock:$sock:$sni"
elif [ -n "$ct" ]; then key="ct:${ct#*:*:}:$sni"
else key="$sni"; fi
case "$key" in
  far.example)                echo "0.001 0.121 2" ;;   # 120 мс
  near.example)               echo "0.002 0.017 2" ;;   # 15 мс
  noh2.example)               echo "0.001 0.006 1.1" ;; # быстрее всех, но без HTTP/2 — не подходит
  close.example)              echo "0.001 0.111 2" ;;   # 110 мс
  ct:127.0.0.1:8443:cdn.x)    echo "0.000 0.005 2" ;;   # selfsteal по TCP с правильным SNI
  sock:/dev/shm/s.sock:cdn.x) echo "0.000 0.003 2" ;;   # selfsteal по сокету с правильным SNI
  *)                          exit 35 ;;                # TLS не договорились (в т.ч. selfsteal без SNI)
esac
EOF
chmod +x "$OUT/bin/curl"; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/lib/reality.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

node_reality_dests > "$OUT/d"
t "dest+SNI из api lsi: far.example:443/far.example, голый порт -> 127.0.0.1:8443/cdn.x, сокет как есть" \
  "[ \"\$(tr '\t\n' '| ' < $OUT/d)\" = 'far.example:443|far.example 127.0.0.1:8443|cdn.x /dev/shm/s.sock|cdn.x ' ]"
t "отрицательный контроль: selfsteal 127.0.0.1:8443 без SNI не отвечает (так проверяла 1.2.2)" "[ -z \"\$(node_reality_probe 127.0.0.1:8443)\" ]"
t "selfsteal 127.0.0.1:8443 с SNI cdn.x: 5 мс" "[ \"\$(node_reality_probe 127.0.0.1:8443 cdn.x)\" = '5 yes yes' ]"
t "selfsteal unix-сокет с SNI cdn.x: 3 мс" "[ \"\$(node_reality_probe /dev/shm/s.sock cdn.x)\" = '3 yes yes' ]"
node_reality_check near.example noh2.example dead.example > "$OUT/r1" 2>&1
t "текущий далёкий dest: 120 мс, МЕДЛЕННО" "grep -qE 'far.example:443 +120 мс .*МЕДЛЕННО' $OUT/r1"
t "selfsteal в отчёте: SNI и пометка, 5 и 3 мс, отлично" "grep -qE '127.0.0.1:8443 \\(SNI cdn.x\\), selfsteal на этой ноде +5 мс .*отлично' $OUT/r1 && grep -qE '/dev/shm/s.sock \\(SNI cdn.x\\), selfsteal на этой ноде +3 мс' $OUT/r1"
t "кандидат без HTTP/2 помечен как неподходящий" "grep -qE 'noh2.example:443 .*без HTTP/2' $OUT/r1"
t "недоступный кандидат помечен" "grep -qE 'dead.example:443 +недоступен' $OUT/r1"
t "совет по самому медленному dest (120 мс): near.example, а не noh2" "grep -q 'Быстрее текущего: near.example:443 — 15 мс против 120 мс' $OUT/r1"
t "приватный ключ и UUID из API не попали в вывод" "! grep -qE '169|0f5d1a2b|user1' $OUT/r1"
# только selfsteal (далёкий dest убран) — менять не нужно
python3 -c "import json; d=json.load(open('$OUT/lsi.json')); d['inbounds']=d['inbounds'][1:]; json.dump(d, open('$OUT/lsi.json','w'))"
node_reality_check near.example > "$OUT/r2" 2>&1
t "только selfsteal: совета сменить нет" "grep -q 'менять не нужно' $OUT/r2 && ! grep -q 'Быстрее текущего' $OUT/r2"
t "в журнал node ничего из API не записано" "! grep -qE '169|0f5d1a2b|far.example' $NODE_LOG"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: reality-check"; else cat "$OUT/r1"; echo "FAILED: $fails"; exit 1; fi
