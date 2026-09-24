#!/bin/bash
# node — lib/storage.sh: §17 storage-hardening — проверенные на старой ветке твики:
#   THP -> madvise, I/O scheduler=none для SSD/virtio, noatime + снятие discard
#   + weekly fstrim (вместо sync-TRIM на каждый delete).
# Reversibility-first: runtime-значения — в реестре (kinds sysfs/mount), файлы —
# через node_persist (backup + манифест). В контейнерах (overlay) — пропуск.
set -euo pipefail

node_storage_plan() {
    log info "storage" "plan: thp=$(node_conf_get HARDEN_THP 1) sched_none=$(node_conf_get HARDEN_SCHED_NONE 1) noatime=$(node_conf_get HARDEN_NOATIME 1)"
}

node_storage_apply() {
    local rootfstype
    rootfstype="$(findmnt -no FSTYPE / 2>/dev/null || echo '?')"
    if [ "$rootfstype" = "overlay" ]; then
        log info "storage" "контейнер (overlay) — storage-hardening пропущен"
        return 0
    fi

    # --- THP -> madvise (проверенный дефолт старой ветки) ---
    if [ "$(node_conf_get HARDEN_THP 1)" = "1" ]; then
        local thp=/sys/kernel/mm/transparent_hugepage/enabled orig
        if [ -w "$thp" ]; then
            orig="$(sed -E 's/.*\[(.*)\].*/\1/' "$thp" 2>/dev/null || echo '?')"
            if [ "$orig" != "madvise" ] && printf 'madvise' > "$thp" 2>/dev/null; then
                node_rt_record "-" sysfs "kernel/mm/transparent_hugepage/enabled" "$orig"
                ok "storage" "THP: $orig -> madvise (runtime; restore при rollback)"
            fi
        else
            log info "storage" "THP sysfs недоступен — пропуск"
        fi
        {
            echo "# node: THP=madvise (boot-persist, managed by node)"
            echo "w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise"
        } | node_persist /etc/tmpfiles.d/node-thp-madvise.conf
    fi

    # --- I/O scheduler=none для non-rotational (гипервизор уже шедулит) ---
    if [ "$(node_conf_get HARDEN_SCHED_NONE 1)" = "1" ]; then
        local d dev rot orig applied=0
        for d in /sys/block/*; do
            dev="$(basename "$d")"
            case "$dev" in loop*|ram*|zram*|nbd*) continue ;; esac
            [ -f "$d/queue/scheduler" ] || continue
            rot="$(cat "$d/queue/rotational" 2>/dev/null || echo 1)"
            [ "$rot" = "0" ] || continue
            grep -qw none "$d/queue/scheduler" || continue
            grep -q '\[none\]' "$d/queue/scheduler" && continue
            orig="$(sed -E 's/.*\[(.*)\].*/\1/' "$d/queue/scheduler" 2>/dev/null || echo '?')"
            if printf 'none' > "$d/queue/scheduler" 2>/dev/null; then
                node_rt_record "-" sysfs "block/$dev/queue/scheduler" "$orig"
                applied=$((applied + 1))
            fi
        done
        [ "$applied" -gt 0 ] && ok "storage" "scheduler=none на $applied non-rotational дисках"
        # оба правила портированы из старого продакшен-стека (60-vpn-io-scheduler.rules,
        # v5.11.0/v5.12.1). Раньше здесь был паттерн на разделы sdN — он матчил
        # ТОЛЬКО разделы (у разделов нет queue/scheduler) и не покрывал
        # vd*/xvd*/nvme* — правило было мёртвым.
        # Правило 1: virtio (vd/xvd) — без проверки rotational (бывает misreport=1).
        # Правило 2: sd/nvme/mmcblk — только rotational==0 (реальные HDD не трогаем).
        # Guard ATTR{queue/scheduler}=="*none*": только если none поддерживается.
        {
            echo "# node: I/O scheduler=none для SSD/virtio дисков VPS (managed by node)"
            echo "# Гипервизор делает scheduling на хосте — гостевая очередь лишняя."
            echo 'ACTION=="add|change", KERNEL=="vd[a-z]|xvd[a-z]", \'
            echo '    ATTR{queue/scheduler}=="*none*", \'
            echo '    ATTR{queue/scheduler}="none"'
            echo 'ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-9]n[0-9]|mmcblk[0-9]", \'
            echo '    ATTR{queue/rotational}=="0", ATTR{queue/scheduler}=="*none*", \'
            echo '    ATTR{queue/scheduler}="none"'
        } | node_persist /etc/udev/rules.d/99-node-io-scheduler.rules
    fi

    # --- noatime + снятие discard + weekly fstrim ---
    if [ "$(node_conf_get HARDEN_NOATIME 1)" = "1" ]; then
        node_noatime_apply
    fi
}

