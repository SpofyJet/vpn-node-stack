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

    # crowdsec Blocklist-as-a-Service: console → Blocklist → Integrations →
    # "Raw IP List" → ID + Basic-Auth логин/пароль (показываются ОДИН раз).
    # Креды живут в config.conf (0640 root). Community-тариф: не чаще 1 pull/24ч
    # (иначе HTTP 429) — updater сам душит интервал через BL_INTERVAL_crowdsec.
    local cs_id cs_user cs_pass cs_endpoint="" cs_mode
    cs_id="$(shield_conf_get CROWDSEC_INTEGRATION_ID "")"
    cs_user="$(shield_conf_get CROWDSEC_USER "")"
    cs_pass="$(shield_conf_get CROWDSEC_PASSWORD "")"
    cs_mode="$(shield_crowdsec_resolve_mode)"
    if [ "$cs_mode" = "feed" ] && [ -n "$cs_id" ] && [ -n "$cs_user" ] && [ -n "$cs_pass" ]; then
        cs_endpoint="https://admin.api.crowdsec.net/v1/integrations/${cs_id}/content"
    elif [ "$cs_mode" = "agent" ]; then
        # локальный источник: updater читает cscli decisions (демон тянет CAPI сам)
        cs_endpoint="local://cscli-decisions"
    elif [ "${SH_F_ENABLE_CROWDSEC_LIST:-0}" = "1" ]; then
        log warn "blocklist" "ENABLE_CROWDSEC_LIST=1, но креды не заданы — будет agent-режим (нужен crowdsec-демон); либо задай CROWDSEC_INTEGRATION_ID/USER/PASSWORD для feed"
    fi

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
MAIN_LOCK_FILE="__MAIN_LOCK_FILE__"
HEADER_EOF
        # baked-конфиг (значения из config.conf на момент apply)
        printf 'BL_ENABLED_scanner="%s"\n' "$SH_F_ENABLE_SCANNER_LIST"
        printf 'BL_ENABLED_threat="%s"\n' "$SH_F_ENABLE_THREAT_LIST"
        printf 'BL_ENABLED_tor="%s"\n' "$SH_F_BLOCK_TOR"
        printf 'BL_ENABLED_custom="%s"\n' "$SH_F_ENABLE_CUSTOM_LIST"
        printf 'BL_ENABLED_crowdsec="%s"\n' "${SH_F_ENABLE_CROWDSEC_LIST:-0}"
        printf 'BL_ENABLED_spamhaus="%s"\n' "${SH_F_ENABLE_SPAMHAUS_LIST:-1}"
        printf 'BL_ENABLED_cins="%s"\n' "${SH_F_ENABLE_CINS_LIST:-1}"
        printf 'BL_URLS_scanner="%s"\n' "$svc_scanner"
        printf 'BL_URLS_threat="%s"\n' "$svc_threat"
        printf 'BL_URLS_tor="%s"\n' "$svc_tor"
        # custom: локальный файл /etc/shieldnode/lists/custom.txt (оператор) +
        # опциональный центральный URL (BLOCKLIST_CUSTOM_URLS — например raw
        # custom.txt из операторского репо; синкается каждый тик таймера)
        printf 'BL_URLS_custom="%s"\n' "$(shield_conf_get BLOCKLIST_CUSTOM_URLS "")"
        printf 'BL_URLS_crowdsec="%s"\n' "$cs_endpoint"
        # spamhaus DROP/EDROP (v4) + dropv6 (v6): формат "S24-x.y.z.w/24 ; comment"
        # (префикс S<len>- и хвост после ';' срезаются парсером)
        printf 'BL_URLS_spamhaus="https://www.spamhaus.org/drop/drop.txt https://www.spamhaus.org/drop/dropv6.txt https://www.spamhaus.org/drop/edrop.txt"\n'
        # CINS Army: plain IP list (v4 only)
        printf 'BL_URLS_cins="https://cinsscore.com/list/ci-badguys.txt"\n'
        # креды crowdsec НЕ запекаются в updater (скрипт 0750, но читаем
        # группой) — они живут в /etc/shieldnode/crowdsec.creds (0600 root),
        # updater source'ит его при каждом тике (см. BODY)
        printf 'BL_MIN_scanner="%s"\n' "$(shield_conf_get MIN_ENTRIES_SCANNER 1000)"
        printf 'BL_MIN_threat="%s"\n' "$(shield_conf_get MIN_ENTRIES_THREAT 500)"
        printf 'BL_MIN_tor="%s"\n' "$(shield_conf_get MIN_ENTRIES_TOR 100)"
        printf 'BL_MIN_custom="%s"\n' "$(shield_conf_get MIN_ENTRIES_CUSTOM 0)"
        printf 'BL_MIN_crowdsec="%s"\n' "$(shield_conf_get MIN_ENTRIES_CROWDSEC 500)"
        printf 'BL_MIN_spamhaus="%s"\n' "$(shield_conf_get MIN_ENTRIES_SPAMHAUS 50)"
        printf 'BL_MIN_cins="%s"\n' "$(shield_conf_get MIN_ENTRIES_CINS 2000)"
        printf 'BL_MAX_scanner=100000\nBL_MAX_threat=200000\nBL_MAX_tor=10000\nBL_MAX_custom=50000\nBL_MAX_crowdsec=400000\nBL_MAX_spamhaus=20000\nBL_MAX_cins=200000\n'
        # размер сетов (для tmp-сета при атомарном swap — должен совпадать с firewall)
        printf 'BL_SIZE_scanner="%s"\nBL_SIZE_threat="%s"\nBL_SIZE_tor="%s"\nBL_SIZE_custom="%s"\nBL_SIZE_crowdsec="%s"\nBL_SIZE_spamhaus="%s"\nBL_SIZE_cins="%s"\n' \
            "${SH_R_SCANNER_BLOCKLIST_SIZE:-262144}" "${SH_R_THREAT_BLOCKLIST_SIZE:-131072}" \
            "${SH_R_TOR_BLOCKLIST_SIZE:-16384}" "${SH_R_CUSTOM_BLOCKLIST_SIZE:-65536}" \
            "${SH_R_CROWDSEC_BLOCKLIST_SIZE:-262144}" "${SH_R_SPAMHAUS_BLOCKLIST_SIZE:-8192}" \
            "${SH_R_CINS_BLOCKLIST_SIZE:-65536}"
        # min-prefix v4/v6: threat — /16 (анти-compromise), scanner/custom — /8,
        # tor — только /32 (single IPs) / v6 /128, crowdsec — /24 (CAPI отдаёт
        # одиночные IP, но консольные листы могут содержать CIDR)
        printf 'BL_MINP4_scanner=8 BL_MINP4_threat=16 BL_MINP4_tor=32 BL_MINP4_custom=8 BL_MINP4_crowdsec=24 BL_MINP4_spamhaus=16 BL_MINP4_cins=20\n'
        printf 'BL_MINP6_scanner=24 BL_MINP6_threat=29 BL_MINP6_tor=128 BL_MINP6_custom=24 BL_MINP6_crowdsec=64 BL_MINP6_spamhaus=32 BL_MINP6_cins=64\n'
        # crowdsec interval: feed — community-тариф не чаще 1 pull/24ч (иначе 429);
        # agent — читаем ЛОКАЛЬНУЮ БД демона (демон сам тянет CAPI ~раз/2ч),
        # дефолт 30 мин без риска рейт-лимита. Ключи разведены: у feed своё,
        # у agent своё — иначе значение feed'а (1440) молча душило бы agent.
        local cs_interval
        if [ "$cs_mode" = "agent" ]; then
            cs_interval="$(shield_conf_get CROWDSEC_AGENT_INTERVAL_MIN 30)"
        else
            cs_interval="$(shield_conf_get CROWDSEC_UPDATE_INTERVAL_MIN 1440)"
        fi
        printf 'BL_INTERVAL_crowdsec="%s"\n' "$cs_interval"
        cat <<'BODY_EOF'

