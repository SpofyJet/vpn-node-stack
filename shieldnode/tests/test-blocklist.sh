#!/bin/bash
# shieldnode — тест: агрегаторские блоклисты (lib/blocklist.sh) без root.
# Эмитим updater через shield_blocklist_install (persist/systemctl подменены),
# затем гоняем updater против fake-nft (база set'ов в /tmp) с file:// фидами.
# Запуск: bash tests/test-blocklist.sh
set -euo pipefail

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHIELD_DIR SHIELD_VERSION=1.0.0
OUT=/tmp/shieldnode-bl-test
export SHIELD_STATE_DIR="$OUT/state"
export SHIELD_LOG="$OUT/shieldnode.log"
export SHIELD_LOCK="$OUT/lock"
export NODE_PROFILE_DIR="$OUT/profile.d"
LOG_LEVEL=info

rm -rf "$OUT"
mkdir -p "$OUT/state" "$OUT/profile.d" "$OUT/bin" "$OUT/fixtures" "$OUT/nftdb"

source "$SHIELD_DIR/lib/common.sh"
source "$SHIELD_DIR/config.sh"
shield_load_config
# crowdsec-режимы (resolve_mode) — без реального демона
source "$SHIELD_DIR/detect.sh"
source "$SHIELD_DIR/lib/crowdsec.sh"

# --- подмены persist/systemctl (цели за пределами /tmp) ---
SYSTEMCTL_LOG="$OUT/systemctl.log"
: > "$SYSTEMCTL_LOG"
shield_persist_stream() { local dst="$1" mode="${2:-0644}"
    mkdir -p "$OUT$(dirname "$dst")"; cat > "$OUT$dst"; chmod "$mode" "$OUT$dst" 2>/dev/null || true; }
shield_manifest_record() { :; }
cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$OUT/bin/systemctl"
export PATH="$OUT/bin:$PATH"

# --- fake nft v2: table/sets/rules; batch = любые mutating-операции ---
# rules DB: файл rules, строки "HANDLE<TAB>rule-text". Поддержка swap-пути:
# add set / delete set / rename set / delete rule handle / insert position /
# add rule / flush set / add element. FAKE_NFT_NO_SWAP=1 — эмуляция старого nft.
cat > "$OUT/bin/nft" <<'EOF'
#!/bin/bash
NFT_DB="${FAKE_NFT_DB:?}"
OPS="${FAKE_NFT_OPS:-/dev/null}"
check=0; batch=""; args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -a) shift ;;  # list -a: handles и так в выводе
        -c) check=1; shift ;;
        -f) batch="$2"; shift ;;
        list|table|set|chain) args+=("$1"); shift ;;
        *) args+=("$1"); shift ;;
    esac
done
# --- list ---
if [ "${args[0]:-}" = "list" ]; then
    case "${args[1]:-}" in
        table) [ -f "$NFT_DB/table" ] || exit 1; exit 0 ;;
        set)   name="${args[-1]}"; [ -f "$NFT_DB/set_$name" ] || exit 1; exit 0 ;;
        chain) [ -f "$NFT_DB/rules" ] || exit 1
               while IFS=$'\t' read -r h r; do printf '        %s # handle %s\n' "$r" "$h"; done < "$NFT_DB/rules"
               exit 0 ;;
    esac
    exit 1
fi
[ -n "$batch" ] || exit 1
# эмуляция старого nft: rename set не поддерживается
if [ "${FAKE_NFT_NO_SWAP:-0}" = "1" ] && [ "$check" = "1" ] && grep -q "rename set" "$batch"; then
    exit 1
