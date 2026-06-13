#!/usr/bin/env bash
# v3xtun — запуск в режиме разработки (hot-reload).
# Использование:  ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"

command -v cargo >/dev/null || { echo "Нужен rust: sudo pacman -S rust" >&2; exit 1; }
command -v npm   >/dev/null || { echo "Нужен npm:  sudo pacman -S npm"  >&2; exit 1; }

[ -d node_modules ] || npm install
exec npm run tauri dev
