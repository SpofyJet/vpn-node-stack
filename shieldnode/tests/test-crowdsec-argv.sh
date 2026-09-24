#!/bin/bash
# shieldnode — тест: пароль crowdsec НЕ попадает в argv curl (backlog #8).
# 2026-09-24 (v1.1.4): updater звал `curl -u "$CROWDSEC_USER:$CROWDSEC_PASSWORD"` —
# пароль виден любому локальному пользователю в /proc/<pid>/cmdline (ps) на время
# запроса. Теперь креды идут curl-конфигом через stdin (`-K -`).
# Под root: `unshare -mn` + tmpfs поверх путей updater'а; curl/nft — заглушки/настоящий.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v nft >/dev/null 2>&1 || { echo "SKIP: нет nft"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
for d in /etc/shieldnode /etc/systemd/system /etc/tmpfiles.d /usr/local/sbin /var/lib/shieldnode /var/log /run; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-csargv
rm -rf "$OUT"; mkdir -p "$OUT/bin"
export SHIELD_DIR SHIELD_VERSION=test SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG=/var/log/shieldnode.log
export SHIELD_LOCK=/run/shieldnode/shieldnode.lock SHIELD_CONFIG="$OUT/config.conf" SHIELD_EXCLUDE="$OUT/none"
: > /var/log/shieldnode.log; unset SSH_CONNECTION
PW='p$(touch /tmp/pwned-cs)"q\z w'
{ printf 'ENABLE_CROWDSEC_LIST=1\nCROWDSEC_INTEGRATION_ID=integration-4242\nCROWDSEC_USER=bl-user\n'
  printf "CROWDSEC_PASSWORD='%s'\n" "$PW"; } > "$SHIELD_CONFIG"

# curl-заглушка: argv — в файл; конфиг из stdin (-K -) — в файл; отдаёт фикстуру
cat > "$OUT/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$OUT/curl.argv"
out=""; prev=""; for a in "\$@"; do
    [ "\$prev" = "-o" ] && out="\$a"
    [ "\$prev" = "-K" ] && [ "\$a" = "-" ] && cat > "$OUT/curl.stdin"
    prev="\$a"; done
[ -n "\$out" ] || exit 1
awk 'BEGIN{for(i=0;i<600;i++) printf "45.%d.%d.9\n", int(i/250)+30, i%250}' > "\$out"
EOF
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/systemctl"; cp "$OUT/bin/systemctl" "$OUT/bin/logger"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

bash "$SHIELD_DIR/main.sh" --dry-run apply 2>/dev/null \
  | awk '/^table inet shieldnode$/{on=1} on && !/^20[0-9][0-9]-[0-9-]+T[0-9:]+Z \[/' > "$OUT/rs.nft"
t "ruleset (crowdsec on) загружен" "nft -f $OUT/rs.nft"
(
    source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
    source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"; source "$SHIELD_DIR/lib/blocklist.sh"
    shield_persist_stream() { mkdir -p "$(dirname "$1")"; cat > "$1"; chmod "${2:-0644}" "$1"; }
    shield_manifest_record() { :; }
    export SH_F_ENABLE_SCANNER_LIST=0 SH_F_ENABLE_THREAT_LIST=0 SH_F_BLOCK_TOR=0 SH_F_ENABLE_CUSTOM_LIST=0 SH_F_ENABLE_CROWDSEC_LIST=1
    shield_blocklist_install
) >/dev/null 2>&1
t "creds-файл создан" "test -s /etc/shieldnode/crowdsec.creds"

rc=0; bash /usr/local/sbin/shieldnode-blocklist crowdsec > /dev/null 2>&1 || rc=$?
t "crowdsec: fetch состоялся (curl вызван для admin.api.crowdsec.net)" "grep -q 'admin.api.crowdsec.net' $OUT/curl.argv"
t "crowdsec: пароль НЕ в argv curl" "! grep -qF 'q\\z' $OUT/curl.argv && ! grep -q 'touch /tmp/pwned-cs' $OUT/curl.argv"
t "crowdsec: логин НЕ в argv curl (-u не используется)" "! grep -q 'bl-user' $OUT/curl.argv && ! grep -qE '(^| )-u ' $OUT/curl.argv"
t "crowdsec: креды переданы curl-конфигом через stdin, с экранированием" \
  "[ \"\$(cat $OUT/curl.stdin)\" = 'user = \"bl-user:p\$(touch /tmp/pwned-cs)\\\"q\\\\z w\"' ]"
t "crowdsec: код из пароля не исполнен" "[ ! -e /tmp/pwned-cs ]"
t "crowdsec: сет наполнен (updater rc=0)" "[ $rc = 0 ] && nft list set inet shieldnode crowdsec_blocklist_v4 | grep -q '45\\.30\\.0\\.9'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: crowdsec-argv (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
