#!/bin/bash
# node — lib/sysctl.sh: сбор ключей от модулей, валидация владения, запись, применение.
# Запрещено: sysctl --system. Применяем только свои файлы через sysctl -p.
set -euo pipefail

# Имена с суффиксом 99-zN выбраны не случайно: sysctl.d применяет файлы в
# лексикографическом порядке, а штатные дистрибутивные/облачные файлы
# (99-sysctl.conf на Debian, 99-cloudimg-*.conf на Ubuntu cloud images)
# иначе перекрывали бы наши значения. 'z' идёт после 's'/'c', поэтому наши
# файлы применяются последними и побеждают. Админ всё ещё может перекрыть
# нас своим файлом с суффиксом выше (например 99-z9-*.conf).
NODE_SYSCTL_BASE="/etc/sysctl.d/99-z0-node-base.conf"
NODE_SYSCTL_DATAPATH="/etc/sysctl.d/99-z1-node-datapath.conf"
NODE_SYSCTL_CONNTRACK="/etc/sysctl.d/99-z2-node-conntrack.conf"
NODE_SYSCTL_IPV6="/etc/sysctl.d/99-z3-node-ipv6.conf"
NODE_SYSCTL_MEM="/etc/sysctl.d/99-z4-node-vm.conf"
# Единый список наших sysctl-файлов (запись/применение/self-test итерируют его)
NODE_SYSCTL_FILES=("$NODE_SYSCTL_BASE" "$NODE_SYSCTL_DATAPATH" "$NODE_SYSCTL_CONNTRACK" "$NODE_SYSCTL_IPV6" "$NODE_SYSCTL_MEM")

# План: файлы со строками "key<TAB>value<TAB>file"
NODE_PLAN_FILE=""

node_sysctl_plan_init() {
    # 2026-09-24 (v1.1.6): повторный init (status/rt-reapply) — тот же файл, не новый
    # mktemp; удаляется на выходе (_node_tmp_cleanup, config.sh)
    if [ -z "${NODE_PLAN_FILE:-}" ] || [ ! -f "$NODE_PLAN_FILE" ]; then NODE_PLAN_FILE="$(mktemp)"; fi
    : > "$NODE_PLAN_FILE"
}

# node_sysctl_add <file> <key> <value>
node_sysctl_add() {
    local file="$1" key="$2" value="$3"
    # 2026-09-23: значение из конфига не валидировалось — мусор (TCP_SOMAXCONN=abc)
    # попадал в файл, sysctl -p падал и die оставлял систему «частично применённой».
    # Все ключи node — числа (в т.ч. через пробел); токены (bbr, fq) — только
    # у ключей, которые их принимают.
    local ok_val=0
    [[ "$value" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]] && ok_val=1
    case "$key" in net.ipv4.tcp_congestion_control|net.core.default_qdisc)
        [[ "$value" =~ ^[a-z][a-z0-9_]*$ ]] && ok_val=1 ;;
    # 2026-09-24 (v1.1.7): список портов/диапазонов через запятую (ip-sysctl.rst)
    net.ipv4.ip_local_reserved_ports)
        [[ "$value" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] && ok_val=1 ;; esac
    if [ "$ok_val" != 1 ]; then
        warn "sysctl" "невалидное значение $key='$value' (конфиг?) — ключ пропущен, текущее значение ядра оставлено"
        return 0
    fi
    validate_key_ownership "$key" || { warn "sysctl" "skip foreign-owned key: $key"; return 0; }
    printf '%s\t%s\t%s\n' "$key" "$value" "$file" >> "$NODE_PLAN_FILE"
}

# node_sysctl_add_probed <file> <key> <value> — добавить только если ключ существует
# в текущем ядре (новые/удалённые sysctl между версиями ядер не роняют apply).
node_sysctl_add_probed() {
    local file="$1" key="$2" value="$3"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        sysctl -n "$key" >/dev/null 2>&1 || { log warn "sysctl" "ключ $2 отсутствует в ядре $(uname -r) — пропуск"; return 0; }
    fi
    node_sysctl_add "$file" "$key" "$value"
}

