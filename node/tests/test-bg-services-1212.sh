#!/bin/bash
# node — тест: фоновые службы v1.2.12 (lib/services.sh, HARDEN_BG_SERVICES).
#   * ModemManager.service и udisks2.service отключаются: до 1.2.12 имена стояли без суффикса,
#     systemd 255 такой юнит «не находит», и обе службы работали на каждой ноде;
#   * новый список — multipathd, fwupd, upower, networkd-dispatcher, таймеры, mdcheck/mdmonitor,
#     unattended-upgrades.service — с условиями (multipath, RAID, файлы-хуки);
#   * исходное состояние каждого юнита снимается и возвращается откатом;
#   * DRY_RUN ничего не меняет; HARDEN_BG_SERVICES=0 — список не трогаем.
# systemctl — заглушка (mocks.sh), пути — во временном каталоге. Под root — ещё и свой
# mount ns с tmpfs поверх каталогов /etc, куда пишет node_services_apply: живой сервер не задет.
set -euo pipefail

if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: под root нужен unshare -m (без изоляции тест писал бы в живой /etc)"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
if [ "${NODE_TEST_IN_NS:-0}" = "1" ]; then
    for d in /etc/apt/apt.conf.d /etc/default/grub.d /etc/needrestart; do
        if [ -d "$d" ]; then mount -t tmpfs t "$d"; fi
    done
fi

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"   # mktemp кода стека (план sysctl, кэш конфига) — внутрь $OUT, уйдёт вместе с ним
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
export NODE_APT_CONF_DIR="$OUT/apt.conf.d" NODE_NEEDRESTART_DIR="$OUT/needrestart" NODE_SYSTEMD_TIMERS_DIR="$OUT/timers"
export NODE_SYS_BLOCK="$OUT/sys-block" NODE_MULTIPATH_WWIDS="$OUT/wwids" NODE_PROC_MDSTAT="$OUT/mdstat"
export NODE_DISPATCHER_DIRS="$OUT/disp-etc $OUT/disp-lib"
mkdir -p "$NODE_STATE_DIR" "$NODE_APT_CONF_DIR" "$NODE_NEEDRESTART_DIR" "$NODE_SYSTEMD_TIMERS_DIR" "$NODE_SYS_BLOCK" \
         "$OUT/disp-etc/routable.d" "$OUT/disp-lib/off.d" "$OUT/bin"
