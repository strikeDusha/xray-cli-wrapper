# v3xtun

GUI-обёртка над **tun2proxy** и **xray** для Arch Linux (KDE Plasma / Wayland).
Графический интерфейс на **Tauri 2** (Rust + TypeScript): запуск/остановка, редактор
конфига xray, настройка маршрутизации tun2proxy и системный трей. После установки
доступна командой `v3xtun` из консоли.

> Раньше в этом репозитории жил Python-CLI `xr`. Он остаётся в истории git; актуальный
> проект — графический **v3xtun**.

## Быстрый старт

```bash
git clone https://github.com/strikeDusha/xray-cli-wrapper.git
cd xray-cli-wrapper
./install.sh          # соберёт релиз и поставит команду `v3xtun` в ~/.local/bin
v3xtun                # запуск GUI (или иконка в меню приложений)
```

`./install.sh` сам проверит зависимости и подскажет команду `pacman`, если чего-то не хватает.

## Как это работает

```
системный трафик ─▶ TUN (tun2proxy) ─▶ SOCKS5 127.0.0.1:10808 (xray inbound) ─▶ ваш сервер (xray outbound)
```

- **xray** запускается от пользователя и поднимает локальный SOCKS5-инбаунд.
- **tun2proxy** создаёт TUN-интерфейс и заворачивает весь трафик ОС в этот SOCKS5.
- IP вашего сервера обязательно попадает в **bypass**, иначе исходящее соединение xray
  к серверу само уйдёт в туннель → петля. На вкладке «Маршрутизация» есть кнопка
  «Извлечь адреса сервера из конфига» (хостнеймы резолвятся в IP при старте).

Подробности архитектуры — в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Зависимости (Arch)

```bash
# рантайм
sudo pacman -S xray            # или: yay -S xray-bin
yay -S tun2proxy               # ставит бинарь tun2proxy-bin

# сборка
sudo pacman -S --needed rust nodejs npm webkit2gtk-4.1 \
               base-devel libappindicator-gtk3 librsvg patchelf
```

> Если бинарь tun2proxy называется иначе, укажите путь в «Настройки → Путь к бинарю tun2proxy».

## Консольные команды

```bash
v3xtun            # запустить графический интерфейс
v3xtun --help     # справка
v3xtun --version  # версия
```

## Версия без GUI — `v3xtun.sh` (чистый Bash)

Если не нужен графический интерфейс (сервер, SSH, headless), есть консольный
двойник на чистом Bash — **`v3xtun.sh`**. Тот же стек (xray + tun2proxy), без
сборки Rust/Node: нужны только `jq`, `xray`, `tun2proxy` и `curl`.

```bash
./v3xtun.sh                      # интерактивная оболочка (в стиле Claude Code)
./v3xtun.sh add "vless://…"      # добавить сервер по ссылке (vless/vmess/trojan/ss)
./v3xtun.sh tun on               # включить VPN на всю систему (tun2proxy --setup)
./v3xtun.sh status               # статус, exit-IP, порты
./v3xtun.sh --help
```

Что делает: парсит share-ссылки и подписки, генерирует конфиг xray, поднимает
его как `systemd --user` сервис, переключает системный прокси, и включает
**TUN-режим через tun2proxy** с теми же гарантиями, что и GUI — пиннинг IP
сервера, `--bypass` на адрес сервера (без петли), virtual-DNS (без утечек) и
проверкой exit-IP после включения. Если на `tun2proxy` выдан `cap_net_admin`
(кнопка «Выдать права» в GUI или `setcap`), TUN поднимается **без root**.

Свой конфиг хранит в `~/.config/v3xtun/` (отдельно от GUI, чтобы не пересекаться).

## Скрипты

| Скрипт | Назначение |
|---|---|
| `./install.sh`   | собрать релиз и установить команду `v3xtun` + ярлык |
| `./run.sh`       | dev-режим с hot-reload (`tauri dev`) |
| `./uninstall.sh` | удалить команду, ярлык и иконку |
| `./v3xtun.sh`    | консольная версия на Bash (без сборки, нужен `jq`) |

Ручная сборка бандлов (`.AppImage` / `.deb` / `.rpm`):

```bash
npm install && npm run tauri build
# артефакты: src-tauri/target/release/bundle/
```

## Права (CAP_NET_ADMIN)

tun2proxy создаёт TUN и правит маршруты — нужен `CAP_NET_ADMIN`. Два варианта:

1. **Рекомендуется — capability на бинарь (без root в рантайме).**
   На «Панели» нажмите **«Выдать права»** — разово выполнится через `pkexec`:
   ```bash
   sudo setcap cap_net_admin,cap_net_raw+ep $(command -v tun2proxy-bin)
   ```
   После этого старт/стоп надёжны: остановка идёт через `SIGTERM`, tun2proxy сам
   корректно восстанавливает маршруты и DNS (`SIGKILL` бы их подвесил).

2. **Через pkexec при каждом запуске.** Галочка «Запускать через pkexec» на вкладке
   «Маршрутизация». Запрос пароля при каждом старте; остановка root-процесса менее
   надёжна — вариант 1 предпочтительнее.

## Конфигурация

Файлы — в `~/.config/dev.v3xtun.app/`:

- `settings.json` — настройки приложения и tun2proxy;
- `xray-config.json` — конфиг xray (вкладка «Конфиг xray»).

Шаблон по умолчанию — VLESS + Reality; замените `YOUR_*` своими данными.

## Структура

```
index.html, src/        фронтенд (TypeScript + Vite)
src-tauri/src/
  process.rs            запуск/остановка/мониторинг xray и tun2proxy, логи
  config.rs             настройки, конфиг xray, сборка команд, capabilities, автозапуск
  commands.rs           команды Tauri
  tray.rs               системный трей
  lib.rs / main.rs      сборка приложения + CLI (--help/--version)
install.sh, run.sh, uninstall.sh
docs/ARCHITECTURE.md
```

## Решение проблем

### `Gdk-Message: Error 71 (Protocol error) dispatching to wayland display`

Окно не открывается на Wayland (частая беда WebKitGTK на KDE Plasma). v3xtun уже
выставляет `WEBKIT_DISABLE_DMABUF_RENDERER=1` сам при старте. Если этого мало,
попробуйте по очереди:

```bash
# 1) отключить также композитинг WebKitGTK
WEBKIT_DISABLE_COMPOSITING_MODE=1 v3xtun

# 2) принудительно запустить через XWayland (почти всегда срабатывает на KDE)
GDK_BACKEND=x11 v3xtun
```

Чтобы закрепить рабочий вариант, допишите переменную в `Exec=` файла
`~/.local/share/applications/v3xtun.desktop` и в `~/.local/bin/v3xtun` (если делали
обёртку), либо экспортируйте в `~/.config/environment.d/` /  `~/.bashrc`.

> На NVIDIA с проприетарным драйвером под Wayland надёжнее всего вариант с
> `GDK_BACKEND=x11`.

### `cargo: command not found` / ошибки `webkit2gtk-4.1`

Не установлены зависимости сборки — см. раздел «Зависимости (Arch)».
`./install.sh` тоже выводит точную команду `pacman`.

## Лицензия

MIT.
