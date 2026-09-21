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
        {
            echo "# node: I/O scheduler=none для non-rotational (managed by node)"
            echo 'ACTION=="add|change", KERNEL=="sd*[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"'
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
    # меняем ли что-то? relatime/atime -> noatime, discard -> убрать (swap не трогаем)
    if ! grep -vE '^[[:space:]]*#' "$fstab" | awk '$3!="swap" {print $4}' | grep -qE '(^|,)(relatime|atime|discard)(,|$)'; then
        log info "storage" "fstab уже без relatime/atime/discard — noatime не нужен"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    awk '
        /^[[:space:]]*#/ { print; next }
        $3 == "swap"     { print; next }
        $4 ~ /discard/   {
            o=$4
            gsub(/,discard/, "", o)   # средний/последний: убираем с ведущей запятой
            sub(/^discard,/, "", o)   # первым с запятой справа
            sub(/^discard$/, "", o)   # единственный
            sub(/^,/, "", o); sub(/,$/, "", o)
            if (o=="") o="defaults"
            $4=o
        }
        $4 ~ /(^|,)(relatime|atime)(,|$)/ { sub(/(relatime|atime)/, "noatime", $4) }
        { print }
    ' "$fstab" > "$tmp"
    node_persist "$fstab" < "$tmp"
    rm -f "$tmp"
    ok "storage" "fstab: noatime вместо relatime/atime, discard снят (backup сохранён)"

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
