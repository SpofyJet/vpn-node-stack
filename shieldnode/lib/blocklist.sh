#!/bin/bash
# shieldnode — lib/blocklist.sh: агрегаторские блоклисты (scanner/threat/tor/custom)
# с автообновлением. Порт проверенного в бою апдейтера старого shieldnode
# (ШАГ 6, updater v3.12.0+): те же источники-агрегаторы, те же гарантии:
#   MIN_ENTRIES (не применяем деградировавший фид), FAIL_THRESHOLD + keep
#   last-known-good (stale OK, никогда не flush'им в пустоту), flock-сериализация,
#   hash-guard для custom, атомарный swap (nft -c -f → nft -f, v4/v6 раздельными
#   транзакциями), CIDR-агрегация через ipaddress.collapse_addresses.
# Правила drop ПОСЛЕ whitelist (lib/nft.sh) — админ/TRUSTED_IPS списками не режутся.
set -euo pipefail

SHIELD_BLOCKLIST_SCRIPT=/usr/local/sbin/shieldnode-blocklist
SHIELD_BLOCKLIST_STATE=/var/lib/shieldnode/blocklists
SHIELD_LISTS_DIR=/etc/shieldnode/lists
SHIELD_BLOCKLIST_OVERRIDE=/etc/shieldnode/blocklist.conf

