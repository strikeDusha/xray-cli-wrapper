#!/usr/bin/env bash
# Installer for xr (xray-cli) on Arch Linux.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SRC="$(cd "$(dirname "$0")" && pwd)/xr"

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }

echo
echo "  $(c '1;38;5;209' 'xray-cli installer')"
echo

# 1. xray-core
if ! command -v xray >/dev/null 2>&1; then
  echo "  $(c '38;5;221' '!') xray-core is not installed."
  if command -v pacman >/dev/null 2>&1; then
    echo "      install it with:  $(c '38;5;116' 'sudo pacman -S xray')"
    echo "      or from the AUR:  $(c '38;5;116' 'yay -S xray-bin')"
  fi
  echo
else
  echo "  $(c '38;5;114' '✓') found $(xray version 2>/dev/null | head -1)"
fi

# 2. install the script
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC" "$BIN_DIR/xr"
echo "  $(c '38;5;114' '✓') installed xr → $BIN_DIR/xr"

# 3. PATH check
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  $(c '38;5;221' '!') $BIN_DIR is not on your PATH. Add to your shell rc:"
     echo "      $(c '38;5;116' "export PATH=\"$BIN_DIR:\$PATH\"")" ;;
esac

# 4. write systemd user unit (no daemon-reload failure if systemd absent)
if command -v systemctl >/dev/null 2>&1; then
  "$BIN_DIR/xr" install-unit >/dev/null 2>&1 || true
  echo "  $(c '38;5;114' '✓') wrote systemd --user unit (xray-cli.service)"
fi

echo
echo "  done. run  $(c '38;5;116' 'xr')  for the interactive shell, or  $(c '38;5;116' 'xr --help')"
echo
