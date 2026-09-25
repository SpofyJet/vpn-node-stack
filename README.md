# vpn-node-stack

Оптимизация и защита VPN-нод (Remnawave/Remnanode + Xray-core): node — тюнинг ОС/сети, shieldnode — nftables-фаервол

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

Одна команда — на чистой ноде сразу предложит установку (1-3 минуты), затем откроет меню:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/SpofyJet/vpn-node-stack/main/vpn-node-setup.sh)"
```

Установка идёт тремя строками — `[1/3] Загрузка` → `[2/3] Фаервол` → `[3/3] Оптимизация` — и заканчивается итогом:
какие порты под защитой, работает ли CrowdSec, BBR/IPv6, нужна ли перезагрузка. Подробный журнал —
`/var/log/vpn-node-setup.log` (`--verbose` — весь вывод на экран).

После установки — две команды:

```bash
sudo vpn-node                 # меню: обновить, пульт защиты, статус, безопасность, оптимизация, откат
sudo guard                    # пульт защиты: что отбито, кто в бане, блок-листы, проблемы + действия
```

Команды без меню: `sudo vpn-node status | apply | apply --dry-run | rollback | emergency on|off | uninstall`.
Без терминала (CI, cloud-init): `sudo bash -c "$(curl -fsSL …/vpn-node-setup.sh)" _ apply`.
Порядок всегда: сначала фаервол (shieldnode), затем оптимизация (node).

### Пульт защиты (`sudo guard`)

По-русски и по смыслу: сколько отбито сканеров, вредоносных сетей, подбора паролей SSH, флуда (и сколько
за время просмотра), кто сейчас в бане, размер блок-листов и когда следующее обновление, и только реальные
проблемы — с подсказкой, что сделать. Действия: кто в бане, разбанить IP, доверенные IP, обновить
блок-листы, полная проверка, аварийный режим. `guard --once` — снимок для cron/мониторинга.

### Меню безопасности

- **Защищаемые порты** — видно, откуда каждый порт: SSH, порты Xray/RemnaNode (rw-core, sing-box, hysteria), открытые в UFW, добавленные вручную. Порт или диапазон (`20000-20100`) добавляется в два нажатия.
- **Доверенные IP** — панель Remnawave, мониторинг: без лимитов и блок-листов.
- **CrowdSec** — community blocklist включён по умолчанию (агент без аккаунта, обновление каждые 30 мин).
- **Блок-листы**, **пульт защиты (guard)**, **аварийный режим**, **применить фаервол**.

## Использование без меню

```bash
bash /opt/vpn-node-stack/node/install.sh status       # оптимизация: что применено
bash /opt/vpn-node-stack/shieldnode/install.sh status # фаервол: health-check
bash /opt/vpn-node-stack/node/install.sh detect       # диагностика без изменений
```

Конфиги (всё опционально, значения по умолчанию разумные): `/etc/node/node.conf`, `/etc/shieldnode/config.conf`.
Формат — `KEY=value`, файлы не исполняются; меню пишет их само, с проверкой ввода.

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
