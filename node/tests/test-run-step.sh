#!/bin/bash
# node — тест: node_step_run (common.sh) — контракт исполнения шагов apply.
# Регрессия бага 2026-09-22: форма `( cmd ) || { handler; }` отключала errexit
# ВНУТРИ subshell, ошибка в середине шага не прерывала его, rc получала
# последняя команда — шаги apply молча «успевали» с половиной провалов.
# Запуск: bash tests/test-run-step.sh (root не нужен)
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-test-runstep/state
export NODE_LOG=/tmp/node-test-runstep/node.log
rm -rf /tmp/node-test-runstep
mkdir -p "$NODE_STATE_DIR"

source "$NODE_DIR/lib/common.sh"

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# --- 1. ошибка В СЕРЕДИНЕ шага прерывает шаг (errexit жив внутри subshell) ---
STEP_SAW_AFTER=0
step_with_mid_failure() {
    false
    STEP_SAW_AFTER=1   # под подавленным errexit эта строка выполнялась
    return 0           # и шаг возвращал 0
}
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run midfail step_with_mid_failure
t "mid-failure: шаг прерван (side-effect после ошибки не выполнился)" test "$STEP_SAW_AFTER" -eq 0
t "mid-failure: счётчик инкрементирован" test "$NODE_STEP_RC" -eq 1
t "mid-failure: имя шага в failed-списке" grep -qw midfail <<<"$NODE_STEP_FAILED"

# --- 2. успешный шаг: rc не трогаем, список пустой ---
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run goodstep true
t "good: rc остался 0" test "$NODE_STEP_RC" -eq 0
t "good: failed-список пуст" test -z "$NODE_STEP_FAILED"

# --- 3. rc шага пробрасывается (не только 0/1) ---
step_rc7() { return 7; }
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run rc7 step_rc7
t "rc7: счётчик инкрементирован" test "$NODE_STEP_RC" -eq 1
t "rc7: имя зафиксировано" grep -qw rc7 <<<"$NODE_STEP_FAILED"

# --- 4. вызывающий скрипт НЕ умирает от ошибки шага (set +e снаружи корректен) ---
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run boom false
t "boom: вызывающий шелл жив после упавшего шага" true

# --- 5. ошибка в ПАЙПЛАЙНЕ шага прерывает его (pipefail действует) ---
STEP_PIPE_AFTER=0
step_pipefail() {
    false | true   # без pipefail rc=0; с pipefail — ошибка компонента видна
    STEP_PIPE_AFTER=1
    return 0
}
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run pipefail step_pipefail
t "pipefail: пайплайн с внутренней ошибкой прервал шаг" test "$STEP_PIPE_AFTER" -eq 0
t "pipefail: счётчик инкрементирован" test "$NODE_STEP_RC" -eq 1

# --- 6. аккумуляция нескольких упавших шагов ---
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run a false
node_step_run b true
node_step_run c false
t "accum: два падения посчитаны" test "$NODE_STEP_RC" -eq 2
t "accum: оба имени в списке" bash -c "grep -qw a <<<\"\$0\" && grep -qw c <<<\"\$0\"" "$NODE_STEP_FAILED"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: run-step (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
