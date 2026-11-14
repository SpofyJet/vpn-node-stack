#!/bin/bash
# node — тест: автоперезагрузка после сбоя ядра (v1.2.12, HARDEN_PANIC_REBOOT):
# kernel.panic=10 и kernel.panic_on_oops=1 идут обычным путём sysctl стека — план, файл
# 99-z0-node-base.conf, реестр исходных значений, возврат при выключении флага.
#
# kernel.* — не сетевые ключи: отдельный netns их НЕ изолирует. Поэтому sysctl здесь — только
# заглушка по файлу $SYSDB; настоящий kernel.panic сервера тест не читает и не пишет.
# Под root — свой mount ns с tmpfs поверх /etc/sysctl.d (код стека ищет свои ключи в
# /etc/sysctl.d/99-z[0-4]-node-*.conf); без root эта часть пропускается.
set -euo pipefail

if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
IN_NS="${NODE_TEST_IN_NS:-0}"
if [ "$IN_NS" = "1" ]; then mount -t tmpfs t /etc/sysctl.d; fi

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp"; export TMPDIR="$OUT/tmp"   # mktemp кода стека (план sysctl, кэш конфига) — внутрь $OUT, уйдёт вместе с ним
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/sysctl.d"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG=/dev/null NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
: > "$NODE_CONFIG"

