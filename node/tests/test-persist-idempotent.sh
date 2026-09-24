#!/bin/bash
# node — тест: persist не перезаписывает и не бэкапит файл с тем же содержимым;
# update-grub — только при изменении grub-сниппета.
# 2026-09-24 (v1.1.6): каждый apply/rt-reapply переписывал все свои файлы и делал
# .pre-node-* даже при идентичном содержимом: при BACKUP_KEEP=5 пять повторных
# apply вытесняли все значимые старые версии одинаковыми копиями; update-grub
# (перегенерация grub.cfg) — на каждом apply (HARDEN_KDUMP=1 по умолчанию).
# Под root: `unshare -m` + tmpfs поверх /etc/default/grub.d и /etc/apt/apt.conf.d.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: unshare -m недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
for d in /etc/default/grub.d /etc/apt/apt.conf.d; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/etc"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" NODE_CONFIG="$OUT/c" DRY_RUN=0
: > "$OUT/c"; : > "$OUT/log"
printf '#!/bin/sh\necho x >> %s/update-grub.calls\n' "$OUT" > "$OUT/bin/update-grub"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/systemctl"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1 || true
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/services.sh"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
F="$OUT/etc/99-z0-node-base.conf"
echo "a = 1" | node_persist_stream "$F" >/dev/null 2>&1
m1="$(stat -c %Y.%i "$F")"; sleep 1
echo "a = 1" | node_persist_stream "$F" >/dev/null 2>&1
t "то же содержимое: файл не переписан (mtime/inode прежние)" "[ \"\$(stat -c %Y.%i $F)\" = '$m1' ]"
t "то же содержимое: .pre-node-* не создан" "! ls $F.pre-node-* >/dev/null 2>&1"
echo "a = 2" | node_persist_stream "$F" >/dev/null 2>&1
t "другое содержимое: записано, backup прежней версии есть" "grep -qx 'a = 2' $F && grep -qx 'a = 1' \$(ls $F.pre-node-* | head -1)"
t "манифест содержит путь" "grep -qxF '$F' $NODE_STATE_DIR/applied-files.txt"
# update-grub: только при изменении сниппета kdump
printf 'HARDEN_BG_SERVICES=0\nHARDEN_UNATTENDED=0\nHARDEN_PACKAGEKIT=0\nHARDEN_IRQBALANCE=0\nHARDEN_RPCBIND=0\n' > "$OUT/c"
node_load_config >/dev/null 2>&1 || true
node_services_apply >/dev/null 2>&1; node_services_apply >/dev/null 2>&1; node_services_apply >/dev/null 2>&1
t "HARDEN_KDUMP: 3 apply подряд -> update-grub ровно 1 раз" "[ \$(wc -l < $OUT/update-grub.calls) = 1 ]"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: persist-idempotent (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
