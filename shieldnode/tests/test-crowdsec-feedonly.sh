#!/bin/bash
# shieldnode — тест: crowdsec-agent в feed-only режиме (v1.2.6).
# Демон НЕ должен парсить локальные логи (acquisition) — только тянуть community
# blocklist по CAPI. Прод-регрессия: cscli setup оставляет acquis.d/setup.*.yaml
# (syslog/kern.log/auth.log) -> миллионы строк флода UFW парсились впустую.
# НЮАНС: crowdsec падает с FATAL "no datasource enabled" при ПОЛНОСТЬЮ пустом
# acquisition — поэтому вместо удаления всех источников ставим заглушку
# (пустой файл + yaml-дескриптор), проверяем и её присутствие.
set -euo pipefail
SHIELD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/bin" "$OUT/etc/acquis.d" "$OUT/state" "$OUT/varlog"
# systemctl-заглушка: is-active -> $FAKE_ACTIVE (0=active), остальное — в лог вызовов
printf '#!/bin/sh\necho "$*" >> "%s/systemctl.calls"\ncase "$*" in *is-active*) exit "${FAKE_ACTIVE:-3}" ;; *is-enabled*) exit "${FAKE_ENABLED:-0}" ;; esac\nexit 0\n' "$OUT" > "$OUT/bin/systemctl"
chmod +x "$OUT/bin/systemctl"; export PATH="$OUT/bin:$PATH"
export SHIELD_DIR SHIELD_LOG="$OUT/log" SHIELD_STATE_DIR="$OUT/state" \
       SHIELD_CROWDSEC_ETC="$OUT/etc" SHIELD_FEEDONLY_STUB="$OUT/varlog/feedonly.log"
: > "$OUT/log"
source "$SHIELD_DIR/lib/common.sh"; source "$SHIELD_DIR/config.sh"; source "$SHIELD_DIR/lib/crowdsec.sh"
fails=0
t() { if eval "$2" >/dev/null 2>&1; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

fx() { # стоковое состояние: acquis.yaml с источником + сгенерированные acquis.d
    printf 'filenames:\n  - /var/log/syslog\nlabels:\n  type: syslog\nsource: file\n' > "$OUT/etc/acquis.yaml"
    printf 'filenames: [/var/log/syslog]\nlabels: {type: syslog}\nsource: file\n'   > "$OUT/etc/acquis.d/setup.linux.yaml"
    printf 'filenames: [/var/log/auth.log]\nlabels: {type: sshd}\nsource: file\n'  > "$OUT/etc/acquis.d/setup.sshd.yaml"
    : > "$OUT/systemctl.calls"
}

fx; FAKE_ACTIVE=0 shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "acquis.yaml очищен" "[ ! -s '$OUT/etc/acquis.yaml' ]"
t "acquis.d/setup.linux.yaml удалён" "[ ! -e '$OUT/etc/acquis.d/setup.linux.yaml' ]"
t "acquis.d/setup.sshd.yaml удалён"  "[ ! -e '$OUT/etc/acquis.d/setup.sshd.yaml' ]"
t "бэкап acquis.yaml сделан" "ls '$OUT/etc'/acquis.yaml.pre-shieldnode-* >/dev/null 2>&1"
t "бэкап setup.sshd.yaml сделан" "ls '$OUT/etc/acquis.d'/setup.sshd.yaml.pre-shieldnode-* >/dev/null 2>&1"
t "заглушка yaml на месте" "[ -e '$OUT/etc/acquis.d/99-shieldnode-feedonly.yaml' ]"
t "заглушка yaml ссылается на stub-файл" "grep -q 'feedonly.log' '$OUT/etc/acquis.d/99-shieldnode-feedonly.yaml'"
t "stub-файл создан" "[ -e '$OUT/varlog/feedonly.log' ]"
t "демон активен -> restart вызван" "grep -q 'restart crowdsec.service' '$OUT/systemctl.calls'"

fx; FAKE_ACTIVE=3 shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "демон неактивен+enabled -> start (не restart), источники чистятся" "grep -q 'start crowdsec.service' '$OUT/systemctl.calls' && ! grep -q restart '$OUT/systemctl.calls' && [ ! -e '$OUT/etc/acquis.d/setup.linux.yaml' ]"

fx; FAKE_ACTIVE=3 FAKE_ENABLED=1 shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "демон неактивен+disabled -> не дёргаем вообще" "! grep -qE 'start|restart' '$OUT/systemctl.calls'"

# идемпотентность: повторный прогон по чистому состоянию — ничего не дёргаем
FAKE_ACTIVE=0 shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "повторный прогон: restart не дёргаем" "! grep -q restart '$OUT/systemctl.calls'"
t "повторный прогон: заглушка на месте" "[ -e '$OUT/etc/acquis.d/99-shieldnode-feedonly.yaml' ]"

# заглушка восстанавливается, если её файл съела ротация (без restart)
rm -f "$OUT/varlog/feedonly.log"
FAKE_ACTIVE=0 shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "stub-файл восстановлен без restart" "[ -e '$OUT/varlog/feedonly.log' ] && ! grep -q restart '$OUT/systemctl.calls'"

# не-yaml файлы оператора в acquis.d не трогаем
fx; touch "$OUT/etc/acquis.d/operator-notes.txt"
FAKE_ACTIVE=3 shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "не-yaml в acquis.d сохранён" "[ -e '$OUT/etc/acquis.d/operator-notes.txt' ]"

# etc отсутствует — тихий no-op (crowdsec не установлен)
SHIELD_CROWDSEC_ETC="$OUT/no-such-dir" shield_crowdsec_feedonly_ensure >/dev/null 2>&1
t "нет /etc/crowdsec — no-op без ошибки" "[ $? -eq 0 ]"

# v1.2.9: чужой crowdsec-firewall-bouncer — предупреждаем с готовой командой, сами не отключаем
t "bouncer включён -> имена юнитов" "[ \"\$(FAKE_ENABLED=0 shield_crowdsec_foreign_bouncer)\" = 'crowdsec-firewall-bouncer.service cs-firewall-bouncer.service' ]"
t "bouncer выключен и не запущен -> пусто" "[ -z \"\$(FAKE_ENABLED=1 FAKE_ACTIVE=3 shield_crowdsec_foreign_bouncer)\" ]"
t "bouncer выключен, но запущен -> тоже находим" "[ -n \"\$(FAKE_ENABLED=1 FAKE_ACTIVE=0 shield_crowdsec_foreign_bouncer)\" ]"
printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/cscli"; chmod +x "$OUT/bin/cscli"; hash -r
shield_conf_get() { echo "${2:-}"; }
: > "$OUT/systemctl.calls"
ens="$(DRY_RUN=1 FAKE_ENABLED=0 shield_crowdsec_agent_ensure 2>&1 || true)"
t "apply: предупреждение о чужом bouncer с командой отключения" "grep -q 'включён чужой crowdsec-firewall-bouncer.service.*Отключить: systemctl disable --now crowdsec-firewall-bouncer.service' <<<\"\$ens\""
t "apply: сам bouncer не отключает" "! grep -qE '(disable|stop|mask).*bouncer' '$OUT/systemctl.calls'"
ens="$(DRY_RUN=1 FAKE_ENABLED=1 FAKE_ACTIVE=3 shield_crowdsec_agent_ensure 2>&1 || true)"
t "apply: bouncer нет -> предупреждения нет" "! grep -q 'чужой' <<<\"\$ens\""
rm -f "$OUT/bin/cscli"; hash -r

[ "$fails" -eq 0 ] && echo "PASS: все проверки feed-only" || { echo "FAIL: $fails провалов"; exit 1; }