# shellcheck source=mocks.sh
source "$NODE_DIR/tests/mocks.sh"
mock_sysctl_install "$OUT/bin" "$OUT/mock"   # SYSDB, SYSCALLS
export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
CONFIG_CACHE="$OUT/config.cache"; export CONFIG_CACHE
cfg() { { printf '%s\n' "$@"; grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$NODE_DIR/node.defaults.conf"; } > "$CONFIG_CACHE"; }
cfg
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/sysctl.sh"; source "$NODE_DIR/lib/kernel.sh"
# только базовый файл и только во временном каталоге (в mount ns — на tmpfs /etc/sysctl.d): список
# NODE_SYSCTL_FILES с настоящими путями здесь недопустим — node_sysctl_write счёл бы файлы живой
# ноды «устаревшими» и удалил бы их
if [ "$IN_NS" = "1" ]; then NODE_SYSCTL_BASE="/etc/sysctl.d/99-z0-node-base.conf"; else NODE_SYSCTL_BASE="$OUT/sysctl.d/99-z0-node-base.conf"; fi
NODE_SYSCTL_FILES=("$NODE_SYSCTL_BASE")

fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
db() { printf 'kernel.panic=0\nkernel.panic_on_oops=0\nnet.core.somaxconn=4096\n' > "$SYSDB"; : > "$SYSCALLS"; }
val() { awk -F= -v k="$1" '$1 == k { print $2 }' "$SYSDB"; }
planned() { awk -F'\t' -v k="$1" -v v="$2" -v f="$NODE_SYSCTL_BASE" '$1 == k && $2 == v && $3 == f { ok = 1 } END { exit !ok }' "$NODE_PLAN_FILE"; }
inplan() { awk -F'\t' -v k="$1" '$1 == k { ok = 1 } END { exit !ok }' "$NODE_PLAN_FILE"; }
orig() { awk -F'\t' -v k="$1" -v v="$2" '$1 == k && $2 == v { n++ } END { exit !(n == 1) }' "$NODE_STATE_DIR/sysctl-orig.tsv"; }   # ровно одна запись
plan() { node_sysctl_plan_init; node_sysctl_add "$NODE_SYSCTL_BASE" net.core.somaxconn 65535; node_panic_plan; }
apply_sim() { plan; node_sysctl_write; node_sysctl_apply; node_sysctl_restore_dropped; node_sysctl_owner_dump; }

# ---------- 1. план ----------
db; plan > "$OUT/plan.log" 2>&1
t "по умолчанию: kernel.panic=10 в плане, в базовом файле node" 'planned kernel.panic 10'
t "по умолчанию: kernel.panic_on_oops=1 в плане" 'planned kernel.panic_on_oops 1'
t "дефолт HARDEN_PANIC_REBOOT=1 записан в node.defaults.conf" 'grep -qx "HARDEN_PANIC_REBOOT=1" "$NODE_DIR/node.defaults.conf"'
t "проверка записываемости не меняет значение (пишет текущее)" '[ "$(val kernel.panic)" = 0 ] && [ "$(val kernel.panic_on_oops)" = 0 ] && grep -qx -- "-w kernel.panic=0" "$SYSCALLS"'

cfg HARDEN_PANIC_REBOOT=0; db; plan > "$OUT/plan0.log" 2>&1
t "HARDEN_PANIC_REBOOT=0: ключей в плане нет, sysctl не вызывался для kernel.*" '! inplan kernel.panic && ! inplan kernel.panic_on_oops && ! grep -q "kernel\." "$SYSCALLS"'
t "HARDEN_PANIC_REBOOT=0: сказано в журнале" 'grep -q "HARDEN_PANIC_REBOOT=0" "$OUT/plan0.log"'
cfg

# контейнер: /proc/sys/kernel только для чтения — пропуск, а не падение sysctl -p
db; SYSCTL_RO="kernel.panic kernel.panic_on_oops" plan > "$OUT/ro.log" 2>&1
t "ключи только для чтения (контейнер): в план не попали, остальной план цел" '! inplan kernel.panic && ! inplan kernel.panic_on_oops && inplan net.core.somaxconn'
t "…с предупреждением" 'grep -q "kernel.panic не записываемый" "$OUT/ro.log"'
# ключа нет в ядре
printf 'net.core.somaxconn=4096\n' > "$SYSDB"; : > "$SYSCALLS"; plan > "$OUT/nokey.log" 2>&1
t "ключа нет в ядре: пропуск" '! inplan kernel.panic && inplan net.core.somaxconn'

# DRY_RUN и status: план есть, записи нет
db; DRY_RUN=1 plan >/dev/null 2>&1
t "DRY_RUN: ключи в плане, ни одной записи sysctl" 'planned kernel.panic 10 && ! grep -q -- "^-w" "$SYSCALLS"'
db; MODE=status plan >/dev/null 2>&1
t "status: ключи в плане (таблица expected/actual), ни одной записи sysctl" 'planned kernel.panic 10 && planned kernel.panic_on_oops 1 && ! grep -q -- "^-w" "$SYSCALLS"'
db; DRY_RUN=1 apply_sim >/dev/null 2>&1
t "DRY_RUN apply: файл не записан, значения ядра прежние" '[ ! -e "$NODE_SYSCTL_BASE" ] && [ "$(val kernel.panic)" = 0 ] && [ ! -e "$NODE_STATE_DIR/sysctl-orig.tsv" ]'

# ---------- 2. apply: файл, значения, реестр исходных ----------
rm -rf "${NODE_STATE_DIR:?}"/*   # пробный прогон выше записал owner-keys (настоящий apply при --dry-run до этого не доходит)
db; apply_sim > "$OUT/apply.log" 2>&1
t "apply: строки в 99-z0-node-base.conf" 'grep -qx "kernel.panic = 10" "$NODE_SYSCTL_BASE" && grep -qx "kernel.panic_on_oops = 1" "$NODE_SYSCTL_BASE"'
t "apply: в ядре 10 / 1" '[ "$(val kernel.panic)" = 10 ] && [ "$(val kernel.panic_on_oops)" = 1 ]'
t "apply: исходные 0 / 0 в реестре отката" 'orig kernel.panic 0 && orig kernel.panic_on_oops 0'
t "apply: ключи в реестре владения" 'grep -qx kernel.panic "$NODE_STATE_DIR/owner-keys.txt" && grep -qx kernel.panic_on_oops "$NODE_STATE_DIR/owner-keys.txt"'
apply_sim >/dev/null 2>&1
t "повторный apply: реестр хранит исходные 0 / 0, а не 10 / 1" 'orig kernel.panic 0 && orig kernel.panic_on_oops 0'

# значение хостера сохраняется как исходное (не обязательно 0)
rm -rf "${NODE_STATE_DIR:?}"/* "$NODE_SYSCTL_BASE"
printf 'kernel.panic=60\nkernel.panic_on_oops=0\nnet.core.somaxconn=4096\n' > "$SYSDB"
apply_sim >/dev/null 2>&1
t "у хостера было kernel.panic=60: ставим 10, исходное 60 в реестре" '[ "$(val kernel.panic)" = 10 ] && orig kernel.panic 60'

# ---------- 3. флаг выключили — значения возвращаются (нужен tmpfs /etc/sysctl.d) ----------
if [ "$IN_NS" = "1" ]; then
    rm -rf "${NODE_STATE_DIR:?}"/* "$NODE_SYSCTL_BASE"; db
    apply_sim >/dev/null 2>&1
    cfg HARDEN_PANIC_REBOOT=0
    apply_sim > "$OUT/off.log" 2>&1
    t "1 -> 0: строк kernel.panic в файле node нет" '! grep -q "kernel\.panic" "$NODE_SYSCTL_BASE"'
    t "1 -> 0: в ядре снова исходные 0 / 0" '[ "$(val kernel.panic)" = 0 ] && [ "$(val kernel.panic_on_oops)" = 0 ]'
    t "1 -> 0: остальные ключи node на месте" '[ "$(val net.core.somaxconn)" = 65535 ]'
    cfg
    apply_sim >/dev/null 2>&1
    t "0 -> 1: снова 10 / 1" '[ "$(val kernel.panic)" = 10 ] && [ "$(val kernel.panic_on_oops)" = 1 ]'
    # соседство с файлом разового скрипта: он применяется позже нашего и стек его не трогает
    printf 'kernel.panic = 10\nkernel.panic_on_oops = 1\n' > /etc/sysctl.d/99-z9-spofy-panic.conf
    apply_sim >/dev/null 2>&1
    t "файл разового скрипта 99-z9-…-panic.conf стек не трогает" 'grep -qx "kernel.panic = 10" /etc/sysctl.d/99-z9-spofy-panic.conf && [ ! -e /etc/sysctl.d/99-z9-spofy-panic.conf.pre-node-* ]'
else
    echo "skip - выключение флага и соседний файл: нужен root + unshare -m (tmpfs поверх /etc/sysctl.d)"
fi

# ---------- 4. строки в status и в контракте ----------
t "apply.sh: node_panic_plan в плане, флаг в контракте стека" 'grep -q "node_bbr_plan; node_panic_plan" "$NODE_DIR/apply.sh" && grep -q "panic_reboot:\$(node_conf_get HARDEN_PANIC_REBOOT 1)" "$NODE_DIR/apply.sh"'
# таблица status: остальные ключи — настоящим sysctl (только чтение), запись заглушка не пропускает
printf 'kernel.panic=10\nkernel.panic_on_oops=0\n' > "$SYSDB"; : > "$SYSCALLS"
( export MODE=status NODE_DIAG_DIR="$OUT/state/diagnostics" NODE_PROFILE_DIR="$OUT/profile.d" NO_COLOR=1 SYSCTL_PASS=1 NODE_VERSION=test
  source "$NODE_DIR/detect.sh"; source "$NODE_DIR/status.sh"; node_status ) > "$OUT/status.out" 2>&1 || true
t "status: kernel.panic 10/10 — ✓" 'grep -E "^kernel\.panic +10 +10 +✓" "$OUT/status.out"'
t "status: kernel.panic_on_oops ожидается 1, в ядре 0 — ✗" 'grep -E "^kernel\.panic_on_oops +1 +0 +✗" "$OUT/status.out"'
t "status ничего не пишет в sysctl" '! grep -q -- "^-w\|^-p\|^-qw" "$SYSCALLS"'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: panic-reboot (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
