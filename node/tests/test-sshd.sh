#!/bin/bash
# node — тест: sshd — пределы на незавершённые входы и вход только по ключу (v1.2.12, lib/sshd.sh).
#   HARDEN_SSHD_LIMITS=1      -> sshd_config.d/01-node-limits.conf
#   HARDEN_SSH_PASSWORD_OFF=1 -> sshd_config.d/00-node-keys-only.conf — только если root войдёт по ключу
# Проверяем: содержимое файлов, sshd -t до и после записи, возврат файла при ошибке, запись без
# PerSource* на старом OpenSSH, reload (не restart) и только при изменении, отказы при риске
# потерять вход, выключение флагов, DRY_RUN, соседство с чужими файлами.
# sshd и systemctl — заглушки, конфиг — во временном каталоге (NODE_SSHD_CONFIG/NODE_SSHD_DIR):
# настоящий /etc/ssh не читается и не меняется, настоящий sshd не перечитывается. В конце — сверка
# текста файлов с НАСТОЯЩИМ sshd на копии конфига (sshd -t/-T -f, только чтение), если он есть.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"   # mktemp кода стека (план sysctl, кэш конфига) — внутрь $OUT, уйдёт вместе с ним
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/ssh/sshd_config.d" "$OUT/root/.ssh"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
export NODE_SSHD_CONFIG="$OUT/ssh/sshd_config" NODE_SSHD_DIR="$OUT/ssh/sshd_config.d" NODE_SSHD_BIN="$OUT/bin/sshd"
export NODE_SSH_ROOT_KEYS="$OUT/root/.ssh/authorized_keys" SSHD_CALLS="$OUT/sshd.calls"
: > "$NODE_CONFIG"; : > "$SSHD_CALLS"
# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_systemctl_install "$OUT/bin" "$OUT/mock"
REAL_SSHD="$(command -v sshd 2>/dev/null || true)"; [ -n "$REAL_SSHD" ] || { [ -x /usr/sbin/sshd ] && REAL_SSHD=/usr/sbin/sshd; } || true
REAL_KEYGEN="$(command -v ssh-keygen 2>/dev/null || true)"
export PATH="$OUT/bin:$PATH"

