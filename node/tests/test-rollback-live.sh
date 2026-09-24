#!/bin/bash
# node — тест: дефекты node rollback, найденные на живой ноде (2026-09-24, v1.1.5).
# Под root: `unshare -m`, tmpfs поверх /usr/local/sbin, /etc/systemd/system,
# /etc/udev/rules.d, /etc/sysctl.d, /run; sysctl/systemctl — заглушки через PATH.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: unshare -m недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
for d in /usr/local/sbin /etc/systemd/system /etc/udev/rules.d /etc/sysctl.d /run; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
# node_rollback проигрывает rt-реестр (sysfs THP, NIC) по НАСТОЯЩИМ /sys-путям —
# маскируем их (найдено canary-прогоном: без этого тест ставил хосту THP=always)
mount -t tmpfs t /sys/kernel/mm; mount -t tmpfs t /sys/class/net

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-rbl
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state/diagnostics"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diagnostics" NODE_PROFILE_DIR="$OUT/profile.d"
export NODE_LOG="$OUT/node.log" NODE_RT_TWEAKS="$OUT/state/runtime-tweaks.tsv" NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
: > "$NODE_LOG"; : > "$NODE_CONFIG"
for c in logger udevadm tc nft; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
printf '#!/bin/sh\necho "$*" >> %s/systemctl.log\nexit 0\n' "$OUT" > "$OUT/bin/systemctl"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1 || true

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

# --- 1) node_rt_record: iface "-" (sysfs/THP) — дедупликация ---
# grep -qF "-<TAB>sysfs..." без `--` принимал шаблон за опцию -> каждый re-apply
# дописывал строку с ТЕКУЩИМ (уже подкрученным) значением; rollback проигрывал
# реестр по порядку, и последняя строка возвращала подкрученное значение.
: > "$NODE_RT_TWEAKS"
node_rt_record - sysfs kernel/mm/transparent_hugepage/enabled always
node_rt_record - sysfs kernel/mm/transparent_hugepage/enabled madvise   # re-apply: текущее уже madvise
t "rt_record: iface '-' — одна запись, исходное значение (always) сохранено" \
  "[ \$(wc -l < $NODE_RT_TWEAKS) = 1 ] && grep -q \$'\talways\$' $NODE_RT_TWEAKS"

# --- 2) units: disable --now ДО удаления unit-файлов; node-fq-tune тоже ---
# живая нода: после rollback node-rt-tweaks/node-fq-tune — «not-found active exited»,
# висячие симлинки в multi-user.target.wants (файлы удалялись раньше disable)
cat > "$OUT/bin/systemctl" <<SEOF
#!/bin/bash
echo "\$*" >> "$OUT/systemctl.log"
case "\$1" in
  cat) [ -e "/etc/systemd/system/\$2" ] ;;
  disable|enable)
    for u in "\${@:2}"; do case "\$u" in --*) continue ;; esac
      [ -e "/etc/systemd/system/\$u" ] || { echo "MISSING \$u" >> "$OUT/systemctl.log"; exit 1; }; done ;;
esac
SEOF
chmod +x "$OUT/bin/systemctl"; : > "$OUT/systemctl.log"
: > "$NODE_RT_TWEAKS"   # фикстура §1 (THP) не должна проигрываться в §2
: > "$NODE_STATE_DIR/applied-files.txt"; : > "$NODE_STATE_DIR/file-origins.tsv"
for u in node-rt-tweaks.service node-fq-tune.service; do
    echo "[Unit]" > "/etc/systemd/system/$u"
    echo "/etc/systemd/system/$u" >> "$NODE_STATE_DIR/applied-files.txt"
    printf '%s\tcreated\n' "/etc/systemd/system/$u" >> "$NODE_STATE_DIR/file-origins.tsv"
done
( source "$NODE_DIR/persist.sh"; source "$NODE_DIR/rollback.sh"; node_rollback "" ) > /dev/null 2>&1 || true
t "units: disable --now node-rt-tweaks до удаления файла" "grep -qx 'disable --now node-rt-tweaks.service' $OUT/systemctl.log"
t "units: disable --now node-fq-tune (раньше не отключался вовсе)" "grep -qx 'disable --now node-fq-tune.service' $OUT/systemctl.log"
t "units: ни одного disable по отсутствующему файлу" "! grep -q '^MISSING' $OUT/systemctl.log"
t "units: unit-файлы удалены" "[ ! -e /etc/systemd/system/node-rt-tweaks.service ] && [ ! -e /etc/systemd/system/node-fq-tune.service ]"

