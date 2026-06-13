#!/usr/bin/env bash
# v3xtun — сборка релиза и установка команды `v3xtun` в PATH.
# Использование:  ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- проверка инструментов сборки ----
need=()
command -v cargo >/dev/null  || need+=("rust")
command -v npm   >/dev/null  || need+=("npm (nodejs)")
command -v node  >/dev/null  || need+=("nodejs")
pkg-config --exists webkit2gtk-4.1 2>/dev/null || need+=("webkit2gtk-4.1")
if [ "${#need[@]}" -gt 0 ]; then
  warn "Не хватает зависимостей сборки: ${need[*]}"
  echo  "    Установите на Arch:"
  echo  "    sudo pacman -S --needed rust nodejs npm webkit2gtk-4.1 base-devel libappindicator-gtk3 librsvg patchelf"
  die   "Установите зависимости и запустите снова."
fi

# ---- рантайм-бинари (предупреждение, не критично для сборки) ----
command -v xray >/dev/null || warn "xray не найден в PATH — нужен для работы (sudo pacman -S xray  или  yay -S xray-bin)."
if ! command -v tun2proxy-bin >/dev/null && ! command -v tun2proxy >/dev/null; then
  warn "tun2proxy не найден в PATH — нужен для работы (yay -S tun2proxy)."
fi

# ---- сборка ----
say "Установка npm-зависимостей…"
npm install

say "Сборка фронтенда…"
npm run build

say "Сборка релизного бинаря (cargo build --release)…"
( cd src-tauri && cargo build --release )

BIN="$HERE/src-tauri/target/release/v3xtun"
[ -x "$BIN" ] || die "Бинарь не собрался: $BIN"

# ---- установка команды и ярлыка ----
BINDIR="$HOME/.local/bin"
APPDIR="$HOME/.local/share/applications"
ICONDIR="$HOME/.local/share/icons/hicolor/512x512/apps"
mkdir -p "$BINDIR" "$APPDIR" "$ICONDIR"

ln -sf "$BIN" "$BINDIR/v3xtun"
install -m644 "$HERE/src-tauri/icons/icon.png" "$ICONDIR/v3xtun.png"

cat > "$APPDIR/v3xtun.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=v3xtun
Comment=GUI для tun2proxy + xray
Exec=$BINDIR/v3xtun
Icon=v3xtun
Terminal=false
Categories=Network;
EOF

say "Готово."
echo "    Команда:   v3xtun        (запустит GUI)"
echo "    Справка:   v3xtun --help"
echo "    Ярлык:     меню приложений → v3xtun"

case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *) warn "$BINDIR не в PATH. Добавьте в ~/.bashrc или ~/.zshrc:"
     echo  '       export PATH="$HOME/.local/bin:$PATH"' ;;
esac
