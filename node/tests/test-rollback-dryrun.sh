#!/bin/bash
# node — тест: `rollback --dry-run` не выполняет откат (v1.2.12). До этой версии флаг читал только
# apply, и «пробный» откат на живой ноде снимал всё по-настоящему.
# Безопасность самого теста: работает с копией модуля, где rollback.sh заменён заглушкой (настоящий
# откат невозможен даже при провале), и не под root (state уходит в /tmp).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
# rootless-режим main.sh заводит свой state в /tmp/node-rollback.XXXXXX (абсолютный шаблон, мимо TMPDIR) — убираем за собой
BEFORE="$(ls -d /tmp/node-rollback.* 2>/dev/null | sort || true)"
cleanup() {
    local d
    for d in /tmp/node-rollback.*; do
        [ -d "$d" ] || continue
        grep -qxF "$d" <<<"$BEFORE" || rm -rf -- "$d"
    done
    rm -rf "$OUT"
}
trap cleanup EXIT
chmod 755 "$OUT"; mkdir -p "$OUT/tmp"; chmod 1777 "$OUT/tmp"
cp -a "$SRC" "$OUT/node"
printf '%s\n' '#!/bin/bash' 'node_rollback() { echo "CALLED ${1:-}" > "$MARK"; }' > "$OUT/node/rollback.sh"
: > "$OUT/mark"; chmod 666 "$OUT/mark"; chmod -R a+rX "$OUT/node"
fail=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fail=1; }
run() { # run <аргументы main.sh> — не под root
    if [ "$(id -u)" -eq 0 ]; then
        setpriv --reuid=65534 --regid=65534 --clear-groups env MARK="$OUT/mark" TMPDIR="$OUT/tmp" bash "$OUT/node/main.sh" "$@" 2>&1
    else
        env MARK="$OUT/mark" TMPDIR="$OUT/tmp" bash "$OUT/node/main.sh" "$@" 2>&1
    fi
}
echo "== rollback --dry-run"
out="$(run rollback --dry-run)" && rc=0 || rc=$?
[ "$rc" = 0 ] && ok "код возврата 0" || bad "код возврата $rc: $out"
[ ! -s "$OUT/mark" ] && ok "node_rollback не вызван" || bad "node_rollback ВЫЗВАН при --dry-run: $(cat "$OUT/mark")"
grep -q "rollback: ничего не меняем" <<<"$out" && ok "сказано, что ничего не меняется" || bad "нет строки dry-run: $out"
echo "== rollback --dry-run с набором"
: > "$OUT/mark"
out="$(run rollback 20261114-010203 --dry-run)" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ ! -s "$OUT/mark" ] && grep -q "набор 20261114-010203" <<<"$out" && ok "набор назван, откат не вызван" || bad "rc=$rc mark=$(cat "$OUT/mark") out=$out"
echo "== rollback без --dry-run не под root — отказ, а не откат"
: > "$OUT/mark"
out="$(run rollback)" && rc=0 || rc=$?
[ "$rc" != 0 ] && [ ! -s "$OUT/mark" ] && ok "без root и без --dry-run — отказ (rc=$rc)" || bad "rc=$rc mark=$(cat "$OUT/mark")"
[ "$fail" = 0 ] && echo "PASS test-rollback-dryrun" || { echo "FAILED test-rollback-dryrun"; exit 1; }