: > "$NODE_CONFIG"
# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_systemctl_install "$OUT/bin" "$OUT/mock"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/update-grub"; chmod +x "$OUT/bin/update-grub"
export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
CONFIG_CACHE="$OUT/config.cache"; export CONFIG_CACHE
# cfg KEY=VAL… — конфиг прогона: сначала переопределения, затем defaults (первое совпадение побеждает);
# kdump выключен всегда: его ветка пишет в grub.d и зовёт update-grub
cfg() { { printf '%s\n' HARDEN_KDUMP=0 "$@"; grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"; }
cfg
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/services.sh"

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
is() { [ "$(ustate "$1")" = "$2" ]; }   # is <юнит> <enabled/active>
snap()   { awk -F'\t' -v u="$1" -v e="$2" -v a="$3" '$1 == u && $2 == e && $3 == a { f = 1 } END { exit !f }' "$NODE_SVC_STATE" 2>/dev/null; }
insnap() { awk -F'\t' -v u="$1" '$1 == u { f = 1 } END { exit !f }' "$NODE_SVC_STATE" 2>/dev/null; }

# нода «как до разового скрипта» (mock_units_stock_node: состояния с живой ноды 14.11) + чистый реестр
fleet() {
    rm -rf "$MOCK_UNITS"; mkdir -p "$MOCK_UNITS"; : > "$MOCK_SYSTEMCTL_LOG"; rm -f "$NODE_SVC_STATE"
    mock_units_stock_node
}
NEW_OFF="multipathd.service multipathd.socket fwupd-refresh.timer networkd-dispatcher.service unattended-upgrades.service man-db.timer apport-autoreport.timer apport-autoreport.path update-notifier-download.timer update-notifier-motd.timer ua-timer.timer snapd.snap-repair.timer mdcheck_start.timer mdcheck_continue.timer mdmonitor-oneshot.timer"
all_off() { local u; for u in $NEW_OFF; do is "$u" disabled/inactive || { echo "не выключен: $u $(ustate "$u")"; return 1; }; done; }
all_as_before() { local u; for u in "$@"; do grep -q "^$u " "$OUT/before.txt" || return 1; [ "$(ustate "$u")" = "$(awk -v u="$u" '$1 == u {print $2}' "$OUT/before.txt")" ] || { echo "изменён: $u"; return 1; }; done; }
before() { local f; : > "$OUT/before.txt"; for f in "$MOCK_UNITS"/*; do echo "$(basename "$f") $(ustate "$(basename "$f")")" >> "$OUT/before.txt"; done; }

# ---------- 1. apply по умолчанию: всё лишнее выключено, исходное состояние записано ----------
fleet; before
node_services_apply > "$OUT/run1.log" 2>&1
t "ModemManager.service отключён (до 1.2.12 имя без суффикса — юнит не находился)" 'is ModemManager.service disabled/inactive'
t "udisks2.service отключён" 'is udisks2.service disabled/inactive'
t "systemd-заглушка: имя без суффикса не находится (условие прежней ошибки)" '[ -z "$(systemctl list-unit-files --no-legend ModemManager)" ] && [ -n "$(systemctl list-unit-files --no-legend ModemManager.service)" ]'
t "новый список выключен: multipathd, networkd-dispatcher, таймеры, mdcheck, unattended-upgrades" 'all_off'
t "multipathd: сокет остановлен раньше службы" '[ "$(grep -n "^disable --now multipathd.socket$" "$MOCK_SYSTEMCTL_LOG" | cut -d: -f1)" -lt "$(grep -n "^disable --now multipathd.service$" "$MOCK_SYSTEMCTL_LOG" | cut -d: -f1)" ]'
t "fwupd.service и upower.service замаскированы" 'is fwupd.service masked/inactive && is upower.service masked/inactive'
t "снимок: исходные состояния (enabled/active, static/active, disabled/active)" 'snap multipathd.service enabled active && snap multipathd.socket disabled active && snap fwupd.service static active && snap upower.service disabled active && snap ModemManager.service enabled active && snap unattended-upgrades.service enabled active && snap ua-timer.timer enabled inactive'
t "ssh, docker, синхронизация времени, cron не тронуты" 'all_as_before ssh.service docker.service systemd-timesyncd.service cron.service'
t "уже выключенный юнит в снимок не попадает (motd-news.timer disabled/inactive)" '! insnap motd-news.timer'

# повторный apply: снимок не переписывается текущим (уже выключенным) состоянием
cp "$NODE_SVC_STATE" "$OUT/state1.tsv"
node_services_apply > "$OUT/run1b.log" 2>&1
t "повторный apply: снимок исходных состояний не изменился" 'cmp -s "$OUT/state1.tsv" "$NODE_SVC_STATE"'

# ---------- 2. откат возвращает всё как было ----------
node_services_rollback > "$OUT/rb.log" 2>&1
t "откат: все юниты в исходном состоянии" 'all_as_before $(cut -d" " -f1 "$OUT/before.txt")'
t "откат: fwupd/upower размаскированы" 'grep -q "^unmask fwupd.service$" "$MOCK_SYSTEMCTL_LOG" && grep -q "^unmask upower.service$" "$MOCK_SYSTEMCTL_LOG"'
t "откат: снимок очищен" '[ ! -e "$NODE_SVC_STATE" ]'

# ---------- 3. условия: multipath, RAID, файлы-хуки ----------
fleet; before
mkdir -p "$NODE_SYS_BLOCK/dm-0/dm" "$NODE_SYS_BLOCK/dm-1/dm"
echo "LVM-abcdef0123456789" > "$NODE_SYS_BLOCK/dm-0/dm/uuid"
node_services_apply >/dev/null 2>&1
t "LVM (dm без mpath) — не multipath: multipathd выключен" 'is multipathd.service disabled/inactive && is multipathd.socket disabled/inactive'
fleet; before
echo "mpath-3600508b4000156d700012000000b0000" > "$NODE_SYS_BLOCK/dm-1/dm/uuid"
node_services_apply > "$OUT/run3.log" 2>&1
t "есть multipath-устройство: multipathd не тронут" 'all_as_before multipathd.service multipathd.socket && ! grep -q "multipathd" "$MOCK_SYSTEMCTL_LOG"'
t "…остальной список при этом выключен" 'is man-db.timer disabled/inactive && is fwupd.service masked/inactive'
rm -rf "$NODE_SYS_BLOCK"/dm-*
fleet; before
printf '# Multipath wwids, Version : 1.0\n#\n/3600508b4000156d700012000000b0000/\n' > "$NODE_MULTIPATH_WWIDS"
node_services_apply >/dev/null 2>&1
t "WWID в /etc/multipath/wwids: multipathd не тронут" 'all_as_before multipathd.service multipathd.socket'
printf '# Multipath wwids, Version : 1.0\n#\n' > "$NODE_MULTIPATH_WWIDS"
fleet; before; node_services_apply >/dev/null 2>&1
t "wwids только с комментариями: multipathd выключен" 'is multipathd.service disabled/inactive'
rm -f "$NODE_MULTIPATH_WWIDS"

fleet; before
printf 'Personalities : [raid1]\nmd0 : active raid1 vdb1[1] vda1[0]\n      1046528 blocks super 1.2 [2/2] [UU]\n\nunused devices: <none>\n' > "$NODE_PROC_MDSTAT"
node_services_apply >/dev/null 2>&1
t "есть программный RAID: таймеры mdcheck/mdmonitor не тронуты" 'all_as_before mdcheck_start.timer mdcheck_continue.timer mdmonitor-oneshot.timer'
printf 'Personalities : [raid0] [raid1]\nunused devices: <none>\n' > "$NODE_PROC_MDSTAT"
fleet; before; node_services_apply >/dev/null 2>&1
t "mdstat без массивов: таймеры mdcheck/mdmonitor выключены" 'is mdcheck_start.timer disabled/inactive && is mdmonitor-oneshot.timer disabled/inactive'
rm -f "$NODE_PROC_MDSTAT"
fleet; before; node_services_apply >/dev/null 2>&1
t "нет /proc/mdstat (md не загружен): таймеры выключены" 'is mdcheck_continue.timer disabled/inactive'

fleet; before
echo '#!/bin/sh' > "$OUT/disp-etc/routable.d/50-ifup-hooks"
node_services_apply >/dev/null 2>&1
t "свой файл-хук в /etc/networkd-dispatcher: служба не тронута" 'all_as_before networkd-dispatcher.service'
rm -f "$OUT/disp-etc/routable.d/50-ifup-hooks"
fleet; before
ln -s /bin/true "$OUT/disp-lib/off.d/chrony-onoffline"
node_services_apply >/dev/null 2>&1
t "хук пакета в /usr/lib/networkd-dispatcher (ссылка): служба не тронута" 'all_as_before networkd-dispatcher.service'
rm -f "$OUT/disp-lib/off.d/chrony-onoffline"
fleet; before; node_services_apply >/dev/null 2>&1
t "пустые каталоги хуков: networkd-dispatcher выключен" 'is networkd-dispatcher.service disabled/inactive'

# ---------- 4. условие появилось позже — следующий apply возвращает юниты ----------
# (после сценария выше таймеры md выключены и лежат в снимке)
printf 'md127 : active raid1 vdb[1] vda[0]\n' > "$NODE_PROC_MDSTAT"
echo '#!/bin/sh' > "$OUT/disp-etc/routable.d/50-x"
mkdir -p "$NODE_SYS_BLOCK/dm-3/dm"; echo "mpath-360a98000" > "$NODE_SYS_BLOCK/dm-3/dm/uuid"
node_services_apply > "$OUT/run4.log" 2>&1
t "появился RAID: таймеры md возвращены (enabled/active)" 'is mdcheck_start.timer enabled/active && is mdcheck_continue.timer enabled/active && is mdmonitor-oneshot.timer enabled/active'
t "появился файл-хук: networkd-dispatcher возвращён" 'is networkd-dispatcher.service enabled/active'
t "появился multipath: multipathd возвращён (служба enabled/active, сокет disabled/active)" 'is multipathd.service enabled/active && is multipathd.socket disabled/active'
t "возвращённые юниты сняты с учёта, остальные остались в снимке" '! insnap mdcheck_start.timer && ! insnap networkd-dispatcher.service && ! insnap multipathd.service && insnap man-db.timer'
rm -f "$NODE_PROC_MDSTAT" "$OUT/disp-etc/routable.d/50-x"; rm -rf "$NODE_SYS_BLOCK"/dm-*

# ---------- 5. флаги ----------
fleet; before; cfg HARDEN_BG_SERVICES=0
node_services_apply >/dev/null 2>&1
t "HARDEN_BG_SERVICES=0: список не тронут (включая ModemManager, fwupd, unattended-upgrades.service)" 'all_as_before $NEW_OFF ModemManager.service udisks2.service fwupd.service upower.service'
t "HARDEN_BG_SERVICES=0: таймеры apt выключены как раньше (HARDEN_UNATTENDED=1)" 'is apt-daily.timer disabled/inactive'

fleet; before; cfg HARDEN_UNATTENDED=0
node_services_apply >/dev/null 2>&1
t "HARDEN_UNATTENDED=0: unattended-upgrades.service и таймеры apt не тронуты" 'all_as_before unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer'
t "HARDEN_UNATTENDED=0: остальной фон выключен" 'is man-db.timer disabled/inactive && is ModemManager.service disabled/inactive'

# 1 -> 0: служба, выключенная прежним apply, возвращается
fleet; before; cfg
node_services_apply >/dev/null 2>&1
t "HARDEN_UNATTENDED=1: unattended-upgrades.service выключен" 'is unattended-upgrades.service disabled/inactive'
cfg HARDEN_UNATTENDED=0
node_services_apply >/dev/null 2>&1
t "HARDEN_UNATTENDED 1 -> 0: unattended-upgrades.service возвращён и снят с учёта" 'is unattended-upgrades.service enabled/active && ! insnap unattended-upgrades.service'
cfg

# ---------- 6. DRY_RUN ----------
fleet; before
rm -rf "${NODE_APT_CONF_DIR:?}" "${NODE_STATE_DIR:?}"/*; mkdir -p "$NODE_APT_CONF_DIR"
DRY_RUN=1 node_services_apply > "$OUT/dry.log" 2>&1
t "DRY_RUN: ни один юнит не изменён" 'all_as_before $(cut -d" " -f1 "$OUT/before.txt")'
t "DRY_RUN: systemctl не вызывался на изменение, снимка нет" '[ ! -s "$MOCK_SYSTEMCTL_LOG" ] && [ ! -e "$NODE_SVC_STATE" ]'
t "DRY_RUN: в плане названы новые юниты" 'grep -q "would disable multipathd.socket multipathd.service" "$OUT/dry.log" && grep -q "would disable+mask fwupd.service upower.service" "$OUT/dry.log"'
t "DRY_RUN: файлы не записаны" '[ -z "$(ls -A "$NODE_APT_CONF_DIR")" ]'

# ---------- 7. края ----------
# служба, которую D-Bus поднимает снова после stop, — маскируется (и размаскируется откатом)
fleet; before
MOCK_STUBBORN="udisks2.service" node_services_apply >/dev/null 2>&1
t "udisks2 пережил stop — замаскирован" '[ "$(sed -n 1p "$MOCK_UNITS/udisks2.service")" = masked ]'
node_services_rollback >/dev/null 2>&1
t "…и размаскирован откатом (enabled)" '[ "$(sed -n 1p "$MOCK_UNITS/udisks2.service")" = enabled ]'
# минимальный образ: юнитов из списка нет вовсе
rm -rf "$MOCK_UNITS"; mkdir -p "$MOCK_UNITS"; : > "$MOCK_SYSTEMCTL_LOG"; rm -f "$NODE_SVC_STATE"
mkunit ssh.service enabled active
t "юнитов из списка нет: apply проходит" 'node_services_apply'
t "…ничего не вызвано и не записано в снимок" '[ ! -s "$MOCK_SYSTEMCTL_LOG" ] && [ ! -s "$NODE_SVC_STATE" ]'
# юниты уже выключены и замаскированы разовым скриптом — стек их не «выключает» повторно
fleet
for u in $NEW_OFF ModemManager.service udisks2.service; do mkunit "$u" disabled inactive; done
mkunit fwupd.service masked inactive static; mkunit upower.service masked inactive
: > "$MOCK_SYSTEMCTL_LOG"
node_services_apply >/dev/null 2>&1
t "после разового скрипта: выключенные юниты не трогаются и в снимок не пишутся" '! grep -qE "multipathd|man-db|ModemManager|networkd-dispatcher" "$MOCK_SYSTEMCTL_LOG" && ! insnap multipathd.service && ! insnap man-db.timer && ! insnap ModemManager.service'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: bg-services-1212 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
