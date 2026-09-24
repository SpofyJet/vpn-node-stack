#!/bin/bash
# vpn-node-setup.sh — установка и управление стеком node + shieldnode (Remnawave / Xray).
#
# Первый запуск (скачает стек с GitHub и откроет меню):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/SpofyJet/vpn-node-stack/main/vpn-node-setup.sh)"
# Дальше — одной командой (ярлык ставится после установки):
#   sudo vpn-node                      # меню
#   sudo vpn-node apply | status | rollback | emergency on|off | guard | uninstall
#
# 2026-09-24 (v1.2.0): интерактивное меню (установка, статус, меню безопасности, оптимизация)
# при запуске БЕЗ аргументов в терминале; ярлык /usr/local/sbin/vpn-node. С аргументами и без
# терминала (CI, cron, `curl | bash`) — прежнее поведение: без аргументов = apply.
#
# Что делает apply:
#   1. Качает снапшот репозитория с codeload.github.com.
#   2. Проверяет архив на опасные пути (../ или абсолютные) — до распаковки.
#   3. Чистой заменой распаковывает в /opt/vpn-node-stack (stale-файлов не будет).
#   4. Порядок: СНАЧАЛА фаервол [1/2 shieldnode], ЗАТЕМ оптимизация [2/2 node].
#      Худший сценарий при сбое — «нода защищена, но не оптимизирована»,
#      а не открытая нода без фаервола. Откат идёт в обратном порядке.
#   5. Пост-проверка: таблица inet shieldnode реально существует в nft.
#
# Какой код исполняется (v1.1.3):
#   apply           — качает снапшот и ЗАМЕНЯЕТ установленное дерево (обновление), затем apply;
#   apply --dry-run — качает во ВРЕМЕННЫЙ каталог, показывает план новой версии, ничего не пишет;
#   status|detect|guard|emergency|rollback|uninstall — УСТАНОВЛЕННАЯ копия, без сети.
#                     Если стек не установлен — временная загрузка, после выхода убирается.
#
# Переопределение источника (тесты/зеркала/закрепление версии):
#   VPN_STACK_REF=v1.2.0   VPN_STACK_REPO=Owner/name   VPN_STACK_TARBALL_URL=https://...
set -euo pipefail

VERSION="1.2.0"
REPO="${VPN_STACK_REPO:-SpofyJet/vpn-node-stack}"
RAW_BASE="${VPN_STACK_RAW_BASE:-https://raw.githubusercontent.com/$REPO/main}"
# 2026-09-24 (v1.1.3): VPN_STACK_REF — воспроизводимая установка (тег/ветка/коммит).
# Без него URL прежний (refs/heads/main).
if [ -n "${VPN_STACK_REF:-}" ]; then
    case "$VPN_STACK_REF" in *[!A-Za-z0-9._/-]*|*..*) printf 'ОШИБКА: недопустимый VPN_STACK_REF\n' >&2; exit 1 ;; esac
    TARBALL_URL="${VPN_STACK_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/$VPN_STACK_REF}"
else
    TARBALL_URL="${VPN_STACK_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/refs/heads/main}"
fi
WORK_DIR="${VPN_STACK_WORK_DIR:-/opt/vpn-node-stack}"
# 2026-09-24 (v1.2.0): ярлык и конфиги, которые правит меню (переопределяемы для тестов)
BIN_LINK="${VPN_STACK_BIN:-/usr/local/sbin/vpn-node}"
SHIELD_CONF="${VPN_STACK_SHIELD_CONF:-/etc/shieldnode/config.conf}"
NODE_CONF="${VPN_STACK_NODE_CONF:-/etc/node/node.conf}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }

# sanity WORK_DIR (после die()): не даём rm -rf снести корень или системную
# папку — WORK_DIR обязан быть путём минимум из двух компонентов (/opt/vpn-node-stack)
case "$WORK_DIR" in
    /|"") die "небезопасный WORK_DIR: '$WORK_DIR'" ;;
    /*/*) : ;;
    *)    die "небезопасный WORK_DIR: '$WORK_DIR' (нужен абсолютный путь минимум из двух компонентов)" ;;
esac

# ---------- команды стека (прежняя логика установщика) ----------
stack_main() {
    # ---------- окружение ----------
    command -v curl >/dev/null 2>&1 || die "нужен curl: apt-get install -y curl"
    command -v tar  >/dev/null 2>&1 || die "нужен tar"

    # ---------- команда (первый не-флаг аргумент) + флаг --dry-run ----------
    # 2026-09-23: --dry-run ищем во ВСЕХ аргументах (раньше break на команде: для
    # `apply --dry-run` dry=0 -> пост-проверка nft давала ложную «ФАЕРВОЛ НЕ АКТИВЕН»)
    CMD="apply"
    dry=0; cmd_seen=0
    for a in "$@"; do
        case "$a" in
            --dry-run) dry=1 ;;
            -*) : ;;
            *)  [ "$cmd_seen" = 1 ] || { CMD="$a"; cmd_seen=1; } ;;
        esac
    done
    case "$CMD" in
        apply|status|detect|rollback|uninstall|install|emergency|guard) : ;;
        *) die "неизвестная команда '$CMD' (ожидалось: menu|apply|status|detect|rollback|emergency|guard|uninstall)" ;;
    esac
    # 2026-09-23: `install` не знает ни один из стеков — shieldnode падал, авто-откат
    # снимал рабочий фаервол. Это алиас apply: подменяем слово в пробрасываемых аргументах.
    if [ "$CMD" = "install" ]; then
        CMD="apply"; _args=()
        for a in "$@"; do if [ "$a" = "install" ]; then _args+=("apply"); else _args+=("$a"); fi; done
        set -- "${_args[@]}"
    fi

    # ---------- root ----------
    if [ "$(id -u)" -ne 0 ]; then
        case "$CMD" in
            status|detect|guard)
                : ;;  # только чтение — root не обязателен
            *)
                die "команда '$CMD' требует root. Запусти:
      sudo vpn-node $*
    или (стек ещё не установлен):
      sudo bash -c \"\$(curl -fsSL $RAW_BASE/vpn-node-setup.sh)\" _ $*"
                ;;
        esac
    fi

    # ---------- откуда брать код ----------
    # 2026-09-24 (v1.1.3): раньше ЛЮБАЯ команда качала свежий main и заменяла установленное
    # дерево: --dry-run писал на диск, status/rollback/uninstall молча обновляли код (boot-
    # юниты node исполняют код из этого дерева — после «status» работала другая версия, чем
    # применённая), emergency без сети не включался. Теперь дерево заменяет только apply.
    installed=0
    [ -f "$WORK_DIR/node/install.sh" ] && [ -f "$WORK_DIR/shieldnode/install.sh" ] && installed=1
    replace_tree=0; need_download=0
    if [ "$CMD" = "apply" ]; then
        need_download=1
        [ "$dry" = 1 ] || replace_tree=1
    elif [ "$installed" = 0 ]; then
        need_download=1
    fi

    RUN_DIR="$WORK_DIR"
    DL=""
    trap 'if [ -n "$DL" ]; then rm -rf "$DL"; fi' EXIT
    say "==> vpn-node-setup v$VERSION"
    if [ "$need_download" = 1 ]; then
        if [ "$replace_tree" = 1 ]; then
            mkdir -p "$WORK_DIR"
            DL="$(mktemp -d "$WORK_DIR/.dl.XXXXXX")"          # та же ФС — mv атомарен
        else
            DL="$(mktemp -d "${TMPDIR:-/tmp}/vpn-node-stack.XXXXXX")"   # установку не трогаем
        fi
        say "==> репозиторий: $REPO${VPN_STACK_REF:+ @ $VPN_STACK_REF}"
        curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$DL/repo.tar.gz" "$TARBALL_URL" \
            || die "не удалось скачать снапшот $TARBALL_URL (проверь сеть, имя репозитория и его видимость — приватный repo вернёт 404)"

        # ---------- безопасность архива (до распаковки) ----------
        # Две стадии ДО какого-либо удаления:
        #  1) листинг в файл — битый/оборванный архив отлавливается по коду tar,
        #     а не по ложному «нет совпадений» от grep (и нет гонки SIGPIPE grep -q);
        #  2) проверка путей по готовому листингу.
        LIST="$DL/list.txt"
        if ! tar -tzf "$DL/repo.tar.gz" > "$LIST" 2>/dev/null; then
            die "снапшот $DL/repo.tar.gz повреждён (скачался не полностью?) — установленная копия НЕ тронута"
        fi
        if grep -qE '(^\.\./|(^|/)\.\.(/|$)|^/)' "$LIST"; then
            die "снапшот содержит опасные пути (.. или абсолютные) — распаковка отменена"
        fi

        # Распаковываем во временный подкаталог и проверяем install.sh ДО того,
        # как трогаем старые папки: сбой распаковки оставляет ноду в рабочем виде.
        mkdir -p "$DL/extract"
        tar -xzf "$DL/repo.tar.gz" --strip-components=1 -C "$DL/extract" \
            || die "распаковка снапшота не удалась — установленная копия на месте"
        [ -f "$DL/extract/node/install.sh" ]       || die "в снапшоте нет node/install.sh — репозиторий не тот?"
        [ -f "$DL/extract/shieldnode/install.sh" ] || die "в снапшоте нет shieldnode/install.sh — репозиторий не тот?"
        # git-архивы не хранят exec-биты: без этого симлинк guard → main.sh даст
        # "Permission denied" на ноде (инцидент 2026-09-22). Восстанавливаем явно.
        chmod +x "$DL/extract/node/install.sh"       "$DL/extract/node/main.sh"
        chmod +x "$DL/extract/shieldnode/install.sh" "$DL/extract/shieldnode/main.sh"
        # 2026-09-24 (v1.2.0): архив GitHub несёт режимы 0664/0775 — дерево, которое исполняют
        # от root boot-юниты и ярлык vpn-node, не должно быть group/world-writable; владелец — root
        chmod -R go-w "$DL/extract"
        if [ "$(id -u)" -eq 0 ]; then chown -R 0:0 "$DL/extract" 2>/dev/null || true; fi
        if [ "$replace_tree" = 1 ]; then
            rm -rf "$WORK_DIR/node" "$WORK_DIR/shieldnode"
            mv "$DL/extract/node"       "$WORK_DIR/node"
            mv "$DL/extract/shieldnode" "$WORK_DIR/shieldnode"
            # 2026-09-24 (v1.2.0): копия установщика рядом со стеком — её запускает ярлык vpn-node
            if [ -f "$DL/extract/vpn-node-setup.sh" ]; then
                install -m 0755 "$DL/extract/vpn-node-setup.sh" "$WORK_DIR/.vpn-node-setup.sh.new" \
                    && mv -f "$WORK_DIR/.vpn-node-setup.sh.new" "$WORK_DIR/vpn-node-setup.sh"
            fi
            rm -rf "$DL"; DL=""
            say "==> распаковано в $WORK_DIR (exec-биты восстановлены)"
        else
            RUN_DIR="$DL/extract"
            say "==> временная копия (установка не тронута): $RUN_DIR"
        fi
    else
        say "==> установленная копия: $WORK_DIR (без загрузки)"
    fi
    NODE_DIR="$RUN_DIR/node"
    SHIELD_DIR="$RUN_DIR/shieldnode"
    cd "$RUN_DIR"

    # ---------- запуск ----------
    # apply:  фаервол ПЕРВЫМ. Принцип «нет фаервола — вообще не начинаем»:
    #         если shieldnode не поднялся — откатываем его и НЕ трогаем node
    #         (система остаётся в исходном состоянии). Откат — в обратном порядке.
    rc_node=0; rc_shield=0
    # 2026-09-23: был ли фаервол ДО этого запуска. shieldnode при сбое apply сам
    # оставляет/восстанавливает прежний ruleset (nft -c до изменений, restore из
    # backup при nft -f/self-test fail) — внешний rollback на такой ноде СНИМАЛ
    # рабочий фаервол (fail-open) и стирал config.conf. Авто-откат — только когда
    # фаервола до нас не было (чистая установка, частичное состояние убираем).
    had_fw=0
    command -v nft >/dev/null 2>&1 && nft list table inet shieldnode >/dev/null 2>&1 && had_fw=1
    case "$CMD" in
        rollback)
            say "==> [1/2] node: откат оптимизаций"
            bash "$NODE_DIR/install.sh" "$@"   || rc_node=$?
            say "==> [2/2] shieldnode: откат фаервола"
            bash "$SHIELD_DIR/install.sh" "$@" || rc_shield=$?
            ;;
        emergency|guard)
            # 2026-09-23: команды ТОЛЬКО shieldnode — node их не знает (exit 64 ->
            # ложное «node завершился с ошибкой» после успешного emergency on)
            say "==> shieldnode $CMD"
            bash "$SHIELD_DIR/install.sh" "$@" || rc_shield=$?
            ;;
        apply)
            say "==> [1/2] shieldnode (nftables-фаервол)"
            if bash "$SHIELD_DIR/install.sh" "$@"; then
                :
            else
                rc_shield=$?   # код берём в else: в then-ветке $? был бы 0
                if [ "$had_fw" = 1 ]; then
                    warn "shieldnode завершился с ошибкой $rc_shield — прежний фаервол сохранён (shieldnode откатывает свой ruleset сам); авто-rollback НЕ выполняется"
                    die "обновление ОТМЕНЕНО: фаервол прежней версии активен — node (оптимизация) намеренно не запускался"
                fi
                warn "shieldnode завершился с ошибкой $rc_shield — откатываем его правки"
                bash "$SHIELD_DIR/install.sh" rollback || warn "авто-откат shieldnode не полностью (см. /var/log/shieldnode.log)"
                die "установка ОТМЕНЕНА: фаервол не поднят — node (оптимизация) намеренно не запускался"
            fi
            say "==> [2/2] node (оптимизация ОС/сети)"
            bash "$NODE_DIR/install.sh" "$@" || rc_node=$?
            ;;
        *)
            say "==> [1/2] shieldnode"
            bash "$SHIELD_DIR/install.sh" "$@" || rc_shield=$?
            say "==> [2/2] node"
            bash "$NODE_DIR/install.sh" "$@"   || rc_node=$?
            ;;
    esac

    # ---------- пост-проверка: фаервол реально включён ----------
    # «Применили, а таблицы нет» — самый неприятный сценарий, ловим жёстко.
    _post=0
    case "$CMD" in apply) _post=1 ;; emergency) case " $* " in *" status "*) : ;; *) _post=1 ;; esac ;; esac
    case "$_post" in
        1)
            if [ "$dry" -eq 1 ]; then
                say "==> dry-run: пост-проверка nft пропущена (фаервол намеренно не применялся)"
            elif command -v nft >/dev/null 2>&1 && nft list table inet shieldnode >/dev/null 2>&1; then
                say "==> фаервол: таблица inet shieldnode активна"
            else
                printf 'ОШИБКА: ФАЕРВОЛ НЕ АКТИВЕН — таблицы inet shieldnode в nft нет.\n' >&2
                printf '       Лог: /var/log/shieldnode.log; диагностика: bash %s/install.sh status\n' "$SHIELD_DIR" >&2
                exit 1
            fi
            ;;
    esac

    # ---------- итог ----------
    worst=$(( rc_shield != 0 ? rc_shield : rc_node ))
    case "$CMD" in
        status|detect|guard)
            # read-only: ненулевой rc — это «есть отклонения/замечания», не сбой
            # установки; пробрасываем как есть, без паничных сообщений
            exit "$worst"
            ;;
    esac
    if [ "$rc_shield" -ne 0 ]; then
        die "shieldnode завершился с ошибкой $rc_shield — смотри лог выше и /var/log/shieldnode.log"
    fi
    if [ "$rc_node" -ne 0 ]; then
        die "node завершился с ошибкой $rc_node (фаервол применён — нода под защитой; лог: /var/log/node.log)"
    fi

    [ "$CMD" = apply ] && [ "$dry" = 0 ] && install_shortcut
    say
    say "${C_G}ГОТОВО.${C_0} Дальше всё — одной командой:"
    say "  ${C_B}sudo vpn-node${C_0}             # меню: статус, безопасность, оптимизация, откат"
    say "  ${C_B}sudo vpn-node status${C_0}      # что применено"
    say "  ${C_B}guard${C_0}                     # дашборд дропов фаервола"
}

# ---------- UI и меню (v1.2.0) ----------
# Цвета — только в терминале и без NO_COLOR (логи/CI/пайпы получают чистый текст).
C_0="" C_B="" C_D="" C_G="" C_Y="" C_R="" C_C=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    C_0=$'\033[0m' C_B=$'\033[1m' C_D=$'\033[2m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_C=$'\033[36m'
fi
die()  { printf '%sОШИБКА:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
warn() { printf '%sВНИМАНИЕ:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }

# install_shortcut — /usr/local/sbin/vpn-node -> установленная копия установщика
install_shortcut() {
    local self="$WORK_DIR/vpn-node-setup.sh" tmp
    [ -f "$self" ] || return 0
    mkdir -p "$(dirname "$BIN_LINK")" || return 0
    tmp="$(mktemp "$BIN_LINK.XXXXXX")" || return 0
    printf '#!/bin/bash\n# vpn-node — ярлык меню/команд стека node + shieldnode (создан vpn-node-setup v%s)\nexec bash %q "$@"\n' \
        "$VERSION" "$self" > "$tmp"
    chmod 0755 "$tmp" && mv -f "$tmp" "$BIN_LINK" || { rm -f "$tmp"; return 0; }
}

# ---------- меню ----------
# Ввод: читаем stdin (в терминале это клавиатура). EOF (Ctrl+D) — выход из меню.
ask() { # ask <prompt> -> $REPLY
    printf '%s' "$1"
    IFS= read -r REPLY || { echo; exit 0; }
    REPLY="${REPLY%$'\r'}"
}
pause() { printf '\n%s' "${C_D}Enter — вернуться в меню…${C_0}"; IFS= read -r _ || exit 0; }
confirm() { # confirm <вопрос> [y|n — дефолт]
    local def="${2:-n}" hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
    ask "  $1 $hint "
    case "${REPLY,,}" in
        y|yes|д|да) return 0 ;;
        n|no|н|нет) return 1 ;;
        "") [ "$def" = y ] ;;
        *) return 1 ;;
    esac
}
cls() { [ -t 1 ] && [ "${VPN_STACK_NO_CLEAR:-0}" != 1 ] && printf '\033[H\033[2J' || true; }
ok_()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
bad_()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
info_() { printf '  %s•%s %s\n' "$C_C" "$C_0" "$*"; }

box() { # box <строка>... — рамка по ширине самой длинной строки
    local l w=0 n
    for l in "$@"; do n="${#l}"; [ "$n" -gt "$w" ] && w="$n"; done
    printf '%s╭%s╮%s\n' "$C_C" "$(printf '─%.0s' $(seq 1 $((w + 2))))" "$C_0"
    for l in "$@"; do printf '%s│%s %s%*s %s│%s\n' "$C_C" "$C_0" "$l" $((w - ${#l})) "" "$C_C" "$C_0"; done
    printf '%s╰%s╯%s\n' "$C_C" "$(printf '─%.0s' $(seq 1 $((w + 2))))" "$C_0"
}
kv() { # kv <метка> <значение> — выравнивание по СИМВОЛАМ (printf %-Ns считает байты кириллицы)
    printf '  %s%s%*s%s %s\n' "$C_D" "$1" $((10 - ${#1})) "" "$C_0" "$2"
}
item() { printf '   %s%2s%s  %s\n' "$C_B" "$1" "$C_0" "$2"; }

is_installed() { [ -f "$WORK_DIR/node/install.sh" ] && [ -f "$WORK_DIR/shieldnode/install.sh" ]; }
ver_of() { sed -nE "s/^$2=\"([^\"]+)\"/\\1/p" "$WORK_DIR/$1/main.sh" 2>/dev/null | head -1; }
fw_active() { command -v nft >/dev/null 2>&1 && nft list table inet shieldnode >/dev/null 2>&1; }
set_elems() { # элементы nft-сета через пробел
    nft -n list set inet shieldnode "$1" 2>/dev/null | awk '/elements = \{/ {f = 1; sub(/.*elements = \{/, "")}
        f { l = $0; e = sub(/\}.*/, "", l); print l; if (e) f = 0 }' | tr ',\t\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' || true
}