# node_sysctl_add_writable <file> <key> <value> — как _probed, плюс проверка, что
# ключ ЗАПИСЫВАЕМ: пишем текущее значение обратно (no-op). Ловит RO /proc/sys
# (LXC/OpenVZ) до записи файла — иначе sysctl -p уронил бы весь apply.
node_sysctl_add_writable() {
    local file="$1" key="$2" value="$3" cur
    if [ "${DRY_RUN:-0}" != "1" ] && [ "${MODE:-}" != "status" ]; then   # status — read-only
        cur="$(sysctl -n "$key" 2>/dev/null)" || { log warn "sysctl" "ключ $key отсутствует — пропуск"; return 0; }
        sysctl -w "$key=$(printf '%s' "$cur" | tr '\t' ' ')" >/dev/null 2>&1 \
            || { log warn "sysctl" "ключ $key не записываемый (контейнер?) — пропуск"; return 0; }
    fi
    node_sysctl_add "$file" "$key" "$value"
}

# 2026-09-24 (v1.1.6): исходное (до node) значение ключа — из реестра sysctl-orig,
# иначе текущее из /proc/sys (NODE_PROC_ROOT — override фикстуры тестов)
node_sysctl_baseline() {
    local key="$1" v=""
    [ -f "$NODE_STATE_DIR/sysctl-orig.tsv" ] && v="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$NODE_STATE_DIR/sysctl-orig.tsv")"
    [ -n "$v" ] || v="$(cat "${NODE_PROC_ROOT:-/proc}/sys/${key//.//}" 2>/dev/null || true)"
    printf '%s' "$v"
}

# node_sysctl_restore_dropped — 2026-09-24 (v1.1.7): ключи, которыми node владел на прошлом
# apply (owner-keys.txt переписывается только в конце apply), но которых больше нет в плане,
# получают исходное (до node) runtime-значение из реестра sysctl-orig. Раньше удалённая из
# плана настройка (выключенная опция, пересмотренный дефолт) жила в ядре до reboot/rollback.
# Ключ, ещё заданный оставшимся файлом node, не трогаем. Заменяет разовый
# node_filemax_runtime_restore (v1.1.6).
node_sysctl_restore_dropped() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    local owner="$NODE_STATE_DIR/owner-keys.txt" reg="$NODE_STATE_DIR/sysctl-orig.tsv" k orig cur kre n=0
    [ -s "$owner" ] && [ -s "$reg" ] || return 0
    while read -r k; do
        [ -n "$k" ] || continue
        awk -F'\t' -v k="$k" '$1 == k { f = 1 } END { exit !f }' "$NODE_PLAN_FILE" 2>/dev/null && continue
        case "$k" in net.ipv6.conf.*.disable_ipv6) continue ;; esac   # v1.2.0: инвариант (lib/ipv6.sh)
        kre="${k//./\\.}"
        grep -rqsE "^${kre}[[:space:]]*=" /etc/sysctl.d/99-z[01234]-node-*.conf 2>/dev/null && continue
        # 2026-09-24 (v1.1.7): пустое исходное — тоже значение (ip_local_reserved_ports «» до node)
        awk -F'\t' -v k="$k" '$1 == k { f = 1 } END { exit !f }' "$reg" || continue
        orig="$(awk -F'\t' -v k="$k" '$1 == k { print $2; exit }' "$reg")"
        cur="$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ' || true)"
        [ "$cur" = "$orig" ] && continue
        if sysctl -w "$k=$orig" >/dev/null 2>&1; then
            log info "sysctl" "ключ $k больше не в плане node — возвращено исходное: $cur -> $orig"
            n=$((n + 1))
        else
            # 2026-09-25 (v1.1.8): исходное записано под другим ядром (6.8: usecs 2000; XanMod
            # HZ=250 требует >= 8000) — ядро отвергает, оставляем текущее и говорим об этом
            log info "sysctl" "ключ $k: исходное '$orig' ядро $(uname -r) не принимает (записано под другим ядром?) — оставлено $cur"
        fi
    done < "$owner"
    [ "$n" -gt 0 ] && ok "sysctl" "исходные значения возвращены для $n ключ(ей), выпавших из плана"
    return 0
}

