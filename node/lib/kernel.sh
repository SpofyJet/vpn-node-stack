#!/bin/bash
# node — lib/kernel.sh: BBR + (опц.) XanMod-ядро. Требование: авто-BBR когда ядро
# умеет; XanMod — ENABLE_XANMOD=1 (с v1.2.0 — по запросу, DIAGNOSIS P1-5).
# Никогда не ребутаем сами; откат ядра — restore grub-файла + purge (документирован).
set -euo pipefail

XANMOD_REPO_LIST=/etc/apt/sources.list.d/xanmod-kernel.list
# 2026-09-24 (v1.1.6): ключ — в /etc/apt/keyrings + signed-by в строке репо (доверие только
# репозиторию XanMod, как в официальной инструкции). В /etc/apt/trusted.gpg.d ключ был
# доверен для ЛЮБОГО репозитория; прежний путь убираем при установке/удалении.
XANMOD_GPG=/etc/apt/keyrings/xanmod-archive-keyring.gpg
XANMOD_GPG_LEGACY=/etc/apt/trusted.gpg.d/xanmod-kpg.gpg

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

# node_bbr_generation — "3" если модуль tcp_bbr ядра — BBRv3, иначе "1".
# 2026-09-24 (v1.1.7): раньше «ядро >= 6.15 -> BBRv3 в мейнлайне» — ЛОЖНО: мейнлайн
# (torvalds/master, 7.3-rc) содержит BBRv1 (tcp_bbr.c без inflight_lo и без версии).
# BBRv3 — патчсет Google, который несут XanMod и др.; признак — `modinfo -F version
# tcp_bbr` = 3 (XanMod 6.18: builtin, version 3; стоковое 6.8: поля нет).
node_bbr_generation() {
    local v; v="$(modinfo -F version tcp_bbr 2>/dev/null | head -1 || true)"
    if [ "$v" = 3 ] || node_kernel_is_xanmod; then echo 3; else echo 1; fi
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
            log info "kernel" "BBRv3 доступен (tcp_bbr version 3) — план: congestion_control=bbr, qdisc=fq"
        else
            log info "kernel" "BBR v1 доступен — план: congestion_control=bbr, qdisc=fq (BBRv3: XanMod, ENABLE_XANMOD=1 + reboot)"
        fi
    else
        # 2026-09-24 (v1.1.7): без ветки «ядро >= 6.15» (ложная посылка о BBRv3 в мейнлайне)
        log warn "kernel" "BBR недоступен в текущем ядре ($(uname -r)). XanMod: ENABLE_XANMOD=1 в /etc/node/node.conf, затем reboot и повторный apply."
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
    # 2026-09-24 (v1.1.6): ENABLE_XANMOD=1 стал дефолтом. Дефолт (ключа нет в node.conf) —
    # «мягкий»: где XanMod не нужен/невозможен — info/warn и пропуск, apply не падает
    # (иначе каждый apply на ARM, jammy (нет suite — 404) или при сбое сети кончался бы
    # ошибкой). Явный ENABLE_XANMOD=1 в node.conf — строгий режим, как прежде.
    # явный = ключ задан в node.conf: в CONFIG_CACHE строки пользователя идут ПЕРВЫМИ,
    # defaults дописаны следом (ключ там всегда) — два вхождения и первое = 1
    local explicit=0 uv=""
    uv="$(awk -F= '$1 == "ENABLE_XANMOD" { n++; if (n == 1) v = $2 } END { if (n > 1) print v }' "${CONFIG_CACHE:-/dev/null}" 2>/dev/null || true)"
    [[ "$uv" =~ ^[[:space:]]*[\"\']?1 ]] && explicit=1
    if ! node_xanmod_supported; then
        [ "$explicit" = 1 ] && die "XanMod поддерживается только на Debian/Ubuntu x86_64 (тут: $(uname -m), $(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null || echo '?'))"
        log info "kernel" "XanMod (дефолт): платформа не поддерживается ($(uname -m)) — пропуск"
        return 0
    fi
    # 2026-09-24 (v1.1.7): пропуск по факту BBRv3 в текущем ядре (tcp_bbr version 3), а не по
    # версии ядра — мейнлайн BBRv3 не содержит (прежний пропуск «>= 6.15» был ложным)
    if [ "$explicit" = 0 ] && [ "$(node_bbr_generation)" = 3 ]; then
        log info "kernel" "XanMod (дефолт): текущее ядро $(uname -r) уже с BBRv3 — замена ядра не нужна"
        return 0
    fi
    # отказ на шаге: явный режим — rc 1 (шаг apply «упал», как прежде); дефолт — warn, rc 0
    _xm_fail() { log warn "kernel" "$1"; [ "$explicit" = 1 ] && return 1; return 0; }

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
    # 2026-09-24 (v1.1.6): источник XanMod уже настроен другим инструментом/вручную — не
    # дублируем (дубль источника = предупреждения apt) и НЕ перезаписываем чужой ключ
    local foreign="" own_repo=0 codename=""
    # 2026-09-25 (v1.2.0, E7): `|| true` на ВЕСЬ конвейер — без чужого источника второй grep
    # получает пустой ввод и выходит 1, pipefail+set -e обрывали шаг: XanMod не ставился нигде
    foreign="$( { grep -rlsE '^[^#]*deb(\[[^]]*\])?[[:space:]].*deb\.xanmod\.org' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true; } \
        | grep -vxF "$XANMOD_REPO_LIST" | awk 'NR == 1' || true)"
    if [ -n "$foreign" ]; then
        log info "kernel" "источник XanMod уже настроен ($foreign) — используем его, свой не добавляем"
    else
        own_repo=1
        # репозиторий + ключ (backup + atomic + манифест — единые правила проекта)
        declare -F node_origin_record >/dev/null 2>&1 && node_origin_record "$XANMOD_REPO_LIST"   # 2026-09-23: реестр для rollback
        backup "$XANMOD_REPO_LIST"
        # 2026-09-24 (v1.1.6): suite = кодовое имя дистрибутива. Прежний `releases` XanMod убрал
        # (HTTP 404 «does not have a Release file» — ENABLE_XANMOD=1 не работал вовсе);
        # живые: noble/bookworm/trixie, jammy — 404 (проверено 2026-09-24).
        codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
        if ! [[ "$codename" =~ ^[a-z]+$ ]]; then
            [ "$explicit" = 1 ] && die "XanMod: не удалось определить VERSION_CODENAME из /etc/os-release"
            log warn "kernel" "XanMod (дефолт): VERSION_CODENAME не определён — пропуск"; return 0
        fi
        printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "$XANMOD_GPG" "$codename" | atomic_write "$XANMOD_REPO_LIST"
        node_manifest_record "$XANMOD_REPO_LIST"
        if command -v wget >/dev/null 2>&1; then
            # gpg --dearmor при обрыве сети выдавал ПУСТОЙ keyring (apt потом
            # отвергал репозиторий с невнятной ошибкой). Через temp + проверка -s;
            # при фейле — rm; пустой keyring не оставляем.
            local ktmp; ktmp="$(mktemp)"
            if wget -qO- https://dl.xanmod.org/gpg.key 2>/dev/null | gpg --dearmor > "$ktmp" 2>/dev/null && [ -s "$ktmp" ]; then
                declare -F node_origin_record >/dev/null 2>&1 && node_origin_record "$XANMOD_GPG"
                atomic_write "$XANMOD_GPG" < "$ktmp"
                node_manifest_record "$XANMOD_GPG"
                rm -f "$ktmp" "$XANMOD_GPG_LEGACY"
            else
                rm -f "$ktmp" "$XANMOD_GPG" "$XANMOD_REPO_LIST"
                [ "$explicit" = 1 ] && die "kernel: gpg key import failed (сеть/gpg?) — XanMod не устанавливаем, пустой keyring удалён"
                log warn "kernel" "XanMod (дефолт): ключ не скачан (сеть?) — пропуск, repo убран; повторный apply доустановит"
                return 0
            fi
        else
            log warn "kernel" "wget отсутствует — добавьте ключ вручную: https://dl.xanmod.org/gpg.key"
        fi
    fi
    # Сетевой сбой здесь НЕ убивает весь apply (счётчик шага: apply доработает,
    # но итоговая сводка назовёт xanmod_install среди упавших — return 1, не 0:
    # иначе сбой молча исчезал из консольного вывода, оставаясь только warn'ом
    # в логе. С ноды в РФ deb.xanmod.org периодически недоступен — реальный
    # сценарий, а не теория). Повторный apply доустанавливает.
    # 2026-09-23 (v1.1.2): Acquire::Retries — разовый сетевой сбой зеркала не валит шаг
    # 2026-09-24 (v1.1.6): при отказе update убираем СВОЙ только что добавленный репо и ключ —
    # иначе битый источник ломал бы каждый последующий `apt update` хоста
    if ! apt-get -o Acquire::Retries=3 update -qq; then
        if [ "$own_repo" = 1 ]; then
            rm -f "$XANMOD_REPO_LIST" "$XANMOD_GPG"
            _xm_fail "apt update с репо XanMod ($codename) не прошёл (нет suite для $codename или сеть) — XanMod пропущен, репо и ключ убраны"; return
        fi
        _xm_fail "apt update не прошёл (сеть/источники) — XanMod пропущен, повторите apply"; return
    fi
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends "$pkg" || { _xm_fail "apt install $pkg failed — повторите apply"; return; }
    # 2026-09-23 (v1.1.4): маркер ожидания reboot в state (переживает reboot, в отличие от /run)
    mkdir -p "${NODE_STATE_DIR:-/var/lib/node}"
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$pkg" "$(uname -r)" > "$(node_xanmod_pending_file)"
    # pin: держим ядро при autoremove (через node_persist — backup + манифест,
    # а не printf > напрямую мимо единой точки записи)
    if declare -F node_persist >/dev/null 2>&1; then
        printf '%s\n' 'Package: linux-image*xanmod*' 'Pin: release o=XanMod' 'Pin-Priority: 1001' | node_persist /etc/apt/preferences.d/xanmod-kernel
    else
        printf '%s\n' 'Package: linux-image*xanmod*' 'Pin: release o=XanMod' 'Pin-Priority: 1001' | atomic_write /etc/apt/preferences.d/xanmod-kernel
        node_manifest_record /etc/apt/preferences.d/xanmod-kernel
    fi
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    # баннер — после шумного update-grub, прямо перед y/N-промптом
    node_reboot_notice "XanMod установлен ($pkg). ТРЕБУЕТСЯ REBOOT для активации нового ядра: sudo reboot (сейчас активно $(uname -r))"
    node_kernel_reboot_offer
}

# --- заметное напоминание о reboot после XanMod (v1.1.4, 2026-09-23) ---
# Раньше напоминания были обычными строками `log warn`, неотличимыми от сотен
# соседних; маркер жил только в /run (tmpfs) — после reboot, в котором GRUB
# поднял СТАРОЕ ядро, следа не оставалось вовсе. Авто-reboot по-прежнему нет.
# 2026-09-24 (v1.1.5): версия ядра записи GRUB по умолчанию (stdout; пусто — не определить).
# Только GRUB_DEFAULT=0 (первая запись grub.cfg) — saved/именованные записи не угадываем.
node_grub_default_kernel() {
    local cfg="${NODE_GRUB_CFG:-/boot/grub/grub.cfg}" def
    def="$(awk -F= '/^GRUB_DEFAULT=/{v=$2} END{gsub(/["'"'"']/, "", v); print v}' "${NODE_GRUB_DEFAULT_FILE:-/etc/default/grub}" 2>/dev/null || true)"
    [ "${def:-0}" = "0" ] || return 0
    awk '$1 == "linux" && $2 ~ /vmlinuz-/ { v = $2; sub(/.*vmlinuz-/, "", v); print v; exit }' "$cfg" 2>/dev/null || true
}

node_xanmod_pending_file() { echo "${NODE_STATE_DIR:-/var/lib/node}/pending-reboot-xanmod"; }

# node_reboot_notice <текст> [fd=2] — рамка + «>>> текст <<<». Жирный жёлтый —
# ТОЛЬКО если fd это терминал и не задан NO_COLOR (в лог/пайп/CI — без ANSI-мусора).
node_reboot_notice() {
    local msg="$1" fd="${2:-2}" c="" r="" line="======================================================================"
    if [ -t "$fd" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then c=$'\033[1;33m'; r=$'\033[0m'; fi
    printf '%s%s%s\n%s>>> %s <<<%s\n%s%s%s\n' "$c" "$line" "$r" "$c" "$msg" "$r" "$c" "$line" "$r" >&"$fd"
}

# ожидает reboot: маркер есть, пакет XanMod реально установлен, активно НЕ XanMod-ядро
# (ловит и «перезагрузились, а GRUB загрузил старое ядро»)
node_xanmod_reboot_pending() {
    [ -f "$(node_xanmod_pending_file)" ] || return 1
    node_kernel_is_xanmod && return 1
    dpkg -l 'linux-image*xanmod*' 2>/dev/null | awk '/^ii/{f = 1} END{exit !f}'
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
    rm -f "$XANMOD_REPO_LIST" "$XANMOD_GPG" "$XANMOD_GPG_LEGACY" /etc/apt/preferences.d/xanmod-kernel
    # восстанавливаем grub-файл из нашего последнего backup (if-guard: &&-цепочка
    # под set -e убила бы скрипт при отсутствии бэкапа)
    local g; g="$(ls -1t /etc/default/grub.pre-node-* 2>/dev/null | head -1 || true)"
    if [ -n "$g" ]; then
        cp -a "$g" /etc/default/grub
        command -v update-grub >/dev/null 2>&1 && update-grub || true
        log info "kernel" "grub restored from $g"
    fi
    rm -f "$(node_xanmod_pending_file)" 2>/dev/null || true   # 2026-09-23 (v1.1.4): XanMod снят — ждать нечего
    log warn "kernel" "XanMod удалён. Для полного отката: sudo reboot (загрузится стоковое ядро)."
}
