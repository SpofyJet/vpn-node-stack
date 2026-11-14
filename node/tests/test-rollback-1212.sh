#!/bin/bash
# node — тест: v1.2.12 одним циклом — apply → повторный apply → rollback для четырёх новинок сразу
# (kernel.panic, фоновые службы, предел ожидания сети при загрузке, sshd), по настоящим путям.
#   A. чистая нода: всё ставится; повторный apply ничего не переписывает и не перечитывает;
#      `main.sh rollback` возвращает исходное — файлы стека и каталог drop-in удалены, kernel.panic
#      и юниты как до node (маски сняты), sshd перечитал конфиг, реестры пусты;
#   B. нода после 1.2.11 и разовых скриптов 14.11 (их файлы на месте, юниты уже выключены):
#      apply и rollback чужие файлы не трогают, после отката действуют настройки разовых скриптов;
#      стек sshd не настраивал (флаги 0) — откат sshd не перечитывает;
#   C. DRY_RUN: шаги apply ничего не меняют; `main.sh --dry-run apply` показывает новые пункты плана.
# Apply — отдельным процессом: те же функции и тем же порядком, что в node_apply (apply.sh), но
# только шаги 1.2.12 — весь node_apply настраивает сетевую карту, conntrack и ядро сервера.
# Rollback — настоящий `main.sh rollback`.
#
# Изоляция: только root и свой mount namespace. tmpfs ложится поверх всех каталогов, с которыми
# стек работает по настоящим путям (список SANDBOX), а systemctl, sysctl, sshd, tc, nft, udevadm,
# update-grub, grub-editenv, ethtool, modprobe — заглушки в PATH: живой сервер не затрагивается.
# Без root или unshare — SKIP (77). Каталоги из SANDBOX, которых на машине нет, создаются пустыми.
set -euo pipefail

command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
[ "$(id -u)" -eq 0 ] || { echo "SKIP: нужен root (свой mount namespace)"; exit 77; }
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: unshare -m недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 NODE_TEST_OUTER_MNT="$(readlink /proc/self/ns/mnt)" exec unshare -m bash "$0" "$@"
fi
# fail-closed: дальше tmpfs ложится поверх /etc/ssh, /etc/systemd/system, /var/lib/node… — это
# допустимо только в своём mount namespace (переменная NODE_TEST_IN_NS сама по себе — не гарантия)
if [ -z "${NODE_TEST_OUTER_MNT:-}" ] || [ "$(readlink /proc/self/ns/mnt)" = "$NODE_TEST_OUTER_MNT" ]; then
    echo "SKIP: нет своего mount namespace — tmpfs лёг бы поверх живых каталогов сервера"; exit 77
fi
mount --make-rprivate /