# --- конфиги: декларативные KEY=value (first-match), НЕ source'ятся ни node, ни shieldnode ---
conf_get() { # conf_get <file> <KEY> -> значение без кавычек
    [ -f "$1" ] || return 0
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}
conf_set() { # conf_set <file> <KEY> <value> — атомарно, с backup; значение уже провалидировано
    local f="$1" k="$2" v="$3" tmp
    mkdir -p "$(dirname "$f")"
    [ -f "$f" ] || { : > "$f"; chmod 0640 "$f"; }
    cp -p "$f" "$f.menu.bak" 2>/dev/null || true
    tmp="$(mktemp "$f.XXXXXX")"
    awk -v k="$k" -v line="$k=\"$v\"" '
        index($0, k "=") == 1 { if (!d) { print line; d = 1 }; next }
        { print }
        END { if (!d) print line }' "$f" > "$tmp"
    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
    mv -f "$tmp" "$f"
}
valid_port() { # порт или диапазон a-b
    local a="${1%-*}" b="${1#*-}"
    [[ "$a" =~ ^[0-9]{1,5}$ && "$b" =~ ^[0-9]{1,5}$ ]] || return 1
    [ "$((10#$a))" -ge 1 ] && [ "$((10#$b))" -le 65535 ] && [ "$((10#$a))" -le "$((10#$b))" ]
}
valid_ip() { # IPv4[/8-32] | IPv6[/16-128] — те же правила, что shield_valid_cidr
    local a="${1%/*}" m="" o
    [[ "$1" == */* ]] && m="${1#*/}"
    if [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        for o in ${a//./ }; do [ "$((10#$o))" -le 255 ] || return 1; done
        [ -z "$m" ] || { [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$m))" -ge 8 ] && [ "$((10#$m))" -le 32 ]; }
    elif [[ "$a" == *:* && "$a" =~ ^[0-9A-Fa-f:]+$ ]]; then
        [ -z "$m" ] || { [[ "$m" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$m))" -ge 16 ] && [ "$((10#$m))" -le 128 ]; }
    else
        return 1
    fi
}
list_add() { # list_add "<список>" <элемент> — без дублей
    case " $1 " in *" $2 "*) echo "$1" ;; *) echo "${1:+$1 }$2" ;; esac
}
list_del() { local x out=""; for x in $1; do [ "$x" = "$2" ] || out="${out:+$out }$x"; done; echo "$out"; }

run_stack() { # выполнить команду стека в subshell (die/exit не закрывают меню)
    # subshell — ГОЛЫМ оператором: в `( ... ) || rc=$?` bash отключает errexit на всё
    # выполнение subshell (сбойный mv/rm посреди обновления дерева не остановил бы установку)
    local rc
    set +e
    ( set -e; stack_main "$@" )
    rc=$?
    set -e
    echo
    if [ "$rc" -eq 0 ]; then ok_ "готово"; else bad_ "завершилось с кодом $rc (подробности выше)"; fi
    return "$rc"
}
run_tool() { # run_tool <node|shieldnode> <args...> — только один стек, установленная копия
    local t="$1" rc=0; shift
    bash "$WORK_DIR/$t/install.sh" "$@" || rc=$?
    echo
    if [ "$rc" -eq 0 ]; then ok_ "$t: готово"; else bad_ "$t: код $rc (лог: /var/log/$t.log)"; fi
    return "$rc"
}
need_installed() {
    is_installed && return 0
    echo; warn "стек ещё не установлен — сначала пункт 1 главного меню"; pause; return 1
}

# --- шапка: что происходит на ноде прямо сейчас ---
header() {
    cls
    box "VPN NODE STACK  ·  установщик v$VERSION" \
        "оптимизация + защита нод Remnawave / Xray"
    local host ip kern st fw ports cs
    host="$(hostname 2>/dev/null || echo '?')"
    ip="$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
    kern="$(uname -r)"
    if is_installed; then
        st="${C_G}установлен${C_0}  node $(ver_of node NODE_VERSION) · shieldnode $(ver_of shieldnode SHIELD_VERSION)"
    else
        st="${C_Y}не установлен${C_0}"
    fi
    if [ -f /run/shieldnode/emergency ]; then
        fw="${C_R}● АВАРИЙНЫЙ РЕЖИМ${C_0} (только SSH + whitelist)"
    elif fw_active; then
        fw="${C_G}● активен${C_0}"
    else
        fw="${C_R}○ не активен${C_0}"
    fi
    if fw_active; then
        local pt pu; pt="$(set_elems protected_tcp)"; pu="$(set_elems protected_udp)"
        ports="tcp ${C_B}${pt:-—}${C_0}   udp ${C_B}${pu:-—}${C_0}"
    else
        ports="${C_D}—${C_0}"
    fi
    if [ "$(conf_get "$SHIELD_CONF" ENABLE_CROWDSEC_LIST)" = 0 ]; then
        cs="${C_D}○ выключен${C_0}"
    elif systemctl is-active --quiet crowdsec.service 2>/dev/null; then
        cs="${C_G}● включён${C_0} (демон активен)"
    else
        cs="${C_Y}● включён${C_0} (демон не активен — применится при установке/обновлении)"
    fi
    kv "Хост" "${C_B}$host${C_0}  ${C_D}${ip:-?} · $kern${C_0}"
    kv "Стек" "$st"
    kv "Фаервол" "$fw"
    kv "Защита" "$ports"
    kv "CrowdSec" "$cs"
    echo
}

# ---------- меню безопасности (shieldnode) ----------
sec_apply_prompt() {
    echo
    if confirm "Применить изменения фаервола сейчас?" y; then
        run_tool shieldnode apply || true
    else
        info_ "сохранено в $SHIELD_CONF — применится при следующем «Применить фаервол» / обновлении"
    fi
    pause
}
shield_probe() { # shield_probe <функция> [args] — вызов детектора shieldnode (read-only, subshell)
    ( export SHIELD_DIR="$WORK_DIR/shieldnode" SHIELD_LOG=/dev/null
      SHIELD_STATE_DIR="$(mktemp -d)" || exit 0; export SHIELD_STATE_DIR   # не предсказуемый /tmp-путь под root
      set +e; source "$SHIELD_DIR/lib/common.sh" && source "$SHIELD_DIR/config.sh" && shield_load_config >/dev/null 2>&1 \
        && source "$SHIELD_DIR/detect.sh" && declare -F "$1" >/dev/null && "$@"
      rm -rf "$SHIELD_STATE_DIR" ) 2>/dev/null || true
}
sec_ports_show() {
    local v
    echo
    printf '  %sЗащищаемые порты сейчас (nft, abuse-лимиты):%s\n' "$C_B" "$C_0"
    v="$(set_elems protected_tcp)"; info_ "tcp: ${C_B}${v:-—}${C_0}"
    v="$(set_elems protected_udp)"; info_ "udp: ${C_B}${v:-—}${C_0}"
    printf '\n  %sОткуда берутся:%s\n' "$C_B" "$C_0"
    v="$(shield_probe shield_detect_ssh_ports)";            info_ "SSH:                ${v:-—}"
    v="$(shield_probe shield_detect_vpn_listen tcp)";        info_ "VPN-ядро tcp:       ${v:-— (xray/remnanode не запущен?)}"
    v="$(shield_probe shield_detect_vpn_listen udp)";        info_ "VPN-ядро udp:       ${v:-—}"
    v="$(shield_probe shield_detect_ufw_ports tcp)";         info_ "UFW tcp:            ${v:-—}"
    v="$(shield_probe shield_detect_ufw_ports udp)";         info_ "UFW udp:            ${v:-—}"
    v="$(conf_get "$SHIELD_CONF" PROTECTED_TCP_EXTRA)";      info_ "вручную tcp:        ${v:-—}"
    v="$(conf_get "$SHIELD_CONF" PROTECTED_UDP_EXTRA)";      info_ "вручную udp:        ${v:-—}"
    [ "$(conf_get "$SHIELD_CONF" PROTECTED_FROM_UFW)" = 0 ] && info_ "порты из UFW ${C_Y}выключены${C_0} (PROTECTED_FROM_UFW=0)"
    return 0
}
sec_ports_edit() { # sec_ports_edit add|del
    local mode="$1" proto key cur p bad="" changed=0
    ask "  Протокол — ${C_B}t${C_0}cp или ${C_B}u${C_0}dp? [t/u] "
    case "${REPLY,,}" in t|tcp) proto=tcp; key=PROTECTED_TCP_EXTRA ;; u|udp) proto=udp; key=PROTECTED_UDP_EXTRA ;; *) warn "нужно t или u"; pause; return 0 ;; esac
    cur="$(conf_get "$SHIELD_CONF" "$key")"
    if [ "$mode" = add ]; then
        ask "  Порты $proto через пробел (порт или диапазон 20000-20100): "
    else
        [ -n "$cur" ] || { info_ "ручных $proto-портов нет"; pause; return 0; }
        ask "  Убрать из ручных $proto ($cur): "
    fi
    for p in $REPLY; do
        if ! valid_port "$p"; then bad="$bad $p"; continue; fi
        if [ "$mode" = add ]; then cur="$(list_add "$cur" "$p")"; else cur="$(list_del "$cur" "$p")"; fi
        changed=1
    done
    [ -n "$bad" ] && warn "пропущено (не порт 1-65535 / диапазон a-b):$bad"
    [ "$changed" = 1 ] || { pause; return 0; }
    conf_set "$SHIELD_CONF" "$key" "$cur"
    ok_ "$key=\"$cur\""
    sec_apply_prompt
}
sec_trusted() {
    local cur p bad="" changed=0
    cur="$(conf_get "$SHIELD_CONF" TRUSTED_IPS)"
    echo
    info_ "доверенные IP (whitelist: без лимитов и блок-листов): ${C_B}${cur:-нет}${C_0}"
    info_ "сюда — IP панели Remnawave и мониторинга; свой IP SSH-сессии добавляется сам"
    ask "  ${C_B}a${C_0} — добавить, ${C_B}d${C_0} — убрать, Enter — назад: "
    case "${REPLY,,}" in
        a) ask "  IP/CIDR через пробел: "
           for p in $REPLY; do if valid_ip "$p"; then cur="$(list_add "$cur" "$p")"; changed=1; else bad="$bad $p"; fi; done ;;
        d) ask "  Убрать: "
           for p in $REPLY; do cur="$(list_del "$cur" "$p")"; changed=1; done ;;
        *) return 0 ;;
    esac
    [ -n "$bad" ] && warn "пропущено (не IPv4/IPv6 или маска шире /8 / /16):$bad"
    [ "$changed" = 1 ] || { pause; return 0; }
    conf_set "$SHIELD_CONF" TRUSTED_IPS "$cur"
    ok_ "TRUSTED_IPS=\"$cur\""
    sec_apply_prompt
}
sec_crowdsec() {
    local cur; cur="$(conf_get "$SHIELD_CONF" ENABLE_CROWDSEC_LIST)"; [ -n "$cur" ] || cur=1
    echo
    if [ "$cur" = 1 ]; then
        info_ "CrowdSec community blocklist: ${C_G}включён${C_0}"
        command -v cscli >/dev/null 2>&1 && info_ "решений в базе: $(cscli decisions list -o json 2>/dev/null | grep -c '"value"' || true)"
        confirm "Выключить CrowdSec-список?" n || return 0
        conf_set "$SHIELD_CONF" ENABLE_CROWDSEC_LIST 0
        info_ "демон crowdsec не удаляется (apt purge crowdsec — вручную)"
    else
        info_ "CrowdSec community blocklist: ${C_D}выключен${C_0}"
        info_ "включение ставит демон crowdsec (~150-200MB RAM), аккаунт не нужен"
        confirm "Включить CrowdSec-список?" y || return 0
        conf_set "$SHIELD_CONF" ENABLE_CROWDSEC_LIST 1
    fi
    sec_apply_prompt
}
sec_emergency() {
    echo
    if [ -f /run/shieldnode/emergency ]; then
        info_ "аварийный режим ${C_R}ВКЛЮЧЁН${C_0}: $(head -1 /run/shieldnode/emergency)"
        confirm "Выключить и вернуть обычный фаервол?" y && run_stack emergency off || true
    else
        info_ "аварийный режим пропускает ТОЛЬКО SSH и whitelist — для атаки на ноду"
        confirm "Включить аварийный режим? VPN-клиенты отключатся" n && run_stack emergency on || true
    fi
    pause
}
menu_security() {
    while :; do
        header
        printf '  %s🛡  Безопасность (shieldnode)%s\n\n' "$C_B" "$C_0"
        item 1 "Защищаемые порты — показать"
        item 2 "Добавить защищаемый порт"
        item 3 "Убрать ручной порт"
        item 4 "Доверенные IP (панель, мониторинг)"
        item 5 "CrowdSec — включить / выключить"
        item 6 "Обновить блок-листы сейчас"
        item 7 "Дашборд дропов (guard)"
        item 8 "Аварийный режим — вкл / выкл"
        item 9 "Применить фаервол"
        item 0 "Назад"
        echo
        ask "  Выбор: "
        case "$REPLY" in
            1) sec_ports_show; pause ;;
            2) sec_ports_edit add ;;
            3) sec_ports_edit del ;;
            4) sec_trusted ;;
            5) sec_crowdsec ;;
            6) echo; if systemctl start shieldnode-blocklist.service 2>/dev/null; then ok_ "блок-листы обновлены (журнал: /var/log/shieldnode.log)"; else bad_ "не удалось (systemctl status shieldnode-blocklist)"; fi; pause ;;
            7) run_stack guard || true; pause ;;
            8) sec_emergency ;;
            9) echo; run_tool shieldnode apply || true; pause ;;
            0|q|"") return 0 ;;
            *) ;;
        esac
    done
}

