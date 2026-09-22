#!/bin/bash
# vpn-node-setup.sh — однострочная установка стека node + shieldnode с GitHub.
#
#   bash <(curl -sL https://raw.githubusercontent.com/SpofyJet/vpn-node-stack/main/vpn-node-setup.sh)
#
# Что делает:
#   1. Качает снапшот репозитория с codeload.github.com (тот же источник,
#      что обслуживает git clone; репозиторий хранит ТОЛЬКО исходники).
#   2. Проверяет архив на опасные пути (../ или абсолютные) — до распаковки.
#   3. Чистой заменой распаковывает в /opt/vpn-node-stack (stale-файлов не будет).
#   4. Порядок: СНАЧАЛА фаервол [1/2 shieldnode], ЗАТЕМ оптимизация [2/2 node].
#      Худший сценарий при сбое — «нода защищена, но не оптимизирована»,
#      а не открытая нода без фаервола. Откат идёт в обратном порядке.
#   5. Пост-проверка: таблица inet shieldnode реально существует в nft.
#      «Фаервол не включён» после apply — невозможно молча: будет ОШИБКА.
#
# Команды (пробрасываются обоим стекам):
#   bash <(curl -sL ...)              # apply (default)
#   bash <(curl -sL ...) --dry-run    # только план, ничего не писать
#   bash <(curl -sL ...) status       # статус (root не нужен)
#   bash <(curl -sL ...) rollback     # откат (node → shieldnode)
#
# Переопределение источника (тесты/зеркала):
#   VPN_STACK_REPO=Owner/name bash <(curl -sL ...)
#   VPN_STACK_TARBALL_URL=https://mirror.example.com/repo.tar.gz bash <(curl -sL ...)
set -euo pipefail

VERSION="1.1.0"
REPO="${VPN_STACK_REPO:-SpofyJet/vpn-node-stack}"
RAW_BASE="${VPN_STACK_RAW_BASE:-https://raw.githubusercontent.com/$REPO/main}"
TARBALL_URL="${VPN_STACK_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/refs/heads/main}"
WORK_DIR="${VPN_STACK_WORK_DIR:-/opt/vpn-node-stack}"
NODE_DIR="$WORK_DIR/node"
SHIELD_DIR="$WORK_DIR/shieldnode"

say()  { printf '%s\n' "$*"; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }

# ---------- окружение ----------
command -v curl >/dev/null 2>&1 || die "нужен curl: apt-get install -y curl"
command -v tar  >/dev/null 2>&1 || die "нужен tar"

# ---------- команда (первый не-флаг аргумент) ----------
CMD="apply"
for a in "$@"; do
    case "$a" in
        -*) continue ;;
        *)  CMD="$a"; break ;;
    esac
done
case "$CMD" in
    apply|status|detect|rollback|uninstall|install|emergency|guard) : ;;
    *) die "неизвестная команда '$CMD' (ожидалось: apply|status|detect|rollback|...)" ;;
esac

# ---------- root ----------
if [ "$(id -u)" -ne 0 ]; then
    case "$CMD" in
        status|detect|guard)
            : ;;  # только чтение — root не обязателен
        *)
            die "команда '$CMD' требует root. Запусти:
  sudo bash -c 'bash <(curl -sL $RAW_BASE/vpn-node-setup.sh) $*'
(process-substitution должна создаваться ВНУТРИ sudo-shell: fd 63 не переживает sudo;
 stdin=терминал сохраняется — интерактивные prompt'ы работают)"
            ;;
    esac
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ---------- скачивание снапшота ----------
DL="$(mktemp -d "$WORK_DIR/.dl.XXXXXX")"
trap 'rm -rf "$DL"' EXIT

say "==> vpn-node-setup v$VERSION"
say "==> репозиторий: $REPO"
curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$DL/repo.tar.gz" "$TARBALL_URL" \
    || die "не удалось скачать снапшот $TARBALL_URL (проверь сеть, имя репозитория и его видимость — приватный repo вернёт 404)"

# ---------- безопасность архива (до распаковки) ----------
if tar -tzf "$DL/repo.tar.gz" | grep -qE '(^\.\./|(^|/)\.\.(/|$)|^/)'; then
    die "снапшот содержит опасные пути (.. или абсолютные) — распаковка отменена"
fi

# ---------- чистая замена (без наложения и stale-файлов) ----------
rm -rf "$NODE_DIR" "$SHIELD_DIR"
tar -xzf "$DL/repo.tar.gz" --strip-components=1 -C "$WORK_DIR" \
    || die "распаковка снапшота не удалась"
[ -f "$NODE_DIR/install.sh" ]    || die "в снапшоте нет node/install.sh — репозиторий не тот?"
[ -f "$SHIELD_DIR/install.sh" ]  || die "в снапшоте нет shieldnode/install.sh — репозиторий не тот?"
rm -rf "$DL"; trap - EXIT
say "==> распаковано в $WORK_DIR"

# ---------- запуск ----------
# apply:  фаервол ПЕРВЫМ. Принцип «нет фаервола — вообще не начинаем»:
#         если shieldnode не поднялся — откатываем его и НЕ трогаем node
#         (система остаётся в исходном состоянии). Откат — в обратном порядке.
rc_node=0; rc_shield=0
case "$CMD" in
    rollback)
        say "==> [1/2] node: откат оптимизаций"
        bash "$NODE_DIR/install.sh" "$@"   || rc_node=$?
        say "==> [2/2] shieldnode: откат фаервола"
        bash "$SHIELD_DIR/install.sh" "$@" || rc_shield=$?
        ;;
    apply|install|emergency)
        say "==> [1/2] shieldnode (nftables-фаервол)"
        if ! bash "$SHIELD_DIR/install.sh" "$@"; then
            rc_shield=$?
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
case "$CMD" in
    apply|install|emergency)
        if command -v nft >/dev/null 2>&1 && nft list table inet shieldnode >/dev/null 2>&1; then
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

say
say "ГОТОВО. Полезные команды:"
say "  guard                                # дашборд дропов (пульт)"
say "  bash $SHIELD_DIR/install.sh status   # что применено (shieldnode)"
say "  bash $NODE_DIR/install.sh status     # что применено (node)"
say "  bash $NODE_DIR/install.sh rollback   # откат node"
say "  bash $SHIELD_DIR/install.sh rollback # откат shieldnode"