# --- 3) vm.dirty_*: до node — ratio-режим (bytes=0). Ядро: запись 0 в *_bytes = EINVAL,
# запись *_ratio обнуляет *_bytes и наоборот. Rollback писал bytes=0 (отказ) —
# на живой ноде остались 64M/256M от node.
printf 'vm.dirty_ratio=20\nvm.dirty_background_ratio=10\nvm.dirty_bytes=0\nvm.dirty_background_bytes=0\n' > "$OUT/kv"
cat > "$OUT/bin/sysctl" <<SEOF
#!/bin/bash
KV="$OUT/kv"
get() { awk -F= -v k="\$1" '\$1 == k { print \$2 }' "\$KV"; }
put() { awk -F= -v OFS== -v k="\$1" -v v="\$2" '\$1 == k { \$2 = v } { print }' "\$KV" > "\$KV.n" && mv "\$KV.n" "\$KV"; }
case "\$1" in
  -n) v="\$(get "\$2")"; [ -n "\$v" ] || exit 255; echo "\$v" ;;
  -w) k="\${2%%=*}"; v="\${2#*=}"
      case "\$k" in
        vm.dirty_bytes|vm.dirty_background_bytes)
            [ "\$v" -ge 8192 ] 2>/dev/null || { echo "sysctl: setting key \"\$k\": Invalid argument" >&2; exit 255; }
            put "\$k" "\$v"; put "\${k%_bytes}_ratio" 0 ;;
        vm.dirty_ratio|vm.dirty_background_ratio) put "\$k" "\$v"; put "\${k%_ratio}_bytes" 0 ;;
        *) grep -q "^\$k=" "\$KV" || exit 255; put "\$k" "\$v" ;;
      esac ;;
  *) exit 0 ;;
esac
SEOF
chmod +x "$OUT/bin/sysctl"
rm -f "$NODE_STATE_DIR/sysctl-orig.tsv" "$NODE_STATE_DIR/owner-keys.txt" "$NODE_STATE_DIR/applied-files.txt"
(
    source "$NODE_DIR/lib/sysctl.sh"
    NODE_PLAN_FILE="$OUT/plan"
    printf 'vm.dirty_background_bytes\t67108864\tx\nvm.dirty_bytes\t268435456\tx\n' > "$NODE_PLAN_FILE"
    node_sysctl_orig_record
    sysctl -w vm.dirty_background_bytes=67108864; sysctl -w vm.dirty_bytes=268435456   # «apply»
) > /dev/null 2>&1
t "dirty: после apply — bytes-режим node (фикстура корректна)" "grep -qx vm.dirty_bytes=268435456 $OUT/kv && grep -qx vm.dirty_ratio=0 $OUT/kv"
( source "$NODE_DIR/persist.sh"; source "$NODE_DIR/rollback.sh"; node_rollback "" ) > /dev/null 2>&1 || true
t "dirty rollback: ratio-режим восстановлен (dirty_ratio=20, dirty_bytes=0)" "grep -qx vm.dirty_ratio=20 $OUT/kv && grep -qx vm.dirty_bytes=0 $OUT/kv"
t "dirty rollback: background ratio восстановлен (10, bytes=0)" "grep -qx vm.dirty_background_ratio=10 $OUT/kv && grep -qx vm.dirty_background_bytes=0 $OUT/kv"

# --- 4) 2026-09-24 (v1.1.7): ключи, которые node владел на прошлом apply, но больше не
# планирует, получают исходное (до node) runtime-значение из реестра — иначе удалённая
# из плана настройка (fs.file-max, disable_ipv6, udp-таймауты conntrack...) жила до reboot
printf 'fs.file-max=2097152\nnet.ipv6.conf.all.disable_ipv6=1\nnet.netfilter.nf_conntrack_udp_timeout=180\nnet.core.somaxconn=65535\n' >> "$OUT/kv"
printf 'fs.file-max\t9223372036854775807\nnet.ipv6.conf.all.disable_ipv6\t0\nnet.netfilter.nf_conntrack_udp_timeout\t30\nnet.core.somaxconn\t4096\n' > "$NODE_STATE_DIR/sysctl-orig.tsv"
printf 'fs.file-max\nnet.ipv6.conf.all.disable_ipv6\nnet.netfilter.nf_conntrack_udp_timeout\nnet.core.somaxconn\n' > "$NODE_STATE_DIR/owner-keys.txt"
(
    source "$NODE_DIR/lib/sysctl.sh"
    NODE_PLAN_FILE="$OUT/plan"; printf 'net.core.somaxconn\t65535\t/etc/sysctl.d/99-z0-node-base.conf\n' > "$NODE_PLAN_FILE"
    node_sysctl_restore_dropped
) > /dev/null 2>&1 || true
t "выпавшие из плана ключи -> исходные: file-max, disable_ipv6, udp_timeout" \
  "grep -qx fs.file-max=9223372036854775807 $OUT/kv && grep -qx net.ipv6.conf.all.disable_ipv6=0 $OUT/kv && grep -qx net.netfilter.nf_conntrack_udp_timeout=30 $OUT/kv"
t "ключ, оставшийся в плане, не трогается (somaxconn=65535)" "grep -qx net.core.somaxconn=65535 $OUT/kv"
printf 'net.ipv4.ip_local_reserved_ports=20443\n' >> "$OUT/kv"
printf 'net.ipv4.ip_local_reserved_ports\t\n' >> "$NODE_STATE_DIR/sysctl-orig.tsv"; echo net.ipv4.ip_local_reserved_ports >> "$NODE_STATE_DIR/owner-keys.txt"
( source "$NODE_DIR/lib/sysctl.sh"; NODE_PLAN_FILE="$OUT/plan"; node_sysctl_restore_dropped ) > /dev/null 2>&1 || true
t "v1.1.7: пустое исходное (ip_local_reserved_ports) тоже возвращается" "grep -qx 'net.ipv4.ip_local_reserved_ports=' $OUT/kv"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rollback-live (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
