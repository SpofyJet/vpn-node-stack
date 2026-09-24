#!/bin/bash
# node — тест: rollback ПОСЛЕ ПОВТОРНОГО apply (регрессия 2026-09-23).
#   A. свой файл, записанный дважды, удаляется (раньше «восстанавливался» из
#      собственного бэкапа прошлого apply и переживал откат);
#      pre-existing файл возвращается к состоянию ДО node;
#   B. runtime sysctl возвращается к значению ДО node (реестр sysctl-orig.tsv),
#      а не к значению из снапшота повторного apply. Нужен root: реальный
#      net.core.somaxconn в отдельном netns; без root — B пропускается.
# Под root тест сам уходит в `unshare -mn`: tmpfs поверх /etc/sysctl.d,
# /etc/udev/rules.d, /usr/local/sbin — хост (живая нода) не затрагивается.
set -euo pipefail

if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ] && unshare -mn true 2>/dev/null; then
    NODE_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
IN_NS="${NODE_TEST_IN_NS:-0}"
if [ "$IN_NS" = "1" ]; then
    for d in /etc/sysctl.d /etc/udev/rules.d /usr/local/sbin; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
fi

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-reapply
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diag" NODE_PROFILE_DIR="$OUT/profile.d"
export NODE_LOG="$OUT/node.log" DRY_RUN=0 NODE_VERSION=test
rm -rf "$OUT"; mkdir -p "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR" "$OUT/etc" "$OUT/bin"; touch "$NODE_LOG"
for c in systemctl udevadm nft update-grub; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/apply.sh"; source "$NODE_DIR/detect.sh"
source "$NODE_DIR/lib/sysctl.sh"; source "$NODE_DIR/rollback.sh"

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ---------- A. файлы ----------
OWN="$OUT/etc/99-own.conf"; PRE="$OUT/etc/pre.conf"
echo "ORIGINAL-OPERATOR" > "$PRE"
echo v1 | node_persist_stream "$OWN" >/dev/null; echo n1 | node_persist_stream "$PRE" >/dev/null
sleep 1
echo v2 | node_persist_stream "$OWN" >/dev/null; echo n2 | node_persist_stream "$PRE" >/dev/null   # повторный apply
t "re-apply: бэкап собственной версии создан (условие бага)" 'ls "$OWN".pre-node-* >/dev/null'
t "реестр: own=created, pre=копия" 'grep -qP "^\Q$OWN\E\tcreated$" "$NODE_STATE_DIR/file-origins.tsv" && grep -q "^$PRE	$NODE_STATE_DIR/origins/" "$NODE_STATE_DIR/file-origins.tsv"'
node_rollback "" >/dev/null 2>&1
t "rollback: свой файл УДАЛЁН (не восстановлен из своего бэкапа)" '[ ! -e "$OWN" ]'
t "rollback: pre-existing = состояние ДО node" 'grep -qx ORIGINAL-OPERATOR "$PRE"'
t "rollback: реестр и копии очищены" '[ ! -e "$NODE_STATE_DIR/file-origins.tsv" ] && [ ! -d "$NODE_STATE_DIR/origins" ]'

# legacy: путь в манифесте без записи в реестре (установка до v1.1.1) — прежняя логика
LEG="$OUT/etc/legacy.conf"; echo LEGACY-BACKUP > "$LEG.pre-node-20240101-000000"; echo CUR > "$LEG"
echo "$LEG" > "$NODE_STATE_DIR/applied-files.txt"
echo x | node_persist_stream "$LEG" >/dev/null
t "legacy-путь не попадает в реестр (происхождение неизвестно)" '! grep -q "^$LEG	" "$NODE_STATE_DIR/file-origins.tsv" 2>/dev/null'

# ---------- B. runtime sysctl ----------
if [ "$IN_NS" = "1" ]; then
    rm -f "$NODE_STATE_DIR"/*.txt "$NODE_STATE_DIR/applied-files.txt"
    sysctl -w net.core.somaxconn=4096 >/dev/null; orig=4096
    apply_sim() { node_detect; node_sysctl_plan_init; node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn 65535
                  node_sysctl_write; node_sysctl_apply; node_sysctl_owner_dump; }
    apply_sim >/dev/null 2>&1; sleep 1; apply_sim >/dev/null 2>&1
    t "B: apply применил 65535" '[ "$(sysctl -n net.core.somaxconn)" = 65535 ]'
    t "B: реестр хранит исходное 4096" 'grep -qx "net.core.somaxconn	4096" "$NODE_STATE_DIR/sysctl-orig.tsv"'
    node_rollback "" >/dev/null 2>&1
    t "B: rollback удалил 99-z0-node-base.conf" '[ ! -e "$NODE_SYSCTL_BASE" ]'
    t "B: runtime somaxconn возвращён к значению ДО node ($orig)" '[ "$(sysctl -n net.core.somaxconn)" = "$orig" ]'
    t "B: owner-keys очищен (следующий apply снова запишет исходные)" '[ ! -s "$NODE_STATE_DIR/owner-keys.txt" ]'
    # невалидное значение из конфига не должно ронять sysctl -p
    node_sysctl_plan_init
    node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn "abc" >/dev/null 2>&1
    t "валидация: мусорное значение не попало в план" '! grep -q abc "$NODE_PLAN_FILE"'
else
    echo "skip - B (runtime sysctl): нужен root + unshare -mn"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: reapply-rollback (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