SANDBOX="/var/lib/node /etc/node /etc/node-profile.d /run/node /var/log /usr/local/sbin /etc/systemd/system /etc/udev/rules.d /etc/sysctl.d /etc/default /etc/ssh /etc/apt/apt.conf.d /etc/needrestart /etc/modprobe.d /etc/modules-load.d /etc/nftables.d"
# реестр ключей shieldnode живого сервера не читаем (каталог не создаём: нет его — нет и реестра)
if [ -d /var/lib/shieldnode ]; then SANDBOX="$SANDBOX /var/lib/shieldnode"; fi
# каталоги, где после отката не должно остаться ничего от node
ETC_DIRS="/usr/local/sbin /etc/systemd/system /etc/udev/rules.d /etc/sysctl.d /etc/default /etc/ssh /etc/apt/apt.conf.d /etc/needrestart"
SANDBOX_UP=0
sandbox() { # пустые каталоги: tmpfs поверх настоящих; повторный вызов — прежний tmpfs снимается
    local d
    for d in $SANDBOX; do
        if [ "$SANDBOX_UP" = 1 ]; then umount "$d"; else mkdir -p "$d"; fi
        mount -t tmpfs t "$d"
    done
    SANDBOX_UP=1
}

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"   # mktemp кода стека (план sysctl, кэш конфига) — внутрь $OUT, уйдёт вместе с ним
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/sys-block"
# окружение — как его выставляет main.sh; конфиг — /etc/node/node.conf (в песочнице)
unset NODE_CONFIG CONFIG_CACHE NODE_SSHD_CONFIG NODE_SSHD_DIR NODE_WAIT_ONLINE_DROPIN NODE_APT_CONF_DIR NODE_NEEDRESTART_DIR
export NODE_DIR NODE_STATE_DIR=/var/lib/node NODE_DIAG_DIR=/var/lib/node/diagnostics NODE_PROFILE_DIR=/etc/node-profile.d
export NODE_LOG=/var/log/node.log NODE_LOCK=/run/node/node.lock DRY_RUN=0 NO_COLOR=1
# то, что код читает с машины, а ответ должен быть один на любой машине
export NODE_SYS_BLOCK="$OUT/sys-block" NODE_MULTIPATH_WWIDS="$OUT/wwids" NODE_PROC_MDSTAT="$OUT/mdstat"
export NODE_DISPATCHER_DIRS="$OUT/dispatcher" NODE_SYSTEMD_TIMERS_DIR="$OUT/timers"
export NODE_WAIT_ONLINE_BIN="$OUT/lib/systemd-networkd-wait-online"
export NODE_SSHD_BIN="$OUT/bin/sshd" NODE_SSH_ROOT_KEYS="$OUT/root-keys" NODE_SSH_KEYGEN_BIN=/nonexistent
export SSHD_CALLS="$OUT/sshd.calls" OTHER_CALLS="$OUT/other.calls"

# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_systemctl_install "$OUT/bin" "$OUT/mock"
mock_sysctl_install "$OUT/bin" "$OUT/mock"
mock_sshd_install "$OUT/bin"
# остальное, что зовёт rollback и что на живом сервере что-то меняет, — пустые заглушки с журналом
for c in tc nft udevadm update-grub grub-editenv ethtool modprobe; do
    printf '#!/bin/sh\necho "%s $*" >> "$OTHER_CALLS"\nexit 0\n' "$c" > "$OUT/bin/$c"