# shield_blocklist_install — эмитим updater + oneshot-службу + timer; сидим списки.
shield_blocklist_install() {
    command -v curl >/dev/null 2>&1 || { log warn "blocklist" "нет curl — updater эмитим, но fetch будет неработоспособен"; }
    command -v systemctl >/dev/null 2>&1 || { log warn "blocklist" "нет systemctl — updater/timer пропущены"; return 0; }

    # --- baked-конфиг: значения фиксируем на момент apply (источники/минимумы) ---
    local interval threshold
    interval="$(shield_conf_get BLOCKLIST_UPDATE_INTERVAL 360)"
    threshold="$(shield_conf_get BLOCKLIST_FAIL_THRESHOLD 3)"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=360
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
    [ "$interval" -ge 5 ] || { log warn "blocklist" "интервал $interval мин слишком мал — выставлено 5"; interval=5; }
    [ "$threshold" -ge 1 ] || threshold=3

    local svc_scanner svc_threat svc_tor svc_custom
    svc_scanner="$(shield_conf_get BLOCKLIST_SCANNER_URLS "")"
    svc_threat="$(shield_conf_get BLOCKLIST_THREAT_URLS "")"
    svc_tor="$(shield_conf_get BLOCKLIST_TOR_URLS "")"

    # --- 1) updater-скрипт ---
    {
        cat <<'HEADER_EOF'
#!/bin/bash
# shieldnode-blocklist — агрегаторские блоклисты: fetch → validate → atomic swap.
# Сгенерировано shieldnode (lib/blocklist.sh). Ручные правки будут перезаписаны
# при следующем apply. Операторские оверрайды: /etc/shieldnode/blocklist.conf
# (BL_URLS_<list>, BL_MIN_<list>, BL_FAIL_THRESHOLD, BL_INTERVAL_MIN).
set -o pipefail
export LANG=C LC_ALL=C

TAG="shieldnode-blocklist"
TABLE="inet shieldnode"
STATE_DIR="__STATE_DIR__"
LISTS_DIR="__LISTS_DIR__"
LOG_FILE="__LOG_FILE__"
FAIL_THRESHOLD="__FAIL_THRESHOLD__"
BL_LOCK_FILE="__LOCK_FILE__"
HEADER_EOF
        # baked-конфиг (значения из config.conf на момент apply)
        printf 'BL_ENABLED_scanner="%s"\n' "$SH_F_ENABLE_SCANNER_LIST"
        printf 'BL_ENABLED_threat="%s"\n' "$SH_F_ENABLE_THREAT_LIST"
        printf 'BL_ENABLED_tor="%s"\n' "$SH_F_BLOCK_TOR"
        printf 'BL_ENABLED_custom="%s"\n' "$SH_F_ENABLE_CUSTOM_LIST"
        printf 'BL_URLS_scanner="%s"\n' "$svc_scanner"
        printf 'BL_URLS_threat="%s"\n' "$svc_threat"
        printf 'BL_URLS_tor="%s"\n' "$svc_tor"
        printf 'BL_URLS_custom=""\n'
        printf 'BL_MIN_scanner="%s"\n' "$(shield_conf_get MIN_ENTRIES_SCANNER 1000)"
        printf 'BL_MIN_threat="%s"\n' "$(shield_conf_get MIN_ENTRIES_THREAT 500)"
        printf 'BL_MIN_tor="%s"\n' "$(shield_conf_get MIN_ENTRIES_TOR 100)"
        printf 'BL_MIN_custom="%s"\n' "$(shield_conf_get MIN_ENTRIES_CUSTOM 0)"
        printf 'BL_MAX_scanner=100000\nBL_MAX_threat=200000\nBL_MAX_tor=10000\nBL_MAX_custom=50000\n'
        # min-prefix v4/v6: threat — /16 (анти-compromise), scanner/custom — /8,
        # tor — только /32 (single IPs) / v6 /128
        printf 'BL_MINP4_scanner=8 BL_MINP4_threat=16 BL_MINP4_tor=32 BL_MINP4_custom=8\n'
        printf 'BL_MINP6_scanner=24 BL_MINP6_threat=29 BL_MINP6_tor=128 BL_MINP6_custom=24\n'
        cat <<'BODY_EOF'

# операторские оверрайды (не перезаписываются apply)
if [ -f "__OVERRIDE__" ]; then
    # shellcheck source=/dev/null
    . "__OVERRIDE__"
fi

bl_log() { # bl_log <level> <msg>
    local lvl="$1"; shift
    logger -t "$TAG" "$lvl: $*" 2>/dev/null || true
    if [ -w "$LOG_FILE" ]; then
        printf '%s [%s] blocklist: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$lvl" "$*" >> "$LOG_FILE"
    fi
}

# 0) firewall не применён/откачен — нечего обновлять (exit 0, тихо)
if ! nft list table $TABLE >/dev/null 2>&1; then
    exit 0
fi

mkdir -p "$STATE_DIR" "$(dirname "$BL_LOCK_FILE")" 2>/dev/null || true

# flock: серия триггеров схлопывается в последовательные запуски; при занятом
# lock'е >90с — пропуск тика (следующий применит), а не параллельный апдейт
exec 9>"$BL_LOCK_FILE"
flock -w 90 9 2>/dev/null || { bl_log info "lock timeout 90s — пропуск тика"; exit 0; }

# --- JSON-извлечение (spamhaus DROP [{...,"cidr":...}], ripe stat {"prefixes":[...]}) ---
extract_json_ips() { # extract_json_ips <file>
    python3 - "$1" <<'PY_EOF' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
out = []
def walk(o):
    if isinstance(o, dict):
        for k in ("cidr", "prefix", "ip", "address"):
            v = o.get(k)
            if isinstance(v, str) and ("/" in v or ":" in v or "." in v):
                out.append(v.strip())
        for v in o.values():
            if isinstance(v, (dict, list)):
                walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(data)
for x in sorted(set(out)):
    print(x)
PY_EOF
}

# --- обновление одного списка ---
update_list() { # update_list <name>
    local name="$1" enabled urls min_entries max_entries minp4 minp6
    eval "enabled=\"\$BL_ENABLED_$name\""
    [ "$enabled" = "1" ] || return 0
    eval "urls=\"\$BL_URLS_$name\""
    eval "min_entries=\"\$BL_MIN_$name\""
    eval "max_entries=\"\$BL_MAX_$name\""
    eval "minp4=\"\$BL_MINP4_$name\""
    eval "minp6=\"\$BL_MINP6_$name\""
    local set_v4="${name}_blocklist_v4" set_v6="${name}_blocklist_v6"
    local fail_counter="$STATE_DIR/fails-$name.cnt"
    local tmp remote_ok=0 local_ok=0
    tmp="$(mktemp -d /tmp/shieldnode-bl.XXXXXX)" || return 1
    : > "$tmp/all.raw"

    # 1) remote-источники (ан aggregator'ов). JSON — через извлекатель, иначе raw.
    local u f
    for u in $urls; do
        f="$tmp/$(echo "$u" | sha256sum | cut -c1-12).raw"
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$f" "$u" 2>/dev/null && [ -s "$f" ]; then
            remote_ok=$((remote_ok + 1))
            case "$u" in
                *.json|*.json\?*) extract_json_ips "$f" >> "$tmp/all.raw" 2>/dev/null || cat "$f" >> "$tmp/all.raw" ;;
                *) cat "$f" >> "$tmp/all.raw" ;;
            esac
        else
            bl_log warn "$name: fetch failed: $u"
        fi
    done

    # 2) local-источник (оператор): /etc/shieldnode/lists/<name>.txt
    if [ -s "$LISTS_DIR/$name.txt" ]; then
        cat "$LISTS_DIR/$name.txt" >> "$tmp/all.raw"
        local_ok=1
    fi

    # 3) всё недоступно и локального нет — keep last-known-good, bump fail counter
    if [ ! -s "$tmp/all.raw" ]; then
        bl_log warn "$name: нет ни одного источника — set не тронут"
        bump_fail "$name" "$fail_counter"
        rm -rf "$tmp"
        return 1
    fi

    # 4) парсинг v4: plain IP / CIDR / "CIDR ; SBLxxx" / inline-комментарии.
    #    Bogon-фильтр (RFC1918/CGNAT/loopback/multicast/reserved/test) — в листы
    #    такое не должно попадать, а если попало (compromised feed) — отсекаем.
    grep -oE '^[[:space:]]*[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]+)?' "$tmp/all.raw" 2>/dev/null | \
        awk '{ sub(/^[[:space:]]+/, ""); print }' | \
        awk -F'[./]' -v minprefix="$minp4" '
        {
            prefix = (NF >= 5) ? $5 : 32
            if (prefix < minprefix || prefix > 32) next
            o1 = $1 + 0; o2 = $2 + 0; o3 = $3 + 0; o4 = $4 + 0
            if (o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255) next
            if (o1 == 0)   next
            if (o1 == 10)  next
            if (o1 == 127) next
            if (o1 >= 224) next
            if (o1 == 169 && o2 == 254) next
            if (o1 == 172 && o2 >= 16 && o2 <= 31) next
            if (o1 == 192 && o2 == 168) next
            if (o1 == 100 && o2 >= 64 && o2 <= 127) next
            if (o1 == 192 && o2 == 0 && o3 == 0) next
            if (o1 == 192 && o2 == 0 && o3 == 2) next
            if (o1 == 198 && (o2 == 18 || o2 == 19)) next
            if (o1 == 198 && o2 == 51 && o3 == 100) next
            if (o1 == 203 && o2 == 0 && o3 == 113) next
            print $0
        }' | sort -u > "$tmp/parsed.list"
    local v4_count
    v4_count=$(wc -l < "$tmp/parsed.list"); v4_count="${v4_count:-0}"

    # 4.1) hard cap: фид внезапно выдал подозрительно много — refuse apply
    if [ "$v4_count" -gt "$max_entries" ]; then
        bl_log warn "$name: ABORT v4 count=$v4_count > cap=$max_entries — suspicious, set не тронут"
        bump_fail "$name" "$fail_counter"
        rm -rf "$tmp"
        return 1
    fi

    # 5) парсинг v6 (v6-часть часто 0 — это не ошибка, min-check к v6 не применяем)
    grep -oiE '^[[:space:]]*([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(/[0-9]{1,3})?' "$tmp/all.raw" 2>/dev/null | \
        awk '{ sub(/^[[:space:]]+/, ""); print tolower($0) }' | \
        awk -v minp="$minp6" '
        {
            raw = $0; addr = raw; pfx = 128; hascidr = 0
            if (index(raw, "/") > 0) { split(raw, a, "/"); addr = a[1]; pfx = a[2] + 0; hascidr = 1 }
            if (pfx < minp || pfx > 128) next
            if (addr == "::" || addr == "::1") next
            if (addr ~ /^fe[89ab]/) next
            if (addr ~ /^f[cd]/)    next
            if (addr ~ /^ff/)       next
            if (addr ~ /^2001:0?db8:/) next
            if (addr ~ /^::ffff:/)  next
            if (addr ~ /^64:ff9b:/) next
            if (addr !~ /:/) next
            if (addr ~ /:$/ && addr !~ /::$/) next
            if (addr ~ /^:/  && addr !~ /^::/) next
            tmp = addr; ncol = gsub(/:/, ":", tmp)
            if (addr ~ /::/) { if (ncol > 7) next } else { if (ncol != 7) next }
            print (hascidr ? addr "/" pfx : addr)
        }' | sort -u > "$tmp/parsed6.list"
    local v6_count
    v6_count=$(wc -l < "$tmp/parsed6.list"); v6_count="${v6_count:-0}"
    if [ "$v6_count" -gt "$max_entries" ]; then
        bl_log warn "$name: v6 count=$v6_count > cap — v6 пропущен"
        : > "$tmp/parsed6.list"; v6_count=0
    fi

    # 6) min-check: меньше ожидаемого — деградировавший фид, НЕ применяем
    if [ "$v4_count" -lt "$min_entries" ]; then
        bl_log warn "$name: только $v4_count записей (мин. $min_entries) — set не тронут"
        bump_fail "$name" "$fail_counter"
        rm -rf "$tmp"
        return 1
    fi

    # 7) hash-guard (custom): тот же контент — no-op, не дергаем nft
    local cur_hash=""
    if [ "$name" = "custom" ]; then
        cur_hash=$(sha256sum "$tmp/parsed.list" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$cur_hash" ] && [ -f "$STATE_DIR/.applied-custom.sha256" ] && \
           [ "$(cat "$STATE_DIR/.applied-custom.sha256" 2>/dev/null)" = "$cur_hash" ]; then
            rm -rf "$tmp"
            return 0
        fi
    fi

    # 8) CIDR-агрегация (collapse): меньше элементов → быстрее загрузка и lookup.
    #    Fallback без python3 — сырой список (auto-merge частично компенсирует).
    cp "$tmp/parsed.list" "$tmp/load.list"
    cp "$tmp/parsed6.list" "$tmp/load6.list"
    if command -v python3 >/dev/null 2>&1; then
        if collapse_cidrs "$tmp/parsed.list" "$tmp/load.list"; then
            local agg
            agg=$(wc -l < "$tmp/load.list"); agg="${agg:-0}"
            [ "$agg" -lt "$v4_count" ] && bl_log info "$name: CIDR-агрегация v4: $v4_count → $agg"
        else
            cp "$tmp/parsed.list" "$tmp/load.list"
        fi
        if [ -s "$tmp/parsed6.list" ]; then
            collapse_cidrs "$tmp/parsed6.list" "$tmp/load6.list" || cp "$tmp/parsed6.list" "$tmp/load6.list"
        fi
    fi

    # 9) атомарный swap: v4 транзакция, затем ИЗОЛИРОВАННАЯ v6 (битый v6 не ломает v4)
    local rc=0 v6_failed=0
    if nft list set $TABLE "$set_v4" >/dev/null 2>&1; then
        {
            echo "flush set $TABLE $set_v4"
            awk -v setname="$set_v4" '
                NR % 1000 == 1 { if (NR > 1) print "}"; printf "add element inet shieldnode %s { ", setname }
                { printf "%s%s", (NR % 1000 == 1 ? "" : ", "), $0 }
                END { print " }" }' "$tmp/load.list"
        } > "$tmp/nft-batch"
        if nft -c -f "$tmp/nft-batch" >/dev/null 2>"$tmp/nft.err" && nft -f "$tmp/nft-batch" 2>>"$tmp/nft.err"; then
            echo 0 > "$fail_counter"
            rm -f "$STATE_DIR/.alert-$name"
        else
            bl_log error "$name: nft swap v4 failed: $(head -c 300 "$tmp/nft.err")"
            bump_fail "$name" "$fail_counter"
            rc=1
        fi
    else
        bl_log warn "$name: set $set_v4 отсутствует — skip"
        rc=1
    fi

    if nft list set $TABLE "$set_v6" >/dev/null 2>&1 && [ -s "$tmp/load6.list" ]; then
        {
            echo "flush set $TABLE $set_v6"
            awk -v setname="$set_v6" '
                NR % 1000 == 1 { if (NR > 1) print "}"; printf "add element inet shieldnode %s { ", setname }
                { printf "%s%s", (NR % 1000 == 1 ? "" : ", "), $0 }
                END { print " }" }' "$tmp/load6.list"
        } > "$tmp/nft-batch6"
        if ! nft -c -f "$tmp/nft-batch6" >/dev/null 2>"$tmp/nft6.err" || ! nft -f "$tmp/nft-batch6" 2>>"$tmp/nft6.err"; then
            v6_failed=1
            bl_log warn "$name: v6 swap failed: $(head -c 300 "$tmp/nft6.err") — v4 не затронут"
        fi
    fi

    if [ "$rc" = "0" ]; then
        cp "$tmp/load.list" "$STATE_DIR/last-good-$name.txt" 2>/dev/null || true
        if [ "$name" = "custom" ] && [ -n "$cur_hash" ] && [ "$v6_failed" = "0" ]; then
            echo "$cur_hash" > "$STATE_DIR/.applied-custom.sha256"
        fi
        bl_log info "$name: updated $set_v4: $v4_count v4 + $v6_count v6 (remote=$remote_ok, local=$local_ok)"
    fi
    rm -rf "$tmp"
    return "$rc"
}

collapse_cidrs() { # collapse_cidrs <in> <out>
    python3 - "$1" "$2" <<'COLLAPSE_EOF'
import sys, ipaddress
nets = []
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                nets.append(ipaddress.ip_network(line, strict=False))
            except ValueError:
                pass
    with open(sys.argv[2], 'w') as out:
        for n in ipaddress.collapse_addresses(nets):
            out.write(str(n) + '\n')
except Exception:
    sys.exit(1)
COLLAPSE_EOF
}

bump_fail() { # bump_fail <name> <counter-file>
    local name="$1" cf="$2" cur
    cur=$(cat "$cf" 2>/dev/null || echo 0); cur="${cur:-0}"
    cur=$((cur + 1))
    echo "$cur" > "$cf"
    if [ "$cur" -ge "$FAIL_THRESHOLD" ] && [ ! -f "$STATE_DIR/.alert-$name" ]; then
        bl_log error "$name: $cur подряд ошибок — keeping last-known-good (stale OK), проверь источники/сеть"
        date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/.alert-$name"
    fi
}

rc=0
# аргументы = подмножество списков (systemd path-триггер зовёт с "custom");
# без аргументов — все включённые
lists="$*"
[ -n "$lists" ] || lists="scanner threat tor custom"
for list_name in $lists; do
    update_list "$list_name" || rc=1
done
exit "$rc"
BODY_EOF
    } | sed -e "s|__STATE_DIR__|$SHIELD_BLOCKLIST_STATE|g" \
            -e "s|__LISTS_DIR__|$SHIELD_LISTS_DIR|g" \
            -e "s|__LOG_FILE__|/var/log/shieldnode.log|g" \
            -e "s|__FAIL_THRESHOLD__|$threshold|g" \
            -e "s|__LOCK_FILE__|/run/shieldnode/blocklist.lock|g" \
            -e "s|__OVERRIDE__|$SHIELD_BLOCKLIST_OVERRIDE|g" \
        | shield_persist_stream "$SHIELD_BLOCKLIST_SCRIPT" 0755

    # --- 2) oneshot-служба + timer (OnBootSec=3min, далее раз в BLOCKLIST_UPDATE_INTERVAL мин) ---
    shield_persist_stream /etc/systemd/system/shieldnode-blocklist.service 0644 <<EOF
