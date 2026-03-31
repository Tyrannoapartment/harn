#!/usr/bin/env bash
# harn installer
#
# Usage:
#   bash install.sh              # user install (~/.local/share/harn, ~/.local/bin/harn)
#   bash install.sh --global     # system-wide install (/usr/local/lib/harn, /usr/local/bin/harn)
#   HARN_PREFIX=/opt bash install.sh   # custom prefix

set -euo pipefail

R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' W=$'\033[1;37m' N=$'\033[0m'

ok()   { echo -e "${G}  ✓${N}  $*"; }
info() { echo -e "     $*"; }
warn() { echo -e "${Y}  !${N}  $*"; }
err()  { echo -e "${R}  ✗${N}  $*" >&2; }

# ── Determine install paths ───────────────────────────────────────────────────
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

# ── Dependency check ──────────────────────────────────────────────────────────
echo ""
echo -e "${W}harn installer${N}"
echo -e "────────────────────────────────────"
echo ""
echo -e "  Install path:  ${W}$LIB_DIR${N}"
echo -e "  Command:       ${W}$BIN_DIR/harn${N}"
echo ""

DEPS_OK=true

check_dep() {
  local cmd="$1" hint="${2:-}"
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd  $(command -v "$cmd")"
  else
    warn "$cmd not found${hint:+ — $hint}"
    DEPS_OK=false
  fi
}

echo -e "${W}Checking dependencies${N}"
check_dep python3

# AI CLI — copilot or claude, one is enough
if command -v copilot &>/dev/null; then
  ok "copilot  $(command -v copilot)  ${W}(AI CLI)${N}"
elif command -v claude &>/dev/null; then
  ok "claude  $(command -v claude)  ${W}(AI CLI)${N}"
else
  warn "No AI CLI found — install copilot or claude"
  info "copilot: npm install -g @githubnext/github-copilot-cli"
  info "claude:  https://claude.ai/code"
  DEPS_OK=false
fi
echo ""

if [[ "$DEPS_OK" == "false" ]]; then
  warn "Some dependencies are missing. Install them to enable all features."
  echo ""
fi

# ── Install files ─────────────────────────────────────────────────────────────
echo -e "${W}Installing files...${N}"

if [[ "$GLOBAL" == "true" ]]; then
  sudo mkdir -p "$LIB_DIR" "$BIN_DIR"
  COPY="sudo cp"; LN="sudo ln"; CHMOD="sudo chmod"
else
  mkdir -p "$LIB_DIR" "$BIN_DIR"
  COPY="cp"; LN="ln"; CHMOD="chmod"
fi

$COPY "$SRC_DIR/harn.sh" "$LIB_DIR/harn.sh"
$CHMOD +x "$LIB_DIR/harn.sh"
ok "harn.sh"

$COPY -r "$SRC_DIR/parser" "$LIB_DIR/"
ok "parser/"

$COPY -r "$SRC_DIR/prompts" "$LIB_DIR/"
ok "prompts/"

$LN -sf "$LIB_DIR/harn.sh" "$BIN_DIR/harn"
ok "harn → $LIB_DIR/harn.sh"

# ── PATH check ────────────────────────────────────────────────────────────────
echo ""
if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  ok "${W}harn${N} is ready to use!"
else
  warn "${W}$BIN_DIR${N} is not in your PATH."
  echo ""
  echo "  Add the following to your shell config (~/.zshrc or ~/.bashrc):"
  echo ""
  echo -e "    ${W}export PATH=\"$BIN_DIR:\$PATH\"${N}"
  echo ""
  echo "  Then reload your shell:"
  echo -e "    ${W}source ~/.zshrc${N}  or  ${W}source ~/.bashrc${N}"
fi

echo ""
echo -e "────────────────────────────────────"
echo -e "${G}Installation complete!${N}"
echo ""
echo "  Navigate to your project and run:"
echo -e "    ${W}cd /path/to/your/project${N}"
echo -e "    ${W}harn start${N}   ← setup wizard runs automatically on first use"
echo ""
