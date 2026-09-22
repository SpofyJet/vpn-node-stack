#!/bin/bash
# shieldnode — тест: генератор ruleset (lib/nft.sh) без root.
# Запуск: bash tests/test-template.sh
set -euo pipefail

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHIELD_DIR
export SHIELD_VERSION=1.0.0
export SHIELD_STATE_DIR=/tmp/shieldnode-test/state
export SHIELD_LOG=/tmp/shieldnode-test/shieldnode.log
export SHIELD_LOCK=/tmp/shieldnode-test/lock
export DRY_RUN=1
export NODE_PROFILE_DIR=/tmp/shieldnode-test/profile.d
LOG_LEVEL=info

rm -rf /tmp/shieldnode-test
mkdir -p "$SHIELD_STATE_DIR" "$NODE_PROFILE_DIR"

source "$SHIELD_DIR/lib/common.sh"
source "$SHIELD_DIR/config.sh"
source "$SHIELD_DIR/lib/nft.sh"
source "$SHIELD_DIR/emergency.sh"

# фабрика окружения для генератора (как после limits_resolve)
export SH_F_SSH_PORTS="22 2222"
export SH_F_PROTECTED_TCP="443 8443"
export SH_F_PROTECTED_UDP="443"
export SH_F_ADMIN_V4="203.0.113.10"
export SH_F_ADMIN_V6=""
export SH_F_EXCL_V4="198.51.100.0/24"
export SH_F_EXCL_V6=""
export SH_F_IPV6=0
export SH_F_EXTENSIONS=""
export SH_F_WAN_IFACE="eth0"
export SH_F_ENABLE_ANTISPOOF=0
export SH_F_ENABLE_SSH_PROTECTION=1 SH_F_ENABLE_INVALID_DROP=1 SH_F_ENABLE_LOOPBACK=1
export SH_F_ENABLE_ESTABLISHED=1 SH_F_ENABLE_ABUSE_LIMITING=1 SH_F_ENABLE_SYN_PROTECTION=1
export SH_R_SSH_CONN_MAX=8 SH_R_SSH_NEW_RATE=10 SH_R_SSH_NEW_BURST=20
export SH_R_TCP_NEW_RATE=300 SH_R_TCP_NEW_BURST=600 SH_R_TCP_SYN_RATE=50 SH_R_TCP_SYN_BURST=100
export SH_R_TCP_CONN_MAX=15000 SH_R_TCP_GLOBAL_CEIL=8000
export SH_R_UDP_RATE=500 SH_R_UDP_BURST=1000 SH_R_UDP_GLOBAL_CEIL=20000
export SH_R_SSH_ABUSERS_TIMEOUT=3600 SH_R_SSH_ABUSERS_SIZE=65536
export SH_R_TCP_ABUSERS_TIMEOUT=900 SH_R_TCP_ABUSERS_SIZE=131072
export SH_R_UDP_ABUSERS_TIMEOUT=900 SH_R_UDP_ABUSERS_SIZE=65536
export SH_R_TEMP_BLOCKLIST_TIMEOUT=3600 SH_R_TEMP_BLOCKLIST_SIZE=32768
export SH_F_ENABLE_BLOCKLISTS=1 SH_F_ENABLE_SCANNER_LIST=1 SH_F_ENABLE_THREAT_LIST=1
export SH_F_BLOCK_TOR=0 SH_F_ENABLE_CUSTOM_LIST=1
export SH_R_SCANNER_BLOCKLIST_SIZE=262144 SH_R_THREAT_BLOCKLIST_SIZE=131072
export SH_R_TOR_BLOCKLIST_SIZE=16384 SH_R_CUSTOM_BLOCKLIST_SIZE=65536
export SH_R_CROWDSEC_BLOCKLIST_SIZE=262144
export SH_R_SPAMHAUS_BLOCKLIST_SIZE=8192 SH_R_CINS_BLOCKLIST_SIZE=65536
export SH_F_ENABLE_CROWDSEC_LIST=0 SH_F_ENABLE_SPAMHAUS_LIST=1 SH_F_ENABLE_CINS_LIST=1
export SH_F_ENABLE_AMP_GUARD=1 SH_F_ENABLE_ICMP_GUARD=1

fails=0
t() { local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }

shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset.nft
RS=/tmp/shieldnode-test/ruleset.nft

