#!/bin/bash
# node — main.sh: dispatcher (ТЗ §4, §17).
# Modes: apply (default) | status | rollback [id] | detect | uninstall
set -euo pipefail

NODE_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODE_DIR="$SCRIPT_DIR"
export NODE_STATE_DIR="/var/lib/node"
export NODE_DIAG_DIR="$NODE_STATE_DIR/diagnostics"
export NODE_PROFILE_DIR="/etc/node-profile.d"
export NODE_LOG="/var/log/node.log"
export NODE_LOCK="/run/node/node.lock"

DRY_RUN=0
MODE="apply"
ROLLBACK_ID=""
export DRY_RUN

usage() {
    cat <<'EOF'
node — оптимизатор ОС/сети для VPN-нод (Remnawave/Xray). v1.0.0

Использование: node [опции] <команда> [аргумент]

Команды:
  apply            применить оптимизацию (по умолчанию; с --dry-run — только план)
  detect           снапшот окружения (работает без root, снимок в /tmp)
  status           ожидаемое vs фактическое (работает без root)
  rollback [id]    откат к backup-набору (без id — последний/удаление своих)
  uninstall        полный откат

Опции:
  --id <id>        явный id набора отката (альтернатива позиционному)
  --dry-run        ничего не писать/не применять
  -h, --help       эта справка

Конфигурация: /etc/node/node.conf
Лог: /var/log/node.log (без секретов)
EOF
}

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --id)
            shift
            [ $# -gt 0 ] || { echo "--id requires a value" >&2; exit 64; }
            ROLLBACK_ID="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

for arg in "${POSITIONAL[@]}"; do
    case "$arg" in
        apply|status|detect|uninstall|rollback|rt-reapply) MODE="$arg" ;;
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ROLLBACK_ID="$arg" ;;
        *) echo "unknown argument: '$arg'" >&2; usage >&2; exit 64 ;;
    esac
done
export MODE ROLLBACK_ID

# shellcheck source=lib/common.sh
source "$NODE_DIR/lib/common.sh"

if [ "$(id -u)" -eq 0 ]; then
    require_root
    acquire_lock
    mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR" "$(dirname "$NODE_LOCK")" 2>/dev/null || true
else
    case "$MODE" in
        detect|status) : ;;  # только чтение — root не обязателен
        *) die "run as root: sudo bash install.sh (mode=$MODE требует root)" ;;
    esac
    if [ "$MODE" = "detect" ]; then
        # снапшот нужно куда-то писать — уводим во временный каталог
        export NODE_STATE_DIR="$(mktemp -d /tmp/node-detect.XXXXXX)"
        export NODE_DIAG_DIR="$NODE_STATE_DIR/diagnostics"
        mkdir -p "$NODE_DIAG_DIR"
    fi
    log info "main" "rootless mode=$MODE"
fi

log info "main" "node v$NODE_VERSION mode=$MODE dry_run=$DRY_RUN"

# shellcheck source=config.sh
source "$NODE_DIR/config.sh"
node_load_config

case "$MODE" in
    apply)
        # shellcheck source=detect.sh
        source "$NODE_DIR/detect.sh"
        # shellcheck source=persist.sh
        source "$NODE_DIR/persist.sh"
        # shellcheck source=apply.sh
        source "$NODE_DIR/apply.sh"
        node_detect
        node_apply
        ;;
    status)
        # shellcheck source=detect.sh
        source "$NODE_DIR/detect.sh"
        # shellcheck source=status.sh
        source "$NODE_DIR/status.sh"
        node_status
        ;;
    rollback)
        # shellcheck source=rollback.sh
        source "$NODE_DIR/rollback.sh"
        node_rollback "$ROLLBACK_ID"
        ;;
    detect)
        # shellcheck source=detect.sh
        source "$NODE_DIR/detect.sh"
        # shellcheck source=lib/limits.sh
        source "$NODE_DIR/lib/limits.sh"  # node_limits_detect_units — секция xray_units в снапшоте
        node_detect
        log info "main" "snapshot: $NODE_LAST_SNAPSHOT"
        echo "$NODE_LAST_SNAPSHOT"
        ;;
    uninstall)
        # shellcheck source=uninstall.sh
        source "$NODE_DIR/uninstall.sh"
        node_uninstall
        ;;
    rt-reapply)
        # внутренний режим (вызывается node-rt-tweaks.service при boot):
        # только runtime-твики; sysctl/сервисы/файлы не трогаем
        # shellcheck source=apply.sh
        source "$NODE_DIR/apply.sh"
        node_rt_reapply
        ;;
    *)
        die "unknown mode: $MODE (apply|status|rollback|detect|uninstall)"
        ;;
esac

log info "main" "done mode=$MODE"
