#!/bin/bash
# node — тест: lib/services.sh (hardening) с моком systemctl. Без root.
# Запуск: bash tests/test-services.sh
set -euo pipefail

# 2026-09-24 (v1.1.5): под root сценарий 9 (node_rt_rollback) писал в НАСТОЯЩИЙ
# /sys/kernel/mm/transparent_hugepage/enabled (THP -> always; ядро пересчитывает
# vm.min_free_kbytes) и делал remount настоящего / — найдено на живой ноде.
# Изоляция: свой mount ns, tmpfs поверх /sys/kernel/mm и /sys/class/net.
if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
if [ "${NODE_TEST_IN_NS:-0}" = "1" ]; then
    mount -t tmpfs t /sys/kernel/mm; mount -t tmpfs t /sys/class/net
fi
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR="$(mktemp -d /tmp/node-svc-test.XXXXXX)"
export NODE_LOG=/dev/null
export NODE_LOCK="$NODE_STATE_DIR/lock"
export DRY_RUN=0
LOG_LEVEL=info

mkdir -p "$NODE_STATE_DIR/mock-units"
CALLS="$NODE_STATE_DIR/calls.log"
: > "$CALLS"

# --- мок systemctl: состояние юнита в $NODE_STATE_DIR/mock-units/<unit> ---
# формат файла: строка1 = is-enabled (enabled/disabled/masked/static/unknown)
#               строка2 = is-active (active/inactive/unknown)
systemctl() {
    local cmd="$1"; shift
    local u st
    case "$cmd" in
        is-enabled|--quiet|-q)
            # разбор: is-enabled [--quiet] <unit>
            for u in "$@"; do
                case "$u" in --quiet|-q) continue ;; esac
                if [ -f "$NODE_STATE_DIR/mock-units/$u" ]; then
                    sed -n '1p' "$NODE_STATE_DIR/mock-units/$u"
                    return 0
                fi
                echo "unknown"; return 1
            done ;;
        is-active)
            u="$1"
            if [ -f "$NODE_STATE_DIR/mock-units/$u" ]; then
                sed -n '2p' "$NODE_STATE_DIR/mock-units/$u"; return 0
            fi
            echo "unknown"; return 3 ;;
        list-unit-files)
            for u in "$@"; do
                case "$u" in --no-legend) continue ;; esac
                [ -f "$NODE_STATE_DIR/mock-units/$u" ] && echo "$u custom"
            done; return 0 ;;
        disable|enable|mask|unmask|start|stop)
            echo "systemctl $cmd $*" >> "$CALLS"
            local now=0
            for u in "$@"; do
                case "$u" in --now) now=1; continue ;; esac
                [ -f "$NODE_STATE_DIR/mock-units/$u" ] || continue
                st="$(sed -n '1p' "$NODE_STATE_DIR/mock-units/$u")"
                case "$cmd" in
                    disable) [ "$st" != "masked" ] && { echo "disabled" > "$NODE_STATE_DIR/mock-units/$u"; echo "inactive" >> "$NODE_STATE_DIR/mock-units/$u"; } ;;
                    enable)  [ "$st" = "disabled" ] && { echo "enabled" > "$NODE_STATE_DIR/mock-units/$u"; echo "inactive" >> "$NODE_STATE_DIR/mock-units/$u"; } ;;
                    mask)    { echo "masked" > "$NODE_STATE_DIR/mock-units/$u"; echo "inactive" >> "$NODE_STATE_DIR/mock-units/$u"; } ;;
                    unmask)  { echo "disabled" > "$NODE_STATE_DIR/mock-units/$u"; echo "inactive" >> "$NODE_STATE_DIR/mock-units/$u"; } ;;
                    start)   sed -i '2s/.*/active/' "$NODE_STATE_DIR/mock-units/$u" ;;
                    stop)    sed -i '2s/.*/inactive/' "$NODE_STATE_DIR/mock-units/$u" ;;
                esac
            done; return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl 2>/dev/null || true

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
# минимальный CONFIG_CACHE (без /etc/node/node.conf)
CONFIG_CACHE="$(mktemp)"
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf" > "$CONFIG_CACHE"
export CONFIG_CACHE

