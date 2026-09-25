#!/bin/bash
# shieldnode — тест: blocklist-updater против НАСТОЯЩЕГО nft (ядро, пустой netns).
# 2026-09-23 (v1.1.4): backlog #1 — `nft rename set` не существует (nft 1.0.9:
# "syntax error, unexpected set, expecting chain"). Старый updater каждый тик
# заливал полный <set>__next, падал на nft -c и уходил в flush+refill: двойная
# загрузка + warn в каждом тике. flush+add одним `nft -f` — уже одна транзакция.
# Под root тест уходит в `unshare -mn`: свой netns (живой firewall не тронут) и
# tmpfs поверх /etc/shieldnode, /usr/local/sbin, /var/lib/shieldnode, /var/log, /run.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /etc/shieldnode /etc/systemd/system /etc/tmpfiles.d /usr/local/sbin /var/lib/shieldnode /var/log /run; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done
nft -c -f - <<<'add table inet t' 2>/dev/null || { echo "SKIP: nft в netns не работает"; exit 77; }

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-realnft
rm -rf "$OUT"; mkdir -p "$OUT/bin"
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG=/var/log/shieldnode.log
export SHIELD_LOCK=/run/shieldnode/shieldnode.lock SHIELD_CONFIG="$OUT/config.conf" SHIELD_EXCLUDE="$OUT/none"
: > "$SHIELD_CONFIG"; : > /var/log/shieldnode.log; unset SSH_CONNECTION

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# systemctl/logger — заглушки (unit'ы не нужны, журнал хоста не засоряем);
# nft — прозрачная обёртка: протокол вызовов + копия каждого загруженного batch
REAL_NFT="$(command -v nft)"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/systemctl"; cp "$OUT/bin/systemctl" "$OUT/bin/logger"
cat > "$OUT/bin/nft" <<EOF
#!/bin/bash
echo "\$*" >> "$OUT/nft.calls"
prev=""; for a in "\$@"; do [ "\$prev" = "-f" ] && cp "\$a" "$OUT/batch.\$(date +%s%N)" 2>/dev/null; prev="\$a"; done
[ -n "\${NFT_INJECT_FAIL:-}" ] && case " \$* " in *" -f "*) echo "Error: \$NFT_INJECT_FAIL" >&2; exit 1 ;; esac
exec "$REAL_NFT" "\$@"
EOF
chmod +x "$OUT/bin/"*
export PATH="$OUT/bin:$PATH"
# v1.2.0: IPv6-состояние хоста — фикстура (свежий netns теста имеет IPv6 включённым)
mkdir -p "$OUT/proc"; echo "BOOT_IMAGE=/vmlinuz ro ipv6.disable=1" > "$OUT/proc/cmdline"; export SHIELD_PROC="$OUT/proc"

# --- настоящая таблица: ruleset из генератора (dry-run печатает, ничего не пишет) ---
bash "$SHIELD_DIR/main.sh" --dry-run apply > "$OUT/dry.out" 2>/dev/null
awk '/^table inet shieldnode$/{on=1} on && !/^20[0-9][0-9]-[0-9-]+T[0-9:]+Z \[/' "$OUT/dry.out" > "$OUT/ruleset.nft"
t "ruleset: сгенерирован и загружен настоящим nft" "nft -f '$OUT/ruleset.nft'"

# 2026-09-23 (v1.1.4): status/health парсил `nft -n list chain` — с nft 1.0.9 -n печатает
# и ct state числами (0x2,0x4 / 0x8), символьные шаблоны не совпадали: ложные FAIL
# «established ... отсутствует» и «SSH N: защитных правил нет» на живой ноде
bash "$SHIELD_DIR/main.sh" status > "$OUT/status.out" 2>&1 || true
t "status: established/related — PASS на настоящем nft" "grep -q 'PASS.*established/related accept — до первого drop' $OUT/status.out"
t "status: SSH rate/conn-limit — PASS на настоящем nft" "grep -q 'PASS.*SSH [0-9]*: rate/conn-limit активны' $OUT/status.out"
t "status: health без FAIL на свежем ruleset" "grep -q 'health: FAIL=0' $OUT/status.out"
# 2026-09-23 (v1.1.4): `nft list chains inet shieldnode` — синтаксическая ошибка (list chains
# принимает только family); под set -e/pipefail status молча умирал после секции firewall
t "status: доходит до конца (секция persist / ownership)" "grep -q -- '--- persist / ownership ---' $OUT/status.out"
t "status: в секции firewall перечислены цепочки prerouting и input" "grep -q '^  chain prerouting' $OUT/status.out && grep -q '^  chain input' $OUT/status.out"

# 2026-09-24 (v1.1.4): первый guard (снапшота нет, prev_ts=0) печатал «дельта за
# <секунды с 1970>s» — на живой ноде «дельта за 1790200980s»
NO_COLOR=1 bash "$SHIELD_DIR/main.sh" guard > "$OUT/guard1.out" 2>&1 || true
# 2026-09-25 (v1.1.7): новый дашборд — первый запуск без «+N — за …», итог и группы есть
t "guard: первый запуск — итог без «+N — за …» (снапшота ещё нет)" \
  "grep -qE '(Итого|пока ничего — атак не было)' $OUT/guard1.out && ! grep -q '+N — за' $OUT/guard1.out && grep -q '● работает' $OUT/guard1.out"