fi
[ "$check" = "1" ] && exit 0
next_handle() { local m=0 h; while IFS=$'\t' read -r h _; do [ "$h" -gt "$m" ] && m="$h"; done < "$NFT_DB/rules"; echo $((m+10)); }
while IFS= read -r line; do
    case "$line" in
        "flush set inet shieldnode "*)
            name="${line##* }"; : > "$NFT_DB/set_$name"; echo "flush set $name" >> "$OPS" ;;
        "add element inet shieldnode "*)
            rest="${line#add element inet shieldnode }"
            name="${rest%% *}"
            inner="${rest#* \{ }"; inner="${inner% \}}"
            oldifs="$IFS"; IFS=','
            for e in $inner; do echo "$e" | sed 's/^ //;s/ $//' >> "$NFT_DB/set_$name"; done
            IFS="$oldifs" ;;
        "add set inet shieldnode "*)
            name="$(printf '%s' "$line" | sed -E 's/add set inet shieldnode ([^ ]+) \{.*/\1/')"
            : > "$NFT_DB/set_$name"; echo "add set $name" >> "$OPS" ;;
        "delete set inet shieldnode "*)
            name="${line##* }"; rm -f "$NFT_DB/set_$name"; echo "delete set $name" >> "$OPS" ;;
        "rename set inet shieldnode "*)
            a="$(printf '%s' "$line" | awk '{print $5}')"; b="$(printf '%s' "$line" | awk '{print $6}')"
            mv "$NFT_DB/set_$a" "$NFT_DB/set_$b"; echo "rename set $a $b" >> "$OPS" ;;
        "delete rule inet shieldnode prerouting handle "*)
            h="${line##* handle }"; grep -v "^$h" "$NFT_DB/rules" > "$NFT_DB/rules.tmp" || true
            mv "$NFT_DB/rules.tmp" "$NFT_DB/rules"; echo "delete rule $h" >> "$OPS" ;;
        "insert rule inet shieldnode prerouting position "*)
            pos="$(printf '%s' "$line" | awk '{print $7}')"
            rule="$(printf '%s' "$line" | sed -E 's/insert rule inet shieldnode prerouting position [0-9]+ //')"
            nh="$(next_handle)"
            awk -F'\t' -v pos="$pos" -v nh="$nh" -v rule="$rule" 'BEGIN{OFS="\t"} {if ($1==pos) print nh, rule; print}' "$NFT_DB/rules" > "$NFT_DB/rules.tmp"
            mv "$NFT_DB/rules.tmp" "$NFT_DB/rules"; echo "insert rule pos=$pos" >> "$OPS" ;;
        "add rule inet shieldnode prerouting "*)
            rule="${line#add rule inet shieldnode prerouting }"
            nh="$(next_handle)"; printf '%s\t%s\n' "$nh" "$rule" >> "$NFT_DB/rules"; echo "add rule (append)" >> "$OPS" ;;
    esac
done < "$batch"
exit 0
EOF
chmod +x "$OUT/bin/nft"
touch "$OUT/nftdb/table"
for s in scanner_blocklist_v4 scanner_blocklist_v6 threat_blocklist_v4 threat_blocklist_v6 \
         tor_exit_blocklist_v4 tor_exit_blocklist_v6 custom_blocklist_v4 custom_blocklist_v6 \
         spamhaus_blocklist_v4 spamhaus_blocklist_v6 cins_blocklist_v4; do
    : > "$OUT/nftdb/set_$s"
done
# rules DB: drop-правила нового шаблона (с counter name) + два хвостовых правила
cat > "$OUT/nftdb/rules" <<'RULES_EOF'
10	ip saddr @scanner_blocklist_v4 counter name c_drops_scanner_v4 drop
20	ip6 saddr @scanner_blocklist_v6 counter name c_drops_scanner_v6 drop
30	ip saddr @threat_blocklist_v4 counter name c_drops_threat_v4 drop
40	ip6 saddr @threat_blocklist_v6 counter name c_drops_threat_v6 drop
50	ip saddr @tor_exit_blocklist_v4 counter name c_drops_tor_v4 drop
60	ip6 saddr @tor_exit_blocklist_v6 counter name c_drops_tor_v6 drop
70	ip saddr @custom_blocklist_v4 counter name c_drops_custom_v4 drop
80	ip6 saddr @custom_blocklist_v6 counter name c_drops_custom_v6 drop
85	ip saddr @spamhaus_blocklist_v4 counter name c_drops_spamhaus_v4 drop
86	ip6 saddr @spamhaus_blocklist_v6 counter name c_drops_spamhaus_v6 drop
87	ip saddr @cins_blocklist_v4 counter name c_drops_cins_v4 drop
90	ip saddr @ssh_abusers counter name c_drops_ssh_abusers_v4 drop
100	tcp dport 22 ct state new meter ssh_new_22 { ip saddr limit rate over 5/minute burst 2 packets } add @ssh_abusers { ip saddr timeout 1800s } counter name c_drops_ssh_abusers_v4 drop
RULES_EOF
: > "$OUT/nftdb/ops.log"; export FAKE_NFT_OPS="$OUT/nftdb/ops.log"