node_noatime_apply() {
    local fstab="${NODE_FSTAB:-/etc/fstab}"   # override для тестов
    if [ ! -f "$fstab" ]; then
        log info "storage" "fstab отсутствует — noatime пропущен"
        return 0
    fi
    # Трансформация: discard снимаем; noatime добавляем, если среди опций нет
    # noatime/nodiratime — включая запись 'defaults' (раньше ранний выход
    # срабатывал только при литеральных relatime/atime/discard, и 'defaults'
    # давал молчаливый no-op). swap не трогаем.
    local tmp; tmp="$(mktemp)"
    awk '
        /^[[:space:]]*#/ { print; next }
        NF < 4           { print; next }
        $3 == "swap"     { print; next }
        {
            o=$4
            # discard: убираем с ведущей запятой / первым / единственным
            gsub(/,discard/, "", o)
            sub(/^discard,/, "", o)
            sub(/^discard$/, "", o)
            sub(/^,/, "", o); sub(/,$/, "", o)
            if (o=="") o="defaults"
            if (o !~ /(^|,)(noatime|nodiratime)(,|$)/) {
                if (o ~ /(^|,)(relatime|atime)(,|$)/) sub(/(relatime|atime)/, "noatime", o)
                else o = o ",noatime"
            }
            $4=o
            print
        }
    ' "$fstab" > "$tmp"
    # нечего менять — не трогаем файл вообще (ни backup, ни записи в манифест)
    if cmp -s "$tmp" "$fstab"; then
        rm -f "$tmp"
        log info "storage" "fstab: уже noatime и без discard — изменений не требуется"
        return 0
    fi
    # валидация нового fstab ДО записи (битый fstab = незагружаемая система);
    # findmnt есть не везде — если команды нет, пропускаем проверку
    if command -v findmnt >/dev/null 2>&1; then
        if ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
            log error "storage" "findmnt --verify отверг новый fstab:"
            findmnt --verify --tab-file "$tmp" 2>&1 | head -10 | while read -r l; do log error "storage" "  $l"; done
            rm -f "$tmp"
            die "storage: трансформированный fstab не прошёл findmnt --verify — НЕ применяем (оригинал не тронут)"
        fi
    fi
    node_persist "$fstab" < "$tmp"
    rm -f "$tmp"
    ok "storage" "fstab: noatime везде (включая defaults), discard снят (backup сохранён)"

    # runtime remount / с захватом текущих опций (откат вернёт именно их)
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log info "dry-run" "storage: would remount / noatime + enable fstrim.timer"
        return 0
    fi
    local opts
    opts="$(findmnt -no OPTIONS / 2>/dev/null || echo '?')"
    if [ "$opts" != "?" ] && ! grep -qE '(^|,)noatime(,|$)' <<<"$opts"; then
        if mount -o remount,noatime / >/dev/null 2>&1; then
            node_rt_record "/" mount "/" "$opts"
            ok "storage" "/ remounted noatime (orig: $opts)"
        else
            warn "storage" "runtime remount / не удался — noatime применится после reboot"
        fi
    fi
    # weekly fstrim вместо sync-discard
    node_svc_enable fstrim.timer

    # если / НЕ описан в fstab (часть cloud-образов) — boot-persist через oneshot
    if ! grep -vE '^[[:space:]]*#' "$fstab" | awk '{print $2}' | grep -qx '/'; then
        log info "storage" "/ не описан в fstab — добавляю boot-persist remount"
        {
            echo "[Unit]"
            echo "Description=node noatime remount (managed by node)"
            echo ""
            echo "[Service]"
            echo "Type=oneshot"
            echo "RemainAfterExit=yes"
            echo "ExecStart=/bin/mount -o remount,noatime /"
            echo ""
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } | node_persist /etc/systemd/system/node-noatime-remount.service
        if [ "${DRY_RUN:-0}" != "1" ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable node-noatime-remount.service >/dev/null 2>&1 || true
        fi
    fi
}
