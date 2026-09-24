#!/bin/bash
# node — тест: заметное напоминание о reboot после установки XanMod (v1.1.4).
#   баннер: жирный жёлтый только на TTY (script -qec = настоящий pty), без ANSI
#   в пайп/лог и при NO_COLOR; после УСПЕШНОГО apt install — маркер в state и баннер
#   (после apt, перед y/N-промптом); при сбое apt — ни маркера, ни баннера;
#   «ожидает reboot» = маркер + пакет XanMod + активно не-XanMod ядро (в т.ч. после
#   reboot, где GRUB поднял старое ядро и /run-маркер исчез); status — баннер в
#   самом верху; node_xanmod_remove снимает маркер. Авто-reboot не вызывается.
# Сценарии установки/status — в `unshare -m` (tmpfs поверх /etc/apt, /etc/default,
# /run, /var/lib, /var/log): хост не затрагивается. Без root — только unit-часть.
set -euo pipefail
if [ "$(id -u)" -eq 0 ] && [ "${NODE_TEST_IN_NS:-0}" != "1" ] && unshare -m true 2>/dev/null; then
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
IN_NS="${NODE_TEST_IN_NS:-0}"
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-reboot114
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log" NODE_NO_REBOOT_PROMPT=1
: > "$NODE_LOG"
REAL_UNAME="$(command -v uname)"
cat > "$OUT/bin/uname" <<EOF
#!/bin/sh
case "\$1" in -r) echo "\${FAKE_UNAME_R:-6.1.0-18-amd64}" ;; -m) echo x86_64 ;; *) exec "$REAL_UNAME" "\$@" ;; esac
EOF
cat > "$OUT/bin/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = "-l" ] && [ "${FAKE_XANMOD_PKG:-0}" = 1 ] && echo "ii  linux-image-6.12.9-x64v3-xanmod1  6.12.9  amd64  Linux kernel"
exit 0
EOF
cat > "$OUT/bin/apt-get" <<'EOF'
#!/bin/sh
echo "APT-GET $*" >&2; echo "$*" >> "$APTLOG"
case "$*" in *install*) exit "${FAKE_APT_RC:-0}" ;; *update*) exit "${FAKE_APT_UPDATE_RC:-0}" ;; esac; exit 0
EOF
printf '#!/bin/sh\necho "-----BEGIN PGP-----"\n' > "$OUT/bin/wget"
printf '#!/bin/sh\ncat >/dev/null; echo KEY\n' > "$OUT/bin/gpg"
printf '#!/bin/sh\necho "Generating grub configuration file ..." >&2\n' > "$OUT/bin/update-grub"
printf '#!/bin/sh\necho "REBOOT-CALLED $*" >> "%s/reboot.called"\nexit 0\n' "$OUT" > "$OUT/bin/systemctl"
cp "$OUT/bin/systemctl" "$OUT/bin/reboot"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH" APTLOG="$OUT/apt.log"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"
printf 'ENABLE_XANMOD=1\nXANMOD_VARIANT=v3\n' > "$OUT/node.conf"; NODE_CONFIG="$OUT/node.conf" node_load_config >/dev/null 2>&1
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/kernel.sh"

