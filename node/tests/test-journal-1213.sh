#!/bin/bash
# node — тест: журнал ядра без строки на каждый отброшенный пакет (v1.2.13, lib/journal.sh).
#   QUIET_NFT_PACKET_LOG=1 -> /etc/rsyslog.d/10-node-nftlog.conf: строки ядра «torrent-blocker: » и
#   «ingress-filter-ip: » (нода Remnawave пишет их на каждый отброшенный пакет) в файлы не попадают.
# Проверяем: текст файла, rsyslogd -N1 до и после записи, возврат при ошибке, перезапуск rsyslog
# только при изменении и только работающего, пропуск без rsyslog, выключение флага, DRY_RUN,
# предупреждение и строку status, когда нода всё ещё пишет каждый пакет, откат и проводку в apply /
# rollback / status. rsyslogd, systemctl и nft — заглушки, каталог rsyslog.d — временный
# (NODE_RSYSLOG_DIR): настоящий /etc/rsyslog.d не читается и не меняется, настоящий rsyslog не
# перезапускается. В конце — сверка текста файла с НАСТОЯЩИМ rsyslogd (-N1 -f на копии, только
# чтение), если он есть и ему разрешено читать временный каталог.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/rsyslog.d"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
export NODE_RSYSLOG_DIR="$OUT/rsyslog.d" NODE_RSYSLOGD_BIN="$OUT/bin/rsyslogd" RSYSLOG_CALLS="$OUT/rsyslogd.calls" NFT_RULES="$OUT/nft.rules"
: > "$NODE_CONFIG"; : > "$RSYSLOG_CALLS"; : > "$NFT_RULES"
# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_systemctl_install "$OUT/bin" "$OUT/mock"
REAL_RSYSLOGD="$(command -v rsyslogd 2>/dev/null || true)"; [ -n "$REAL_RSYSLOGD" ] || { [ -x /usr/sbin/rsyslogd ] && REAL_RSYSLOGD=/usr/sbin/rsyslogd; } || true
export PATH="$OUT/bin:$PATH"

# заглушка rsyslogd: -N1 — проверка конфига. MOCK_RSYSLOG_BROKEN=1 — конфиг сломан ещё до нас;
# MOCK_RSYSLOG_REJECT=1 — rsyslogd отвергает именно файл стека
cat > "$OUT/bin/rsyslogd" <<'MOCK'
#!/bin/bash
echo "$*" >> "${RSYSLOG_CALLS:-/dev/null}"
echo "rsyslogd: version 8.2312.0, config validation run (level 1), master config /etc/rsyslog.conf"
if [ "${MOCK_RSYSLOG_BROKEN:-0}" = 1 ]; then
    echo "rsyslogd: error during parsing file /etc/rsyslog.d/99-other.conf, on or before line 3: syntax error"; exit 1
fi
if [ "${MOCK_RSYSLOG_REJECT:-0}" = 1 ] && [ -f "$NODE_RSYSLOG_DIR/10-node-nftlog.conf" ]; then
    echo "rsyslogd: error during parsing file $NODE_RSYSLOG_DIR/10-node-nftlog.conf, on or before line 5: invalid character"; exit 1
