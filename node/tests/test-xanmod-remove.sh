#!/bin/bash
# node — тест: node_xanmod_remove (v1.2.5) отказывается, когда удаление сломало бы загрузку:
# работающее ядро — XanMod (prerm отказал бы, а раньше `|| true` глотал отказ и в лог шло «удалён»)
# и нет штатного ядра. Проверяются только ветки отказа — до них функция ничего не меняет.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" DRY_RUN=0
: > "$NODE_LOG"
printf '#!/bin/sh\necho "$*" >> %s/apt.calls\nexit 0\n' "$OUT" > "$OUT/bin/apt-get"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/systemctl"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
source "$NODE_DIR/lib/kernel.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

# 1) работает XanMod — отказ, apt не вызывается
printf '#!/bin/sh\necho 6.12.1-x64v3-xanmod1\n' > "$OUT/bin/uname"; chmod +x "$OUT/bin/uname"
rc=0; ( node_xanmod_remove ) > "$OUT/r1" 2>&1 || rc=$?
t "работает XanMod: отказ (rc!=0)" '[ "$rc" != 0 ]'
t "работает XanMod: apt-get purge не вызывался" '[ ! -s "$OUT/apt.calls" ]'
t "работает XanMod: понятная причина" 'grep -q "на ходу не удаляется" "$OUT/r1"'

# 2) штатное ядро, но других (не xanmod) linux-image нет — отказ
printf '#!/bin/sh\necho 6.8.0-111-generic\n' > "$OUT/bin/uname"
printf '#!/bin/sh\necho "ii  linux-image-6.12.1-x64v3-xanmod1 6.12.1 amd64 x"\n' > "$OUT/bin/dpkg"; chmod +x "$OUT/bin/dpkg"
rc=0; ( node_xanmod_remove ) > "$OUT/r2" 2>&1 || rc=$?
t "нет штатного ядра: отказ (rc!=0), apt не вызывался" '[ "$rc" != 0 ] && [ ! -s "$OUT/apt.calls" ]'
t "нет штатного ядра: понятная причина" 'grep -q "штатного ядра" "$OUT/r2"'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: xanmod-remove"; else cat "$OUT/r1" "$OUT/r2"; echo "FAILED: $fails"; exit 1; fi
