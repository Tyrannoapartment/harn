#!/usr/bin/env bash
# harn uninstaller

set -euo pipefail

G=$'\033[0;32m' Y=$'\033[1;33m' W=$'\033[1;37m' N=$'\033[0m'

GLOBAL=false
[[ "${1:-}" == "--global" ]] && GLOBAL=true

if [[ -n "${HARN_PREFIX:-}" ]]; then
  LIB_DIR="$HARN_PREFIX/lib/harn"
  BIN_DIR="$HARN_PREFIX/bin"
elif [[ "$GLOBAL" == "true" ]]; then
  LIB_DIR="/usr/local/lib/harn"
  BIN_DIR="/usr/local/bin"
else
  LIB_DIR="${HOME}/.local/share/harn"
  BIN_DIR="${HOME}/.local/bin"
fi

echo ""
echo -e "${W}harn uninstaller${N}"
echo -e "────────────────────────────────────"
echo ""

RM="rm"
[[ "$GLOBAL" == "true" ]] && RM="sudo rm"

if [[ -L "$BIN_DIR/harn" ]]; then
  $RM -f "$BIN_DIR/harn"
  echo -e "${G}  ✓${N}  Removed $BIN_DIR/harn"
fi

if [[ -d "$LIB_DIR" ]]; then
  $RM -rf "$LIB_DIR"
  echo -e "${G}  ✓${N}  Removed $LIB_DIR"
fi

echo ""
echo -e "${Y}  !${N}  Project-level .harness/ and .harness_config were NOT removed."
echo "     To remove them manually: rm -rf .harness .harness_config"
echo ""
echo -e "${G}Uninstall complete.${N}"
echo ""
