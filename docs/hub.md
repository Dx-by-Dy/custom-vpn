# Hub (ROLE=hub): сервер, к которому подключаются люди

Хаб принимает сотрудников по VLESS REALITY (TCP) и Hysteria 2 (UDP), раздает им подписки и решает, куда выпустить трафик: RU — прямо с хаба, остальное — по маршруту человека (с хаба, через exit или никуда). Хаб может жить сам по себе — тогда пользователи заводятся на нем, — или под [control](control.md): тогда схема приходит снимками из DNS и одинакова на всех хабах.

| Сервис | Порт | Что делает |
|---|---|---|
| sing-box | 443/tcp | VLESS REALITY; для посторонних выглядит как `REALITY_SNI` (music.yandex.ru) |
| sing-box | 443/udp | Hysteria 2 (QUIC) |
| caddy | 8443/tcp | подписки (`SUB_PORT`) |
| caddy | 80/tcp | проверки Let's Encrypt; `ACME_HTTP_PORT`, если 80 занят сайтом |

Caddy получает сертификат на `DOMAIN` и продлевает его, hysteria берет тот же сертификат. VLESS работает сразу, hysteria включается, как только caddy получит сертификат (`up` ждет до трех минут). Контейнеры — в `network_mode: host`, от root только ради портов < 1024, остальные capabilities сброшены. Трафик клиентов в приватные сети, на адреса самого хаба (в том числе через имена вроде `localtest.me`) и BitTorrent заблокирован.

## Развертывание

1. A-запись домена → IP сервера. **До запуска**: иначе caddy упрется в лимиты Let's Encrypt. Проверьте, что имя набрано латиницей.
2. На сервере:

   ```sh
   git clone https://github.com/Dx-by-Dy/custom-vpn.git /opt/custom-vpn && cd /opt/custom-vpn
   ./vpn.sh hub install-docker             # если docker еще нет
   cp .env.example .env && nano .env   # DOMAIN; ROUTE_DEFAULT (см. «Маршруты»)
   ./vpn.sh hub deploy                     # sysctl, ключи, пользователь default, запуск, таймер, ссылки
   ```