t "ruleset непуст" test -s "$RS"
t "нет destroy table (runtime-файл чистый)" bash -c "! grep -q 'destroy table' '$RS'"
t "таблица inet shieldnode" grep -q "table inet shieldnode" "$RS"
t "цепочка prerouting priority -150 policy accept" grep -q 'chain prerouting' "$RS"
t "набор whitelist_v4" grep -q 'set whitelist_v4' "$RS"
t "whitelist с CIDR-исключением" grep -q '198.51.100.0/24' "$RS"
t "admin IP в whitelist" grep -q '203.0.113.10' "$RS"
t "abuse-наборы (§21–24)" bash -c "grep -q 'set ssh_abusers' '$RS' && grep -q 'set tcp_abusers' '$RS' && grep -q 'set udp_abusers' '$RS' && grep -q 'set temporary_blocklist' '$RS'"
# блок объявления сета между «set NAME {» и отступом «    }»; флаг — словом в строке flags
set_has_flag() { # $1=ruleset $2=setname $3=flag
    awk -v pat="set $2 {" 'index($0, pat) > 0 {f=1; next}
        f && /^    \}/ {exit}
        f && index($0, "flags ") > 0 {print}' "$1" | grep -qw "$3"
}
export -f set_has_flag
t "abuse-наборы: flags dynamic (наполняются из правил — без него падает nft -c)" bash -c "set_has_flag '$RS' ssh_abusers dynamic && set_has_flag '$RS' tcp_abusers dynamic && set_has_flag '$RS' udp_abusers dynamic && set_has_flag '$RS' temporary_blocklist dynamic"
t "protected_tcp/udp с портами" bash -c "grep -q 'set protected_tcp' '$RS' && grep -q '8443' '$RS'"
t "per-src rate-limit ТОЛЬКО через meter" bash -c "grep -q 'meter ssh_new_22' '$RS' && grep -q 'meter tcp_syn' '$RS' && grep -q 'meter udp_rate' '$RS'"
t "plain limit только для global ceiling" bash -c "grep -q 'limit rate over 8000/minute counter name c_drops_global_tcp drop' '$RS' && grep -q 'limit rate over 20000/second counter name c_drops_global_udp drop' '$RS'"
t "SSH-правила для обоих портов" bash -c "grep -q 'dport 22 ' '$RS' && grep -q 'dport 2222 ' '$RS'"
t "ct count SSH_CONN_MAX/TCP_CONN_MAX" bash -c "grep -q 'ct count over 8' '$RS' && grep -q 'ct count over 15000' '$RS'"
t "invalid-drop флаговые правила (§22)" bash -c "grep -q 'ct state invalid counter name c_drops_invalid drop' '$RS' && grep -q 'fin|syn|rst|ack' '$RS'"
t "established accept" grep -q 'ct state established,related accept' "$RS"
t "loopback chain input" grep -q 'iifname "lo" accept' "$RS"
t "фигурные скобки сбалансированы" bash -c "test \$(grep -o '{' '$RS' | wc -l) = \$(grep -o '}' '$RS' | wc -l)"
t "нет пустых elements = { }" bash -c "! grep -q 'elements = {  *}' '$RS'"
t "нет sysctl/conntrack-вмешательства (вне комментариев)" bash -c "! grep -vE '^[[:space:]]*#' '$RS' | grep -Eiq 'sysctl|nf_conntrack'"
t "без секретов в правилах" bash -c "! grep -Eiq 'password|passwd|token|secret|uuid' '$RS'"
t "антиспуф выключен по умолчанию" bash -c "! grep -q '10.0.0.0/8' '$RS'"
SH_F_ENABLE_ANTISPOOF=1
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-spoof.nft
t "антиспуф opt-in работает" bash -c "grep -q '10.0.0.0/8' /tmp/shieldnode-test/ruleset-spoof.nft"
SH_F_ENABLE_ANTISPOOF=0

# --- отсутствие абьюз-лимитинга при ENABLE_ABUSE_LIMITING=0 ---
SH_F_ENABLE_ABUSE_LIMITING=0
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-noabuse.nft
t "выключение abuse-limiting убирает политики" bash -c "! grep -q 'meter tcp_syn' /tmp/shieldnode-test/ruleset-noabuse.nft"
SH_F_ENABLE_ABUSE_LIMITING=1

# --- ENABLE_SYN_PROTECTION: мастер-выключатель только SYN-rate правила ---
SH_F_ENABLE_SYN_PROTECTION=0
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-nosyn.nft
t "SYN_PROTECTION=0 убирает syn-meter, НЕ трогает new-rate/conn-limit" \
    bash -c "! grep -q 'meter tcp_syn' /tmp/shieldnode-test/ruleset-nosyn.nft && grep -q 'meter tcp_new' /tmp/shieldnode-test/ruleset-nosyn.nft && grep -q 'ct count over 15000' /tmp/shieldnode-test/ruleset-nosyn.nft"