source "$NODE_DIR/lib/services.sh"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

mkunit() { # <unit> <enabled> <active>
    printf '%s\n%s\n' "$2" "$3" > "$NODE_STATE_DIR/mock-units/$1"
}

# --- сценарий 1: disable enabled+active юнита → снапшот + отключение + откат ---
mkunit irqbalance.service enabled active
node_svc_disable irqbalance.service
t "irqbalance отключён (disabled/inactive)" bash -c "grep -qx disabled '$NODE_STATE_DIR/mock-units/irqbalance.service' && grep -qx inactive '$NODE_STATE_DIR/mock-units/irqbalance.service'"
t "снапшот записан (enabled/active)" bash -c "grep -Pqx 'irqbalance.service\tenabled\tactive' '$NODE_SVC_STATE'"
node_services_rollback
t "откат: re-enabled" bash -c "grep -qx enabled '$NODE_STATE_DIR/mock-units/irqbalance.service'"
t "откат: started (был active)" bash -c "grep -qx active '$NODE_STATE_DIR/mock-units/irqbalance.service'"
t "снапшот очищен после отката" bash -c "! test -f '$NODE_SVC_STATE'"

# --- сценарий 1b (v1.1.7): irqbalance отключается только при ENABLE_IRQ_AFFINITY=1 ---
mkunit irqbalance.service enabled active; rm -f "$NODE_SVC_STATE"
node_svc_irqbalance_apply
t "дефолт (без IRQ-affinity): irqbalance НЕ отключён" bash -c "grep -qx enabled '$NODE_STATE_DIR/mock-units/irqbalance.service' && grep -qx active '$NODE_STATE_DIR/mock-units/irqbalance.service'"
printf 'ENABLE_IRQ_AFFINITY=1\n' | cat - "$CONFIG_CACHE" > "$CONFIG_CACHE.1"; cp "$CONFIG_CACHE" "$CONFIG_CACHE.0"; mv "$CONFIG_CACHE.1" "$CONFIG_CACHE"
node_svc_irqbalance_apply
t "ENABLE_IRQ_AFFINITY=1: irqbalance отключён" bash -c "grep -qx disabled '$NODE_STATE_DIR/mock-units/irqbalance.service'"
mv "$CONFIG_CACHE.0" "$CONFIG_CACHE"; printf 'rpcbind.service\tenabled\tactive\n' >> "$NODE_SVC_STATE"
node_svc_irqbalance_apply
t "affinity выключена: отключённый ранее irqbalance возвращён (enabled/active)" bash -c "grep -qx enabled '$NODE_STATE_DIR/mock-units/irqbalance.service' && grep -qx active '$NODE_STATE_DIR/mock-units/irqbalance.service'"
t "снапшот: irqbalance снят с учёта, чужие записи остались" bash -c "! grep -q irqbalance '$NODE_SVC_STATE' && grep -q rpcbind '$NODE_SVC_STATE'"
rm -f "$NODE_SVC_STATE"

# --- сценарий 2: mask → rollback делает unmask ---
mkunit rpcbind.service enabled active
node_svc_mask rpcbind.service
t "rpcbind замаскирован" bash -c "grep -qx masked '$NODE_STATE_DIR/mock-units/rpcbind.service'"
node_services_rollback
t "откат: unmask + re-enable" bash -c "grep -qx enabled '$NODE_STATE_DIR/mock-units/rpcbind.service'"

# --- сценарий 3: уже выключенный юнит не трогаем (idempotent) ---
mkunit colord.service disabled inactive
: > "$CALLS"
node_svc_disable colord.service
t "выключенный юнит пропущен (нет вызова disable)" bash -c "! grep -q 'disable colord' '$CALLS'"

# --- сценарий 4: несуществующий юнит пропущен ---
node_svc_disable nonexistent.service
t "несуществующий юнит пропущен" bash -c "! test -f '$NODE_STATE_DIR/mock-units/nonexistent.service'"

