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

Одной командой (скрипт сам скачает снапшот этого репозитория с GitHub, распакует в `/opt/vpn-node-stack` и запустит оба инсталлятора — сначала фаервол, потом оптимизация):

```bash
sudo bash -c 'bash <(curl -sL https://raw.githubusercontent.com/SpofyJet/vpn-node-stack/main/vpn-node-setup.sh)'
```

Опции: `--dry-run` (только план), `status` (без root), `rollback` (откат).

Либо из клонированного репозитория:

```bash
git clone https://github.com/SpofyJet/vpn-node-stack.git
cd vpn-node-stack

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