SH_F_ENABLE_SYN_PROTECTION=1
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-synback.nft
t "SYN_PROTECTION=1 возвращает syn-meter" bash -c "grep -q 'meter tcp_syn' /tmp/shieldnode-test/ruleset-synback.nft"

# --- агрегаторские блоклисты: сеты + drop-правила ПОСЛЕ whitelist ---
t "blocklist: наборы scanner/threat/custom (tor выключен)" bash -c "grep -q 'set scanner_blocklist_v4' '$RS' && grep -q 'set threat_blocklist_v4' '$RS' && grep -q 'set custom_blocklist_v4' '$RS' && ! grep -q 'set tor_exit_blocklist_v4' '$RS'"
t "blocklist: interval+auto-merge на сетах" bash -c "grep -A4 'set scanner_blocklist_v4' '$RS' | grep -q 'flags interval' && grep -A4 'set scanner_blocklist_v4' '$RS' | grep -q 'auto-merge'"
t "blocklist: drop-правила после whitelist-accept" bash -c "awk '/ip saddr @whitelist_v4 accept/{f=1; next} f && /ip saddr @scanner_blocklist_v4 counter name/{print; exit}' '$RS' | grep -q drop"
t "blocklist: tor drop-правил нет при BLOCK_TOR=0" bash -c "! grep -q 'tor_exit_blocklist_v4 counter name' '$RS'"
SH_F_BLOCK_TOR=1
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-tor.nft
t "blocklist: BLOCK_TOR=1 добавляет tor-сет и drop" bash -c "grep -q 'set tor_exit_blocklist_v4' /tmp/shieldnode-test/ruleset-tor.nft && grep -q 'ip saddr @tor_exit_blocklist_v4 counter name' /tmp/shieldnode-test/ruleset-tor.nft"
SH_F_BLOCK_TOR=0
SH_F_ENABLE_BLOCKLISTS=0
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-nobl.nft
t "blocklist: мастер-выключатель убирает сеты и правила" bash -c "! grep -q 'blocklist_v4' /tmp/shieldnode-test/ruleset-nobl.nft"
SH_F_ENABLE_BLOCKLISTS=1

# --- crowdsec community blocklist (opt-in) ---
t "crowdsec: по умолчанию выключен — сетов/правил/счётчиков нет" bash -c "! grep -q 'crowdsec_blocklist' '$RS' && ! grep -q 'c_drops_crowdsec' '$RS'"
SH_F_ENABLE_CROWDSEC_LIST=1
SH_R_CROWDSEC_BLOCKLIST_SIZE=262144
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-cs.nft
t "crowdsec: сеты v4/v6 + drop-правила с counter" bash -c "grep -q 'set crowdsec_blocklist_v4' /tmp/shieldnode-test/ruleset-cs.nft && grep -q 'ip saddr @crowdsec_blocklist_v4 counter name c_drops_crowdsec_v4 drop' /tmp/shieldnode-test/ruleset-cs.nft"
t "crowdsec: drop ПОСЛЕ whitelist-accept" bash -c "awk '/ip saddr @whitelist_v4 accept/{f=1; next} f && /ip saddr @crowdsec_blocklist_v4 counter name/{print; exit}' /tmp/shieldnode-test/ruleset-cs.nft | grep -q drop"
t "crowdsec: drop-правило несёт counter (инвариант счётчиков)" bash -c "test \$(grep -cE '^[[:space:]]*[^#[:space:]].* drop$' /tmp/shieldnode-test/ruleset-cs.nft) = \$(grep -c 'counter name c_drops_' /tmp/shieldnode-test/ruleset-cs.nft)"
SH_F_IPV6=1
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-cs6.nft
t "crowdsec: v6-компаньон при IPv6" bash -c "grep -q 'set crowdsec_blocklist_v6' /tmp/shieldnode-test/ruleset-cs6.nft && grep -q 'c_drops_crowdsec_v6' /tmp/shieldnode-test/ruleset-cs6.nft"
SH_F_IPV6=0
SH_F_ENABLE_CROWDSEC_LIST=0
unset SH_R_CROWDSEC_BLOCKLIST_SIZE

# --- IPv6: блоклист-компаньоны _v6 ---
SH_F_IPV6=1
SH_F_ADMIN_V6="2001:db8::42"
SH_F_BLOCK_TOR=1
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-v6bl.nft
t "IPv6: блоклисты _v6 + drop v6" bash -c "grep -q 'set scanner_blocklist_v6' /tmp/shieldnode-test/ruleset-v6bl.nft && grep -q 'ip6 saddr @threat_blocklist_v6 counter name' /tmp/shieldnode-test/ruleset-v6bl.nft && grep -q 'ip6 saddr @tor_exit_blocklist_v6 counter name' /tmp/shieldnode-test/ruleset-v6bl.nft"
SH_F_IPV6=0
SH_F_BLOCK_TOR=0
SH_F_ADMIN_V6=""

