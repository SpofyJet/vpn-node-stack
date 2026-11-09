#!/bin/bash
# shieldnode — lib/crowdsec.sh: режим «agent» для crowdsec-фида (БЕЗ аккаунта
# консоли). Как в старом стеке: crowdsec-демон регистрируется в CAPI анонимно
# (cscli capi register), получает community blocklist, а updater читает решения
# локально (cscli decisions list) и заливает в наши nft-сеты. Баунсер НЕ ставим
# — nftables по-прежнему single-owner (shieldnode таблица).
#
# Выбор режима (CROWDSEC_MODE):
#   feed   — Blocklist-as-a-Service: нужны CROWDSEC_INTEGRATION_ID/USER/PASSWORD
#            (консоль app.crowdsec.net → Blocklist → Integrations)
#   agent  — локальный демон + анонимная CAPI-регистрация, аккаунт НЕ нужен
#   auto   — (default) креды заданы → feed, иначе agent
set -euo pipefail

# _cscli — cscli с таймаутом (2026-09-24, v1.1.6): `cscli capi status/register` ходит в сеть;
# без сети (или с зависшим LAPI) вызов висел минутами и держал apply фаервола (lock).
_cscli() { timeout "${SHIELD_CSCLI_TIMEOUT:-30}" cscli "$@"; }

# shield_crowdsec_resolve_mode — печатает feed|agent
shield_crowdsec_resolve_mode() {
    local mode; mode="$(shield_conf_get CROWDSEC_MODE auto)"
    case "$mode" in
        feed|agent) echo "$mode" ;;
        auto|*)     if [ -n "$(shield_conf_get CROWDSEC_INTEGRATION_ID '')" ] && \
                       [ -n "$(shield_conf_get CROWDSEC_USER '')" ] && \
                       [ -n "$(shield_conf_get CROWDSEC_PASSWORD '')" ]; then
                        echo feed
                    else
                        echo agent
                    fi ;;
    esac
}

# shield_crowdsec_whitelist_ips — админ-IP (ssh-сессия) + TRUSTED_IPS для cscli whitelist
shield_crowdsec_whitelist_ips() {
    local out="" tip
    tip="$(shield_detect_admin_ip 2>/dev/null || true)"
    [ -n "$tip" ] && case "$tip" in *:*) ;; *) out="$out $tip" ;; esac
    for tip in $(shield_conf_get TRUSTED_IPS ""); do
        case "$tip" in *:*) ;; *) out="$out $tip" ;; esac
    done
    echo "$out" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# shield_crowdsec_feedonly_ensure — 2026-11-02 (v1.2.6): crowdsec на VPN-ноде — ТОЛЬКО