# заглушка sshd (mocks.sh): -V | -t -f CFG | -T -f CFG; MOCK_SSHD_VER / _NOVER / _REJECT / _BROKEN
mock_sshd_install "$OUT/bin"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
CONFIG_CACHE="$OUT/config.cache"; export CONFIG_CACHE
cfg() { { printf '%s\n' "$@"; grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"; }
cfg
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/sshd.sh"

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
LIM="$NODE_SSHD_LIMITS_FILE"; KEYS="$NODE_SSHD_KEYS_FILE"
eff() { "$NODE_SSHD_BIN" -T -f "$NODE_SSHD_CONFIG" 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'; }
nlog() { grep -c "^$1" "$MOCK_SYSTEMCTL_LOG" || true; }   # сколько вызовов systemctl <команда…>
# сервер «как у хостера»: Include первым, файл cloud-init разрешает пароль, sshd работает
fresh() {
    rm -rf "${OUT:?}/ssh" "${NODE_STATE_DIR:?}"/* "${OUT:?}/root/.ssh"/*; mkdir -p "$NODE_SSHD_DIR"
    printf '# test sshd_config\nInclude %s/*.conf\nPort 22\nUsePAM yes\n' "$NODE_SSHD_DIR" > "$NODE_SSHD_CONFIG"
    printf 'PasswordAuthentication yes\n' > "$NODE_SSHD_DIR/50-cloud-init.conf"
    rm -rf "$MOCK_UNITS"; mkdir -p "$MOCK_UNITS"; mkunit ssh.service disabled active; mkunit ssh.socket enabled active
    : > "$MOCK_SYSTEMCTL_LOG"; : > "$SSHD_CALLS"; cfg
    MAIN_SUM="$(cksum < "$NODE_SSHD_CONFIG")"
}
main_intact() { [ "$(cksum < "$NODE_SSHD_CONFIG")" = "$MAIN_SUM" ]; }
# ключ root: настоящий (ssh-keygen), иначе строка правильного вида для запасного счёта
if [ -n "$REAL_KEYGEN" ] && "$REAL_KEYGEN" -q -t ed25519 -N '' -C test-key -f "$OUT/testkey" >/dev/null 2>&1; then
    PUB="$(cat "$OUT/testkey.pub")"
else
    PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake test-key"
    export NODE_SSH_KEYGEN_BIN=/nonexistent
fi
rootkey() { printf '%s\n' "$@" > "$NODE_SSH_ROOT_KEYS"; }
run() { rc=0; node_sshd_apply > "$OUT/run.log" 2>&1 || rc=$?; }

# =================== A. пределы на незавершённые входы ===================
fresh; run
t "apply: 01-node-limits.conf с четырьмя директивами" 'grep -qx "LoginGraceTime 30" "$LIM" && grep -qx "MaxStartups 60:30:200" "$LIM" && grep -qx "PerSourceMaxStartups 10" "$LIM" && grep -qx "PerSourceNetBlockSize 24:64" "$LIM"'
t "действует: 30 с, 60:30:200, 10 на сеть /24" '[ "$(eff logingracetime)" = 30 ] && [ "$(eff maxstartups)" = 60:30:200 ] && [ "$(eff persourcemaxstartups)" = 10 ] && [ "$(eff persourcenetblocksize)" = 24:64 ]'
t "sshd перечитал конфиг: один reload ssh.service, restart не вызывался" '[ "$(nlog "reload ssh.service")" = 1 ] && [ "$(nlog restart)" = 0 ] && [ "$(nlog "reload ")" = 1 ]'
t "sshd -t вызван до записи и после неё" '[ "$(grep -c -- "^-t " "$SSHD_CALLS")" -ge 2 ]'
t "по умолчанию вход по паролю не трогаем: 00-node-keys-only.conf нет" '[ ! -e "$KEYS" ] && [ "$(eff passwordauthentication)" = yes ]'
t "основной sshd_config не изменён" 'main_intact'
t "файл в манифесте и в реестре как созданный node (rollback удалит)" 'grep -qxF "$LIM" "$NODE_STATE_DIR/applied-files.txt" && awk -F"\t" -v p="$LIM" "\$1 == p && \$2 == \"created\" { f = 1 } END { exit !f }" "$NODE_STATE_DIR/file-origins.tsv"'
t "код возврата 0" '[ "$rc" = 0 ]'
: > "$MOCK_SYSTEMCTL_LOG"; before="$(cksum < "$LIM")"; run
t "повторный apply: файл не переписан, reload не вызывался" '[ "$(cksum < "$LIM")" = "$before" ] && [ "$(nlog "reload ")" = 0 ] && [ "$rc" = 0 ] && ! ls "$LIM".pre-node-* >/dev/null 2>&1'

fresh; MOCK_SSHD_VER=8.2; export MOCK_SSHD_VER; run
t "OpenSSH 8.2: файл без PerSource*, sshd -t проходит, reload" 'grep -qx "MaxStartups 60:30:200" "$LIM" && ! grep -q "PerSource" "$LIM" && [ "$(nlog "reload ssh.service")" = 1 ] && [ "$rc" = 0 ]'
t "OpenSSH 8.2: сказано, что предела на одну сеть нет" 'grep -q "без PerSourceMaxStartups" "$OUT/run.log"'
: > "$MOCK_SYSTEMCTL_LOG"; run
t "OpenSSH 8.2, повторный apply: без перезаписи и reload" '[ "$(nlog "reload ")" = 0 ] && ! ls "$LIM".pre-node-* >/dev/null 2>&1'
unset MOCK_SSHD_VER

fresh; export MOCK_SSHD_NOVER=1 MOCK_SSHD_REJECT="persourcemaxstartups persourcenetblocksize"; run
t "версию не узнали, sshd -t отверг PerSource*: файл переписан без них, reload один" 'grep -qx "LoginGraceTime 30" "$LIM" && ! grep -q "PerSource" "$LIM" && [ "$(nlog "reload ssh.service")" = 1 ] && [ "$rc" = 0 ]'
unset MOCK_SSHD_NOVER MOCK_SSHD_REJECT

# sshd -t отверг наш файл целиком — файл убран, sshd не перечитан
fresh; export MOCK_SSHD_REJECT="maxstartups"
# (заглушка отвергает директиву только когда она есть в конфиге: до записи sshd -t проходит)
run
t "sshd -t отверг файл: файл убран, reload не вызывался, шаг вернул ошибку" '[ ! -e "$LIM" ] && [ "$(nlog "reload ")" = 0 ] && [ "$rc" != 0 ]'
t "…причина названа, основной конфиг цел" 'grep -q "sshd -t отверг" "$OUT/run.log" && grep -q "maxstartups" "$OUT/run.log" && main_intact'
unset MOCK_SSHD_REJECT
# то же, но раньше стояла рабочая версия нашего файла — возвращается она
fresh; run; printf '# прежняя версия node\nLoginGraceTime 45\n' > "$LIM"; : > "$MOCK_SYSTEMCTL_LOG"
export MOCK_SSHD_REJECT="maxstartups"; run; unset MOCK_SSHD_REJECT
t "sshd -t отверг новую версию: возвращена прежняя, reload не вызывался" 'grep -qx "LoginGraceTime 45" "$LIM" && ! grep -q MaxStartups "$LIM" && [ "$(nlog "reload ")" = 0 ] && [ "$rc" != 0 ]'

# нет Include — основной конфиг не правим, пропуск с предупреждением
fresh; printf 'Port 22\nPasswordAuthentication yes\n' > "$NODE_SSHD_CONFIG"; run
t "нет Include на sshd_config.d: файл не создан, предупреждение, шаг не падает" '[ ! -e "$LIM" ] && grep -q "нет Include" "$OUT/run.log" && [ "$rc" = 0 ] && [ "$(nlog "reload ")" = 0 ]'
fresh; printf 'Port 22\nMatch User deploy\n    Include %s/*.conf\n' "$NODE_SSHD_DIR" > "$NODE_SSHD_CONFIG"; run
t "Include только внутри Match: считается, что его нет" '[ ! -e "$LIM" ] && grep -q "нет Include" "$OUT/run.log"'
fresh; printf 'include "sshd_config.d/*.conf"\nPort 22\n' > "$NODE_SSHD_CONFIG"; run
t "Include относительным путём, в кавычках, строчными: распознан" 'grep -qx "MaxStartups 60:30:200" "$LIM" && [ "$rc" = 0 ]'
fresh; printf 'Port 22\nInclude %s/*.conf' "$NODE_SSHD_DIR" > "$NODE_SSHD_CONFIG"; run
t "Include последней строкой без перевода строки: распознан" '[ -e "$LIM" ]'

# конфиг сломан до нас — не трогаем
fresh; export MOCK_SSHD_BROKEN=1; run; unset MOCK_SSHD_BROKEN
t "sshd -t не проходит ещё до записи: ничего не пишем и не перечитываем" '[ ! -e "$LIM" ] && [ "$(nlog "reload ")" = 0 ] && grep -q "до записи файлов node" "$OUT/run.log" && [ "$rc" = 0 ]'
fresh; NODE_SSHD_BIN="$OUT/bin/none" run
t "sshd не установлен: пропуск без ошибки" '[ ! -e "$LIM" ] && [ "$rc" = 0 ] && [ ! -s "$MOCK_SYSTEMCTL_LOG" ]'

# имя юнита и неработающая служба
fresh; rm -f "$MOCK_UNITS/ssh.service" "$MOCK_UNITS/ssh.socket"; mkunit sshd.service enabled active; run
t "юнит sshd.service (не Debian): reload sshd.service" '[ "$(nlog "reload sshd.service")" = 1 ] && [ "$rc" = 0 ]'
fresh; mkunit ssh.service disabled inactive; run
t "sshd не запущен (socket-активация без соединений): файл записан, reload не нужен" '[ -e "$LIM" ] && [ "$(nlog "reload ")" = 0 ] && [ "$rc" = 0 ] && grep -q "не запущена" "$OUT/run.log"'
fresh; export MOCK_RELOAD_FAIL=1; run; unset MOCK_RELOAD_FAIL
t "reload не удался: файл остаётся (он верен), шаг вернул ошибку, restart не вызывался" '[ -e "$LIM" ] && [ "$rc" != 0 ] && [ "$(nlog restart)" = 0 ] && grep -q "reload ssh.service не удался" "$OUT/run.log"'

# флаг выключили
fresh; run; : > "$MOCK_SYSTEMCTL_LOG"; cfg HARDEN_SSHD_LIMITS=0; run
t "HARDEN_SSHD_LIMITS 1 -> 0: свой файл убран, sshd перечитан, действуют значения sshd" '[ ! -e "$LIM" ] && [ "$(nlog "reload ssh.service")" = 1 ] && [ "$(eff maxstartups)" = 10:30:100 ] && [ "$rc" = 0 ]'
: > "$MOCK_SYSTEMCTL_LOG"; run
t "HARDEN_SSHD_LIMITS=0 повторно: ничего не делает" '[ "$(nlog "reload ")" = 0 ] && [ "$rc" = 0 ]'
fresh; printf 'MaxStartups 30:30:60\n' > "$LIM"; cfg HARDEN_SSHD_LIMITS=0; run
t "HARDEN_SSHD_LIMITS=0: файл с нашим именем, созданный не node, оставлен" 'grep -qx "MaxStartups 30:30:60" "$LIM" && [ "$(nlog "reload ")" = 0 ]'

# значение задано раньше нашего файла; соседние файлы разовых скриптов
fresh; printf 'MaxStartups 10:30:60\n' > "$NODE_SSHD_DIR/00-hoster.conf"; run
t "MaxStartups задан файлом с меньшим именем: предупреждение с действующим значением, шаг не падает" 'grep -q "действует 10:30:60" "$OUT/run.log" && [ -e "$LIM" ] && [ "$rc" = 0 ]'
fresh
printf 'LoginGraceTime 30\nMaxStartups 60:30:200\nPerSourceMaxStartups 10\nPerSourceNetBlockSize 24:64\n' > "$NODE_SSHD_DIR/01-spofy-limits.conf"
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$NODE_SSHD_DIR/00-spofy-keys-only.conf"
s1="$(cksum < "$NODE_SSHD_DIR/01-spofy-limits.conf")$(cksum < "$NODE_SSHD_DIR/00-spofy-keys-only.conf")"; run
t "рядом файлы разовых скриптов: не тронуты, наш файл встал, sshd -t проходит" '[ "$(cksum < "$NODE_SSHD_DIR/01-spofy-limits.conf")$(cksum < "$NODE_SSHD_DIR/00-spofy-keys-only.conf")" = "$s1" ] && [ -e "$LIM" ] && [ "$rc" = 0 ] && [ "$(eff maxstartups)" = 60:30:200 ] && [ "$(eff passwordauthentication)" = no ]'
t "наш файл читается раньше файла разового скрипта (01-node < 01-spofy)" '[ "$(printf "%s\n" 01-spofy-limits.conf 01-node-limits.conf 00-node-keys-only.conf 00-spofy-keys-only.conf 50-cloud-init.conf | LC_ALL=C sort | tr "\n" " ")" = "00-node-keys-only.conf 00-spofy-keys-only.conf 01-node-limits.conf 01-spofy-limits.conf 50-cloud-init.conf " ]'

fresh; DRY_RUN=1 run
t "DRY_RUN: ничего не записано, sshd и systemctl не вызывались" '[ ! -e "$LIM" ] && [ ! -e "$KEYS" ] && [ ! -s "$SSHD_CALLS" ] && [ ! -s "$MOCK_SYSTEMCTL_LOG" ] && [ ! -e "$NODE_STATE_DIR/applied-files.txt" ] && [ "$rc" = 0 ]'

# =================== B. вход только по ключу ===================
fresh; rootkey "$PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "ключ у root есть: 00-node-keys-only.conf записан" 'grep -qx "PasswordAuthentication no" "$KEYS" && grep -qx "KbdInteractiveAuthentication no" "$KEYS" && [ "$rc" = 0 ]'
t "действует: пароль выключен, хотя 50-cloud-init.conf его разрешает; вход по ключу включён" '[ "$(eff passwordauthentication)" = no ] && [ "$(eff pubkeyauthentication)" = yes ] && grep -qx "PasswordAuthentication yes" "$NODE_SSHD_DIR/50-cloud-init.conf"'
t "оба файла за один apply — один reload" '[ -e "$LIM" ] && [ "$(nlog "reload ")" = 1 ]'
t "основной sshd_config и authorized_keys не изменены" 'main_intact && [ "$(cat "$NODE_SSH_ROOT_KEYS")" = "$PUB" ]'
: > "$MOCK_SYSTEMCTL_LOG"; run
t "повторный apply: без изменений и reload" '[ "$(nlog "reload ")" = 0 ] && [ "$rc" = 0 ]'
# ключ потом исчез — файл уже стоит, стек его не снимает (пароль снова включать не ему)
rm -f "$NODE_SSH_ROOT_KEYS"; run
t "файл уже стоит, ключ root исчез: стек пароль обратно не включает" '[ -e "$KEYS" ] && [ "$(eff passwordauthentication)" = no ] && [ "$rc" = 0 ]'

refused() { [ ! -e "$KEYS" ] && [ "$(eff passwordauthentication)" = yes ] && [ "$rc" != 0 ] && grep -q "НЕ выключен" "$OUT/run.log"; }
fresh; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "у root нет authorized_keys: отказ с ошибкой, пароль не выключен" 'refused && grep -q "нет ключа" "$OUT/run.log"'
t "…при этом пределы входа поставлены и sshd перечитан" '[ -e "$LIM" ] && [ "$(nlog "reload ssh.service")" = 1 ]'
fresh; rootkey "# только комментарий" ""; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "в authorized_keys только комментарии и пустые строки: отказ" 'refused'
fresh; rootkey "command=\"/usr/local/bin/backup.sh\",no-pty $PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "единственный ключ — с command= (войти им нельзя): отказ" 'refused'
fresh; rootkey "no-pty,command=\"/bin/false\" $PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "command= не первой опцией: отказ" 'refused'
fresh; rootkey "это не ключ" "ssh-ed25519"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "строки, не похожие на ключ: отказ" 'refused'
fresh; rootkey "command=\"/bin/false\" $PUB" "from=\"10.0.0.0/8\" $PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "есть и ключ с command=, и обычный (с from=): пароль выключен" '[ -e "$KEYS" ] && [ "$(eff passwordauthentication)" = no ] && [ "$rc" = 0 ]'

fresh; rootkey "$PUB"; printf 'PermitRootLogin no\n' >> "$NODE_SSHD_CONFIG"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "PermitRootLogin no (ключ root не поможет войти): отказ" 'refused && grep -q "PermitRootLogin no" "$OUT/run.log"'
fresh; rootkey "$PUB"; printf 'PermitRootLogin forced-commands-only\n' >> "$NODE_SSHD_CONFIG"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "PermitRootLogin forced-commands-only: отказ" 'refused'
fresh; rootkey "$PUB"; printf 'PermitRootLogin yes\n' >> "$NODE_SSHD_CONFIG"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "PermitRootLogin yes: пароль выключен" '[ -e "$KEYS" ] && [ "$rc" = 0 ]'
fresh; rootkey "$PUB"; printf 'PubkeyAuthentication no\n' > "$NODE_SSHD_DIR/10-hoster.conf"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "вход по ключу выключен в конфиге: отказ" 'refused && grep -q "pubkeyauthentication=.no" "$OUT/run.log"'

# значение задано раньше нашего файла — не действует: вернуть как было
fresh; rootkey "$PUB"; printf 'PasswordAuthentication yes\n' > "$NODE_SSHD_DIR/00-aaa.conf"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "PasswordAuthentication задан файлом с меньшим именем: наш файл убран, ошибка" '[ ! -e "$KEYS" ] && [ "$rc" != 0 ] && grep -q "не действует" "$OUT/run.log" && grep -q "возвращён в прежнее состояние" "$OUT/run.log"'
fresh; rootkey "$PUB"; export MOCK_SSHD_REJECT="kbdinteractiveauthentication"; cfg HARDEN_SSH_PASSWORD_OFF=1; run; unset MOCK_SSHD_REJECT
t "sshd -t отверг файл: убран, пароль не выключен, ошибка" 'refused && grep -q "sshd -t отверг" "$OUT/run.log"'
# стоял и действовал, потом оператор перекрыл его своим файлом — ошибка, файл не трогаем
fresh; rootkey "$PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
printf 'PasswordAuthentication yes\n' > "$NODE_SSHD_DIR/00-aaa.conf"; : > "$MOCK_SYSTEMCTL_LOG"; run
t "файл стоял, позже его перекрыли: ошибка, наш файл оставлен, reload нет" '[ -e "$KEYS" ] && [ "$rc" != 0 ] && grep -q "не действует" "$OUT/run.log" && [ "$(nlog "reload ")" = 0 ]'
fresh; rootkey "$PUB"; printf 'KbdInteractiveAuthentication yes\n' > "$NODE_SSHD_DIR/00-aaa.conf"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "KbdInteractiveAuthentication остался yes: предупреждение, пароль выключен" 'grep -q "KbdInteractiveAuthentication остался yes" "$OUT/run.log" && [ -e "$KEYS" ] && [ "$rc" = 0 ]'

# флаг выключили — свой файл убран, об этом сказано громко
fresh; rootkey "$PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run; : > "$MOCK_SYSTEMCTL_LOG"; cfg; run
t "HARDEN_SSH_PASSWORD_OFF 1 -> 0: файл убран, sshd перечитан" '[ ! -e "$KEYS" ] && [ "$(nlog "reload ssh.service")" = 1 ] && [ "$rc" = 0 ]'
t "…с предупреждением и действующим значением" 'grep -q "вход по паролю снова определяется" "$OUT/run.log" && grep -q "passwordauthentication=yes" "$OUT/run.log"'
fresh; rootkey "$PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; DRY_RUN=1 run
t "DRY_RUN с HARDEN_SSH_PASSWORD_OFF=1: ничего не записано" '[ ! -e "$KEYS" ] && [ ! -e "$LIM" ] && [ ! -s "$SSHD_CALLS" ]'

# счёт ключей: ssh-keygen и запасной способ
rootkey "$PUB" "# комментарий" "" "command=\"x\" $PUB"
t "node_sshd_root_keys: один ключ, дающий вход" '[ "$(node_sshd_root_keys)" = 1 ]'
t "node_sshd_root_keys без ssh-keygen: тот же счёт по виду строки" '[ "$(NODE_SSH_KEYGEN_BIN=/nonexistent node_sshd_root_keys)" = 1 ]'
rm -f "$NODE_SSH_ROOT_KEYS"
t "node_sshd_root_keys: файла нет — 0" '[ "$(node_sshd_root_keys)" = 0 ]'

# =================== C. откат: sshd перечитывает конфиг ===================
fresh; rootkey "$PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
sig="$(_node_sshd_sig)"; : > "$MOCK_SYSTEMCTL_LOG"; : > "$SSHD_CALLS"
node_sshd_rollback_reload "$sig" > "$OUT/rb0.log" 2>&1
t "откат не тронул файлы стека: sshd не проверяется и не перечитывается" '[ ! -s "$MOCK_SYSTEMCTL_LOG" ] && [ ! -s "$SSHD_CALLS" ]'
rm -f "$LIM" "$KEYS"   # шаг 1 отката: файлы, созданные node, удаляются по манифесту
node_sshd_rollback_reload "$sig" > "$OUT/rb1.log" 2>&1
t "откат убрал файлы: sshd -t и reload" 'grep -q -- "^-t " "$SSHD_CALLS" && [ "$(nlog "reload ssh.service")" = 1 ] && [ "$(eff passwordauthentication)" = yes ] && [ "$(eff maxstartups)" = 10:30:100 ]'
fresh; run; sig="$(_node_sshd_sig)"; rm -f "$LIM"; : > "$MOCK_SYSTEMCTL_LOG"
MOCK_SSHD_BROKEN=1 node_sshd_rollback_reload "$sig" > "$OUT/rb2.log" 2>&1
t "после отката sshd -t не проходит: reload не делаем, предупреждение" '[ "$(nlog "reload ")" = 0 ] && grep -q "после отката не проходит" "$OUT/rb2.log"'
t "rollback.sh: отпечаток до шага 1 и reload после него" 'grep -q "sshd_sig=\"\$(_node_sshd_sig)\"" "$NODE_DIR/rollback.sh" && grep -q "node_sshd_rollback_reload \"\$sshd_sig\"" "$NODE_DIR/rollback.sh"'

# =================== D. план, status, подключение ===================
cfg
t "plan: флаги и значения" 'node_sshd_plan | grep -q "limits=1 .*MaxStartups 60:30:200.* password_off=0"'
fresh; rootkey "$PUB"; cfg HARDEN_SSH_PASSWORD_OFF=1; run
t "status: флаги и наличие файлов" 'node_sshd_status | grep -q "^sshd: limits=1 (файл: есть) password_off=1 (файл: есть)"'
cfg HARDEN_SSHD_LIMITS=0 HARDEN_SSH_PASSWORD_OFF=1; run
t "status после выключения пределов" 'node_sshd_status | grep -q "^sshd: limits=0 (файл: нет) password_off=1 (файл: есть)"'
t "дефолты: пределы включены, вход только по ключу — по запросу" 'grep -qx "HARDEN_SSHD_LIMITS=1" "$NODE_DIR/node.defaults.conf" && grep -qx "HARDEN_SSH_PASSWORD_OFF=0" "$NODE_DIR/node.defaults.conf"'
t "apply.sh: шаг, строка плана, флаги в контракте" 'grep -q "node_step_run sshd_apply  *node_sshd_apply" "$NODE_DIR/apply.sh" && grep -q "node_sshd_plan" "$NODE_DIR/apply.sh" && grep -q "sshd_limits:\$(node_conf_get HARDEN_SSHD_LIMITS 1),ssh_password_off:\$(node_conf_get HARDEN_SSH_PASSWORD_OFF 0)" "$NODE_DIR/apply.sh"'

# =================== E. текст файлов глазами настоящего sshd ===================
# sshd -t/-T -f <копия> только читает: конфиг — временный, служба не затрагивается
R="$OUT/real"; mkdir -p "$R/sshd_config.d"
printf 'Include %s/sshd_config.d/*.conf\n' "$R" > "$R/sshd_config"
if [ "$(id -u)" -eq 0 ] && [ -n "$REAL_SSHD" ] && "$REAL_SSHD" -t -f "$R/sshd_config" >/dev/null 2>&1; then
    _node_sshd_limits_text 0 > "$R/sshd_config.d/01-node-limits.conf"; _node_sshd_keys_text > "$R/sshd_config.d/00-node-keys-only.conf"
    t "настоящий sshd: файлы без PerSource* проходят sshd -t" '"$REAL_SSHD" -t -f "$R/sshd_config"'
    real_eff() { "$REAL_SSHD" -T -f "$R/sshd_config" 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'; }
    t "настоящий sshd -T: 30 с, 60:30:200, пароль выключен, ключ включён" '[ "$(real_eff logingracetime)" = 30 ] && [ "$(real_eff maxstartups)" = 60:30:200 ] && [ "$(real_eff passwordauthentication)" = no ] && [ "$(real_eff kbdinteractiveauthentication)" = no ] && [ "$(real_eff pubkeyauthentication)" = yes ]'
    if NODE_SSHD_BIN="$REAL_SSHD" node_sshd_persource_supported; then
        _node_sshd_limits_text 1 > "$R/sshd_config.d/01-node-limits.conf"
        t "настоящий sshd (>= 8.5): полный файл проходит sshd -t" '"$REAL_SSHD" -t -f "$R/sshd_config"'
        t "настоящий sshd -T: 10 незавершённых входов на сеть /24 (IPv6 /64)" '[ "$(real_eff persourcemaxstartups)" = 10 ] && [ "$(real_eff persourcenetblocksize)" = 24:64 ]'
    else
        echo "skip - PerSource*: настоящий sshd старше 8.5"
    fi
else
    echo "skip - сверка с настоящим sshd: нужен root и рабочий sshd (ключи хоста, /run/sshd)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: sshd (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
