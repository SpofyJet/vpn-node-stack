#!/bin/bash
# deploy-to-github.sh — деплой проектов node/ и shieldnode/ в GitHub-репозиторий.
#
# РАЗМЕЩЕНИЕ: в /opt рядом с этим скриптом должны лежать ЛИБО папки, ЛИБО архивы:
#   вариант А:  /opt/node/...  /opt/shieldnode/...  /opt/deploy-to-github.sh
#   вариант Б:  /opt/node.tar.gz  /opt/shieldnode.tar.gz  /opt/deploy-to-github.sh
#              (папок нет — скрипт распакует архивы сам, с проверкой безопасности)
#
# ЗАПУСК:   bash /opt/deploy-to-github.sh
#
# Что делает:
#   1. Спрашивает GitHub Classic Token (ввод скрыт, в логи/историю не попадает).
#   2. Проверяет токен и права (нужен scope repo для приватного репозитория).
#   3. Создаёт репозиторий, если его ещё нет.
#   4. Генерирует README.md заново (старый перезаписывается).
#   5. Генерирует SHA256SUMS (node.tar.gz + shieldnode.tar.gz + vpn-node-setup.sh)
#      — vpn-node-setup.sh верифицирует архивы по нему при однострочной установке.
#   6. git init → commit → push (токен передаётся через временный askpass-скрипт
#      и НИКОГДА не попадает в URL remote, .git/config и history).
#
# Неинтерактивный режим (для CI): переменные окружения
#   GITHUB_TOKEN, REPO_NAME, REPO_VISIBILITY (private|public), REPO_DESCRIPTION
set -euo pipefail

# ---------- настройки по умолчанию (переопределяются env) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_NAME="${REPO_NAME:-vpn-node-stack}"
REPO_VISIBILITY="${REPO_VISIBILITY:-private}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-Оптимизация и защита VPN-нод (Remnawave/Remnanode + Xray-core): node — тюнинг ОС/сети, shieldnode — nftables-фаервол}"
API="https://api.github.com"

die() { echo "ОШИБКА: $*" >&2; exit 1; }
warn() { echo "ВНИМАНИЕ: $*" >&2; }

# ---------- проверка окружения ----------
command -v git  >/dev/null 2>&1 || die "нужен git: apt-get install -y git"
command -v curl >/dev/null 2>&1 || die "нужен curl: apt-get install -y curl"
command -v tar  >/dev/null 2>&1 || die "нужен tar"

# ---------- распаковка архивов (если папки не распакованы) ----------
extract_if_needed() { # $1=папка $2=архив
    local dir="$1" tgz="$2"
    if [ -f "$dir/install.sh" ]; then
        if [ -f "$tgz" ] && [ "$tgz" -nt "$dir/install.sh" ]; then
            warn "$dir/ распакован РАНЬШЕ, чем изменён $tgz — в репозиторий уйдёт СТАРОЕ содержимое папки. Обнови: rm -rf $dir && bash deploy-to-github.sh"
        fi
        return 0
    fi
    if [ ! -f "$tgz" ]; then
        [ -d "$dir" ] && die "$dir/ существует, но $dir/install.sh в ней нет — сломанная папка. Удали $dir/ или положи рядом $tgz"
        die "не найдено ни $dir/install.sh, ни $tgz — положи рядом с этим скриптом папки node/ и shieldnode/ ИЛИ архивы node.tar.gz и shieldnode.tar.gz"
    fi
    echo "Распаковываю $tgz ..."
    # безопасность: не распаковываем архивы с абсолютными путями или ..
    if tar -tzf "$tgz" | grep -qE '(^\.\./|(^|/)\.\.(/|$)|^/)'; then
        die "$tgz содержит опасные пути (.. или абсолютные) — распаковка отменена"
    fi
    tar -xzf "$tgz" || die "не удалось распаковать $tgz"
    [ -f "$dir/install.sh" ] || die "в $tgz нет $dir/install.sh — архив не тот?"
    echo "Распаковано: $dir/"
}
extract_if_needed node node.tar.gz
extract_if_needed shieldnode shieldnode.tar.gz

