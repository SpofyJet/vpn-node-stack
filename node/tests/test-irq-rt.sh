#!/bin/bash
# node — тест: (1) обнаружение IRQ NIC (virtio/msi_irqs/PCI/legacy),
# (2) node-rt-tweaks boot-unit: эмитится при включённых твиках, удаляется при выключенных.
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DIR
export NODE_STATE_DIR=/tmp/node-irt-test/state
export NODE_DIAG_DIR="$NODE_STATE_DIR/diagnostics"
export NODE_LOG=/tmp/node-irt-test/node.log
export NODE_PROFILE_DIR=/tmp/node-irt-test/profile.d
export NODE_RT_TWEAKS="$NODE_STATE_DIR/runtime-tweaks.tsv"
LOG_LEVEL=error
rm -rf /tmp/node-irt-test
mkdir -p "$NODE_STATE_DIR" "$NODE_PROFILE_DIR" "$NODE_DIAG_DIR"
touch "$NODE_LOG"

source "$NODE_DIR/lib/common.sh"
source "$NODE_DIR/config.sh"
node_load_config >/dev/null 2>&1 || true

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# ---------- фикстуры sysfs/proc ----------
FX=/tmp/node-irt-test/fixtures
mkdir -p "$FX/sys/class/net/eth0/device/msi_irqs" "$FX/sys/class/net/eth0/queues"
for i in 24 25 26 27; do : > "$FX/sys/class/net/eth0/device/msi_irqs/$i"; done
# virtio-стиль /proc/interrupts: метки НЕ содержат имя интерфейса
cat > "$FX/interrupts" <<'PIEOF'
            CPU0       CPU1
   1:      12345      12340   IO-APIC    1-edge      i8042
  24:     908172      12340   PCI-MSI 524288-edge    virtio0-input.0
  25:     908171        234   PCI-MSI 524289-edge    virtio0-output.0
  26:         12        567   PCI-MSI 524290-edge    virtio0-output.1
  27:      12340     908173   PCI-MSI 524291-edge    virtio0-config
PIEOF

source "$NODE_DIR/lib/irq.sh"

# msi_irqs приоритет: вернутся ровно 24-27 даже при «бедном» /proc/interrupts
got="$(NODE_SYS_ROOT="$FX/sys" NODE_PROC_ROOT="$FX" node_nic_irq_candidates eth0 | tr '\n' ' ')"
[ "$got" = "24 25 26 27 " ] || { echo "FAIL - msi_irqs: '$got'"; fails=$((fails+1)); }
[ "$got" = "24 25 26 27 " ] && echo "ok   - msi_irqs приоритет (virtio: имени iface в /proc/interrupts нет)"

# fallback PCI: убираем msi_irqs, PCI-адрес устройства = 0000:00:03.0 — метки его не содержат,
# legacy-имени нет -> ожидаем пусто (не падает, exit 0)
rm -rf "$FX/sys/class/net/eth0/device/msi_irqs"
got="$(NODE_SYS_ROOT="$FX/sys" NODE_PROC_ROOT="$FX" node_nic_irq_candidates eth0 | tr '\n' ' ')"
[ -z "$got" ] && echo "ok   - fallback без msi/pci/legacy: пусто, без ошибки" || { echo "FAIL - fallback: '$got'"; fails=$((fails+1)); }

# legacy: метка содержит имя интерфейса
mkdir -p "$FX/sys/class/net/eth1/device"
cat > "$FX/interrupts" <<'PIEOF'
            CPU0
  40:      99999   PCI-MSI 1048576-edge      eth1-Tx-Rx-0
  41:      99998   PCI-MSI 1048577-edge      eth1-Tx-Rx-1
PIEOF
got="$(NODE_SYS_ROOT="$FX/sys" NODE_PROC_ROOT="$FX" node_nic_irq_candidates eth1 | tr '\n' ' ')"
[ "$got" = "40 41 " ] && echo "ok   - legacy: метки eth1-Tx-Rx -> 40 41" || { echo "FAIL - legacy: '$got'"; fails=$((fails+1)); }

