#!/usr/bin/env bash
# harn 제거 스크립트

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
echo -e "${W}harn 제거${N}"
echo -e "────────────────────────────────────"
echo ""

RM="rm"
[[ "$GLOBAL" == "true" ]] && RM="sudo rm"

if [[ -L "$BIN_DIR/harn" ]]; then
  $RM -f "$BIN_DIR/harn"
  echo -e "${G}  ✓${N}  $BIN_DIR/harn 제거됨"
fi

if [[ -d "$LIB_DIR" ]]; then
  $RM -rf "$LIB_DIR"
  echo -e "${G}  ✓${N}  $LIB_DIR 제거됨"
fi

echo ""
echo -e "${Y}  !${N}  프로젝트 내 .harness/ 와 .harness_config 는 제거하지 않았습니다."
echo "     직접 삭제하려면: rm -rf .harness .harness_config"
echo ""
echo -e "${G}제거 완료${N}"
echo ""