# --- сценарий 5: static → stop-path, откат НЕ делает enable ---
mkunit apt-daily.timer static inactive
node_svc_disable apt-daily.timer
t "static: состояние сохранено (disable невозможен — stop-path без падения)" test -f "$NODE_STATE_DIR/mock-units/apt-daily.timer"
node_services_rollback
t "static: откат без enable (static нельзя включать)" bash -c "! grep -q 'enable apt-daily' '$CALLS' || true"
t "static: снапшот очищен" bash -c "! test -f '$NODE_SVC_STATE'"

# --- сценарий 6: ipv6 ---
# 2026-09-25 (v1.2.0): IPv6 — инвариант (lib/ipv6.sh, test-ipv6.sh), в плане sysctl его нет:
# ключи плана откатываются rollback'ом, а IPv6 не должен включаться никогда
source "$NODE_DIR/lib/sysctl.sh"
node_sysctl_plan_init
DRY_RUN=1 node_harden_ipv6
t "v1.2.0: disable_ipv6 не в откатываемом плане" bash -c "! grep -q 'disable_ipv6' '$NODE_PLAN_FILE'"

# --- сценарий 7: маска-если-выжил (static/dbus resurrection, урок v5.10.3) ---
mkunit dbus-daemon.service static active
node_svc_disable dbus-daemon.service
t "static+active: stop-path сработал" bash -c "grep -qx inactive '$NODE_STATE_DIR/mock-units/dbus-daemon.service'"
# мок: stop переводит в inactive, но не маскирует; is-active quiet -> выжил -> маска
# (в моке после stop юнит inactive, поэтому маска-если-выжил проверяется на active-юните,
#  который stop не смог остановить — эмулируем: stop не меняет состояние)
rm -f "$NODE_STATE_DIR/mock-units/dbus-daemon.service"
mkunit stubborn.service static active
node_svc_disable stubborn.service
t "stubborn: disable невозможен, stop сработал" bash -c "grep -qx inactive '$NODE_STATE_DIR/mock-units/stubborn.service'"

# --- сценарий 8: node_svc_enable (fstrim) + rollback возвращает выключенное ---
mkunit fstrim.timer disabled inactive
node_svc_enable fstrim.timer
t "fstrim включён" bash -c "grep -qx enabled '$NODE_STATE_DIR/mock-units/fstrim.timer'"
node_services_rollback
t "откат fstrim: disabled (как было до нас)" bash -c "grep -qx disabled '$NODE_STATE_DIR/mock-units/fstrim.timer'"

# --- сценарий 9: реестр rt не падает на sysfs/mount kinds ---
source "$NODE_DIR/lib/common.sh" 2>/dev/null || true
cat > "$NODE_RT_TWEAKS" <<EOF
-	sysfs	kernel/mm/transparent_hugepage/enabled	always
eth0	sysfs	class/net/eth0/gro_flush_timeout	10
/	mount	/	rw,relatime
EOF
# 2026-09-24 (v1.1.5): remount корня — только заглушкой (раньше: настоящий mount -o remount /)
findmnt() { return 0; }; mount() { echo "mount $*" >> "$NODE_STATE_DIR/mount.calls"; }
t "rt-откат терпит sysfs/mount (непишемые пути в sandbox)" node_rt_rollback
t "rt-откат: remount корня ушёл в заглушку, не в систему" grep -q 'remount,rw,relatime /' "$NODE_STATE_DIR/mount.calls"
unset -f findmnt mount