# --- пути lib/blocklist.sh под sandbox (script — production-путь: stub мапит в $OUT) ---
source "$SHIELD_DIR/lib/blocklist.sh"
SHIELD_BLOCKLIST_STATE="$OUT/var/lib/shieldnode/blocklists"
SHIELD_LISTS_DIR="$OUT/etc/shieldnode/lists"
SHIELD_BLOCKLIST_OVERRIDE="$OUT/etc/shieldnode/blocklist.conf"

# --- конфиг-окружение install'а ---
export SH_F_ENABLE_SCANNER_LIST=1 SH_F_ENABLE_THREAT_LIST=1 SH_F_BLOCK_TOR=0 SH_F_ENABLE_CUSTOM_LIST=1
export DRY_RUN=0
mkdir -p "$(dirname "$SHIELD_CONFIG")" 2>/dev/null || true
# центральный custom-URL (аналог старого репо) — должен запечься в updater.
# Пишем в CONFIG_CACHE (user-часть мержа), т.к. /etc в sandbox не для записи.
printf 'BLOCKLIST_CUSTOM_URLS="file://%s/fixtures/custom-central.txt"\n' "$OUT" >> "$CONFIG_CACHE"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ================= 1) install =================
shield_blocklist_install

SHIELD_BLOCKLIST_SCRIPT="$OUT/usr/local/sbin/shieldnode-blocklist"   # где оказался файл после stub-маппинга
t "install: updater эмитирован" test -x "$SHIELD_BLOCKLIST_SCRIPT"
t "install: updater синтаксически валиден" bash -n "$SHIELD_BLOCKLIST_SCRIPT"
t "install: service ссылается на production-путь updater'а" grep -q "ExecStart=/usr/local/sbin/shieldnode-blocklist" "$OUT/etc/systemd/system/shieldnode-blocklist.service"
t "install: timer интервал из конфига" grep -q "OnUnitActiveSec=360min" "$OUT/etc/systemd/system/shieldnode-blocklist.timer"
t "install: timer enable через systemctl" grep -q "enable --now shieldnode-blocklist.timer" "$SYSTEMCTL_LOG"
t "install: custom.txt засеян" test -f "$SHIELD_LISTS_DIR/custom.txt"
t "install: hardening юнита (NoNewPrivileges/ProtectSystem/Timeout)" bash -c "grep -q 'NoNewPrivileges=true' '$OUT/etc/systemd/system/shieldnode-blocklist.service' && grep -q 'ProtectSystem=strict' '$OUT/etc/systemd/system/shieldnode-blocklist.service' && grep -q 'TimeoutStartSec=600' '$OUT/etc/systemd/system/shieldnode-blocklist.service'"
t "install: custom path-триггер (PathChanged, без PathExists)" bash -c "grep -q 'PathChanged=.*custom.txt' '$OUT/etc/systemd/system/shieldnode-blocklist-custom.path' && ! grep -q 'PathExists' '$OUT/etc/systemd/system/shieldnode-blocklist-custom.path'"
t "install: custom.service зовёт updater с аргументом custom" grep -q "ExecStart=/usr/local/sbin/shieldnode-blocklist custom" "$OUT/etc/systemd/system/shieldnode-blocklist-custom.service"
t "install: scanner URLs запечены (13 источников)" bash -c "grep -q '^BL_URLS_scanner=.*antiscanner.list' '$OUT/usr/local/sbin/shieldnode-blocklist' && test \$(grep '^BL_URLS_scanner=' '$OUT/usr/local/sbin/shieldnode-blocklist' | grep -o 'https://' | wc -l) = \$(grep '^BLOCKLIST_SCANNER_URLS=' '$SHIELD_DIR/shieldnode.defaults.conf' | grep -o 'https://' | wc -l)"
t "install: threat URLs: spamhaus DROP v4/v6 + firehol" bash -c "grep -q '^BL_URLS_threat=.*drop_v4.json' '$OUT/usr/local/sbin/shieldnode-blocklist' && grep -q 'firehol_level1.netset' '$OUT/usr/local/sbin/shieldnode-blocklist'"
t "install: tor выключен по умолчанию (BL_ENABLED_tor=0)" grep -q '^BL_ENABLED_tor="0"' "$SHIELD_BLOCKLIST_SCRIPT"
t "install: BLOCKLIST_CUSTOM_URLS запечён в updater" grep -q '^BL_URLS_custom="file://.*/fixtures/custom-central.txt"' "$SHIELD_BLOCKLIST_SCRIPT"

