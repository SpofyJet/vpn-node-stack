#!/bin/bash
# shieldnode — тест: отпечаток ports-watch (v1.2.3) — один `ss -Hlntx` вместо pgrep+ss+md5sum.
# Меняется: перезапуск Xray (новое имя @xtls-api-*), новый внешний TCP-слушатель, mtime конфига.
# НЕ меняется: loopback-слушатели. Без API-сокета Xray — запасной путь через pgrep.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/ufw" "$OUT/state"
export SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" SHIELD_CONFIG="$OUT/config.conf" SHIELD_UFW_DIR="$OUT/ufw"
: > "$OUT/config.conf"; : > "$OUT/ufw/user.rules"; : > "$OUT/ufw/ufw.conf"
printf '#!/bin/bash\necho PGREP >> %s/pgrep.log; echo 4242\n' "$OUT" > "$OUT/bin/pgrep"; chmod +x "$OUT/bin/pgrep"
export PATH="$OUT/bin:$PATH"
set +u; source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/lib/ports.sh"; set -u
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
ssf() { printf '%s\n' "$@" > "$OUT/ss"; }
export SHIELD_SS_FIXTURE="$OUT/ss"
base=(
 "u_str LISTEN 0 8192 @xtls-api-AAAA 11243 * 0"
 "u_str LISTEN 0 4096 /run/docker.sock 999 * 0"
 "tcp LISTEN 0 8192 127.0.0.53%lo:53 0.0.0.0:*"
 "tcp LISTEN 0 8192 127.0.0.1:6060 0.0.0.0:*"
 "tcp LISTEN 0 8192 0.0.0.0:22 0.0.0.0:*"
 "tcp LISTEN 0 8192 *:443 *:*"
 "tcp LISTEN 0 8192 *:2222 *:*")
ssf "${base[@]}"; f0="$(_ports_fingerprint)"
t "отпечаток: API-сокет Xray и внешние порты 22/443/2222, без loopback" "[[ '$f0' == '@xtls-api-AAAA t22 t2222 t443 |'* ]]"
t "при API-сокете Xray pgrep не вызывается" "[ ! -e $OUT/pgrep.log ]"
ssf "${base[@]/@xtls-api-AAAA/@xtls-api-BBBB}"; f1="$(_ports_fingerprint)"
t "перезапуск ядра (новое имя API-сокета) -> отпечаток другой" "[ '$f0' != '$f1' ]"
ssf "${base[@]}" "tcp LISTEN 0 8192 *:8443 *:*"; f2="$(_ports_fingerprint)"
t "новый внешний TCP-слушатель (инбаунд) -> отпечаток другой" "[ '$f0' != '$f2' ]"
ssf "${base[@]}" "tcp LISTEN 0 8192 127.0.0.1:61000 0.0.0.0:*" "tcp LISTEN 0 8192 [::1]:7000 [::]:*"; f3="$(_ports_fingerprint)"
t "новый loopback-слушатель -> отпечаток тот же (без лишнего полного прохода)" "[ '$f0' = '$f3' ]"
ssf "${base[@]}"; touch -d '2020-01-01' "$SHIELD_CONFIG"; f4="$(_ports_fingerprint)"
t "изменился config.conf (mtime) -> отпечаток другой" "[ '$f0' != '$f4' ]"
ssf "tcp LISTEN 0 8192 *:443 *:*"; f5="$(_ports_fingerprint)"
t "без API-сокета Xray (sing-box/hysteria) — запасной путь pgrep" "[ -e $OUT/pgrep.log ] && [[ '$f5' == *4242* ]]"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: ports-fingerprint"; else echo "FAILED: $fails"; exit 1; fi
