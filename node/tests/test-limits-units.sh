#!/bin/bash
# node — тест: выбор юнитов для drop-in LimitNOFILE (v1.2.0).
# Лаба: у shieldnode-ports.service в Description есть «Xray» — node ставил ему drop-in (правка
# юнита другого компонента). Теперь: только ExecStart с xray/remnanode, юниты стека исключены.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin"
cat > "$OUT/bin/systemctl" <<'EOS'
#!/bin/bash
case "$1" in
  list-units) printf '%s\n' "xray.service loaded active running" "shieldnode-ports.service loaded active running" \
                            "remnanode-agent.service loaded active running" "ssh.service loaded active running" \
                            "node-rt-tweaks.service loaded active running" ;;
  cat) case "$2" in
         xray.service) printf '[Unit]\nDescription=Xray\n[Service]\nExecStart=/usr/local/bin/xray run -c /etc/xray/config.json\n' ;;
         shieldnode-ports.service) printf '[Unit]\nDescription=shieldnode: порты следуют за инбаундами Xray\n[Service]\nExecStart=/bin/bash /opt/vpn-node-stack/shieldnode/main.sh ports-watch\n' ;;
         remnanode-agent.service) printf '[Unit]\nDescription=agent\n[Service]\nExecStart=/opt/remnanode/bin/remnanode\n' ;;
         ssh.service) printf '[Unit]\nDescription=OpenBSD Secure Shell server\n[Service]\nExecStart=/usr/sbin/sshd -D\n' ;;
         node-rt-tweaks.service) printf '[Unit]\nDescription=node rt (xray datapath)\n[Service]\nExecStart=/usr/local/sbin/node-rt-tweaks.sh xray\n' ;;
       esac ;;
esac
EOS
chmod +x "$OUT/bin/systemctl"; export PATH="$OUT/bin:$PATH" NODE_LOG="$OUT/log" NODE_STATE_DIR="$OUT/state"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/lib/limits.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
u="$(node_limits_detect_units | tr '\n' ' ')"; echo "  (units: $u)"
t "xray.service (ExecStart xray) выбран" "[[ ' $u' == *' xray.service '* ]]"
t "remnanode в ExecStart — выбран" "[[ '$u' == *remnanode-agent.service* ]]"
t "shieldnode-ports («Xray» только в Description) — НЕ выбран" "[[ '$u' != *shieldnode-ports* ]]"
t "юниты node-* — НЕ выбраны" "[[ '$u' != *node-rt-tweaks* ]]"
t "ssh — НЕ выбран" "[[ '$u' != *ssh.service* ]]"
echo
if [ "$fails" -eq 0 ]; then echo "PASS: limits-units (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
