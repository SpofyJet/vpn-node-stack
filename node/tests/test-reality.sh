#!/bin/bash
# node — тест: reality-check (v1.2.2) — dest из `api lsi` (фикстура), замер через curl-заглушку.
# Проверяем: dest извлекается (в т.ч. голый порт и без порта), приватный ключ/UUID из API в вывод не
# попадают, совет «сменить dest» — только при выигрыше >= 20 мс и только кандидату с HTTP/2.
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
 {"tag": "VLESS_REALITY_2", "receiverSettings": [{"streamSettings": {"securitySettings": [{"_TypedMessage_": "xray.transport.internet.reality.Config",
   "dest": "8443"}]}}]},
 {"tag": "SS", "receiverSettings": [{"port": 8388}]}
]}
EOF
# curl-заглушка: «namelookup appconnect http_version» по хосту из URL
cat > "$OUT/bin/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"; h="${url#https://}"; h="${h%%:*}"
case "$h" in
  far.example)   echo "0.001 0.121 2" ;;   # 120 мс
  127.0.0.1)     echo "0.000 0.004 2" ;;
  near.example)  echo "0.002 0.017 2" ;;   # 15 мс
  noh2.example)  echo "0.001 0.006 1.1" ;; # быстрее всех, но без HTTP/2 — не подходит
  close.example) echo "0.001 0.111 2" ;;   # 110 мс
  *)             exit 35 ;;                # TLS не договорились
esac
EOF
chmod +x "$OUT/bin/curl"; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/lib/reality.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

d="$(node_reality_dests)"
t "dest из api lsi: far.example:443 и голый порт -> 127.0.0.1:8443" "[ \"\$(printf '%s' \"$d\" | tr '\n' ' ')\" = 'far.example:443 127.0.0.1:8443' ]"
r="$(node_reality_check near.example noh2.example dead.example 2>&1)"; printf '%s\n' "$r" > "$OUT/r1"
t "текущий dest с замером и оценкой МЕДЛЕННО (120 мс)" "grep -qE 'far.example:443 +120 мс .*МЕДЛЕННО' $OUT/r1"
t "кандидат без HTTP/2 помечен как неподходящий" "grep -qE 'noh2.example:443 .*без HTTP/2' $OUT/r1"
t "недоступный кандидат помечен" "grep -qE 'dead.example:443 +недоступен' $OUT/r1"
t "совет по самому медленному dest (120 мс): near.example, а не noh2 (без HTTP/2)" "grep -q 'Быстрее текущего: near.example:443 — 15 мс против 120 мс' $OUT/r1"
t "приватный ключ и UUID из API не попали в вывод" "! grep -qE '169|0f5d1a2b|user1' $OUT/r1"
# только далёкий dest (второй инбаунд убран) — совет сменить на near.example
python3 -c "import json; d=json.load(open('$OUT/lsi.json')); d['inbounds']=d['inbounds'][:1]; json.dump(d, open('$OUT/lsi.json','w'))"
node_reality_check near.example noh2.example close.example > "$OUT/r2" 2>&1
t "совет сменить: near.example — 15 против 120 мс" "grep -q 'Быстрее текущего: near.example:443 — 15 мс против 120 мс' $OUT/r2"
node_reality_check close.example > "$OUT/r3" 2>&1
t "разница < 20 мс (110 против 120) — менять не нужно" "grep -q 'менять не нужно' $OUT/r3"
t "в журнал node ничего из API не записано" "! grep -qE '169|0f5d1a2b|far.example' $NODE_LOG"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: reality-check"; else echo "FAILED: $fails"; exit 1; fi