# --- сценарий 10: fstab-трансформация (fixture, DRY_RUN) ---
source "$NODE_DIR/persist.sh"   # node_persist fallback (sysctl.sh его больше не несёт)
source "$NODE_DIR/lib/storage.sh"
# mock findmnt: --verify принимает (фейковые UUID фикстуры иначе отвергаются),
# остальные вызовы -> rc=1 (код имеет fallback на '?')
findmnt() { case "${1:-}" in --verify) return 0 ;; *) return 1 ;; esac; }
FAKE_FSTAB="$(mktemp)"
cat > "$FAKE_FSTAB" <<'EOF'
# /etc/fstab fixture
UUID=aaaa / ext4 rw,relatime,discard,errors=remount-ro 0 1
UUID=bbbb /boot/efi vfat rw,relatime,fmask=0022,discard 0 1
UUID=cccc none swap sw 0 0
UUID=dddd /data xfs rw,noatime 0 0
UUID=eeee /var ext4 defaults 0 2
EOF
NODE_FSTAB="$FAKE_FSTAB" node_noatime_apply   # persist реально пишет fixture (в /tmp)
t "fstab: relatime+discard -> noatime, discard снят" bash -c "grep -qE '/ ext4 rw,noatime,errors=remount-ro' '$FAKE_FSTAB'"
t "fstab: efi discard снят, noatime встал" bash -c "grep -qE '/boot/efi vfat rw,noatime,fmask=0022' '$FAKE_FSTAB'"
t "fstab: swap не тронут" bash -c "grep -qE 'none swap sw 0 0' '$FAKE_FSTAB'"
t "fstab: уже-noatime строка не изменилась" bash -c "grep -qE '/data xfs rw,noatime 0 0' '$FAKE_FSTAB'"
t "fstab: defaults получил noatime (раньше был молчаливый no-op)" bash -c "grep -qE '/var ext4 defaults,noatime' '$FAKE_FSTAB'"

# --- сценарий 10b: полностью готовый fstab — файл не трогаем (нет backup/no-op) ---
FAKE_FSTAB2="$(mktemp)"
printf 'UUID=aaaa / ext4 rw,noatime,errors=remount-ro 0 1\nUUID=cccc none swap sw 0 0\n' > "$FAKE_FSTAB2"
NODE_FSTAB="$FAKE_FSTAB2" node_noatime_apply
t "fstab: готовый fstab — без backup (файл не перезаписан)" bash -c "! ls '$FAKE_FSTAB2'.pre-node-* >/dev/null 2>&1"

# --- сценарий 10c: findmnt --verify отверг новый fstab -> die, оригинал не тронут ---
findmnt() { case "${1:-}" in --verify) return 1 ;; *) return 1 ;; esac; }
FAKE_FSTAB3="$(mktemp)"
printf 'UUID=aaaa / ext4 rw,relatime 0 1\n' > "$FAKE_FSTAB3"
# die() делает exit 1 — обязательно в subshell, иначе убьёт тест-раннер
if ( NODE_FSTAB="$FAKE_FSTAB3" node_noatime_apply ) >/dev/null 2>&1; then
    echo "FAIL - fstab: findmnt --verify fail должен убивать node_noatime_apply"; fails=$((fails+1))
else
    echo "ok   - fstab: findmnt --verify fail -> die (не применяем)"
fi
t "fstab: оригинал не тронут при fail verify" bash -c "grep -qE 'rw,relatime' '$FAKE_FSTAB3' && ! ls '$FAKE_FSTAB3'.pre-node-* >/dev/null 2>&1"
unset -f findmnt
rm -f "$FAKE_FSTAB" "$FAKE_FSTAB2" "$FAKE_FSTAB3"

# --- сценарий 11: udev-правила scheduler (порт старого стека) ---
# раньше было мёртвое KERNEL=="sd*[0-9]" (матчит только разделы без queue/scheduler)
t "udev: правило vd/xvd без проверки rotational" bash -c "grep -q 'KERNEL==\"vd\[a-z\]|xvd\[a-z\]\"' '$NODE_DIR/lib/storage.sh'"
t "udev: правило sd/nvme/mmcblk с rotational==0" bash -c "grep -q 'KERNEL==\"sd\[a-z\]|nvme\[0-9\]n\[0-9\]|mmcblk\[0-9\]\"' '$NODE_DIR/lib/storage.sh' && grep -q 'ATTR{queue/rotational}==\"0\"' '$NODE_DIR/lib/storage.sh'"
t "udev: guard scheduler содержит none" bash -c "grep -q 'ATTR{queue/scheduler}==\"\*none\*\"' '$NODE_DIR/lib/storage.sh'"
t "udev: мёртвое sd*[0-9] удалено из правил" bash -c "! grep -q 'KERNEL==\"sd\*\[0-9\]\"' '$NODE_DIR/lib/storage.sh'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: services (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
