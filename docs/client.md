# Client (ROLE=client): VPN для программ на сервере

Серверу, которому нужен выход наружу (бот, CI, скрипты), — sing-box на localhost: прокси socks5 + http на `CLIENT_LISTEN` (по умолчанию `127.0.0.1:2080`) через хабы подписки одного пользователя. Куда уходит трафик, решает хаб, как для телефона: RU — с хаба, остальное — по маршруту пользователя (у которого обычно свой маршрут, например `cz1/ip1`).

## Развертывание

```sh
# в control: отдельный пользователь под этот сервер
./vpn.sh user add ci-runner --route cz1/ip1
./vpn.sh links ci-runner                   # ссылка на подписку на каждом хабе

# на сервере
git clone https://github.com/Dx-by-Dy/custom-vpn.git /opt/custom-vpn && cd /opt/custom-vpn
./vpn.sh install-docker                    # если docker еще нет
ROLE=client CLIENT_SUB='https://cdn.specterite.ru:8443/<token>/sub https://cdn2.specterite.ru:8443/<token>/sub' ./vpn.sh deploy
```

`CLIENT_SUB` — ссылка на подписку или страницу импорта; можно несколько через пробел (ссылки разных хабов) — клиент берет первую, которая ответит. `CLIENT_LISTEN=127.0.0.1:2080` можно задать тут же или потом в `.env` (затем `./vpn.sh up`).

## Использование

```sh
curl -x socks5h://127.0.0.1:2080 https://api.ipify.org          # IP маршрута пользователя
curl -x socks5h://127.0.0.1:2080 https://ip.beget.ru            # IP хаба (RU)
export HTTPS_PROXY=http://127.0.0.1:2080 HTTP_PROXY=http://127.0.0.1:2080   # для программ, которые понимают прокси
```

`socks5h` (имя резолвит прокси) — правильнее, чем `socks5`: так RU / не RU решает хаб по имени. Адреса частных сетей идут мимо прокси.

## Как работает

- Хабы отдают для каждого пользователя `…/<token>/sing-box.json` — VLESS REALITY и Hysteria 2 каждого хаба. Клиент кладет копию в `data/client/sub.json` и собирает `generated/sing-box.json`: `mixed` на `CLIENT_LISTEN` → `urltest` между всеми хабами (каждые 3 минуты меряет RU-адрес — то есть сам хаб) → самый быстрый.
- Если хаб пропал, через несколько минут трафик идет через другой; когда вернется — обратно на быстрейший.
- `vpn-maintenance.timer` раз в час (`prune`) обновляет подписку и перезапускает sing-box, если хабы или ключи поменялись (новый хаб, `rotate`). Если ни один `CLIENT_SUB` не отвечает — работает на последней копии.
- Подписка с любого хаба содержит все хабы, поэтому новый хаб клиент подхватит сам.

## Проверка

```sh
./vpn.sh check
```

```
containers   ok
subscription ok (cdn.specterite.ru cdn2.specterite.ru, refreshed 0h ago)
proxy        ok (127.0.0.1:2080: RU leaves as 91.219.150.99, the rest as 109.172.8.54)
```

`subscription` падает, если подписку не удавалось обновить больше 2 суток; `proxy` — если через прокси не проходит даже RU (хабы недоступны). «the rest nowhere» при живом RU — у пользователя маршрут `none` или его exit не работает.

## Безопасность

- Прокси слушает только localhost. `CLIENT_LISTEN=0.0.0.0:2080` открыл бы его всем — тогда только за firewall'ом.
- `data/client/sub.json` — ключи пользователя (права 600). Утекли — в control `user del` + `user add`, новый `CLIENT_SUB` здесь (`.env`, затем `./vpn.sh up`).
- Убрать: `./vpn.sh uninstall`.
