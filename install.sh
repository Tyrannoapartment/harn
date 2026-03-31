#!/usr/bin/env bash
# harn 설치 스크립트
#
# 사용법:
#   bash install.sh              # 기본 설치 (~/.local/share/harn, ~/.local/bin/harn)
#   bash install.sh --global     # 시스템 전역 설치 (/usr/local/lib/harn, /usr/local/bin/harn)
#   HARN_PREFIX=/opt bash install.sh   # 커스텀 경로

set -euo pipefail

# ── 색상 ───────────────────────────────────────────────────────────────────────
R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' W=$'\033[1;37m' N=$'\033[0m'

ok()   { echo -e "${G}  ✓${N}  $*"; }
info() { echo -e "     $*"; }
warn() { echo -e "${Y}  !${N}  $*"; }
err()  { echo -e "${R}  ✗${N}  $*" >&2; }

# ── 경로 결정 ─────────────────────────────────────────────────────────────────
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

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 의존성 확인 ───────────────────────────────────────────────────────────────
echo ""
echo -e "${W}harn 설치${N}"
echo -e "────────────────────────────────────"
echo ""
echo -e "  설치 위치:  ${W}$LIB_DIR${N}"
echo -e "  명령어:     ${W}$BIN_DIR/harn${N}"
echo ""

DEPS_OK=true

check_dep() {
  local cmd="$1" hint="${2:-}"
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd $(command -v "$cmd")"
  else
    warn "$cmd 를 찾을 수 없습니다${hint:+ — $hint}"
    DEPS_OK=false
  fi
}

echo -e "${W}의존성 확인${N}"
check_dep python3

# AI CLI — copilot 또는 claude 중 하나만 있으면 됨
if command -v copilot &>/dev/null; then
  ok "copilot $(command -v copilot)  ${W}(AI CLI)${N}"
elif command -v claude &>/dev/null; then
  ok "claude $(command -v claude)  ${W}(AI CLI)${N}"
else
  warn "AI CLI 없음 — copilot 또는 claude 중 하나를 설치하세요"
  info "copilot: npm install -g @githubnext/github-copilot-cli"
  info "claude:  https://claude.ai/code"
  DEPS_OK=false
fi
echo ""

if [[ "$DEPS_OK" == "false" ]]; then
  warn "일부 의존성이 없습니다. 설치 후 누락된 기능이 있을 수 있습니다."
  echo ""
fi

# ── 설치 ─────────────────────────────────────────────────────────────────────
echo -e "${W}파일 설치 중...${N}"

# 라이브러리 디렉터리 생성
if [[ "$GLOBAL" == "true" ]]; then
  sudo mkdir -p "$LIB_DIR" "$BIN_DIR"
  COPY="sudo cp"
  LN="sudo ln"
  CHMOD="sudo chmod"
else
  mkdir -p "$LIB_DIR" "$BIN_DIR"
  COPY="cp"
  LN="ln"
  CHMOD="chmod"
fi

# 파일 복사
$COPY "$SRC_DIR/harn.sh" "$LIB_DIR/harn.sh"
$CHMOD +x "$LIB_DIR/harn.sh"
ok "harn.sh"

$COPY -r "$SRC_DIR/parser" "$LIB_DIR/"
ok "parser/"

$COPY -r "$SRC_DIR/prompts" "$LIB_DIR/"
ok "prompts/"

# harn 명령어 링크
$LN -sf "$LIB_DIR/harn.sh" "$BIN_DIR/harn"
ok "harn → $LIB_DIR/harn.sh"

# ── PATH 확인 ─────────────────────────────────────────────────────────────────
echo ""
if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  ok "${W}harn${N} 명령어를 바로 사용할 수 있습니다!"
else
  warn "${W}$BIN_DIR${N} 가 PATH에 없습니다."
  echo ""
  echo "  셸 설정 파일(~/.zshrc 또는 ~/.bashrc)에 아래 줄을 추가하세요:"
  echo ""
  echo -e "    ${W}export PATH=\"$BIN_DIR:\$PATH\"${N}"
  echo ""
  echo "  추가 후 셸을 재시작하거나 다음을 실행하세요:"
  echo -e "    ${W}source ~/.zshrc${N}  또는  ${W}source ~/.bashrc${N}"
fi

echo ""
echo -e "────────────────────────────────────"
echo -e "${G}설치 완료!${N}"
echo ""
echo "  프로젝트 디렉터리로 이동 후 사용:"
echo -e "    ${W}cd /path/to/your/project${N}"
echo -e "    ${W}harn start${N}   ← 첫 실행 시 자동으로 설정 마법사가 시작됩니다"
echo ""
