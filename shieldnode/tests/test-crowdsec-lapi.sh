#!/bin/bash
# shieldnode — тест: LAPI crowdsec на занятом 127.0.0.1:8080 переносится (v1.1.6).
# С ENABLE_CROWDSEC_LIST=1 по умолчанию демон ставится на каждую ноду; LAPI 8080 часто занят
# (HTTP-inbound Xray/nginx) — демон не стартовал, список оставался пустым.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/etc"
cat > "$OUT/bin/ss" <<'EOS'
#!/bin/bash
# занятые порты: из $BUSY ("8080:nginx 18080:xray")
for b in $BUSY; do p="${b%%:*}"; n="${b#*:}"
    case "$*" in *"sport = :$p"*) echo "LISTEN 0 511 127.0.0.1:$p 0.0.0.0:* users:((\"$n\",pid=9,fd=6))" ;; esac; done
exit 0
EOS
printf '#!/bin/sh\necho "$*" >> "%s/sysctl.calls"\ncase "$*" in *is-active*) exit "${FAKE_ACTIVE:-3}" ;; esac\nexit 0\n' "$OUT" > "$OUT/bin/systemctl"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
export SHIELD_DIR SHIELD_LOG="$OUT/log" SHIELD_STATE_DIR="$OUT/state" SHIELD_CROWDSEC_ETC="$OUT/etc"; : > "$OUT/log"
source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"
fx() { printf 'api:\n  server:\n    listen_uri: 127.0.0.1:8080\n' > "$OUT/etc/config.yaml"
       printf 'url: http://127.0.0.1:8080\nlogin: x\n' > "$OUT/etc/local_api_credentials.yaml"; : > "$OUT/sysctl.calls"; }
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

fx; BUSY="8080:nginx" shield_crowdsec_lapi_port_fix >/dev/null 2>&1
t "8080 занят nginx: LAPI -> 18080 (config.yaml)" "grep -q 'listen_uri: 127.0.0.1:18080' '$OUT/etc/config.yaml'"
t "8080 занят nginx: url в local_api_credentials -> 18080" "grep -qx 'url: http://127.0.0.1:18080' '$OUT/etc/local_api_credentials.yaml'"
t "restart crowdsec вызван" "grep -q 'restart crowdsec.service' '$OUT/sysctl.calls'"
fx; BUSY="8080:nginx 18080:xray" shield_crowdsec_lapi_port_fix >/dev/null 2>&1
t "18080 тоже занят -> 18081" "grep -q 'listen_uri: 127.0.0.1:18081' '$OUT/etc/config.yaml'"
fx; BUSY="" shield_crowdsec_lapi_port_fix >/dev/null 2>&1
t "8080 свободен: конфиг не тронут" "grep -q 'listen_uri: 127.0.0.1:8080' '$OUT/etc/config.yaml' && ! grep -q restart '$OUT/sysctl.calls'"
fx; BUSY="8080:crowdsec" shield_crowdsec_lapi_port_fix >/dev/null 2>&1
t "8080 занят самим crowdsec: не тронут" "grep -q 'listen_uri: 127.0.0.1:8080' '$OUT/etc/config.yaml'"
fx; FAKE_ACTIVE=0 BUSY="8080:nginx" shield_crowdsec_lapi_port_fix >/dev/null 2>&1
t "демон активен: не трогаем" "grep -q 'listen_uri: 127.0.0.1:8080' '$OUT/etc/config.yaml'"
# --- установка агента: install-скрипт переехал на корень install.crowdsec.net (v1.1.6) ---
# /install.sh отдаёт 403 (S3) — раньше агент не ставился нигде. curl/apt/cscli — заглушки.
if ! command -v cscli >/dev/null 2>&1; then
cat > "$OUT/bin/curl" <<EOS
#!/bin/bash
out=""; prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
url="\${@: -1}"; echo "\$url" >> "$OUT/curl.calls"
case "\$url:\${CS_ROOT:-script}" in
    */install.sh:*) exit 22 ;;
    *:html)   echo '<html>403</html>' > "\$out" ;;
    *:script) printf '#!/bin/sh\necho REPO_SCRIPT_RAN >> "%s/calls"\n' "$OUT" > "\$out" ;;
esac
EOS
cat > "$OUT/bin/apt-get" <<EOS
#!/bin/sh
echo "apt-get \$*" >> "$OUT/calls"
printf '#!/bin/sh\ncase "\\\$*" in "decisions list"*) echo "[]" ;; esac\nexit 0\n' > "$OUT/bin/cscli"; chmod +x "$OUT/bin/cscli"
EOS
chmod +x "$OUT/bin/curl" "$OUT/bin/apt-get"
shield_conf_get() { echo "${2:-}"; }
: > "$OUT/calls"; : > "$OUT/curl.calls"; rm -f "$OUT/bin/cscli"; hash -r
rc=0; DRY_RUN=0 shield_crowdsec_agent_ensure >/dev/null 2>&1 || rc=$?
t "агент: скачан корень https://install.crowdsec.net (не 403-путь /install.sh)" "head -1 '$OUT/curl.calls' | grep -qx 'https://install.crowdsec.net'"
t "агент: скрипт репозитория выполнен, затем apt-get install crowdsec" "grep -q REPO_SCRIPT_RAN '$OUT/calls' && grep -q 'apt-get .*install -y crowdsec' '$OUT/calls' && [ $rc = 0 ]"
: > "$OUT/calls"; : > "$OUT/curl.calls"; rm -f "$OUT/bin/cscli"; hash -r
rc=0; CS_ROOT=html DRY_RUN=0 shield_crowdsec_agent_ensure >/dev/null 2>&1 || rc=$?
t "агент: вместо скрипта HTML/403 -> не исполняем, apt не зовём, rc!=0 (apply не падает: || true)" "[ $rc != 0 ] && ! grep -q 'apt-get' '$OUT/calls' && grep -q 'install.sh' '$OUT/curl.calls'"
rm -f "$OUT/bin/cscli" "$OUT/bin/curl" "$OUT/bin/apt-get"
else
    echo "skip - установка агента: cscli уже есть на хосте"
fi

# зависший cscli (нет сети / LAPI) не держит apply фаервола: вызовы с таймаутом (v1.1.6)
printf '#!/bin/sh\nsleep 60\n' > "$OUT/bin/cscli"; chmod +x "$OUT/bin/cscli"; hash -r
start=$(date +%s); SHIELD_CSCLI_TIMEOUT=1 DRY_RUN=1 FAKE_ACTIVE=0 shield_crowdsec_agent_ensure >/dev/null 2>&1 || true; el=$(( $(date +%s) - start ))
t "зависший cscli: agent-шаг укладывается в таймауты (${el}с < 15с)" "[ $el -lt 15 ]"
rm -f "$OUT/bin/cscli"; hash -r

echo
if [ "$fails" -eq 0 ]; then echo "PASS: crowdsec-lapi (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