# ---------- SHA256SUMS для однострочной установки ----------
# vpn-node-setup.sh качает архивы с raw.githubusercontent и проверяет по этому файлу.
# Без vpn-node-setup.sh checksum'и всё равно генерируем (дешево), но предупреждаем.
command -v sha256sum >/dev/null 2>&1 || warn "нет sha256sum — SHA256SUMS не сгенерирую (vpn-node-setup.sh будет ругаться)"
if command -v sha256sum >/dev/null 2>&1; then
    SUM_FILES=(node.tar.gz shieldnode.tar.gz)
    [ -f vpn-node-setup.sh ] && SUM_FILES+=(vpn-node-setup.sh) || warn "vpn-node-setup.sh не найден рядом с deploy-to-github.sh — в репозиторий (и в SHA256SUMS) попадут только архивы, однострочник работать не будет"
    sha256sum "${SUM_FILES[@]}" > SHA256SUMS
    echo "Сгенерирован SHA256SUMS (${#SUM_FILES[@]} файлов)"
fi

# ---------- токен ----------
if [ -n "${GITHUB_TOKEN:-}" ]; then
    TOKEN="$GITHUB_TOKEN"
    echo "Токен взят из переменной GITHUB_TOKEN"
else
    echo
    echo "GitHub Classic Token с правами repo"
    echo "(создать: github.com → Settings → Developer settings → Personal access tokens → Tokens (classic))"
    printf "Вставь токен (ввод скрыт): "
    read -rs TOKEN || true
    echo
    [ -n "$TOKEN" ] || die "пустой токен"
fi

# ---------- временные файлы с секретом (удаляются всегда) ----------
GH_HDR="$(mktemp)";       printf 'Authorization: token %s\nAccept: application/vnd.github+json\n' "$TOKEN" > "$GH_HDR"; chmod 600 "$GH_HDR"
API_BODY="$(mktemp)"; API_HDR="$(mktemp)"; PAYLOAD="$(mktemp)"
ASKPASS="$(mktemp /tmp/.gh-askpass.XXXXXX)"; chmod 700 "$ASKPASS"
cleanup() { rm -f "$GH_HDR" "$API_BODY" "$API_HDR" "$PAYLOAD" "$ASKPASS"; }
trap cleanup EXIT

# ---------- GitHub API ----------
api() { # api METHOD PATH [JSON_BODY_FILE] -> тело ответа в $API_BODY, код в $HTTP_CODE
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "$method" -H @"$GH_HDR" -o "$API_BODY" -w '%{http_code}' -D "$API_HDR")
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data @"$body")
    HTTP_CODE="$(curl "${args[@]}" "$API$path")"
}

# --- кто мы ---
api GET /user
[ "$HTTP_CODE" = "200" ] || die "токен не принят GitHub (HTTP $HTTP_CODE). Нужен НЕ просроченный classic token."
LOGIN="$(sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' "$API_BODY" | head -1)"
[ -n "$LOGIN" ] || die "не смог определить логин из ответа GitHub"
SCOPES="$(grep -i '^x-oauth-scopes:' "$API_HDR" | tr -d '\r' | cut -d: -f2- | tr ',' '\n' | sed 's/^ *//')"
echo "Авторизован как: $LOGIN"

# --- параметры репозитория (спрашиваем, если stdin — терминал) ---
if [ -t 0 ]; then
    printf "Имя репозитория [%s]: " "$REPO_NAME"; read -r ans || ans=""; [ -n "$ans" ] && REPO_NAME="$ans"
fi
case "$REPO_VISIBILITY" in
    private|public) ;;
    *)
        if [ -t 0 ]; then
            printf "Приватный репозиторий? Однострочник установки работает только с публичным. [y/N]: "; read -r ans || ans=""
            case "${ans:-n}" in
                y|Y|yes|YES) REPO_VISIBILITY=private ;;
                *)           REPO_VISIBILITY=public ;;
            esac
        else
            REPO_VISIBILITY=private
            warn "неинтерактивный режим: репозиторий будет приватным — однострочник работать НЕ будет"
        fi
        ;;
esac
if [ -t 0 ]; then
    printf "Описание [%s]: " "$REPO_DESCRIPTION"; read -r ans; [ -n "$ans" ] && REPO_DESCRIPTION="$ans"
fi

# --- проверка scope под выбранную видимость ---
if [ "$REPO_VISIBILITY" = "private" ]; then
    echo "$SCOPES" | grep -qx 'repo' || die "токену нужен scope 'repo' (полный) для приватного репозитория. Сейчас у токена: $(echo "$SCOPES" | tr '\n' ' ')"