node_sysctl_write() {
    local file key value
    for file in "${NODE_SYSCTL_FILES[@]}"; do
        if [ -s "$NODE_PLAN_FILE" ] && grep -F "$file" "$NODE_PLAN_FILE" > /dev/null 2>&1; then
            {
                echo "# node — $(date -u '+%Y-%m-%d') — managed by node, do not edit"
                grep -F "$file" "$NODE_PLAN_FILE" | sort -u -t$'\t' -k1,1 | \
                    awk -F'\t' '{printf "%s = %s\n", $1, $2}'
            } | node_persist "$file"
        elif [ -f "$file" ]; then
            # оператор выключил фичу (в плане ключей файла нет), а наш старый
            # 99-z*-node-*.conf остался на диске — удаляем, иначе устаревшие
            # значения молча продолжают действовать. backup — перед удалением.
            if [ "${DRY_RUN:-0}" = "1" ]; then
                log info "dry-run" "would remove stale $file (нет в текущем плане)"
            else
                backup "$file"
                rm -f "$file"
                log info "sysctl" "удалён устаревший $file (ключей нет в плане; backup сохранён)"
            fi
        fi
    done
}

# ВАЖНО: node_persist здесь НЕ определяется. Делегат с записью в манифест
# живёт в apply.sh; fallback — в persist.sh. Локальное определение здесь
# (баг 2026-09: манифест всегда пуст) перекрывало делегат, т.к. этот файл
# source'ится внутри node_apply ПОСЛЕ apply.sh, — rollback/uninstall ломались.

# node_sysctl_orig_record — исходные (до node) runtime-значения ключей плана.
# Баг 2026-09-23: rollback брал baseline из ПОСЛЕДНЕГО снапшота detect, а он
# после повторного apply содержит уже значения node (и первый снапшот не знает
# большинства ключей) — runtime после отката оставался «оптимизированным».
# Реестр пишется ОДИН раз на ключ; ключи, уже бывшие под node до v1.1.1
# (есть в owner-keys.txt), не пишем — их текущее значение не исходное (legacy).
node_sysctl_orig_record() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    local reg="$NODE_STATE_DIR/sysctl-orig.tsv" owner="$NODE_STATE_DIR/owner-keys.txt" k v _f
    mkdir -p "$NODE_STATE_DIR"; touch "$reg"
    while IFS=$'\t' read -r k v _f; do
        [ -n "$k" ] || continue
        case "$k" in net.ipv6.conf.*.disable_ipv6) continue ;; esac   # v1.2.0: откатывать нечего
        if awk -F'\t' -v k="$k" '$1==k{f=1} END{exit !f}' "$reg"; then continue; fi
        if [ -f "$owner" ] && grep -qxF -- "$k" "$owner"; then continue; fi
        v="$(sysctl -n "$k" 2>/dev/null)" || continue
        printf '%s\t%s\n' "$k" "$(printf '%s' "$v" | tr '\t' ' ')" >> "$reg"
        # 2026-09-24 (v1.1.5): vm.dirty_*_bytes=0 — ядро было в ratio-режиме; вернуть 0 в
        # *_bytes нельзя (EINVAL), вернуть режим можно только записью *_ratio — пишем и его
        case "$k" in
            vm.dirty_bytes|vm.dirty_background_bytes)
                local rk="${k%_bytes}_ratio" rv
                if [ "$v" = "0" ] && ! awk -F'\t' -v k="$rk" '$1==k{f=1} END{exit !f}' "$reg"; then
                    rv="$(sysctl -n "$rk" 2>/dev/null)" && printf '%s\t%s\n' "$rk" "$rv" >> "$reg"
                fi ;;
        esac
    done < "$NODE_PLAN_FILE"
}

node_sysctl_apply() {
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "sysctl -p (skipped)"; return 0; }
    node_sysctl_orig_record
    local f
    for f in "${NODE_SYSCTL_FILES[@]}"; do
        [ -f "$f" ] || continue
        sysctl -p "$f" >/dev/null || die "sysctl -p failed: $f (система в частично применённом состоянии — выполни: bash $NODE_DIR/install.sh rollback)"
        log info "sysctl" "applied $f"
    done
}

# Список наших ключей -> реестр владения
node_sysctl_owner_dump() {
    [ -f "$NODE_PLAN_FILE" ] && cut -f1 "$NODE_PLAN_FILE" | sort -u > "$NODE_STATE_DIR/owner-keys.txt" || true
    chmod 0644 "$NODE_STATE_DIR/owner-keys.txt" 2>/dev/null || true
}