# ---------- меню оптимизации (node) ----------
menu_node() {
    local v6
    while :; do
        header
        v6="$(conf_get "$NODE_CONF" HARDEN_IPV6)"; [ -n "$v6" ] || v6=1
        printf '  %s⚙  Оптимизация (node)%s\n\n' "$C_B" "$C_0"
        item 1 "Статус оптимизации"
        item 2 "Применить оптимизацию"
        item 3 "План изменений (ничего не меняет)"
        if [ "$v6" = 1 ]; then item 4 "IPv6: ${C_D}выключен${C_0} — включить"; else item 4 "IPv6: ${C_G}включён${C_0} — выключить"; fi
        item 5 "Откатить оптимизацию"
        item 0 "Назад"
        echo
        ask "  Выбор: "
        case "$REPLY" in
            1) echo; run_tool node status || true; pause ;;
            2) echo; run_tool node apply || true; pause ;;
            3) echo; run_tool node apply --dry-run || true; pause ;;
            4) echo
               if [ "$v6" = 1 ]; then confirm "Включить IPv6 (прокси получит v6-вход и выход)?" y || continue; conf_set "$NODE_CONF" HARDEN_IPV6 0
               else confirm "Выключить IPv6 на ноде?" y || continue; conf_set "$NODE_CONF" HARDEN_IPV6 1; fi
               # порядок: node меняет IPv6, затем shieldnode перестраивает v6-правила
               run_tool node apply && run_tool shieldnode apply || true
               pause ;;
            5) echo; confirm "Откатить оптимизацию node к исходному состоянию?" n && run_tool node rollback || true; pause ;;
            0|q|"") return 0 ;;
            *) ;;
        esac
    done
}