3. Под control — сразу подключить ([control.md](control.md#хаб)):

   ```sh
   ./vpn.sh hub control join               # cvpn-hub:... → в control: ./vpn.sh control hub add hub2 '...'
   ./vpn.sh hub control set 'cvpn-ctl:...' # из вывода control hub add; снимок приходит сразу
   ```

`up` перед запуском проверяет, что `VLESS_PORT`/tcp, `HYSTERIA_PORT`/udp, `SUB_PORT`/tcp и `ACME_HTTP_PORT`/tcp не заняты чужими процессами, и если заняты — пишет кем и что делать, ничего не запуская. `SUB_PORT` и `HYSTERIA_PORT` можно просто поменять (`SUB_PORT` входит в ссылки — после смены подписку импортируют заново). После запуска `up` проверяет, что порт 80 действительно доводит запросы Let's Encrypt до caddy.

## 443/tcp занят сайтом

Hysteria (UDP) с сайтом не конфликтует. Для VLESS два пути:

- **другой порт**: `VLESS_PORT=8444` — сайт не трогаем, но REALITY не на 443 выглядит менее естественно;
- **маршрутизация по SNI**: nginx `stream` на 443 отдает соединения с SNI `REALITY_SNI` в sing-box, с SNI `DOMAIN` — caddy (свой сертификат и 404, кроме подписок; иначе тот, кто проверит `DOMAIN:443`, увидит сертификат чужого сайта), остальное — сайтам. В `.env` — `VLESS_LISTEN=127.0.0.1:8444` (там слушает sing-box; в ссылках остается `VLESS_PORT=443`). Готовый конфиг nginx `up` печатает, если 443 занят: блок `stream` (пакет `libnginx-mod-stream`) и замена `listen 443 ssl` у сайтов на `listen 127.0.0.1:4443 ssl proxy_protocol` + `real_ip_header proxy_protocol` — сайты продолжают видеть настоящие адреса. sing-box и caddy PROXY protocol здесь не читают, поэтому их ветки идут через промежуточные `server`, которые заголовок снимают. `check` проверяет обе: SNI `REALITY_SNI` на 443 доходит до sing-box, SNI `DOMAIN` — до caddy. Порт 80 тогда тоже у nginx: `ACME_HTTP_PORT=8880`, а nginx пробрасывает `/.well-known/acme-challenge/` для `DOMAIN` в caddy (пример `up` тоже печатает).

## Маршруты

RU (имена `.ru .su .рф`, список `geosite-category-ru`, российские IP из `geoip-ru`) уходит прямо с хаба. Остальное — по маршруту человека:

| Маршрут | Куда |
|---|---|
| `local` | с самого хаба |
| `none` | никуда: работает только RU |
| `EXIT/ИМЯ` | через exit `EXIT` с его IP `ИМЯ` |
| `EXIT/ИМЯ+ru` | то же, и RU тоже: всё через exit |

Маршрут может быть списком (`cz1/ip1,il1/ip1`): тогда каждый маршрут — отдельная подписка со своим ключом, человек выбирает выход в приложении, а хаб по ключу выпускает только туда ([control.md](control.md#выбор-выхода)). Маршрут — свой у человека, иначе маршрут его группы, иначе `ROUTE_DEFAULT` (`none` или пусто — без интернета, кроме RU; у старых установок по умолчанию `local`). Если маршрута нет (exit удален, IP переименован), трафик никуда не уходит — тихого переключения на другой IP нет, `check` об этом говорит.

На самостоятельном хабе:

```sh
./vpn.sh hub exit add cz1 'cvpn-exit:...'   # токен от ./vpn.sh exit hub add на exit'е
./vpn.sh hub group add sales cz1/ip1
./vpn.sh hub user add ivan --group sales    # или --route cz1/ip2
./vpn.sh hub user route ivan cz1/ip2        # свой маршрут сильнее группы; - — снова маршрут группы
./vpn.sh hub route list
./vpn.sh hub route ip cz1/ip1               # с какого IP маршрут выходит прямо сейчас (без маршрута — все)
./vpn.sh hub site route blocked.example.ru  # не считать RU: по маршруту человека
./vpn.sh hub site hub service.example.com    # считать RU: с хаба
./vpn.sh hub site list                      # исключения; site del DOMAIN — снова решают списки
```

- Списки RU — от SagerNet в `data/rule-sets/`, таймер обновляет их раз в сутки (`./vpn.sh hub update rules` — сразу); если GitHub с хаба недоступен, они скачиваются через exit.
- Что уходит с хаба, хаб резолвит сам (и блокирует имена, указывающие на приватные сети и на него самого). На exit уходит имя, exit резолвит его сам, из своей страны.

## Пользователи и подписки

На самостоятельном хабе (под control — то же самое делается в control):

```sh
./vpn.sh hub user add vasya    # создать и показать ссылки (+ QR, если стоит qrencode)
./vpn.sh hub user links vasya       # ссылки еще раз
./vpn.sh hub user del vasya    # ключи и подписка перестают работать сразу
./vpn.sh hub user rotate vasya      # новые ключи, старые работают еще 24 часа (--grace H)
```

- `https://DOMAIN:8443/<token>/<маршрут>/sub` и `…/sing-box.json` — подписка каждого маршрута человека (`cz1/ip1` → `cz1-ip1`); `/<token>/sub` — первого из них.
- `https://DOMAIN:8443/<token>/sub` — подписка (base64-список `vless://` + `hysteria2://`) для любого приложения; приложения сами ее обновляют. Под control в ней все хабы снимка (этот первым, `SUB_NAME-hub1-reality`, `SUB_NAME-hub1-hy2`, ...).
- `https://DOMAIN:8443/<token>/` — страница с кнопками импорта в Hiddify, NekoBox, V2Box.
- `https://DOMAIN:8443/<token>/sing-box.json` — те же хабы outbound'ами sing-box (для [client](client.md)).
- Все, кроме токенов пользователей, отдает 404. Изменение пользователей перезапускает sing-box — у всех на секунду рвется соединение.
- Ротация не меняет ссылку: пока старые ключи работают, приложение обновляет подписку через живой туннель. Если **утекла ссылка** — `user rotate` не поможет, нужны `user del` + `user add`.

## Под control

- Пользователи, группы, маршруты, exit'ы, `ROUTE_DEFAULT` и `SUB_NAME` приходят снимками; команды, которые их меняют, здесь отказывают (`user list`, `route list`, `route ip`, `user links` работают).
- `vpn-sync.timer` раз в 5 минут читает `head.<CONTROL_DOMAIN>` через резолверы `CONTROL_RESOLVERS` (по умолчанию `system 77.88.8.8 1.1.1.1 8.8.8.8`); `./vpn.sh hub control sync` — сразу. Список доменов управления приходит в снимке, менять его здесь не нужно.
- Снимок вручную, если DNS недоступен: `./vpn.sh hub control apply < state.txt` (с ноутбука: `ssh root@хаб 'cd /opt/custom-vpn && ./vpn.sh hub control apply' < generated/state.txt`).
- `./vpn.sh hub control unset` — снова управлять пользователями здесь (остаются пользователи последнего снимка), таймер снимается.
- Ключ шифрования снимков хаба — `data/control/age.key`; он есть только на этом хабе.
- Код обновляется приказом из control (`./vpn.sh control hub update`): тот же таймер читает его и делает `update repo` до приказанного коммита — только вперед, с откатом, если `check` после стал хуже. Итог — строка `update` в `./vpn.sh hub check` (и в `status.json` для `control check`).

## Проверка

```sh
./vpn.sh hub check
```

Контейнеры; срок сертификата (меньше 14 дней — продления не проходят); путь Let's Encrypt через 80; доступность `REALITY_SNI`; `sni-proxy` (если `VLESS_LISTEN`); под control — `control` (версия снимка) и `dns` (когда DNS читался); каждый маршрут — с какого IP выходит (`local`, каждый `EXIT/IP`), что `none` никуда не выходит, что RU выходит с хаба; свежесть списков RU. `vpn-maintenance.timer` раз в час делает `prune` и `check`; сбой виден в `systemctl --failed` и `journalctl -u vpn-maintenance`.

## Бэкап

`.env` (ключи REALITY), а у самостоятельного хаба еще `users.conf`, `exits.conf`, `groups.conf`, `routing.conf`; под control — `data/control/age.key` (без него хаб не прочитает снимки: тогда `hub control join` заново и `control hub add` в control). С этими файлами на новом сервере клиенты продолжают работать — достаточно перенести A-запись.

## Переезд со старых версий

- **xray + hysteria этого репозитория**: `./vpn.sh hub update repo` — `init` переименует ключи в `.env` (`XRAY_PORT` → `VLESS_PORT`, `XRAY_*_KEY` → `REALITY_*`), `up` заменит контейнеры на sing-box; ключи и ссылки прежние. Установка с `REALITY_XVER=1` (маскировка под свой сайт) остановится на `init` с подсказкой: sing-box не передает сайту PROXY protocol — нужен другой `REALITY_SNI` или SNI-маршрутизация.
- **systemd-установка** xray / hysteria: `systemctl disable --now xray hysteria-server`, затем `./vpn.sh hub deploy`. Однопользовательский `.env` (`XRAY_UUID` / `HYSTERIA_PASSWORD` / `SUB_TOKEN`) станет пользователем `default` с той же подпиской.