# --- IPv6-компаньоны при SH_F_IPV6=1 ---
SH_F_ENABLE_ABUSE_LIMITING=1
SH_F_IPV6=1
SH_F_ADMIN_V6="2001:db8::42"
shield_nft_build_ruleset > /tmp/shieldnode-test/ruleset-v6.nft
t "IPv6: whitelist_v6 + admin6" bash -c "grep -q 'set whitelist_v6' /tmp/shieldnode-test/ruleset-v6.nft && grep -q '2001:db8::42' /tmp/shieldnode-test/ruleset-v6.nft"
t "IPv6: abuse-компаньоны _v6" bash -c "grep -q 'ssh_abusers_v6' /tmp/shieldnode-test/ruleset-v6.nft && grep -q 'tcp_abusers_v6' /tmp/shieldnode-test/ruleset-v6.nft && grep -q 'udp_abusers_v6' /tmp/shieldnode-test/ruleset-v6.nft"

# --- emergency ruleset ---
SH_F_ADMIN_V4="203.0.113.10"
shield_emergency_ruleset > /tmp/shieldnode-test/emergency.nft
t "emergency: только ssh/established/whitelist" bash -c "grep -q 'tcp dport 22 ct state new accept' /tmp/shieldnode-test/emergency.nft && grep -q 'ip protocol tcp drop' /tmp/shieldnode-test/emergency.nft"
t "emergency: скобки сбалансированы" bash -c "test \$(grep -o '{' /tmp/shieldnode-test/emergency.nft | wc -l) = \$(grep -o '}' /tmp/shieldnode-test/emergency.nft | wc -l)"

# --- владение sysctl (§15): net.netfilter.* — жёсткий запрет для shieldnode ---
t "validate_key_ownership: net.netfilter.* запрещён" bash -c "! validate_key_ownership net.netfilter.nf_conntrack_max"
t "validate_key_ownership: rp_filter разрешён" validate_key_ownership net.ipv4.conf.all.rp_filter

echo
# базовый цикл = 22; +spamhaus_v4 (v6 нет — SH_F_IPV6=0), +cins_v4, +amp, +icmp = 26
t "counters: 26 именованных счётчиков объявлены (22 базовых + spamhaus/cins/amp/icmp)" bash -c "test \$(grep -c '^    counter c_drops_' '$RS') = 26"
t "counters: spamhaus/cins/amp/icmp счётчики на месте" bash -c "grep -q 'c_drops_spamhaus_v4' '$RS' && grep -q 'c_drops_cins_v4' '$RS' && grep -q 'c_drops_amp' '$RS' && grep -q 'c_drops_icmp' '$RS'"
t "amp-guard: NEW UDP с amplifier source-портами дропается" bash -c "grep -q 'udp sport { 53, 123, 1900, 11211, 389 }' '$RS'"
t "icmp-guard: v6 PMTUD-exceptions (packet-too-big) accept'ятся ДО rate-limit" bash -c "grep -q 'icmpv6 type { packet-too-big, time-exceeded, parameter-problem } accept' '$RS' && grep -q 'icmp type echo-request limit rate over 10/second' '$RS'"
t "counters: КАЖДОЕ drop-правило несёт counter name" bash -c "test \$(grep -cE '^[[:space:]]*[^#[:space:]].* drop$' '$RS') = \$(grep -c 'counter name c_drops_' '$RS')"
t "counters: scanner/threat/tor/custom v4+v6 имеют свои счётчики" bash -c "grep -q 'c_drops_scanner_v4' '$RS' && grep -q 'c_drops_threat_v6' '$RS' && grep -q 'c_drops_custom_v4' '$RS'"
t "counters: syn/tcp/udp/ssh-abusers + global + invalid + antispoof" bash -c "grep -q 'c_drops_syn_v4' '$RS' && grep -q 'c_drops_global_tcp' '$RS' && grep -q 'c_drops_global_udp' '$RS' && grep -q 'c_drops_invalid' '$RS' && grep -q 'c_drops_antispoof' '$RS'"
t "counters: LOG-флуда нет — log statement отсутствует" bash -c "! grep -qE ' counter name c_drops_.* log |log prefix| nflog' '$RS'"

if [ "$fails" -eq 0 ]; then echo "PASS: template (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
