#!/bin/bash
# node — lib/kernel.sh: BBR + (опц.) XanMod-ядро. Требование: авто-BBR когда ядро
# умеет; замена ядра — только явным ENABLE_XANMOD=1 (одна строчка в конфиге).
# Никогда не ребутаем сами; откат ядра — restore grub-файла + purge (документирован).
set -euo pipefail

XANMOD_REPO_LIST=/etc/apt/sources.list.d/xanmod-kernel.list
XANMOD_GPG=/etc/apt/trusted.gpg.d/xanmod-kpg.gpg

node_kernel_is_xanmod() { uname -r | grep -qi xanmod; }

# node_kernel_version_ge — сравнение версии текущего ядра: node_kernel_version_ge 6 15
# Разбирает uname -r (форматы "6.15.2", "6.15.2-1-xanmod1", "5.15.0-105-generic").
node_kernel_version_ge() {
    local want_maj="$1" want_min="$2" cur_maj cur_min
    cur_maj="$(uname -r | cut -d. -f1)"
    cur_min="$(uname -r | cut -d. -f2 | cut -d- -f1)"
    [[ "$cur_maj" =~ ^[0-9]+$ ]] || return 1
    [[ "$cur_min" =~ ^[0-9]+$ ]] || return 1
    if [ "$cur_maj" -gt "$want_maj" ]; then return 0; fi
    [ "$cur_maj" -eq "$want_maj" ] && [ "$cur_min" -ge "$want_min" ]
}

# node_bbr_generation — "3" если ядро >= 6.15 (BBRv3 в мейнлайне), иначе "1".
# XanMod также шлёт BBRv3, но здесь речь только о stock-ядре.
node_bbr_generation() {
    node_kernel_version_ge 6 15 && echo 3 || echo 1
}

# node_bbr_available — 0 если модуль tcp_bbr загружен/загружаем и доступен.
node_bbr_available() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr
}

node_bbr_active() {
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]
}

# node_bbr_plan — добавить BBR в sysctl-план, если ядро умеет (иначе warn, не ломаем).
node_bbr_plan() {
    [ "$(node_conf_get ENABLE_BBR 1)" = "1" ] || { log info "kernel" "ENABLE_BBR=0 — пропуск"; return 0; }
    # На stock-ядрах модуль tcp_bbr часто НЕ загружен — тогда bbr отсутствует в
    # tcp_available_congestion_control и BBR молча не включался. Как в старом
    # стеке: сначала modprobe, потом проверка доступности.
    if [ "${DRY_RUN:-0}" != "1" ] && command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if node_bbr_available; then
        node_sysctl_add "$NODE_SYSCTL_DATAPATH" net.ipv4.tcp_congestion_control bbr
        node_sysctl_add "$NODE_SYSCTL_DATAPATH" net.core.default_qdisc fq
        # автозагрузка модуля при boot — иначе после reboot sysctl-файл
        # применяется до загрузки tcp_bbr и congestion_control=bbr не встаёт
        # (как nf_conntrack через /etc/modules-load.d)
        if declare -F node_persist >/dev/null 2>&1; then
            {
                echo "# node — force-load tcp_bbr (BBR congestion control at boot), managed by node"
                echo "tcp_bbr"
            } | node_persist /etc/modules-load.d/tcp_bbr.conf
        fi
        if [ "$(node_bbr_generation)" = "3" ]; then
            log info "kernel" "BBRv3 доступен (мейнлайн >=6.15) — план: congestion_control=bbr, qdisc=fq"
        else
            log info "kernel" "BBR v1 доступен — план: congestion_control=bbr, qdisc=fq (BBRv3: ядро >=6.15 или ENABLE_XANMOD=1 + reboot)"
        fi
    else
        if node_kernel_version_ge 6 15; then
            log warn "kernel" "ядро >=6.15, но модуль tcp_bbr недоступен — проверь конфигурацию ядра (CONFIG_TCP_CONG_BBR)"
        else
            log warn "kernel" "BBR недоступен в текущем ядре ($(uname -r)). XanMod: ENABLE_XANMOD=1 в /etc/node/node.conf, затем reboot и повторный apply (BBRv3 с ядра 6.15 — XanMod не нужен)."
        fi
    fi
}

# node_cpu_xlevel — x86-64 уровень CPU: v3/v2/v1 (для выбора пакета XanMod).
node_cpu_xlevel() {
    local flags; flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)"
    if grep -qw avx2 <<<"$flags" && grep -qw bmi2 <<<"$flags" && grep -qw fma <<<"$flags" && grep -qw avx <<<"$flags"; then
        echo v3
    elif grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags"; then
        echo v2
    else
        echo v1
    fi
}

