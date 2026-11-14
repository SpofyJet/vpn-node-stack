#!/bin/bash
# node — тест: предел ожидания сети при загрузке (v1.2.12, BOOT_NET_WAIT_SEC, lib/boot.sh).
# Нода с IPv6 в netplan и выключенным IPv6 в ядре ждала сеть 120 с при каждой перезагрузке:
# drop-in ограничивает systemd-networkd-wait-online. Проверяем содержимое drop-in, условия
# (юнит включён, бинарь есть, версия systemd), daemon-reload только при изменении, 0 = убрать,
# DRY_RUN, мусор в конфиге. systemctl и systemd-networkd-wait-online — заглушки, drop-in — во
# временном каталоге (NODE_WAIT_ONLINE_DROPIN): настоящие юниты и сеть не затрагиваются.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"   # mktemp кода стека (план sysctl, кэш конфига) — внутрь $OUT, уйдёт вместе с ним
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/lib"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
DROPDIR="$OUT/etc/systemd/system/systemd-networkd-wait-online.service.d"
export NODE_WAIT_ONLINE_DROPIN="$DROPDIR/90-node-timeout.conf" NODE_WAIT_ONLINE_BIN="$OUT/lib/systemd-networkd-wait-online"
: > "$NODE_CONFIG"
# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_systemctl_install "$OUT/bin" "$OUT/mock"
export PATH="$OUT/bin:$PATH"
# заглушка бинаря: справка как у systemd 255 (WAIT_OLD=1 — как у systemd < 242, без --any и -o)
cat > "$NODE_WAIT_ONLINE_BIN" <<'EOF'
#!/bin/sh
echo "run $*" >> "${WAIT_CALLS:-/dev/null}"
if [ "${WAIT_OLD:-0}" = 1 ]; then
    printf '%s\n' "  -h --help                 Show this help" "  -i --interface=INTERFACE  Block until at least these interfaces have appeared" "     --timeout=SECS         Maximum time to wait for network connectivity"
else
    printf '%s\n' "  -h --help                 Show this help" "  -i --interface=INTERFACE[:MIN_OPERSTATE[:MAX_OPERSTATE]]" "  -o --operational-state=MIN_OPERSTATE[:MAX_OPERSTATE]" "     --any                  Wait until at least one of the interfaces is online" "     --timeout=SECS         Maximum time to wait for network connectivity"
