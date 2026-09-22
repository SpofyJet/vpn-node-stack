#!/bin/bash
# vpn-node-setup.sh — однострочная установка стека node + shieldnode с GitHub.
#
#   bash <(curl -sL https://raw.githubusercontent.com/SpofyJet/vpn-node-stack/main/vpn-node-setup.sh)
#
# Что делает:
#   1. Скачивает node.tar.gz и shieldnode.tar.gz из того же репозитория.
#   2. Проверяет SHA256 (SHA256SUMS в репозитории; deploy-to-github.sh его генерирует).
#   3. Проверяет архивы на опасные пути (.. / абсолютные) — до распаковки.
#   4. Распаковывает в /opt/vpn-node-stack и запускает node/install.sh,
#      затем shieldnode/install.sh (сначала оптимизация, потом фаервол).
#
# Аргументы пробрасываются обоим инсталляторам:
#   bash <(curl -sL ...)              # apply (default)
#   bash <(curl -sL ...) --dry-run    # только план, ничего не писать
#   bash <(curl -sL ...) status       # статус (root не нужен)
#   bash <(curl -sL ...) rollback     # откат обоих
#
# Переопределение источника (тесты/зеркала):
#   VPN_STACK_RAW_BASE=https://mirror.example.com/stack bash <(curl -sL ...)
set -euo pipefail

VERSION="1.0.0"
RAW_BASE="${VPN_STACK_RAW_BASE:-https://raw.githubusercontent.com/SpofyJet/vpn-node-stack/main}"
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
        status|detect)
            : ;;  # только чтение — root не обязателен
        guard)
            : ;;  # read-only дашборд
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

# ---------- скачивание ----------
DL="$(mktemp -d "$WORK_DIR/.dl.XXXXXX")"
trap 'rm -rf "$DL"' EXIT

fetch() { # fetch <file>
    local f="$1"
    curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 -o "$DL/$f" "$RAW_BASE/$f" \
        || die "не удалось скачать $RAW_BASE/$f (проверь сеть и имя репозитория)"
}

say "==> vpn-node-setup v$VERSION"
say "==> источник: $RAW_BASE"
fetch node.tar.gz
fetch shieldnode.tar.gz
fetch SHA256SUMS || warn "SHA256SUMS не найден — проверка целостности только через tar"

# ---------- целостность ----------
if [ -s "$DL/SHA256SUMS" ]; then
    ( cd "$DL" && grep -E ' (node|shieldnode)\.tar\.gz$' SHA256SUMS | sha256sum -c - >/dev/null ) \
        || die "SHA256 не сошёлся — архив повреждён или репозиторий подменён. Установка отменена."
    say "==> SHA256: ок"
else
    warn "SHA256SUMS пуст или отсутствует — checksum-проверка пропущена (обнови deploy-to-github.sh)"
fi

# ---------- безопасность архивов (до распаковки) ----------
for tgz in node.tar.gz shieldnode.tar.gz; do
    if tar -tzf "$DL/$tgz" | grep -qE '(^\.\./|(^|/)\.\.(/|$)|^/)'; then
        die "$tgz содержит опасные пути (.. или абсолютные) — распаковка отменена"
    fi
done

# ---------- распаковка (чистая, без наложения на старые файлы) ----------
rm -rf "$NODE_DIR" "$SHIELD_DIR"
tar -xzf "$DL/node.tar.gz"       -C "$WORK_DIR"
tar -xzf "$DL/shieldnode.tar.gz" -C "$WORK_DIR"
[ -f "$NODE_DIR/install.sh" ]    || die "в node.tar.gz нет node/install.sh — архив не тот?"
[ -f "$SHIELD_DIR/install.sh" ]  || die "в shieldnode.tar.gz нет shieldnode/install.sh — архив не тот?"
rm -rf "$DL"; trap - EXIT
say "==> распаковано в $WORK_DIR"

# ---------- запуск (node → shieldnode: сначала оптимизация, потом фаервол) ----------
if [ "$(id -u)" -eq 0 ]; then
    say "==> [1/2] node (оптимизация ОС/сети)"
    bash "$NODE_DIR/install.sh" "$@"
    say "==> [2/2] shieldnode (nftables-фаервол)"
    bash "$SHIELD_DIR/install.sh" "$@"
else
    say "==> [1/2] node (оптимизация ОС/сети)"
    bash "$NODE_DIR/install.sh" "$@"
    say "==> [2/2] shieldnode (nftables-фаервол)"
    bash "$SHIELD_DIR/install.sh" "$@"
fi

say
say "ГОТОВО. Полезные команды:"
say "  guard                              # дашборд дропов (пульт)"
say "  bash $NODE_DIR/install.sh status     # что применено (node)"
say "  bash $SHIELD_DIR/install.sh status   # что применено (shieldnode)"
say "  bash $NODE_DIR/install.sh rollback   # откат node"
say "  bash $SHIELD_DIR/install.sh rollback # откат shieldnode"
