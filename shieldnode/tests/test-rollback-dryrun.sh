#!/bin/bash
# shieldnode — тест: `rollback --dry-run` и `uninstall --dry-run` ничего не меняют. 2026-11-14 (v1.2.11).
# До этой версии под --dry-run были прикрыты только systemctl, nft и stack.conf: файлы по манифесту удалялись
# и возвращались, sysctl возвращались, манифест и оба реестра обнулялись по-настоящему — «пробный» откат на
# живом сервере выполнял откат наполовину.
# Проверяется на песочнице «после apply» (манифест, реестр происхождения, sysctl-orig.tsv, owner-keys,
# снимок detect, stack.conf, копии .pre-shieldnode-*):
#   1) после `rollback --dry-run`, `rollback <набор> --dry-run` и `uninstall --dry-run` каждый файл песочницы
#      тот же байт в байт и с тем же временем изменения; ни одного изменяющего вызова systemctl / nft / sysctl;
#   2) напечатано, что было бы сделано: по строке на файл и на каждую настройку ядра;
#   3) настоящий откат после этого делает ровно то, что обещал пробный: те же файлы удалены, те же
#      возвращены из тех же источников, те же `sysctl -w`.
# Безопасность самого теста: под root уходит в `unshare -mn` и сам это проверяет; tmpfs поверх всех каталогов,
# куда пишет откат; systemctl, nft и sysctl — заглушки.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${SHIELD_TEST_IN_NS:-0}" != "1" ]; then
    unshare -mn true 2>/dev/null || { echo "SKIP: unshare -mn недоступен"; exit 77; }
    SHIELD_TEST_IN_NS=1 exec unshare -mn bash "$0" "$@"
fi
# дальше — настоящий откат в /etc, /usr/local/sbin и /var/lib: только в своих mount- и net-пространствах
# (переменная SHIELD_TEST_IN_NS, выставленная снаружи руками, не должна пустить тест на настоящий сервер)
for ns in mnt net; do
    if [ "$(readlink "/proc/$$/ns/$ns")" = "$(readlink "/proc/1/ns/$ns" 2>/dev/null || true)" ]; then
        echo "FAIL: тест не в своём пространстве ($ns) — останов, чтобы не тронуть настоящий сервер"; exit 1
    fi
done
DIRS="/etc/systemd/system /etc/sysctl.d /etc/nftables.d /etc/shieldnode /etc/node-profile.d /usr/local/sbin /var/lib/shieldnode /run"
for d in $DIRS /var/log; do
    mkdir -p "$d"; mount -t tmpfs t "$d"
done

SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/shieldnode-test-rollback-dryrun
rm -rf "$OUT"; mkdir -p "$OUT/bin"
S=/var/lib/shieldnode
SEC=/etc/sysctl.d/99-z5-shieldnode-security.conf
unset SHIELD_STATE_DIR SHIELD_MANIFEST SHIELD_CONFIG SHIELD_EXCLUDE SHIELD_LOG SHIELD_LOCK DRY_RUN

# заглушки: каждый вызов — в свой журнал; чтение (`sysctl -n`, `nft list`) отвечает пустым успехом
for c in systemctl nft sysctl; do
    printf '#!/bin/sh\necho "$*" >> "%s/%s.log"\nexit 0\n' "$OUT" "$c" > "$OUT/bin/$c"
done
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/logger"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