# ================= 2) custom: apply =================
cat > "$SHIELD_LISTS_DIR/custom.txt" <<'EOF'
# операторский список
91.240.118.0/24
185.220.101.4
8.8.8.8
10.1.2.3          # RFC1918 — bogon-фильтр должен отрезать
EOF
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=0
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_MIN_custom=2
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "custom: применились 3 записи (bogon отрезан)" bash -c "test \$(wc -l < '$OUT/nftdb/set_custom_blocklist_v4') = 3"
t "custom: plain IP → /32, CIDR сохранён" bash -c "grep -qx '8.8.8.8/32' '$OUT/nftdb/set_custom_blocklist_v4' && grep -qx '91.240.118.0/24' '$OUT/nftdb/set_custom_blocklist_v4' && grep -qx '185.220.101.4/32' '$OUT/nftdb/set_custom_blocklist_v4'"
t "custom: last-good снапшот сохранён" test -f "$SHIELD_BLOCKLIST_STATE/last-good-custom.txt"
t "custom: hash-guard marker записан" test -f "$SHIELD_BLOCKLIST_STATE/.applied-custom.sha256"
t "custom: 10.1.2.3 не прошёл bogon-фильтр" bash -c "! grep -q '10\.1\.2\.3' '$OUT/nftdb/set_custom_blocklist_v4'"

# ================= 3) custom: hash-guard no-op =================
before="$(sha256sum "$OUT/nftdb/set_custom_blocklist_v4")"
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
after="$(sha256sum "$OUT/nftdb/set_custom_blocklist_v4")"
t "custom: повторный запуск — no-op (hash-guard)" test "$before" = "$after"

# ================= 4) custom: min-check держит last-known-good =================
cat > "$SHIELD_LISTS_DIR/custom.txt" <<EOF
192.0.2.1
EOF
sed -i 's/BL_MIN_custom=2/BL_MIN_custom=5/' "$SHIELD_BLOCKLIST_OVERRIDE"
if PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"; then
    echo "FAIL - min-check: updater вернул 0 при недоборе"; fails=$((fails+1))
else
    echo "ok   - min-check: updater вернул non-zero"
fi
t "min-check: старый set сохранён (3 записи)" bash -c "test \$(wc -l < '$OUT/nftdb/set_custom_blocklist_v4') = 3"
t "min-check: fail counter инкрементирован" bash -c "test \$(cat '$SHIELD_BLOCKLIST_STATE/fails-custom.cnt') = 1"

# ================= 5) scanner: file:// фид + spamhaus-формат + JSON =================
cat > "$OUT/fixtures/scanner.txt" <<'EOF'
# multi-format scanner feed
185.220.101.4
91.240.118.0/24 ; SBL12345
45.148.10.8 # inline comment
EOF
cat > "$OUT/fixtures/drop.json" <<'EOF'
[{"cidr":"6.6.6.0/24","sbl":"SBL99999"},{"cidr":"45.155.205.0/24","sbl":"SBL88888"}]
EOF
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=1
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_ENABLED_custom=0
BL_URLS_scanner="file://$OUT/fixtures/scanner.txt file://$OUT/fixtures/drop.json file:///nonexistent-404"
BL_MIN_scanner=3
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "scanner: применены v4-записи из plain+JSON фидов" bash -c "grep -qx '185.220.101.4/32' '$OUT/nftdb/set_scanner_blocklist_v4' && grep -qx '6.6.6.0/24' '$OUT/nftdb/set_scanner_blocklist_v4'"
t "scanner: spamhaus '; SBL' парсится как CIDR" grep -qx "91.240.118.0/24" "$OUT/nftdb/set_scanner_blocklist_v4"
t "scanner: fail counter сброшен на успехе" bash -c "test \$(cat '$SHIELD_BLOCKLIST_STATE/fails-scanner.cnt' 2>/dev/null || echo x) = 0"

# ================= 6) scanner: все источники мертвы → keep old + alert на пороге =================
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=1
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_ENABLED_custom=0
BL_URLS_scanner="file:///nonexistent-404"
BL_MIN_scanner=3
EOF
for i in 1 2 3; do
    PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" >/dev/null 2>&1 || true