[Unit]
Description=shieldnode aggregator blocklist updater (scanner/threat/tor/custom)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SHIELD_BLOCKLIST_SCRIPT
Nice=19
IOSchedulingClass=idle
# Принципиально: только обновление set'ов; ssh/docker/xray не трогаем.
# hardening как в старой ветке: updater не нужен root-доступ к системе
# сверх state/лога/lock'а
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$SHIELD_BLOCKLIST_STATE /run/shieldnode /var/log/shieldnode.log
TimeoutStartSec=600
EOF
    # path-триггер для custom: мгновенный apply при правке custom.txt
    # (edge-триггер PathChanged; без PathExists — иначе цикл рестартов)
    shield_persist_stream /etc/systemd/system/shieldnode-blocklist-custom.service 0644 <<EOF
[Unit]
Description=shieldnode custom blocklist update (path-triggered)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SHIELD_BLOCKLIST_SCRIPT custom
Nice=19
IOSchedulingClass=idle
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$SHIELD_BLOCKLIST_STATE /run/shieldnode /var/log/shieldnode.log
TimeoutStartSec=600
EOF
    shield_persist_stream /etc/systemd/system/shieldnode-blocklist-custom.path 0644 <<EOF
[Unit]
Description=watch $SHIELD_LISTS_DIR/custom.txt

