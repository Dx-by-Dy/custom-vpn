# custom-vpn

Корпоративный VPN на sing-box: сотрудники подключаются к хабам в РФ (VLESS REALITY и Hysteria 2), хаб выпускает каждого через нужный exit и IP за границей, RU-трафик уходит прямо с хаба. Схема ведется на ноутбуке администратора и доходит до хабов подписанными зашифрованными снимками через DNS — отдельного сервера управления нет. Все в Docker, одна команда на развертывание каждого сервера.

```
телефон / ноутбук / сервер ──VLESS REALITY / hy2──► хаб (РФ) ──VLESS REALITY──► exit ──► интернет
                                                      │ RU
                                                      └──────────────────────────────────► интернет
ноутбук (control) ──снимок──► TXT в домене управления ◄──каждые 5 мин── хабы
```

Как это устроено и почему — [ARCHITECTURE.md](ARCHITECTURE.md). Что сделано и что дальше — [TODO.md](TODO.md).

## Роли

Один `vpn.sh` на всех, роль записана в `.env` (`ROLE=…`); `./vpn.sh help` показывает команды своей роли.

| Роль | Где | Что делает | Документация |
|---|---|---|---|
| `control` | ноутбук администратора | вся схема: пользователи, группы, маршруты, exit'ы, хабы; публикует снимки в DNS | [docs/control.md](docs/control.md) |
| `hub` | сервер в РФ | принимает людей, раздает подписки, выпускает трафик по маршрутам | [docs/hub.md](docs/hub.md) |
| `exit` | сервер за границей | принимает только хабы, выпускает трафик с нужного IP | [docs/exit.md](docs/exit.md) |
| `client` | сервер, которому нужен VPN | sing-box на localhost (socks5/http) через хабы | [docs/client.md](docs/client.md) |

Хаб может работать и сам по себе, без control: тогда пользователи и маршруты заводятся на нем самом ([docs/hub.md](docs/hub.md)).

## Развертывание каскада с нуля

1. **Exit'ы** — на каждом: `ROLE=exit ./vpn.sh deploy`, затем `./vpn.sh hub add main` (токен `cvpn-exit:…`). [docs/exit.md](docs/exit.md)
2. **Control** — на ноутбуке: `ROLE=control ./vpn.sh init`, в `.env` — домен управления и доступ к DNS-панели; `./vpn.sh exit add cz1 'cvpn-exit:…'` для каждого exit'а. [docs/control.md](docs/control.md)
3. **Хабы** — A-запись домена → IP, на сервере `./vpn.sh deploy` и `./vpn.sh control join` (токен `cvpn-hub:…`); в control `./vpn.sh hub add hub1 'cvpn-hub:…'` (токен `cvpn-ctl:…`); на хабе `./vpn.sh control set 'cvpn-ctl:…'`. [docs/hub.md](docs/hub.md)
4. **Люди** — в control: `./vpn.sh group add sales cz1/ip1`, `./vpn.sh user add ivan --group sales`, `./vpn.sh links ivan` — ссылку отправить человеку.
5. **Серверы-клиенты** — в control пользователь со своим маршрутом, на сервере `ROLE=client CLIENT_SUB='<ссылка>' ./vpn.sh deploy`. [docs/client.md](docs/client.md)

Код на серверы — `git clone https://github.com/Dx-by-Dy/custom-vpn.git /opt/custom-vpn`; docker, если его нет, — `./vpn.sh install-docker`.

## Общее для всех серверов

### Проверка

`./vpn.sh check` — здоровье этого сервера (что именно проверяется, см. документацию роли). `vpn-maintenance.timer` раз в час запускает `prune` и `check`; сбой виден в `systemctl --failed` и `journalctl -u vpn-maintenance`.

### Обновление

```sh
./vpn.sh update repo     # новый код с GitHub (ключи, пользователи, сертификаты остаются)
./vpn.sh update images   # новые версии sing-box / caddy (откат, если не взлетело)
./vpn.sh update rules    # хаб: скачать списки RU заново (таймер делает это раз в сутки)
```

`update repo` показывает новые коммиты и изменяемые файлы, спрашивает, бэкапит `.env` и списки в `backups/` и сверяет их после. Локальные правки отслеживаемых файлов (шаблоны, `compose.yaml`) теряются — об этом предупредит. Каталог без git при первом запуске становится git-checkout'ом. Control обновляется `git pull`; если меняется формат снимка — сначала хабы, потом control.

Настройки: правка `.env` (или `templates/*`), затем `./vpn.sh up`.

### Firewall

```sh
./vpn.sh firewall --dry-run   # план
./vpn.sh firewall             # ufw
```

Открывает ssh (порт из sshd), порты этой роли и спрашивает про остальные сервисы, которые слушают публичные адреса (сайт и т. п., по умолчанию оставляет). Все остальное входящее закрывается. Затем предлагает отключить вход по SSH-паролю — только если в `authorized_keys` есть ключи.

### Удаление

```sh
./vpn.sh uninstall      # спрашивает, что оставить
./vpn.sh uninstall -y   # все до чистого состояния
```

Всегда убирает контейнеры, таймеры (`vpn-maintenance`, `vpn-sync`) и настройки sysctl (возвращает прежние значения). Спрашивает про образы, правила ufw, вход по SSH-паролю, ключи и пользователей (по умолчанию остаются — `deploy` поднимет тот же VPN с теми же ссылками) и docker. Что менялось на хосте, записано в `/var/lib/custom-vpn`. Каталог репозитория остается.

### Бэкап

| Роль | Что бэкапить |
|---|---|
| control | весь каталог, кроме `generated/`: `.env` (пароль DNS), `*.conf`, `data/control/` (ключ подписи) |
| hub | `.env`; самостоятельный — еще `users.conf`, `exits.conf`, `groups.conf`, `routing.conf`; под control — `data/control/age.key` |
| exit | `.env`, `hubs.conf` |
| client | ничего: `deploy` с той же ссылкой |

## Команды

`./vpn.sh help` — список для роли этого сервера. Сводка:

| `./vpn.sh …` | Роли | |
|---|---|---|
| `deploy` | hub, exit, client | `tune` + `init` + `up` + таймер (+ ссылки / токены) |
| `init` | все | `.env`, ключи; control — ключ подписи |
| `up` / `down` / `logs` | hub, exit, client | собрать конфиги и запустить / остановить / логи; в control `up` = `publish` |
| `check` | hub, exit, client | здоровье |
| `prune` | все | хаб: просроченные ключи и списки RU; client: обновить подписку; control: почистить и опубликовать |
| `user …`, `group …`, `exit …`, `route list`, `links`, `rotate` | control, hub | схема (на хабе под control — только просмотр) |
| `hub add\|token\|del\|list` | control | хабы схемы |
| `hub add\|token\|del\|list` | exit | токены хабов этого exit'а |
| `publish`, `import FILE` | control | опубликовать снимок; забрать пользователей хаба |
| `control join\|set\|unset`, `sync`, `state apply\|export` | hub | работа под control |
| `update repo\|images\|rules`, `firewall`, `tune`, `render`, `install-docker`, `uninstall` | серверы | обслуживание |

`-y` — ответить «да» на все вопросы (для скриптов).