done
t "stale: counter дошёл до threshold" bash -c "test \$(cat '$SHIELD_BLOCKLIST_STATE/fails-scanner.cnt') = 3"
t "stale: алерт-маркер создан" test -f "$SHIELD_BLOCKLIST_STATE/.alert-scanner"
t "stale: set сохранён (last-known-good)" bash -c "grep -qx '6.6.6.0/24' '$OUT/nftdb/set_scanner_blocklist_v4'"

# ================= 6.5) аргументы = подмножество списков =================
: > "$OUT/nftdb/set_scanner_blocklist_v4"
: > "$OUT/nftdb/set_custom_blocklist_v4"
rm -f "$SHIELD_BLOCKLIST_STATE/.applied-custom.sha256"   # иначе hash-guard = no-op
cat > "$SHIELD_LISTS_DIR/custom.txt" <<EOF
91.240.118.0/24
185.220.101.4
8.8.8.8
EOF
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=1
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_ENABLED_custom=1
BL_URLS_scanner="file://$OUT/fixtures/scanner.txt"
BL_MIN_scanner=3
BL_MIN_custom=2
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" custom
t "args: custom применён" bash -c "test \$(wc -l < '$OUT/nftdb/set_custom_blocklist_v4') = 3"
t "args: scanner НЕ тронут при вызове с 'custom'" bash -c "test ! -s '$OUT/nftdb/set_scanner_blocklist_v4'"
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "args: полный прогон применяет scanner" bash -c "test -s '$OUT/nftdb/set_scanner_blocklist_v4'"

# ================= 7) firewall отсутствует → тихий exit 0 =================
rm -f "$OUT/nftdb/table"
t "no-table: exit 0 без таблицы" bash -c "PATH='$OUT/bin:$PATH' FAKE_NFT_DB='$OUT/nftdb' bash '$SHIELD_BLOCKLIST_SCRIPT'"
touch "$OUT/nftdb/table"

# ================= 8) v6: изолированная v6-транзакция =================
cat > "$OUT/fixtures/scanner6.txt" <<EOF
185.220.102.9
2a06:98c0:dead::/48
2606:4700::/32
fe80::1          # link-local — bogon
EOF
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=1
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_ENABLED_custom=0
BL_URLS_scanner="file://$OUT/fixtures/scanner6.txt"
BL_MIN_scanner=1
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "v6: v6-элементы применены отдельной транзакцией" bash -c "grep -qx '2a06:98c0:dead::/48' '$OUT/nftdb/set_scanner_blocklist_v6' && grep -qx '2606:4700::/32' '$OUT/nftdb/set_scanner_blocklist_v6'"
t "v6: link-local отрезан" bash -c "! grep -q 'fe80' '$OUT/nftdb/set_scanner_blocklist_v6'"

echo
# ================= 8) atomic swap: rename-путь, позиция, fallback =================
# чистое состояние: set'ы пустые, rules DB — новый шаблон, ops-log чистый
for s in scanner_blocklist_v4 scanner_blocklist_v6 threat_blocklist_v4 threat_blocklist_v6 \
         tor_exit_blocklist_v4 tor_exit_blocklist_v6 custom_blocklist_v4 custom_blocklist_v6 \
         spamhaus_blocklist_v4 spamhaus_blocklist_v6 cins_blocklist_v4; do
    : > "$OUT/nftdb/set_$s"