fi
EOF
chmod +x "$NODE_WAIT_ONLINE_BIN"; export WAIT_CALLS="$OUT/wait.calls"; : > "$WAIT_CALLS"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
CONFIG_CACHE="$OUT/config.cache"; export CONFIG_CACHE
cfg() { { printf '%s\n' "$@"; grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"; }
cfg
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/boot.sh"

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
F="$NODE_WAIT_ONLINE_DROPIN"; U=systemd-networkd-wait-online.service
reloads() { grep -c '^daemon-reload$' "$MOCK_SYSTEMCTL_LOG" || true; }
fresh() { rm -rf "${OUT:?}/etc" "${NODE_STATE_DIR:?}"/*; : > "$MOCK_SYSTEMCTL_LOG"; : > "$WAIT_CALLS"; mkunit "$U" enabled active; cfg; }
execs() { grep '^ExecStart=' "$F" | tr '\n' '|'; }

# ---------- 1. по умолчанию: 10 с, --any -o routable ----------
fresh
node_boot_net_wait_apply > "$OUT/run1.log" 2>&1
t "drop-in создан: сброс ExecStart и новая команда с пределом 10 с" '[ "$(execs)" = "ExecStart=|ExecStart=$NODE_WAIT_ONLINE_BIN --any -o routable --timeout=10|" ]'
t "секция [Service] одна, перед ExecStart" '[ "$(grep -c "^\[Service\]$" "$F")" = 1 ] && [ "$(grep -n "^\[Service\]$" "$F" | cut -d: -f1)" -lt "$(grep -n "^ExecStart=$" "$F" | cut -d: -f1)" ]'
t "имя 90-node-timeout.conf: читается после 10-netplan.conf, до zz-* оператора" '[ "$(printf "%s\n" 10-netplan.conf 90-node-timeout.conf zz-spofy-timeout.conf | sort | sed -n 2p)" = 90-node-timeout.conf ]'
t "daemon-reload — один раз" '[ "$(reloads)" = 1 ]'
t "сеть и служба не тронуты: ни restart, ни start/stop, бинарь не запускался на ожидание" '! grep -qE "^(restart|start|stop|reload|enable|disable) " "$MOCK_SYSTEMCTL_LOG" && ! grep -q "timeout" "$WAIT_CALLS"'
t "файл в манифесте и в реестре как созданный node (rollback удалит)" 'grep -qxF "$F" "$NODE_STATE_DIR/applied-files.txt" && awk -F"\t" -v p="$F" "\$1 == p && \$2 == \"created\" { f = 1 } END { exit !f }" "$NODE_STATE_DIR/file-origins.tsv"'
t "права 0644" '[ "$(stat -c %a "$F")" = 644 ]'
if command -v systemd-analyze >/dev/null 2>&1; then
    # синтаксис drop-in глазами systemd: юнит-копия со штатным телом + наш drop-in
    mkdir -p "$OUT/verify/x-wait.service.d"
    printf '[Unit]\nDescription=x\n[Service]\nType=oneshot\nExecStart=/bin/true\n' > "$OUT/verify/x-wait.service"
    sed "s|$NODE_WAIT_ONLINE_BIN|/bin/true|" "$F" > "$OUT/verify/x-wait.service.d/90-node-timeout.conf"
    # чужие юниты сервера verify тоже читает — смотрим только строки про наш юнит
    t "systemd-analyze verify: drop-in разбирается без замечаний" '! SYSTEMD_UNIT_PATH="$OUT/verify:" systemd-analyze verify "$OUT/verify/x-wait.service" 2>&1 | grep -F "x-wait.service"'
else
    echo "skip - systemd-analyze verify (нет systemd-analyze)"
fi

# повторный apply — без изменений: ни записи, ни daemon-reload
before="$(cksum < "$F")"; : > "$MOCK_SYSTEMCTL_LOG"
node_boot_net_wait_apply > "$OUT/run1b.log" 2>&1
t "повторный apply: файл не переписан, daemon-reload не вызывался" '[ "$(cksum < "$F")" = "$before" ] && [ "$(reloads)" = 0 ] && ! ls "$F".pre-node-* >/dev/null 2>&1'

# ---------- 2. другое значение, 0, выключенный юнит ----------
cfg BOOT_NET_WAIT_SEC=25; : > "$MOCK_SYSTEMCTL_LOG"
node_boot_net_wait_apply >/dev/null 2>&1
t "BOOT_NET_WAIT_SEC=25: предел 25 с, daemon-reload" 'grep -qx "ExecStart=$NODE_WAIT_ONLINE_BIN --any -o routable --timeout=25" "$F" && [ "$(reloads)" = 1 ]'
cfg BOOT_NET_WAIT_SEC=0; : > "$MOCK_SYSTEMCTL_LOG"
node_boot_net_wait_apply > "$OUT/run0.log" 2>&1
t "BOOT_NET_WAIT_SEC=0: свой drop-in убран вместе с каталогом и копиями, daemon-reload" '[ ! -e "$F" ] && [ ! -d "$DROPDIR" ] && [ "$(reloads)" = 1 ]'
: > "$MOCK_SYSTEMCTL_LOG"; node_boot_net_wait_apply >/dev/null 2>&1
t "BOOT_NET_WAIT_SEC=0 повторно: ничего не делает" '[ ! -e "$F" ] && [ "$(reloads)" = 0 ]'

fresh; mkunit "$U" disabled inactive
node_boot_net_wait_apply > "$OUT/dis.log" 2>&1
t "юнит выключен (сеть через ifupdown): drop-in не создаётся, daemon-reload нет" '[ ! -e "$F" ] && [ "$(reloads)" = 0 ]'
fresh; rm -f "$MOCK_UNITS/$U"
node_boot_net_wait_apply >/dev/null 2>&1
t "юнита нет: drop-in не создаётся" '[ ! -e "$F" ] && [ "$(reloads)" = 0 ]'
fresh; mkunit "$U" enabled-runtime inactive
node_boot_net_wait_apply >/dev/null 2>&1
t "юнит включён генератором netplan (enabled-runtime): drop-in создан" 'grep -q -- "--timeout=10" "$F"'
# юнит выключили после того, как drop-in был поставлен
fresh; node_boot_net_wait_apply >/dev/null 2>&1; mkunit "$U" disabled inactive; : > "$MOCK_SYSTEMCTL_LOG"
node_boot_net_wait_apply >/dev/null 2>&1
t "юнит выключили позже: свой drop-in убран" '[ ! -e "$F" ] && [ "$(reloads)" = 1 ]'

# чужой файл с нашим именем (в реестре node его нет) не удаляем
fresh; mkdir -p "$DROPDIR"; printf '[Service]\nExecStart=\nExecStart=/bin/true\n' > "$F"; cfg BOOT_NET_WAIT_SEC=0
node_boot_net_wait_apply > "$OUT/foreign.log" 2>&1
t "BOOT_NET_WAIT_SEC=0: файл, созданный не node, оставлен" 'grep -qx "ExecStart=/bin/true" "$F"'
# соседний drop-in оператора не трогаем, каталог с ним не удаляем
fresh; mkdir -p "$DROPDIR"; echo "# оператор" > "$DROPDIR/zz-spofy-timeout.conf"
node_boot_net_wait_apply >/dev/null 2>&1; cfg BOOT_NET_WAIT_SEC=0; node_boot_net_wait_apply >/dev/null 2>&1
t "соседний drop-in оператора цел после установки и снятия нашего" '[ ! -e "$F" ] && grep -q "оператор" "$DROPDIR/zz-spofy-timeout.conf"'

# ---------- 3. старый systemd, нет бинаря ----------
fresh
WAIT_OLD=1 node_boot_net_wait_apply >/dev/null 2>&1
t "systemd без --any/-o (< 242): только предел времени" '[ "$(execs)" = "ExecStart=|ExecStart=$NODE_WAIT_ONLINE_BIN --timeout=10|" ]'
cfg BOOT_NET_WAIT_SEC=25
WAIT_OLD=1 node_boot_net_wait_apply >/dev/null 2>&1
t "systemd < 242: предел берётся из BOOT_NET_WAIT_SEC (25 с)" '[ "$(execs)" = "ExecStart=|ExecStart=$NODE_WAIT_ONLINE_BIN --timeout=25|" ]'
fresh
NODE_WAIT_ONLINE_BIN="$OUT/lib/none" node_boot_net_wait_apply > "$OUT/nobin.log" 2>&1
t "бинаря нет: drop-in не создан, предупреждение, шаг не падает" '[ ! -e "$F" ] && grep -q "не найден" "$OUT/nobin.log"'
t "поиск бинаря: первый существующий из списка" '[ "$(NODE_WAIT_ONLINE_BIN="$OUT/lib/none $OUT/lib/systemd-networkd-wait-online" node_boot_net_wait_bin)" = "$OUT/lib/systemd-networkd-wait-online" ]'

# ---------- 4. мусор в конфиге ----------
for bad in abc 999 121 -5 10s 1.5 '10;reboot' '$(id)'; do
    fresh; cfg "BOOT_NET_WAIT_SEC=$bad"
    node_boot_net_wait_apply > "$OUT/bad.log" 2>&1
    t "BOOT_NET_WAIT_SEC='$bad': берётся 10, в ExecStart только число" '[ "$(execs)" = "ExecStart=|ExecStart=$NODE_WAIT_ONLINE_BIN --any -o routable --timeout=10|" ] && grep -q "берём 10" "$OUT/bad.log"'
done
for good in 1 120 010; do
    fresh; cfg "BOOT_NET_WAIT_SEC=$good"; node_boot_net_wait_apply >/dev/null 2>&1
    t "BOOT_NET_WAIT_SEC=$good принимается" 'grep -qx "ExecStart=$NODE_WAIT_ONLINE_BIN --any -o routable --timeout=$((10#$good))" "$F"'
done
fresh; cfg "BOOT_NET_WAIT_SEC="
node_boot_net_wait_apply >/dev/null 2>&1
t "пустое значение = по умолчанию 10" 'grep -q -- "--timeout=10$" "$F"'

# ---------- 5. DRY_RUN, план, status ----------
fresh
DRY_RUN=1 node_boot_net_wait_apply > "$OUT/dry.log" 2>&1
t "DRY_RUN: файла нет, каталог не создан, systemctl не вызывался" '[ ! -e "$F" ] && [ ! -d "$DROPDIR" ] && [ ! -s "$MOCK_SYSTEMCTL_LOG" ] && [ ! -e "$NODE_STATE_DIR/applied-files.txt" ]'
t "DRY_RUN: в журнале сказано, что было бы сделано" 'grep -q "would limit" "$OUT/dry.log"'
t "plan: строка с пределом" 'node_boot_net_wait_plan | grep -q "не дольше 10 с"'
cfg BOOT_NET_WAIT_SEC=0
t "plan: 0 — не ограничиваем" 'node_boot_net_wait_plan | grep -q "BOOT_NET_WAIT_SEC=0"'
t "status: 0 и нет файла" 'node_boot_net_wait_status | grep -q "план=не ограничивать drop-in=нет (юнит включён)"'
fresh; node_boot_net_wait_apply >/dev/null 2>&1
t "status: план и факт 10 с" 'node_boot_net_wait_status | grep -q "план=10 с drop-in=10 с (юнит включён)"'
t "apply.sh: шаг и строка плана подключены, значение в контракте" 'grep -q "node_step_run boot_net_wait  *node_boot_net_wait_apply" "$NODE_DIR/apply.sh" && grep -q "node_boot_net_wait_plan" "$NODE_DIR/apply.sh" && grep -q "boot_net_wait:\$(node_conf_get BOOT_NET_WAIT_SEC 10)" "$NODE_DIR/apply.sh"'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: boot-net-wait (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