# --- песочница «после apply» -------------------------------------------------------------------------------
own() { printf '%s\n' "$2" > "$1"; echo "$1" >> "$S/applied-files.txt"; printf '%s\tcreated\n' "$1" >> "$S/file-origins.tsv"; }
build() {
    local d
    for d in $DIRS; do find "$d" -mindepth 1 -delete; done
    mkdir -p "$S/origins" "$S/diagnostics" /run/shieldnode
    : > "$S/applied-files.txt"; : > "$S/file-origins.tsv"
    # созданы shieldnode
    own /etc/systemd/system/shieldnode.service "[Unit]"
    own /etc/systemd/system/shieldnode-cleanup.timer "[Timer]"
    own "$SEC" "net.ipv4.tcp_rfc1337 = 1"; echo "net.ipv4.conf.all.rp_filter = 1" >> "$SEC"
    ln -s "$SHIELD_DIR/main.sh" /usr/local/sbin/guard
    echo /usr/local/sbin/guard >> "$S/applied-files.txt"; printf '%s\tcreated\n' /usr/local/sbin/guard >> "$S/file-origins.tsv"
    # был до shieldnode: исходное состояние — в реестре происхождения
    echo "AFTER" > /etc/nftables.d/shieldnode.nft; echo "BEFORE" > "$S/origins/etc_nftables.d_shieldnode.nft"
    echo /etc/nftables.d/shieldnode.nft >> "$S/applied-files.txt"
    printf '%s\t%s\n' /etc/nftables.d/shieldnode.nft "$S/origins/etc_nftables.d_shieldnode.nft" >> "$S/file-origins.tsv"
    # в реестре происхождения нет, рядом — копия прежней версии
    echo "NEW" > /etc/nftables.d/legacy.nft; echo "OLD" > /etc/nftables.d/legacy.nft.pre-shieldnode-20261101-000000
    echo /etc/nftables.d/legacy.nft >> "$S/applied-files.txt"
    # ни реестра, ни копии
    echo "#!/bin/sh" > /usr/local/sbin/shieldnode-blocklist; echo /usr/local/sbin/shieldnode-blocklist >> "$S/applied-files.txt"
    # операторский конфиг в манифесте и запись о файле, которого уже нет
    echo "SSH_PORT=22" > /etc/shieldnode/config.conf; echo /etc/shieldnode/config.conf >> "$S/applied-files.txt"
    echo /etc/systemd/system/gone.service >> "$S/applied-files.txt"
    # юнит, которого нет в манифесте (остался бы после отката — его снимает uninstall)
    echo "[Unit]" > /etc/systemd/system/shieldnode-ports.service
    # настройки ядра: исходные значения (реестр) и снимок detect
    printf 'net.ipv4.tcp_rfc1337\t0\n' > "$S/sysctl-orig.tsv"
    printf 'net.ipv4.tcp_rfc1337\nnet.ipv4.conf.all.rp_filter\n' > "$S/owner-keys.txt"
    printf '## sysctl-managed-baseline\nnet.ipv4.tcp_rfc1337 = 0\nnet.ipv4.conf.all.rp_filter = 2\n## end\n' > "$S/diagnostics/20261101-000000.txt"
    echo "crowdsec-firewall-bouncer.service" > "$S/foreign-bouncer.removed"
    printf '[node]\nversion=1\n[shieldnode]\nversion=1.2.10\n' > /etc/node-profile.d/stack.conf
    : > /run/shieldnode/emergency
    # время изменения — в прошлом: перезапись тем же содержимым тоже будет видна
    find $DIRS -mindepth 1 \( -type f -o -type d \) -exec touch -d '2026-11-01 00:00:00' {} +
    rm -f "$OUT"/systemctl.log "$OUT"/nft.log "$OUT"/sysctl.log
}
# снимок песочницы: файлы (sha256, права, время изменения), ссылки и каталоги; lock — служебный, не в счёт
snap() {
    local p
    find $DIRS -mindepth 1 ! -name '*.lock' -print0 | sort -z | while IFS= read -r -d '' p; do
        if [ -L "$p" ]; then echo "L $p -> $(readlink "$p")"
        elif [ -d "$p" ]; then echo "D $p"
        else echo "F $p $(sha256sum < "$p" | cut -c1-64) $(stat -c '%a %Y' "$p")"; fi
    done
}
main() { bash "$SHIELD_DIR/main.sh" "$@"; }
fails=0
t() { local name="$1"; shift
    if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
# ни одного изменяющего вызова: systemctl — кроме чтения, nft — кроме list, sysctl — кроме -n
quiet() {
    ! grep -qvE '^(is-active|is-enabled|show|status|list-|cat) ' "$OUT/systemctl.log" 2>/dev/null \
        && ! grep -qvE '^(-[a-z]+ )*list ' "$OUT/nft.log" 2>/dev/null && ! grep -qvE '^-n ' "$OUT/sysctl.log" 2>/dev/null
}
same() { snap > "$OUT/after.snap"; cmp -s "$OUT/before.snap" "$OUT/after.snap"; }
has() { grep -qF -- "$1" "$2"; }

# ================= 1. rollback --dry-run =================
build; snap > "$OUT/before.snap"
rc=0; main rollback --dry-run > "$OUT/dry.out" 2>&1 || rc=$?
t "rollback --dry-run: rc=0" "[ $rc = 0 ]"
t "rollback --dry-run: все файлы песочницы те же (манифест, реестры, файлы из манифеста, копии, stack.conf)" "same"
t "rollback --dry-run: ни одного изменяющего вызова systemctl / nft / sysctl" "quiet"
t "сказано: файл, созданный shieldnode, был бы удалён" \
    "has 'would remove /etc/systemd/system/shieldnode.service (создан shieldnode)' $OUT/dry.out && has 'would remove $SEC (создан shieldnode)' $OUT/dry.out && has 'would remove /usr/local/sbin/guard (создан shieldnode)' $OUT/dry.out"
t "сказано: файл, бывший до shieldnode, был бы возвращён из реестра происхождения" \
    "has 'would restore /etc/nftables.d/shieldnode.nft <- $S/origins/etc_nftables.d_shieldnode.nft' $OUT/dry.out"
t "сказано: файл без записи в реестре был бы возвращён из копии рядом" \
    "has 'would restore /etc/nftables.d/legacy.nft <- /etc/nftables.d/legacy.nft.pre-shieldnode-20261101-000000' $OUT/dry.out"
t "сказано: файл без реестра и без копии был бы удалён; операторский конфиг остаётся" \
    "grep -q 'would remove /usr/local/sbin/shieldnode-blocklist\$' $OUT/dry.out && has 'операторский /etc/shieldnode/config.conf оставлен' $OUT/dry.out && ! has 'gone.service' $OUT/dry.out"
t "сказано: настройки ядра — из реестра исходных значений и из снимка (файл с ними был бы удалён)" \
    "has 'would sysctl -w net.ipv4.tcp_rfc1337=0' $OUT/dry.out && has 'would sysctl -w net.ipv4.conf.all.rp_filter=2' $OUT/dry.out && [ \"\$(grep -c 'would sysctl -w' $OUT/dry.out)\" = 2 ]"
t "сказано: службы и фаервол, чужой bouncer, раздел stack.conf" \
    "has 'would: disable timers/service, delete table inet shieldnode' $OUT/dry.out && has 'would enable back foreign crowdsec bouncer: crowdsec-firewall-bouncer.service' $OUT/dry.out && has 'would remove section [shieldnode] from /etc/node-profile.d/stack.conf' $OUT/dry.out"
t "итог — «ничего не изменено», а не «rollback завершён»" "has 'rollback: ничего не изменено' $OUT/dry.out && ! has 'rollback завершён' $OUT/dry.out"

# ================= 2. rollback <набор> --dry-run =================
build; snap > "$OUT/before.snap"
rc=0; main rollback 20261101-000000 --dry-run > "$OUT/dry-id.out" 2>&1 || rc=$?
t "rollback <набор> --dry-run: rc=0, файлы те же, изменяющих вызовов нет" "[ $rc = 0 ] && same && quiet"
t "rollback <набор> --dry-run: реестр происхождения не используется — копия рядом или удаление" \
    "has 'would restore /etc/nftables.d/legacy.nft <- /etc/nftables.d/legacy.nft.pre-shieldnode-20261101-000000' $OUT/dry-id.out && grep -q 'would remove /etc/nftables.d/shieldnode.nft\$' $OUT/dry-id.out"

# ================= 3. uninstall --dry-run =================
build; snap > "$OUT/before.snap"
rc=0; main uninstall --dry-run > "$OUT/dry-un.out" 2>&1 || rc=$?
t "uninstall --dry-run: rc=0" "[ $rc = 0 ]"
t "uninstall --dry-run: все файлы песочницы те же, каталог состояния на месте" "same && [ -s $S/applied-files.txt ]"
t "uninstall --dry-run: ни одного изменяющего вызова systemctl / nft / sysctl" "quiet"
t "uninstall --dry-run: названо то же, что у отката, каталог состояния и юнит мимо манифеста" \
    "has 'would remove /etc/systemd/system/shieldnode.service (создан shieldnode)' $OUT/dry-un.out && has 'would rm -rf $S' $OUT/dry-un.out && has 'would remove /etc/systemd/system/shieldnode-ports.service (нет в манифесте)' $OUT/dry-un.out"
t "uninstall --dry-run: юнит из манифеста второй раз не назван" "[ \"\$(grep -c 'would remove /etc/systemd/system/shieldnode.service' $OUT/dry-un.out)\" = 1 ]"
t "uninstall --dry-run: итог — «ничего не изменено», а не «shieldnode удалён»" "has 'uninstall: ничего не изменено' $OUT/dry-un.out && ! has 'shieldnode удалён' $OUT/dry-un.out"

# ================= 4. настоящий откат делает ровно то, что обещал пробный =================
build
main rollback --dry-run > "$OUT/promise.out" 2>&1 || true
sed -nE 's/.*would remove (\/[^ ]+).*/\1/p' "$OUT/promise.out" | sort > "$OUT/promise.rm"
sed -nE 's/.*would restore (\/[^ ]+) <- (\/[^ ]+).*/\1 \2/p' "$OUT/promise.out" | sort > "$OUT/promise.cp"
sed -nE 's/.*would sysctl -w ([^ ]+).*/-w \1/p' "$OUT/promise.out" | sort > "$OUT/promise.sysctl"
# содержимое источников — до отката (реестр происхождения откат потом стирает)
while read -r dst src; do echo "$dst $(sha256sum < "$src" | cut -c1-64)"; done < "$OUT/promise.cp" > "$OUT/promise.sha"
rm -f "$OUT"/systemctl.log "$OUT"/nft.log "$OUT"/sysctl.log
rc=0; main rollback > "$OUT/real.out" 2>&1 || rc=$?
t "настоящий rollback: rc=0, «rollback завершён»" "[ $rc = 0 ] && has 'rollback завершён' $OUT/real.out"
t "настоящий rollback: удалены ровно обещанные файлы (их 5)" \
    "[ \"\$(grep -c . $OUT/promise.rm)\" = 5 ] && while read -r f; do [ ! -e \"\$f\" ] && [ ! -L \"\$f\" ] || exit 1; done < $OUT/promise.rm"
t "настоящий rollback: возвращены ровно обещанные файлы из обещанных источников (их 2)" \
    "[ \"\$(grep -c . $OUT/promise.sha)\" = 2 ] && while read -r f h; do [ \"\$(sha256sum < \"\$f\" | cut -c1-64)\" = \"\$h\" ] || exit 1; done < $OUT/promise.sha"
t "настоящий rollback: те же sysctl -w, что обещаны" "grep '^-w ' $OUT/sysctl.log | sort | cmp -s - $OUT/promise.sysctl && [ -s $OUT/promise.sysctl ]"
t "настоящий rollback: манифест пуст, реестры убраны, раздел [shieldnode] убран, операторский конфиг и юнит мимо манифеста на месте" \
    "[ ! -s $S/applied-files.txt ] && [ ! -e $S/file-origins.tsv ] && [ ! -e $S/sysctl-orig.tsv ] && ! grep -q shieldnode /etc/node-profile.d/stack.conf && grep -q '^\[node\]' /etc/node-profile.d/stack.conf && [ -f /etc/shieldnode/config.conf ] && [ -f /etc/systemd/system/shieldnode-ports.service ]"
t "настоящий rollback: службы выключены, таблица снята" "grep -q '^disable --now shieldnode.service' $OUT/systemctl.log && grep -q 'delete table inet shieldnode' $OUT/nft.log"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rollback-dryrun (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
