#!/bin/bash
# shieldnode — main.sh: точка входа, режимы, lock, диспетчеризация (TZ §4, §28).
set -euo pipefail

SHIELD_VERSION="1.1.2"
# readlink -f: вызов может идти через symlink /usr/local/sbin/guard → main.sh
SHIELD_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export SHIELD_DIR
export SHIELD_STATE_DIR="${SHIELD_STATE_DIR:-/var/lib/shieldnode}"
export SHIELD_LOG="${SHIELD_LOG:-/var/log/shieldnode.log}"
export SHIELD_LOCK="${SHIELD_LOCK:-/run/shieldnode/shieldnode.lock}"
export DRY_RUN=0
export LOG_LEVEL=info

usage() {
    cat <<'EOF'
shieldnode — nftables-фаервол для VPN-нод (Remnawave/Xray). v1.1.2

Использование: shieldnode [опции] <команда> [аргумент]

Команды:
  apply               применить политики (по умолчанию; с --dry-run — только показ)
  detect              снапшот окружения (без изменений)
  status              ожидаемое vs фактическое состояние
  guard               пульт: дропы, наборы, conntrack, службы, алерты (read-only)
  rollback [id]       откат к backup-набору (без id — последний/удаление своих)
  emergency on|off    аварийный минимальный режим
  uninstall           полный откат + удаление своих файлов

Опции:
  --dry-run           ничего не писать/не применять, только показать план
  -h, --help          эта справка

Конфигурация: /etc/shieldnode/config.conf (пустое значение = авто)
Лог: /var/log/shieldnode.log (без секретов)
EOF
}

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --mode=*) POSITIONAL+=("${1#*=}") ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

cmd="${POSITIONAL[0]:-apply}"
subarg="${POSITIONAL[1]:-}"

# вызов как `guard` (symlink /usr/local/sbin/guard → install.sh) = дашборд
if [ "$cmd" = "apply" ] && [ "$(basename "$0")" = "guard" ]; then
    cmd="guard"
fi

# shellcheck source=lib/common.sh
source "$SHIELD_DIR/lib/common.sh"

case "$cmd" in
    detect|status) : ;;  # root не обязателен (только чтение)
    guard) : ;;  # read-only дашборд; nft list всё равно требует CAP_NET_ADMIN, но не роняем
    *) require_root ;;
esac

mkdir -p "$SHIELD_STATE_DIR" "$(dirname "$SHIELD_LOCK")" 2>/dev/null || true
# 2026-09-23: log() пишет только в УЖЕ существующий writable файл, создавать его
# было некому — /var/log/shieldnode.log на свежей ноде не появлялся никогда.
if [ "$(id -u)" -eq 0 ] && [ ! -e "$SHIELD_LOG" ]; then install -m 0640 /dev/null "$SHIELD_LOG" 2>/dev/null || true; fi

# shellcheck source=config.sh
source "$SHIELD_DIR/config.sh"
shield_load_config
log info "main" "shieldnode v$SHIELD_VERSION cmd=$cmd dry_run=$DRY_RUN"

case "$cmd" in
    apply)
        acquire_lock
        # shellcheck source=detect.sh
        source "$SHIELD_DIR/detect.sh"
        # shellcheck source=lib/nft.sh
        source "$SHIELD_DIR/lib/nft.sh"
        # shellcheck source=emergency.sh
        source "$SHIELD_DIR/emergency.sh"
        # shellcheck source=firewall.sh
        source "$SHIELD_DIR/firewall.sh"
        # shellcheck source=lib/crowdsec.sh
        source "$SHIELD_DIR/lib/crowdsec.sh"
        # shellcheck source=ssh.sh
        source "$SHIELD_DIR/ssh.sh"
        # shellcheck source=limits.sh
        source "$SHIELD_DIR/limits.sh"
        # shellcheck source=persist.sh
        source "$SHIELD_DIR/persist.sh"
        # shellcheck source=lib/blocklist.sh
        source "$SHIELD_DIR/lib/blocklist.sh"
        shield_apply
        ;;
    detect)
        # shellcheck source=detect.sh
        source "$SHIELD_DIR/detect.sh"
        shield_detect
        ;;
    status)
        # shellcheck source=detect.sh
        source "$SHIELD_DIR/detect.sh"
        # shellcheck source=ssh.sh
        source "$SHIELD_DIR/ssh.sh"
        # shellcheck source=lib/crowdsec.sh
        source "$SHIELD_DIR/lib/crowdsec.sh"
        # shellcheck source=status.sh
        source "$SHIELD_DIR/status.sh"
        shield_status
        ;;
    guard)
        # shellcheck source=detect.sh
        source "$SHIELD_DIR/detect.sh"
        # shellcheck source=guard.sh
        source "$SHIELD_DIR/guard.sh"
        shield_guard
        ;;
    rollback)
        acquire_lock
        # shellcheck source=rollback.sh
        source "$SHIELD_DIR/rollback.sh"
        shield_rollback "$subarg"
        ;;
    emergency)
        # on/off меняют таблицу — тот же lock, что и у apply (status — read-only, не нужен)
        [ "$subarg" = "status" ] || acquire_lock
        # off требует полного apply — подключаем весь стек как в apply
        # (blocklist/crowdsec обязательны: shield_apply зовёт shield_blocklist_install,
        # без source — command not found и падение посреди apply)
        # shellcheck source=detect.sh
        source "$SHIELD_DIR/detect.sh"
        # shellcheck source=lib/nft.sh
        source "$SHIELD_DIR/lib/nft.sh"
        # shellcheck source=emergency.sh
        source "$SHIELD_DIR/emergency.sh"
        # shellcheck source=firewall.sh
        source "$SHIELD_DIR/firewall.sh"
        # shellcheck source=lib/crowdsec.sh
        source "$SHIELD_DIR/lib/crowdsec.sh"
        # shellcheck source=ssh.sh
        source "$SHIELD_DIR/ssh.sh"
        # shellcheck source=limits.sh
        source "$SHIELD_DIR/limits.sh"
        # shellcheck source=persist.sh
        source "$SHIELD_DIR/persist.sh"
        # shellcheck source=lib/blocklist.sh
        source "$SHIELD_DIR/lib/blocklist.sh"
        shield_emergency "$subarg"
        ;;
    uninstall)
        acquire_lock  # гонка с apply/rollback исключена
        # shellcheck source=rollback.sh
        source "$SHIELD_DIR/rollback.sh"
        # shellcheck source=uninstall.sh
        source "$SHIELD_DIR/uninstall.sh"
        shield_uninstall
        ;;
    *)
        usage >&2
        die "unknown command: $cmd"
        ;;
esac
