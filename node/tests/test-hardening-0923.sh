#!/bin/bash
# node — тест: регрессии аудита 2026-09-23.
#   scrub (все секреты строки, JSON, «голые» UUID) + создание лог-файла main.sh;
#   node-rt-tweaks: shebang (203/EXEC), ReadWritePaths под ProtectSystem=strict,
#   tmpfiles /run/node; cpumask группами по 32 бита (EOVERFLOW на >32 CPU);
#   откат RSS; nic_diag без ethtool-статистики; валидация FQ_* и BACKUP_KEEP.
# Части, требующие root (main.sh на реальных путях, запись в sysfs), идут в
# `unshare -mn` с tmpfs поверх /var/log,/var/lib,/run; без root — skip.
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-0923
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diag" NODE_PROFILE_DIR="$OUT/profile.d"
export NODE_LOG="$OUT/node.log" NODE_RT_TWEAKS="$OUT/state/runtime-tweaks.tsv" DRY_RUN=0
rm -rf "$OUT"; mkdir -p "$NODE_DIAG_DIR" "$NODE_PROFILE_DIR" "$OUT/bin" "$OUT/out"; : > "$NODE_LOG"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ---------- scrub ----------
S="$(printf '%s' 'token=AAAA1111 password=hunter2secret {"password": "jsonpw99"} Bearer bt0k id 3f2b9c1e-7d4a-4e21-9b3c-0a1b2c3d4e5f tokens: 5' | scrub)"
t "scrub: ВСЕ секреты строки (второй тоже)"   '! grep -qE "AAAA1111|hunter2secret" <<<"$S"'
t "scrub: JSON-форма \"password\": \"x\""      '! grep -q jsonpw99 <<<"$S"'
t "scrub: Bearer-токен"                        '! grep -q bt0k <<<"$S"'
t "scrub: «голый» UUID"                        '! grep -q 3f2b9c1e-7d4a <<<"$S" && grep -q "\*\*\*\*-uuid" <<<"$S"'
t "scrub: обычный текст не портится"           'grep -q "tokens: 5" <<<"$S"'

# ---------- rt unit (persist-stub в $OUT/out, как test-irq-rt) ----------
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/apply.sh"
node_persist_stream() { local dst="$1"; mkdir -p "$OUT/out$(dirname "$dst")"; cat > "$OUT/out$dst"; }
systemctl() { return 0; }; udevadm() { return 0; }
node_rt_boot_persist >/dev/null 2>&1
U="$OUT/out/etc/systemd/system/node-rt-tweaks.service"; W="$OUT/out/usr/local/sbin/node-rt-tweaks.sh"; TF="$OUT/out/etc/tmpfiles.d/node.conf"
t "rt: wrapper начинается с #!/bin/bash (systemd execve без sh-fallback)" '[ "$(head -1 "$W")" = "#!/bin/bash" ]'
t "rt: ProtectSystem=strict сохранён"          'grep -qx "ProtectSystem=strict" "$U"'
for p in /run/node "$NODE_STATE_DIR" "$NODE_LOG" /etc/systemd/system /usr/local/sbin; do
    t "rt: ReadWritePaths содержит -$p"         "grep '^ReadWritePaths=' '$U' | tr ' =' '\n\n' | grep -qx -- '-$p'"
done
t "rt: tmpfiles создаёт /run/node при boot"    'grep -qx "d /run/node 0755 root root -" "$TF"'
t "rt: tmpfiles создаёт лог"                   'grep -qx "f $NODE_LOG 0640 root root -" "$TF"'
unset -f systemctl udevadm

# ---------- cpumask ----------
source "$NODE_DIR/lib/irq.sh"
t "cpumask: <=32 CPU — прежний вывод (e)"      '[ "$(node_cpumask_hex 14)" = e ]'
t "cpumask: 34 CPU — группы по 32 бита"         '[ "$(node_cpumask_hex $(( (1<<34) - 4 )))" = "3,fffffffc" ]'
t "cpumask: 64 CPU"                             '[ "$(node_cpumask_hex -1)" = "ffffffff,ffffffff" ]'
t "cpumask: RPS и XPS пишут через хелпер"       '[ "$(grep -c "node_cpumask_hex \"\$mask\" >" "$NODE_DIR/lib/irq.sh")" = 2 ] && ! grep -q "printf .%x. \"\$mask\" >" "$NODE_DIR/lib/irq.sh"'
if [ "$(id -u)" -eq 0 ] && unshare -n true 2>/dev/null; then
    t "cpumask: ядро принимает вывод хелпера; одно слово >8 цифр — EOVERFLOW" \
      "unshare -n bash -c 'source $NODE_DIR/lib/irq.sh; node_cpumask_hex 1 > /sys/class/net/lo/queues/rx-0/rps_cpus && ! printf 000000001 > /sys/class/net/lo/queues/rx-0/rps_cpus' 2>/dev/null"
