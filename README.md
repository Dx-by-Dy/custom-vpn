# custom-vpn

Xray (VLESS + REALITY + Vision) и Hysteria 2 в Docker, для быстрого развертывания на новом сервере.

| Сервис   | Порт       | Что делает                                                                 |
|----------|------------|----------------------------------------------------------------------------|
| xray     | 443/tcp    | VLESS REALITY, для посторонних выглядит как `REALITY_SNI` (по умолчанию ozon) |
| hysteria | 443/udp    | Hysteria 2 (QUIC), сертификат Let's Encrypt на `DOMAIN`                     |
| hysteria | 80/tcp     | только на время выпуска/продления сертификата (HTTP-01)                     |

Контейнеры работают в `network_mode: host` (без NAT для UDP), от root только ради портов < 1024, все остальные capabilities сброшены. Трафик клиентов в приватные сети и на сам хост заблокирован, BitTorrent в xray тоже.

## Развертывание

1. A-запись домена → IP сервера. **До запуска**, иначе hysteria будет в цикле пытаться получить сертификат и упрется в лимиты Let's Encrypt.
2. На сервере:

   ```sh
   git clone <repo> /opt/vpn && cd /opt/vpn
   ./vpn.sh install-docker        # если docker еще нет
   cp .env.example .env && nano .env   # DOMAIN, ACME_EMAIL
   ./vpn.sh                       # = deploy: sysctl, секреты, конфиги, запуск, ссылки
   ```

`deploy` сам сгенерирует UUID, ключи REALITY, shortId и пароль hysteria и допишет их в `.env`. В конце выведет ссылки `vless://` и `hysteria2://` (и QR-коды, если установлен `qrencode`).

**Бэкапить нужно только `.env`** — все остальное воспроизводится из репозитория. С тем же `.env` на новом сервере клиенты продолжат работать, достаточно перенести A-запись.

## Команды

| `./vpn.sh …`     |                                                              |
|------------------|--------------------------------------------------------------|
| `deploy` (по умолчанию) | `tune` + `init` + `up` + `links`                       |
| `init`           | создать `.env` из примера, догенерировать пустые секреты     |
| `render`         | собрать `generated/*` из `templates/*` и проверить конфиг xray |
| `up`             | `render` + `docker compose up -d`                            |
| `down` / `logs`  | остановить / смотреть логи                                    |
| `links`          | показать клиентские ссылки                                    |
| `tune`           | BBR + увеличенные UDP-буферы (`/etc/sysctl.d/99-vpn.conf`)     |
| `install-docker` | поставить docker через get.docker.com                         |

Поменять настройки: правим `.env` или `templates/*`, затем `./vpn.sh up`.
Обновить версии: меняем `XRAY_IMAGE` / `HYSTERIA_IMAGE` в `.env`, затем `./vpn.sh up`.

## Переезд со старого сервера (systemd)

На старом сервере xray и hysteria стоят как systemd-сервисы и держат порты. Если разворачиваешь поверх:

```sh
systemctl disable --now xray hysteria-server
./vpn.sh
```

## Что изменилось относительно старых конфигов

- **xray**: добавлен `flow: xtls-rprx-vision` — VLESS без flow xray помечает как deprecated (это видно в логах на текущем сервере). **Клиентам нужно включить flow** — проще всего заново импортировать ссылку.
- **xray**: убран блок `dns` — он был в формате sing-box/клиента (`detour`, outbound `proxy`, которого на сервере нет). Вместо него DoH 1.1.1.1 для роутинга.
- **xray**: добавлены sniffing, блокировка `geoip:private` и BitTorrent, `dest` → `target`, `tcp` → `raw` (новые имена).
- **hysteria**: явный `acme.type: http` (443/tcp занят xray, TLS-ALPN всё равно не работал), ACL против доступа в приватные сети.
- Все секреты и домен вынесены в `.env`, шаблоны в репозитории без секретов. Старые конфиги (с секретами) лежат в `old/`, она в `.gitignore`.