else
    echo "$SCOPES" | grep -qx 'repo' || echo "$SCOPES" | grep -qx 'public_repo' || die "токену нужен scope 'public_repo' или 'repo'. Сейчас: $(echo "$SCOPES" | tr '\n' ' ')"
fi

# --- репозиторий существует? если нет — создаём ---
api GET "/repos/$LOGIN/$REPO_NAME"
if [ "$HTTP_CODE" = "200" ]; then
    echo "Репозиторий $LOGIN/$REPO_NAME уже существует — пушу в него"
    if grep -q '"private": *true' "$API_BODY"; then
        warn "репозиторий ПРИВАТНЫЙ — однострочник через raw.githubusercontent.com работать НЕ будет (там 404 без токена). Сделай публичным: Settings → Danger zone → Change visibility → Public"
    else
        echo "Видимость: публичный — однострочник будет работать"
    fi
else
    printf '{"name":"%s","private":%s,"description":"%s","auto_init":false}' \
        "$REPO_NAME" "$([ "$REPO_VISIBILITY" = "private" ] && echo true || echo false)" "$REPO_DESCRIPTION" > "$PAYLOAD"
    api POST /user/repos "$PAYLOAD"
    [ "$HTTP_CODE" = "201" ] || { sed -n 's/.*"message": *"\([^"]*\)".*/\1/p' "$API_BODY" | head -1 | { read -r m; die "не удалось создать репозиторий (HTTP $HTTP_CODE)${m:+: $m}"; }; }
    echo "Создан репозиторий: https://github.com/$LOGIN/$REPO_NAME ($REPO_VISIBILITY)"
fi

# ---------- README.md (всегда перегенерируется — старый вариант перезаписывается) ----------
cat > README.md <<'READMEEOF'
# __REPO_NAME__

__REPO_DESCRIPTION__

Два независимых скрипта для Linux-серверов под высокой нагрузкой (Remnawave/Remnanode + Xray-core):