fi
echo "rsyslogd: End of config validation run. Bye."
MOCK
# заглушка nft: `nft -t list ruleset` печатает правила из $NFT_RULES
cat > "$OUT/bin/nft" <<'MOCK'
#!/bin/bash
case "$*" in "-t list ruleset") cat "${NFT_RULES:-/dev/null}" ;; esac
exit 0
MOCK
chmod +x "$OUT/bin/rsyslogd" "$OUT/bin/nft"
id() { echo 0; }   # чтение правил nft в lib/journal.sh — только под root

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
CONFIG_CACHE="$OUT/config.cache"; export CONFIG_CACHE
cfg() { { printf '%s\n' "$@"; grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"; }
cfg
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/journal.sh"

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
F="$NODE_RSYSLOG_FILE"
nlog() { grep -c "^$1" "$MOCK_SYSTEMCTL_LOG" || true; }
ncheck() { grep -c -- '-N1' "$RSYSLOG_CALLS" || true; }
# сервер «как у хостера»: rsyslog работает, в rsyslog.d файлы дистрибутива
fresh() {
    rm -rf "${OUT:?}/rsyslog.d" "${NODE_STATE_DIR:?}"/*; mkdir -p "$NODE_RSYSLOG_DIR"
    printf '# ufw\n:msg,contains,"[UFW " /var/log/ufw.log\n' > "$NODE_RSYSLOG_DIR/20-ufw.conf"
    printf 'kern.*\t-/var/log/kern.log\n' > "$NODE_RSYSLOG_DIR/50-default.conf"
    rm -rf "$MOCK_UNITS"; mkdir -p "$MOCK_UNITS"; mkunit rsyslog.service enabled active
    : > "$MOCK_SYSTEMCTL_LOG"; : > "$RSYSLOG_CALLS"; : > "$NFT_RULES"; cfg
    unset MOCK_RSYSLOG_BROKEN MOCK_RSYSLOG_REJECT
    HOST_SUM="$(cksum "$NODE_RSYSLOG_DIR/20-ufw.conf" "$NODE_RSYSLOG_DIR/50-default.conf")"
}
host_intact() { [ "$(cksum "$NODE_RSYSLOG_DIR/20-ufw.conf" "$NODE_RSYSLOG_DIR/50-default.conf")" = "$HOST_SUM" ]; }
run() { rc=0; node_journal_apply > "$OUT/run.log" 2>&1 || rc=$?; }
node_rules() { # <сколько правил с записью без предела>
    {
        echo 'table ip remnanode {'
        echo '	chain input {'
        echo '		type filter hook input priority filter - 10; policy accept;'
        echo '		counter name "processed"'
        local i; for i in $(seq 1 "$1"); do
            if [ $((i % 2)) = 1 ]; then echo '		ip saddr @ingress-filter-ip log prefix "ingress-filter-ip: " counter name "ingress-filter-ip" drop'
            else echo '		ip saddr @torrent-blocker log prefix "torrent-blocker: " counter name "torrent-blocker" drop'; fi
        done
        echo '	}'
        echo '}'
        echo 'table ip filter {'
        echo '	chain ufw-logging-deny {'
        echo '		limit rate 3/minute burst 10 packets counter log prefix "[UFW BLOCK] "'
        echo '	}'
        echo '}'
    } > "$NFT_RULES"
}

# =================== A. файл фильтра ===================
fresh; run
t "apply: 10-node-nftlog.conf — одно правило: строки ядра с двумя префиксами отбросить" 'grep -qxF "if \$syslogfacility-text == \"kern\" and (\$msg contains \"torrent-blocker: \" or \$msg contains \"ingress-filter-ip: \") then stop" "$F" && [ "$(grep -cvE "^#" "$F")" = 1 ]'
t "имя файла читается раньше файлов дистрибутива (20-ufw, 50-default)" '[ "$(ls "$NODE_RSYSLOG_DIR" | head -n 1)" = 10-node-nftlog.conf ]'
t "rsyslogd -N1 вызван до записи и после неё" '[ "$(ncheck)" = 2 ]'
t "rsyslog перезапущен один раз" '[ "$(nlog "restart rsyslog.service")" = 1 ] && [ "$(nlog "restart ")" = 1 ]'
t "файлы дистрибутива не изменены" 'host_intact'
t "файл в манифесте и в реестре как созданный node (rollback удалит)" 'grep -qxF "$F" "$NODE_STATE_DIR/applied-files.txt" && awk -F"\t" -v p="$F" "\$1 == p && \$2 == \"created\" { f = 1 } END { exit !f }" "$NODE_STATE_DIR/file-origins.tsv"'
t "код возврата 0, предупреждений нет (нода каждый пакет не пишет)" '[ "$rc" = 0 ] && ! grep -q "WARN\|пишет в журнал ядра" "$OUT/run.log"'
: > "$MOCK_SYSTEMCTL_LOG"; before="$(cksum < "$F")"; run
t "повторный apply: файл не переписан, rsyslog не перезапускался, копий нет" '[ "$(cksum < "$F")" = "$before" ] && [ "$(nlog "restart ")" = 0 ] && [ "$rc" = 0 ] && ! ls "$F".pre-node-* 2>/dev/null | grep -q .'

# =================== B. когда rsyslog трогать нельзя или нечего ===================
fresh; MOCK_RSYSLOG_BROKEN=1; export MOCK_RSYSLOG_BROKEN; run
t "конфиг rsyslog сломан ещё до нас: файл не пишем, rsyslog не перезапускаем, rc 0, причина названа" '[ ! -e "$F" ] && [ "$(nlog "restart ")" = 0 ] && [ "$rc" = 0 ] && grep -q "99-other.conf" "$OUT/run.log"'
fresh; MOCK_RSYSLOG_REJECT=1; export MOCK_RSYSLOG_REJECT; run
t "rsyslogd отверг файл стека: файл убран, rsyslog не перезапущен, rc 1" '[ ! -e "$F" ] && [ "$(nlog "restart ")" = 0 ] && [ "$rc" = 1 ] && grep -q "возвращён в прежнее состояние" "$OUT/run.log"'
t "после отказа: файлы дистрибутива целы, копий стека нет" 'host_intact && ! ls "$F".pre-node-* 2>/dev/null | grep -q .'
fresh; printf '# старая версия файла стека\n:msg, contains, "torrent-blocker: " stop\n' | node_persist "$F" >/dev/null 2>&1; old="$(cat "$F")"
MOCK_RSYSLOG_REJECT=1; export MOCK_RSYSLOG_REJECT
# rsyslogd отвергает и прежний файл: до записи конфиг уже «сломан» — стек его не трогает
run
t "файл стека уже был и конфиг не проходит: файл не переписан, rc 0" '[ "$(cat "$F")" = "$old" ] && [ "$rc" = 0 ] && [ "$(nlog "restart ")" = 0 ]'
fresh; rm -f "$OUT/bin/rsyslogd"; run
t "rsyslog не установлен: пропуск, файла нет, rc 0" '[ ! -e "$F" ] && [ "$rc" = 0 ] && grep -q "rsyslog не установлен" "$OUT/run.log"'
cat > "$OUT/bin/rsyslogd" <<'MOCK'
#!/bin/bash
echo "$*" >> "${RSYSLOG_CALLS:-/dev/null}"
echo "rsyslogd: version 8.2312.0, config validation run (level 1), master config /etc/rsyslog.conf"
if [ "${MOCK_RSYSLOG_BROKEN:-0}" = 1 ]; then echo "rsyslogd: error during parsing file /etc/rsyslog.d/99-other.conf, on or before line 3: syntax error"; exit 1; fi
if [ "${MOCK_RSYSLOG_REJECT:-0}" = 1 ] && [ -f "$NODE_RSYSLOG_DIR/10-node-nftlog.conf" ]; then echo "rsyslogd: error during parsing file $NODE_RSYSLOG_DIR/10-node-nftlog.conf, on or before line 5: invalid character"; exit 1; fi
echo "rsyslogd: End of config validation run. Bye."
MOCK
chmod +x "$OUT/bin/rsyslogd"
fresh; rm -rf "$NODE_RSYSLOG_DIR"; run
t "каталога rsyslog.d нет: пропуск, rc 0" '[ ! -e "$F" ] && [ "$rc" = 0 ]'
fresh; mkunit rsyslog.service enabled inactive; run
t "rsyslog остановлен: файл записан, перезапуска нет, rc 0" '[ -f "$F" ] && [ "$(nlog "restart ")" = 0 ] && [ "$rc" = 0 ] && grep -q "вступит при её запуске" "$OUT/run.log"'
fresh; DRY_RUN=1 run; DRY_RUN=0
t "DRY_RUN: ничего не записано, rsyslogd и systemctl не вызывались" '[ ! -e "$F" ] && [ "$(ncheck)" = 0 ] && [ "$(nlog "restart ")" = 0 ] && [ "$rc" = 0 ]'

# =================== C. флаг выключен ===================
fresh; run; : > "$MOCK_SYSTEMCTL_LOG"; cfg QUIET_NFT_PACKET_LOG=0; run
t "QUIET_NFT_PACKET_LOG=0: файл стека убран, rsyslog перезапущен один раз, rc 0" '[ ! -e "$F" ] && [ "$(nlog "restart rsyslog.service")" = 1 ] && [ "$rc" = 0 ]'
fresh; cfg QUIET_NFT_PACKET_LOG=0; run
t "флаг 0 на чистом сервере: ничего не пишем и не перезапускаем" '[ ! -e "$F" ] && [ "$(nlog "restart ")" = 0 ] && [ "$(ncheck)" = 0 ] && [ "$rc" = 0 ]'
fresh; printf '# файл владельца сервера\n' > "$F"; cfg QUIET_NFT_PACKET_LOG=0; run
t "флаг 0: чужой файл с тем же именем не удаляем" '[ -f "$F" ] && grep -q "файл владельца" "$F" && [ "$rc" = 0 ]'

# =================== D. нода всё ещё пишет каждый пакет ===================
fresh; node_rules 4; run
t "apply: предупреждение — нода пишет каждый пакет (правил: 4), названа настройка NFTABLES_LOGGING" 'grep -q "правил: 4" "$OUT/run.log" && grep -q "NFTABLES_LOGGING=false" "$OUT/run.log" && [ "$rc" = 0 ]'
t "правило UFW с пределом (limit rate) за запись каждого пакета не считается" '[ "$(node_journal_packet_log_rules)" = 4 ]'
t "status: файл есть, нода пишет каждый пакет — ДА, правил: 4" 'node_journal_status | grep -q "файл rsyslog: есть" && node_journal_status | grep -q "ДА, правил: 4"'
node_rules 0
t "status: правил с записью нет — «нет»" 'node_journal_status | grep -q "каждый отброшенный пакет: нет"'
id() { echo 1000; }
t "status без root: «не проверено», nft не вызывается" 'node_journal_status | grep -q "не проверено"'
id() { echo 0; }

# =================== E. откат ===================
fresh; run; sig="$(_node_journal_sig)"; : > "$MOCK_SYSTEMCTL_LOG"
node_journal_rollback_restart "$sig"
t "откат: файл не менялся — rsyslog не перезапускается" '[ "$(nlog "restart ")" = 0 ]'
rm -f "$F"; node_journal_rollback_restart "$sig"
t "откат: файл стека убран — rsyslog перезапущен один раз" '[ "$(nlog "restart rsyslog.service")" = 1 ]'

# =================== F. проводка ===================
t "apply.sh: план и шаг journal_apply сразу после sshd_apply" 'grep -q "node_journal_plan" "$NODE_DIR/apply.sh" && [ "$(grep -oE "node_step_run (sshd_apply|journal_apply|nic_diag)" "$NODE_DIR/apply.sh" | awk "{print \$2}" | tr "\n" " ")" = "sshd_apply journal_apply nic_diag " ]'
t "rollback.sh: отпечаток до шага 1 и перезапуск после него" 'grep -q "journal_sig=\"\$(_node_journal_sig)\"" "$NODE_DIR/rollback.sh" && grep -q "node_journal_rollback_restart \"\$journal_sig\"" "$NODE_DIR/rollback.sh"'
t "status.sh печатает строку журнала" 'grep -q "node_journal_status" "$NODE_DIR/status.sh"'
t "node.defaults.conf: QUIET_NFT_PACKET_LOG=1" 'grep -qx "QUIET_NFT_PACKET_LOG=1" "$NODE_DIR/node.defaults.conf"'

# =================== G. настоящий rsyslogd читает наш текст (только чтение, на копии) ===================
if [ -n "$REAL_RSYSLOGD" ]; then
    mkdir -p "$OUT/real.d"; printf '*.* /dev/null\n' > "$OUT/real.d/50-default.conf"
    printf '$IncludeConfig %s/*.conf\n' "$OUT/real.d" > "$OUT/real.conf"
    if "$REAL_RSYSLOGD" -N1 -f "$OUT/real.conf" >/dev/null 2>&1; then
        _node_journal_text > "$OUT/real.d/10-node-nftlog.conf"
        t "настоящий rsyslogd -N1 принимает файл стека" '"$REAL_RSYSLOGD" -N1 -f "$OUT/real.conf"'
        printf 'if $syslogfacility-text == "kern" and ( then stop\n' > "$OUT/real.d/10-node-nftlog.conf"
        t "и отвергает заведомо испорченный (проверка сама работает)" '! "$REAL_RSYSLOGD" -N1 -f "$OUT/real.conf"'
    else
        echo "skip - настоящему rsyslogd нельзя читать временный каталог (AppArmor) — сверка пропущена"
    fi
else
    echo "skip - rsyslogd не установлен — сверка с настоящим пропущена"
fi

echo "fails=$fails"
exit "$fails"