fails=0
t() { local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
ESC=$'\033'

# ---------- баннер: цвет только на TTY ----------
node_reboot_notice "TEST MSG" 2> "$OUT/pipe.txt"
t "баннер в пайп: текст «>>> TEST MSG <<<» + рамка" 'grep -qx ">>> TEST MSG <<<" "$OUT/pipe.txt" && [ "$(grep -c "^=\{70\}$" "$OUT/pipe.txt")" = 2 ]'
t "баннер в пайп/лог: БЕЗ ANSI escape-кодов" '! grep -q "$ESC" "$OUT/pipe.txt"'
if command -v script >/dev/null 2>&1; then
    TERM=xterm script -qec "bash -c 'source $NODE_DIR/lib/common.sh; source $NODE_DIR/lib/kernel.sh; node_reboot_notice COLORED 1'" /dev/null > "$OUT/tty.txt" 2>&1 || true
    t "баннер на TTY (pty): жирный жёлтый ESC[1;33m ... ESC[0m" 'grep -q "${ESC}\[1;33m>>> COLORED <<<${ESC}\[0m" "$OUT/tty.txt"'
    NO_COLOR=1 TERM=xterm script -qec "bash -c 'source $NODE_DIR/lib/common.sh; source $NODE_DIR/lib/kernel.sh; node_reboot_notice PLAIN 1'" /dev/null > "$OUT/nc.txt" 2>&1 || true
    t "NO_COLOR=1 на TTY: без цвета" 'grep -q ">>> PLAIN <<<" "$OUT/nc.txt" && ! grep -q "${ESC}\[1;33m" "$OUT/nc.txt"'
else echo "skip - TTY-цвет (нет script)"; fi

# ---------- «ожидает reboot»: условие ----------
MK="$(node_xanmod_pending_file)"
t "маркер лежит в \$NODE_STATE_DIR" '[ "$MK" = "$NODE_STATE_DIR/pending-reboot-xanmod" ]'
printf 'ts\tlinux-xanmod-lts-x64v3\t6.1.0-18-amd64\n' > "$MK"
t "маркер + пакет + стоковое ядро => ожидает reboot"          'FAKE_XANMOD_PKG=1 node_xanmod_reboot_pending'
t "активно XanMod-ядро => НЕ ожидает"                         '! FAKE_XANMOD_PKG=1 FAKE_UNAME_R=6.12.9-x64v3-xanmod1 node_xanmod_reboot_pending'
t "пакет XanMod не установлен (удалён) => НЕ ожидает"         '! FAKE_XANMOD_PKG=0 node_xanmod_reboot_pending'
rm -f "$MK"
t "нет маркера => НЕ ожидает"                                 '! FAKE_XANMOD_PKG=1 node_xanmod_reboot_pending'
t "apply: в конце баннер при ожидании + снятие устаревшего маркера" \
  'grep -q "node_xanmod_reboot_pending; } && ! node_kernel_is_xanmod" "$NODE_DIR/apply.sh" && grep -q "node_reboot_notice \"XanMod установлен, но активно старое ядро" "$NODE_DIR/apply.sh" && grep -q "маркер ожидания reboot снят" "$NODE_DIR/apply.sh"'

# ---------- реальная установка (mocks) ----------
if [ "$IN_NS" != "1" ]; then
    echo "skip - установка/status/remove (нужен root + unshare -m)"
else
    for d in /etc/apt /etc/default /run /var/lib /var/log; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
    mkdir -p /etc/apt/sources.list.d /etc/apt/keyrings /etc/apt/preferences.d; echo 'GRUB_DEFAULT=0' > /etc/default/grub
    # успех
    : > "$APTLOG"; rc=0; node_xanmod_install > "$OUT/inst.txt" 2>&1 || rc=$?
    t "установка: rc 0"                                          '[ "$rc" = 0 ]'
    t "установка: пакет ставился через apt-get install"          'grep -q "install -y --no-install-recommends linux-xanmod" "$APTLOG"'
    t "установка: маркер записан (время, пакет, старое ядро)"   'awk -F"\t" "NF==3 && \$2 ~ /xanmod/ && \$3 == \"6.1.0-18-amd64\"" "$MK" | grep -q .'
    t "установка: баннер «>>> XanMod установлен … REBOOT» выведен" 'grep -q "^>>> XanMod установлен (linux-xanmod.*ТРЕБУЕТСЯ REBOOT.*sudo reboot.*<<<$" "$OUT/inst.txt"'
    a=$(grep -n "APT-GET .*install -y" "$OUT/inst.txt" | head -1 | cut -d: -f1); g=$(grep -n "Generating grub" "$OUT/inst.txt" | head -1 | cut -d: -f1); b=$(grep -n "^>>> XanMod" "$OUT/inst.txt" | head -1 | cut -d: -f1)
    t "порядок: apt install -> update-grub -> баннер (не утонет в выводе grub)" '[ "${a:-0}" -lt "${g:-0}" ] && [ "${g:-0}" -lt "${b:-0}" ]'
    t "/run/node/reboot-required тоже выставлен (прежнее поведение)" '[ -f /run/node/reboot-required ]'
    t "НИКАКОГО авто-reboot"                                     '[ ! -e "$OUT/reboot.called" ]'
    # 2026-09-24 (v1.1.6): ключ XanMod — в /etc/apt/keyrings + signed-by (доверие ТОЛЬКО этому репо);
    # в /etc/apt/trusted.gpg.d он был доверен для ЛЮБОГО репозитория
    # suite — кодовое имя дистрибутива (прежний `releases` XanMod убрал: 404)
    t "ключ XanMod: /etc/apt/keyrings, репо с signed-by и suite=VERSION_CODENAME, в trusted.gpg.d ничего" \
      '[ -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ] && grep -q "^deb \[signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg\] http://deb.xanmod.org $(. /etc/os-release; echo $VERSION_CODENAME) main" /etc/apt/sources.list.d/xanmod-kernel.list && ! ls /etc/apt/trusted.gpg.d/xanmod* >/dev/null 2>&1'
    # 2026-09-24 (v1.1.6): сбой apt update (нет suite/сеть) — свой репо и ключ убраны,
    # apt хоста не остаётся с битым источником
    rm -f "$MK" /run/node/reboot-required; rc=0; FAKE_APT_UPDATE_RC=100 node_xanmod_install > "$OUT/upd.txt" 2>&1 || rc=$?
    t "сбой apt update: rc 1, репо и ключ XanMod убраны" '[ "$rc" = 1 ] && [ ! -e /etc/apt/sources.list.d/xanmod-kernel.list ] && [ ! -e /etc/apt/keyrings/xanmod-archive-keyring.gpg ]'
    # сбой apt install
    rm -f "$MK" /run/node/reboot-required; rc=0; FAKE_APT_RC=100 node_xanmod_install > "$OUT/fail.txt" 2>&1 || rc=$?
    t "сбой apt install: rc 1, НЕТ маркера и НЕТ баннера"        '[ "$rc" = 1 ] && [ ! -e "$MK" ] && ! grep -q "^>>> XanMod" "$OUT/fail.txt"'
    # status через реальную точку входа: маркер в /var/lib/node, /run-маркера НЕТ (reboot, GRUB поднял старое ядро)
    mkdir -p /var/lib/node; printf 'ts\tlinux-xanmod-lts-x64v3\t6.1.0-18-amd64\n' > /var/lib/node/pending-reboot-xanmod; rm -rf /run/node
    FAKE_XANMOD_PKG=1 bash "$NODE_DIR/main.sh" status > "$OUT/st.txt" 2>&1 || true
    t "status: баннер «kernel: XanMod установлен (…), ОЖИДАЕТ REBOOT»" 'grep -q "^>>> kernel: XanMod установлен (linux-xanmod-lts-x64v3), ОЖИДАЕТ REBOOT" "$OUT/st.txt"'
    n=$(grep -n "^>>> kernel: XanMod" "$OUT/st.txt" | cut -d: -f1); h=$(grep -n "^node v1" "$OUT/st.txt" | cut -d: -f1)
    t "status: баннер сразу под заголовком (самый верх)"         '[ -n "$n" ] && [ -n "$h" ] && [ $((n - h)) -le 2 ]'
    t "status: нижняя строка «reboot: ТРЕБУЕТСЯ» без /run-маркера" 'grep -q "^reboot: ТРЕБУЕТСЯ" "$OUT/st.txt"'
    # (обычные warn-строки проекта окрашены логгером всегда — это прежнее поведение;
    #  проверяем именно баннер: рамка и строка «>>> … <<<» без ANSI вне TTY)
    t "status в файл: баннер без ANSI" '! grep -E "^(>>> kernel|={70})" "$OUT/st.txt" | grep -q "$ESC"'
    t "лог-файл: баннера/ANSI в /var/log нет (только plain warn)" '! grep -q "$ESC" "$NODE_LOG"'
    FAKE_XANMOD_PKG=1 FAKE_UNAME_R=6.12.9-x64v3-xanmod1 bash "$NODE_DIR/main.sh" status > "$OUT/st2.txt" 2>&1 || true
    t "status: XanMod уже активно — баннера нет"                 '! grep -q "ОЖИДАЕТ REBOOT" "$OUT/st2.txt"'
    # откат XanMod снимает маркер
    printf 'ts\tp\tk\n' > "$MK"; node_xanmod_remove > /dev/null 2>&1 || true
    t "node_xanmod_remove: маркер снят"                          '[ ! -e "$MK" ]'
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: reboot-notice (all checks)"; else echo "FAILED: $fails проверок"; exit 1; fi