# операторские оверрайды (не перезаписываются apply)
if [ -f "__OVERRIDE__" ]; then
    # shellcheck source=/dev/null
    . "__OVERRIDE__"
fi

# crowdsec-креды feed-режима — отдельный файл 0600 root:root (создаётся apply
# из конфига ТОЛЬКО когда crowdsec включён и креды заданы); в updater (0750)
# они не запекаются
if [ -f /etc/shieldnode/crowdsec.creds ]; then
    # shellcheck source=/dev/null
    . /etc/shieldnode/crowdsec.creds
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

# основной lock shieldnode (apply/rollback): updater не должен менять сеты
# посреди apply. НЕблокирующе: занят → пропуск тика (следующий применит).
# Если lock-файл недоступен (нет прав/каталога) — info и работаем без него.
if [ -n "${MAIN_LOCK_FILE:-}" ]; then
    mkdir -p "$(dirname "$MAIN_LOCK_FILE")" 2>/dev/null || true
    if exec 8>"$MAIN_LOCK_FILE" 2>/dev/null; then
        flock -n 8 2>/dev/null || { bl_log info "main lock занят (apply/rollback) — пропуск тика"; exit 0; }
    else
        bl_log info "main lock $MAIN_LOCK_FILE недоступен — тик без основного lock'а"
    fi
