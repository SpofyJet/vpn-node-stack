#!/bin/bash
# node — тест: ip_local_reserved_ports резервирует РЕАЛЬНЫЕ инбаунды (v1.2.0, DIAGNOSIS P0-1).
# v1.1.7-1.3.0 резервировал ВСЕ слушающие сокеты в [10240,32767] на момент apply — включая
# эфемерные UDP-сокеты исходящих потоков Xray; реальный инбаунд, не слушавший в тот момент,
# не резервировался. sysctl — заглушка (хост не трогаем).
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/profile" "$OUT/sysctl.d"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" NODE_PROFILE_DIR="$OUT/profile" SYSDB="$OUT/sysdb"
: > "$OUT/log"
printf 'net.ipv4.ip_local_port_range=10240\t65535\nnet.ipv4.ip_local_reserved_ports=\n' > "$SYSDB"
cat > "$OUT/bin/sysctl" <<'EOS'
#!/bin/bash
# sysctl-заглушка: -n KEY / -w/-qw KEY=VAL по файлу $SYSDB
q=0; [ "$1" = -qw ] && { q=1; set -- -w "$2"; }
case "$1" in
  -n) awk -F= -v k="$2" '$1==k{print $2}' "$SYSDB" ;;
  -w) k="${2%%=*}"; v="${2#*=}"; grep -v "^$k=" "$SYSDB" > "$SYSDB.t"; echo "$k=$v" >> "$SYSDB.t"; mv "$SYSDB.t" "$SYSDB" ;;
esac
EOS
cat > "$OUT/bin/ss" <<'EOS'
#!/bin/bash
case "$*" in
  *-Hltn*) printf '%s\n' "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*" "LISTEN 0 4096 *:443 *:*" "LISTEN 0 4096 *:24000 *:*" "LISTEN 0 4096 127.0.0.1:30000 0.0.0.0:*" ;;
  *-Hltnu*|*-Hlu*) printf '%s\n' "UNCONN 0 0 *:41234 *:*" "UNCONN 0 0 *:15555 *:*" ;;
esac
EOS
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
source "$NODE_DIR/lib/sysctl.sh"; source "$NODE_DIR/lib/tcp.sh"
NODE_SYSCTL_BASE="$OUT/sysctl.d/99-z0-node-base.conf"; printf 'net.core.somaxconn = 4096\n' > "$NODE_SYSCTL_BASE"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

# контракт shieldnode: реальные инбаунды
printf '[node]\nx=1\n[shieldnode]\nversion=1.2.0\ninbound_tcp=443 8388 20000-20010\ninbound_udp=8388 36712\nnode_api_port=2222\n' > "$OUT/profile/stack.conf"
r="$(node_reserved_ports_compute 10240 65535)"; echo "  (контракт: $r)"
t "контракт: резерв — инбаунды в эфемерном диапазоне (20000-20010, 36712)" "[ '$r' = '20000-20010,36712' ]"
t "UDP-сокеты из ss (41234, 15555) не резервируются" "[[ '$r' != *41234* && '$r' != *15555* ]]"
r="$(node_reserved_ports_compute 1024 65535)"
t "широкий диапазон [1024,65535]: 2222 и 8388 тоже в резерве (443 < 1024 — нет)" "[ '$r' = '2222,8388,20000-20010,36712' ]"

rm -f "$OUT/profile/stack.conf"
r="$(node_reserved_ports_compute 10240 65535)"
t "без контракта: только TCP LISTEN в диапазоне (24000), не loopback 30000, не UDP" "[ '$r' = '24000' ]"

printf '[shieldnode]\ninbound_tcp=443\ninbound_udp=36712\nnode_api_port=2222\n' > "$OUT/profile/stack.conf"
printf 'TCP_RESERVED_PORTS="50000 1200"\n' > "$OUT/c"; NODE_CONFIG="$OUT/c" node_load_config >/dev/null 2>&1
r="$(node_reserved_ports_compute 10240 65535)"
t "TCP_RESERVED_PORTS оператора — как есть (даже вне диапазона)" "[ '$r' = '1200,36712,50000' ]"
: > "$OUT/c"; NODE_CONFIG="$OUT/c" node_load_config >/dev/null 2>&1

# runtime-синхронизация
node_reserve_ports_sync
t "sync: runtime = 36712" "grep -qx 'net.ipv4.ip_local_reserved_ports=36712' '$SYSDB'"
t "sync: строка в sysctl-файле node (переживёт reboot), прочее цело" "grep -qx 'net.ipv4.ip_local_reserved_ports = 36712' '$NODE_SYSCTL_BASE' && grep -q somaxconn '$NODE_SYSCTL_BASE'"
t "sync: исходное (пустое) — в реестре отката" "grep -qP '^net.ipv4.ip_local_reserved_ports\t$' '$OUT/state/sysctl-orig.tsv'"
cp "$NODE_SYSCTL_BASE" "$OUT/before"; : > "$OUT/log"
node_reserve_ports_sync
t "sync: повторно без изменений — ничего не пишет (идемпотентно)" "cmp -s '$OUT/before' '$NODE_SYSCTL_BASE' && ! grep -q 'reserved_ports:' '$OUT/log'"
printf '[shieldnode]\ninbound_tcp=443 25000\ninbound_udp=36712\nnode_api_port=2222\n' > "$OUT/profile/stack.conf"
node_reserve_ports_sync
t "sync: новый инбаунд 25000 — резерв обновлён" "grep -qx 'net.ipv4.ip_local_reserved_ports=25000,36712' '$SYSDB'"
t "sync: исходное в реестре не перезаписано текущим" "[ \$(grep -c ip_local_reserved_ports '$OUT/state/sysctl-orig.tsv') = 1 ]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: reserved-ports (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