| Папка | Назначение |
|---|---|
| **node/** | Оптимизация ОС и сети: sysctl-профили по tier'ам RAM, conntrack, лимиты FD, TCP/UDP/BBR, IRQ/RSS, настройка NIC, отключение лишних служб, тюнинг дата-плана, диагностика, атомарный откат |
| **shieldnode/** | nftables-фаервол: защита SSH, отброс невалидных пакетов, SYN-защита, abuse-лимиты per-source, аварийный режим, атомарное применение и откат, блок-листы (threat/scanner/tor/custom) с автообновлением |

## Требования

- Debian / Ubuntu, root, systemd
- kernel ≥ 5.10 рекомендуется (BBR, fq, опционально XanMod)
- python3 — только для парсинга JSON-блоклистов (shieldnode)
- nftables — для shieldnode

## Установка

Одной командой (скрипт сам скачает архивы из этого репозитория, проверит SHA256 и запустит оба инсталлятора):

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/__LOGIN__/__REPO_NAME__/main/vpn-node-setup.sh)
```

Опции: `--dry-run` (только план), `status` (без root), `rollback` (откат).

Либо из клонированного репозитория:

```bash
git clone https://github.com/__LOGIN__/__REPO_NAME__.git
cd __REPO_NAME__

# 1) оптимизация ноды
sudo bash node/install.sh            # plan → apply → self-test; --dry-run для просмотра

# 2) фаервол
sudo bash shieldnode/install.sh      # SSH-whitelist спросит текущий IP автоматически
```

## Использование

```bash
bash node/install.sh status          # что применено, какие значения
bash node/install.sh rollback        # вернуть исходное состояние
bash node/install.sh detect          # диагностика без изменений

bash shieldnode/install.sh status
bash shieldnode/install.sh rollback

# тесты (не требуют root, кроме test-policies.sh)
bash node/tests/test-config.sh && bash node/tests/test-datapath.sh && bash node/tests/test-rollback.sh
bash shieldnode/tests/test-blocklist.sh && bash shieldnode/tests/test-template.sh
```

Конфиги (всё опционально, значения по умолчанию разумные): `/etc/node/node.conf`, `/etc/shieldnode/shieldnode.conf`.

## Гарантии безопасности

- В логи не пишутся токены/UUID/конфиги Xray — только метаданные.
- node не трогает конфиг Xray (inbounds/outbounds/routing/TLS/REALITY).
- shieldnode не пишет net.netfilter.* — conntrack в одних руках у node.
- Нет блокировки SSH: whitelist-first, loopback accept, self-test, авто-откат при ошибке.
- Каждое применение — атомарно: временный файл → проверка → swap, с backup перед перезаписью.

## Структура

```
node/            install.sh, main.sh, apply.sh, config.sh, persist.sh,
                 rollback.sh, status.sh, detect.sh, uninstall.sh,
                 node.defaults.conf, lib/*.sh, tests/*.sh
shieldnode/      install.sh, main.sh, firewall.sh, config.sh, persist.sh,
                 rollback.sh, status.sh, detect.sh, emergency.sh, limits.sh,
                 ssh.sh, shieldnode.defaults.conf, lib/*.sh, tests/*.sh
```

## Дисклеймер

Скрипты меняют сетевой стек и фаервол. Прогони \`--dry-run\`, прочитай diff, держи консоль открытой до self-test. Использование — на свой риск.
READMEEOF
    # подстановка плейсхолдеров через awk -v: безопасно для любых символов в значениях
    awk -v d="$REPO_DESCRIPTION" -v n="$REPO_NAME" -v l="$LOGIN" \
        '{gsub(/__REPO_DESCRIPTION__/,d); gsub(/__REPO_NAME__/,n); gsub(/__LOGIN__/,l)} 1' \
        README.md > README.md.tmp.$$ && mv README.md.tmp.$$ README.md
    echo "Сгенерирован README.md (перезаписан)"

# ---------- .gitignore ----------
if [ ! -f .gitignore ]; then
    printf '*.log\n.DS_Store\n' > .gitignore
    echo "Сгенерирован .gitignore"
fi

# ---------- git ----------
[ -d .git ] || { git init -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }; }

REMOTE_URL="https://github.com/$LOGIN/$REPO_NAME.git"
if git remote get-url origin >/dev/null 2>&1; then
    warn "remote origin уже настроен: $(git remote get-url origin) — пушу туда"
else
    git remote add origin "$REMOTE_URL"
fi

# git-идентичность: только если не задана глобально/локально
git config user.name  >/dev/null 2>&1 || git config user.name  "$LOGIN"
git config user.email >/dev/null 2>&1 || git config user.email "$LOGIN@users.noreply.github.com"

# коммитим ТОЛЬКО наш набор путей — ничего лишнего из /opt.
# Индекс перед этим чистим (rm --cached не трогает файлы на диске):
# файлы, которые мы раньше коммитили, а теперь их нет в списке — удалятся из репозитория.
paths=()
for p in README.md .gitignore node shieldnode node.tar.gz shieldnode.tar.gz SHA256SUMS vpn-node-setup.sh "$(basename "$0")"; do
    [ -e "$SCRIPT_DIR/$p" ] && paths+=("$p")
done
for md in "$SCRIPT_DIR"/*.md; do
    [ -e "$md" ] && paths+=("$(basename "$md")")
done
if [ -n "$(git ls-files)" ]; then
    git rm -r --cached . >/dev/null
fi
git add -- "${paths[@]}"

if git diff --cached --quiet; then
    echo "Изменений нет — коммитить нечего"
else
    git commit -q -m "node + shieldnode: оптимизация и защита VPN-нод" && echo "Коммит создан"
fi

# ---------- push через временный askpass (токен не в remote URL) ----------
cat > "$ASKPASS" <<'ASKEOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' "__LOGIN__" ;;
    *)          printf '%s\n' "__TOKEN__" ;;
esac
ASKEOF
sed -i "s|__LOGIN__|$LOGIN|;s|__TOKEN__|$TOKEN|" "$ASKPASS"

echo
echo "Пушу в origin..."
if ! GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git push -u origin main; then
    die "push не прошёл. Если репозиторий уже содержал коммиты: git pull --rebase origin main && git push"
fi

echo
echo "ГОТОВО: https://github.com/$LOGIN/$REPO_NAME (branch: main)"
echo "Если токен создавался только для этого деплоя — отзови его: github.com/settings/tokens"