# --- updater: эмитим через shield_blocklist_install в tmpfs-пути ---
(
    source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
    source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"; source "$SHIELD_DIR/lib/blocklist.sh"
    shield_persist_stream() { mkdir -p "$(dirname "$1")"; cat > "$1"; chmod "${2:-0644}" "$1"; }
    shield_manifest_record() { :; }
    export SH_F_ENABLE_SCANNER_LIST=1 SH_F_ENABLE_THREAT_LIST=1 SH_F_BLOCK_TOR=0 SH_F_ENABLE_CUSTOM_LIST=1
    shield_blocklist_install
) >/dev/null 2>&1
UPD=/usr/local/sbin/shieldnode-blocklist
t "updater: эмитирован" "test -x $UPD"
# только локальный threat-список, без сети
cat > /etc/shieldnode/blocklist.conf <<'EOF'
BL_URLS_threat=""
EOF
# 3000 непересекающихся /32 (без агрегации), вне bogon-диапазонов
awk 'BEGIN{for(i=0;i<3000;i++) printf "45.%d.%d.%d\n", int(i/250)+10, i%250, 7}' > /etc/shieldnode/lists/threat.txt

: > "$OUT/nft.calls"; rm -f "$OUT"/batch.*
rc=0; bash "$UPD" threat || rc=$?
t "tick1: updater rc=0" "[ $rc = 0 ]"
t "tick1: live-сет содержит 3000 записей" "[ \$(nft list set inet shieldnode threat_blocklist_v4 | tr ',' '\n' | grep -c '45\.') = 3000 ]"
t "tick1: нет warn 'atomic swap недоступен' (нет мёртвого rename-пути)" "! grep -q 'atomic swap' /var/log/shieldnode.log"
t "tick1: ни одного 'rename set' в загруженных batch'ах" "! grep -l 'rename set' $OUT/batch.* "
t "tick1: tmp-сет __next не создавался" "! grep -q '__next' $OUT/nft.calls $OUT/batch.*"
t "tick1: ровно одна мутирующая загрузка (nft -f без -c)" "[ \$(grep -c '^-f ' $OUT/nft.calls) = 1 ]"
t "tick1: flush и все элементы — в ОДНОМ batch (одна транзакция)" \
  "f=\$(ls $OUT/batch.* | tail -1); head -1 \$f | grep -qx 'flush set inet shieldnode threat_blocklist_v4' && [ \$(grep -oE '[{ ]45\.' \$f | wc -l) = 3000 ]"

# tick2: список изменился — ушедшие записи должны исчезнуть (flush сработал)
awk 'BEGIN{for(i=1000;i<3500;i++) printf "45.%d.%d.%d\n", int(i/250)+10, i%250, 7}' > /etc/shieldnode/lists/threat.txt
: > "$OUT/nft.calls"; rm -f "$OUT"/batch.*
rc=0; bash "$UPD" threat || rc=$?
t "tick2: updater rc=0" "[ $rc = 0 ]"
t "tick2: сет = новый список (2500), старые записи удалены" \
  "l=\$(nft list set inet shieldnode threat_blocklist_v4); [ \$(printf '%s' \"\$l\" | tr ',' '\n' | grep -c '45\.') = 2500 ] && ! printf '%s' \"\$l\" | grep -q '45\.10\.0\.7[^0-9]'"
t "tick2: drop-правило на месте ровно одно, с counter" \
  "[ \$(nft list chain inet shieldnode prerouting | grep -c 'ip saddr @threat_blocklist_v4 counter name \"c_drops_threat_v4\" drop') = 1 ]"

# 2026-09-24 (v1.1.4): пустой список (custom.txt из шаблона, MIN_ENTRIES_CUSTOM=0) давал
# batch «flush set …» + висячую « }» — синтакс-ошибка nft, shieldnode-blocklist.service
# падал на КАЖДОМ тике свежей ноды. Пустой список = пустой сет (оператор снял баны).
printf '45.200.0.7\n45.200.0.8\n' > /etc/shieldnode/lists/custom.txt
bash "$UPD" custom >/dev/null 2>&1 || true
printf '# шаблон: ни одной записи\n' > /etc/shieldnode/lists/custom.txt
rc=0; bash "$UPD" custom || rc=$?
t "custom: пустой список — updater rc=0" "[ $rc = 0 ]"
t "custom: пустой список — сет очищен (прежние баны сняты)" "! nft list set inet shieldnode custom_blocklist_v4 | grep -q '45\.200\.'"
# 2026-09-24 (v1.1.4): причина отказа nft должна попадать в лог (после удаления
# rename-пути legacy.err не логировался — только «nft swap v4 failed»)
printf '45.201.0.7\n' > /etc/shieldnode/lists/custom.txt
NFT_INJECT_FAIL="injected-reason-4242" bash "$UPD" custom >/dev/null 2>&1 || true
t "ошибка nft: текст причины в логе" "grep 'custom: nft swap v4 failed' /var/log/shieldnode.log | grep -q 'injected-reason-4242'"
# 2026-09-23 (v1.1.4): `exec 8>"$MAIN_LOCK_FILE" 2>/dev/null` навсегда перенаправлял
# stderr updater'а в /dev/null — все ошибки после lock'а пропадали из журнала юнита
bash -x "$UPD" threat > /dev/null 2> "$OUT/xtrace.err" || true
t "stderr: после main lock stderr updater'а не теряется (xtrace доходит до update_list)" \
  "grep -q 'update_list threat' $OUT/xtrace.err"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: realnft (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