fi

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
        # cscli decisions list -o json отдаёт объекты с полем "value"
        for k in ("cidr", "prefix", "ip", "address", "value"):
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
    local name="$1" enabled urls min_entries max_entries minp4 minp6 interval_guard
    # без eval под root: косвенное раскрытие ${!v} — код из имени не исполняется
    local _v
    _v="BL_ENABLED_$name"; enabled="${!_v:-0}"
    [ "$enabled" = "1" ] || return 0
    _v="BL_URLS_$name";   urls="${!_v:-}"
    _v="BL_MIN_$name";    min_entries="${!_v:-0}"
    _v="BL_MAX_$name";    max_entries="${!_v:-100000}"
    _v="BL_MINP4_$name";  minp4="${!_v:-8}"
    _v="BL_MINP6_$name";  minp6="${!_v:-24}"
    # маппинг имён сетов: name=tor -> nft-сеты tor_exit_blocklist_{v4,v6}
    # (см. lib/nft.sh), остальные — <name>_blocklist_{v4,v6}
    local set_prefix="${name}_blocklist"
    case "$name" in tor) set_prefix="tor_exit_blocklist" ;; esac
    local set_v4="${set_prefix}_v4" set_v6="${set_prefix}_v6"
    local fail_counter="$STATE_DIR/fails-$name.cnt"
    local tmp remote_ok=0 local_ok=0
    tmp="$(mktemp -d /tmp/shieldnode-bl.XXXXXX)" || return 1
    : > "$tmp/all.raw"

    # 0) per-feed interval-guard: для crowdsec community-тариф разрешает pull
    #    не чаще раза в N минут (default 1440 = 24ч, иначе API шлёт 429).
    #    Пропуск = set остаётся как есть (last-known-good), fail-counter не трогаем.
    #    FORCE=1 — ручной обход гарда (отладка/первичная заливка).
    _v="BL_INTERVAL_$name"; interval_guard="${!_v:-0}"
    if [ "${FORCE:-0}" = "1" ]; then interval_guard=0; fi
    if [ "$interval_guard" -gt 0 ] 2>/dev/null; then
        local lastok_f="$STATE_DIR/lastok-$name.ts" now lastok
        now="$(date +%s)"
        lastok="$([ -f "$lastok_f" ] && cat "$lastok_f" || echo 0)"
        if [ $(( now - lastok )) -lt $(( interval_guard * 60 )) ]; then
            bl_log info "$name: interval-guard ${interval_guard}m не истёк — пропуск fetch (set не тронут)"
            rm -rf "$tmp"
            return 0
        fi
    fi

    # 1) remote-источники (ан aggregator'ов). JSON — через извлекатель, иначе raw.
    #    crowdsec-endpoint — Basic-Auth + --compressed (без сжатия ответы >5MB
    #    ТРУНЦИРУЮТСЯ на ~350k записей — docs.crowdsec.net/u/integrations).
    local u f
    for u in $urls; do
        f="$tmp/$(echo "$u" | sha256sum | cut -c1-12).raw"
        local curl_rc=0
        case "$u" in
            local://cscli-decisions)
                # agent-режим: читаем ЛОКАЛЬНУЮ БД crowdsec (CAPI уже стянул демон)
                if ! command -v cscli >/dev/null 2>&1; then
                    bl_log warn "$name: agent-режим, но cscli не найден — пропущен"
                    continue
                fi
                cscli decisions list -t ban -o json > "$f" 2>/dev/null || curl_rc=$? ;;
            https://admin.api.crowdsec.net/*)
                if [ -z "${CROWDSEC_USER:-}" ] || [ -z "${CROWDSEC_PASSWORD:-}" ]; then
                    bl_log warn "$name: CROWDSEC_USER/CROWDSEC_PASSWORD не заданы — fetch пропущен"
                    continue
                fi
                curl -fsSL --compressed --connect-timeout 10 --max-time 120 \
                     -u "$CROWDSEC_USER:$CROWDSEC_PASSWORD" -o "$f" "$u" 2>/dev/null || curl_rc=$? ;;
            *)
                curl -fsSL --connect-timeout 10 --max-time 60 -o "$f" "$u" 2>/dev/null || curl_rc=$? ;;
        esac
        if [ "$curl_rc" -eq 0 ] && [ -s "$f" ]; then
            remote_ok=$((remote_ok + 1))
            case "$u" in
                # lastok пишем и в agent-режиме — иначе interval-guard (BL_INTERVAL_crowdsec)
                # не будет иметь метки и пропускать прогоны (local-чтение дёшево, но гард
                # сохраняет поведение фида и не дёргает cscli чаще интервала)
                https://admin.api.crowdsec.net/*|local://*) date +%s > "$STATE_DIR/lastok-$name.ts" ;;
            esac
            case "$u" in
                local://*) extract_json_ips "$f" >> "$tmp/all.raw" 2>/dev/null || cat "$f" >> "$tmp/all.raw" ;;
                *.json|*.json\?*) extract_json_ips "$f" >> "$tmp/all.raw" 2>/dev/null || cat "$f" >> "$tmp/all.raw" ;;
                *) cat "$f" >> "$tmp/all.raw" ;;
            esac
        else
            # в лог — только имя фида: integration ID и креды crowdsec не светим
            local ulog="$u"
            case "$u" in https://admin.api.crowdsec.net/*) ulog="crowdsec-feed (integration-id скрыт)" ;; esac
            bl_log warn "$name: fetch failed (rc=$curl_rc): $ulog"
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
    #    Нормализация spamhaus: "S24-1.2.3.0/24 ; Spamhaus DROP" -> "1.2.3.0/24".
    #    2026-09-23 (v1.1.2): ОДИН проход awk вместо sed|grep|awk|awk (5 процессов
    #    -> 1), правила те же: снятие «S24-», IPv4[/p] в начале строки жадно по <=3
    #    цифры на октет (как grep -oE), bogon/диапазон префикса. Отличие: октет-
    #    «хвост» (1.2.3.1234) раньше УСЕКАЛСЯ до 1.2.3.123 и блокировал чужой адрес —
    #    теперь строка отбрасывается. Без {m,n} и без цепочек «[0-9]?»: mawk 1.3.4
    #    (дефолт Debian/Ubuntu) в match() для них НЕ leftmost-longest (из
    #    «1.0.108.130» берёт «1.0.108.13») — берём самый длинный прогон [0-9./]
    #    (простой класс+ mawk матчит верно) и проверяем октеты через split().
    awk -v minprefix="$minp4" '
        {
            if ($0 ~ /^S[0-9]+-[0-9]/) sub(/^S[0-9]+-/, "")
            if (!match($0, /^[[:space:]]*[0-9.\/]+/)) next
            t = substr($0, 1, RLENGTH); sub(/^[[:space:]]+/, "", t)
            sl = index(t, "/"); ip = sl ? substr(t, 1, sl - 1) : t; rest = sl ? substr(t, sl + 1) : ""
            n = split(ip, f, ".")
            if (n < 4) next
            bad = 0; for (i = 1; i <= 4; i++) if (f[i] == "" || length(f[i]) > 3) bad = 1
            if (bad) next
            s = f[1] "." f[2] "." f[3] "." f[4]; prefix = 32
            # префикс — только сразу после 4-го октета (как «(/[0-9]+)?» у grep); +0 — число, не строка
            if (n == 4 && match(rest, /^[0-9]+/)) { p = substr(rest, 1, RLENGTH); s = s "/" p; prefix = p + 0 }
            if (prefix < minprefix || prefix > 32) next
            o1 = f[1] + 0; o2 = f[2] + 0; o3 = f[3] + 0; o4 = f[4] + 0
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
            print s
        }' "$tmp/all.raw" 2>/dev/null | sort -u > "$tmp/parsed.list"
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

    # 9) swap содержимого сета. Предпочтительно АТОМАРНЫЙ: новое содержимое
    #    заливается в <set>__next (не прибит к правилам — трафик его не видит),
    #    затем ОДНА транзакция: delete rule → delete set → rename next→live →
    #    insert rule на прежнюю позицию. Окно «частично заполненного сета» = 0.
    #    Fallback (старый nft / нет handle'ов / mixed-version таблица): legacy
    #    flush+refill одним batch — семантика прежних версий.
    local rc=0 v6_failed=0
    local short="$name"
    case "$set_v4" in tor_exit_*) short="tor" ;; esac

    swap_one() { # swap_one <live_set> <af:4|6> <loadfile> ; 0=ok, 1=fallback-needed
        local set="$1" af="$2" load="$3"
        local tmp_set="${set}__next" afword="ip" stype="ipv4_addr" sz _v
        if [ "$af" = "6" ]; then afword="ip6"; stype="ipv6_addr"; fi
        _v="BL_SIZE_${name}"; sz="${!_v:-262144}"
        # 1) tmp-set с теми же свойствами + заливка (окна для трафика нет)
        {
            echo "add set inet shieldnode $tmp_set { type $stype; flags interval; auto-merge; size ${sz:-262144}; }"
            awk -v setname="$tmp_set" '
                NR % 1000 == 1 { if (NR > 1) print "}"; printf "add element inet shieldnode %s { ", setname }
                { printf "%s%s", (NR % 1000 == 1 ? "" : ", "), $0 }
                END { print " }" }' "$load"
        } > "$tmp/swap-fill.$af"
        if ! nft -c -f "$tmp/swap-fill.$af" >/dev/null 2>"$tmp/swap.$af.err" || ! nft -f "$tmp/swap-fill.$af" 2>>"$tmp/swap.$af.err"; then
            bl_log error "$name: tmp-set $tmp_set fill failed: $(head -c 300 "$tmp/swap.$af.err")"
            nft delete set inet shieldnode "$tmp_set" 2>/dev/null || true
            return 1
        fi
        # 2) handle drop-правила и позиция следующего правила
        local listing rule_handle="" pos_handle=""
        listing="$(nft -a list chain inet shieldnode prerouting 2>/dev/null)" || { nft delete set inet shieldnode "$tmp_set" 2>/dev/null; return 1; }
        rule_handle="$(printf '%s\n' "$listing" | awk -v pat="$afword saddr @${set} counter" '$0 ~ pat { if (match($0, /# handle [0-9]+/)) { print substr($0, RSTART+9, RLENGTH-9); exit } }')"
        if [ -z "$rule_handle" ]; then
            nft delete set inet shieldnode "$tmp_set" 2>/dev/null || true
            return 1   # правила нет (mixed-version) — legacy refill корректен
        fi
        pos_handle="$(printf '%s\n' "$listing" | awk -v rh="$rule_handle" '
            found && match($0, /# handle [0-9]+/) { print substr($0, RSTART+9, RLENGTH-9); exit }
            $0 ~ ("# handle " rh "$") { found=1 }')"
        # 3) swap одной транзакцией
        {
            echo "delete rule inet shieldnode prerouting handle $rule_handle"
            echo "delete set inet shieldnode $set"
            echo "rename set inet shieldnode $tmp_set $set"
            if [ -n "$pos_handle" ]; then
                echo "insert rule inet shieldnode prerouting position $pos_handle $afword saddr @$set counter name c_drops_${short}_v${af} drop"
            else
                echo "add rule inet shieldnode prerouting $afword saddr @$set counter name c_drops_${short}_v${af} drop"
            fi
        } > "$tmp/swap.$af"
        if nft -c -f "$tmp/swap.$af" >/dev/null 2>"$tmp/swap.$af.err" && nft -f "$tmp/swap.$af" 2>>"$tmp/swap.$af.err"; then
            return 0
        fi
        nft delete set inet shieldnode "$tmp_set" 2>/dev/null || true
        bl_log warn "$name: atomic swap v$af недоступен ($(head -c 200 "$tmp/swap.$af.err")) — legacy flush+refill"
        return 1
    }

    legacy_refill() { # legacy_refill <set> <loadfile> ; 0=ok
        local set="$1" load="$2"
        {
            echo "flush set inet shieldnode $set"
            awk -v setname="$set" '
                NR % 1000 == 1 { if (NR > 1) print "}"; printf "add element inet shieldnode %s { ", setname }
                { printf "%s%s", (NR % 1000 == 1 ? "" : ", "), $0 }
                END { print " }" }' "$load"
        } > "$tmp/legacy.nft"
        nft -c -f "$tmp/legacy.nft" >/dev/null 2>"$tmp/legacy.err" && nft -f "$tmp/legacy.nft" 2>>"$tmp/legacy.err"
    }

    if nft list set $TABLE "$set_v4" >/dev/null 2>&1; then
        if swap_one "$set_v4" 4 "$tmp/load.list" || legacy_refill "$set_v4" "$tmp/load.list"; then
            echo 0 > "$fail_counter"
            rm -f "$STATE_DIR/.alert-$name"
        else
            bl_log error "$name: nft swap v4 failed"
            bump_fail "$name" "$fail_counter"
            rc=1
        fi
    else
        bl_log warn "$name: set $set_v4 отсутствует — skip"
        rc=1
    fi

    if nft list set $TABLE "$set_v6" >/dev/null 2>&1 && [ -s "$tmp/load6.list" ]; then
        if ! swap_one "$set_v6" 6 "$tmp/load6.list" && ! legacy_refill "$set_v6" "$tmp/load6.list"; then
            v6_failed=1
            bl_log warn "$name: v6 swap failed — v4 не затронут"
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
# 2026-09-23 (v1.1.2): IPv4 — слияние целочисленных интервалов + минимальное
# CIDR-разложение (тот же единственный результат, что ipaddress.collapse_addresses,
# в разы быстрее на 200k). Строки, которые быстрый разбор не узнаёт, решает
# ipaddress (набор принимаемых строк прежний); есть IPv6 — прежний путь целиком.
import sys, ipaddress
def fast_v4(s):
    ip, sl, p = s.partition('/')
    o = ip.split('.')
    if len(o) != 4: return None
    v = 0
    for x in o:
        if not (x.isascii() and x.isdigit()) or len(x) > 3 or (len(x) > 1 and x[0] == '0'): return None
        x = int(x)
        if x > 255: return None
        v = (v << 8) | x
    if sl:
        if not (p.isascii() and p.isdigit()) or len(p) > 2 or (len(p) > 1 and p[0] == '0'): return None
        p = int(p)
        if p > 32: return None
    else:
        p = 32
    size = 1 << (32 - p)
    v &= ~(size - 1) & 0xFFFFFFFF
    return (v, v + size - 1)
def legacy(lines, out):
    nets = []
    for line in lines:
        try: nets.append(ipaddress.ip_network(line, strict=False))
        except ValueError: pass
    for n in ipaddress.collapse_addresses(nets): out.write(str(n) + '\n')
try:
    with open(sys.argv[1]) as fh:
        lines = [l.strip() for l in fh if l.strip()]
    iv, v6 = [], False
    for line in lines:
        r = fast_v4(line)
        if r is None:
            try: n = ipaddress.ip_network(line, strict=False)
            except ValueError: continue
            if n.version == 6: v6 = True; break
            r = (int(n.network_address), int(n.broadcast_address))
        iv.append(r)
    with open(sys.argv[2], 'w') as out:
        if v6:
            legacy(lines, out)
        else:
            iv.sort(); merged = []
            for s, e in iv:
                if merged and s <= merged[-1][1] + 1:
                    if e > merged[-1][1]: merged[-1][1] = e
                else:
                    merged.append([s, e])
            w = out.write
            for s, e in merged:
                while s <= e:
                    size = (s & -s) if s else (1 << 32)
                    while size > e - s + 1: size >>= 1
                    w('%d.%d.%d.%d/%d\n' % (s >> 24, (s >> 16) & 255, (s >> 8) & 255, s & 255, 33 - size.bit_length()))
                    s += size
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
[ -n "$lists" ] || lists="scanner threat tor custom crowdsec spamhaus cins"
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
            -e "s|__MAIN_LOCK_FILE__|${SHIELD_LOCK:-/run/shieldnode/shieldnode.lock}|g" \
            -e "s|__OVERRIDE__|$SHIELD_BLOCKLIST_OVERRIDE|g" \
        | shield_persist_stream "$SHIELD_BLOCKLIST_SCRIPT" 0750

    # --- 1.5) crowdsec-креды feed-режима: отдельный файл 0600 root:root,
    #     updater читает его source'ом при каждом тике. Создаём/обновляем
    #     ТОЛЬКО если crowdsec включён и креды заданы (agent-режиму не нужны).
    if [ "$(shield_conf_get ENABLE_CROWDSEC_LIST 0)" = "1" ] && [ -n "$cs_user" ] && [ -n "$cs_pass" ]; then
        # 2026-09-23: файл source'ится root'ом на каждом тике — пароль с $ ` " \
        # раньше ломал auth или исполнялся как код. Безопасные символы — прежний
        # формат "..." (существующие установки байт-в-байт те же), иначе %q.
        _csq() { if [[ "$1" =~ ^[A-Za-z0-9._@%+=:,/-]*$ ]]; then printf '"%s"' "$1"; else printf '%q' "$1"; fi; }
        { printf 'CROWDSEC_USER=%s\n' "$(_csq "$cs_user")"
          printf 'CROWDSEC_PASSWORD=%s\n' "$(_csq "$cs_pass")"
        } | shield_persist_stream /etc/shieldnode/crowdsec.creds 0600
    fi

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
# 2026-09-23: '-' — несуществующий путь без префикса = 226/NAMESPACE (юнит не
# стартовал: blocklists/ и лог не создавал никто, /run/shieldnode пуст после boot)
ReadWritePaths=-$SHIELD_BLOCKLIST_STATE -/run/shieldnode -/var/log/shieldnode.log
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
ReadWritePaths=-$SHIELD_BLOCKLIST_STATE -/run/shieldnode -/var/log/shieldnode.log
TimeoutStartSec=600
EOF
    # 2026-09-23: каталоги/лог для sandbox-юнитов (ProtectSystem=strict сам их не
    # создаст): при boot — systemd-tmpfiles-setup (/run — tmpfs), сейчас — mkdir
    shield_persist_stream "${SHIELD_TMPFILES:-/etc/tmpfiles.d/shieldnode.conf}" 0644 <<EOF
# shieldnode — runtime/state dirs + log for sandboxed units (managed by shieldnode)
d /run/shieldnode 0755 root root -
d $SHIELD_BLOCKLIST_STATE 0750 root root -
f /var/log/shieldnode.log 0640 root root -
EOF
    if [ "${DRY_RUN:-0}" != "1" ]; then
        mkdir -p "$SHIELD_BLOCKLIST_STATE" /run/shieldnode 2>/dev/null || true
        [ -e /var/log/shieldnode.log ] || install -m 0640 /dev/null /var/log/shieldnode.log 2>/dev/null || true
    fi
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
# МГНОВЕННО (systemd path-триггер на этот файл).
# Второй источник — центральный URL в config.conf: BLOCKLIST_CUSTOM_URLS
# (аналог старого репо SpofyJet/shield lists/custom.txt). Оба объединяются.
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
