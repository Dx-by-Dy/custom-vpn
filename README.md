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

Один `vpn.sh` на всех, роль записана в `.env` (`ROLE=…`). Команды — деревом «роль → объект → действие»: `./vpn.sh control user add ivan`, `./vpn.sh hub control join`, `./vpn.sh exit hub add main`. Первое слово — роль этого сервера (на новом сервере оно эту роль и выбирает: `./vpn.sh exit deploy`), поэтому по команде видно, где ее запускать. `./vpn.sh help` показывает дерево своей роли. Старая форма без роли (`./vpn.sh user add ivan`) тоже работает.

| Роль | Где | Что делает | Документация |
|---|---|---|---|
| `control` | ноутбук администратора | вся схема: пользователи, группы, маршруты, exit'ы, хабы; публикует снимки в DNS | [docs/control.md](docs/control.md) |
| `hub` | сервер в РФ | принимает людей, раздает подписки, выпускает трафик по маршрутам | [docs/hub.md](docs/hub.md) |
| `exit` | сервер за границей | принимает только хабы, выпускает трафик с нужного IP | [docs/exit.md](docs/exit.md) |
| `client` | сервер, которому нужен VPN | sing-box на localhost (socks5/http) через хабы | [docs/client.md](docs/client.md) |

Хаб может работать и сам по себе, без control: тогда пользователи и маршруты заводятся на нем самом ([docs/hub.md](docs/hub.md)).

## Развертывание каскада с нуля

1. **Exit'ы** — на каждом: `./vpn.sh exit deploy`, затем `./vpn.sh exit hub add main` (токен `cvpn-exit:…`). [docs/exit.md](docs/exit.md)
2. **Control** — на ноутбуке: `./vpn.sh control init`, в `.env` — домен управления и доступ к DNS-панели; `./vpn.sh control exit add cz1 'cvpn-exit:…'` для каждого exit'а. [docs/control.md](docs/control.md)
3. **Хабы** — A-запись домена → IP, на сервере `./vpn.sh hub deploy` и `./vpn.sh hub control join` (токен `cvpn-hub:…`); в control `./vpn.sh control hub add hub1 'cvpn-hub:…'` (токен `cvpn-ctl:…`); на хабе `./vpn.sh hub control set 'cvpn-ctl:…'`. [docs/hub.md](docs/hub.md)
4. **Люди** — в control: `./vpn.sh control group add sales cz1/ip1`, `./vpn.sh control user add ivan --group sales`, `./vpn.sh control user links ivan` — ссылку отправить человеку.
5. **Серверы-клиенты** — в control пользователь со своим маршрутом, на сервере `CLIENT_SUB='<ссылка>' ./vpn.sh client deploy`. [docs/client.md](docs/client.md)

Код на серверы — `git clone https://github.com/Dx-by-Dy/custom-vpn.git /opt/custom-vpn`; docker, если его нет, — `./vpn.sh ROLE install-docker` (например, `./vpn.sh hub install-docker`).

## Общее для всех серверов

### Проверка

`./vpn.sh ROLE check` — здоровье этого сервера (что именно проверяется, см. документацию роли). `vpn-maintenance.timer` раз в час запускает `prune` и `check`; сбой виден в `systemctl --failed` и `journalctl -u vpn-maintenance`.

### Обновление

```sh
./vpn.sh hub update repo     # новый код с GitHub (ключи, пользователи, сертификаты остаются)
./vpn.sh hub update images   # новые версии sing-box / caddy (откат, если не взлетело)
./vpn.sh hub update rules    # хаб: скачать списки RU заново (таймер делает это раз в сутки)
```

`update repo` показывает новые коммиты и изменяемые файлы, спрашивает, бэкапит `.env` и списки в `backups/` и сверяет их после. Локальные правки отслеживаемых файлов (шаблоны, `compose.yaml`) теряются — об этом предупредит. Каталог без git при первом запуске становится git-checkout'ом. Control обновляется `git pull`; если меняется формат снимка — сначала хабы, потом control.

На exit'е и клиенте — то же с `exit` / `client` вместо `hub`. Настройки: правка `.env` (или `templates/*`), затем `./vpn.sh ROLE up`.

### Firewall

```sh
./vpn.sh exit firewall --dry-run   # план (на хабе — ./vpn.sh hub firewall ...)
./vpn.sh exit firewall             # ufw
```

Открывает ssh (порт из sshd), порты этой роли и спрашивает про остальные сервисы, которые слушают публичные адреса (сайт и т. п., по умолчанию оставляет). Все остальное входящее закрывается. Затем предлагает отключить вход по SSH-паролю — только если в `authorized_keys` есть ключи.

### Удаление

```sh
./vpn.sh hub uninstall      # спрашивает, что оставить
./vpn.sh hub uninstall -y   # все до чистого состояния
```

Всегда убирает контейнеры, таймеры (`vpn-maintenance`, `vpn-sync`) и настройки sysctl (возвращает прежние значения). Спрашивает про образы, правила ufw, вход по SSH-паролю, ключи и пользователей (по умолчанию остаются — `deploy` поднимет тот же VPN с теми же ссылками) и docker. Что менялось на хосте, записано в `/var/lib/custom-vpn`. Каталог репозитория остается.

### Бэкап

| Роль | Что бэкапить |
|---|---|
| control | весь каталог, кроме `generated/`: `.env` (пароль DNS), `*.conf`, `data/control/` (ключ подписи) |
| hub | `.env`; самостоятельный — еще `users.conf`, `exits.conf`, `groups.conf`, `routing.conf`; под control — `data/control/age.key` |
| exit | `.env`, `hubs.conf` |
| client | ничего: `deploy` с той же ссылкой |

### Тесты

```sh
DOCKER=podman tests/templates.sh   # конфиги всех ролей на jq хоста и jq 1.7.1 (Ubuntu 24.04) — одинаковые и валидные
```

Перед выкаткой изменений в `templates/` или jq-программах `lib/`: на хабах Ubuntu 24.04 с jq 1.7.1, которая строже к синтаксису.

## Команды

`./vpn.sh help` — дерево команд роли этого сервера. Сводка:

```
./vpn.sh control  init
                  user   add NAME [--group G] [--route R] | del NAME | list
                         route NAME ROUTE|- | group NAME GROUP|- | links [NAME]
                         rotate NAME|--all [--grace HOURS]
                  group  add NAME [ROUTE] | route NAME ROUTE|- | del NAME | list
                  exit   add NAME TOKEN | del NAME | list
                  hub    add NAME TOKEN | token NAME | del NAME | list
                  route  list
                  publish | import FILE | prune

./vpn.sh hub      deploy | init | up | down | logs | check | prune | render
                  control join | set TOKEN | sync | apply [FILE] | export | unset
                  user …, group …, exit …, route list      (как в control; под control — только просмотр)
                  update repo|images|rules | firewall [--dry-run] | tune | install-docker | uninstall

./vpn.sh exit     deploy | init | up | down | logs | check | prune | render
                  hub    add NAME | token NAME | del NAME | list
                  update repo|images | firewall [--dry-run] | tune | install-docker | uninstall

./vpn.sh client   deploy | init | up | down | logs | check | refresh | render
                  update repo|images | firewall [--dry-run] | tune | install-docker | uninstall
```

`-y` — ответить «да» на все вопросы (для скриптов). Старые имена тоже работают: `links` = `user links`, `rotate` = `user rotate`, `sync` / `state apply` / `state export` = `control sync` / `apply` / `export` на хабе, `prune` = `refresh` на клиенте.
