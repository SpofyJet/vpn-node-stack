#!/bin/bash
# node — тест: парсер конфига (config.sh) — регрессии зафиксированных багов.
# Запуск: bash tests/test-config.sh
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-cfg-test/state
export NODE_LOG=/tmp/node-cfg-test/node.log
LOG_LEVEL=error   # тихо: load_config логирует прогон

rm -rf /tmp/node-cfg-test
mkdir -p "$NODE_STATE_DIR" /tmp/node-cfg-test/etc

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"

fails=0
# Проверка eval'ом в ТЕКУЩЕМ шелле: bash -c не видит неэкспортированные функции.
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# --- 1. inline-комментарий не отравляет значение (баг HARDEN_THP) ---
NODE_CONFIG=/tmp/node-cfg-test/etc/node.conf
printf 'NETDEV_BUDGET=600   # мой комментарий\n' > "$NODE_CONFIG"
node_load_config
t "inline-comment отрезается" 'test "$(node_conf_get NETDEV_BUDGET 0)" = 600'
t "значение без хвостовых пробелов" 'test "$(node_conf_get NETDEV_BUDGET 0 | wc -c)" = 4'

# --- 2. CRLF-конфиг (Windows) читается ---
printf 'TCP_MAX_TW_BUCKETS=777777\r\nENABLE_BUSY_POLL=1\r\n' > "$NODE_CONFIG"
node_load_config
t "CRLF: значение чистое" 'test "$(node_conf_get TCP_MAX_TW_BUCKETS 0)" = 777777'
t "CRLF: флаг читается" 'test "$(node_conf_get ENABLE_BUSY_POLL 0)" = 1'

# --- 3. первое совпадение выигрывает (user-конфиг раньше defaults) ---
printf 'NETDEV_BUDGET=111\nNETDEV_BUDGET=222\n' > "$NODE_CONFIG"
node_load_config
t "first-match: 111, а не 222" 'test "$(node_conf_get NETDEV_BUDGET 0)" = 111'

# --- 4. кавычки снимаются ---
printf 'NETDEV_BUDGET="444"\n' > "$NODE_CONFIG"
node_load_config
t "кавычки снимаются" 'test "$(node_conf_get NETDEV_BUDGET 0)" = 444'

# --- 5. пустое значение => default (авто-семантика) ---
printf 'NETDEV_BUDGET=\n' > "$NODE_CONFIG"
node_load_config
t "пусто => default 600" 'test "$(node_conf_get NETDEV_BUDGET 600)" = 600'

# --- 6. строки без '=' и мусор игнорируются, defaults подхватываются ---
printf 'это не конфиг\n NETDEV_BUDGET=555\n# комментарий\n' > "$NODE_CONFIG"
node_load_config
t "defaults подхватываются" 'test "$(node_conf_get TCP_MEM_PCT 0)" = 25'
t "user-значение с пробелом-индентом НЕ матчится (regex ^)" 'test "$(node_conf_get NETDEV_BUDGET 600)" = 600'

rm -f "$NODE_CONFIG"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: config (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
