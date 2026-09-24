#!/bin/bash
# shieldnode — тест: apply при временно лежащем xray не теряет его защищаемые порты.
# 2026-09-24 (v1.1.5): keep-last-good в shield_detect_protected_ports срабатывал только
# при ПОЛНОСТЬЮ пустом списке, а SSH-порты в нём есть всегда; для UDP keep-last-good не
# было вовсе. apply во время рестарта remnanode/xray молча выводил порты xray из
# protected_tcp/protected_udp — abuse-лимиты для VPN-портов выключены до след. apply.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state"
cat > "$OUT/bin/ss" <<'EOF'
#!/bin/bash
up="$(cat "$SS_MODE_FILE")"
x_tcp='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=77,fd=7))'
x_udp='UNCONN 0 0 0.0.0.0:8443 0.0.0.0:* users:(("xray",pid=77,fd=9))'
ssh='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
case "$*" in
  "-tulnp") echo 'Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
            echo "tcp $ssh"; [ "$up" = up ] && { echo "tcp $x_tcp"; echo "udp $x_udp"; } ;;
  "-ulnp")  echo 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'; [ "$up" = up ] && echo "$x_udp" ;;
  "-tlnp")  echo 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'; echo "$ssh"; [ "$up" = up ] && echo "$x_tcp" ;;
  *) echo 'Recv-Q Send-Q Local Address:Port Peer Address:Port Process' ;;
esac
EOF
chmod +x "$OUT/bin/ss"
export PATH="$OUT/bin:$PATH" SS_MODE_FILE="$OUT/mode" SHIELD_DIR SHIELD_STATE_DIR="$OUT/state" SHIELD_LOG="$OUT/log"
export SHIELD_CONFIG="$OUT/c" SHIELD_EXCLUDE="$OUT/none" SSH_CONNECTION=""
printf 'SSH_PORT=22\n' > "$OUT/c"; : > "$OUT/log"
fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
resolve() { bash -c 'source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; shield_load_config
    source "$SHIELD_DIR/detect.sh"; source "$SHIELD_DIR/limits.sh"; shield_limits_resolve >/dev/null 2>&1
    echo "TCP=[$SH_F_PROTECTED_TCP] UDP=[$SH_F_PROTECTED_UDP]"'; }
echo up > "$OUT/mode";   r1="$(resolve)"
echo down > "$OUT/mode"; r2="$(resolve)"
echo "  (xray up: $r1 | xray down: $r2)"
t "xray up: 443/tcp и 8443/udp под защитой" "[[ '$r1' == *'TCP=[22 443'* && '$r1' == *'UDP=[8443]'* ]]"
t "xray временно лежит: 443/tcp сохранён (keep-last-good)" "[[ '$r2' == *'443'* ]] && [[ '$r2' == TCP=*443*' UDP='* ]]"
t "xray временно лежит: 8443/udp сохранён (keep-last-good)" "[[ '$r2' == *'UDP=[8443]'* ]]"
t "keep-last-good — с предупреждением в логе" "grep -q 'keep-last-good' $OUT/log"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: protected-keep (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