else echo "skip - cpumask kernel write (root+unshare)"; fi

# ---------- RSS rollback ----------
cat > "$OUT/bin/ethtool" <<EOF
#!/bin/sh
echo "\$*" >> "$OUT/ethtool.calls"
case "\$1" in -k) echo "large-receive-offload: off [fixed]" ;; -S) echo "no stats available" >&2; exit 94 ;; esac
exit 0
EOF
printf '#!/bin/sh\ncase "$*" in *"route show to default"*) echo "default via 127.0.0.1 dev lo" ;; esac\nexit 0\n' > "$OUT/bin/ip"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
: > "$OUT/ethtool.calls"; : > "$NODE_RT_TWEAKS"
node_rt_record eth9 rss indir default; node_rt_rollback >/dev/null 2>&1
t "rss: rollback вызывает ethtool -X <if> default" 'grep -qx -- "-X eth9 default" "$OUT/ethtool.calls"'
t "rss: irq_apply записывает твик в реестр"     'grep -q "node_rt_record \"\$ifname\" rss" "$NODE_DIR/lib/irq.sh"'

# ---------- nic_diag: нет ethtool-статистики (wg/tun/venet) ----------
source "$NODE_DIR/lib/nic.sh"
NODE_STEP_RC=0; NODE_STEP_FAILED=""
node_step_run nic_diag node_nic_diag >/dev/null 2>&1
t "nic_diag: 'no stats available' не валит шаг"  '[ "$NODE_STEP_RC" = 0 ]'

# ---------- валидация конфига ----------
printf 'FQ_LIMIT=1; touch %s/pwned\nBACKUP_KEEP=abc\n' "$OUT" > "$OUT/node.conf"
NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
source "$NODE_DIR/lib/datapath.sh"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/tc"; chmod +x "$OUT/bin/tc"
( DRY_RUN=1; node_fq_tune_apply ) >/dev/null 2>&1 || true
FQ="$OUT/out/usr/local/sbin/node-fq-tune.sh"
t "FQ_*: мусор не попадает в генерируемый root-скрипт" '[ -f "$FQ" ] && grep -qx "LIM=100000" "$FQ" && ! grep -q touch "$FQ"'
echo data > "$OUT/f.conf"
t "BACKUP_KEEP=abc: backup не падает (fallback 5)" '( backup "$OUT/f.conf" ) && ls "$OUT"/f.conf.pre-node-*'

# ---------- Phase 4 opt-in: ENABLE_TCP_BUF_TUNE / ENABLE_EEE_OFF ----------
source "$NODE_DIR/lib/sysctl.sh"; source "$NODE_DIR/lib/tcp.sh"
printf 'MemTotal:       16777216 kB\n' > "$OUT/mem16g"; printf 'MemTotal:        1048576 kB\n' > "$OUT/mem1g"
printf 'ENABLE_TCP_BUF_TUNE=0\n' > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem16g"; node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.off" )
t "ENABLE_TCP_BUF_TUNE=0: tcp_rmem/wmem НЕ планируются" '! grep -q "tcp_[rw]mem" "$OUT/plan.off"'
: > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem16g"; node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.t4" )
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem1g";  node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.t1" )
t "дефолт (v1.1.7: TUNE=1): T4 -> tcp_rmem max = tier rmem_max (32MiB)" 'grep -qP "^net.ipv4.tcp_rmem\t4096 131072 33554432\t" "$OUT/plan.t4" && grep -qP "^net.ipv4.tcp_wmem\t4096 16384 33554432\t" "$OUT/plan.t4"'
t "T1: rmem/wmem_max = 8MiB (v1.1.7: quic-go/Hysteria2 просит 7MiB; было 4MiB)" 'grep -qP "^net.core.rmem_max\t8388608\t" "$OUT/plan.t1" && grep -qP "^net.core.wmem_max\t8388608\t" "$OUT/plan.t1"'
t "база (v1.1.7): slow_start_after_idle=0 и mtu_probing=1 без perf-tier" 'grep -qP "^net.ipv4.tcp_slow_start_after_idle\t0\t" "$OUT/plan.t1" && grep -qP "^net.ipv4.tcp_mtu_probing\t1\t" "$OUT/plan.t1"'
t "ENABLE_TCP_BUF_TUNE=0: slow_start/mtu_probing всё равно в базе" 'grep -q tcp_slow_start_after_idle "$OUT/plan.off"'
printf 'ENABLE_TCP_BUF_TUNE=1\nNET_RMEM_MAX=4194304\nNET_WMEM_MAX=4194304\n' > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem1g";  node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.low" )
t "opt: потолок 4MiB (< дефолта ядра 6/4MiB) — tcp_rmem/wmem НЕ понижаем"  '! grep -q "tcp_[rw]mem" "$OUT/plan.low"'
# 2026-09-24 (v1.1.7): повторный apply — runtime уже = значение node (32MiB); база в реестре
# 6/4 MiB -> tcp_rmem/wmem остаются в плане (раньше выпадали и откатывались: флип-флоп)
: > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem16g"; mkdir -p "$NODE_STATE_DIR"
  printf 'net.ipv4.tcp_rmem\t4096 131072 6291456\nnet.ipv4.tcp_wmem\t4096 16384 4194304\n' > "$NODE_STATE_DIR/sysctl-orig.tsv"
  sysctl() { case "$*" in *tcp_rmem*|*tcp_wmem*) echo "4096 131072 33554432" ;; *) command sysctl "$@" ;; esac; }
  node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.re"; rm -f "$NODE_STATE_DIR/sysctl-orig.tsv" )
