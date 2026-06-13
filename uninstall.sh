#!/usr/bin/env bash
# v3xtun — удаление команды, ярлыка и иконки (репозиторий не трогает).
set -euo pipefail

rm -f "$HOME/.local/bin/v3xtun"
rm -f "$HOME/.local/share/applications/v3xtun.desktop"
rm -f "$HOME/.local/share/icons/hicolor/512x512/apps/v3xtun.png"
rm -f "$HOME/.config/autostart/v3xtun.desktop"

echo "v3xtun удалён из ~/.local. Настройки в ~/.config/dev.v3xtun.app/ оставлены."
echo "Чтобы удалить настройки:  rm -rf ~/.config/dev.v3xtun.app"