node_xanmod_supported() {
    [ "$(uname -m)" = "x86_64" ] || return 1
    if command -v apt-get >/dev/null 2>&1 && [ -r /etc/os-release ]; then
        grep -qiE 'debian|ubuntu' /etc/os-release
    else
        return 1
    fi
}

# node_xanmod_pkg — имя метапакета по ветке и CPU-уровню.
# Ветки XanMod: lts (база LTS-апстрима, стабильные бэкпорты — для прод-нод,
# дефолт) и main (rolling mainline — свежие фичи, окно регрессий на каждом
# мажоре; только для тестовых нод). Патчсет (BBRv3, TCP collapse, full-cone
# NAT) у веток общий — разница в базе.
node_xanmod_pkg() {
    local branch="$1" level="$2"
    case "$branch" in
        lts)  printf 'linux-xanmod-lts-x64%s' "$level" ;;
        main) printf 'linux-xanmod-x64%s' "$level" ;;
        *)    return 1 ;;
    esac
}

# node_xanmod_install — установка ядра XanMod (Debian/Ubuntu, apt).
# Безопасность: backup grub-файла, pin-файл apt, БЕЗ авто-ребута; после ребута
# повторный `node apply` доведёт BBR (модуль в комплекте ядра).
node_xanmod_install() {
    [ "$(node_conf_get ENABLE_XANMOD 0)" = "1" ] || return 0
    node_kernel_is_xanmod && { log info "kernel" "ядро уже XanMod ($(uname -r))"; return 0; }
    node_xanmod_supported || die "XanMod поддерживается только на Debian/Ubuntu x86_64 (тут: $(uname -m), $(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo '?'))"

    local branch
    branch="$(node_conf_get XANMOD_BRANCH lts)"
    case "$branch" in lts|main) : ;; *) die "XANMOD_BRANCH: lts|main, получено '$branch'" ;; esac

    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "would install XanMod kernel (branch $branch, variant $(node_conf_get XANMOD_VARIANT auto))"; return 0; }

    local level pkg
    level="$(node_conf_get XANMOD_VARIANT "")"; [ -z "$level" ] && level="$(node_cpu_xlevel)"
    case "$level" in v1|v2|v3) : ;; *) die "XANMOD_VARIANT: v1|v2|v3, получено '$level'" ;; esac
    pkg="$(node_xanmod_pkg "$branch" "$level")"

    require_root
    log info "kernel" "установка $pkg (ветка $branch, CPU level $level)…"
    backup /etc/default/grub
    # репозиторий + ключ (backup + atomic + манифест — единые правила проекта)
    declare -F node_origin_record >/dev/null 2>&1 && node_origin_record "$XANMOD_REPO_LIST"   # 2026-09-23: реестр для rollback
    backup "$XANMOD_REPO_LIST"
    printf 'deb http://deb.xanmod.org releases main\n' | atomic_write "$XANMOD_REPO_LIST"
    node_manifest_record "$XANMOD_REPO_LIST"
    if command -v wget >/dev/null 2>&1; then
        # gpg --dearmor при обрыве сети выдавал ПУСТОЙ keyring (apt потом
        # отвергал репозиторий с невнятной ошибкой). Через temp + проверка -s;
        # при фейле — rm + die, пустой keyring не оставляем.
        local ktmp; ktmp="$(mktemp)"
        if wget -qO- https://dl.xanmod.org/gpg.key 2>/dev/null | gpg --dearmor > "$ktmp" 2>/dev/null && [ -s "$ktmp" ]; then
            declare -F node_origin_record >/dev/null 2>&1 && node_origin_record "$XANMOD_GPG"
            atomic_write "$XANMOD_GPG" < "$ktmp"
            node_manifest_record "$XANMOD_GPG"
            rm -f "$ktmp"
        else
            rm -f "$ktmp" "$XANMOD_GPG"
            die "kernel: gpg key import failed (сеть/gpg?) — XanMod не устанавливаем, пустой keyring удалён"
        fi
    else
        log warn "kernel" "wget отсутствует — добавьте ключ вручную: https://dl.xanmod.org/gpg.key"
    fi
    # Сетевой сбой здесь НЕ убивает весь apply (счётчик шага: apply доработает,
    # но итоговая сводка назовёт xanmod_install среди упавших — return 1, не 0:
    # иначе сбой молча исчезал из консольного вывода, оставаясь только warn'ом
    # в логе. С ноды в РФ deb.xanmod.org периодически недоступен — реальный
    # сценарий, а не теория). Повторный apply доустанавливает.
    # 2026-09-23 (v1.1.2): Acquire::Retries — разовый сетевой сбой зеркала не валит шаг
    apt-get -o Acquire::Retries=3 update -qq || { log warn "kernel" "apt update failed (deb.xanmod.org недоступен?) — XanMod пропущен, повторите apply после исправления сети"; return 1; }
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends "$pkg" || { log warn "kernel" "apt install $pkg failed — повторите apply"; return 1; }
    # pin: держим ядро при autoremove (через node_persist — backup + манифест,
    # а не printf > напрямую мимо единой точки записи)
    if declare -F node_persist >/dev/null 2>&1; then
        printf '%s\n' 'Package: linux-image*xanmod*' 'Pin: release o=XanMod' 'Pin-Priority: 1001' | node_persist /etc/apt/preferences.d/xanmod-kernel
    else
        printf '%s\n' 'Package: linux-image*xanmod*' 'Pin: release o=XanMod' 'Pin-Priority: 1001' | atomic_write /etc/apt/preferences.d/xanmod-kernel
        node_manifest_record /etc/apt/preferences.d/xanmod-kernel
    fi
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    node_kernel_reboot_offer
}