done
cat > "$OUT/nftdb/rules" <<'RULES_EOF'
10	ip saddr @scanner_blocklist_v4 counter name c_drops_scanner_v4 drop
20	ip6 saddr @scanner_blocklist_v6 counter name c_drops_scanner_v6 drop
30	ip saddr @threat_blocklist_v4 counter name c_drops_threat_v4 drop
40	ip6 saddr @threat_blocklist_v6 counter name c_drops_threat_v6 drop
50	ip saddr @tor_exit_blocklist_v4 counter name c_drops_tor_v4 drop
60	ip6 saddr @tor_exit_blocklist_v6 counter name c_drops_tor_v6 drop
70	ip saddr @custom_blocklist_v4 counter name c_drops_custom_v4 drop
80	ip6 saddr @custom_blocklist_v6 counter name c_drops_custom_v6 drop
85	ip saddr @spamhaus_blocklist_v4 counter name c_drops_spamhaus_v4 drop
86	ip6 saddr @spamhaus_blocklist_v6 counter name c_drops_spamhaus_v6 drop
87	ip saddr @cins_blocklist_v4 counter name c_drops_cins_v4 drop
90	ip saddr @ssh_abusers counter name c_drops_ssh_abusers_v4 drop
100	tcp dport 22 ct state new meter ssh_new_22 { ip saddr limit rate over 5/minute burst 2 packets } add @ssh_abusers { ip saddr timeout 1800s } counter name c_drops_ssh_abusers_v4 drop
RULES_EOF
: > "$OUT/nftdb/ops.log"
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=1
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_URLS_scanner="file://$OUT/fixtures/scanner.txt file://$OUT/fixtures/drop.json"
BL_MIN_scanner=2
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "swap: rename-путь (без flush live-сета)" bash -c "grep -q 'rename set scanner_blocklist_v4__next scanner_blocklist_v4' '$OUT/nftdb/ops.log' && ! grep -q 'flush set scanner_blocklist_v4' '$OUT/nftdb/ops.log'"
t "swap: tmp-сет подчищен" bash -c "test ! -e '$OUT/nftdb/set_scanner_blocklist_v4__next'"
t "swap: live-сет содержит 5 агрегированных записей" bash -c "test \$(wc -l < '$OUT/nftdb/set_scanner_blocklist_v4') = 5"
t "swap: drop-правило пересоздано ОДИН раз, с counter, на прежней позиции" \
  bash -c "test \$(grep -c 'scanner_blocklist_v4' '$OUT/nftdb/rules') = 1 && grep -q 'counter name c_drops_scanner_v4 drop' '$OUT/nftdb/rules' && awk '/scanner_blocklist_v4/{a=NR} /threat_blocklist_v4/{b=NR} END{exit !(a<b)}' '$OUT/nftdb/rules'"

# fallback: эмуляция старого nft (rename не поддерживается)
echo "103.177.80.0/24" >> "$OUT/fixtures/scanner.txt"
: > "$OUT/nftdb/ops.log"
FAKE_NFT_NO_SWAP=1 PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "swap-fallback: старый nft -> flush+refill" bash -c "grep -q 'flush set scanner_blocklist_v4' '$OUT/nftdb/ops.log'"
t "swap-fallback: новая запись всё равно применена" bash -c "grep -qx '103.177.80.0/24' '$OUT/nftdb/set_scanner_blocklist_v4'"

# mixed-version: правило без counter (таблица от старого apply) -> fallback без падения
: > "$OUT/nftdb/set_scanner_blocklist_v4"
sed -i 's|ip saddr @scanner_blocklist_v4 counter name c_drops_scanner_v4 drop|ip saddr @scanner_blocklist_v4 drop|' "$OUT/nftdb/rules"
: > "$OUT/nftdb/ops.log"
if FAKE_NFT_NO_SWAP=0 PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"; then
    echo "ok   - swap-mixed: updater завершился 0 (fallback)"
else
    echo "FAIL - swap-mixed: updater упал"; fails=$((fails+1))
fi
t "swap-mixed: legacy flush отработал" bash -c "grep -q 'flush set scanner_blocklist_v4' '$OUT/nftdb/ops.log' && test \$(wc -l < '$OUT/nftdb/set_scanner_blocklist_v4') = 6"

echo
# ================= 9) crowdsec community blocklist (feed без демона) =================
t "crowdsec: по умолчанию выключен (BL_ENABLED_crowdsec=0)" grep -q '^BL_ENABLED_crowdsec="0"' "$SHIELD_BLOCKLIST_SCRIPT"

# креды в конфиге → endpoint и Basic-Auth запекаются в updater
{ printf 'ENABLE_CROWDSEC_LIST=1\nCROWDSEC_INTEGRATION_ID=integration-4242\nCROWDSEC_USER=testuser\nCROWDSEC_PASSWORD=testpass\n'
  cat "$CONFIG_CACHE"; } > "$CONFIG_CACHE.new"
