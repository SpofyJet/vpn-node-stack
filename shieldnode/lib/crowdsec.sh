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
        local arch="amd64" cs_install=""
        [ "$(uname -m)" = "aarch64" ] && arch="arm64"
        cs_install="$(mktemp /tmp/crowdsec-install.XXXXXX)" || {
            warn "crowdsec" "mktemp для install-скрипта не удался — фид не будет работать"
            return 1
        }
        if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$cs_install" \
                https://install.crowdsec.net/install.sh 2>/dev/null || [ ! -s "$cs_install" ]; then
            rm -f "$cs_install"
            warn "crowdsec" "не удалось скачать install-скрипт crowdsec (сеть/права?) — фид не будет работать"
            return 1
        fi
        if ! bash "$cs_install" -i -a "$arch" >/dev/null 2>&1; then
            rm -f "$cs_install"
            warn "crowdsec" "не удалось добавить репозиторий crowdsec — фид не будет работать"
            return 1
        fi
        rm -f "$cs_install"
        DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec >/dev/null 2>&1 || {
            warn "crowdsec" "apt install crowdsec не удался — фид не будет работать"
            return 1
        }
    }

    # RAM-гард: демон ~120-200MB RSS — на 1GB-ноде это осознанный trade-off
    local ram_kb; ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [ "${ram_kb:-0}" -gt 0 ] && [ "$ram_kb" -lt 1048576 ]; then
        warn "crowdsec" "RAM < 1GB (${ram_kb}kB) — crowdsec-демон съест ~150-200MB. Feed-режим (CROWDSEC_MODE=feed) легче, либо осознанно продолжаем"
    fi

    # CAPI-регистрация (анонимная — аккаунт консоли НЕ нужен)
    if ! cscli capi status >/dev/null 2>&1; then
        log info "crowdsec" "CAPI не зарегистрирован — регистрирую анонимно (cscli capi register)…"
        cscli capi register >/dev/null 2>&1 || warn "crowdsec" "cscli capi register не удался — проверь сеть. Community blocklist появится после регистрации"
    else
        ok "crowdsec" "CAPI зарегистрирован"
    fi

    # whitelist (защита от community-бана своих IP — стек-белый список совпадает
    # с nft-whitelist; дубли по длительности не страшны, cscli игнорирует свежие)
    if [ "$(shield_conf_get CROWDSEC_WHITELIST_SYNC 1)" = "1" ]; then
        local wip
        for wip in $(shield_crowdsec_whitelist_ips); do
            # grep -F: точки в IP — regex-wildcards, без -F ложные совпадения
            if ! cscli decisions list -o json 2>/dev/null | grep -qF "\"$wip\""; then
                cscli decisions add --ip "$wip" --type whitelist --duration 8760h >/dev/null 2>&1 || true
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

# shield_crowdsec_agent_status — однострочник для status/guard
shield_crowdsec_agent_status() {
    command -v cscli >/dev/null 2>&1 || { echo "agent: not-installed"; return 0; }
    local capi="no" n="?"
    cscli capi status >/dev/null 2>&1 && capi="yes"
    # grep -c уже печатает "0" при 0 совпадений (rc=1) — "|| echo 0" дал бы "0\n0"
    n="$(cscli decisions list -t ban -o json 2>/dev/null | grep -c '"value"' 2>/dev/null || true)"
    local act; act="$(systemctl is-active crowdsec.service 2>/dev/null || echo inactive)"
    echo "agent: capi=$capi decisions=$n service=$act"
}
