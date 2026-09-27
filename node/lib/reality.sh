#!/bin/bash
# node — lib/reality.sh: скорость dest у REALITY (v1.2.2, режим `reality-check`). ТОЛЬКО ЧТЕНИЕ.
# 2026-09-27: на КАЖДОЕ подключение клиента REALITY открывает соединение к dest и ждёт его TLS-ответа —
# лаба: dest дальше на 150 мс -> время до первого байта у каждого нового соединения 23 -> 322 мс
# (два круга нода<->dest). Далёкий dest тормозит VPN сильнее любых настроек ядра. Конфиг Xray node не
# меняет (dest задаётся в панели) — здесь только замер с этой ноды и подсказка.
# dest берётся из работающего Xray (`api lsi`). В выводе API есть приватный ключ REALITY и UUID
# пользователей: разбор только в памяти, наружу — одно поле dest.
set -euo pipefail

# кандидаты по умолчанию: крупные сайты с TLS 1.3 и HTTP/2 (требования REALITY к dest)
NODE_REALITY_CANDIDATES="${NODE_REALITY_CANDIDATES:-www.microsoft.com:443 www.apple.com:443 dl.google.com:443 www.samsung.com:443 www.nvidia.com:443 www.cloudflare.com:443 addons.mozilla.org:443}"