mv "$CONFIG_CACHE.new" "$CONFIG_CACHE"
# re-emit через production-путь (stub маппит его под $OUT — см. line 148)
SHIELD_BLOCKLIST_SCRIPT=/usr/local/sbin/shieldnode-blocklist
shield_blocklist_install
SHIELD_BLOCKLIST_SCRIPT="$OUT/usr/local/sbin/shieldnode-blocklist"
t "crowdsec: endpoint с ID запечён в updater" bash -c "grep -q '^BL_URLS_crowdsec=\"https://admin.api.crowdsec.net/v1/integrations/integration-4242/content\"' '$SHIELD_BLOCKLIST_SCRIPT'"
t "crowdsec: креды запечены отдельно от URL" bash -c "grep -q '^CROWDSEC_USER=\"testuser\"' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q '^CROWDSEC_PASSWORD=\"testpass\"' '$SHIELD_BLOCKLIST_SCRIPT'"
t "crowdsec: интервал 1440м (лимит community-тарифа) запечён" grep -q '^BL_INTERVAL_crowdsec="1440"' "$SHIELD_BLOCKLIST_SCRIPT"
t "crowdsec: updater валиден после перепечки" bash -n "$SHIELD_BLOCKLIST_SCRIPT"
t "crowdsec: fetch-ветка с Basic-Auth + --compressed присутствует" bash -c "grep -q 'admin.api.crowdsec.net/\*' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q -- '--compressed' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q -- '-u \"\$CROWDSEC_USER:\$CROWDSEC_PASSWORD\"' '$SHIELD_BLOCKLIST_SCRIPT'"
t "crowdsec: гард интервала + FORCE-обход присутствуют" bash -c "grep -q 'BL_INTERVAL_' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q 'lastok-' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q 'FORCE' '$SHIELD_BLOCKLIST_SCRIPT'"

# функционально: свежий lastok → пропуск; FORCE=1 → применение
# (185.220.101.9 — не-bogon; 203.0.113.x/198.51.100.x — TEST-NET, bogon-фильтр отсекает)
: > "$OUT/nftdb/set_crowdsec_blocklist_v4"
echo "185.220.101.9" > "$SHIELD_LISTS_DIR/crowdsec.txt"
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_crowdsec=1
BL_URLS_crowdsec=""
BL_MIN_crowdsec=0
BL_MAX_crowdsec=50000
BL_MINP4_crowdsec=32
BL_SIZE_crowdsec=262144
BL_INTERVAL_crowdsec=1440
EOF
rm -f "$SHIELD_BLOCKLIST_STATE/fails-crowdsec.cnt"
date +%s > "$SHIELD_BLOCKLIST_STATE/lastok-crowdsec.ts"
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" crowdsec
t "crowdsec: свежий lastok → fetch пропущен, set не тронут, fail-counter не бамплен" \
    bash -c "test ! -s '$OUT/nftdb/set_crowdsec_blocklist_v4' && test ! -f '$SHIELD_BLOCKLIST_STATE/fails-crowdsec.cnt'"
FORCE=1 PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" crowdsec
t "crowdsec: FORCE=1 обходит гард, локальный список применён" bash -c "grep -qx '185.220.101.9/32' '$OUT/nftdb/set_crowdsec_blocklist_v4'"
t "crowdsec: last-good снапшот сохранён" bash -c "grep -qx '185.220.101.9/32' '$SHIELD_BLOCKLIST_STATE/last-good-crowdsec.txt'"

# ================= 10) crowdsec agent-режим (CAPI без аккаунта) =================
# конфиг: креды убраны, режим agent — updater должен читать cscli decisions
{ printf 'ENABLE_CROWDSEC_LIST=1\nCROWDSEC_MODE=agent\n'
  grep -v '^CROWDSEC_INTEGRATION_ID\|^CROWDSEC_USER\|^CROWDSEC_PASSWORD' "$CONFIG_CACHE"; } > "$CONFIG_CACHE.new"
mv "$CONFIG_CACHE.new" "$CONFIG_CACHE"
SHIELD_BLOCKLIST_SCRIPT=/usr/local/sbin/shieldnode-blocklist
shield_blocklist_install
SHIELD_BLOCKLIST_SCRIPT="$OUT/usr/local/sbin/shieldnode-blocklist"
t "crowdsec-agent: local://cscli-decisions запечён (не admin.api)" bash -c "grep -q '^BL_URLS_crowdsec=\"local://cscli-decisions\"' '$SHIELD_BLOCKLIST_SCRIPT'"
t "crowdsec-agent: интервал 30м запечён (local-чтение, без 429)" grep -q '^BL_INTERVAL_crowdsec="30"' "$SHIELD_BLOCKLIST_SCRIPT"
t "crowdsec-agent: ветка local://cscli-decisions присутствует" bash -c "grep -q 'local://cscli-decisions)' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q 'cscli decisions list' '$SHIELD_BLOCKLIST_SCRIPT'"

