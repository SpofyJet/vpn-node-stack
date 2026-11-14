#!/bin/bash
# shieldnode — тест: ранний фильтр на входе (spofy-guard) под управлением стека — НАСТОЯЩИЙ nft и настоящие
# пакеты. 2026-11-14 (v1.2.11).
# Свой netns + mount ns (`unshare -mn`): «нода» с устройством wan0 и маршрутом по умолчанию, «клиент» во
# втором netns. Стек ставит фильтр полным apply; дальше — по нескольку пакетов на проверку (без флуда):
#   наблюдение  ничего не отбрасывается (UDP на неслушающий порт и SYN на закрытый порт доходят), счётчик
#               «своих» растёт; пока «свои» под отбросом или сервер отвечает с порта вне списков — отброс
#               не включается, причина с числами видна в status;
#   отброс      (а) UDP на неслушающий порт отбрасывается, (б) ответ на свой исходящий проходит, (в) UDP на
#               слушающий порт проходит, (г) ARP и TCP не затронуты; SYN на слушающий порт проходит,
#               SYN на закрытый — отбрасывается; пакет в соединение, которого на сервере нет, на слушающий
#               порт получает ответ «сброс» (а не молчание), на закрытый — молча отбрасывается;
#   усыновление повторный apply не пересоздаёт таблицы и не трогает режим;
#   обновление  скрипт на сервере другой версии: файл заменяется, правила ставятся заново (`reload`) —
#               режим и знакомые адреса прежние, наблюдение заново не начинается;
#   EARLY_FILTER_MODE=observe: отброс не включается, включённый переводится в наблюдение;
#   старый фильтр UDP (spofy-udp-guard): в наблюдении не трогается, при включении отброса снимается,
#               rollback и ENABLE_EARLY_FILTER=0 включают его обратно;
#   emergency on/off, ENABLE_EARLY_FILTER=0, ручная проба, rollback;
#   фильтр, включённый руками мимо стека: при ENABLE_EARLY_FILTER=0 его не трогают ни apply, ни rollback,
#               при =1 apply принимает его как есть (таблица, правило режима, счётчики и файлы — те же).
# systemctl — заглушка, которая ведёт себя как systemd для двух юнитов фильтра: включённый впервые таймер
# сразу зовёт `spofy-guard ensure` (так и на сервере: OnBootSec давно прошёл).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
for c in nft python3 flock ip; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP: нет $c"; exit 77; }; done
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
# дальше — запись в /etc, /usr/local/sbin, /var/lib и свои правила nft: только в своих mount- и net-пространствах
# (переменная SHIELD_TEST_IN_NS, выставленная снаружи руками, не должна пустить тест на настоящий сервер)
for ns in mnt net; do
    if [ "$(readlink "/proc/$$/ns/$ns")" = "$(readlink "/proc/1/ns/$ns" 2>/dev/null || true)" ]; then
        echo "FAIL: тест не в своём пространстве ($ns) — останов, чтобы не тронуть настоящий сервер"; exit 1
    fi
done
for d in /etc/sysctl.d /etc/nftables.d /etc/systemd/system /etc/shieldnode /etc/tmpfiles.d /etc/logrotate.d \
         /etc/node-profile.d /usr/local/sbin /var/lib/shieldnode /var/log /run; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done
# `spofy-guard sysctl on` дописывает строку в /etc/node/node.conf — настоящий файл сервера прячем
if [ -d /etc/node ]; then mount -t tmpfs t /etc/node; fi

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-earlyfilter-realnft
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/active"
export SHIELD_LOCK=/run/shieldnode/shieldnode.lock
# состояние и настройки самого фильтра — под $OUT (каталог /var/lib/spofy-guard настоящего сервера не трогаем)
export GUARD_STATE="$OUT/gstate" GUARD_CONF="$OUT/spofy-guard.conf"
export SHIELD_EF_MIN_PKTS=5          # в тесте — считанные пакеты
export SHIELD_EF_MEASURE_SEC=1       # замер после обучения — не короче секунды
echo 'LEARN=1' > "$GUARD_CONF"
unset SSH_CONNECTION
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nTRUSTED_IPS=10.99.0.77\n' > /etc/shieldnode/config.conf

cat > "$OUT/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$OUT/systemctl.log"
act="$OUT/active"
case "\$1" in
    is-active) u="\${*: -1}"; [ -e "\$act/\$u" ] && exit 0; exit 3 ;;
    enable)
        if [[ " \$* " == *" --now "* ]]; then
            for u in "\$@"; do case "\$u" in *.timer|*.service)
                if [ ! -e "\$act/\$u" ]; then
                    touch "\$act/\$u"
                    if [ "\$u" = spofy-guard.timer ]; then /usr/local/sbin/spofy-guard ensure >> "$OUT/unit.out" 2>&1; fi
                fi ;; esac; done
        fi ;;
    restart) for u in "\$@"; do case "\$u" in *.timer) touch "\$act/\$u" ;; esac; done ;;
    disable|stop) for u in "\$@"; do case "\$u" in *.timer|*.service) rm -f "\$act/\$u" ;; esac; done ;;
    start) if [[ " \$* " == *" spofy-guard.service "* ]]; then /usr/local/sbin/spofy-guard ensure >> "$OUT/unit.out" 2>&1; fi
           for u in "\$@"; do case "\$u" in *.timer) touch "\$act/\$u" ;; esac; done ;;
esac
exit 0
EOF
for c in logger udevadm; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"
: > "$OUT/systemctl.log"; : > "$OUT/unit.out"

