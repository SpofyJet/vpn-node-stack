#!/bin/bash
# node — тест: fq tune реально меняет параметры fq по семантике ядра и откатывается.
# 2026-09-24 (v1.1.5): `tc qdisc change dev X root fq ...` ядро отвергает для
# дефолтного root-qdisc с handle 0: ("Qdisc not found. To create specify
# NLM_F_CREATE flag") — ошибка глушилась `2>/dev/null || true`, а apply писал
# "fq tuned" безусловно: на живой ноде fq оставался limit 10000p/flow_limit 100p/
# buckets 1024. Fake tc ниже повторяет ядро: change — только по ненулевому handle,
# replace — всегда.
# Под root: `unshare -m`, tmpfs поверх /usr/local/sbin и /etc/systemd/system.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "SKIP: нужен root"; exit 77; fi
command -v unshare >/dev/null 2>&1 || { echo "SKIP: нет unshare"; exit 77; }
if [ "${NODE_TEST_IN_NS:-0}" != "1" ]; then
    unshare -m true 2>/dev/null || { echo "SKIP: unshare -m недоступен"; exit 77; }
    NODE_TEST_IN_NS=1 exec unshare -m bash "$0" "$@"
fi
for d in /usr/local/sbin /etc/systemd/system; do mkdir -p "$d"; mount -t tmpfs t "$d"; done

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=/tmp/node-test-fq
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/state"
export NODE_DIR NODE_STATE_DIR="$OUT/state" NODE_DIAG_DIR="$OUT/state/diag" NODE_PROFILE_DIR="$OUT/profile.d"
export NODE_LOG="$OUT/node.log" NODE_RT_TWEAKS="$OUT/state/runtime-tweaks.tsv" NODE_CONFIG="$OUT/node.conf" DRY_RUN=0
: > "$NODE_LOG"; : > "$NODE_CONFIG"

# состояние fake-ядра: "<dev>\t<parent|root>\t<handle>\t<limit>\t<flow_limit>\t<buckets>"
printf 'ens9\troot\t0:\t10000\t100\t1024\n'   >  "$OUT/qdisc.db"
printf 'ens9\t1:2\t0:\t10000\t100\t1024\n'    >> "$OUT/qdisc.db"
printf 'ens8\t1:1\t10:\t10000\t100\t1024\n'   >> "$OUT/qdisc.db"
cat > "$OUT/bin/tc" <<EOF
#!/bin/bash
DB="$OUT/qdisc.db"
echo "\$*" >> "$OUT/tc.log"
[ "\$1" = qdisc ] || exit 1
op="\$2"; shift 2
if [ "\$op" = show ]; then
    awk -F'\t' '{ if (\$2 == "root") printf "qdisc fq %s dev %s root refcnt 2 limit %sp flow_limit %sp buckets %s\n", \$3, \$1, \$4, \$5, \$6;
                  else printf "qdisc fq %s dev %s parent %s limit %sp flow_limit %sp buckets %s\n", \$3, \$1, \$2, \$4, \$5, \$6 }' "\$DB"
    exit 0
fi
dev=""; where=""; handle=""; L=""; F=""; B=""
while [ \$# -gt 0 ]; do case "\$1" in
    dev) dev="\$2"; shift 2 ;; root) where=root; shift ;; parent) where="\$2"; shift 2 ;;
    handle) handle="\$2"; shift 2 ;; fq) shift ;; limit) L="\$2"; shift 2 ;;
    flow_limit) F="\$2"; shift 2 ;; buckets) B="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\${FAKE_TC_FAIL:-}" ] && { echo "Error: injected" >&2; exit 2; }