# node_reality_lsi_json — `api lsi` работающего Xray (как shieldnode detect.sh; фикстура — NODE_XRAY_LSI_FILE)
node_reality_lsi_json() {
    if [ -n "${NODE_XRAY_LSI_FILE:-}" ]; then cat "$NODE_XRAY_LSI_FILE" 2>/dev/null; return 0; fi
    command -v ss >/dev/null 2>&1 || return 0
    local line sock pid exe cid
    line="$( { ss -xlpH 2>/dev/null || true; } | grep -m1 -E '@xtls-api-[A-Za-z0-9_-]+' || true)"
    [ -n "$line" ] || return 0
    sock="$(grep -oE '@xtls-api-[A-Za-z0-9_-]+' <<<"$line" | head -1)"
    pid="$(grep -oE 'pid=[0-9]+' <<<"$line" | head -1 | cut -d= -f2)"
    [ -n "$sock" ] && [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"; exe="${exe% (deleted)}"
    [ -n "$exe" ] || return 0
    cid="$(grep -oE 'docker-[0-9a-f]{64}\.scope|/docker/[0-9a-f]{64}' "/proc/$pid/cgroup" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1 || true)"
    if [ -n "$cid" ] && command -v docker >/dev/null 2>&1; then
        timeout 15 docker exec "$cid" "$exe" api lsi --server="unix:$sock" -timeout 5 2>/dev/null || true
    elif [ -x "$exe" ]; then
        timeout 15 "$exe" api lsi --server="unix:$sock" -timeout 5 2>/dev/null || true
    fi
}

# node_reality_dests — уникальные dest REALITY-инбаундов: строки «dest<TAB>SNI» (SNI — первый из serverNames).
# dest: «host:port»; голый порт -> 127.0.0.1:порт; путь «/…» или «@…» — unix-сокет (selfsteal), как есть.
# 2026-09-27 (v1.2.4): раньше путь сокета превращался в «/dev/shm/x.sock:443», а 127.0.0.1:8443
# проверялся без SNI — у selfsteal (Caddy отвечает только на свой домен) это «недоступен».
node_reality_dests() {
    node_reality_lsi_json | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
def walk(x):
    if isinstance(x, dict):
        if x.get("_TypedMessage_", "").endswith("reality.Config"):
            v = str(x.get("dest") or x.get("target") or "").strip()
            sn = [str(n) for n in (x.get("serverNames") or x.get("server_names") or []) if n]
            if v:
                if v.isdigit():
                    v = "127.0.0.1:" + v
                elif not v.startswith(("/", "@")) and ":" not in v:
                    v += ":443"
                line = v + "\t" + (sn[0] if sn else "")
                if line not in out:
                    out.append(line)
        for y in x.values():
            walk(y)
    elif isinstance(x, list):
        for y in x:
            walk(y)
walk(d)
print("\n".join(out))' 2>/dev/null || true
}

# node_reality_probe <dest> [SNI] — «рукопожатие_мс tls13 h2»: медиана 5 замеров (3 — мало: на шумной VM выброс
# давал «54 мс» у selfsteal при реальных 6–13) TCP+TLS (без DNS);
# tls13/h2 = yes|no. Пусто — dest недоступен. Как REALITY: соединение к адресу dest, но с SNI клиента
# (serverNames) — у selfsteal (127.0.0.1:порт, unix-сокет) сертификат только на свой домен.
node_reality_probe() {
    local dest="$1" sni="${2:-}" host port r vals="" tls="no" h2="no"
    local -a tgt
    case "$dest" in
        @*) tgt=(--abstract-unix-socket "${dest#@}" "https://${sni:-localhost}/") ;;
        /*) tgt=(--unix-socket "$dest" "https://${sni:-localhost}/") ;;
        *)  host="${dest%:*}"; port="${dest##*:}"
            if [ -n "$sni" ] && [ "$sni" != "$host" ]; then tgt=(--connect-to "$sni:443:$host:$port" "https://$sni/")
            else tgt=("https://$host:$port/"); fi ;;
    esac
    for _ in 1 2 3 4 5; do
        r="$(curl -k -s -o /dev/null --max-time 5 --tlsv1.3 --http2 \
            -w '%{time_namelookup} %{time_appconnect} %{http_version}' "${tgt[@]}" 2>/dev/null || true)"
        # shellcheck disable=SC2086  # r — три поля curl -w
        set -- $r
        [ $# -eq 3 ] || continue
        awk -v a="$2" 'BEGIN { exit !(a > 0) }' || continue
        vals="$vals $(awk -v n="$1" -v a="$2" 'BEGIN { printf "%.0f", (a - n) * 1000 }')"
        tls="yes"; [ "$3" = 2 ] && h2="yes"
    done
    [ -n "$vals" ] || return 0
    printf '%s %s %s\n' "$(tr ' ' '\n' <<<"$vals" | grep . | sort -n | awk '{a[NR] = $1} END {print a[int((NR + 1) / 2)]}')" "$tls" "$h2"
}

_node_reality_verdict() { # <мс>
    if [ "$1" -le 30 ]; then echo "отлично"; elif [ "$1" -le 80 ]; then echo "нормально"; else echo "МЕДЛЕННО"; fi
}

# node_reality_check [кандидат ...] — отчёт: текущий dest (из Xray) и кандидаты, самый быстрый подходящий.
node_reality_check() {
    local cur cands d sn lbl p ms tls h2 best="" best_ms=999999 cur_ms="" line
    command -v curl >/dev/null 2>&1 || { echo "нужен curl"; return 1; }
    cur="$(node_reality_dests)"
    cands="${*:-$NODE_REALITY_CANDIDATES}"
    echo "REALITY dest: сколько нода ждёт при КАЖДОМ подключении клиента (TCP + TLS 1.3 до dest, медиана 5 замеров)"
    echo "  подходит как dest: TLS 1.3 и HTTP/2; меньше мс — быстрее открывается каждое соединение VPN"
    echo
    if [ -n "$cur" ]; then
        echo "  текущий (из работающего Xray):"
        while IFS=$'\t' read -r d sn; do
            [ -n "$d" ] || continue
            lbl="$d"; [ -n "$sn" ] && [ "${d%:*}" != "$sn" ] && lbl="$d (SNI $sn)"
            case "$d" in /*|@*|127.*) lbl="$lbl, selfsteal на этой ноде" ;; esac
            p="$(node_reality_probe "$d" "$sn")"
            if [ -z "$p" ]; then printf '    %s\n      недоступен с ноды или без TLS 1.3 для этого SNI — REALITY с таким dest не работает\n' "$lbl"; continue; fi
            read -r ms tls h2 <<<"$p"
            printf '    %-32s %5s мс   TLS1.3 %s  h2 %s   %s\n' "$lbl" "$ms" "$tls" "$h2" "$(_node_reality_verdict "$ms")"
            # несколько REALITY-инбаундов: сравниваем с самым медленным dest — тормозит он
            if [ -z "$cur_ms" ] || [ "$ms" -gt "$cur_ms" ]; then cur_ms="$ms"; fi
        done <<<"$cur"
    else
        echo "  текущий dest не найден (Xray не запущен или нет REALITY-инбаундов) — только кандидаты"
    fi
    echo
    echo "  варианты с этой ноды:"
    for d in $cands; do
        case "$d" in *:*) : ;; *) d="$d:443" ;; esac
        cut -f1 <<<"$cur" | grep -qxF -- "$d" && continue
        p="$(node_reality_probe "$d")"
        if [ -z "$p" ]; then printf '    %-32s недоступен или без TLS 1.3\n' "$d"; continue; fi
        read -r ms tls h2 <<<"$p"
        line="$(_node_reality_verdict "$ms")"; [ "$h2" = yes ] || line="без HTTP/2 — не подходит"
        printf '    %-32s %5s мс   TLS1.3 %s  h2 %s   %s\n' "$d" "$ms" "$tls" "$h2" "$line"
        if [ "$h2" = yes ] && [ "$ms" -lt "$best_ms" ]; then best="$d"; best_ms="$ms"; fi
    done
    echo
    if [ -n "$best" ] && [ -n "$cur_ms" ] && [ $((cur_ms - best_ms)) -ge 20 ]; then
        echo "  Быстрее текущего: $best — $best_ms мс против $cur_ms мс, то есть минус ~$((cur_ms - best_ms)) мс на каждом новом соединении."
        echo "  Меняется в панели Remnawave: профиль конфигурации -> realitySettings: dest (target) и serverNames"
        echo "  (новый сайт); клиенты получат его с обновлением подписки. Стек конфиг Xray не меняет."
    elif [ -n "$cur_ms" ]; then
        echo "  Текущий dest не медленнее вариантов (разница < 20 мс) — менять не нужно."
    elif [ -n "$best" ]; then
        echo "  Самый быстрый подходящий с этой ноды: $best ($best_ms мс)."
    fi
    return 0
}