cat > "$OUT/h.py" <<'EOF'
import os, socket, sys, time
m, a = sys.argv[1], sys.argv[2:]
def udp(): return socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
if m == "udp-echo":      # <ip> <порт> [файл]: эхо; получив "own", после ответа ждёт файл и шлёт ещё пакет "late"
    s = udp(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((a[0], int(a[1])))
    while True:
        d, peer = s.recvfrom(2048); s.sendto(d, peer)
        if d == b"own" and len(a) > 2:
            for _ in range(200):
                if os.path.exists(a[2]): break
                time.sleep(0.05)
            s.sendto(b"late", peer)
elif m == "udp-ask":     # <адрес> <порт> <свой порт|0> <текст> [ждать второй ответ]
    s = udp()
    if int(a[2]): s.bind(("0.0.0.0", int(a[2])))
    s.settimeout(1.5); s.sendto(a[3].encode(), (a[0], int(a[1])))
    try: print("reply:" + s.recvfrom(2048)[0].decode(), flush=True)
    except socket.timeout: print("timeout", flush=True); sys.exit(0)
    if len(a) > 4:
        s.settimeout(8)
        try: print("reply:" + s.recvfrom(2048)[0].decode(), flush=True)
        except socket.timeout: print("timeout", flush=True)
elif m == "udp-send":    # <адрес> <порт> <текст>
    udp().sendto(a[2].encode(), (a[0], int(a[1])))
elif m == "tcp-serve":   # <ip> <порт>: отвечает "hi:" + полученное
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((a[0], int(a[1]))); s.listen(16)
    while True:
        c, _ = s.accept()
        try:
            c.settimeout(2); c.sendall(b"hi:" + c.recv(1024))
        except OSError: pass
        finally: c.close()
elif m == "tcp-ask":     # <адрес> <порт> <текст> -> ok:<ответ> | refused | timeout
    s = socket.socket(); s.settimeout(1.5)
    try:
        s.connect((a[0], int(a[1]))); s.sendall(a[2].encode()); print("ok:" + s.recv(1024).decode())
    except ConnectionRefusedError: print("refused")
    except (socket.timeout, TimeoutError): print("timeout")
    except OSError as e: print("error:" + str(e))
elif m == "tcp-stale":   # <свой адрес> <адрес> <порт>: ACK в соединение, которого нет -> rst | silence
    import struct
    src, dst, dport, sport = a[0], a[1], int(a[2]), 40777
    r = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP); r.settimeout(1.5)
    def csum(b):
        if len(b) % 2: b += b"\0"
        t = sum(struct.unpack("!%dH" % (len(b) // 2), b)); t = (t >> 16) + (t & 0xffff); t += t >> 16
        return ~t & 0xffff
    tcp = struct.pack("!HHLLBBHHH", sport, dport, 1000, 2000, 5 << 4, 0x10, 1024, 0, 0)
    ph = socket.inet_aton(src) + socket.inet_aton(dst) + struct.pack("!BBH", 0, 6, len(tcp))
    r.sendto(tcp[:16] + struct.pack("!H", csum(ph + tcp)) + tcp[18:], (dst, 0))
    try:
        while True:
            p = r.recv(256); ihl = (p[0] & 15) * 4
            if struct.unpack("!HH", p[ihl:ihl + 4]) == (dport, sport):
                print("rst" if p[ihl + 13] & 4 else "other"); break
    except socket.timeout: print("silence")
EOF

# --- сеть: нода (этот netns, wan0 10.99.0.1) <-> клиент (netns c, 10.99.0.2); маршрут по умолчанию — через клиента
ip link set lo up
ip netns add c
ip link add wan0 type veth peer name c0 netns c
ip addr add 10.99.0.1/24 dev wan0; ip link set wan0 up
ip -n c addr add 10.99.0.2/24 dev c0; ip -n c link set c0 up; ip -n c link set lo up
ip route add default via 10.99.0.2

PIDS=""
bg() { "$@" > /dev/null 2>&1 & PIDS="$PIDS $!"; }
trap 'kill $PIDS 2>/dev/null || true' EXIT
H() { python3 "$OUT/h.py" "$@"; }
C() { ip netns exec c "$@"; }
bg python3 "$OUT/h.py" tcp-serve 127.0.0.1 22       # SSH self-test у apply
bg python3 "$OUT/h.py" tcp-serve 0.0.0.0 8443       # «сервис» ноды: TCP
bg python3 "$OUT/h.py" udp-echo 0.0.0.0 5300        # «сервис» ноды: UDP
bg ip netns exec c python3 "$OUT/h.py" udp-echo 10.99.0.2 7000 "$OUT/go"
bg ip netns exec c python3 "$OUT/h.py" tcp-serve 10.99.0.2 7100
sleep 0.7
# «дошёл ли пакет дальше раннего фильтра»: счётчики на prerouting (после входа устройства, до фаервола)
nft -f - <<'EOF'
table inet eft {
    counter seen_udp { }
    counter seen_syn { }
    chain pre {
        type filter hook prerouting priority -300; policy accept;
        udp dport 5999 counter name seen_udp
        tcp dport 9999 tcp flags & (syn | ack) == syn counter name seen_syn
    }
}
EOF

fails=0
t() { local name="$1"; shift
    if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
gcnt() { { nft list counters table netdev spofy_guard; nft list counters table inet spofy_guard_ct; } 2>/dev/null \
            | awk -v n="c_$1" '$1 == "counter" { c = $2 } $1 == "packets" && c == n { print $2 }'; }
seen() { nft list counter inet eft "seen_$1" | awk '$1 == "packets" { print $2 }'; }
mode() { nft list chain netdev spofy_guard miss 2>/dev/null | grep -oE '(accept|drop)$' || true; }
handle() { nft -a -t list table netdev spofy_guard 2>/dev/null | sed -nE '1s/.*# handle ([0-9]+).*/\1/p'; }
rule_handle() { nft -a list chain netdev spofy_guard miss 2>/dev/null | sed -nE 's/^[[:space:]]*(accept|drop) # handle ([0-9]+)$/\2/p'; }
main() { bash "$SHIELD_DIR/main.sh" "$@"; }
# has <строка> <команда...> — вывод целиком в переменную: `команда | grep -q` под pipefail даёт ложный отказ
has() { local pat="$1" o; shift; o="$("$@" 2>&1 || true)"; grep -qF -- "$pat" <<<"$o"; }
G=/usr/local/sbin/spofy-guard

# старый фильтр UDP (spofy-udp-guard) «работает»: таблица, скрипт (заглушка с его `remove`), юниты, активный таймер
nft add table netdev spofy_udp
cat > /usr/local/sbin/spofy-udp-guard <<'V1STUB'
#!/bin/bash
if [ "${1:-}" = remove ]; then
    nft delete table netdev spofy_udp 2>/dev/null
    systemctl disable --now spofy-udp-guard.timer spofy-udp-guard.service
fi
exit 0
V1STUB
chmod +x /usr/local/sbin/spofy-udp-guard
: > /etc/systemd/system/spofy-udp-guard.service; : > /etc/systemd/system/spofy-udp-guard.timer
touch "$OUT/active/spofy-udp-guard.timer"
v1_on() { [ -e "$OUT/active/spofy-udp-guard.timer" ]; }

# ================= A. первый apply: наблюдение =================
rc=0; main apply > "$OUT/apply1.out" 2>&1 || rc=$?
t "apply: rc=0" "[ $rc = 0 ]"
t "apply: скрипт установлен байт в байт как в стеке, исполняемый" "cmp -s $G $SHIELD_DIR/spofy-guard && [ -x $G ]"
cat > "$OUT/unit.service" <<'EOF'
[Unit]
Description=Spofy guard: early filter at the node's network entry
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/spofy-guard ensure
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
EOF
cat > "$OUT/unit.timer" <<'EOF'
[Unit]
Description=Spofy guard: keep the table, add new listening ports, save memory to disk
[Timer]
OnBootSec=20s
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
t "apply: юниты фильтра — те же имена и тот же текст, что при установке руками" \
    "cmp -s $OUT/unit.service /etc/systemd/system/spofy-guard.service && cmp -s $OUT/unit.timer /etc/systemd/system/spofy-guard.timer"
t "apply: фильтр стоит на устройстве с маршрутом по умолчанию" "has 'device \"wan0\"' nft list chain netdev spofy_guard in"
t "apply: режим — наблюдение, отброса нет" "[ \"\$(mode)\" = accept ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ]"
t "apply: таймер фильтра включён ПОСЛЕ observe (его ensure не включил отброс в обход проверки)" \
    "grep -q 'enable --now spofy-guard.timer' $OUT/systemctl.log && ! grep -q 'boot:' $OUT/unit.out"
t "apply: свой таймер стека (проверка наблюдения) поставлен и запущен" \
    "[ -f /etc/systemd/system/shieldnode-earlyfilter.timer ] && grep -q 'restart shieldnode-earlyfilter.timer' $OUT/systemctl.log"
t "apply: настройки ядра в наблюдении не тронуты" "[ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ ! -e /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "apply: TRUSTED_IPS стека — в наборе доверенных фильтра" "has 10.99.0.77 nft list set netdev spofy_guard trusted"
t "apply: слушающие порты в списках (TCP 8443, UDP 5300)" \
    "has 8443 nft list set netdev spofy_guard tcp_svc && has 5300 nft list set netdev spofy_guard udp_listen"
t "правила: оборванным соединениям — ответ «сброс», для него свой набор слушающих портов" \
    "has 'reject with tcp reset' nft list table inet spofy_guard_ct && has 8443 nft list set inet spofy_guard_ct ports"
t "правила: кадры с чужим MAC пропускаются первым правилом входа (по остальным не идут)" \
    "nft list chain netdev spofy_guard in | grep -A1 'hook ingress' | tail -1 | grep -q 'meta pkttype other counter name \"c_otherhost\" accept'"
t "старый фильтр UDP: пока новый в наблюдении — не тронут" "nft list table netdev spofy_udp && v1_on && [ ! -e /var/lib/shieldnode/earlyfilter.v1 ]"
t "status: строка «наблюдение», устройство, счётчики" "has 'ранний фильтр: наблюдение | устройство wan0 | под отброс попало бы' main status"
t "verify: строка есть и код возврата от неё не зависит" "has '✔ ранний фильтр: наблюдение' main verify"
t "guard: строка в пульте" "has 'наблюдение | устройство wan0' main guard --once && has 'Ранний фильтр' main guard --once"

# ================= B. наблюдение: ничего не отбрасывается =================
C python3 "$OUT/h.py" udp-send 10.99.0.1 5999 x; sleep 0.3
t "наблюдение: UDP на неслушающий порт доходит (и посчитан как «под отброс»)" "[ \"\$(seen udp)\" = 1 ] && [ \"\$(gcnt udp_miss)\" -ge 1 ]"
C python3 "$OUT/h.py" tcp-ask 10.99.0.1 9999 x > /dev/null || true
t "наблюдение: SYN на закрытый порт доходит (и посчитан)" "[ \"\$(seen syn)\" -ge 1 ] && [ \"\$(gcnt syn_closed)\" -ge 1 ]"
t "наблюдение: SYN на слушающий порт проходит" "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8443 ping)\" = ok:hi:ping ]"
t "наблюдение: UDP на слушающий порт проходит" "[ \"\$(C python3 $OUT/h.py udp-ask 10.99.0.1 5300 0 hello)\" = reply:hello ] && [ \"\$(gcnt udp_listen)\" -ge 1 ]"
t "наблюдение: ответ на свой исходящий UDP проходит" "[ \"\$(H udp-ask 10.99.0.2 7000 40001 plain)\" = reply:plain ] && [ \"\$(gcnt udp_reply)\" -ge 1 ]"
# «свой» пакет под отбросом: нода спросила с порта 40000, порт убран из памяти фильтра, клиент шлёт ещё один
# пакет того же соединения — conntrack считает его частью живого соединения, фильтр отбросил бы
H udp-ask 10.99.0.2 7000 40000 own wait > "$OUT/own.out" 2>&1 & OWN=$!
for _ in $(seq 1 40); do grep -q 'reply:own' "$OUT/own.out" 2>/dev/null && break; sleep 0.1; done
nft delete element netdev spofy_guard udp_out '{ 40000 }' || true
touch "$OUT/go"; wait "$OWN" || true
t "наблюдение: «свой» пакет под отбросом ДОХОДИТ до сокета" "[ \"\$(sed -n 2p $OUT/own.out)\" = reply:late ]"
t "наблюдение: счётчик «своих» растёт, причина записана (UDP не к нам)" \
    "[ \"\$(gcnt fp)\" -ge 1 ] && has '5d05 counter packets' nft list set inet spofy_guard_ct fp"

# ================= C. решение о включении отброса =================
# обучение позади: «свой» пакет выше попал под отброс ВО ВРЕМЯ обучения (так на живой ноде выглядят ответы на
# потоки, начатые до фильтра) — по нему не судят: счётчики с нуля, начинается замер
sleep 1.2   # LEARN=1
main early-filter tick > "$OUT/tick0.out" 2>&1 || true
t "обучение закончено: «свои» времени обучения в расчёт не идут — счётчики с нуля, начат замер, отказа нет" \
    "[ \"\$(mode)\" = accept ] && grep -q '^measure' /var/lib/shieldnode/earlyfilter.note && [ \"\$(gcnt fp)\" = 0 ] && [ \"\$(gcnt udp_miss)\" = 0 ] && ! grep -q 'НЕ включён' $OUT/tick0.out && grep -qE '^[0-9]+ [0-9]+ [0-9]+\$' /var/lib/shieldnode/earlyfilter.observe"
t "обучение закончено: память фильтра не сброшена (свой исходящий порт 40001 на месте)" "has 40001 nft list set netdev spofy_guard udp_out"
# тот же «свой» пакет под отбросом — уже во время замера
rm -f "$OUT/go"
H udp-ask 10.99.0.2 7000 40000 own wait > "$OUT/own2.out" 2>&1 & OWN=$!
for _ in $(seq 1 40); do grep -q 'reply:own' "$OUT/own2.out" 2>/dev/null && break; sleep 0.1; done
nft delete element netdev spofy_guard udp_out '{ 40000 }' || true
touch "$OUT/go"; wait "$OWN" || true
for i in 1 2 3; do C python3 "$OUT/h.py" tcp-ask 10.99.0.1 8443 "m$i" > /dev/null; C python3 "$OUT/h.py" udp-ask 10.99.0.1 5300 0 "n$i" > /dev/null; done
sleep 1.2   # SHIELD_EF_MEASURE_SEC=1
main early-filter tick > "$OUT/tick1.out" 2>&1 || true
t "проверка: «свои» под отбросом — отброс НЕ включён, остаётся наблюдение" "[ \"\$(mode)\" = accept ] && grep -q '^dirty:own' /var/lib/shieldnode/earlyfilter.note"
t "проверка: предупреждение с числами — в журнале" "grep -q '\[warn\] earlyfilter: .*«своих» пакетов под отбросом [0-9]* из [0-9]* учтённых' $OUT/tick1.out"
t "проверка: причина видна в status (health WARN и раздел фильтра)" \
    "main status > $OUT/status.out 2>&1; grep -q '\[WARN\] ранний фильтр: отброс НЕ включён' $OUT/status.out && grep -q 'наблюдение ведёт стек' $OUT/status.out"
# порт вне списков: сервис появился после составления списков, нода отвечает с него
bg python3 "$OUT/h.py" tcp-serve 0.0.0.0 8555; sleep 0.5
t "наблюдение: соединение на порт, которого нет в списках, проходит" "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8555 new)\" = ok:hi:new ]"
t "после «не чисто» замер начат заново: счётчик «своих» с нуля" "[ \"\$(gcnt fp)\" = 0 ]"
for i in 1 2 3; do C python3 "$OUT/h.py" tcp-ask 10.99.0.1 8443 "p$i" > /dev/null; C python3 "$OUT/h.py" udp-ask 10.99.0.1 5300 0 "u$i" > /dev/null; done
sleep 1.2
main early-filter tick > "$OUT/tick2.out" 2>&1 || true
t "проверка: сервер отвечает с порта вне списков — отброс НЕ включён, порт назван" "[ \"\$(mode)\" = accept ] && grep -q '^dirty:+ports' /var/lib/shieldnode/earlyfilter.note && grep -q '8555' /var/lib/shieldnode/earlyfilter.note"
"$G" ensure > /dev/null 2>&1                # то, что раз в минуту делает таймер фильтра: дописать новые порты
for i in 1 2 3; do C python3 "$OUT/h.py" tcp-ask 10.99.0.1 8443 "q$i" > /dev/null; C python3 "$OUT/h.py" udp-ask 10.99.0.1 5300 0 "v$i" > /dev/null; done
sleep 1.2
main early-filter tick > "$OUT/tick3.out" 2>&1 || true
t "проверка: порт попал в списки, «своих» нет — отброс ВКЛЮЧЁН" "[ \"\$(mode)\" = drop ] && [ \"\$(cat $GUARD_STATE/mode)\" = enforce ]"
t "включение: две настройки ядра фильтра включены" \
    "[ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 0 ] && [ \"\$(sysctl -n net.ipv4.tcp_synack_retries)\" = 3 ] && [ -f /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "включение: запись с числами в журнале" "grep -q 'earlyfilter: ранний фильтр: отброс включён (устройство wan0)' $OUT/tick3.out"
t "включение: свой таймер стека снят, отметка наблюдения убрана" \
    "[ ! -e /etc/systemd/system/shieldnode-earlyfilter.timer ] && [ ! -e /etc/systemd/system/shieldnode-earlyfilter.service ] && [ ! -e /var/lib/shieldnode/earlyfilter.observe ] && grep -q 'disable --now shieldnode-earlyfilter.timer' $OUT/systemctl.log"
t "status: строка «отброс»" "has '[PASS] ранний фильтр: отброс | устройство wan0 | под отброс попало' main status"
t "старый фильтр UDP: отброс включён — снят (таблица, таймер), отмечено для rollback" \
    "! nft list table netdev spofy_udp && ! v1_on && [ -e /var/lib/shieldnode/earlyfilter.v1 ] && grep -q 'spofy-udp-guard) снят' $OUT/tick3.out"
t "порт, дописанный позже, попал и в набор для ответа «сброс»" "has 8555 nft list set inet spofy_guard_ct ports"

# ================= D. отброс =================
s0="$(seen udp)"; m0="$(gcnt udp_miss)"
C python3 "$OUT/h.py" udp-send 10.99.0.1 5999 x; sleep 0.3
t "(а) отброс: UDP на неслушающий порт отбрасывается на входе" "[ \"\$(seen udp)\" = $s0 ] && [ \"\$(gcnt udp_miss)\" -gt $m0 ]"
t "(б) отброс: ответ на свой исходящий UDP проходит" "[ \"\$(H udp-ask 10.99.0.2 7000 40002 plain2)\" = reply:plain2 ]"
t "(в) отброс: UDP на слушающий порт проходит" "[ \"\$(C python3 $OUT/h.py udp-ask 10.99.0.1 5300 0 hello2)\" = reply:hello2 ]"
C ip neigh flush dev c0 || true; ip neigh flush dev wan0 || true
t "(г) отброс: ARP не затронут — после сброса соседей обмен идёт в обе стороны" \
    "[ \"\$(C python3 $OUT/h.py udp-ask 10.99.0.1 5300 0 arp)\" = reply:arp ] && [ \"\$(H udp-ask 10.99.0.2 7000 40003 arp2)\" = reply:arp2 ]"
t "(г) отброс: TCP не затронут — входящее и исходящее соединения с обменом данными" \
    "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8443 data)\" = ok:hi:data ] && [ \"\$(H tcp-ask 10.99.0.2 7100 out)\" = ok:hi:out ]"
t "отброс: SYN на слушающий порт проходит (порт, дописанный позже, — тоже)" \
    "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8443 syn)\" = ok:hi:syn ] && [ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8555 syn2)\" = ok:hi:syn2 ]"
s0="$(seen syn)"; m0="$(gcnt syn_closed)"
t "отброс: SYN на закрытый порт отбрасывается на входе (клиент не получает даже отказа)" \
    "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 9999 x)\" = timeout ] && [ \"\$(seen syn)\" = $s0 ] && [ \"\$(gcnt syn_closed)\" -gt $m0 ]"
i0="$(gcnt invalid)"
t "отброс: пакет в соединение, которого на сервере нет, на слушающий порт — сразу ответ «сброс»" \
    "[ \"\$(C python3 $OUT/h.py tcp-stale 10.99.0.2 10.99.0.1 8443)\" = rst ] && [ \"\$(gcnt stale)\" -ge 1 ]"
t "отброс: такой же пакет на закрытый порт — молча отбрасывается" \
    "[ \"\$(C python3 $OUT/h.py tcp-stale 10.99.0.2 10.99.0.1 9999)\" = silence ] && [ \"\$(gcnt invalid)\" -gt $i0 ]"

# ================= E. усыновление: повторный apply не трогает включённый фильтр =================
h0="$(handle)"; r0="$(rule_handle)"; m0="$(gcnt udp_miss)"
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nTRUSTED_IPS=10.99.0.77 10.99.0.88\n' > /etc/shieldnode/config.conf
: > "$OUT/unit.out"
rc=0; main apply > "$OUT/apply2.out" 2>&1 || rc=$?
t "повторный apply: rc=0" "[ $rc = 0 ]"
t "повторный apply: таблица та же (не пересоздана)" "[ -n \"$h0\" ] && [ \"\$(handle)\" = \"$h0\" ]"
t "повторный apply: правило режима то же — отброс не переключался" "[ -n \"$r0\" ] && [ \"\$(rule_handle)\" = \"$r0\" ] && [ \"\$(mode)\" = drop ]"
t "повторный apply: счётчики не сброшены" "[ \"\$(gcnt udp_miss)\" -ge $m0 ]"
t "повторный apply: файл и оба юнита совпали — не переписаны" \
    "[ \"\$(grep -cE 'persist: (/usr/local/sbin/spofy-guard|/etc/systemd/system/spofy-guard\.(service|timer)) \(без изменений\)' $OUT/apply2.out)\" = 3 ]"
t "повторный apply: новый адрес из TRUSTED_IPS дописан в набор без пересоздания таблицы" "has 10.99.0.88 nft list set netdev spofy_guard trusted"
t "повторный apply: свой таймер стека не возвращается" "[ ! -e /etc/systemd/system/shieldnode-earlyfilter.timer ]"
t "после apply: UDP на неслушающий порт по-прежнему отбрасывается" \
    "s=\$(seen udp); C python3 $OUT/h.py udp-send 10.99.0.1 5999 x; sleep 0.3; [ \"\$(seen udp)\" = \"\$s\" ]"

# apply --dry-run: шаг фильтра назван в плане, а на сервере не меняется ничего
h0="$(handle)"; r0="$(rule_handle)"; n0="$(grep -c . "$OUT/systemctl.log")"; s0="$(sha256sum "$G" | cut -d' ' -f1)"
rc=0; main apply --dry-run > "$OUT/apply-dry.out" 2>&1 || rc=$?
t "apply --dry-run: rc=0, шаг раннего фильтра назван в плане" "[ $rc = 0 ] && grep -q 'early filter (spofy-guard): ENABLE_EARLY_FILTER=1 EARLY_FILTER_MODE=auto, now: enforce' $OUT/apply-dry.out"
t "apply --dry-run: таблица, правило режима и файл скрипта те же, ни одного меняющего вызова systemctl" \
    "[ \"\$(handle)\" = \"$h0\" ] && [ \"\$(rule_handle)\" = \"$r0\" ] && [ \"\$(mode)\" = drop ] && [ \"\$(sha256sum $G | cut -d' ' -f1)\" = $s0 ] && ! tail -n +\$(( $n0 + 1 )) $OUT/systemctl.log | grep -qE '^(enable|disable|start|stop|restart|daemon-reload|mask|unmask)'"

# ================= J. скрипт на сервере другой версии: замена и `reload` в том же режиме =================
echo '# прежняя версия' >> "$G"
h0="$(handle)"; n0="$(grep -c . "$OUT/systemctl.log")"
t "до обновления: адрес клиента — среди знакомых" "has 10.99.0.2 nft list set netdev spofy_guard known"
rc=0; main apply > "$OUT/apply-up.out" 2>&1 || rc=$?
t "другая версия: apply rc=0, на сервере встроенный скрипт, прежний — в копии рядом" \
    "[ $rc = 0 ] && cmp -s $G $SHIELD_DIR/spofy-guard && ls /usr/local/sbin/spofy-guard.pre-shieldnode-*"
t "другая версия: правила поставлены заново (таблица новая), режим прежний — отброс" \
    "[ -n \"$h0\" ] && [ \"\$(handle)\" != \"$h0\" ] && [ \"\$(mode)\" = drop ] && [ \"\$(cat $GUARD_STATE/mode)\" = enforce ] && grep -q 'ранний фильтр обновлён: .*режим прежний — отброс' $OUT/apply-up.out"
t "другая версия: наблюдение заново не начиналось (ни отметки, ни своего таймера стека, ни временной копии)" \
    "[ ! -e /var/lib/shieldnode/earlyfilter.observe ] && [ ! -e /etc/systemd/system/shieldnode-earlyfilter.timer ] && [ ! -e /var/lib/shieldnode/earlyfilter.prev ] && [ ! -e /var/lib/shieldnode/earlyfilter.upgrade ]"
t "другая версия: знакомые адреса сохранены, настройки ядра фильтра на месте" \
    "has 10.99.0.2 nft list set netdev spofy_guard known && [ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 0 ] && [ -f /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "другая версия: таймер фильтра остановлен на время обновления и запущен обратно" \
    "[ \"\$(tail -n +\$(( $n0 + 1 )) $OUT/systemctl.log | grep -x -e 'stop spofy-guard.timer' -e 'start spofy-guard.timer' | paste -sd, -)\" = 'stop spofy-guard.timer,start spofy-guard.timer' ] && [ -e $OUT/active/spofy-guard.timer ]"
t "после обновления: SYN на слушающий порт проходит, UDP на неслушающий отбрасывается, оборванному — «сброс»" \
    "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8443 up)\" = ok:hi:up ] && s=\$(seen udp) && C python3 $OUT/h.py udp-send 10.99.0.1 5999 x && sleep 0.3 && [ \"\$(seen udp)\" = \"\$s\" ] && [ \"\$(C python3 $OUT/h.py tcp-stale 10.99.0.2 10.99.0.1 8443)\" = rst ]"
h0="$(handle)"; "$G" reload > "$OUT/reload.out" 2>&1 || true
t "reload самого скрипта в отбросе: таблица заново, режим прежний — отброс" \
    "[ -n \"$h0\" ] && [ \"\$(handle)\" != \"$h0\" ] && [ \"\$(mode)\" = drop ] && [ \"\$(cat $GUARD_STATE/mode)\" = enforce ]"

# ================= F. аварийный режим =================
main emergency on > "$OUT/em-on.out" 2>&1 || true
t "emergency on: таблицы фильтра сняты" "! nft list table netdev spofy_guard && ! nft list table inet spofy_guard_ct"
t "emergency on: настройки ядра возвращены" "[ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ ! -e /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "emergency on: юниты фильтра выключены (таймер не поставит таблицу заново)" "[ ! -e $OUT/active/spofy-guard.timer ]"
t "emergency on: status — «снят на время аварийного режима»" "has 'ранний фильтр: нет (снят на время аварийного режима)' main status"
main early-filter tick > /dev/null 2>&1 || true
t "emergency on: проверка по таймеру ничего не ставит" "! nft list table netdev spofy_guard"
main emergency off > "$OUT/em-off.out" 2>&1 || true
t "emergency off: отброс возвращён (скрипт сам учится LEARN с и включает)" "[ \"\$(mode)\" = drop ] && [ \"\$(cat $GUARD_STATE/mode)\" = enforce ]"
t "emergency off: настройки ядра фильтра снова включены" "[ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 0 ] && [ -f /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "emergency off: юниты фильтра включены" "[ -e $OUT/active/spofy-guard.timer ]"

# ================= G. ENABLE_EARLY_FILTER=0 =================
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nENABLE_EARLY_FILTER=0\n' > /etc/shieldnode/config.conf
rc=0; main apply > "$OUT/apply3.out" 2>&1 || rc=$?
t "ENABLE_EARLY_FILTER=0: apply rc=0, таблицы сняты" "[ $rc = 0 ] && ! nft list table netdev spofy_guard && ! nft list table inet spofy_guard_ct"
t "ENABLE_EARLY_FILTER=0: файл, юниты и состояние фильтра убраны" \
    "[ ! -e $G ] && [ ! -e /etc/systemd/system/spofy-guard.service ] && [ ! -e /etc/systemd/system/spofy-guard.timer ] && [ ! -e $GUARD_STATE ]"
t "ENABLE_EARLY_FILTER=0: настройки ядра возвращены" "[ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ \"\$(sysctl -n net.ipv4.tcp_synack_retries)\" != 3 ]"
t "ENABLE_EARLY_FILTER=0: файл больше не числится за стеком" "! grep -qxF $G /var/lib/shieldnode/applied-files.txt"
t "ENABLE_EARLY_FILTER=0: настройки оператора (spofy-guard.conf) на месте" "[ -f $GUARD_CONF ]"
t "ENABLE_EARLY_FILTER=0: старый фильтр UDP, снятый стеком, включён обратно" \
    "v1_on && [ ! -e /var/lib/shieldnode/earlyfilter.v1 ] && grep -q 'spofy-udp-guard) включён обратно' $OUT/apply3.out"
t "ENABLE_EARLY_FILTER=0: status — «нет (ENABLE_EARLY_FILTER=0)»" "has 'ранний фильтр выключен (ENABLE_EARLY_FILTER=0)' main status && has 'ранний фильтр: нет (ENABLE_EARLY_FILTER=0)' main status"

# ================= H. снова =1: только через наблюдение; ручная проба; rollback =================
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\n' > /etc/shieldnode/config.conf
: > "$OUT/unit.out"
rc=0; main apply > "$OUT/apply4.out" 2>&1 || rc=$?
t "снова =1: apply ставит наблюдение, а не сразу отброс" "[ $rc = 0 ] && [ \"\$(mode)\" = accept ] && ! grep -q 'boot:' $OUT/unit.out"
for i in 1 2 3; do C python3 "$OUT/h.py" tcp-ask 10.99.0.1 8443 "p$i" > /dev/null; C python3 "$OUT/h.py" udp-ask 10.99.0.1 5300 0 "u$i" > /dev/null; done
sleep 1.2
touch "$OUT/active/spofy-guard-observe-expire.timer"     # ручная проба с автоснятием
h0="$(handle)"
main early-filter tick > /dev/null 2>&1 || true
rc=0; main apply > "$OUT/apply5.out" 2>&1 || rc=$?
t "ручная проба (spofy-guard-observe-expire.timer активен): ни таймер, ни apply режим не меняют" \
    "[ $rc = 0 ] && [ \"\$(mode)\" = accept ] && [ \"\$(handle)\" = \"$h0\" ] && grep -q 'идёт ручная проба' $OUT/apply5.out"
rm -f "$OUT/active/spofy-guard-observe-expire.timer"
main early-filter tick > "$OUT/tick4a.out" 2>&1 || true       # обучение позади — начинается замер
t "проба закончилась: первая проверка начинает замер, отброс ещё не включён" "[ \"\$(mode)\" = accept ] && grep -q '^measure' /var/lib/shieldnode/earlyfilter.note"
for i in 1 2 3; do C python3 "$OUT/h.py" tcp-ask 10.99.0.1 8443 "r$i" > /dev/null; C python3 "$OUT/h.py" udp-ask 10.99.0.1 5300 0 "w$i" > /dev/null; done
sleep 1.2
main early-filter tick > "$OUT/tick4.out" 2>&1 || true
t "проба закончилась: чистый замер доводится до отброса" "[ \"\$(mode)\" = drop ]"
rc=0; main rollback > "$OUT/rollback.out" 2>&1 || rc=$?
t "rollback: rc=0, таблицы фильтра сняты" "[ $rc = 0 ] && ! nft list table netdev spofy_guard && ! nft list table inet spofy_guard_ct"
t "rollback: настройки ядра возвращены, файл sysctl убран" "[ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ ! -e /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "rollback: юниты выключены и убраны, файл и состояние убраны" \
    "[ ! -e $OUT/active/spofy-guard.timer ] && [ ! -e /etc/systemd/system/spofy-guard.timer ] && [ ! -e /etc/systemd/system/spofy-guard.service ] && [ ! -e $G ] && [ ! -e $GUARD_STATE ]"
t "rollback: отметок стека не осталось" "[ -z \"\$(ls /var/lib/shieldnode/earlyfilter.* 2>/dev/null)\" ]"
t "rollback: настройки оператора (spofy-guard.conf) на месте" "[ -f $GUARD_CONF ]"
t "rollback: последний вызов systemctl — daemon-reload" "[ \"\$(tail -1 $OUT/systemctl.log)\" = daemon-reload ]"
t "rollback: старый фильтр UDP (стек снял его при включении отброса) включён обратно" \
    "v1_on && grep -q 'spofy-udp-guard) включён обратно' $OUT/rollback.out"

# ================= K. EARLY_FILTER_MODE=observe =================
traffic() { local i; for i in 1 2 3; do C python3 "$OUT/h.py" tcp-ask 10.99.0.1 8443 "p$i" > /dev/null; C python3 "$OUT/h.py" udp-ask 10.99.0.1 5300 0 "u$i" > /dev/null; done; }
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nEARLY_FILTER_MODE=observe\n' > /etc/shieldnode/config.conf
rc=0; main apply > "$OUT/apply-k1.out" 2>&1 || rc=$?
t "режим observe: apply ставит наблюдение; ни своего таймера проверки, ни окна наблюдения стека" \
    "[ $rc = 0 ] && [ \"\$(mode)\" = accept ] && [ ! -e /etc/systemd/system/shieldnode-earlyfilter.timer ] && [ ! -e /var/lib/shieldnode/earlyfilter.observe ] && [ -e $OUT/active/spofy-guard.timer ]"
traffic; sleep 1.2
main early-filter tick > /dev/null 2>&1 || true
rc=0; main apply > "$OUT/apply-k2.out" 2>&1 || rc=$?
t "режим observe: чистое наблюдение дольше LEARN — отброс не включают ни таймер, ни apply; ядро не тронуто" \
    "[ $rc = 0 ] && [ \"\$(mode)\" = accept ] && [ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ ! -e /etc/sysctl.d/99-z9-spofy-guard.conf ]"
main status > "$OUT/status-k.out" 2>&1 || true
t "режим observe: status — настройка, причина (INFO, не WARN) и вывод по числам" \
    "grep -q 'EARLY_FILTER_MODE=observe; ведёт стек: да' $OUT/status-k.out && grep -q '\[INFO\] ранний фильтр в наблюдении по настройке EARLY_FILTER_MODE=observe' $OUT/status-k.out && grep -q 'по числам сейчас: чисто' $OUT/status-k.out && ! grep -q '\[WARN\] ранний фильтр' $OUT/status-k.out"
t "режим observe: старый фильтр UDP не снимается" "v1_on && [ ! -e /var/lib/shieldnode/earlyfilter.v1 ]"
h0="$(handle)"; "$G" reload > "$OUT/reload-k.out" 2>&1 || true
t "reload самого скрипта в наблюдении: таблица заново, режим прежний — наблюдение" \
    "[ -n \"$h0\" ] && [ \"\$(handle)\" != \"$h0\" ] && [ \"\$(mode)\" = accept ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ]"
echo '# прежняя версия' >> "$G"; h0="$(handle)"
rc=0; main apply > "$OUT/apply-k3.out" 2>&1 || rc=$?
t "режим observe, скрипт другой версии: заменён, правила поставлены заново, остаётся наблюдение" \
    "[ $rc = 0 ] && cmp -s $G $SHIELD_DIR/spofy-guard && [ \"\$(handle)\" != \"$h0\" ] && [ \"\$(mode)\" = accept ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ] && grep -q 'режим прежний — наблюдение' $OUT/apply-k3.out"
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\n' > /etc/shieldnode/config.conf
rc=0; main apply > "$OUT/apply-k4.out" 2>&1 || rc=$?
t "снова auto: стек берёт наблюдение на себя (окно, свой таймер), отброс сразу не включает" \
    "[ $rc = 0 ] && [ \"\$(mode)\" = accept ] && [ -s /var/lib/shieldnode/earlyfilter.observe ] && [ -e /etc/systemd/system/shieldnode-earlyfilter.timer ]"
sleep 1.2
main early-filter tick > "$OUT/tick-k0.out" 2>&1 || true     # обучение позади — начинается замер
traffic; sleep 1.2
main early-filter tick > "$OUT/tick-k.out" 2>&1 || true
t "снова auto: чистый замер доводится до отброса, старый фильтр UDP снят" \
    "[ \"\$(mode)\" = drop ] && [ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 0 ] && ! v1_on && [ -e /var/lib/shieldnode/earlyfilter.v1 ]"
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nEARLY_FILTER_MODE=observe\n' > /etc/shieldnode/config.conf
t "режим observe задан, а отброс ещё включён: status предупреждает" "has '[WARN] ранний фильтр: отброс' main status && has 'а EARLY_FILTER_MODE=observe' main status"
rc=0; main apply > "$OUT/apply-k5.out" 2>&1 || rc=$?
t "режим observe при включённом отбросе: apply переводит в наблюдение, настройки ядра возвращены" \
    "[ $rc = 0 ] && [ \"\$(mode)\" = accept ] && [ \"\$(cat $GUARD_STATE/mode)\" = observe ] && [ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ ! -e /etc/sysctl.d/99-z9-spofy-guard.conf ]"
t "режим observe при включённом отбросе: пакеты снова не отбрасываются" \
    "s=\$(seen udp) && C python3 $OUT/h.py udp-send 10.99.0.1 5999 x && sleep 0.3 && [ \"\$(seen udp)\" -gt \"\$s\" ]"
t "режим observe при включённом отбросе: старый фильтр UDP, снятый стеком, включён обратно (ранний отброс UDP не пропадает)" \
    "v1_on && [ ! -e /var/lib/shieldnode/earlyfilter.v1 ] && grep -q 'spofy-udp-guard) включён обратно' $OUT/apply-k5.out"
rc=0; main rollback > "$OUT/rollback-k.out" 2>&1 || rc=$?
t "rollback из наблюдения: фильтр снят целиком" "[ $rc = 0 ] && ! nft list table netdev spofy_guard && [ ! -e $G ] && [ ! -e $GUARD_STATE ]"

# ================= I. фильтр, включённый руками мимо стека (как на серверах, где он уже работает) =================
# те же шаги, что при установке руками: файл, observe, sysctl on, enforce, два юнита, enable
install -m 0755 "$SHIELD_DIR/spofy-guard" "$G"
"$G" observe > /dev/null 2>&1; "$G" sysctl on > /dev/null 2>&1; "$G" enforce > /dev/null 2>&1
cp "$OUT/unit.service" /etc/systemd/system/spofy-guard.service; cp "$OUT/unit.timer" /etc/systemd/system/spofy-guard.timer
systemctl enable spofy-guard.service; systemctl enable --now spofy-guard.timer
touch -d '2026-11-13 12:00' "$G" /etc/systemd/system/spofy-guard.service /etc/systemd/system/spofy-guard.timer
mt="$(date -d '2026-11-13 12:00' +%s)"
h0="$(handle)"; r0="$(rule_handle)"
C python3 "$OUT/h.py" udp-send 10.99.0.1 5999 x; sleep 0.3; m0="$(gcnt udp_miss)"
t "руками: отброс включён, файл за стеком не числится" "[ \"\$(mode)\" = drop ] && [ -n \"$h0\" ] && [ \"$m0\" -ge 1 ] && ! grep -qxF $G /var/lib/shieldnode/applied-files.txt"
intact() { [ "$(handle)" = "$h0" ] && [ "$(rule_handle)" = "$r0" ] && [ "$(mode)" = drop ] && [ "$(gcnt udp_miss)" -ge "$m0" ] \
    && [ "$(stat -c %Y "$G")" = "$mt" ] && [ "$(stat -c %Y /etc/systemd/system/spofy-guard.timer)" = "$mt" ] && [ -e "$OUT/active/spofy-guard.timer" ] \
    && [ "$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)" = 0 ] && [ -f /etc/sysctl.d/99-z9-spofy-guard.conf ] && [ "$(cat "$GUARD_STATE/mode")" = enforce ]; }
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nENABLE_EARLY_FILTER=0\n' > /etc/shieldnode/config.conf
rc=0; main apply > "$OUT/apply6.out" 2>&1 || rc=$?
t "ENABLE_EARLY_FILTER=0, фильтр мимо стека: apply его не трогает (таблица, режим, счётчики, файл, юниты, ядро)" \
    "[ $rc = 0 ] && intact && grep -q 'поставлен мимо стека' $OUT/apply6.out && ! grep -qxF $G /var/lib/shieldnode/applied-files.txt"
rc=0; main rollback > "$OUT/rollback2.out" 2>&1 || rc=$?
t "ENABLE_EARLY_FILTER=0, фильтр мимо стека: rollback его не трогает" "[ $rc = 0 ] && intact"
printf 'SSH_PORT=22\nENABLE_CROWDSEC_LIST=0\nTRUSTED_IPS=10.99.0.77\n' > /etc/shieldnode/config.conf
: > "$OUT/unit.out"; n0="$(grep -c . "$OUT/systemctl.log")"
rc=0; main apply > "$OUT/apply7.out" 2>&1 || rc=$?
t "=1, отброс включён руками: apply принимает как есть — таблица и правило режима те же, счётчики целы, файлы не переписаны" \
    "[ $rc = 0 ] && intact && [ \"\$(grep -cE 'persist: (/usr/local/sbin/spofy-guard|/etc/systemd/system/spofy-guard\.(service|timer)) \(без изменений\)' $OUT/apply7.out)\" = 3 ]"
t "=1, отброс включён руками: ни наблюдения заново, ни своего таймера, ни перезапуска юнитов фильтра" \
    "! grep -q 'boot:' $OUT/unit.out && [ ! -e /etc/systemd/system/shieldnode-earlyfilter.timer ] && [ ! -e /var/lib/shieldnode/earlyfilter.observe ] && ! tail -n +\$(( $n0 + 1 )) $OUT/systemctl.log | grep -qE '^(restart|stop|disable).*spofy-guard'"
t "=1, отброс включён руками: теперь файл числится за стеком, TRUSTED_IPS дописан в набор" \
    "grep -qxF $G /var/lib/shieldnode/applied-files.txt && has 10.99.0.77 nft list set netdev spofy_guard trusted"
t "после принятия: SYN на слушающий порт проходит, UDP на неслушающий отбрасывается" \
    "[ \"\$(C python3 $OUT/h.py tcp-ask 10.99.0.1 8443 adopt)\" = ok:hi:adopt ] && s=\$(seen udp) && C python3 $OUT/h.py udp-send 10.99.0.1 5999 x && sleep 0.3 && [ \"\$(seen udp)\" = \"\$s\" ]"
rc=0; main rollback > "$OUT/rollback3.out" 2>&1 || rc=$?
t "rollback после принятия: фильтр снят целиком (его теперь ведёт стек)" \
    "[ $rc = 0 ] && ! nft list table netdev spofy_guard && ! nft list table inet spofy_guard_ct && [ ! -e $G ] && [ ! -e /etc/systemd/system/spofy-guard.timer ] && [ \"\$(sysctl -n net.netfilter.nf_conntrack_tcp_loose)\" = 1 ] && [ ! -e $GUARD_STATE ]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: earlyfilter-realnft (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
