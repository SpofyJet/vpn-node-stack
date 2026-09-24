#!/bin/bash
# shieldnode — тест: rollback останавливает/отключает юниты ДО удаления их файлов.
# 2026-09-24 (v1.1.4): rollback сперва удалял unit-файлы по манифесту, потом звал
# `systemctl disable --now` — на отсутствующих файлах systemctl падает целиком:
# таймеры "Unit to trigger vanished" -> failed, .path оставался active (not-found),
# симлинки в *.wants — висячие (найдено на живой ноде).
# Под root тест уходит в `unshare -mn`: tmpfs поверх /etc/systemd/system, /etc/sysctl.d,
# /etc/nftables.d, /usr/local/sbin, /run — хост не затронут.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /etc/systemd/system /etc/sysctl.d /etc/nftables.d /etc/shieldnode /usr/local/sbin /run; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-rbunits
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log" DRY_RUN=0
export SHIELD_CONFIG="$OUT/config.conf" SHIELD_EXCLUDE="$OUT/none"
: > "$SHIELD_CONFIG"; : > "$SHIELD_LOG"

# systemctl-заглушка с семантикой настоящего: disable/enable на отсутствующем
# unit-файле -> "does not exist", rc=1, и ничего не останавливается
cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$OUT/systemctl.log"
case "\$1" in
  disable|enable)
    for u in "\${@:2}"; do
      case "\$u" in --*) continue ;; esac
      if [ ! -e "/etc/systemd/system/\$u" ]; then
        echo "Failed to \$1 unit: Unit file \$u does not exist." >&2
        echo "MISSING \$u" >> "$OUT/systemctl.log"; exit 1
      fi
    done ;;
esac
exit 0
EOF
for c in logger nft sysctl; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

# состояние «после apply»: unit-файлы созданы shieldnode (манифест + реестр created)
UNITS="shieldnode.service shieldnode-cleanup.service shieldnode-cleanup.timer shieldnode-blocklist.service
shieldnode-blocklist.timer shieldnode-blocklist-custom.service shieldnode-blocklist-custom.path"
: > "$SHIELD_STATE_DIR/applied-files.txt"; : > "$SHIELD_STATE_DIR/file-origins.tsv"
for u in $UNITS; do
    echo "[Unit]" > "/etc/systemd/system/$u"
    echo "/etc/systemd/system/$u" >> "$SHIELD_STATE_DIR/applied-files.txt"
    printf '%s\tcreated\n' "/etc/systemd/system/$u" >> "$SHIELD_STATE_DIR/file-origins.tsv"
done

source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
source "$SHIELD_DIR/rollback.sh"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

: > "$OUT/systemctl.log"
shield_rollback "" >/dev/null 2>&1 || true
t "rollback: disable --now таймеров вызван" "grep -q 'disable --now shieldnode-cleanup.timer' $OUT/systemctl.log && grep -q 'disable --now shieldnode-blocklist.timer' $OUT/systemctl.log"
t "rollback: disable шёл по СУЩЕСТВУЮЩИМ unit-файлам (не 'does not exist')" "! grep -q '^MISSING' $OUT/systemctl.log"
t "rollback: shieldnode.service остановлен (--now; ExecStop нет — только состояние)" "grep -q 'disable --now shieldnode.service' $OUT/systemctl.log"
t "rollback: unit-файлы в итоге удалены" "for u in $(echo $UNITS); do [ ! -e /etc/systemd/system/\$u ] || exit 1; done"
t "rollback: daemon-reload после удаления" "tail -1 $OUT/systemctl.log | grep -qx daemon-reload"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rollback-units (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
