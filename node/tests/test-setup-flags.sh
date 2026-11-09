#!/bin/bash
# vpn-node-setup — тест: --help печатает справку, неизвестный флаг — ошибка (setup 1.5.1).
# Прод-ловушка: `vpn-node --help` молча уходил в apply — качал дерево с GitHub, заменял
# установленное и передавал --help модулям. Теперь флаги проверяются ДО любых действий.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/vpn-node-setup.sh"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/work"
# сеть: любое обращение к curl/wget/git — в журнал (и отказ)
for b in curl wget git; do printf '#!/bin/sh\necho "%s $*" >> "%s/net.calls"\nexit 7\n' "$b" "$OUT" > "$OUT/bin/$b"; done
chmod +x "$OUT/bin"/*; : > "$OUT/net.calls"
export PATH="$OUT/bin:$PATH" VPN_STACK_WORK_DIR="$OUT/work" VPN_STACK_TARBALL_URL="http://127.0.0.1:9/none.tar.gz"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
run() { rc=0; bash "$SETUP" "$@" > "$OUT/out" 2> "$OUT/err" < /dev/null || rc=$?; }
clean() { [ -z "$(ls -A "$OUT/work")" ] && [ ! -s "$OUT/net.calls" ]; }

run --help
t "--help: код 0" '[ "$rc" = 0 ]'
t "--help: печатает справку со списком команд" 'grep -q "apply" "$OUT/out" && grep -q -- "--dry-run" "$OUT/out"'
t "--help: ничего не скачано и не записано" 'clean'
run -h
t "-h: код 0 и справка" '[ "$rc" = 0 ] && grep -q "apply" "$OUT/out"'
run apply --help
t "apply --help: справка, apply не запускается" '[ "$rc" = 0 ] && clean'
run --bogus
t "--bogus: код не 0" '[ "$rc" != 0 ]'
t "--bogus: понятная ошибка с именем флага" 'grep -q "неизвестный флаг --bogus" "$OUT/err"'
t "--bogus: ничего не скачано и не записано" 'clean'
run apply -x
t "apply -x: отказ до любых действий" '[ "$rc" != 0 ] && clean'

[ "$fails" -eq 0 ] && echo "PASS: setup-flags (all checks)" || { echo "FAILED: $fails проверок"; exit 1; }