menu_main() {
    [ "$(id -u)" -eq 0 ] || die "меню требует root: sudo vpn-node"
    # ширина рамок/колонок считается в символах — нужна UTF-8 локаль (под sudo бывает C/POSIX)
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*utf8*) : ;; *) export LC_ALL=C.UTF-8 ;; esac
    while :; do
        header
        if is_installed; then item 1 "🚀 Обновить стек (скачать последнюю версию и применить)"
        else item 1 "🚀 Установить стек (фаервол + оптимизация)"; fi
        item 2 "📊 Статус"
        item 3 "🛡  Безопасность — порты, доверенные IP, CrowdSec, аварийный режим"
        item 4 "⚙  Оптимизация — статус, IPv6, откат"
        item 5 "🔍 План изменений (ничего не меняет)"
        item 6 "↩  Откатить всё"
        item 7 "🗑  Удалить стек"
        item 0 "Выход"
        echo
        [ -x "$BIN_LINK" ] && printf '  %sзапуск в следующий раз: sudo %s%s\n\n' "$C_D" "$(basename "$BIN_LINK")" "$C_0"
        ask "  Выбор: "
        case "$REPLY" in
            1) echo; confirm "Скачать стек с GitHub и применить (сначала фаервол, затем оптимизация)?" y && run_stack apply || true; pause ;;
            2) echo; need_installed && { run_stack status || true; pause; } ;;
            3) need_installed && menu_security ;;
            4) need_installed && menu_node ;;
            5) echo; run_stack apply --dry-run || true; pause ;;
            6) echo; need_installed && { confirm "Откатить оптимизацию и фаервол к исходному состоянию?" n && run_stack rollback || true; pause; } ;;
            7) echo; need_installed && {
                   warn "будут сняты фаервол shieldnode и оптимизации node"
                   ask "  Для подтверждения введи ${C_B}удалить${C_0}: "
                   if [ "$REPLY" = удалить ]; then run_stack uninstall && rm -f "$BIN_LINK" || true; else info_ "отменено"; fi
                   pause; } ;;
            0|q|"") echo; exit 0 ;;
            *) ;;
        esac
    done
}

# ---------- точка входа ----------
# Меню: явная команда `menu`, либо без аргументов в терминале (VPN_STACK_MENU=1/0 — принудительно).
if [ "${1:-}" = menu ] || { [ $# -eq 0 ] && [ "${VPN_STACK_MENU:-}" != 0 ] && { [ "${VPN_STACK_MENU:-}" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; }; }; then
    menu_main
else
    stack_main "$@"
fi