[Path]
PathChanged=$SHIELD_LISTS_DIR/custom.txt

[Install]
WantedBy=multi-user.target
EOF
    shield_persist_stream /etc/systemd/system/shieldnode-blocklist.timer 0644 <<EOF
[Unit]
Description=shieldnode blocklist update timer

[Timer]
OnBootSec=3min
OnUnitActiveSec=${interval}min
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # --- 3) сиды /etc/shieldnode/lists/ (операторские данные: НЕ в manifest, НЕ затираем)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        mkdir -p "$SHIELD_LISTS_DIR"
        chmod 0755 "$SHIELD_LISTS_DIR"
        [ -f "$SHIELD_LISTS_DIR/custom.txt" ] || cat > "$SHIELD_LISTS_DIR/custom.txt" <<'EOF'
# shieldnode custom blocklist — операторские вручную добавленные IP/CIDR.
# Формат: одна запись на строку (IP или CIDR, опционально комментарий после #).
# MIN_ENTRIES_CUSTOM=0 — пустой список допустим. Изменения подхватываются
# shieldnode-blocklist.timer (см. BLOCKLIST_UPDATE_INTERVAL в config.conf).
EOF
        chmod 0644 "$SHIELD_LISTS_DIR/custom.txt"
    else
        log info "dry-run" "would seed $SHIELD_LISTS_DIR/custom.txt"
    fi

    # --- 4) активируем ---
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl daemon-reload
        systemctl enable --now shieldnode-blocklist.timer >/dev/null 2>&1 || \
            log warn "blocklist" "systemctl enable shieldnode-blocklist.timer не удался"
        systemctl enable --now shieldnode-blocklist-custom.path >/dev/null 2>&1 || \
            log warn "blocklist" "systemctl enable shieldnode-blocklist-custom.path не удался"
        # первый запуск неблокирующий: apply уже загрузил пустые сеты, updater
        # их наполнит в фоне (fetch может идти секунды/минуты на больших листах)
        systemctl start --no-block shieldnode-blocklist.service 2>/dev/null || true
    fi
    ok "blocklist" "updater+timer installed: $SHIELD_BLOCKLIST_SCRIPT (interval=${interval}m, threshold=$threshold)"
}