done
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "  -o --operational-state=MIN_OPERSTATE[:MAX_OPERSTATE]" "     --any                  Wait until at least one of the interfaces is online" "     --timeout=SECS         Maximum time to wait for network connectivity"' > "$NODE_WAIT_ONLINE_BIN"
chmod +x "$OUT/bin"/* "$NODE_WAIT_ONLINE_BIN"
export PATH="$OUT/bin:$PATH"

# шаги node_apply, относящиеся к 1.2.12, — тем же порядком (см. проверку порядка в конце теста)
cat > "$OUT/apply-steps.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/apply.sh"
# ---- plan ----
source "$NODE_DIR/lib/sysctl.sh";   node_sysctl_plan_init
node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn 65535     # ключ, которым стек владел и до 1.2.12
source "$NODE_DIR/lib/kernel.sh";   node_panic_plan
source "$NODE_DIR/lib/services.sh"; node_services_plan
source "$NODE_DIR/lib/boot.sh";     node_boot_net_wait_plan
source "$NODE_DIR/lib/sshd.sh";     node_sshd_plan
# ---- persist + apply ----
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_sysctl_write
node_sysctl_apply
node_step_run sysctl_restore_dropped node_sysctl_restore_dropped
node_step_run services_apply         node_services_apply
node_step_run boot_net_wait          node_boot_net_wait_apply
node_step_run sshd_apply             node_sshd_apply
node_step_run sysctl_owner_dump      node_sysctl_owner_dump
exit "$NODE_STEP_RC"
EOF

DROPDIR=/etc/systemd/system/systemd-networkd-wait-online.service.d
DROPIN="$DROPDIR/90-node-timeout.conf"; SSHD_D=/etc/ssh/sshd_config.d
LIM="$SSHD_D/01-node-limits.conf"; KEYS="$SSHD_D/00-node-keys-only.conf"; Z0=/etc/sysctl.d/99-z0-node-base.conf
ST=/var/lib/node
# файлы разовых скриптов оператора (14.11), которые делали то же до 1.2.12: стоят рядом, стек их не трогает
ONEOFF="/etc/sysctl.d/99-z9-spofy-panic.conf $DROPDIR/zz-spofy-timeout.conf $SSHD_D/01-spofy-limits.conf $SSHD_D/00-spofy-keys-only.conf"
NEW_OFF="multipathd.service multipathd.socket fwupd-refresh.timer networkd-dispatcher.service unattended-upgrades.service man-db.timer apport-autoreport.timer apport-autoreport.path update-notifier-download.timer update-notifier-motd.timer ua-timer.timer snapd.snap-repair.timer mdcheck_start.timer mdcheck_continue.timer mdmonitor-oneshot.timer"

# server <stock|oneoff> — сервер «как от хостера»; oneoff — после разовых скриптов 14.11
server() {
    local u
    sandbox
    rm -rf "$MOCK_UNITS"; mkdir -p "$MOCK_UNITS"; mock_units_stock_node
    mkunit ssh.service disabled active; mkunit ssh.socket enabled active   # Ubuntu 24.04: sshd за сокетом
    mkunit systemd-networkd.service enabled active
    mkunit systemd-networkd-wait-online.service enabled inactive
    mkunit packagekit.service static inactive static
    printf '%s\n' kernel.panic=0 kernel.panic_on_oops=0 net.core.somaxconn=4096 > "$SYSDB"
    printf '# test sshd_config\nInclude /etc/ssh/sshd_config.d/*.conf\nPort 22\nUsePAM yes\n' > /etc/ssh/sshd_config
    mkdir -p "$SSHD_D"; printf 'PasswordAuthentication yes\n' > "$SSHD_D/50-cloud-init.conf"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake test-key\n' > "$NODE_SSH_ROOT_KEYS"
    if [ "$1" = oneoff ]; then
        printf '# Spofy 14.11.2026\nkernel.panic = 10\nkernel.panic_on_oops = 1\n' > /etc/sysctl.d/99-z9-spofy-panic.conf
        printf '%s\n' kernel.panic=10 kernel.panic_on_oops=1 net.core.somaxconn=4096 > "$SYSDB"
        mkdir -p "$DROPDIR"
        printf '# 14.11.2026 (spofy)\n[Service]\nExecStart=\nExecStart=/lib/systemd/systemd-networkd-wait-online --any -o routable --timeout=10\n' > "$DROPDIR/zz-spofy-timeout.conf"
        printf '# Spofy 14.11.2026\nLoginGraceTime 30\nMaxStartups 60:30:200\nPerSourceMaxStartups 10\nPerSourceNetBlockSize 24:64\n' > "$SSHD_D/01-spofy-limits.conf"
        printf '# Spofy 13.11.2026\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$SSHD_D/00-spofy-keys-only.conf"
        # bg-off.sh: список выключен, а ModemManager, udisks2, fwupd, upower ещё и замаскированы
        for u in $NEW_OFF; do mkunit "$u" disabled inactive; done
        for u in ModemManager.service udisks2.service upower.service; do mkunit "$u" masked inactive; done
        mkunit fwupd.service masked inactive static
    fi
    : > "$MOCK_SYSTEMCTL_LOG"; : > "$SYSCALLS"; : > "$SSHD_CALLS"; : > "$OTHER_CALLS"
}
conf()     { printf '%s\n' "$@" > /etc/node/node.conf; }
apply()    { rc=0; bash "$OUT/apply-steps.sh" > "$OUT/apply.log" 2>&1 || rc=$?; }
rollback() { rc=0; bash "$NODE_DIR/main.sh" rollback > "$OUT/rollback.log" 2>&1 || rc=$?; }
sysv()  { awk -F= -v k="$1" '$1 == k { print $2 }' "$SYSDB"; }
eff()   { SSHD_CALLS=/dev/null "$NODE_SSHD_BIN" -T -f /etc/ssh/sshd_config 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'; }
ncall() { grep -c "^$1" "$MOCK_SYSTEMCTL_LOG" || true; }   # сколько вызовов systemctl <команда…>
is()    { [ "$(ustate "$1")" = "$2" ]; }
units() { local f; for f in "$MOCK_UNITS"/*; do echo "$(basename "$f") $(ustate "$(basename "$f")")"; done; }
all_off() { local u; for u in "$@"; do is "$u" disabled/inactive || return 1; done; }
same_units() { local u; for u in "$@"; do grep -qxF "$u $(ustate "$u")" "$OUT/units.before" || return 1; done; }
in_manifest() { local f; for f in "$@"; do grep -qxF -- "$f" "$ST/applied-files.txt" || return 1; done; }
orig()  { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$ST/sysctl-orig.tsv" 2>/dev/null; }
# shellcheck disable=SC2086  # списки каталогов и файлов — по словам
etc_files() { find $ETC_DIRS -type f | sort; }
# отпечаток всего, что apply мог бы изменить: файлы, значения ядра, состояния юнитов
# shellcheck disable=SC2086
fp() { { find $ETC_DIRS -type f -exec cksum {} + | sort -k3; cat "$SYSDB"; units; } | cksum; }
# shellcheck disable=SC2086
oneoff_sum() { cksum $ONEOFF; }
host_sum() { cksum /etc/ssh/sshd_config "$SSHD_D/50-cloud-init.conf"; }

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

# =================== A. чистая нода ===================
server stock; conf HARDEN_SSH_PASSWORD_OFF=1
units > "$OUT/units.before"; etc_files > "$OUT/files.before"; HOST_SUM="$(host_sum)"
apply
t "A: apply без ошибок" '[ "$rc" = 0 ]'
t "A: kernel.panic=10 и panic_on_oops=1 — в файле стека и в ядре" 'grep -qx "kernel.panic = 10" "$Z0" && grep -qx "kernel.panic_on_oops = 1" "$Z0" && [ "$(sysv kernel.panic)" = 10 ] && [ "$(sysv kernel.panic_on_oops)" = 1 ]'
t "A: исходные значения записаны: 0, 0, somaxconn 4096" '[ "$(orig kernel.panic)" = 0 ] && [ "$(orig kernel.panic_on_oops)" = 0 ] && [ "$(orig net.core.somaxconn)" = 4096 ]'
t "A: фон выключен: ModemManager, udisks2 и весь новый список" 'all_off ModemManager.service udisks2.service $NEW_OFF'
t "A: fwupd, upower, packagekit замаскированы" 'is fwupd.service masked/inactive && is upower.service masked/inactive && is packagekit.service masked/inactive'
t "A: ssh, сеть, docker, время, cron не тронуты" 'same_units ssh.service ssh.socket systemd-networkd.service systemd-networkd-wait-online.service docker.service systemd-timesyncd.service cron.service'
t "A: drop-in ожидания сети по настоящему пути: 10 с" 'grep -qx "ExecStart=$NODE_WAIT_ONLINE_BIN --any -o routable --timeout=10" "$DROPIN"'
t "A: sshd: оба файла; действует 30 с, 60:30:200, вход по паролю выключен" '[ -f "$LIM" ] && [ -f "$KEYS" ] && [ "$(eff logingracetime)" = 30 ] && [ "$(eff maxstartups)" = 60:30:200 ] && [ "$(eff passwordauthentication)" = no ]'
t "A: sshd перечитан один раз (reload, не restart), юниты перечитаны один раз" '[ "$(ncall "reload ssh.service")" = 1 ] && [ "$(ncall restart)" = 0 ] && [ "$(ncall daemon-reload)" = 1 ]'
t "A: четыре новых файла — в манифесте" 'in_manifest "$Z0" "$DROPIN" "$LIM" "$KEYS"'
t "A: основной sshd_config и файл хостера не изменены" '[ "$(host_sum)" = "$HOST_SUM" ]'

# повторный apply: ничего не переписано, ничего не перечитано (99-z0 не сверяем: в нём дата)
SUMS="$(cksum "$DROPIN" "$LIM" "$KEYS" "$ST/sysctl-orig.tsv" "$ST/services-state.tsv")"; : > "$MOCK_SYSTEMCTL_LOG"
apply
t "A: повторный apply без ошибок; файлы и реестры исходных значений те же" '[ "$rc" = 0 ] && [ "$(cksum "$DROPIN" "$LIM" "$KEYS" "$ST/sysctl-orig.tsv" "$ST/services-state.tsv")" = "$SUMS" ]'
t "A: повторный apply: sshd и юниты не перечитывались, копий файлов нет" '[ "$(ncall "reload ")" = 0 ] && [ "$(ncall daemon-reload)" = 0 ] && [ -z "$(find "$DROPDIR" "$SSHD_D" -name "*.pre-node-*")" ]'
t "A: повторный apply: значения в ядре прежние" '[ "$(sysv kernel.panic)" = 10 ] && [ "$(sysv kernel.panic_on_oops)" = 1 ] && [ "$(sysv net.core.somaxconn)" = 65535 ]'

: > "$MOCK_SYSTEMCTL_LOG"; : > "$SSHD_CALLS"; : > "$SYSCALLS"; : > "$OTHER_CALLS"
rollback
t "A: main.sh rollback без ошибок" '[ "$rc" = 0 ]'
t "A: откат: sshd -t, затем один reload ssh.service (не restart)" 'grep -qx -- "-t -f /etc/ssh/sshd_config" "$SSHD_CALLS" && [ "$(ncall "reload ssh.service")" = 1 ] && [ "$(ncall restart)" = 0 ]'
t "A: откат: файлы sshd стека удалены; вход по паролю и пределы — как до node" '[ ! -e "$LIM" ] && [ ! -e "$KEYS" ] && [ "$(eff passwordauthentication)" = yes ] && [ "$(eff maxstartups)" = 10:30:100 ] && [ "$(eff logingracetime)" = 120 ]'
t "A: откат: drop-in и его каталог удалены, юниты перечитаны" '[ ! -e "$DROPIN" ] && [ ! -d "$DROPDIR" ] && [ "$(ncall daemon-reload)" -ge 1 ]'
t "A: откат: файл sysctl удалён; kernel.panic, panic_on_oops, somaxconn — исходные 0, 0, 4096" '[ ! -e "$Z0" ] && [ "$(sysv kernel.panic)" = 0 ] && [ "$(sysv kernel.panic_on_oops)" = 0 ] && [ "$(sysv net.core.somaxconn)" = 4096 ]'
t "A: откат: все юниты в исходном состоянии (маски fwupd, upower, packagekit сняты)" 'units | cmp -s - "$OUT/units.before"'
t "A: откат: реестры стека пусты" '[ ! -e "$ST/sysctl-orig.tsv" ] && [ ! -e "$ST/services-state.tsv" ] && [ ! -e "$ST/file-origins.tsv" ] && [ ! -s "$ST/applied-files.txt" ] && [ ! -s "$ST/owner-keys.txt" ]'
t "A: откат: в каталогах сервера остались только файлы, бывшие до node" 'etc_files | cmp -s - "$OUT/files.before"'
t "A: откат: основной sshd_config и файл хостера не изменены" '[ "$(host_sum)" = "$HOST_SUM" ]'
t "A: откат: очереди сетевой карты не трогались, sysctl --system не вызывался" '! grep -q "qdisc del" "$OTHER_CALLS" && ! grep -q -- "--system" "$SYSCALLS"'

# =================== B. нода после 1.2.11 и разовых скриптов 14.11 ===================
server oneoff
units > "$OUT/units.before"; ONEOFF_SUM="$(oneoff_sum)"; HOST_SUM="$(host_sum)"
conf HARDEN_PANIC_REBOOT=0 HARDEN_SSHD_LIMITS=0 HARDEN_SSH_PASSWORD_OFF=0 BOOT_NET_WAIT_SEC=0   # что оставил стек 1.2.11
apply
t "B: «как после 1.2.11»: новых файлов стека нет, в 99-z0 нет kernel.panic" '[ "$rc" = 0 ] && [ ! -e "$DROPIN" ] && [ ! -e "$LIM" ] && [ ! -e "$KEYS" ] && [ -f "$Z0" ] && ! grep -q "^kernel\.panic" "$Z0"'
conf HARDEN_SSH_PASSWORD_OFF=1; : > "$MOCK_SYSTEMCTL_LOG"
apply
t "B: apply 1.2.12 без ошибок, файлы разовых скриптов не тронуты" '[ "$rc" = 0 ] && [ "$(oneoff_sum)" = "$ONEOFF_SUM" ]'
t "B: файлы стека встали рядом: kernel.panic в 99-z0, drop-in, два файла sshd" 'grep -qx "kernel.panic = 10" "$Z0" && [ -f "$DROPIN" ] && [ -f "$LIM" ] && [ -f "$KEYS" ]'
t "B: sshd -t принимает оба набора; действует то же: 60:30:200, вход по паролю выключен" 'SSHD_CALLS=/dev/null "$NODE_SSHD_BIN" -t -f /etc/ssh/sshd_config && [ "$(eff maxstartups)" = 60:30:200 ] && [ "$(eff passwordauthentication)" = no ]'
t "B: уже выключенные юниты не трогались" '! grep -qE "^(disable|stop|mask|enable|start) .*(multipathd|man-db|networkd-dispatcher|mdcheck|ua-timer|unattended-upgrades)" "$MOCK_SYSTEMCTL_LOG"'
t "B: замаскированное разовым скриптом осталось замаскированным" 'is ModemManager.service masked/inactive && is udisks2.service masked/inactive && is fwupd.service masked/inactive && is upower.service masked/inactive'
t "B: исходным для kernel.panic записано то, что оставил разовый скрипт (10 и 1)" '[ "$(orig kernel.panic)" = 10 ] && [ "$(orig kernel.panic_on_oops)" = 1 ]'
: > "$MOCK_SYSTEMCTL_LOG"; : > "$SSHD_CALLS"
rollback
t "B: main.sh rollback без ошибок, файлы разовых скриптов не тронуты" '[ "$rc" = 0 ] && [ "$(oneoff_sum)" = "$ONEOFF_SUM" ] && [ "$(host_sum)" = "$HOST_SUM" ]'
t "B: откат: файлы стека удалены, каталог drop-in с чужим файлом остался" '[ ! -e "$Z0" ] && [ ! -e "$DROPIN" ] && [ ! -e "$LIM" ] && [ ! -e "$KEYS" ] && [ -f "$DROPDIR/zz-spofy-timeout.conf" ]'
t "B: откат: вход по паролю остаётся выключенным, пределы действуют (их держат разовые файлы)" '[ "$(eff passwordauthentication)" = no ] && [ "$(eff maxstartups)" = 60:30:200 ] && [ "$(ncall "reload ssh.service")" = 1 ]'
t "B: откат: kernel.panic остаётся 10 и 1 (их держит разовый файл), somaxconn возвращён" '[ "$(sysv kernel.panic)" = 10 ] && [ "$(sysv kernel.panic_on_oops)" = 1 ] && [ "$(sysv net.core.somaxconn)" = 4096 ]'
t "B: откат: юниты — как оставил разовый скрипт (выключены, четыре службы замаскированы)" 'units | cmp -s - "$OUT/units.before"'

# стек sshd и загрузку не настраивал (флаги 0) — откату нечего перечитывать
server stock; conf HARDEN_SSHD_LIMITS=0 BOOT_NET_WAIT_SEC=0
units > "$OUT/units.before"
apply; rc_apply="$rc"; : > "$MOCK_SYSTEMCTL_LOG"; : > "$SSHD_CALLS"
rollback
t "B: флаги 0: откат без ошибок, sshd не проверялся и не перечитывался, юниты как были" '[ "$rc_apply" = 0 ] && [ "$rc" = 0 ] && [ ! -s "$SSHD_CALLS" ] && [ "$(ncall "reload ")" = 0 ] && units | cmp -s - "$OUT/units.before"'

# =================== C. DRY_RUN ===================
server stock; conf HARDEN_SSH_PASSWORD_OFF=1
FP="$(fp)"
# шаги apply с DRY_RUN=1 (настоящий node_apply при --dry-run до них не доходит — проверка с запасом);
# owner-keys.txt не в счёт: его пишет node_sysctl_owner_dump, который про DRY_RUN не знает
DRY_RUN=1 apply
t "C: DRY_RUN=1: шаги apply без ошибок и ничего не изменили — файлы, ядро, юниты" '[ "$rc" = 0 ] && [ "$(fp)" = "$FP" ]'
t "C: DRY_RUN=1: ни одной меняющей команды systemctl, ни одной записи sysctl, реестров нет" '[ ! -s "$MOCK_SYSTEMCTL_LOG" ] && ! grep -qE "^-(w|qw|p) " "$SYSCALLS" && [ -z "$(find "$ST" -type f ! -name owner-keys.txt)" ]'
rm -f "$ST/owner-keys.txt"
# настоящий вход: main.sh --dry-run apply (план целиком; чтение остальных ключей — настоящим sysctl)
rc=0; SYSCTL_PASS=1 bash "$NODE_DIR/main.sh" --dry-run apply > "$OUT/dry.log" 2>&1 || rc=$?
t "C: main.sh --dry-run apply: rc=0; в плане kernel.panic, sshd и ожидание сети" '[ "$rc" = 0 ] && grep -qE "kernel\.panic[[:space:]]+10" "$OUT/dry.log" && grep -qE "kernel\.panic_on_oops[[:space:]]+1" "$OUT/dry.log" && grep -q "sshd: plan: limits=1 .*password_off=1" "$OUT/dry.log" && grep -q "boot: plan: ожидание сети при загрузке — не дольше 10 с" "$OUT/dry.log"'
t "C: main.sh --dry-run apply ничего не изменил" '[ "$(fp)" = "$FP" ] && [ ! -s "$MOCK_SYSTEMCTL_LOG" ] && ! grep -qE "^-(w|qw|p) " "$SYSCALLS" && [ ! -e "$ST/applied-files.txt" ]'

# =================== D. порядок шагов в apply.sh — тот же, что в прогоне этого теста ===================
t "apply.sh: kernel.panic попадает в план (node_panic_plan после node_bbr_plan)" 'grep -qE "node_bbr_plan; node_panic_plan" "$NODE_DIR/apply.sh"'
t "apply.sh: boot_net_wait и sshd_apply — после служб и limits, до настройки сетевой карты" '[ "$(grep -oE "node_step_run (services_apply|limits_persist|boot_net_wait|sshd_apply|nic_diag) " "$NODE_DIR/apply.sh" | awk "{ print \$2 }" | tr "\n" " ")" = "services_apply limits_persist boot_net_wait sshd_apply nic_diag " ]'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rollback-1212 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