# ---------- rt boot unit ----------
source "$NODE_DIR/apply.sh"
node_persist_stream() { local dst="$1"; mkdir -p "/tmp/node-irt-test/out$(dirname "$dst")"; cat > "/tmp/node-irt-test/out$dst"; }
SYSTEMCTL_LOG=/tmp/node-irt-test/systemctl.log; : > "$SYSTEMCTL_LOG"
systemctl() { echo "$*" >> "$SYSTEMCTL_LOG"; return 0; }

# включён FQ_TUNE (default 1) -> unit эмитится с правильным путём
node_rt_boot_persist
t "rt-unit: создан" 'test -f /tmp/node-irt-test/out/etc/systemd/system/node-rt-tweaks.service'
t "rt-unit: ExecStart указывает на wrapper" 'grep -q "node-rt-tweaks.sh" /tmp/node-irt-test/out/etc/systemd/system/node-rt-tweaks.service'
t "rt-unit: wrapper вызывает rt-reapply из NODE_DIR" 'grep -q "cd '"'"$NODE_DIR"'"' && exec bash install.sh rt-reapply" /tmp/node-irt-test/out/usr/local/sbin/node-rt-tweaks.sh'
t "rt-unit: systemctl enable вызван" 'grep -q "enable node-rt-tweaks.service" /tmp/node-irt-test/systemctl.log'

# выключаем все твики (defaults конфигурируем через CONFIG_CACHE: first-match wins)
printf 'ENABLE_FQ_TUNE=0\n' > /tmp/node-irt-test/node.conf
export NODE_CONFIG=/tmp/node-irt-test/node.conf
node_load_config >/dev/null 2>&1 || true
# перенаправляем пути unit'а под sandbox: persist-stub пишет в $OUT
export NODE_RT_UNIT=/etc/systemd/system/node-rt-tweaks.service
node_rt_boot_persist   # создать через stub (в $OUT)
: > "$SYSTEMCTL_LOG"
node_rt_boot_persist
t "rt-unit: disable вызван при удалении" 'grep -q "disable" /tmp/node-irt-test/systemctl.log'
t "rt-unit: факт удаления залогирован" 'grep -q "node-rt-tweaks.service удалён" /tmp/node-irt-test/node.log'

# logrotate emission
node_logrotate_persist
t "logrotate: /etc/logrotate.d/node создан" 'test -f /tmp/node-irt-test/out/etc/logrotate.d/node'
t "logrotate: copytruncate + size" 'grep -q "copytruncate" /tmp/node-irt-test/out/etc/logrotate.d/node && grep -q "size 10M" /tmp/node-irt-test/out/etc/logrotate.d/node'

# ---------- udev hotplug rule ----------
# node_rt_boot_persist уже вызван выше (FQ_TUNE=1) — правило должно было эмититься
t "udev: hotplug rule создано" 'test -f /tmp/node-irt-test/out/etc/udev/rules.d/99-node-rt-hotplug.rules'
t "udev: ловит add net и триггерит unit" 'grep -q "ACTION==\"add\"" /tmp/node-irt-test/out/etc/udev/rules.d/99-node-rt-hotplug.rules && grep -q "SUBSYSTEM==\"net\"" /tmp/node-irt-test/out/etc/udev/rules.d/99-node-rt-hotplug.rules && grep -q "node-rt-tweaks.service" /tmp/node-irt-test/out/etc/udev/rules.d/99-node-rt-hotplug.rules'
t "udev: restart для уже-активного unit" 'grep -q "systemctl restart node-rt-tweaks.service" /tmp/node-irt-test/out/etc/udev/rules.d/99-node-rt-hotplug.rules'

# ---------- sysctl имена 99-zN ----------
t "sysctl: 5 файлов 99-z0..z4 (не 80-84)" 'grep -q "99-z0-node-base.conf" "$NODE_DIR/lib/sysctl.sh" && grep -q "99-z4-node-vm.conf" "$NODE_DIR/lib/sysctl.sh" && ! grep -qE "/etc/sysctl.d/8[0-4]-" "$NODE_DIR/lib/sysctl.sh"'
t "sysctl: rollback glob обновлён" 'grep -q "99-z\[01234\]-node" "$NODE_DIR/rollback.sh"'