# функционально: fake cscli отдаёт decisions JSON
cat > "$OUT/bin/cscli" <<'CSCLI_EOF'
#!/bin/bash
case "$*" in
    "decisions list -t ban -o json")
        echo '[{"value":"185.220.101.9","type":"ban","origin":"CAPI"},{"value":"91.240.118.0/24","type":"ban","origin":"CAPI"}]'
        exit 0 ;;
    *) exit 1 ;;
esac
CSCLI_EOF
chmod +x "$OUT/bin/cscli"
: > "$OUT/nftdb/set_crowdsec_blocklist_v4"
rm -f "$SHIELD_BLOCKLIST_STATE/lastok-crowdsec.ts"
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_crowdsec=1
BL_URLS_crowdsec="local://cscli-decisions"
BL_MIN_crowdsec=0
BL_INTERVAL_crowdsec=0
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" crowdsec
t "crowdsec-agent: decisions из cscli применены в set" bash -c "grep -qx '185.220.101.9/32' '$OUT/nftdb/set_crowdsec_blocklist_v4' && grep -qx '91.240.118.0/24' '$OUT/nftdb/set_crowdsec_blocklist_v4'"

# ================= 11) spamhaus/cins: дефолты + парсинг Sxx- формата =================
t "spamhaus/cins: URL запечены" bash -c "grep -q 'spamhaus.org/drop/drop.txt' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q 'cinsscore.com/list/ci-badguys.txt' '$SHIELD_BLOCKLIST_SCRIPT'"
t "spamhaus/cins: default enabled=1 запечён" bash -c "grep -q '^BL_ENABLED_spamhaus=\"1\"' '$SHIELD_BLOCKLIST_SCRIPT' && grep -q '^BL_ENABLED_cins=\"1\"' '$SHIELD_BLOCKLIST_SCRIPT'"
# парсинг S24-префикса функционально: fixture в формате spamhaus
cat > "$OUT/fixtures/spamhaus.txt" <<'EOF'
S24-91.240.118.0/24 ; Spamhaus DROP Entry
; this line is a comment
S16-45.155.0.0/16 ; EDROP
EOF
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=0
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_custom=0
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=1
BL_ENABLED_cins=0
BL_URLS_custom=""
BL_URLS_spamhaus="file://$OUT/fixtures/spamhaus.txt"
BL_MIN_spamhaus=1
BL_MINP4_spamhaus=8
BL_MAX_spamhaus=1000
EOF
: > "$OUT/nftdb/set_spamhaus_blocklist_v4"
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" spamhaus
t "spamhaus: S24-/S16-префикс срезан, CIDR применён" bash -c "grep -qx '91.240.118.0/24' '$OUT/nftdb/set_spamhaus_blocklist_v4' && grep -qx '45.155.0.0/16' '$OUT/nftdb/set_spamhaus_blocklist_v4'"

# ================= 12) custom: центральный URL + локальный файл объединяются =================
mkdir -p "$OUT/fixtures"
cat > "$OUT/fixtures/custom-central.txt" <<'EOF'
# центральный операторский список (аналог raw custom.txt из репо)
45.148.10.0/24
91.240.118.9
EOF
cat > "$SHIELD_LISTS_DIR/custom.txt" <<'EOF'
# локальная добавка ноды
93.184.216.34
EOF
cat > "$SHIELD_BLOCKLIST_OVERRIDE" <<EOF
BL_LOCK_FILE=$OUT/blocklist.lock
BL_ENABLED_scanner=0
BL_ENABLED_threat=0
BL_ENABLED_tor=0
BL_ENABLED_custom=1
BL_ENABLED_crowdsec=0
BL_ENABLED_spamhaus=0
BL_ENABLED_cins=0
BL_URLS_custom="file://$OUT/fixtures/custom-central.txt"
BL_MIN_custom=0
EOF
: > "$OUT/nftdb/set_custom_blocklist_v4"
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT" custom
t "custom-central: URL + local объединены (3 записи)" bash -c "test \$(wc -l < '$OUT/nftdb/set_custom_blocklist_v4') = 3"
t "custom-central: записи из обоих источников в set" bash -c "grep -qx '45.148.10.0/24' '$OUT/nftdb/set_custom_blocklist_v4' && grep -qx '91.240.118.9/32' '$OUT/nftdb/set_custom_blocklist_v4' && grep -qx '93.184.216.34/32' '$OUT/nftdb/set_custom_blocklist_v4'"

if [ "$fails" -eq 0 ]; then echo "PASS: blocklist (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
