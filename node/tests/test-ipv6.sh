#!/bin/bash
# node — тест: IPv6 выключен всегда (v1.2.0, DIAGNOSIS P1-4 / прод E6).
# v1.1.7–1.3.0: только sysctl all/default/lo в файле плана; systemd-networkd после reboot
# вернул enp5s0 disable_ipv6=0 и fe80::, rollback возвращал disable_ipv6=0 из реестра.
# Фикстуры: /proc (sys/net/ipv6/conf/*, cmdline), grub.d, networkd, daemon.json — всё под $OUT.
set -euo pipefail
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state" "$OUT/proc/sys/net/ipv6/conf" "$OUT/sysctl.d" "$OUT/grub.d" "$OUT/boot" \
         "$OUT/run-net" "$OUT/etc-net" "$OUT/docker" "$OUT/run"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/log" NODE_PROFILE_DIR="$OUT/profile"
export NODE_IPV6_PROC="$OUT/proc" NODE_IPV6_SYSCTL="$OUT/sysctl.d/99-zz-vpn-ipv6-off.conf" NODE_IPV6_GRUB="$OUT/grub.d/99-vpn-node-ipv6.cfg"
export NODE_IPV6_GRUBCFG="$OUT/boot/grub.cfg" NODE_IPV6_NETWORKD_SRC="$OUT/run-net" NODE_IPV6_NETWORKD_DIR="$OUT/etc-net"
export NODE_IPV6_DOCKER_JSON="$OUT/docker/daemon.json" NODE_IPV6_RUN="$OUT/run"
: > "$OUT/log"
for i in all default lo enp5s0 docker0 eth0.100; do mkdir -p "$OUT/proc/sys/net/ipv6/conf/$i"; echo 0 > "$OUT/proc/sys/net/ipv6/conf/$i/disable_ipv6"; done
echo 1 > "$OUT/proc/sys/net/ipv6/conf/all/disable_ipv6"      # как на лабе: all=1, но enp5s0=0
echo "BOOT_IMAGE=/vmlinuz root=/dev/vda1 ro console=ttyS0" > "$OUT/proc/cmdline"
echo "linux /vmlinuz root=/dev/vda1 ro console=ttyS0" > "$OUT/boot/grub.cfg"
printf '[Match]\nName=enp5s0\n[Network]\nDHCP=ipv4\n' > "$OUT/run-net/10-netplan-enp5s0.network"
printf '[Match]\nName=veth*\n' > "$OUT/run-net/80-container-ve.network"
# update-grub: «генерирует» grub.cfg из cmdline + grub.d
cat > "$OUT/bin/update-grub" <<'EOS'
#!/bin/bash
GRUB_CMDLINE_LINUX="console=ttyS0"
for f in "$(dirname "$NODE_IPV6_GRUB")"/*.cfg; do [ -f "$f" ] && . "$f"; done
echo "linux /vmlinuz root=/dev/vda1 ro $GRUB_CMDLINE_LINUX" > "$NODE_IPV6_GRUBCFG"
echo run >> "$NODE_IPV6_GRUBCFG.runs"
EOS
chmod +x "$OUT/bin/"*; export PATH="$OUT/bin:$PATH"
source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
source "$NODE_DIR/lib/ipv6.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

printf '{\n  "log-driver": "json-file",\n  "ipv6": true\n}\n' > "$NODE_IPV6_DOCKER_JSON"
node_ipv6_enforce >/dev/null 2>&1

v() { cat "$OUT/proc/sys/net/ipv6/conf/$1/disable_ipv6"; }
t "runtime: disable_ipv6=1 на ВСЕХ интерфейсах (enp5s0, docker0, eth0.100, lo, default)" \
  "[ \$(v enp5s0)\$(v docker0)\$(v eth0.100)\$(v lo)\$(v default)\$(v all) = 111111 ]"
t "sysctl-файл: all/default + каждый интерфейс (eth0.100 — через /)" \
  "grep -qx 'net.ipv6.conf.enp5s0.disable_ipv6 = 1' '$NODE_IPV6_SYSCTL' && grep -qx 'net/ipv6/conf/eth0.100/disable_ipv6 = 1' '$NODE_IPV6_SYSCTL' && grep -qx 'net.ipv6.conf.default.disable_ipv6 = 1' '$NODE_IPV6_SYSCTL'"
t "sysctl-файл — после файлов node (99-zz > 99-z4)" "[[ \$(basename '$NODE_IPV6_SYSCTL') > 99-z4-node-vm.conf ]]"
t "GRUB: ipv6.disable=1 в cmdline через grub.d" "grep -q 'ipv6.disable=1' '$OUT/boot/grub.cfg' && grep -q 'GRUB_CMDLINE_LINUX=.*ipv6.disable=1' '$NODE_IPV6_GRUB'"
t "GRUB: прежние параметры cmdline сохранены (console=ttyS0)" "grep -q 'console=ttyS0 ipv6.disable=1' '$OUT/boot/grub.cfg'"
t "reboot: маркер «нужна перезагрузка» (cmdline ещё без ipv6.disable=1)" "test -f '$OUT/run/reboot-required-ipv6' && node_ipv6_reboot_pending"
t "networkd: drop-in LinkLocalAddressing=no для netplan-линка" "grep -qx 'LinkLocalAddressing=no' '$OUT/etc-net/10-netplan-enp5s0.network.d/90-vpn-node-ipv6-off.conf' && grep -qx 'IPv6AcceptRA=no' '$OUT/etc-net/10-netplan-enp5s0.network.d/90-vpn-node-ipv6-off.conf'"
t "networkd: штатный шаблон 80-container-* не тронут" "test ! -e '$OUT/etc-net/80-container-ve.network.d'"
t "docker: ipv6 true -> false, прочие ключи сохранены, бэкап" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d[\"ipv6\"] is False and d[\"log-driver\"]==\"json-file\"))' '$NODE_IPV6_DOCKER_JSON' && test -f '$NODE_IPV6_DOCKER_JSON.pre-vpn-node'"

# идемпотентность: второй прогон ничего не переписывает и update-grub не зовёт
cp "$NODE_IPV6_SYSCTL" "$OUT/s1"; cp "$NODE_IPV6_DOCKER_JSON" "$OUT/d1"; runs1="$(wc -l < "$OUT/boot/grub.cfg.runs")"
node_ipv6_enforce >/dev/null 2>&1
t "повторный прогон: файлы те же, update-grub не вызывался" \
  "cmp -s '$OUT/s1' '$NODE_IPV6_SYSCTL' && cmp -s '$OUT/d1' '$NODE_IPV6_DOCKER_JSON' && [ \$(wc -l < '$OUT/boot/grub.cfg.runs') = $runs1 ]"

# «networkd после reboot вернул 0» (прод E6) — следующий apply снова выключает
echo 0 > "$OUT/proc/sys/net/ipv6/conf/enp5s0/disable_ipv6"
node_ipv6_enforce >/dev/null 2>&1
t "интерфейс снова включился -> apply выключает" "[ \$(v enp5s0) = 1 ]"

# HARDEN_IPV6=0 из старого конфига — игнорируется
printf 'HARDEN_IPV6=0\n' > "$OUT/cfg"; NODE_CONFIG="$OUT/cfg" node_load_config >/dev/null 2>&1
echo 0 > "$OUT/proc/sys/net/ipv6/conf/docker0/disable_ipv6"
node_ipv6_enforce >/dev/null 2>&1
t "HARDEN_IPV6=0 игнорируется (предупреждение, IPv6 выключен)" "[ \$(v docker0) = 1 ] && grep -q 'HARDEN_IPV6=0 игнорируется' '$OUT/log'"

# ядро загружено с ipv6.disable=1: стека нет, маркер снят
echo "BOOT_IMAGE=/vmlinuz ro console=ttyS0 ipv6.disable=1" > "$OUT/proc/cmdline"; rm -rf "$OUT/proc/sys/net/ipv6"
node_ipv6_enforce >/dev/null 2>&1
t "после reboot: ipv6.disable=1 активен, маркер reboot снят" "node_ipv6_kernel_off && ! node_ipv6_reboot_pending && test ! -e '$OUT/run/reboot-required-ipv6'"

# невалидный daemon.json — не трогаем
echo '{ broken' > "$NODE_IPV6_DOCKER_JSON"
node_ipv6_enforce >/dev/null 2>&1
t "docker: невалидный JSON не переписан" "grep -qx '{ broken' '$NODE_IPV6_DOCKER_JSON'"

# инвариант не откатывается: restore_dropped / rollback пропускают disable_ipv6
t "rollback/restore_dropped пропускают disable_ipv6" \
  "grep -q 'net.ipv6.conf.\*.disable_ipv6) continue' '$NODE_DIR/rollback.sh' && grep -q 'net.ipv6.conf.\*.disable_ipv6) continue' '$NODE_DIR/lib/sysctl.sh'"
t "файлы инварианта не в манифесте node (rollback их не удаляет)" "! grep -q 'node_persist' '$NODE_DIR/lib/ipv6.sh'"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: ipv6 (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
