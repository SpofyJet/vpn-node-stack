#!/bin/bash
# node — тест: read-only режимы не оставляют временных файлов (mktemp honours TMPDIR).
# 2026-09-24 (v1.1.6): node_load_config (CONFIG_CACHE) и node_sysctl_plan_init
# (NODE_PLAN_FILE) делали mktemp без очистки — каждый status/apply/detect оставлял
# 1-2 файла в /tmp (на живой ноде за сутки — ~400 кэшей конфига и ~360 планов).
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/tmp" "$OUT/state"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
run() { TMPDIR="$OUT/tmp" NODE_CONFIG="$OUT/none" bash "$NODE_DIR/main.sh" "$@" >/dev/null 2>&1 || true; }
run status
t "status: 0 временных файлов после выхода" "[ -z \"\$(ls -A $OUT/tmp)\" ]"
run --dry-run apply
t "--dry-run apply: 0 временных файлов (кроме снапшота rootless-state)" "[ -z \"\$(ls -A $OUT/tmp | grep -v '^node-apply\\.')\" ]"
run detect
t "detect: 0 временных файлов (кроме снапшота rootless-state)" "[ -z \"\$(ls -A $OUT/tmp | grep -v '^node-apply\\.\\|^node-detect\\.')\" ]"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: tmp-leak (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
