#!/bin/bash
# node — тест: слабые места v1.1.2 (2026-09-23).
#   ip route по ключевым словам (dev/via) на всех раскладках: nhid, без шлюза
#   (OpenVZ/wg), multipath, несколько default, пусто; отсутствие SIGPIPE под
#   pipefail при большом выводе; ss Local-порт без номеров колонок; кэш MemTotal;
#   RSS-веса при queues > cpus; документированность ключей конфига; SC2155 в main.sh.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-ws112
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log"
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$NODE_STATE_DIR"; : > "$NODE_LOG"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ---------- ip route: mock с выбором раскладки ----------
cat > "$OUT/bin/ip" <<'EOF'
#!/bin/bash
case "$LAYOUT" in
  std)       echo "default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.5 metric 100" ;;
  nhid)      echo "default nhid 12 via 10.0.0.1 dev eth0 proto static" ;;
  nogw)      echo "default dev venet0 scope link" ;;
  multipath) echo "default proto static metric 100 nexthop via 10.0.0.1 dev eth0 weight 1 nexthop via 10.0.1.1 dev eth1 weight 1" ;;
  two)       printf 'default via 10.0.0.1 dev eth0 metric 100\ndefault via 10.0.9.1 dev eth9 metric 200\n' ;;
  none)      : ;;
  huge)      echo "default via 10.0.0.1 dev eth0"; for i in $(seq 1 200000); do echo "default via 10.9.9.9 dev ethX metric $i"; done ;;
esac
EOF
chmod +x "$OUT/bin/ip"; export PATH="$OUT/bin:$PATH"
chk() { local l="$1" dev="$2" gw="$3"
    t "route $l: dev=${dev:-∅}" "[ \"\$(LAYOUT=$l node_default_iface)\" = '$dev' ]"
    t "route $l: via=${gw:-∅}"  "[ \"\$(LAYOUT=$l node_default_gw)\" = '$gw' ]"; }
chk std eth0 10.0.0.1; chk nhid eth0 10.0.0.1; chk nogw venet0 ""; chk multipath eth0 10.0.0.1; chk two eth0 10.0.0.1; chk none "" ""
t "старый \$5 ломался на nhid/nogw/multipath (условие регрессии)" \
  '[ "$(LAYOUT=nhid ip -o -4 route show to default | awk "{print \$5; exit}")" = 10.0.0.1 ] && [ "$(LAYOUT=nogw ip -o -4 route show to default | awk "{print \$5; exit}")" = link ]'
t "большой вывод: helper читает до конца — rc 0 под pipefail (нет SIGPIPE)" \
  'x="$(LAYOUT=huge node_default_iface)"; [ "$x" = eth0 ]'
t "не осталось \$5/\$3-скрейпа ip route в node" \
  '! grep -rnE "route show to default[^|]*\| *awk .\{print \\\$[0-9]" "$NODE_DIR" --include=*.sh'

# ---------- ss ----------
printf '%s\n' 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
  'LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1,fd=4))' 'LISTEN 0 128 127.0.0.53%lo:53 0.0.0.0:* users:(("x",pid=2,fd=5))' > "$OUT/ss.state"
sed 's/^LISTEN //; 1s/^State  //' "$OUT/ss.state" > "$OUT/ss.nostate"
t "ss: Local-порт с колонкой State (IPv6 [::]:p)" '[ "$(_ss_local_ports sshd < "$OUT/ss.state")" = 2222 ]'
t "ss: Local-порт БЕЗ колонки State (другой набор колонок)" '[ "$(_ss_local_ports sshd < "$OUT/ss.nostate")" = 2222 ]'
t "ss: %iface-суффикс" '[ "$(_ss_local_ports "\"x\"" < "$OUT/ss.state")" = 53 ]'
t "self-test ssh-порт через helper (не \$4)" 'grep -q "_ss_local_ports sshd" "$NODE_DIR/apply.sh" && ! grep -q "split(\$4" "$NODE_DIR/apply.sh"'

# ---------- кэш MemTotal ----------
printf 'MemTotal:        2097152 kB\n' > "$OUT/mem"
t "memtotal: фикстура обходит кэш" '[ "$(_NODE_MEMTOTAL_MB=777 NODE_PROC_MEMINFO=$OUT/mem node_memtotal_mb)" = 2048 ]'
t "memtotal: без фикстуры — значение из кэша (без чтения /proc)" '[ "$( unset NODE_PROC_MEMINFO; _NODE_MEMTOTAL_MB=777 node_memtotal_mb)" = 777 ]'
t "memtotal: node_load_config заполняет кэш = прямому чтению" \
  '( unset NODE_PROC_MEMINFO; NODE_CONFIG=/nonexistent node_load_config >/dev/null 2>&1; [ -n "$_NODE_MEMTOTAL_MB" ] && [ "$_NODE_MEMTOTAL_MB" = "$(_node_memtotal_read)" ] )'

# ---------- RSS: queues > cpus ----------
t "rss: вес не опускается до 0 при queues > cpus" 'grep -q "local w=\$((cpus / queues)); \[ \"\$w\" -ge 1 \] || w=1" "$NODE_DIR/lib/irq.sh"'
t "rss: 2 CPU / 4 очереди -> вес 1 (было 0 0 0 0)" 'cpus=2; queues=4; w=$((cpus / queues)); [ "$w" -ge 1 ] || w=1; [ "$w" = 1 ]'

# ---------- конфиг/мелочи ----------
missing="$(grep -rhoE 'node_conf_get[[:space:]]+"?[A-Z_][A-Z0-9_]*' --include=*.sh "$NODE_DIR" | grep -v tests | awk '{print $2}' | tr -d '"' | sort -u | while read -r k; do grep -qE "^(# )?$k=" "$NODE_DIR/node.defaults.conf" || echo "$k"; done)"
t "каждый ключ, читаемый кодом, есть в node.defaults.conf${missing:+ (нет: $missing)}" '[ -z "$missing" ]'
t "документированные ключи не загружаются как значения (закомментированы)" \
  '( NODE_CONFIG=/nonexistent node_load_config >/dev/null 2>&1; ! grep -qE "^(FQ_|NET_[RW]MEM_DEFAULT|VM_MAX_MAP_COUNT)" "$CONFIG_CACHE" )'
t "контракт: значение оператора в node.conf побеждает (FQ_LIMIT=200000)" \
  '( printf "FQ_LIMIT=200000\n" > $OUT/c.conf; NODE_CONFIG=$OUT/c.conf node_load_config >/dev/null 2>&1; [ "$(node_conf_get FQ_LIMIT 100000)" = 200000 ] )'
t "контракт: дописанное в кэш переопределение не перекрыто defaults" \
  '( NODE_CONFIG=/nonexistent node_load_config >/dev/null 2>&1; echo FQ_LIMIT=300000 >> "$CONFIG_CACHE"; [ "$(node_conf_get FQ_LIMIT 100000)" = 300000 ] )'
t "SC2155: export+\$(mktemp) разделены в main.sh" '! grep -qE "export NODE_STATE_DIR=\"\\\$\(mktemp" "$NODE_DIR/main.sh"'
t "apt: Acquire::Retries для XanMod" '[ "$(grep -c "Acquire::Retries=3" "$NODE_DIR/lib/kernel.sh")" = 2 ]'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: weakspots-112 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