# ---------- conntrack RAM clamp ----------
# узкая фикстура: 1GB RAM -> кап ≈ 838860 с лишним; CONNTRACK_MAX=1048576 должен ужаться
cat > /tmp/node-irt-test/meminfo <<'MIEOF'
MemTotal:        1048576 kB
MemFree:          524288 kB
MIEOF
source "$NODE_DIR/lib/sysctl.sh"; node_sysctl_plan_init
source "$NODE_DIR/lib/conntrack.sh"
printf 'CONNTRACK_MAX=1048576\n' >> /tmp/node-irt-test/node.conf
node_load_config >/dev/null 2>&1 || true
NODE_PROC_MEMINFO=/tmp/node-irt-test/meminfo node_conntrack_plan >/dev/null 2>&1 || true
cap=$(( 1024 * 1024 * 1024 / 4 / 320 ))
t "conntrack: RAM clamp применён (NODE_CONNTRACK_MAX <= $cap)" "[ \"${NODE_CONNTRACK_MAX:-0}\" -le \"$cap\" ] && [ \"${NODE_CONNTRACK_MAX:-0}\" -gt 0 ]"
# без override 1048576 стоит ровно
printf 'CONNTRACK_MAX=1048576\n' > /tmp/node-irt-test/node.conf
node_load_config >/dev/null 2>&1 || true
NODE_PROC_MEMINFO=/proc/meminfo node_conntrack_plan >/dev/null 2>&1 || true
t "conntrack: на реальной RAM clamp не трогает адекватный max" '[ "${NODE_CONNTRACK_MAX:-0}" = 1048576 ]'

# ---------- conntrack тиры старого стека (MB-пороги, fix: заниженный max) ----------
# ≤1.2GB→262144, ≤2.5GB→786432, ≤8.5GB→1048576, >8.5GB→2097152
: > /tmp/node-irt-test/node.conf   # снимаем override CONNTRACK_MAX
node_load_config >/dev/null 2>&1 || true
printf 'MemTotal:        1048576 kB\n' > /tmp/node-irt-test/meminfo
NODE_PROC_MEMINFO=/tmp/node-irt-test/meminfo node_conntrack_plan >/dev/null 2>&1 || true
t "conntrack tier: 1GB -> 262144 (hashsize max/4)" '[ "${NODE_CONNTRACK_MAX:-0}" = 262144 ] && [ "${NODE_CONNTRACK_HASHSIZE:-0}" = 65536 ]'
printf 'MemTotal:        2097152 kB\n' > /tmp/node-irt-test/meminfo
NODE_PROC_MEMINFO=/tmp/node-irt-test/meminfo node_conntrack_plan >/dev/null 2>&1 || true
t "conntrack tier: 2GB -> 786432" '[ "${NODE_CONNTRACK_MAX:-0}" = 786432 ]'
printf 'MemTotal:        8388608 kB\n' > /tmp/node-irt-test/meminfo
NODE_PROC_MEMINFO=/tmp/node-irt-test/meminfo node_conntrack_plan >/dev/null 2>&1 || true
t "conntrack tier: 8GB -> 1048576" '[ "${NODE_CONNTRACK_MAX:-0}" = 1048576 ]'
printf 'MemTotal:        16777216 kB\n' > /tmp/node-irt-test/meminfo
NODE_PROC_MEMINFO=/tmp/node-irt-test/meminfo node_conntrack_plan >/dev/null 2>&1 || true
t "conntrack tier: 16GB -> 2097152" '[ "${NODE_CONNTRACK_MAX:-0}" = 2097152 ]'

# ---------- IRQ mask guard >64 CPU ----------
t "irq: guard 64 бита присутствует (RPS и XPS)" 'grep -q "eff=\$cpus; \[ \"\$eff\" -gt 64 \]" "$NODE_DIR/lib/irq.sh" && [ "$(grep -c "eff=\$cpus" "$NODE_DIR/lib/irq.sh")" -ge 2 ]'

echo
if [ "$fails" -eq 0 ]; then echo "PASS: irq-rt (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