# node_kernel_reboot_offer — интерактивное предложение reboot после установки
# ядра (y/N, таймаут 30с, дефолт N). Напоминание persistent: маркер в /run
# (tmpfs — сам исчезнет после ребута), status показывает его до перезагрузки.
# Авто-reboot без явного «y» невозможен.
node_kernel_reboot_offer() {
    mkdir -p /run/node
    date -u '+%Y-%m-%dT%H:%M:%SZ' > /run/node/reboot-required
    log warn "kernel" "XanMod установлен, активно старое ядро ($(uname -r)) — ТРЕБУЕТСЯ reboot"
    if [ -t 0 ] && [ "${NODE_NO_REBOOT_PROMPT:-0}" != "1" ]; then
        local ans=""
        printf 'Перезагрузить сейчас? VPN-трафик прервётся на 1-2 минуты [y/N] (таймаут 30с): ' >&2
        read -r -t 30 ans || ans=""
        case "$ans" in
            y|Y|д|Д)
                log warn "kernel" "reboot по явному выбору оператора"
                if systemctl reboot 2>/dev/null || reboot 2>/dev/null; then
                    # systemctl reboot АСИНХРОНЕН: возвращается мгновенно, а
                    # shutdown идёт секунды. Без стоп-мира apply продолжался
                    # бы в self-test/contract ПОСРЕДИ останова сервисов →
                    # ложные FAIL (sshd/xray уже лежат) и попытка rollback во
                    # время shutdown (баг 2026-09-22, подтверждён мок-тестом:
                    # AFTER-XANMOD шаги выполнялись в окне shutdown). Спим до
                    # реальной перезагрузки; система убьёт процесс сама.
                    log warn "kernel" "reboot инициирован — apply намеренно прерван; после загрузки повтори apply (доприменит всё под новым ядром)"
                    while :; do sleep 30; done
                else
                    log error "kernel" "reboot не удался — перезагрузи вручную: sudo reboot"
                fi
                ;;
            *)
                log info "kernel" "reboot отложен оператором; напоминание: status (маркер /run/node/reboot-required)"
                ;;
        esac
    else
        log warn "kernel" "неинтерактивный запуск — reboot отложен; напоминание в status"
    fi
}

# node_xanmod_remove — откат ядра (явный вызов, требует reboot для полного эффекта).
node_xanmod_remove() {
    [ "${DRY_RUN:-0}" = "1" ] && { log info "dry-run" "would purge XanMod kernel"; return 0; }
    apt-get purge -y 'linux-image*xanmod*' 2>/dev/null || true
    rm -f "$XANMOD_REPO_LIST" "$XANMOD_GPG" /etc/apt/preferences.d/xanmod-kernel
    # восстанавливаем grub-файл из нашего последнего backup (if-guard: &&-цепочка
    # под set -e убила бы скрипт при отсутствии бэкапа)
    local g; g="$(ls -1t /etc/default/grub.pre-node-* 2>/dev/null | head -1 || true)"
    if [ -n "$g" ]; then
        cp -a "$g" /etc/default/grub
        command -v update-grub >/dev/null 2>&1 && update-grub || true
        log info "kernel" "grub restored from $g"
    fi
    log warn "kernel" "XanMod удалён. Для полного отката: sudo reboot (загрузится стоковое ядро)."
}