t "повторный apply: tcp_rmem/wmem остаются в плане (сравнение с исходным, не с runtime)" 'grep -qP "^net.ipv4.tcp_rmem\t4096 131072 33554432\t" "$OUT/plan.re" && grep -qP "^net.ipv4.tcp_wmem\t4096 16384 33554432\t" "$OUT/plan.re"'

# 2026-09-24 (v1.1.7): порты inbound'ов в добавленной полосе [10240,32767] резервируются
ss() { printf 'tcp LISTEN 0 4096 *:22 *:*\ntcp LISTEN 0 4096 [::]:20443 [::]:*\nudp UNCONN 0 0 0.0.0.0:25000 0.0.0.0:*\ntcp LISTEN 0 4096 *:443 *:*\ntcp LISTEN 0 4096 127.0.0.1:40000 *:*\n'; }
printf 'TCP_RESERVED_PORTS=30000-30010\n' > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem1g"; node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.rp" )
# 2026-09-25 (v1.2.0): UDP-сокет 25000 НЕ резервируется — у Xray это эфемерные сокеты исходящих потоков;
# без контракта shieldnode — только TCP LISTEN (20443) + TCP_RESERVED_PORTS
t "reserved_ports: TCP-слушатель 20443 + TCP_RESERVED_PORTS; UDP 25000, 22/443/40000 — нет" 'grep -qP "^net.ipv4.ip_local_reserved_ports\t20443,30000-30010\t" "$OUT/plan.rp"'
printf 'TCP_PORT_RANGE=32768 60999\n' > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
( export DRY_RUN=1 NODE_PROC_MEMINFO="$OUT/mem1g"; node_sysctl_plan_init; node_tcp_plan >/dev/null 2>&1; cp "$NODE_PLAN_FILE" "$OUT/plan.rp2" )
t "reserved_ports: диапазон не расширен ниже 32768 -> ключ не пишется" '! grep -q ip_local_reserved_ports "$OUT/plan.rp2"'
unset -f ss; : > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
t "opt: остальной план идентичен выключенному"   'diff <(grep -v "tcp_[rw]mem" "$OUT/plan.t4") "$OUT/plan.off"'
cat > "$OUT/bin/ethtool" <<EOF
#!/bin/sh
echo "\$*" >> "$OUT/ethtool.calls"
case "\$1" in --show-eee) echo "EEE settings for \$2:"; echo "	EEE status: enabled - active" ;; esac; exit 0
EOF
chmod +x "$OUT/bin/ethtool"; : > "$OUT/ethtool.calls"; : > "$NODE_RT_TWEAKS"
: > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
node_nic_eee_off >/dev/null 2>&1
t "opt: EEE по умолчанию не трогается"           '! grep -q set-eee "$OUT/ethtool.calls"'
printf 'ENABLE_EEE_OFF=1\n' > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
node_nic_eee_off >/dev/null 2>&1
t "opt: EEE off + orig в реестре"                'grep -qx -- "--set-eee lo eee off" "$OUT/ethtool.calls" && grep -qP "^lo\teee\teee\ton$" "$NODE_RT_TWEAKS"'
t "opt: EEE включает rt boot-unit"               'node_rt_boot_needed'
node_rt_rollback >/dev/null 2>&1
t "opt: rollback EEE -> on"                      'grep -qx -- "--set-eee lo eee on" "$OUT/ethtool.calls"'
: > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1

# ---------- лог-файл создаётся main.sh (реальные пути, root) ----------
if [ "$(id -u)" -eq 0 ] && unshare -m true 2>/dev/null; then
    t "main.sh: создаёт /var/log/node.log (0640) на свежей ноде" \
      "unshare -m bash -c 'for d in /var/log /var/lib /run; do mount -t tmpfs t \$d; done; bash $NODE_DIR/main.sh status >/dev/null 2>&1; [ -s /var/log/node.log ] && [ \"\$(stat -c %a /var/log/node.log)\" = 640 ]'"
else echo "skip - main.sh log creation (root+unshare)"; fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: hardening-0923 (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
