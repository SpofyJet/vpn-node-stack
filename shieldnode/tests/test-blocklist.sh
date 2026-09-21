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

# --- fake nft: table + наборы как файлы; batch = flush/add element ---
cat > "$OUT/bin/nft" <<'EOF'
#!/bin/bash
NFT_DB="${FAKE_NFT_DB:?}"
check=0; batch=""
while [ $# -gt 0 ]; do
    case "$1" in
        list)
            if [ "$2" = "table" ]; then [ -f "$NFT_DB/table" ] || exit 1; exit 0; fi
            if [ "$2" = "set" ]; then
                name="${!#}"
                [ -f "$NFT_DB/set_$name" ] || exit 1
                exit 0
            fi
            exit 1 ;;
        -c) check=1 ;;
        -f) batch="$2" ;;
    esac
    shift
done
[ -n "$batch" ] || exit 1
[ "$check" = "1" ] && exit 0
while IFS= read -r line; do
    case "$line" in
        "flush set inet shieldnode "*)
            name="${line##* }"; : > "$NFT_DB/set_$name" ;;
        "add element inet shieldnode "*)
            rest="${line#add element inet shieldnode }"
            name="${rest%% *}"
            inner="${rest#* \{ }"; inner="${inner% \}}"
            oldifs="$IFS"; IFS=','
            # shellcheck disable=SC2206
            for e in $inner; do echo "$e" | sed 's/^ //;s/ $//' >> "$NFT_DB/set_$name"; done
            IFS="$oldifs" ;;
    esac
done < "$batch"
exit 0
EOF
chmod +x "$OUT/bin/nft"
touch "$OUT/nftdb/table"
for s in scanner_blocklist_v4 scanner_blocklist_v6 threat_blocklist_v4 threat_blocklist_v6 \
         tor_exit_blocklist_v4 tor_exit_blocklist_v6 custom_blocklist_v4 custom_blocklist_v6; do
    : > "$OUT/nftdb/set_$s"
done

# --- пути lib/blocklist.sh под sandbox (script — production-путь: stub мапит в $OUT) ---
source "$SHIELD_DIR/lib/blocklist.sh"
SHIELD_BLOCKLIST_STATE="$OUT/var/lib/shieldnode/blocklists"
SHIELD_LISTS_DIR="$OUT/etc/shieldnode/lists"
SHIELD_BLOCKLIST_OVERRIDE="$OUT/etc/shieldnode/blocklist.conf"

# --- конфиг-окружение install'а ---
export SH_F_ENABLE_SCANNER_LIST=1 SH_F_ENABLE_THREAT_LIST=1 SH_F_BLOCK_TOR=0 SH_F_ENABLE_CUSTOM_LIST=1
export DRY_RUN=0
mkdir -p "$(dirname "$SHIELD_CONFIG")" 2>/dev/null || true

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
BL_ENABLED_custom=0
BL_URLS_scanner="file://$OUT/fixtures/scanner6.txt"
BL_MIN_scanner=1
EOF
PATH="$OUT/bin:$PATH" FAKE_NFT_DB="$OUT/nftdb" bash "$SHIELD_BLOCKLIST_SCRIPT"
t "v6: v6-элементы применены отдельной транзакцией" bash -c "grep -qx '2a06:98c0:dead::/48' '$OUT/nftdb/set_scanner_blocklist_v6' && grep -qx '2606:4700::/32' '$OUT/nftdb/set_scanner_blocklist_v6'"
t "v6: link-local отрезан" bash -c "! grep -q 'fe80' '$OUT/nftdb/set_scanner_blocklist_v6'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: blocklist (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
