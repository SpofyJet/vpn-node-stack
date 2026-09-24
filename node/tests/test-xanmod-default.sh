#!/bin/bash
# node — тест: ENABLE_XANMOD=1 по умолчанию (решение оператора 2026-09-24, v1.1.6).
# Дефолт (ключа нет в node.conf) — «мягкий»: неподдерживаемая платформа, ядро уже с
# BBRv3 (tcp_bbr version 3), нет suite XanMod для дистрибутива (jammy — 404), сбой сети —
# info/warn и пропуск, apply НЕ падает. Уже настроенный чужой источник XanMod не
# дублируется (ключ другого инструмента не перезаписывается). Явный ENABLE_XANMOD=1
# в node.conf — строгий режим как прежде (die/rc 1). Авто-reboot не вызывается.
# Под root: `unshare -m`, tmpfs поверх /etc/apt, /etc/default, /run, /var/lib, /var/log.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: unshare -m недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
for d in /etc/apt /etc/default /run /var/lib /var/log; do mkdir -p "$d"; mount -t tmpfs t "$d"; done
NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/state"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_LOG="$OUT/node.log" NODE_NO_REBOOT_PROMPT=1 APTLOG="$OUT/apt.log"
: > "$NODE_LOG"
REAL_UNAME="$(command -v uname)"
cat > "$OUT/bin/uname" <<EOF
#!/bin/sh
case "\$1" in -r) echo "\${FAKE_UNAME_R:-6.8.0-60-generic}" ;; -m) echo "\${FAKE_ARCH:-x86_64}" ;; *) exec "$REAL_UNAME" "\$@" ;; esac
EOF
cat > "$OUT/bin/apt-get" <<'EOF'
#!/bin/sh
echo "$*" >> "$APTLOG"
case "$*" in *install*) exit "${FAKE_APT_RC:-0}" ;; *update*) exit "${FAKE_APT_UPDATE_RC:-0}" ;; esac; exit 0
EOF
cat > "$OUT/bin/modinfo" <<'EOF'
#!/bin/sh
# tcp_bbr: версия модуля из FAKE_BBR_VERSION (пусто = стоковый v1 без поля version)
case "$*" in *"-F version tcp_bbr"*) [ -n "${FAKE_BBR_VERSION:-}" ] && echo "$FAKE_BBR_VERSION"; exit 0 ;; esac
exit 1
EOF
printf '#!/bin/sh\necho "-----BEGIN PGP-----"\n' > "$OUT/bin/wget"
printf '#!/bin/sh\ncat >/dev/null; echo KEY\n' > "$OUT/bin/gpg"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/update-grub"
printf '#!/bin/sh\necho "REBOOT $*" >> "%s/reboot.called"\nexit 0\n' "$OUT" > "$OUT/bin/systemctl"
cp "$OUT/bin/systemctl" "$OUT/bin/reboot"
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
LIST=/etc/apt/sources.list.d/xanmod-kernel.list KEY=/etc/apt/keyrings/xanmod-archive-keyring.gpg
fresh() { rm -rf /etc/apt/* /var/lib/node "$OUT/state"/*; mkdir -p /etc/apt/sources.list.d /etc/apt/keyrings /etc/apt/preferences.d
          echo 'GRUB_DEFAULT=0' > /etc/default/grub; : > "$APTLOG"; }
inst() { # inst <node.conf content> [env...] -> rc установки (в subshell: die не роняет тест)
    printf '%b' "$1" > "$OUT/node.conf"; shift
    ( export NODE_CONFIG="$OUT/node.conf" "$@"
      source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1
      source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/cpu.sh"; source "$NODE_DIR/lib/kernel.sh"
      node_xanmod_install ) > "$OUT/inst.out" 2>&1
}

fresh; ( source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; NODE_CONFIG="$OUT/none" node_load_config >/dev/null 2>&1
         node_conf_get ENABLE_XANMOD 0 ) > "$OUT/def" 2>/dev/null || true
t "дефолт: ENABLE_XANMOD=1 (node.defaults.conf)" "[ \"\$(cat $OUT/def)\" = 1 ]"

fresh; rc=0; inst '' || rc=$?
t "дефолт, noble x86_64: XanMod ставится (repo со signed-by + apt install)" \
  "[ $rc = 0 ] && grep -q 'signed-by=$KEY' $LIST && grep -q 'install -y --no-install-recommends linux-xanmod' $APTLOG"
t "дефолт: авто-reboot НЕ вызывается" "[ ! -e $OUT/reboot.called ]"

fresh; rc=0; inst '' FAKE_ARCH=aarch64 || rc=$?
t "дефолт, aarch64: пропуск без ошибки (rc 0), apt не вызывался" "[ $rc = 0 ] && [ ! -s $APTLOG ] && [ ! -e $LIST ]"
fresh; rc=0; inst 'ENABLE_XANMOD=1\n' FAKE_ARCH=aarch64 || rc=$?
t "явный ENABLE_XANMOD=1, aarch64: как прежде — ошибка" "[ $rc != 0 ]"

# 2026-09-24 (v1.1.7): мейнлайн НЕ содержит BBRv3 (torvalds/master tcp_bbr.c — v1, без
# inflight_lo/версии); прежнее «ядро >= 6.15 -> BBRv3 уже есть» было ложным. Стоковое 6.16
# (tcp_bbr без version) -> XanMod по-прежнему ставится; ядро с tcp_bbr version 3 -> пропуск.
fresh; rc=0; inst '' FAKE_UNAME_R=6.16.2-generic || rc=$?
t "дефолт, стоковое 6.16 (мейнлайн BBR = v1): XanMod ставится" "[ $rc = 0 ] && grep -q 'install -y' $APTLOG"
fresh; rc=0; inst '' FAKE_UNAME_R=6.16.2-generic FAKE_BBR_VERSION=3 || rc=$?
t "дефолт, ядро уже с BBRv3 (tcp_bbr version 3): пропуск, apt не вызывался" "[ $rc = 0 ] && [ ! -s $APTLOG ]"
gen() { ( export "$@"; source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/lib/kernel.sh"; node_bbr_generation ) 2>/dev/null; }
export -f gen
t "node_bbr_generation: стоковое 6.16 без версии модуля -> 1" "[ \"\$(gen FAKE_UNAME_R=6.16.2-generic)\" = 1 ]"
t "node_bbr_generation: tcp_bbr version 3 (XanMod) -> 3" "[ \"\$(gen FAKE_UNAME_R=6.18.53-x64v3-xanmod1 FAKE_BBR_VERSION=3)\" = 3 ]"

fresh; rc=0; inst '' FAKE_APT_UPDATE_RC=100 || rc=$?
t "дефолт, нет suite/сети (apt update fail): rc 0, свой repo+ключ убраны" "[ $rc = 0 ] && [ ! -e $LIST ] && [ ! -e $KEY ]"
fresh; rc=0; inst 'ENABLE_XANMOD=1\n' FAKE_APT_UPDATE_RC=100 || rc=$?
t "явный ENABLE_XANMOD=1, apt update fail: как прежде — rc 1" "[ $rc = 1 ] && [ ! -e $LIST ]"
fresh; rc=0; inst '' FAKE_APT_RC=100 || rc=$?
t "дефолт, apt install fail: rc 0 (warn), apply не падает" "[ $rc = 0 ] && grep -q 'install' $APTLOG"

fresh; echo "deb [signed-by=$KEY] http://deb.xanmod.org noble main" > /etc/apt/sources.list.d/xanmod-release.list
echo FOREIGN-KEY > "$KEY"; rc=0; inst '' || rc=$?
t "чужой источник XanMod уже есть: свой не добавлен, чужой ключ не перезаписан, пакет ставится" \
  "[ $rc = 0 ] && [ ! -e $LIST ] && [ \"\$(cat $KEY)\" = FOREIGN-KEY ] && grep -q 'install -y' $APTLOG"

fresh; rc=0; inst 'ENABLE_XANMOD=0\n' || rc=$?
t "ENABLE_XANMOD=0 в node.conf: выключено (apt не вызывался)" "[ $rc = 0 ] && [ ! -s $APTLOG ]"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: xanmod-default (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