cur="\$(awk -F'\t' -v d="\$dev" -v w="\$where" '\$1 == d && \$2 == w' "\$DB")"
[ -n "\$cur" ] || { echo "Error: Qdisc not found." >&2; exit 2; }
curh="\$(printf '%s' "\$cur" | cut -f3)"
case "\$op" in
    change) # ядро: дефолтный qdisc (handle 0:) через change не адресуется
        if [ "\$curh" = "0:" ] || { [ -n "\$handle" ] && [ "\$handle" != "\$curh" ]; }; then
            echo "Error: Qdisc not found. To create specify NLM_F_CREATE flag." >&2; exit 2; fi
        newh="\$curh" ;;
    replace) newh="8001:" ;;
    *) exit 1 ;;
esac
awk -F'\t' -v OFS='\t' -v d="\$dev" -v w="\$where" -v h="\$newh" -v L="\$L" -v F="\$F" -v B="\$B" \
    '\$1 == d && \$2 == w { \$3 = h; if (L != "") \$4 = L; if (F != "") \$5 = F; if (B != "") \$6 = B } { print }' "\$DB" > "\$DB.new"
mv "\$DB.new" "\$DB"
EOF
for c in systemctl logger udevadm; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$c"; done
chmod +x "$OUT/bin"/*; export PATH="$OUT/bin:$PATH"

source "$NODE_DIR/lib/common.sh"; source "$NODE_DIR/config.sh"; node_load_config >/dev/null 2>&1 || true
source "$NODE_DIR/persist.sh"; source "$NODE_DIR/lib/datapath.sh"

fails=0
t() { local name="$1"; shift
    if bash -c "$1" >/dev/null 2>&1; then echo "ok   - $name"; else echo "FAIL - $name"; fails=$((fails+1)); fi; }
row() { awk -F'\t' -v d="$1" -v w="$2" '$1 == d && $2 == w { print $4 "/" $5 "/" $6 }' "$OUT/qdisc.db"; }
export -f row; export OUT

node_fq_tune_apply > "$OUT/apply.out" 2>&1 || true
t "root fq (handle 0:, дефолтный) — параметры реально применены" "[ \"\$(row ens9 root)\" = 100000/100/32768 ]"
t "mq-child с handle 0: — применены" "[ \"\$(row ens9 1:2)\" = 100000/100/32768 ]"
t "child с явным handle 10: — применены (change работает)" "[ \"\$(row ens8 1:1)\" = 100000/100/32768 ]"
t "rt-реестр: исходные параметры root записаны" "grep -qP '^ens9\tfq\troot\tlimit 10000 flow_limit 100 buckets 1024\$' $NODE_RT_TWEAKS"
t "rt-реестр: исходные параметры child записаны" "grep -qP '^ens9\tfq\tparent 1:2\tlimit 10000 flow_limit 100 buckets 1024\$' $NODE_RT_TWEAKS"

# повторный apply (rt-reapply): исходное значение в реестре НЕ перезаписано текущим
node_fq_tune_apply > /dev/null 2>&1 || true
t "re-apply: в реестре по-прежнему исходные (а не 100000)" "! grep -q 'limit 100000' $NODE_RT_TWEAKS && [ \$(grep -c \$'\tfq\t' $NODE_RT_TWEAKS) = 3 ]"

# rollback возвращает исходные параметры
node_rt_rollback > /dev/null 2>&1 || true
t "rollback: root fq вернулся к исходным" "[ \"\$(row ens9 root)\" = 10000/100/1024 ]"
t "rollback: child fq вернулся к исходным" "[ \"\$(row ens9 1:2)\" = 10000/100/1024 ]"

# tc отверг всё — «fq tuned» не врём, warn
: > "$NODE_LOG"
FAKE_TC_FAIL=1 node_fq_tune_apply > "$OUT/apply-fail.out" 2>&1 || true
t "отказ tc: без ложного 'fq tuned'" "! grep -q 'fq tuned' $OUT/apply-fail.out $NODE_LOG"
t "отказ tc: warn о неприменённом fq tune" "grep -q 'fq tune не применён' $OUT/apply-fail.out"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: fq-tune (all checks)"; else echo "FAILED: $fails checks"; exit 1; fi
