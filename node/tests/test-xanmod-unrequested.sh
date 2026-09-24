#!/bin/bash
# node — тест: status предупреждает, если GRUB по умолчанию загрузит НЕ запрошенный XanMod.
# 2026-09-24 (v1.1.5): на живой ноде стоял linux-image-6.18.50-x64v3-xanmod1 (поставлен
# другим инструментом 2026-09-11), первая запись GRUB (GRUB_DEFAULT=0) — XanMod, а
# ENABLE_XANMOD=0: следующий reboot молча сменил бы ядро (ограничение №2), status молчал.
# Read-only: фикстуры grub.cfg / default-grub через NODE_GRUB_CFG / NODE_GRUB_DEFAULT_FILE.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/state"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
mkcfg() { printf 'menuentry "Ubuntu" {\n\tlinux\t/boot/vmlinuz-%s root=UUID=x ro\n}\nsubmenu "Advanced" {\n\tlinux\t/boot/vmlinuz-%s root=UUID=x ro\n}\n' "$1" "$(uname -r)" > "$OUT/grub.cfg"; }
st() { # st <ENABLE_XANMOD> -> вывод status
    printf 'ENABLE_XANMOD=%s\n' "$1" > "$OUT/node.conf"
    NODE_CONFIG="$OUT/node.conf" NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diag" NODE_LOG="$OUT/log" \
    NODE_PROFILE_DIR="$OUT/profile.d" NODE_GRUB_CFG="$OUT/grub.cfg" NODE_GRUB_DEFAULT_FILE="$OUT/default-grub" NO_COLOR=1 \
        bash "$NODE_DIR/main.sh" status 2>&1 || true
}
printf 'GRUB_DEFAULT=0\n' > "$OUT/default-grub"
mkcfg 6.18.50-x64v3-xanmod1
st 0 > "$OUT/s1"
t "XanMod в записи GRUB по умолчанию, ENABLE_XANMOD=0 -> предупреждение о смене ядра при reboot" \
  "grep -q 'следующий reboot загрузит 6.18.50-x64v3-xanmod1' $OUT/s1"
st 1 > "$OUT/s2"
t "ENABLE_XANMOD=1 (запрошен) -> без этого предупреждения" "! grep -q 'следующий reboot загрузит' $OUT/s2"
mkcfg "$(uname -r)"; st 0 > "$OUT/s3"
t "по умолчанию грузится текущее stock-ядро -> без предупреждения" "! grep -q 'следующий reboot загрузит' $OUT/s3"
mkcfg 6.18.50-x64v3-xanmod1; printf 'GRUB_DEFAULT=saved\n' > "$OUT/default-grub"; st 0 > "$OUT/s4"
t "GRUB_DEFAULT не 0 (saved) -> запись не угадываем, без ложного предупреждения" "! grep -q 'следующий reboot загрузит' $OUT/s4"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: xanmod-unrequested (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
