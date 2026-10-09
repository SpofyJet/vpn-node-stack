#!/bin/bash
# node — тест: node_unattended_safe_apply (v1.2.5). Дефолт HARDEN_UNATTENDED=0: автообновления
# безопасности включены, но docker/containerd needrestart не перезапускает (обрыв всех VPN-клиентов),
# пакеты docker в автообновления не попадают; прежний «выключатель» node (99-node-no-unattended,
# создан node) убирается, apt-daily*.timer возвращаются в исходное состояние.
# Все пути — во временном каталоге (NODE_APT_CONF_DIR/NODE_NEEDRESTART_DIR), systemctl — заглушка.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null DRY_RUN=0
export NODE_APT_CONF_DIR="$OUT/apt.conf.d" NODE_NEEDRESTART_DIR="$OUT/needrestart" NODE_SYSTEMD_TIMERS_DIR="$OUT/timers"
mkdir -p "$NODE_STATE_DIR" "$NODE_APT_CONF_DIR" "$NODE_NEEDRESTART_DIR" "$NODE_SYSTEMD_TIMERS_DIR"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/services.sh"
systemctl() { echo "$*" >> "$OUT/systemctl.calls"; case "$1" in is-enabled) echo disabled; return 1 ;; is-active) echo inactive; return 3 ;; esac; return 0; }
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

# состояние «после прежнего node»: выключатель создан node, таймеры отключены им же (снапшот: были enabled)
echo 'APT::Periodic::Unattended-Upgrade "0";' > "$NODE_APT_CONF_DIR/99-node-no-unattended"
printf '%s\tcreated\n' "$NODE_APT_CONF_DIR/99-node-no-unattended" > "$NODE_STATE_DIR/file-origins.tsv"
printf 'apt-daily.timer\tenabled\tactive\napt-daily-upgrade.timer\tenabled\tactive\n' > "$NODE_STATE_DIR/services-state.tsv"
node_unattended_safe_apply > "$OUT/run.log" 2>&1

t "выключатель автообновлений node убран" '[ ! -e "$NODE_APT_CONF_DIR/99-node-no-unattended" ]'
t "apt-daily*.timer возвращены (enable/start)" 'grep -qx "enable apt-daily.timer" "$OUT/systemctl.calls" && grep -qx "enable apt-daily-upgrade.timer" "$OUT/systemctl.calls"'
# выключенные таймеры: штамп «последний запуск = сейчас» — без догоняющего обновления в момент apply
t "таймеры не догоняют пропущенный запуск в момент apply (штамп = сейчас)" '[ -e "$NODE_SYSTEMD_TIMERS_DIR/stamp-apt-daily.timer" ] && [ -e "$NODE_SYSTEMD_TIMERS_DIR/stamp-apt-daily-upgrade.timer" ] && [ $(( $(date +%s) - $(stat -c %Y "$NODE_SYSTEMD_TIMERS_DIR/stamp-apt-daily-upgrade.timer") )) -lt 60 ]'
t "docker/containerd исключены из автообновлений" 'grep -q "Package-Blacklist { \"^docker-\" ; \"^containerd\" ; };" "$NODE_APT_CONF_DIR/52-node-unattended-vpn"'
t "авто-reboot выключен" 'grep -q "Automatic-Reboot \"false\"" "$NODE_APT_CONF_DIR/52-node-unattended-vpn"'
t "needrestart не перезапускает docker/containerd" 'grep -qF "\$nrconf{override_rc}{qr(^docker)} = 0;" "$NODE_NEEDRESTART_DIR/conf.d/90-node-vpn.conf" && grep -qF "qr(^containerd)" "$NODE_NEEDRESTART_DIR/conf.d/90-node-vpn.conf"'
if command -v perl >/dev/null 2>&1; then
    t "needrestart drop-in — валидный perl, docker под override, ssh — нет" 'perl -e '"'"'our %nrconf; do $ARGV[0]; die if $@; my ($d,$s)=(0,0); for my $k (keys %{$nrconf{override_rc}}) { $d=1 if "docker.service" =~ $k; $s=1 if "ssh.service" =~ $k } exit !($d && !$s)'"'"' "$NODE_NEEDRESTART_DIR/conf.d/90-node-vpn.conf"'
fi
# защита needrestart — и при выключенных автообновлениях (ручной apt upgrade)
rm -rf "$NODE_NEEDRESTART_DIR/conf.d"; node_needrestart_protect
t "needrestart-защита ставится отдельно от автообновлений" 'grep -qF "qr(^docker)" "$NODE_NEEDRESTART_DIR/conf.d/90-node-vpn.conf"'
t "дефолт: автообновления выключены (HARDEN_UNATTENDED=1)" 'grep -qx "HARDEN_UNATTENDED=1" "$NODE_DIR/node.defaults.conf"'
# чужой (не созданный node) выключатель не трогаем
echo 'x' > "$NODE_APT_CONF_DIR/99-node-no-unattended"; : > "$NODE_STATE_DIR/file-origins.tsv"
node_unattended_safe_apply >/dev/null 2>&1
t "чужой 99-node-no-unattended не удаляется" '[ -e "$NODE_APT_CONF_DIR/99-node-no-unattended" ]'
# снапшот сервиса без «лишней» строки unknown (is-active: вывод И rc!=0)
rm -f "$NODE_STATE_DIR/services-state.tsv"; node_svc_snapshot thermald.service
t "снапшот сервиса — одна строка (is-active inactive rc=3 не даёт «unknown»)" '[ "$(wc -l < "$NODE_STATE_DIR/services-state.tsv")" = 1 ] && grep -qx "thermald.service	disabled	inactive" "$NODE_STATE_DIR/services-state.tsv"'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: unattended-safe"; else cat "$OUT/run.log"; echo "FAILED: $fails"; exit 1; fi