# фетчер community blocklist (CAPI), без локальной детекции. Прод: демон парсил
# kern.log/syslog — миллионы строк флода UFW/torrent-blocker в ноль срабатываний
# (cscli metrics: 2.3M+2.3M lines read, 100% unparsed) — чистый расход CPU/RAM/IO.
# Локальные ssh-баны дублируют rate/conn-limit'ы shieldnode на 22 порту. Сами списки
# сообщества не зависят от acquisition: CAPI-синк демона идёт по таймеру независимо,
# shieldnode-blocklist читает локальную БД (cscli decisions list -a) как раньше.
# Идемпотентно: acquis.d/*.yaml генерирует `cscli setup` при установке/обновлении
# пакета — на каждом apply источники вычищаются заново (бэкапы .pre-shieldnode-*).
# НЮАНС (проверено на проде, 2026-11-02): crowdsec не стартует БЕЗ datasource
# («FATAL: no datasource enabled») — поэтому вместо пустого acquisition оставляем
# ОДИН источник-заглушку: пустой файл, в который никто не пишет. Демон доволен,
# парсинга — ноль.
shield_crowdsec_feedonly_ensure() {
    local etc="${SHIELD_CROWDSEC_ETC:-/etc/crowdsec}" changed=0 f stub stub_yaml
    stub="${SHIELD_FEEDONLY_STUB:-/var/log/shieldnode/crowdsec-feedonly.log}"
    stub_yaml="$etc/acquis.d/99-shieldnode-feedonly.yaml"
    [ -d "$etc" ] || return 0
    # стоковый acquis.yaml (источники syslog) — очищаем
    if [ -s "$etc/acquis.yaml" ]; then
        backup "$etc/acquis.yaml" || true
        : > "$etc/acquis.yaml"; changed=1
    fi
    # чужие источники (setup.linux/sshd от cscli setup) — удаляем, нашу заглушку не трогаем
    for f in "$etc"/acquis.d/*.yaml; do
        [ -e "$f" ] || continue
        [ "$f" = "$stub_yaml" ] && continue
        backup "$f" || true
        rm -f "$f"; changed=1
    done
    # источник-заглушка: файл-дырка + yaml-дескриптор (контент фиксирован — перезаписи нет)
    if ! [ -e "$stub_yaml" ]; then
        mkdir -p "${stub%/*}" 2>/dev/null || true
        [ -e "$stub" ] || : > "$stub" 2>/dev/null || true
        printf '# shieldnode: crowdsec работает ТОЛЬКО как фетчер community blocklist (CAPI).\n# Локальные логи парсить не должен — см. lib/crowdsec.sh, shield_crowdsec_feedonly_ensure.\nfilenames:\n  - %s\nlabels:\n  type: syslog\nsource: file\n' "$stub" > "$stub_yaml"
        changed=1
    fi
    # файл-заглушку мог съесть logrotate/чистка — восстанавливаем молча (restart не нужен)
    [ -e "$stub" ] || : > "$stub" 2>/dev/null || true
    if [ "$changed" = "1" ]; then
        if systemctl is-active --quiet crowdsec.service 2>/dev/null; then
            systemctl restart crowdsec.service >/dev/null 2>&1 \
                || warn "crowdsec" "restart после отключения acquisition не удался — journalctl -u crowdsec"
        elif systemctl is-enabled --quiet crowdsec.service 2>/dev/null; then
            # сервис упал/не поднялся (наш прошлый restart с «no datasource») — поднимаем
            systemctl start crowdsec.service >/dev/null 2>&1 \
                || warn "crowdsec" "start crowdsec не удался — journalctl -u crowdsec"
        fi
        log info "crowdsec" "feed-only: локальный парсинг логов отключён (демон тянет только community blocklist по CAPI)"
    else
        log debug "crowdsec" "feed-only: acquisition уже в заглушке — не тронуто"
    fi
    return 0
}

# shield_crowdsec_foreign_bouncer — 2026-11-09 (v1.2.9): имена включённых или запущенных юнитов
# crowdsec-firewall-bouncer (пусто = нет). shieldnode сам заливает решения crowdsec в свой набор;
# отдельный bouncer держит СВОЮ таблицу nft/ipset мимо shieldnode: блокирует второй раз, белый
# список shieldnode (TRUSTED_IPS) и guard unban на него не действуют. Сами не отключаем —
# его мог поставить оператор; только предупреждаем с готовой командой.
shield_crowdsec_foreign_bouncer() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local u out=""
    for u in crowdsec-firewall-bouncer.service cs-firewall-bouncer.service; do
        if systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl is-active --quiet "$u" 2>/dev/null; then
            out="$out $u"
        fi
    done
    printf '%s' "${out# }"
}
# текст предупреждения (общий для apply и health)
shield_crowdsec_foreign_bouncer_msg() { # <юниты через пробел>
    printf 'включён чужой %s — он блокирует адреса своей таблицей мимо shieldnode (двойная блокировка; TRUSTED_IPS и guard unban на него не действуют). Отключить: systemctl disable --now %s' "$1" "$1"
}

# shield_crowdsec_agent_ensure — установить/починить crowdsec-агент (idempotent).
# Только Debian/Ubuntu (apt). Остальное — честный warn с инструкцией.
shield_crowdsec_agent_ensure() {
    command -v cscli >/dev/null 2>&1 || {
        if ! command -v apt-get >/dev/null 2>&1; then
            warn "crowdsec" "agent-режим требует crowdsec (cscli) — автоустановка только на Debian/Ubuntu. Установи вручную: https://docs.crowdsec.net/docs/getting_started/install_crowdsec"
            return 1
        fi
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log info "dry-run" "crowdsec: apt repo + crowdsec package + capi register"
            return 0
        fi
        log info "crowdsec" "установка crowdsec (официальный репозиторий)…"
        # официальный способ: packagecloud-репо (install.crowdsec.net) — то же,
        # что и в старом стеке. БЕЗ curl|bash-пайпа: скачиваем скрипт во
        # временный файл, проверяем, что он непустой, и запускаем файлом.
        local cs_install=""
        cs_install="$(mktemp /tmp/crowdsec-install.XXXXXX)" || {
            warn "crowdsec" "mktemp для install-скрипта не удался — фид не будет работать"
            return 1
        }
        # 2026-09-24 (v1.1.6): официальный скрипт переехал на корень https://install.crowdsec.net
        # (docs: `curl -s https://install.crowdsec.net | sudo sh`); прежний /install.sh отдаёт
        # 403 — agent-режим не ставился НИ НА ОДНОЙ ноде. Корень первым, старый путь — запасной.
        # Скрипт POSIX sh, аргументов не принимает (только подключает репозиторий).
        local url got=""
        for url in https://install.crowdsec.net https://install.crowdsec.net/install.sh; do
            # --retry — разовый сбой сети не отменяет установку агента (v1.1.2)
            if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 -o "$cs_install" "$url" 2>/dev/null \
                && head -1 "$cs_install" | grep -qE '^#!/bin/(ba)?sh'; then
                got="$url"; break
            fi
        done
        if [ -z "$got" ]; then
            rm -f "$cs_install"
            warn "crowdsec" "не удалось скачать install-скрипт crowdsec (install.crowdsec.net: сеть/403?) — фид не будет работать"
            return 1
        fi
        if ! sh "$cs_install" >/dev/null 2>&1; then
            rm -f "$cs_install"
            warn "crowdsec" "не удалось добавить репозиторий crowdsec ($got) — фид не будет работать"
            return 1
        fi
        rm -f "$cs_install"
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y crowdsec >/dev/null 2>&1 || {
            warn "crowdsec" "apt install crowdsec не удался — фид не будет работать"
            return 1
        }
    }

    # RAM-гард: демон ~120-200MB RSS — на 1GB-ноде это осознанный trade-off
    local ram_kb; ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [ "${ram_kb:-0}" -gt 0 ] && [ "$ram_kb" -lt 1048576 ]; then
        warn "crowdsec" "RAM < 1GB (${ram_kb}kB) — crowdsec-демон съест ~150-200MB. Feed-режим (CROWDSEC_MODE=feed) легче, либо осознанно продолжаем"
    fi

    [ "${DRY_RUN:-0}" = "1" ] || shield_crowdsec_lapi_port_fix || true
    # 2026-11-02 (v1.2.6): agent = фетчер community blocklist, НЕ детектор (подробности
    # в шапке shield_crowdsec_feedonly_ensure). Порядок важен: ДО регистрации/whitelist'а,
    # чтобы демон стартовал уже без источников логов.
    [ "${DRY_RUN:-0}" = "1" ] || shield_crowdsec_feedonly_ensure || true

    local fb; fb="$(shield_crowdsec_foreign_bouncer)"
    [ -z "$fb" ] || warn "crowdsec" "$(shield_crowdsec_foreign_bouncer_msg "$fb")"

    # CAPI-регистрация (анонимная — аккаунт консоли НЕ нужен)
    if ! _cscli capi status >/dev/null 2>&1; then
        log info "crowdsec" "CAPI не зарегистрирован — регистрирую анонимно (cscli capi register)…"
        _cscli capi register >/dev/null 2>&1 || warn "crowdsec" "cscli capi register не удался — проверь сеть. Community blocklist появится после регистрации"
    else
        ok "crowdsec" "CAPI зарегистрирован"
    fi

    # whitelist (защита от community-бана своих IP — стек-белый список совпадает
    # с nft-whitelist; дубли по длительности не страшны, cscli игнорирует свежие)
    if [ "$(shield_conf_get CROWDSEC_WHITELIST_SYNC 1)" = "1" ]; then
        local wip decisions
        # 2026-09-23 (v1.1.2): список решений читаем ОДИН раз (был полный листинг на
        # каждый IP; при community-блоклистах это МБ JSON) и ищем без пайпа: `| grep -q`
        # под pipefail давал SIGPIPE (141) на большом выводе -> «не найден» -> дубль.
        decisions="$(_cscli decisions list -o json 2>/dev/null || true)"
        for wip in $(shield_crowdsec_whitelist_ips); do
            # точное вхождение "IP" в кавычках (как прежний grep -F: без regex-wildcards)
            if [[ "$decisions" != *"\"$wip\""* ]]; then
                _cscli decisions add --ip "$wip" --type whitelist --duration 8760h >/dev/null 2>&1 || true
            fi
        done
    fi

    # сервис (не трогаем при DRY_RUN)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        systemctl enable crowdsec.service >/dev/null 2>&1 || true
        systemctl start crowdsec.service >/dev/null 2>&1 || warn "crowdsec" "systemctl start crowdsec не удался — journalctl -u crowdsec"
    fi
    ok "crowdsec" "agent-режим готов (community blocklist по CAPI, чтение локально)"
    return 0
}

# shield_crowdsec_lapi_port_fix — 2026-09-24 (v1.1.6): LAPI crowdsec по умолчанию слушает
# 127.0.0.1:8080 — на VPN-нодах этот порт часто занят (HTTP-inbound/fallback Xray, nginx):
# демон не стартует, cscli не отвечает, список пуст. Если демон не активен и порт LAPI занят
# ЧУЖИМ процессом — переносим LAPI на первый свободный 127.0.0.1:18080..18099 (config.yaml +
# local_api_credentials.yaml, с backup) и перезапускаем crowdsec. Иначе — ничего не делаем.
shield_crowdsec_lapi_port_fix() {
    local etc="${SHIELD_CROWDSEC_ETC:-/etc/crowdsec}" port np cand
    [ -f "$etc/config.yaml" ] && [ -f "$etc/local_api_credentials.yaml" ] || return 0
    systemctl is-active --quiet crowdsec.service 2>/dev/null && return 0
    port="$(sed -nE 's/^[[:space:]]*listen_uri:[[:space:]]*"?127\.0\.0\.1:([0-9]+)"?.*/\1/p' "$etc/config.yaml" | head -1)"
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    _cs_port_busy() { { ss -Hltnp "sport = :$1" 2>/dev/null || true; } | grep -v '"crowdsec"' | grep -q .; }
    _cs_port_busy "$port" || return 0
    np=""
    for cand in $(seq 18080 18099); do _cs_port_busy "$cand" || { np="$cand"; break; }; done
    [ -n "$np" ] || { warn "crowdsec" "LAPI-порт $port занят, свободного в 18080-18099 нет — crowdsec не запустится"; return 1; }
    backup "$etc/config.yaml"; backup "$etc/local_api_credentials.yaml"
    sed -i -E "s/^([[:space:]]*listen_uri:[[:space:]]*\"?)127\.0\.0\.1:$port/\1127.0.0.1:$np/" "$etc/config.yaml"
    sed -i -E "s#^(url:[[:space:]]*\"?http://127\.0\.0\.1:)$port#\1$np#" "$etc/local_api_credentials.yaml"
    warn "crowdsec" "LAPI 127.0.0.1:$port занят другим процессом — перенесён на 127.0.0.1:$np"
    systemctl restart crowdsec.service >/dev/null 2>&1 || warn "crowdsec" "restart crowdsec после смены порта не удался — journalctl -u crowdsec"
    return 0
}

# shield_crowdsec_agent_status — однострочник для status/guard
shield_crowdsec_agent_status() {
    command -v cscli >/dev/null 2>&1 || { echo "agent: not-installed"; return 0; }
    local capi="no" n="?"
    _cscli capi status >/dev/null 2>&1 && capi="yes"
    # grep -c уже печатает "0" при 0 совпадений (rc=1) — "|| echo 0" дал бы "0\n0"
    n="$(_cscli decisions list -t ban -o json 2>/dev/null | grep -c '"value"' 2>/dev/null || true)"
    local act; act="$(systemctl is-active crowdsec.service 2>/dev/null || echo inactive)"
    echo "agent: capi=$capi decisions=$n service=$act"
}
