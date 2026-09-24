#!/bin/bash
# node — тест: detect.sh формирует снапшот §7
# Запуск: bash tests/test-detect.sh  (root не обязателен: снапшот пишется в $NODE_DIAG_DIR)
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR="${NODE_STATE_DIR:-/tmp/node-test/state}"
export NODE_DIAG_DIR="${NODE_DIAG_DIR:-/tmp/node-test/diag}"
export NODE_PROFILE_DIR="${NODE_PROFILE_DIR:-/tmp/node-test/profile.d}"
export NODE_LOG="${NODE_LOG:-/tmp/node-test/node.log}"
export DRY_RUN=1
LOG_LEVEL=debug

rm -rf /tmp/node-test
mkdir -p "$NODE_STATE_DIR" "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR"

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
source "$NODE_DIR/detect.sh"

fails=0
t() { # t <name> <cmd...>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi
}

node_detect

snap="$NODE_LAST_SNAPSHOT"
t "снапшот создан" test -s "$snap"
t "снапшот: заголовок node diagnostics" grep -q "node diagnostics" "$snap"
t "снапшот: ОС (os-release)" grep -qE "^(PRETTY_)?NAME=" "$snap"
t "снапшот: ядро (uname)" grep -q "Linux" "$snap"
t "снапшот: память MemTotal" grep -q "MemTotal" "$snap"
t "снапшот: число CPU" grep -q "^cpus: " "$snap"
t "снапшот: дефолтный интерфейс" grep -q "^default_iface: " "$snap"
t "снапшот: conntrack max/count" grep -q "nf_conntrack_max" "$snap"
t "снапшот: baseline-секция для rollback" grep -q "sysctl-managed-baseline" "$snap"
t "права 0640" bash -c "test \"$(stat -c %a "$snap")\" = 640"
t "в снапшоте нет секретов" bash -c "! grep -Eiq 'password|passwd|token|secret|uuid' '$snap'"
t "NODE_LAST_SNAPSHOT экспортирован" test -n "${NODE_LAST_SNAPSHOT:-}"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: detect (12/12)"; else echo "FAILED: $fails проверок"; exit 1; fi
