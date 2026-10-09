#!/bin/bash
# node — тест: node_udp_health (v1.2.2) — разбор `ss -uamnp` для UDP-сокетов прокси: буфер, очередь,
# потери и подсказка по причине (буфер меньше запроса quic-go -> rmem_max/NET_ADMIN; полный -> CPU).
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log"
: > "$OUT/log"
cat > "$OUT/bin/ss" <<'EOF'
#!/bin/bash
cat <<'X'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
UNCONN 0      0            0.0.0.0:443       0.0.0.0:*    users:(("rw-core",pid=2054,fd=12))
	 skmem:(r4608,rb16777216,t0,tb16777216,f0,w0,o0,bl0,d37)
UNCONN 0      0                  *:8388              *:*    users:(("rw-core",pid=2054,fd=9))
	 skmem:(r0,rb212992,t0,tb212992,f0,w0,o0,bl0,d5)
UNCONN 0      0            0.0.0.0:36712     0.0.0.0:*    users:(("xray",pid=77,fd=3))
	 skmem:(r0,rb16777216,t0,tb16777216,f0,w0,o0,bl0,d0)
UNCONN 0      0      127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=500,fd=13))
	 skmem:(r0,rb212992,t0,tb212992,f0,w0,o0,bl0,d99)
X
EOF
printf '#!/bin/bash\nexit 1\n' > "$OUT/bin/ethtool"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
source "$NODE_DIR/lib/udp.sh"
node_udp_health > "$OUT/h" 2>&1
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
t "заголовок: память UDP, RcvbufErrors, NIC RX" "grep -q '^UDP (QUIC/Hysteria2): память UDP .* RcvbufErrors с загрузки: .* NIC RX-кольцо нет данных' $OUT/h"
t ":443 — потери при полном буфере 16 МиБ -> причина CPU, не память" "grep -q 'ПОТЕРИ: сокет 0.0.0.0:443 (rw-core): буфер 16 МиБ, в очереди 4608 Б, потеряно 37 пакетов — буфер полный по размеру: Xray не успевает читать' $OUT/h"
t ":8388 — потери при буфере 208 КиБ -> rmem_max/NET_ADMIN" "grep -q 'ПОТЕРИ: сокет \\*:8388 (rw-core): буфер 208 КиБ, .*потеряно 5 пакетов — буфер меньше, чем просит quic-go' $OUT/h"
# 2026-10-08: эфемерный сокет без потерь — только в сводке (раньше строка на КАЖДЫЙ сокет:
# на живой ноде ~3000 строк исходящих UDP-потоков rw-core)
t "xray :36712 без потерь — в сводке, не поштучно" "grep -q '  xray: UDP-сокетов 1 (буфер 16 МиБ…16 МиБ), в очередях 0 Б, потерь на открытых сокетах 0 — ok' $OUT/h && ! grep -q ':36712' $OUT/h"
t "сводка rw-core: 2 сокета, потери суммируются" "grep -q '  rw-core: UDP-сокетов 2 (буфер 208 КиБ…16 МиБ), в очередях 4608 Б, потерь на открытых сокетах 42 — см. ниже' $OUT/h"
t "чужие процессы (systemd-resolved) не показываются" "! grep -q ':53' $OUT/h"

# 2026-10-08: живая нода — тысячи эфемерных UDP-сокетов rw-core: вывод не растёт с их числом
cat > "$OUT/bin/ss" <<'EOF'
#!/bin/bash
echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
for i in $(seq 1 3000); do
    printf 'UNCONN 0      0            0.0.0.0:%d     0.0.0.0:*    users:(("rw-core",pid=2054,fd=%d))\n\t skmem:(r0,rb212992,t0,tb212992,f0,w0,o0,bl0,d0)\n' $((40000 + i)) $((100 + i))
done
EOF
node_udp_health > "$OUT/h2" 2>&1
t "3000 эфемерных сокетов -> сводка в 1 строку (+заголовок)" "[ \$(wc -l < $OUT/h2) -le 3 ] && grep -q 'rw-core: UDP-сокетов 3000 ' $OUT/h2"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: udp-health"; else cat "$OUT/h"; echo "FAILED: $fails"; exit 1; fi
