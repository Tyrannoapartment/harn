#!/usr/bin/env bash
# harn — AI Multi-Agent Sprint Development Loop
#
#   Automates a Planner → Generator → Evaluator loop to implement backlog items sprint by sprint
#
# Usage:  harn <command>
#   harn start      select backlog item and run
#   harn auto       auto mode (resume / start / discover)
#   harn backlog    show pending items
#   harn status     current status
#   harn help       full help

set -euo pipefail

HARN_VERSION="1.1.2"

# Resolve symlink to find the actual script location (handles relative symlinks)
_THIS="${BASH_SOURCE[0]}"
while [[ -L "$_THIS" ]]; do
  _DIR="$(cd "$(dirname "$_THIS")" && pwd)"
  _THIS="$(readlink "$_THIS")"
  [[ "$_THIS" != /* ]] && _THIS="$_DIR/$_THIS"
done
SCRIPT_DIR="$(cd "$(dirname "$_THIS")" && pwd)"
ROOT_DIR="$(pwd)"
HARN_DIR="$ROOT_DIR/.harn"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
CONFIG_FILE="$ROOT_DIR/.harn_config"

# ── Backward-compat migration: .harness/ → .harn/ ─────────────────────────────
if [[ ! -d "$HARN_DIR" && -d "$ROOT_DIR/.harness" ]]; then
  mv "$ROOT_DIR/.harness" "$HARN_DIR" 2>/dev/null || true
fi
if [[ ! -f "$CONFIG_FILE" && -f "$ROOT_DIR/.harness_config" ]]; then
  mv "$ROOT_DIR/.harness_config" "$CONFIG_FILE" 2>/dev/null || true
fi

# Defaults (before config is loaded)
BACKLOG_FILE="$ROOT_DIR/sprint-backlog.md"
BACKLOG_FILE_DISPLAY="${BACKLOG_FILE}"
MAX_ITERATIONS=5
GIT_ENABLED="false"
GIT_BASE_BRANCH="main"
GIT_PR_TARGET_BRANCH="main"
GIT_PLAN_PREFIX="plan/"
GIT_FEAT_PREFIX="feat/"
GIT_AUTO_PUSH="false"
GIT_AUTO_PR="false"
GIT_PR_DRAFT="true"
GIT_AUTO_MERGE="false"
CUSTOM_PROMPTS_DIR=""
SPRINT_COUNT=2
SPRINT_ROLES=""

# Retrospective suppression flag (prevents per-item retro in harn all)
HARN_SKIP_RETRO="false"

# Configurable test/lint/E2E commands (empty = auto-detect)
LINT_COMMAND=""
TEST_COMMAND=""
E2E_COMMAND=""

# AI backend (copilot | claude) — set by init, overridable via AI_BACKEND env
AI_BACKEND=""
AI_BACKEND_PLANNER=""
AI_BACKEND_GENERATOR_CONTRACT=""
AI_BACKEND_GENERATOR_IMPL=""
AI_BACKEND_EVALUATOR_CONTRACT=""
AI_BACKEND_EVALUATOR_QA=""

# Role-specific model defaults (can be overridden via config or env)
COPILOT_MODEL_PLANNER="claude-haiku-4.5"
COPILOT_MODEL_GENERATOR_CONTRACT="claude-sonnet-4.6"
COPILOT_MODEL_GENERATOR_IMPL="claude-opus-4.6"
COPILOT_MODEL_EVALUATOR_CONTRACT="claude-haiku-4.5"
COPILOT_MODEL_EVALUATOR_QA="claude-sonnet-4.5"

# ── Log setup ──────────────────────────────────────────────────────────────────
mkdir -p "$HARN_DIR"
LOG_FILE="$HARN_DIR/harn.log"

# ── Colors & styles ────────────────────────────────────────────────────────────
R=$'\033[0;31m'   # red
G=$'\033[0;32m'   # green
Y=$'\033[0;33m'   # yellow
B=$'\033[0;34m'   # blue
M=$'\033[0;35m'   # magenta
C=$'\033[0;36m'   # cyan
W=$'\033[1;37m'   # bold white
D=$'\033[2m'      # dim
N=$'\033[0m'      # reset
BLD=$'\033[1m'    # bold

# User instructions session buffer
USER_EXTRA_INSTRUCTIONS=""

# ── Log functions ──────────────────────────────────────────────────────────────
_ts()      { date '+%H:%M:%S'; }
_log_raw() { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"; }

log_info() { _log_raw "  ${D}$(_ts)${N}  $*"; }
log_ok()   { _log_raw "  ${G}✓${N}  $*"; }
log_warn() { _log_raw "  ${Y}⚠${N}  $*"; }
log_err()  { _HARN_SILENT_EXIT=1; _log_raw "  ${R}✗${N}  $*" >&2; }

log_step() {
  _log_raw ""
  _log_raw "${C}  ┄┄ ${W}$*${N}"
  _log_raw "${C}  $(printf '─%.0s' {1..56})${N}"
}

log_agent_start() {
  local model="$1" role="$2" task="$3"
  local ansi_color
  case "$model" in
    *claude*) ansi_color=$'\033[0;34m' ;;  # blue
    copilot*) ansi_color=$'\033[0;32m' ;;  # green
    *)        ansi_color=$'\033[0;36m' ;;  # cyan
  esac
  local output
  output=$(python3 -c '
import sys, os, unicodedata

def wcswidth(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W","F") else 1 for c in s)

def trunc(s, width):
    out, cur = "", 0
    for c in s:
        cw = 2 if unicodedata.east_asian_width(c) in ("W","F") else 1
        if cur + cw > width - 1:
            return out + "\u2026"
        out += c; cur += cw
    return out

color  = sys.argv[1]
model  = sys.argv[2]
role   = sys.argv[3]
task   = sys.argv[4]

reset  = "\033[0m"
bold_w = "\033[1;37m"
dim    = "\033[2m"

try:
    cols = os.get_terminal_size().columns
except OSError:
    cols = 80

inner = max(cols - 6, 20)   # 6 = "  │  " prefix width
bar   = color + "  " + "\u2500" * (inner + 4) + reset

header = trunc(model + "  \u00b7  " + role, inner)
detail = trunc(task, inner)

print()
print(bar)
print(color + "  \u2502" + reset + "  " + bold_w + header + reset)
print(color + "  \u2502" + reset + "  " + dim    + detail + reset)
print(bar)
print()
' "$ansi_color" "$model" "$role" "$task")
  # Terminal output + log file write (ANSI stripped)
  echo -e "$output"
  echo -e "$output" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

log_agent_done() {
  _log_raw ""
  _log_raw "${D}  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌${N}"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
_print_banner() {
  python3 - <<'PYEOF'
import unicodedata

def wcswidth(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)

def pad(s, width):
    return s + ' ' * max(0, width - wcswidth(s))

W = 44
cyan   = "\033[0;36m"
bwhite = "\033[1;37m"
dim    = "\033[2m"
bold   = "\033[1m"
reset  = "\033[0m"

title    = "◆ harn"
subtitle = "AI Multi-Agent Sprint Loop"

top    = cyan + "  ╭" + "─" * W + "╮" + reset
line1  = cyan + "  │" + reset + "  " + bold + bwhite + pad(title, W - 2) + reset + cyan + "│" + reset
line2  = cyan + "  │" + reset + "  " + dim + pad(subtitle, W - 2) + reset + cyan + "│" + reset
bottom = cyan + "  ╰" + "─" * W + "╯" + reset

print()
print(top)
print(line1)
print(line2)
print(bottom)
print()
PYEOF
}

# ── Sprint progress ────────────────────────────────────────────────────────────
_print_sprint_progress() {
  local current="$1" total="$2"
  [[ "$total" -le 0 ]] && return
  local filled=$(( current * 12 / total ))
  local bar="" i
  for i in $(seq 1 12); do
    if [[ $i -le $filled ]]; then bar="${bar}${G}▓${N}"
    else bar="${bar}${D}░${N}"; fi
  done
  _log_raw ""
  _log_raw "  ${D}Sprint${N} ${W}${current}${N}${D}/${total}${N}  ${bar}  ${D}$((current * 100 / total))%${N}"
  _log_raw ""
}

# ── User instructions input ────────────────────────────────────────────────────
_ask_user_instructions() {
  local context="${1:-next agent}"

  # Skip in non-interactive environments (pipes, CI, etc.)
  [[ ! -t 1 ]] && return 0

  echo -e "" >/dev/tty
  echo -e "${B}  ╭─ 💬 Additional instructions${N}" >/dev/tty
  echo -e "${B}  │${N}  Enter instructions to pass to ${W}${context}${N}." >/dev/tty
  echo -e "${B}  │${N}  ${D}Empty line = skip  ·  Multi-line input supported${N}" >/dev/tty
  echo -e "${B}  ╰${N}" >/dev/tty

  local content
  content=$(_input_multiline)

  if [[ -n "$content" ]]; then
    USER_EXTRA_INSTRUCTIONS="${USER_EXTRA_INSTRUCTIONS}
## User Instructions ($(_ts))

${content}"
    echo -e "  ${G}✓${N}  Will be passed to the next agent." >/dev/tty
    echo -e "" >/dev/tty
  fi
}

# ── Python readline-based input helpers ─────────────────────────────────────────
# Correctly handles backspace for multi-byte characters (e.g., Korean) via readline/libedit

# Single line input — raw mode + direct wide-char backspace handling
# (macOS libedit mishandles backspace for 2-column Korean characters)
_input_readline() {
  python3 -c '
import sys, tty, termios, unicodedata

def cw(c):
    return 2 if unicodedata.east_asian_width(c) in ("W","F") else 1

fd = open("/dev/tty","rb+",buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)
chars = []
buf = b""
cancelled = False
try:
    while True:
        b = fd.read(1)
        if not b: break
        byte = b[0]
        if byte in (13,10):
            fd.write(b"\r\n"); fd.flush(); break
        elif byte in (127,8):
            if chars:
                c = chars.pop(); w = cw(c)
                fd.write(b"\x08"*w + b" "*w + b"\x08"*w); fd.flush()
        elif byte == 3:
            raise KeyboardInterrupt
        elif byte == 17:
            raise KeyboardInterrupt
        elif byte == 4:
            if not chars: break
        elif byte == 27:
            b2 = fd.read(1)
            if b2 == b"[":
                while True:
                    b3 = fd.read(1)
                    if b3 and 0x40 <= b3[0] <= 0x7e: break
        elif byte >= 32:
            buf += b
            try:
                c = buf.decode("utf-8"); chars.append(c); buf = b""
                fd.write(c.encode("utf-8")); fd.flush()
            except UnicodeDecodeError:
                pass
except KeyboardInterrupt:
    cancelled = True
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
fd.close()
if cancelled:
    sys.exit(1)
result = "".join(chars)
if result: print(result, end="")
'
}

# Multi-line input (empty line = done) — raw mode + wide-char backspace
_input_multiline() {
  python3 -c '
import sys, tty, termios, unicodedata

def cw(c):
    return 2 if unicodedata.east_asian_width(c) in ("W","F") else 1

PROMPT = "  \033[36m\u276f\033[0m "

def read_line(fd):
    fd.write(PROMPT.encode()); fd.flush()
    chars = []
    buf = b""
    while True:
        b = fd.read(1)
        if not b: return None
        byte = b[0]
        if byte in (13,10):
            fd.write(b"\r\n"); fd.flush()
            return "".join(chars)
        elif byte in (127,8):
            if chars:
                c = chars.pop(); w = cw(c)
                fd.write(b"\x08"*w + b" "*w + b"\x08"*w); fd.flush()
        elif byte == 3:
            raise KeyboardInterrupt
        elif byte == 4:
            if not chars: return None
        elif byte == 27:
            b2 = fd.read(1)
            if b2 == b"[":
                while True:
                    b3 = fd.read(1)
                    if b3 and 0x40 <= b3[0] <= 0x7e: break
        elif byte >= 32:
            buf += b
            try:
                c = buf.decode("utf-8"); chars.append(c); buf = b""
                fd.write(c.encode("utf-8")); fd.flush()
            except UnicodeDecodeError:
                pass

fd = open("/dev/tty","rb+",buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)
lines = []
try:
    while True:
        line = read_line(fd)
        if line is None: break
        if line == "": break
        lines.append(line)
except KeyboardInterrupt:
    pass
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
fd.close()
if lines: print("\n".join(lines), end="")
'
}

# Arrow-key menu selector
# Usage: _pick_menu "prompt text" default_index item1 item2 ...
# Stdout: selected item; exits 1 on Ctrl+Q/Ctrl+C
_pick_menu() {
  local menu_prompt="$1" default_idx="${2:-0}"
  shift 2
  local items=("$@")
  [[ ${#items[@]} -eq 0 ]] && return 1
  python3 -c '
import sys, tty, termios

prompt    = sys.argv[1]
def_idx   = int(sys.argv[2]) if len(sys.argv) > 2 else 0
items     = sys.argv[3:]
n         = len(items)
if n == 0: sys.exit(1)
idx       = min(def_idx, n - 1)

fd  = open("/dev/tty", "rb+", buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)

def render():
    out = b""
    for i, item in enumerate(items):
        if i == idx:
            out += f"  \033[36m\u276f\033[0m \033[1m{item}\033[0m\r\n".encode()
        else:
            out += f"    \033[2m{item}\033[0m\r\n".encode()
    return out

selected  = None
cancelled = False
try:
    fd.write(f"\r\n  \033[1m{prompt}\033[0m\r\n".encode())
    fd.write(b"  \033[2m(\xe2\x86\x91\xe2\x86\x93 navigate  Enter select  Ctrl+Q cancel)\033[0m\r\n\r\n")
    fd.write(render())
    fd.write(f"\033[{n}A".encode())
    fd.flush()
    while True:
        fd.write(render())
        fd.write(f"\033[{n}A".encode())
        fd.flush()
        b = fd.read(1)
        if not b: break
        byte = b[0]
        if byte in (13, 10):
            selected = items[idx]; break
        elif byte in (17, 3):
            cancelled = True; break
        elif byte == 27:
            b2 = fd.read(1)
            if b2 == b"[":
                b3 = fd.read(1)
                if   b3 == b"A": idx = (idx - 1) % n
                elif b3 == b"B": idx = (idx + 1) % n
                elif b3 in (b"5", b"6"): fd.read(1)
finally:
    fd.write(f"\033[{n}B\r\n".encode())
    fd.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    fd.close()
if selected and not cancelled:
    print(selected, end="")
    sys.exit(0)
sys.exit(1)
' "$menu_prompt" "$default_idx" "${items[@]}"
}

COPILOT_MODEL_FLAG_SUPPORT=""

copilot_supports_model_flag() {
  if [[ -n "$COPILOT_MODEL_FLAG_SUPPORT" ]]; then
    [[ "$COPILOT_MODEL_FLAG_SUPPORT" == "true" ]]
    return
  fi

  if copilot --help 2>/dev/null | grep -q -- "--model"; then
    COPILOT_MODEL_FLAG_SUPPORT="true"
  else
    COPILOT_MODEL_FLAG_SUPPORT="false"
  fi

  [[ "$COPILOT_MODEL_FLAG_SUPPORT" == "true" ]]
}

# ── Role-specific model configuration ───────────────────────────────────────

validate_role_models() {
  : # All roles use copilot — no separate validation needed
}

print_model_config() {
  local backend; backend=$(_detect_ai_cli)
  [[ -z "$backend" ]] && backend="(not detected)"
  echo -e "${W}harn Role Model Config${N}  [backend: ${W}${backend}${N}]"
  echo -e "  planner               : ${W}$COPILOT_MODEL_PLANNER${N}       (env: HARN_MODEL_PLANNER)"
  echo -e "  generator (contract)  : ${W}$COPILOT_MODEL_GENERATOR_CONTRACT${N}  (env: HARN_MODEL_GENERATOR_CONTRACT)"
  echo -e "  generator (implement) : ${W}$COPILOT_MODEL_GENERATOR_IMPL${N}     (env: HARN_MODEL_GENERATOR_IMPL)"
  echo -e "  evaluator (contract)  : ${W}$COPILOT_MODEL_EVALUATOR_CONTRACT${N}  (env: HARN_MODEL_EVALUATOR_CONTRACT)"
  echo -e "  evaluator (qa)        : ${W}$COPILOT_MODEL_EVALUATOR_QA${N}       (env: HARN_MODEL_EVALUATOR_QA)"
}

# ── Config loading ──────────────────────────────────────────────────────────────

load_config() {
  [[ ! -f "$CONFIG_FILE" ]] && return

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # Convert relative BACKLOG_FILE path → absolute path
  if [[ -n "${BACKLOG_FILE:-}" && "${BACKLOG_FILE}" != /* ]]; then
    BACKLOG_FILE="$ROOT_DIR/$BACKLOG_FILE"
  fi
  BACKLOG_FILE_DISPLAY="$BACKLOG_FILE"

  # Apply MODEL_* vars from config → internal COPILOT_MODEL_* (env override takes precedence)
  COPILOT_MODEL_PLANNER="${HARN_MODEL_PLANNER:-${MODEL_PLANNER:-$COPILOT_MODEL_PLANNER}}"
  COPILOT_MODEL_GENERATOR_CONTRACT="${HARN_MODEL_GENERATOR_CONTRACT:-${MODEL_GENERATOR_CONTRACT:-$COPILOT_MODEL_GENERATOR_CONTRACT}}"
  COPILOT_MODEL_GENERATOR_IMPL="${HARN_MODEL_GENERATOR_IMPL:-${MODEL_GENERATOR_IMPL:-$COPILOT_MODEL_GENERATOR_IMPL}}"
  COPILOT_MODEL_EVALUATOR_CONTRACT="${HARN_MODEL_EVALUATOR_CONTRACT:-${MODEL_EVALUATOR_CONTRACT:-$COPILOT_MODEL_EVALUATOR_CONTRACT}}"
  COPILOT_MODEL_EVALUATOR_QA="${HARN_MODEL_EVALUATOR_QA:-${MODEL_EVALUATOR_QA:-$COPILOT_MODEL_EVALUATOR_QA}}"

  # Apply AI_BACKEND from config (env override takes precedence)
  AI_BACKEND="${HARN_AI_BACKEND:-${AI_BACKEND:-}}"

  # Per-role backend overrides (fall back to global AI_BACKEND)
  AI_BACKEND_PLANNER="${AI_BACKEND_PLANNER:-$AI_BACKEND}"
  AI_BACKEND_GENERATOR_CONTRACT="${AI_BACKEND_GENERATOR_CONTRACT:-$AI_BACKEND}"
  AI_BACKEND_GENERATOR_IMPL="${AI_BACKEND_GENERATOR_IMPL:-$AI_BACKEND}"
  AI_BACKEND_EVALUATOR_CONTRACT="${AI_BACKEND_EVALUATOR_CONTRACT:-$AI_BACKEND}"
  AI_BACKEND_EVALUATOR_QA="${AI_BACKEND_EVALUATOR_QA:-$AI_BACKEND}"

  # Apply sprint settings from config
  SPRINT_COUNT="${SPRINT_COUNT:-2}"
  SPRINT_ROLES="${SPRINT_ROLES:-}"

  # Apply custom prompts directory
  if [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]]; then
    local custom_abs="$CUSTOM_PROMPTS_DIR"
    [[ "${CUSTOM_PROMPTS_DIR}" != /* ]] && custom_abs="$ROOT_DIR/$CUSTOM_PROMPTS_DIR"
    [[ -d "$custom_abs" ]] && PROMPTS_DIR="$custom_abs"
  fi
}

# ── Custom prompt generation ───────────────────────────────────────────────────

# Detect AI CLI: config/env override → auto-detect
_detect_ai_cli() {
  # Explicit override via env or loaded config
  local backend="${AI_BACKEND:-}"
  if [[ -n "$backend" ]]; then
    echo "$backend"; return
  fi
  # Auto-detect
  if command -v copilot &>/dev/null; then echo "copilot"
  elif command -v claude &>/dev/null; then echo "claude"
  else echo ""
  fi
}

# Check which AI CLIs are installed; print a guidance message if none
_check_ai_cli_installed() {
  local has_copilot=false has_claude=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude   &>/dev/null && has_claude=true

  if [[ "$has_copilot" == "false" && "$has_claude" == "false" ]]; then
    echo -e "\n${R}✗ No AI CLI found.${N}"
    echo -e "  harn requires ${W}GitHub Copilot CLI${N} or ${W}Claude CLI${N}.\n"
    echo -e "  ${W}GitHub Copilot CLI${N} (requires GitHub Copilot subscription)"
    echo -e "    npm install -g @githubnext/github-copilot-cli"
    echo -e "    gh auth login && gh copilot --version\n"
    echo -e "  ${W}Claude CLI${N} (requires Anthropic API key)"
    echo -e "    npm install -g @anthropic-ai/claude-cli   (or: pip install claude-cli)"
    echo -e "    export ANTHROPIC_API_KEY=sk-ant-..."
    echo -e "    claude --version\n"
    return 1
  fi
  return 0
}

# Interactive AI backend selection; sets AI_BACKEND variable
_select_ai_backend() {
  local has_copilot=false has_claude=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude   &>/dev/null && has_claude=true

  if [[ "$has_copilot" == "true" && "$has_claude" == "true" ]]; then
    local choice
    choice=$(_pick_menu "Default AI backend" 0 "copilot  (GitHub Copilot CLI)" "claude   (Anthropic Claude CLI)") || return 1
    [[ "$choice" == claude* ]] && AI_BACKEND="claude" || AI_BACKEND="copilot"
  elif [[ "$has_copilot" == "true" ]]; then
    AI_BACKEND="copilot"
    echo -e "\n${G}✓${N} Using ${W}copilot${N} (GitHub Copilot CLI detected)"
  elif [[ "$has_claude" == "true" ]]; then
    AI_BACKEND="claude"
    echo -e "\n${G}✓${N} Using ${W}claude${N} (Anthropic Claude CLI detected)"
  fi
}

_get_models_for_backend() {
  local backend="$1"
  if [[ "$backend" == "claude" ]]; then
    printf '%s\n' \
      "claude-haiku-4.5" "claude-sonnet-4.5" "claude-sonnet-4.6" \
      "claude-opus-4.5"  "claude-opus-4.6"
  else  # copilot — supports both claude and GPT models
    printf '%s\n' \
      "claude-haiku-4.5" "claude-sonnet-4.5" "claude-sonnet-4.6" \
      "claude-opus-4.5"  "claude-opus-4.6" \
      "gpt-4.1" "gpt-4o" "gpt-4o-mini" "o1" "o3-mini"
  fi
}

# Select AI backend + model for a role interactively.
# Prints "backend model" on success, exits 1 on cancel.
_pick_role_model() {
  local role_label="$1" default_backend="${2:-copilot}" default_model="$3"

  local has_copilot=false has_claude=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  [[ "$has_copilot" == "false" && "$has_claude" == "false" ]] && {
    log_err "No AI CLI found. Run: harn init"; return 1
  }

  # Build flat combined list: "backend / model"
  local options=()
  if [[ "$has_copilot" == "true" ]]; then
    while IFS= read -r m; do [[ -n "$m" ]] && options+=("copilot / $m"); done \
      < <(_get_models_for_backend "copilot")
  fi
  if [[ "$has_claude" == "true" ]]; then
    while IFS= read -r m; do [[ -n "$m" ]] && options+=("claude / $m"); done \
      < <(_get_models_for_backend "claude")
  fi

  # Find default index
  local def_i=0
  local default_str="${default_backend} / ${default_model}"
  for i in "${!options[@]}"; do
    [[ "${options[$i]}" == "$default_str" ]] && { def_i=$i; break; }
  done

  local selected
  selected=$(_pick_menu "${role_label}" "$def_i" "${options[@]}") || return 1

  # Parse "backend / model" → "backend model"
  local backend="${selected%% /*}"
  local model="${selected##*/ }"
  printf "%s %s" "$backend" "$model"
}

# Generate a single prompt using the AI CLI
_ai_generate() {
  local ai_cmd="$1" prompt_text="$2" out_file="$3"
  case "$ai_cmd" in
    copilot) copilot --yolo -p "$prompt_text" > "$out_file" 2>/dev/null ;;
    claude)  claude -p "$prompt_text" > "$out_file" 2>/dev/null ;;
  esac
}

# Generate custom prompt files based on per-agent instructions + Git guidelines
_generate_custom_prompts() {
  local hint_planner="$1" hint_generator="$2" hint_evaluator="$3" git_guide="$4"
  local custom_dir="$ROOT_DIR/.harn/prompts"
  mkdir -p "$custom_dir"

  local ai_cmd
  ai_cmd=$(_detect_ai_cli)

  local roles="planner generator evaluator"
  for role in $roles; do
    local base="$PROMPTS_DIR/${role}.md"
    local out="$custom_dir/${role}.md"

    # Select role-specific hint
    local hint=""
    case "$role" in
      planner)   hint="$hint_planner" ;;
      generator) hint="$hint_generator" ;;
      evaluator) hint="$hint_evaluator" ;;
    esac

    # Combine additional instructions
    local extra=""
    [[ -n "$git_guide" ]] && extra="${extra}
**Git workflow guidelines**: ${git_guide}"
    [[ -n "$hint"      ]] && extra="${extra}
**Special instructions**: ${hint}"

    # No instructions — copy base prompt
    if [[ -z "$extra" ]]; then
      cp "$base" "$out"
      continue
    fi

    local role_kr
    case "$role" in
      planner)   role_kr="Planner" ;;
      generator) role_kr="Generator" ;;
      evaluator) role_kr="Evaluator" ;;
    esac

    log_info "Generating ${role_kr} prompt..."

    if [[ -n "$ai_cmd" ]]; then
      local gen_prompt
      gen_prompt="Below is the base prompt for the ${role_kr} agent.

$(cat "$base")

---

Naturally integrate the following instructions into the prompt and output the entire revised prompt.
Output only the prompt content — no markdown code blocks (\`\`\`).

Instructions to add:
${extra}"

      if _ai_generate "$ai_cmd" "$gen_prompt" "$out"; then
        log_ok "${role_kr} prompt generated: ${W}$out${N}"
      else
        log_warn "${role_kr} prompt generation failed — adding instructions to base prompt"
        cp "$base" "$out"
        printf "\n\n## Additional instructions\n%s\n" "$extra" >> "$out"
      fi
    else
      # No AI CLI — append instructions directly to base prompt
      cp "$base" "$out"
      printf "\n\n## Additional instructions\n%s\n" "$extra" >> "$out"
      log_ok "${role_kr} prompt generated (manual): ${W}$out${N}"
    fi
  done
}

# ── Initialization wizard ──────────────────────────────────────────────────────

cmd_init() {
  echo -e "\n${W}══════════════════════════════════════════${N}"
  echo -e "${W}  harn initial setup${N}"
  echo -e "${W}══════════════════════════════════════════${N}"
  echo -e "Project root: ${W}$ROOT_DIR${N}"
  echo -e "Config file:  ${W}$CONFIG_FILE${N}\n"

  if [[ -f "$CONFIG_FILE" ]]; then
    printf "${Y}Config file already exists. Overwrite? [y/N]: ${N}"
    local ow; ow=$(_input_readline)
    echo ""
    [[ "$ow" == "y" || "$ow" == "Y" ]] || { log_info "Initialization cancelled"; return 0; }
  fi

  # ── Project basic settings ───────────────────────────────────────────────────
  local bf_default="sprint-backlog.md"
  printf "Backlog file path (relative to project root) [%s]: " "$bf_default"
  local bf_input; bf_input=$(_input_readline); echo ""
  local bf="${bf_input:-$bf_default}"

  printf "Max QA retry count [5]: "
  local mi_input; mi_input=$(_input_readline); echo ""
  local mi="${mi_input:-5}"

  # ── AI CLI detection ──────────────────────────────────────────────────────────
  _check_ai_cli_installed || return 1
  _select_ai_backend

  # ── AI model settings (per role) ──────────────────────────────────────────────
  echo -e "\n${W}AI model settings${N} — select AI tool and model for each role"
  echo -e "  ${D}Use ↑↓ arrows to navigate, Enter to select, Ctrl+Q to cancel init${N}\n"

  local mp mp_backend _tmp_p
  _tmp_p=$(_pick_role_model "Planner" "${AI_BACKEND:-copilot}" "claude-haiku-4.5") \
    || { echo ""; log_info "Init cancelled"; return 0; }
  read -r mp_backend mp <<< "$_tmp_p"

  local mgc mgc_backend _tmp_gc
  _tmp_gc=$(_pick_role_model "Generator (contract)" "${AI_BACKEND:-copilot}" "claude-sonnet-4.6") \
    || { echo ""; log_info "Init cancelled"; return 0; }
  read -r mgc_backend mgc <<< "$_tmp_gc"

  local mgi mgi_backend _tmp_gi
  _tmp_gi=$(_pick_role_model "Generator (impl)" "${AI_BACKEND:-copilot}" "claude-opus-4.6") \
    || { echo ""; log_info "Init cancelled"; return 0; }
  read -r mgi_backend mgi <<< "$_tmp_gi"

  local mec mec_backend _tmp_ec
  _tmp_ec=$(_pick_role_model "Evaluator (contract)" "${AI_BACKEND:-copilot}" "claude-haiku-4.5") \
    || { echo ""; log_info "Init cancelled"; return 0; }
  read -r mec_backend mec <<< "$_tmp_ec"

  local meq meq_backend _tmp_eq
  _tmp_eq=$(_pick_role_model "Evaluator (QA)" "${AI_BACKEND:-copilot}" "claude-sonnet-4.5") \
    || { echo ""; log_info "Init cancelled"; return 0; }
  read -r meq_backend meq <<< "$_tmp_eq"

  # ── Sprint structure ──────────────────────────────────────────────────────────
  echo -e "\n${W}Sprint structure${N}"
  printf "Number of sprints [2]: "
  local sc_input; sc_input=$(_input_readline); echo ""
  local sc="${sc_input:-2}"

  # Validate: must be a positive integer
  if ! [[ "$sc" =~ ^[1-9][0-9]*$ ]]; then
    log_warn "Invalid sprint count '$sc' — defaulting to 2"
    sc=2
  fi

  # If not default 2, ask what each sprint should do
  local sprint_roles_arr=()
  if [[ "$sc" -ne 2 ]]; then
    echo -e "  ${D}Describe the goal/role of each sprint (Enter = use default label)${N}"
    for ((i=1; i<=sc; i++)); do
      local padded; padded=$(printf "%03d" "$i")
      printf "  Sprint %s role: " "$padded"
      local sr; sr=$(_input_readline); echo ""
      sprint_roles_arr+=("Sprint ${padded}: ${sr:-Sprint ${padded} implementation}")
    done
  else
    sprint_roles_arr=(
      "Sprint 001: Complete feature implementation (all layers at once)"
      "Sprint 002: Full test suite for Sprint 001"
    )
  fi
  # Join with | delimiter for storage
  local sprint_roles_str
  sprint_roles_str=$(printf "%s|" "${sprint_roles_arr[@]}")
  sprint_roles_str="${sprint_roles_str%|}"

  # ── Git integration ─────────────────────────────────────────────────────────────
  echo -e "\n${W}Git integration${N}"
  printf "Enable Git integration? [y/N]: "
  local git_yn; git_yn=$(_input_readline); echo ""
  local git_en="false"
  local git_branch="main" git_pr_target="main" git_auto_push="false" git_auto_pr="false" git_pr_draft="true" git_guide=""

  if [[ "$git_yn" == "y" || "$git_yn" == "Y" ]]; then
    git_en="true"
    printf "Base working branch (branch off from) [main]: "
    local gb; gb=$(_input_readline); echo ""; git_branch="${gb:-main}"

    printf "PR target branch (where PRs are merged into) [%s]: " "$git_branch"
    local gpt; gpt=$(_input_readline); echo ""; git_pr_target="${gpt:-$git_branch}"

    printf "Auto push? [y/N]: "
    local gp; gp=$(_input_readline); echo ""
    [[ "$gp" == "y" || "$gp" == "Y" ]] && git_auto_push="true"

    printf "Auto PR creation? [y/N]: "
    local gpr; gpr=$(_input_readline); echo ""
    [[ "$gpr" == "y" || "$gpr" == "Y" ]] && git_auto_pr="true"

    if [[ "$git_auto_pr" == "true" ]]; then
      printf "Create PR as Draft? [Y/n]: "
      local gprd; gprd=$(_input_readline); echo ""
      [[ "$gprd" == "n" || "$gprd" == "N" ]] && git_pr_draft="false"
    fi

    echo -e "\n${B}Git workflow guidelines${N}"
    echo -e "  Enter branching strategy, commit conventions, PR rules, etc."
    echo -e "  These guidelines will be reflected in all agent prompts. (Enter = skip)"
    printf "> "
    git_guide=$(_input_readline); echo ""
  fi

  # ── Per-agent special instructions ──────────────────────────────────────────
  echo -e "\n${W}Per-agent special instructions${N}"
  echo -e "  Enter project architecture, tech stack, coding conventions, etc."
  echo -e "  The AI CLI will naturally integrate these into the base prompts. (Enter = skip)\n"

  printf "Planner   — spec/sprint planning instructions: "
  local hint_planner; hint_planner=$(_input_readline); echo ""

  printf "Generator — implementation instructions: "
  local hint_generator; hint_generator=$(_input_readline); echo ""

  printf "Evaluator — QA/evaluation instructions: "
  local hint_evaluator; hint_evaluator=$(_input_readline); echo ""

  # ── Write config file ───────────────────────────────────────────────────────
  local cpd=""
  cat > "$CONFIG_FILE" <<CFGEOF
# harn config file — $(date '+%Y-%m-%d %H:%M:%S')
# project: $ROOT_DIR

# === Project settings ===
BACKLOG_FILE="${bf}"
MAX_ITERATIONS=${mi}
SPRINT_COUNT=${sc}
SPRINT_ROLES="${sprint_roles_str}"

# === AI backend ===
AI_BACKEND="${AI_BACKEND}"
AI_BACKEND_PLANNER="${mp_backend}"
AI_BACKEND_GENERATOR_CONTRACT="${mgc_backend}"
AI_BACKEND_GENERATOR_IMPL="${mgi_backend}"
AI_BACKEND_EVALUATOR_CONTRACT="${mec_backend}"
AI_BACKEND_EVALUATOR_QA="${meq_backend}"

# === AI model settings ===
MODEL_PLANNER="${mp}"
MODEL_GENERATOR_CONTRACT="${mgc}"
MODEL_GENERATOR_IMPL="${mgi}"
MODEL_EVALUATOR_CONTRACT="${mec}"
MODEL_EVALUATOR_QA="${meq}"

# === Git integration ===
GIT_ENABLED="${git_en}"
GIT_BASE_BRANCH="${git_branch}"
GIT_PR_TARGET_BRANCH="${git_pr_target}"
GIT_PLAN_PREFIX="plan/"
GIT_FEAT_PREFIX="feat/"
GIT_AUTO_PUSH="${git_auto_push}"
GIT_AUTO_PR="${git_auto_pr}"
GIT_PR_DRAFT="${git_pr_draft}"
GIT_AUTO_MERGE="false"

# === Agent instructions (regenerate with harn init) ===
GIT_GUIDE="${git_guide}"
HINT_PLANNER="${hint_planner}"
HINT_GENERATOR="${hint_generator}"
HINT_EVALUATOR="${hint_evaluator}"

# === Custom prompts ===
CUSTOM_PROMPTS_DIR="${cpd}"
CFGEOF

  log_ok "Config file created: ${W}$CONFIG_FILE${N}"

  # ── Custom prompt generation ──────────────────────────────────────────────────
  if [[ -n "$hint_planner" || -n "$hint_generator" || -n "$hint_evaluator" || -n "$git_guide" ]]; then
    echo ""
    local ai_cmd; ai_cmd=$(_detect_ai_cli)
    if [[ -n "$ai_cmd" ]]; then
      log_info "Generating custom prompts with AI CLI(${W}${ai_cmd}${N})..."
    else
      log_warn "AI CLI not found — adding instructions directly to base prompts."
    fi
    _generate_custom_prompts "$hint_planner" "$hint_generator" "$hint_evaluator" "$git_guide"
    cpd=".harn/prompts"
    # Update CUSTOM_PROMPTS_DIR in config
    sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
  fi

  # Load the newly created config
  load_config

  echo ""
  log_ok "Initialization complete!"
  echo -e "  ${W}harn backlog${N}  — view backlog items"
  echo -e "  ${W}harn start${N}    — start the loop"
  echo ""
}

# ── Backlog helpers ───────────────────────────────────────────────────────────

# Pending item slug list (in-progress → pending order)
_ensure_backlog_file() {
  [[ -f "$BACKLOG_FILE" ]] && return 0
  log_warn "Backlog file not found: ${W}$BACKLOG_FILE${N}"
  log_info "Creating default backlog file..."
  mkdir -p "$(dirname "$BACKLOG_FILE")"
  cat > "$BACKLOG_FILE" <<'BACKLOG_EOF'
# Sprint Backlog

## Pending
<!-- Add backlog items below. Format:
- [ ] **slug-name**
  Brief description of the feature or task.
-->

## In Progress

## Done
BACKLOG_EOF
  log_ok "Created: ${W}$BACKLOG_FILE${N}"
  log_info "Add items with: ${W}harn add${N}  or edit the file directly"
  echo ""
}

backlog_pending_slugs() {
  [[ ! -f "$BACKLOG_FILE" ]] && return
  python3 - "$BACKLOG_FILE" <<'EOF'
import re, sys

content = open(sys.argv[1]).read()
sections = re.split(r'^## ', content, flags=re.MULTILINE)

in_progress = []
pending = []
for section in sections:
    name = section.split('\n', 1)[0].strip().lower()
    items = re.findall(r'- \[ \] \*\*([^*]+)\*\*', section)
    if 'in progress' in name:
        in_progress.extend(items)
    elif 'pending' in name:
        pending.extend(items)

for slug in in_progress + pending:
    print(slug)
EOF
}

# Return the full description block for a given slug
backlog_item_text() {
  local slug="$1"
  [[ ! -f "$BACKLOG_FILE" ]] && echo "(backlog not found)" && return
  python3 - "$BACKLOG_FILE" "$slug" <<'EOF'
import re, sys

content = open(sys.argv[1]).read()
slug = sys.argv[2]

pattern = r'(- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*[^\n]*\n(?:[ \t]+[^\n]*\n)*)'
match = re.search(pattern, content)
if match:
    print(match.group(1).strip())
else:
    print(f'(item "{slug}" not found in backlog)')
EOF
}

# Select next item: in-progress → pending order
backlog_next_slug() {
  backlog_pending_slugs | head -1
}

# Mark backlog item as done [x]
backlog_mark_done() {
  local slug="$1"
  [[ ! -f "$BACKLOG_FILE" ]] && return
  sed -i '' "s/- \[ \] \*\*${slug}\*\*/- [x] **${slug}**/" "$BACKLOG_FILE"
  log_ok "Backlog: ${W}$slug${N} marked as done"
}

# Upsert plan line for selected backlog item (In Progress items take priority)
backlog_upsert_plan_line() {
  local slug="$1"
  local plan_text="$2"

  [[ ! -f "$BACKLOG_FILE" ]] && return 2

  python3 - "$BACKLOG_FILE" "$slug" "$plan_text" <<'PYEOF'
import re
import sys

path, slug, plan_text = sys.argv[1], sys.argv[2], sys.argv[3].strip()
content = open(path, encoding='utf-8').read()
lines = content.splitlines()

slug_pattern = re.compile(r'^- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*')
plan_pattern = re.compile(r'^\s+plan:\s*')

candidates = []
i = 0
current_section = ''
while i < len(lines):
    line = lines[i]
    if line.startswith('## '):
        current_section = line[3:].strip().lower()
        i += 1
        continue

    if slug_pattern.match(line):
        start = i
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            if nxt.startswith('## '):
                break
            if nxt.startswith('- ['):
                break
            j += 1
        candidates.append((current_section, start, j))
        i = j
        continue

    i += 1

if not candidates:
    print(f'NOT_FOUND:{slug}')
    sys.exit(2)

target = None
for cand in candidates:
    if 'in progress' in cand[0]:
        target = cand
        break
if target is None:
    target = candidates[0]

_, start, end = target
item_lines = lines[start:end]
new_plan_line = f'  plan: {plan_text}'

changed = False
plan_idx = None
for idx in range(1, len(item_lines)):
    if plan_pattern.match(item_lines[idx]):
        plan_idx = idx
        break

if plan_idx is not None:
    if item_lines[plan_idx] != new_plan_line:
        item_lines[plan_idx] = new_plan_line
        changed = True
else:
    item_lines.insert(1, new_plan_line)
    changed = True

if not changed:
    print('UNCHANGED')
    sys.exit(3)

lines[start:end] = item_lines
new_content = '\n'.join(lines) + ('\n' if content.endswith('\n') else '')
open(path, 'w', encoding='utf-8').write(new_content)
print('UPDATED')
PYEOF
}

# ── Run management ──────────────────────────────────────────────────────────────
mkdir -p "$HARN_DIR/runs"

current_run_id() {
  [[ -L "$HARN_DIR/current" ]] && basename "$(readlink "$HARN_DIR/current")" || echo ""
}

require_run_dir() {
  local id
  id=$(current_run_id)
  [[ -z "$id" ]] && { log_err "No active run. Use: harn start"; exit 1; }
  echo "$HARN_DIR/runs/$id"
}

# Must be called in the current shell, not a subshell
sync_run_log() {
  local id
  id=$(current_run_id)
  [[ -z "$id" ]] && return 0
  LOG_FILE="$HARN_DIR/runs/$id/run.log"
  touch "$LOG_FILE"
  ln -sfn "$LOG_FILE" "$HARN_DIR/current.log"
}

current_sprint_num() {
  cat "${1}/current_sprint" 2>/dev/null || echo "1"
}

sprint_dir() {
  local run_dir="$1"
  local num="${2:-$(current_sprint_num "$run_dir")}"
  local dir="$run_dir/sprints/$(printf '%03d' "$num")"
  mkdir -p "$dir"
  echo "$dir"
}

sprint_status()    { cat "${1}/status"    2>/dev/null || echo "pending"; }
sprint_iteration() { cat "${1}/iteration" 2>/dev/null || echo "0"; }

count_sprints_in_backlog() {
  local backlog_file="$1"
  local count

  # grep -c exits 1 when no matches (while still printing 0); avoid `|| echo 0`
  # to prevent accidental multiline values like "0\n0" in numeric comparisons.
  count=$(grep -c "^## Sprint" "$backlog_file" 2>/dev/null || true)
  count="${count%%$'\n'*}"
  [[ "$count" =~ ^[0-9]+$ ]] || count="0"
  echo "$count"
}

# ── Real-time markdown color renderer ─────────────────────────────────────────
# Pipe stdin → md_stream.py → colored rendering stdout
# Saved to log file without ANSI codes, displayed with color in terminal
_md_stream() {
  python3 -u "$SCRIPT_DIR/parser/md_stream.py"
}

# ── Agent invocation ──────────────────────────────────────────────────────────
invoke_copilot() {
  local prompt_input="$1" output_file="$2" role="${3:-implementing...}" prompt_mode="${4:-file}" copilot_model="${5:-}" copilot_effort="${6:-}"
  local prompt_text="$prompt_input"
  if [[ "$prompt_mode" == "file" ]]; then
    prompt_text="$(cat "$prompt_input")"
  fi

  local copilot_label="copilot"
  [[ -n "$copilot_model" ]] && copilot_label="copilot ($copilot_model)"
  log_agent_start "$copilot_label" "$role" "output → $(basename "$output_file")"

  local -a copilot_cmd=(copilot --add-dir "$ROOT_DIR" --yolo -p "$prompt_text")
  [[ -n "$copilot_effort" ]] && copilot_cmd+=(--effort "$copilot_effort")
  local use_env_model_fallback="false"
  if [[ -n "$copilot_model" ]]; then
    if copilot_supports_model_flag; then
      copilot_cmd+=(--model "$copilot_model")
    else
      # Old CLI fallback: specify model via COPILOT_MODEL env var
      use_env_model_fallback="true"
      log_warn "copilot --model not supported, using COPILOT_MODEL fallback: $copilot_model"
    fi
  fi

  local exit_code=0
  if [[ "$use_env_model_fallback" == "true" ]]; then
    COPILOT_MODEL="$copilot_model" "${copilot_cmd[@]}" 2>&1 \
      | tee "$output_file" \
      | tee -a "$LOG_FILE" \
      | _md_stream || exit_code=${PIPESTATUS[0]}
  else
    "${copilot_cmd[@]}" 2>&1 \
      | tee "$output_file" \
      | tee -a "$LOG_FILE" \
      | _md_stream || exit_code=${PIPESTATUS[0]}
  fi

  if [[ $exit_code -ne 0 ]]; then
    log_warn "copilot exited abnormally (exit $exit_code) — output: $(basename "$output_file")"
  fi
  log_agent_done "$copilot_label"
  return $exit_code
}

invoke_role() {
  local role_key="$1" prompt_input="$2" output_file="$3" role_label="$4" prompt_mode="${5:-inline}" model="${6:-}" role_detail="${7:-$role_key}"
  # Determine backend for this specific role
  local backend
  case "$role_detail" in
    planner)             backend="${AI_BACKEND_PLANNER:-}" ;;
    generator_contract)  backend="${AI_BACKEND_GENERATOR_CONTRACT:-}" ;;
    generator_impl)      backend="${AI_BACKEND_GENERATOR_IMPL:-}" ;;
    evaluator_contract)  backend="${AI_BACKEND_EVALUATOR_CONTRACT:-}" ;;
    evaluator_qa)        backend="${AI_BACKEND_EVALUATOR_QA:-}" ;;
  esac
  [[ -z "$backend" ]] && backend=$(_detect_ai_cli)
  [[ -z "$backend" ]] && backend="copilot"

  case "$backend" in
    claude)
      local prompt_text="$prompt_input"
      [[ "$prompt_mode" == "file" ]] && prompt_text="$(cat "$prompt_input")"
      local label="claude"; [[ -n "$model" ]] && label="claude ($model)"
      log_agent_start "$label" "$role_label" "output → $(basename "$output_file")"
      local exit_code=0
      local -a claude_cmd=(claude -p "$prompt_text")
      [[ -n "$model" ]] && claude_cmd+=(--model "$model")
      "${claude_cmd[@]}" 2>&1 \
        | tee "$output_file" \
        | tee -a "$LOG_FILE" \
        | _md_stream || exit_code=${PIPESTATUS[0]}
      [[ $exit_code -ne 0 ]] && log_warn "claude exited abnormally (exit $exit_code)"
      log_agent_done "$label"
      return $exit_code
      ;;
    copilot|*)
      local copilot_effort=""
      [[ "$role_key" == "generator" ]] && copilot_effort="high"
      invoke_copilot "$prompt_input" "$output_file" "$role_label" "$prompt_mode" "$model" "$copilot_effort"
      ;;
  esac
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_backlog() {
  _ensure_backlog_file
  echo -e "${W}Pending backlog items:${N}"
  local slugs
  slugs=$(backlog_pending_slugs)
  if [[ -z "$slugs" ]]; then
    echo "  (none — all done!)"
    return
  fi
  local i=1
  while IFS= read -r slug; do
    local section
    section=$(python3 - "$BACKLOG_FILE" "$slug" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
slug = sys.argv[2]
sections = re.split(r'^## ', content, flags=re.MULTILINE)
for sec in sections:
    name = sec.split('\n',1)[0].strip()
    if re.search(r'\*\*' + re.escape(slug) + r'\*\*', sec):
        print(name)
        break
EOF
)
    echo -e "  ${W}$i.${N} ${Y}$slug${N}  ${B}[$section]${N}"
    i=$(( i + 1 ))
  done <<< "$slugs"
  echo ""
  echo -e "Run: ${W}harn start${N} — select a backlog item and run the full loop"
}

cmd_start() {
  local slug_or_prompt="${1:-}"
  local max_sprints="${2:-10}"
  local max_sprints_arg="${2:-}"

  # No argument — show backlog list and prompt for a number
  if [[ -z "$slug_or_prompt" ]]; then
    _ensure_backlog_file

    local slugs
    slugs=$(backlog_pending_slugs)
    if [[ -z "$slugs" ]]; then
      log_warn "No pending items in backlog. Add an item first."
      log_info "To discover items: harn discover"
      exit 1
    fi

    echo -e "\n${W}Select backlog item${N}"
    echo -e "${B}──────────────────────────────${N}"
    local i=1
    local slug_array=()
    while IFS= read -r s; do
      echo -e "  ${W}$i.${N} ${Y}$s${N}"
      slug_array+=("$s")
      i=$(( i + 1 ))
    done <<< "$slugs"
    echo ""
    printf "Enter number (1–${#slug_array[@]}): "
    local choice; choice=$(_input_readline); echo ""

    if [[ "$choice" =~ ^[0-9]+$ ]] && \
       [[ "$choice" -ge 1 ]] && \
       [[ "$choice" -le "${#slug_array[@]}" ]]; then
      slug_or_prompt="${slug_array[$(( choice - 1 ))]}"
      log_info "Selected: ${W}$slug_or_prompt${N}"
    else
      log_err "Invalid input: $choice"
      exit 1
    fi
  fi

  local run_id
  run_id=$(date +%Y%m%d-%H%M%S)
  local run_dir="$HARN_DIR/runs/$run_id"

  mkdir -p "$run_dir/sprints"
  echo "$slug_or_prompt" > "$run_dir/prompt.txt"
  echo "1" > "$run_dir/current_sprint"

  # This run's dedicated log (current.log → symlink to this run's log)
  local run_log="$run_dir/run.log"
  ln -sfn "$run_log" "$HARN_DIR/current.log"
  LOG_FILE="$run_log"

  {
    echo "════════════════════════════════════════════════════════════"
    echo "  harn Sprint Harness"
    echo "  Run ID   : $run_id"
    echo "  Item     : $slug_or_prompt"
    echo "  Started  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════"
  } | tee -a "$LOG_FILE"

  ln -sfn "$run_dir" "$HARN_DIR/current"
  log_ok "Run created: $run_id  (${W}$slug_or_prompt${N})"
  log_info "View live log: ${W}harn tail${N}  →  $run_log"

  if ! cmd_plan; then
    log_err "Failed at initial planning stage. Check the log and retry: $run_log"
    return 1
  fi

  # If max sprints not specified as start argument, auto-calculate from backlog
  # to proceed from start to finish in one go.
  if [[ -z "$max_sprints_arg" ]]; then
    local planned_total
    planned_total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    if [[ "$planned_total" -gt 0 ]]; then
      max_sprints="$planned_total"
    fi
  fi

  log_step "Starting automated run"
  log_info "Initialization complete. Running sprint loop automatically (contract → implement → evaluate → next, up to ${max_sprints} sprints)."

  if ! _run_sprint_loop "$max_sprints"; then
    log_err "Automated sprint loop was interrupted. Check the failure point and resume with 'harn resume $(basename "$run_dir")'."
    return 1
  fi

  if [[ -f "$run_dir/completed" ]]; then
    log_ok "harn start full automated run complete"
  else
    log_warn "Reached max sprint count (${max_sprints}). Automated run ended. Run 'harn start' to continue."
  fi
}

cmd_plan() {
  local run_dir
  run_dir=$(require_run_dir)
  local slug_or_prompt
  slug_or_prompt=$(cat "$run_dir/prompt.txt")

  log_step "Planning phase"

  local context_block
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    local item_text
    item_text=$(backlog_item_text "$slug_or_prompt")
    context_block="## Backlog Item

\`\`\`
$item_text
\`\`\`

## Full Backlog (for reference)

$(cat "$BACKLOG_FILE")
"
  else
    context_block="## Request

$slug_or_prompt"
  fi

  local prompt
  # Build sprint structure instruction block from config
  local sprint_instruction
  if [[ -n "${SPRINT_ROLES:-}" ]]; then
    sprint_instruction="## Sprint Structure (configured — follow exactly)\n\nProduce exactly ${SPRINT_COUNT} sprint(s):\n"
    IFS='|' read -ra roles_arr <<< "$SPRINT_ROLES"
    for role_line in "${roles_arr[@]}"; do
      sprint_instruction+="- ${role_line}\n"
    done
  else
    sprint_instruction="## Sprint Structure\n\nProduce exactly 2 sprints:\n- Sprint 001: Complete feature implementation (all layers at once)\n- Sprint 002: Full test suite for Sprint 001\n"
  fi

  prompt="$(cat "$PROMPTS_DIR/planner.md")

---

$(printf '%b' "$sprint_instruction")

---

$context_block

---

## Output Instructions

Use the following section markers exactly in your output:

=== plan.text ===
[One-line plan text. Plain text, no markdown]

=== spec.md ===
[Product spec content]

=== sprint-backlog.md ===
[Sprint backlog content]"

  local raw="$run_dir/plan-raw.md"
  invoke_role "planner" "$prompt" "$raw" "Planner — expand backlog item into sprint spec" "inline" "$COPILOT_MODEL_PLANNER" "planner"

  awk '/^=== plan\.text ===$/{f=1;next} /^=== spec\.md ===$/{f=0} f{print}' "$raw" \
    > "$run_dir/plan.txt"
  awk '/^=== spec\.md ===$/{f=1;next} /^=== sprint-backlog\.md ===$/{f=0} f{print}' "$raw" \
    > "$run_dir/spec.md"
  awk '/^=== sprint-backlog\.md ===$/{f=1;next} f{print}' "$raw" \
    > "$run_dir/sprint-backlog.md"

  local plan_text
  plan_text=$(python3 - "$run_dir/plan.txt" <<'PYEOF'
import sys
path = sys.argv[1]
try:
    lines = [ln.strip() for ln in open(path, encoding='utf-8').read().splitlines() if ln.strip()]
except FileNotFoundError:
    lines = []
print(' '.join(lines))
PYEOF
)
  if [[ -z "$plan_text" ]]; then
    plan_text="$slug_or_prompt"
    log_warn "plan.text not found — using slug/prompt as plan text"
  fi
  echo "$plan_text" > "$run_dir/plan.txt"

  if [[ ! -s "$run_dir/spec.md" ]]; then
    cp "$raw" "$run_dir/spec.md"
    log_warn "Section markers not found — saving full output as spec.md"
  fi

  log_ok "Spec → $run_dir/spec.md"
  log_ok "Sprint backlog → $run_dir/sprint-backlog.md"
  log_ok "Plan text → $run_dir/plan.txt"

  # Planning done → move backlog item from Pending → In Progress
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    python3 - "$BACKLOG_FILE" "$slug_or_prompt" <<'PYEOF'
import re, sys
path, slug = sys.argv[1], sys.argv[2]
content = open(path).read()

# Move from Pending to In Progress section
item_pattern = re.compile(
    r'(- \[ \] \*\*' + re.escape(slug) + r'\*\*[^\n]*(?:\n[ \t]+[^\n]*)*)',
    re.MULTILINE
)
match = item_pattern.search(content)
if not match:
    print(f'Item not found: {slug}')
    sys.exit(0)

item_text = match.group(1)
# Remove from original location
content = content[:match.start()] + content[match.end():]

# Add under In Progress section (create if missing)
if '## In Progress' in content:
    content = content.replace('## In Progress\n', '## In Progress\n' + item_text + '\n')
else:
    content = '## In Progress\n' + item_text + '\n\n' + content

open(path, 'w').write(content)
print(f'✓ {slug} → In Progress')
PYEOF
    log_ok "Backlog: ${W}$slug_or_prompt${N} → In Progress"

    if backlog_upsert_plan_line "$slug_or_prompt" "$plan_text"; then
      log_ok "Backlog plan line updated: ${W}$slug_or_prompt${N}"
    else
      case "$?" in
        2) log_warn "Backlog plan update failed: slug not found (${W}$slug_or_prompt${N})" ;;
        3) log_info "Backlog plan line unchanged (already up to date)" ;;
        *) log_warn "Exception during backlog plan update (slug=${W}$slug_or_prompt${N})" ;;
      esac
    fi

  fi

  # Create Git branch, commit backlog, create Draft PR
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    _git_setup_plan_branch "$slug_or_prompt" "$run_dir" "$plan_text"
  fi

  log_ok "Planning complete"
}

cmd_contract() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ -f "$sprint/contract.md" ]] && {
    log_warn "Scope already exists. Delete $sprint/contract.md to recreate it."
    return 0
  }

  log_step "Sprint $sprint_num — scope negotiation"

  local prev_context=""
  for s in "$run_dir/sprints"/*/; do
    [[ "$s" == "$sprint"/ ]] && continue
    [[ -d "$s" ]] || continue
    local sn; sn=$(basename "$s")
    prev_context+="### Sprint $sn
$(cat "$s/handoff.md" 2>/dev/null || cat "$s/contract.md" 2>/dev/null || echo "(no info)")

"
  done

  local gen_prompt_file="$sprint/contract-gen-prompt.md"
  cat > "$gen_prompt_file" <<EOF
$(cat "$PROMPTS_DIR/generator.md")

---

## Product Spec

$(cat "$run_dir/spec.md")

## Sprint Backlog

$(cat "$run_dir/sprint-backlog.md" 2>/dev/null || echo "")

## Previous Sprint Context

$prev_context

---

## Task Instructions

You are the **Generator (Developer)**. Propose a detailed scope for **Sprint $sprint_num**.

Include:
1. **Sprint Goal** — one sentence
2. **Features to implement** — concrete deliverables
3. **PASS Criteria** — numbered, specific, verifiable
4. **Packages/Files** — items to create or modify
5. **Out of scope** — explicitly excluded items

Be specific. The evaluator will review each PASS criterion individually.
EOF

  # Inject user extra instructions
  if [[ -n "$USER_EXTRA_INSTRUCTIONS" ]]; then
    printf "\n\n---\n%s\n" "$USER_EXTRA_INSTRUCTIONS" >> "$gen_prompt_file"
    USER_EXTRA_INSTRUCTIONS=""
  fi

  invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal.md" "Generator — Sprint $sprint_num scope proposal" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT" "generator_contract"

  log_info "Evaluator reviewing scope..."
  local eval_prompt
  eval_prompt="$(cat "$PROMPTS_DIR/evaluator.md")

---

## Task: Sprint Scope Review

### Sprint $sprint_num Scope Proposal

$(cat "$sprint/contract-proposal.md")

**If clear and verifiable**: write \`APPROVED\` on its own line with a brief confirmation.
**If revision needed**: write \`NEEDS_REVISION\` on its own line and list specific revisions needed."

  invoke_role "evaluator" "$eval_prompt" "$sprint/contract-review.md" "Evaluator — Sprint $sprint_num scope review" "inline" "$COPILOT_MODEL_EVALUATOR_CONTRACT" "evaluator_contract"

  if grep -qi 'APPROVED' "$sprint/contract-review.md"; then
    cp "$sprint/contract-proposal.md" "$sprint/contract.md"
    log_ok "Sprint $sprint_num scope approved"
  else
    log_warn "Scope needs revision — revising..."
    cat >> "$gen_prompt_file" <<EOF

---

## Evaluator Feedback

$(cat "$sprint/contract-review.md")

Please revise the scope incorporating the above feedback.
EOF
    invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal-v2.md" "Generator — Sprint $sprint_num scope revision" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT" "generator_contract"
    cp "$sprint/contract-proposal-v2.md" "$sprint/contract.md"
    log_ok "Sprint $sprint_num scope revision complete"
  fi

  log_info "Next step: harn implement"
}

cmd_implement() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ ! -f "$sprint/contract.md" ]] && {
    log_err "No scope for sprint $sprint_num. Run: harn contract"
    exit 1
  }

  local iteration
  iteration=$(( $(sprint_iteration "$sprint") + 1 ))
  echo "$iteration" > "$sprint/iteration"

  log_step "Sprint $sprint_num — development (iteration $iteration)"

  local qa_feedback=""
  if [[ $iteration -gt 1 && -f "$sprint/qa-report.md" ]]; then
    qa_feedback="## Evaluator Feedback (iteration $((iteration - 1)))

$(cat "$sprint/qa-report.md")

**Resolve all FAIL criteria listed above.**"
  fi

  local prev_handoff=""
  local prev_num=$(( sprint_num - 1 ))
  if [[ -d "$run_dir/sprints/$(printf '%03d' "$prev_num")" ]]; then
    prev_handoff="## Previous Sprint Handoff

$(cat "$run_dir/sprints/$(printf '%03d' "$prev_num")/handoff.md" 2>/dev/null || echo "(none)")"
  fi

  local prompt_file="$sprint/gen-prompt-iter${iteration}.md"
  cat > "$prompt_file" <<EOF
$(cat "$PROMPTS_DIR/generator.md")

---

## Product Spec

$(cat "$run_dir/spec.md")

## Sprint $sprint_num Scope

$(cat "$sprint/contract.md")

$prev_handoff

$qa_feedback

---

## Task Instructions

Implement **Sprint $sprint_num** according to the scope above.
After implementation, write a summary at the end:

=== Implementation Summary ===
- What was implemented
- Key files created/modified
- Known constraints
EOF

  # Inject user extra instructions
  if [[ -n "$USER_EXTRA_INSTRUCTIONS" ]]; then
    printf "\n\n---\n%s\n" "$USER_EXTRA_INSTRUCTIONS" >> "$prompt_file"
    USER_EXTRA_INSTRUCTIONS=""
  fi

  echo "in-progress" > "$sprint/status"

  # First implementation: Opus (IMPL), QA FAIL retry: Sonnet (CONTRACT)
  local impl_model="$COPILOT_MODEL_GENERATOR_IMPL"
  [[ $iteration -gt 1 ]] && impl_model="$COPILOT_MODEL_GENERATOR_CONTRACT"

  invoke_role "generator" "$prompt_file" "$sprint/implementation-iter${iteration}.md" "Generator — Sprint $sprint_num implementation (iteration $iteration)" "file" "$impl_model" "generator_impl"
  cp "$sprint/implementation-iter${iteration}.md" "$sprint/implementation.md"

  log_ok "Sprint $sprint_num implementation complete (iteration $iteration)"

  # Git commit implementation results
  _git_commit_sprint_impl "$sprint_num" "$sprint"

  log_info "Next step: harn evaluate"
}

cmd_evaluate() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")
  local iteration
  iteration=$(sprint_iteration "$sprint")

  [[ ! -f "$sprint/implementation.md" ]] && {
    log_err "No implementation for sprint $sprint_num. Run: harn implement"
    exit 1
  }

  log_step "Sprint $sprint_num — evaluation (iteration $iteration)"

  log_info "Running automated checks..."
  local test_results="$sprint/test-results.txt"
  {
    cd "$ROOT_DIR"

    # ── Static analysis / lint ──────────────────────────────────────────────
    if [[ -n "${LINT_COMMAND:-}" ]]; then
      echo "=== lint: $LINT_COMMAND ==="
      eval "$LINT_COMMAND" 2>&1 | tail -30 || true
    elif [[ -f "pubspec.yaml" ]] && command -v dart &>/dev/null; then
      echo "=== dart analyze ==="
      dart analyze 2>&1 | tail -30 || true
    elif [[ -f "package.json" ]] && command -v npx &>/dev/null; then
      echo "=== eslint / tsc ==="
      (npx tsc --noEmit 2>&1 | tail -20 || true)
    elif command -v go &>/dev/null && [[ -f "go.mod" ]]; then
      echo "=== go vet ==="
      go vet ./... 2>&1 | tail -20 || true
    else
      echo "(lint: no LINT_COMMAND configured — skipped)"
    fi
    echo ""

    # ── Unit / integration tests (last sprint only) ──────────────────────────
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    if [[ "$sprint_num" -eq "$total" ]]; then

      if [[ -n "${TEST_COMMAND:-}" ]]; then
        echo "=== tests: $TEST_COMMAND ==="
        eval "$TEST_COMMAND" 2>&1 | tail -50 || true
      elif [[ -f "pubspec.yaml" ]] && command -v flutter &>/dev/null; then
        echo "=== flutter test ==="
        flutter test --reporter compact 2>&1 | tail -50 || true
      elif [[ -f "package.json" ]] && grep -q '"test"' package.json; then
        echo "=== npm test ==="
        npm test --if-present 2>&1 | tail -50 || true
      elif [[ -f "Cargo.toml" ]] && command -v cargo &>/dev/null; then
        echo "=== cargo test ==="
        cargo test 2>&1 | tail -50 || true
      elif command -v pytest &>/dev/null; then
        echo "=== pytest ==="
        pytest 2>&1 | tail -50 || true
      elif [[ -f "go.mod" ]] && command -v go &>/dev/null; then
        echo "=== go test ==="
        go test ./... 2>&1 | tail -50 || true
      else
        echo "(tests: no TEST_COMMAND configured — skipped)"
        echo "Set TEST_COMMAND in .harn_config to enable automated tests"
      fi
      echo ""

      # ── E2E environment (optional) ─────────────────────────────────────────
      if [[ -n "${E2E_COMMAND:-}" ]]; then
        echo "=== E2E setup: $E2E_COMMAND ==="
        eval "$E2E_COMMAND" 2>&1 | tail -30 || true
        echo "=== E2E environment ready ==="
        echo ""
      fi
    fi
  } > "$test_results"
  log_info "Checks complete → $test_results"

  # E2E environment context (last sprint only)
  local e2e_context=""
  if [[ -f "$sprint/e2e-env.txt" ]]; then
    e2e_context="
### E2E Test Environment
\`\`\`
$(cat "$sprint/e2e-env.txt")
\`\`\`

The services started at the URLs above are running.
Use **Playwright MCP tools** to test the app at http://localhost:3000 directly.
- Available tools: browser_navigate, browser_click, browser_snapshot, browser_screenshot
- Backend API available at http://localhost:8080
- Include test results in the report"
  fi

  local eval_prompt
  eval_prompt="$(cat "$PROMPTS_DIR/evaluator.md")

---

## Sprint $sprint_num QA

### Scope
$(cat "$sprint/contract.md")

### Implementation Summary
$(cat "$sprint/implementation.md")

### Automated Check Results
\`\`\`
$(cat "$test_results")
\`\`\`
$e2e_context

Write exactly one line at the end of the report:
\`VERDICT: PASS\`  or  \`VERDICT: FAIL\`"

  local eval_exit_code=0
  invoke_role "evaluator" "$eval_prompt" "$sprint/qa-report.md" "Evaluator — Sprint $sprint_num QA (iteration $iteration)" "inline" "$COPILOT_MODEL_EVALUATOR_QA" "evaluator_qa" || eval_exit_code=$?

  # Clean up background processes tracked in e2e-env.txt (if any)
  if [[ -f "$sprint/e2e-env.txt" ]]; then
    log_info "Shutting down E2E environment..."
    while IFS='=' read -r key val; do
      [[ "$key" == *_PID ]] && kill "$val" 2>/dev/null && log_info "$key ($val) stopped" || true
    done < "$sprint/e2e-env.txt"
  fi

  if [[ $eval_exit_code -ne 0 ]]; then
    echo "fail" > "$sprint/status"
    log_err "Sprint $sprint_num: evaluator execution error (exit $eval_exit_code) — stopping loop"
    log_info "Manual resume: fix the issue then run harn evaluate  or  harn implement"
    return 1
  fi

  if grep -qiE 'VERDICT[[:space:]]*:[[:space:]]*PASS' "$sprint/qa-report.md"; then
    echo "pass" > "$sprint/status"
    log_ok "Sprint $sprint_num: ${G}PASS${N}"
    _git_push_sprint_pass "$sprint_num"
    log_info "Next step: harn next"
  else
    echo "fail" > "$sprint/status"
    local cur_iter
    cur_iter=$(sprint_iteration "$sprint")
    log_warn "Sprint $sprint_num: QA ${Y}FAIL${N} (iteration $cur_iter / $MAX_ITERATIONS) — retrying automatically... (report: $sprint/qa-report.md)"
  fi
}

# Internal: only increments sprint counter (used for sprint transitions in auto mode)
_sprint_advance() {
  local run_dir="$1"
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local next_num=$(( sprint_num + 1 ))
  echo "$next_num" > "$run_dir/current_sprint"
  log_info "Switching to sprint $next_num"
}

cmd_next() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  log_step "Finishing up"

  # Write final completion summary
  invoke_role "evaluator" "$(cat "$PROMPTS_DIR/evaluator.md")

## Task: Final Completion Summary

### Scope
$(cat "$sprint/contract.md" 2>/dev/null || echo '(none)')

### Implementation Summary
$(cat "$sprint/implementation.md" 2>/dev/null || echo '(none)')

### QA Report
$(cat "$sprint/qa-report.md" 2>/dev/null || echo '(none)')

Write a completion summary for the full work (max 300 chars):
1. Summary of what was implemented
2. Key changed files
3. Known limitations or follow-up tasks" \
    "$sprint/handoff.md" "Evaluator — final completion summary" "inline" "$COPILOT_MODEL_EVALUATOR_QA" "evaluator_qa"

  # Backlog → Done move
  local slug_or_prompt
  slug_or_prompt=$(cat "$run_dir/prompt.txt")
  if [[ "$slug_or_prompt" != *" "* && -f "$BACKLOG_FILE" ]]; then
    python3 - "$BACKLOG_FILE" "$slug_or_prompt" <<'PYEOF'
import re, sys
path, slug = sys.argv[1], sys.argv[2]
content = open(path).read()
item_pattern = re.compile(
    r'(- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*[^\n]*(?:\n[ \t]+[^\n]*)*)',
    re.MULTILINE
)
match = item_pattern.search(content)
if not match:
    sys.exit(0)
item_text = re.sub(r'- \[[ ]\]', '- [x]', match.group(1), count=1)
content = content[:match.start()] + content[match.end():]
if '## Done' in content:
    content = content.replace('## Done\n', '## Done\n' + item_text + '\n')
else:
    content = content.rstrip() + '\n\n## Done\n' + item_text + '\n'
open(path, 'w').write(content)
PYEOF
    log_ok "Backlog: ${W}$slug_or_prompt${N} → Done"
  fi

  # Completion flag (prevents auto resumption)
  touch "$run_dir/completed"
  rm -f "$HARN_DIR/current"

  log_ok "${G}Task fully complete: $slug_or_prompt${N}"
}

cmd_stop() {
  local pid_file="$HARN_DIR/harn.pid"

  if [[ ! -f "$pid_file" ]]; then
    log_warn "No running harness found (PID file missing)"
    log_info "Already stopped or was not started with harn start."
    return 0
  fi

  local pid
  pid=$(cat "$pid_file")

  if ! kill -0 "$pid" 2>/dev/null; then
    log_warn "Process PID=$pid already stopped — cleaning up PID file"
    rm -f "$pid_file"
    return 0
  fi

  log_info "Stopping harness... (PID: ${W}$pid${N})"

  # Send SIGTERM to the entire process group (including claude/copilot child processes)
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 2

  # If still alive, send SIGKILL
  if kill -0 "$pid" 2>/dev/null; then
    log_warn "Still running after SIGTERM — sending SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"

  # Mark current sprint as cancelled
  local run_dir
  run_dir=$(require_run_dir 2>/dev/null) || true
  if [[ -n "$run_dir" ]]; then
    local sprint_num sprint
    sprint_num=$(current_sprint_num "$run_dir")
    sprint=$(sprint_dir "$run_dir" "$sprint_num")
    local cur_status
    cur_status=$(sprint_status "$sprint")
    if [[ "$cur_status" == "in-progress" || "$cur_status" == "pending" ]]; then
      echo "cancelled" > "$sprint/status"
    fi
    log_ok "Run ${W}$(basename "$run_dir")${N} stopped"
  else
    log_ok "Harness stopped"
  fi
}

# Convert Git remote URL to owner/repo format
# e.g.) https://github.com/org/repo.git  →  org/repo
#       git@github.com:org/repo.git      →  org/repo
_git_url_to_nwo() {
  local url="$1"
  echo "$url" \
    | sed 's|\.git$||' \
    | sed 's|^https://[^/]*/||' \
    | sed 's|^git@[^:]*:||'
}

# ── Git planning branch creation & Draft PR ──────────────────────────────────
# Called after cmd_plan: create branch → commit backlog → create Draft PR
_git_setup_plan_branch() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local slug="$1" run_dir="$2" plan_text="$3"
  local branch="${GIT_PLAN_PREFIX}${slug}"
  local pr_target="${GIT_PR_TARGET_BRANCH:-$GIT_BASE_BRANCH}"

  log_step "Git: Creating planning branch"

  # Check current branch
  local current_branch
  current_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    log_warn "Git: Cannot determine HEAD — skipping branch creation"
    return 0
  fi

  # Create or checkout branch
  if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    log_warn "Branch ${W}$branch${N} already exists — checking out"
    git -C "$ROOT_DIR" checkout "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done
  else
    git -C "$ROOT_DIR" checkout -b "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done
    log_ok "Branch created: ${W}$branch${N}"
  fi

  # Commit backlog file (only if changed)
  if [[ -f "$BACKLOG_FILE" ]]; then
    git -C "$ROOT_DIR" add "$BACKLOG_FILE"
    if ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
      git -C "$ROOT_DIR" commit -m "plan: ${slug} — planning started (sprint backlog updated)" \
        2>&1 | while IFS= read -r line; do log_info "$line"; done
      log_ok "Sprint backlog committed"
    else
      log_info "Backlog file unchanged — skipping commit"
    fi
  fi

  # Push branch to origin
  if ! git -C "$ROOT_DIR" push -u origin "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_warn "Push failed — skipping Draft PR creation. Push manually and create a PR."
    log_info "Branch: ${W}$branch${N}"
    return 0
  fi
  log_ok "Branch pushed: origin/${W}$branch${N}"

  # Create Draft PR
  local pr_title="[Plan] ${slug}: ${plan_text}"
  local pr_body
  pr_body=$(cat "$run_dir/spec.md" 2>/dev/null || echo "$plan_text")

  local draft_flag="--draft"
  [[ "$GIT_PR_DRAFT" == "false" ]] && draft_flag=""

  log_info "Creating Draft PR... (base: ${W}${pr_target}${N}, head: ${W}${branch}${N})"
  local pr_out

  # shellcheck disable=SC2086
  if pr_out=$(gh pr create \
      --base "$pr_target" \
      --head "$branch" \
      --title "$pr_title" \
      --body "$pr_body" \
      $draft_flag 2>&1); then
    log_ok "Draft PR created: ${W}$pr_out${N}"
    echo "$pr_out" > "$run_dir/pr-url.txt"
  else
    log_warn "PR creation failed — create it manually"
    log_info "Branch: origin/${W}$branch${N}  →  ${W}$pr_target${N}"
    log_info "Error: $pr_out"
  fi
}

# Called after cmd_implement: commit implementation changes & push
_git_commit_sprint_impl() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local sprint_num="$1" sprint_dir_path="$2"
  local iteration
  iteration=$(cat "$sprint_dir_path/iteration" 2>/dev/null || echo "1")

  # Extract one-line sprint goal from contract.md
  local sprint_goal
  sprint_goal=$(grep -m1 '^\*\*Goal\*\*\|^Goal:' "$sprint_dir_path/contract.md" 2>/dev/null \
    | sed 's/^\*\*Goal\*\*[: ]*//;s/^Goal[: ]*//' | xargs)
  [[ -z "$sprint_goal" ]] && sprint_goal="Sprint ${sprint_num} implementation"

  local commit_msg="feat(sprint-${sprint_num}): ${sprint_goal}"
  [[ "$iteration" -gt 1 ]] && commit_msg="${commit_msg} (retry ${iteration})"

  log_step "Git: Sprint $sprint_num implementation commit"

  cd "$ROOT_DIR"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    log_info "No changes to commit — generator may not have modified any files"
    return 0
  fi

  git commit -m "$commit_msg" \
    2>&1 | while IFS= read -r line; do log_info "$line"; done
  log_ok "Commit done: ${W}${commit_msg}${N}"

  if [[ "$GIT_AUTO_PUSH" == "true" ]]; then
    local cur_branch
    cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    git push origin "$cur_branch" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
    log_ok "Push done: origin/${W}${cur_branch}${N}"
  fi
}

_git_push_sprint_pass() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local sprint_num="$1"
  local cur_branch
  cur_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [[ -z "$cur_branch" || "$cur_branch" == "HEAD" ]]; then
    log_warn "Git: Cannot determine HEAD — skipping push"
    return 0
  fi

  log_step "Git: Sprint $sprint_num passed — pushing to origin/${W}${cur_branch}${N}"
  cd "$ROOT_DIR"

  # Commit any uncommitted changes (e.g. qa-report.md, status files)
  git add -A
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "qa(sprint-${sprint_num}): evaluator PASS — sprint complete" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
  fi

  if git push origin "$cur_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "Push done: origin/${W}${cur_branch}${N}"
  else
    log_warn "Push failed — run: git push origin ${cur_branch}"
  fi
}


_git_merge_to_base() {
  [[ "$GIT_ENABLED" != "true" ]]    && return 0
  [[ "$GIT_AUTO_MERGE" != "true" ]] && return 0

  local feat_branch base_branch pr_target
  feat_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  base_branch="$GIT_BASE_BRANCH"
  pr_target="${GIT_PR_TARGET_BRANCH:-$GIT_BASE_BRANCH}"

  if [[ -z "$feat_branch" || "$feat_branch" == "$base_branch" || "$feat_branch" == "HEAD" ]]; then
    log_warn "Git: Cannot identify feature branch to merge (current: ${feat_branch:-unknown})"
    return 0
  fi

  log_step "Git finalize: ${W}${feat_branch}${N} → ${W}${pr_target}${N}"

  # Commit uncommitted changes (including backlog Done status, etc.)
  cd "$ROOT_DIR"
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log_info "Auto-committing uncommitted changes..."
    git add -A
    git commit -m "chore: harn auto-commit — sprint complete" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
  fi

  # Push feature branch to origin
  log_info "Updating PR: pushing origin/${W}${feat_branch}${N}..."
  if ! git push origin "$feat_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_warn "Push failed — merge the PR manually"
    return 1
  fi
  log_ok "Push done: origin/${W}${feat_branch}${N}"

  # gh pr merge — not squash
  local pr_url_file pr_url
  pr_url_file="$(require_run_dir 2>/dev/null)/pr-url.txt"
  pr_url=$(cat "$pr_url_file" 2>/dev/null || echo "")

  local merge_target="${pr_url:-$feat_branch}"
  log_info "Merging PR (not squash): ${W}${merge_target}${N}"

  if gh pr merge "$merge_target" --merge 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "PR merge complete: ${W}${feat_branch}${N} → ${W}${pr_target}${N}"
  else
    log_warn "gh pr merge failed — merge the PR on GitHub manually and then continue"
    log_info "PR: ${pr_url:-}"
    return 1
  fi

  # Return to base branch and pull
  log_info "Returning to base branch: ${W}${base_branch}${N}"
  git checkout "$base_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done

  log_info "Pulling origin/${W}${base_branch}${N}..."
  if git pull origin "$base_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "Pull complete: origin/${W}${base_branch}${N}"
  else
    log_warn "Pull failed — run: git pull origin ${base_branch}"
    return 1
  fi
}

# ── Retrospective ──────────────────────────────────────────────────────────────
cmd_retrospective() {
  local run_dir="$1"
  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_warn "No AI CLI — skipping retrospective"
    return 0
  fi

  log_step "Retrospective"

  # ── Context collection ─────────────────────────────────────────────────────
  local backlog_item=""
  [[ -f "$run_dir/selected-slug" ]] && backlog_item=$(cat "$run_dir/selected-slug")

  local sprint_summary=""
  for sprint_path in "$run_dir/sprints"/*/; do
    local snum; snum=$(basename "$sprint_path")
    local plan="" eval_result="" verdict=""
    [[ -f "$sprint_path/contract.md" ]] && plan=$(head -30 "$sprint_path/contract.md")
    [[ -f "$sprint_path/status"      ]] && verdict=$(cat "$sprint_path/status")
    if [[ -f "$sprint_path/evaluation.md" ]]; then
      eval_result=$(grep -A5 'QA_VERDICT\|VERDICT\|FAIL\|PASS' "$sprint_path/evaluation.md" 2>/dev/null | head -20 || true)
    fi
    sprint_summary+="
### Sprint ${snum} (${verdict:-unknown})
**Plan:**
${plan}
**Eval:**
${eval_result}"
  done

  local retro_prompt_file="$PROMPTS_DIR/retrospective.md"
  [[ ! -f "$retro_prompt_file" ]] && retro_prompt_file="$SCRIPT_DIR/prompts/retrospective.md"

  local prompt
  prompt="$(cat "$retro_prompt_file")

---

## Current Run Data

**Backlog item**: ${backlog_item}

**Sprint summary**:
${sprint_summary}

**Current planner prompt**:
$(cat "$PROMPTS_DIR/planner.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/planner.md")

**Current generator prompt**:
$(cat "$PROMPTS_DIR/generator.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/generator.md")

**Current evaluator prompt**:
$(cat "$PROMPTS_DIR/evaluator.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/evaluator.md")"

  local retro_out="$run_dir/retrospective.md"
  log_info "AI(${W}${ai_cmd}${N}) analyzing retrospective..."
  if ! _ai_generate "$ai_cmd" "$prompt" "$retro_out"; then
    log_warn "Retrospective generation failed — skipping"
    return 0
  fi

  # ── Print summary ──────────────────────────────────────────────────────────
  local summary
  summary=$(awk '/^=== retro-summary ===$/{f=1;next} /^=== /{f=0} f{print}' "$retro_out")
  if [[ -n "$summary" ]]; then
    echo ""
    echo -e "${W}  Retrospective Summary${N}"
    echo -e "${D}  ────────────────────────────────────${N}"
    echo "$summary" | while IFS= read -r line; do
      echo -e "  $line"
    done
    echo ""
  fi

  # ── Review prompt improvement suggestions ────────────────────────────────────
  local roles="planner generator evaluator"
  local role_names=("planner:Planner" "generator:Generator" "evaluator:Evaluator")
  local any_applied=false

  for role_pair in "${role_names[@]}"; do
    local role="${role_pair%%:*}"
    local role_kr="${role_pair##*:}"

    local suggestion
    suggestion=$(awk "/^=== prompt-suggestion:${role} ===$/{f=1;next} /^=== /{f=0} f{print}" "$retro_out" | sed '/^$/d')

    [[ -z "$suggestion" || "$suggestion" == "none" ]] && continue

    echo -e "${C}  ╭─ 💡 ${role_kr} prompt improvement suggestion${N}"
    echo "$suggestion" | while IFS= read -r line; do
      echo -e "${C}  │${N}  $line"
    done
    echo -e "${C}  ╰${N}"
    echo ""
    printf "  Add this suggestion to the ${W}${role_kr}${N} prompt? [y/N]: "
    local yn; yn=$(_input_readline); echo ""

    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
      # Add to custom prompt file or base file
      local target_prompt="$PROMPTS_DIR/${role}.md"
      if [[ ! -f "$target_prompt" ]]; then
        # Not in custom directory — copy base file then add
        mkdir -p "$PROMPTS_DIR"
        cp "$SCRIPT_DIR/prompts/${role}.md" "$target_prompt"
      fi
      printf '\n\n## Retrospective Improvements (%s)\n\n%s\n' "$(date '+%Y-%m-%d')" "$suggestion" >> "$target_prompt"
      log_ok "Added to ${role_kr} prompt: ${W}${target_prompt}${N}"
      any_applied=true
    else
      log_info "${role_kr} suggestion skipped"
    fi
  done

  if [[ "$any_applied" == "true" ]]; then
    # Reflect custom prompt directory in config
    if [[ "$PROMPTS_DIR" != "$SCRIPT_DIR/prompts" ]]; then
      local rel_dir="${PROMPTS_DIR#$ROOT_DIR/}"
      sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${rel_dir}\"|" "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "Prompt improvements applied."
  fi

  log_ok "Retrospective complete — results: ${W}${retro_out}${N}"
}

# ── Sprint loop main body ─────────────────────────────────────────────────────
_run_sprint_loop() {
  local max_sprints="${1:-10}"
  local run_dir
  run_dir=$(require_run_dir)

  # Always update current.log symlink (so tail works on resume too)
  local run_log="$run_dir/run.log"
  touch "$run_log"
  ln -sfn "$run_log" "$HARN_DIR/current.log"
  LOG_FILE="$run_log"

  # Save PID (so harn stop can find this process)
  echo "$$" > "$HARN_DIR/harn.pid"
  trap 'rm -f "$HARN_DIR/harn.pid"' EXIT
  trap 'rm -f "$HARN_DIR/harn.pid"; log_warn "Harness interrupted by user."; exit 130' INT
  trap 'rm -f "$HARN_DIR/harn.pid"; log_warn "Harness received termination signal."; exit 143' TERM

  log_step "Loop started (up to $max_sprints sprints)"

  for _ in $(seq 1 "$max_sprints"); do
    local sprint_num
    sprint_num=$(current_sprint_num "$run_dir")
    local sprint
    sprint=$(sprint_dir "$run_dir" "$sprint_num")

    # Show progress
    local total_planned
    total_planned=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    _print_sprint_progress "$sprint_num" "${total_planned:-$max_sprints}"

    if [[ ! -f "$sprint/contract.md" ]]; then
      cmd_contract
    fi

    # Use already-completed iteration count as initial value on resume
    local iter
    iter=$(sprint_iteration "$sprint")

    if [[ "$(sprint_status "$sprint")" == "pass" ]]; then
      log_info "Sprint $sprint_num already passed — moving to next"
    elif [[ $iter -ge $MAX_ITERATIONS ]]; then
      log_warn "Sprint $sprint_num already reached max iterations ($MAX_ITERATIONS) — forcing advance"
    else
      while [[ $iter -lt $MAX_ITERATIONS ]]; do
        cmd_implement
        iter=$(sprint_iteration "$sprint")
        if ! cmd_evaluate; then
          log_err "Evaluator process error — stopping loop. Fix the issue and run harn evaluate."
          return 1
        fi
        [[ "$(sprint_status "$sprint")" == "pass" ]] && break
      done
      if [[ "$(sprint_status "$sprint")" != "pass" ]]; then
        log_warn "Sprint $sprint_num: max iterations ($MAX_ITERATIONS) reached — forcing advance without QA pass"
      fi
    fi

    # Check if all sprints are complete
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")

    if [[ $total -gt 0 && $sprint_num -ge $total ]]; then
      # ── Last sprint done: final cleanup and exit ────────────────────────────
      _log_raw ""
      _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
      _log_raw "${G}  ║  ✓  All ${total} sprints complete!${N}"
      _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"
      cmd_next          # write handoff + move backlog to Done + set completed flag
      _git_merge_to_base
      if [[ "$HARN_SKIP_RETRO" != "true" ]]; then
        cmd_retrospective "$run_dir"
      fi
      break
    else
      # ── Intermediate sprint done: increment counter and move to next sprint ─
      log_info "Sprint $sprint_num done — switching to sprint $(( sprint_num + 1 ))"
      _sprint_advance "$run_dir"
    fi
  done
}

# ── New task discovery ─────────────────────────────────────────────────────────

cmd_discover() {
  log_step "Backlog discovery — codebase analysis"

  mkdir -p "$HARN_DIR"
  LOG_FILE="$HARN_DIR/harn.log"

  local out_file="$HARN_DIR/discovery-$(date +%Y%m%d-%H%M%S).md"
  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt
  prompt="You are a senior engineer analyzing the **Servan** project codebase.

> **Language instruction**: Write all descriptions, goals, and reasoning in **English**. Slugs, code, and file paths stay in English.

## Servan Architecture

Servan is a Dart/Flutter monorepo — AI Report Dispatcher.
Bounded contexts: Report, Transform, Dispatch, Device, Auth, Feedback.
Key packages: packages/domain, packages/application, packages/infrastructure, packages/features/*, services/backend, services/mcp, apps/mobile.

## Current Backlog (do NOT duplicate these)

\`\`\`
$current_backlog
\`\`\`

## Your Task

Scan the codebase for:
1. TODO / FIXME / HACK comments
2. Incomplete features (stub, placeholder, not-implemented)
3. Critical paths with no tests
4. Architecture violations or layer rule violations
5. New features that add user value

Pick the **2–4 highest-value items** not already in the backlog above.

## Output Format

Output ONLY this block — nothing else:

=== new-items ===
- [ ] **slug-for-item**
  English description (1–2 lines): what to do and why.

- [ ] **another-slug**
  English description.

Rules:
- slug: hyphenated-lowercase, max 50 chars
- 2–4 items only
- No duplicates with existing backlog"

  invoke_role "planner" "$prompt" "$out_file" "Analyst — discover new backlog items" "inline" "$COPILOT_MODEL_PLANNER" "planner"

  # Extract content after section marker
  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "Could not extract new items — check $out_file."
    return 0
  fi

  # Create default structure if backlog file doesn't exist
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "Backlog file created: $BACKLOG_FILE"
  fi

  # Insert directly into ## Pending section (items passed via stdin)
  printf '%s' "${new_items}" | python3 - "$BACKLOG_FILE" <<'PYEOF'
import sys, re

path = sys.argv[1]
new_items_text = sys.stdin.read().strip()
if not new_items_text:
    sys.exit(0)

content = open(path, encoding='utf-8').read()
lines = content.splitlines()

pending_start = None
for i, line in enumerate(lines):
    if re.match(r'^## Pending\s*$', line):
        pending_start = i
    elif pending_start is not None and re.match(r'^## ', line):
        break

insert_lines = [''] + new_items_text.splitlines() + ['']

if pending_start is None:
    lines += ['', '## Pending'] + insert_lines
else:
    lines[pending_start + 1:pending_start + 1] = insert_lines

open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF

  log_ok "New items added to backlog"
  echo ""
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r line; do
    echo -e "  ${Y}$line${N}"
  done
  echo ""
  log_info "Check: harn backlog   /   Start now: harn auto"
}

# ── Add backlog item ───────────────────────────────────────────────────────────

cmd_add() {
  log_step "Adding backlog item"

  # Create default structure if backlog file doesn't exist
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    mkdir -p "$(dirname "$BACKLOG_FILE")"
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "Backlog file created: $BACKLOG_FILE"
  fi

  echo -e ""
  echo -e "${B}  ╭─ ✚ New backlog item${N}"
  echo -e "${B}  │${N}  Describe the feature or task you want to implement."
  echo -e "${B}  │${N}  AI will generate a slug and description and add it to the backlog."
  echo -e "${B}  │${N}  ${D}Multi-line input supported  ·  Empty line to finish${N}"
  echo -e "${B}  ╰${N}"

  local user_input
  user_input=$(_input_multiline)

  if [[ -z "$user_input" ]]; then
    log_warn "No input — cancelled"
    return 0
  fi

  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_err "AI CLI not found. Install copilot or claude."
    exit 1
  fi

  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt
  prompt="You are a sprint backlog manager.

> **Language**: Write all descriptions in English. Slugs, code, and file names stay in English.

## Current Backlog
\`\`\`
${current_backlog}
\`\`\`

## User Request
${user_input}

## Task
Generate 1–3 backlog items based on the request above.
Do not duplicate existing backlog items.

## Output Format (output ONLY this block — nothing else)

=== new-items ===
- [ ] **slug-for-item**
  English description (1–2 lines): what to do and why.

Rules:
- slug: hyphenated-lowercase, max 50 chars
- Description indented 2 spaces directly below the item
- 1–3 items only"

  log_info "AI(${W}${ai_cmd}${N}) generating backlog items..."

  local out_file="$HARN_DIR/add-$(date +%Y%m%d-%H%M%S).md"
  mkdir -p "$HARN_DIR"

  if ! _ai_generate "$ai_cmd" "$prompt" "$out_file"; then
    log_err "AI generation failed"
    return 1
  fi

  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "Could not extract items — check $out_file."
    return 0
  fi

  # Add to Pending section (items passed via stdin — prevents quote conflicts)
  printf '%s' "${new_items}" | python3 - "$BACKLOG_FILE" <<'PYEOF'
import sys, re

path = sys.argv[1]
new_items_text = sys.stdin.read().strip()
if not new_items_text:
    sys.exit(0)

content = open(path, encoding='utf-8').read()
lines = content.splitlines()

# Find end of ## Pending section and insert there
pending_start = None
next_section = None
for i, line in enumerate(lines):
    if re.match(r'^## Pending\s*$', line):
        pending_start = i
    elif pending_start is not None and re.match(r'^## ', line):
        next_section = i
        break

insert_lines = [''] + new_items_text.splitlines() + ['']

if pending_start is None:
    # No ## Pending section — append to end of file
    lines += ['', '## Pending'] + insert_lines
else:
    # Insert right after the ## Pending header
    insert_at = pending_start + 1
    lines[insert_at:insert_at] = insert_lines

open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF

  echo ""
  log_ok "Added to backlog:"
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r item; do
    echo -e "  ${C}▸${N} $item"
  done
  echo ""
  log_info "Check: ${W}harn backlog${N}   /   Start now: ${W}harn start${N}"
}

# ── Auto mode ──────────────────────────────────────────────────────────────────

cmd_auto() {
  log_step "Auto mode"

  local run_id run_dir
  run_id=$(current_run_id)

  # 1. Resume in-progress run if present
  if [[ -n "$run_id" ]]; then
    run_dir="$HARN_DIR/runs/$run_id"
    if [[ ! -f "$run_dir/completed" ]]; then
      local sprint_num sprint cur_status
      sprint_num=$(current_sprint_num "$run_dir")
      sprint="$run_dir/sprints/$(printf '%03d' "$sprint_num")"
      cur_status=$(sprint_status "$sprint" 2>/dev/null || echo "pending")

      if [[ "$cur_status" != "cancelled" ]]; then
        log_info "Resuming in-progress run: ${W}$run_id${N}  (sprint $sprint_num · $cur_status)"
        _run_sprint_loop 10
        return 0
      else
        log_info "Last run was cancelled — looking for next item"
      fi
    else
      log_info "Last run completed (${W}$run_id${N}) — looking for next item"
    fi
  fi

  # 2. Start next pending backlog item if available
  local next_slug
  next_slug=$(backlog_next_slug)

  if [[ -n "$next_slug" ]]; then
    log_info "Starting next backlog item: ${W}$next_slug${N}"
    rm -f "$HARN_DIR/current"   # reset previous run pointer
    cmd_start "$next_slug"
    return 0
  fi

  # 3. Backlog empty → analyze codebase and add new items
  log_warn "Backlog is empty."
  cmd_discover

  # If discovery produced new items, start immediately
  next_slug=$(backlog_next_slug)
  if [[ -n "$next_slug" ]]; then
    log_info "Starting first discovered item: ${W}$next_slug${N}"
    rm -f "$HARN_DIR/current"
    cmd_start "$next_slug"
  fi
}

cmd_all() {
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    log_err "Backlog file not found: $BACKLOG_FILE"
    exit 1
  fi

  local slugs
  slugs=$(backlog_pending_slugs)

  if [[ -z "$slugs" ]]; then
    log_warn "No pending items in backlog."
    log_info "To add items: ${W}harn discover${N}  or  ${W}harn add${N}"
    return 0
  fi

  local slug_array=()
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && slug_array+=("$slug")
  done <<< "$slugs"

  local total_items="${#slug_array[@]}"
  log_step "Full automated run — ${W}${total_items}${N} item(s)"
  echo ""
  local i=1
  for slug in "${slug_array[@]}"; do
    echo -e "  ${D}$i.${N} ${Y}$slug${N}"
    i=$(( i + 1 ))
  done
  echo ""

  # Suppress per-item retrospective — run all at end
  HARN_SKIP_RETRO="true"

  local completed_run_dirs=()
  local failed_slugs=()
  local item_num=0

  for slug in "${slug_array[@]}"; do
    item_num=$(( item_num + 1 ))
    log_step "[$item_num/$total_items] Starting item: ${W}$slug${N}"

    # Reset run pointer (so cmd_start creates a new run)
    rm -f "$HARN_DIR/current"

    if cmd_start "$slug"; then
      # Record just-completed run directory
      local finished_run
      finished_run=$(ls -dt "$HARN_DIR/runs/"*/ 2>/dev/null | head -1)
      finished_run="${finished_run%/}"
      [[ -n "$finished_run" ]] && completed_run_dirs+=("$finished_run")
      log_ok "[$item_num/$total_items] Complete: ${W}$slug${N}"
    else
      log_err "[$item_num/$total_items] Failed: ${W}$slug${N} — continuing with next item"
      failed_slugs+=("$slug")
    fi
    echo ""
  done

  HARN_SKIP_RETRO="false"

  # ── Completion banner ────────────────────────────────────────────────────────
  local done_count="${#completed_run_dirs[@]}"
  local fail_count="${#failed_slugs[@]}"

  _log_raw ""
  _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
  _log_raw "${G}  ║  ✓  All ${total_items} item(s) processed   (success: ${done_count}  failed: ${fail_count})${N}"
  _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"

  if [[ $fail_count -gt 0 ]]; then
    log_warn "Failed items: ${failed_slugs[*]}"
    log_info "Re-run failed items manually: ${W}harn start <slug>${N}"
  fi

  # ── Retrospective: run sequentially for all completed items ─────────────────
  if [[ $done_count -gt 0 ]]; then
    log_step "Running retrospective (${done_count} item(s))"
    for run_dir in "${completed_run_dirs[@]}"; do
      local item_slug
      item_slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || basename "$run_dir")
      log_info "Retrospective: ${W}$item_slug${N}"
      cmd_retrospective "$run_dir" || true
    done
  fi
}

cmd_status() {
  local run_id run_dir sprint_num
  run_id=$(current_run_id)
  if [[ -z "$run_id" ]]; then
    log_warn "No active run. Start with: ${W}harn start${N}"
    return 0
  fi
  run_dir="$HARN_DIR/runs/$run_id"
  sprint_num=$(current_sprint_num "$run_dir")

  echo -e "${W}Run ID:${N}    $run_id"
  echo -e "${W}Item:${N}      $(cat "$run_dir/prompt.txt" 2>/dev/null || echo "(unknown)")"
  echo -e "${W}Current sprint:${N} $sprint_num"

  echo ""
  echo -e "${W}Sprints:${N}"
  local any=0
  for s in "$run_dir/sprints"/*/; do
    [[ -d "$s" ]] || continue
    any=1
    local sn status iter icon
    sn=$(basename "$s"); status=$(sprint_status "$s"); iter=$(sprint_iteration "$s")
    icon="⏳"
    [[ "$status" == "pass" ]]        && icon="${G}✓${N}"
    [[ "$status" == "fail" ]]        && icon="${R}✗${N}"
    [[ "$status" == "in-progress" ]] && icon="${Y}↻${N}"
    [[ "$status" == "cancelled" ]]   && icon="${R}⊘${N}"

    local status_label="pending"
    [[ "$status" == "pass" ]]        && status_label="passed"
    [[ "$status" == "fail" ]]        && status_label="failed"
    [[ "$status" == "in-progress" ]] && status_label="in-progress"
    [[ "$status" == "cancelled" ]]   && status_label="cancelled"

    echo -e "  Sprint $sn  $icon $status_label  (iterations: $iter)"
  done
  [[ $any -eq 0 ]] && echo "  (no sprints)"
}

cmd_config() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      echo -e "${W}harn Configuration${N}  (${CONFIG_FILE})"
      echo -e "  Project:           ${W}$ROOT_DIR${N}"
      echo -e "  Backlog file:      ${W}$BACKLOG_FILE${N}"
      echo -e "  Max retries:       ${W}$MAX_ITERATIONS${N}"
      echo -e "  Git integration:   ${W}$GIT_ENABLED${N}"
      [[ "$GIT_ENABLED" == "true" ]] && {
        echo -e "  Base working branch: ${W}$GIT_BASE_BRANCH${N}"
        echo -e "  PR target branch:  ${W}${GIT_PR_TARGET_BRANCH:-$GIT_BASE_BRANCH}${N}"
        echo -e "  Auto push:         ${W}$GIT_AUTO_PUSH${N}"
        echo -e "  Auto PR:           ${W}$GIT_AUTO_PR${N}"
      }
      echo ""
      echo -e "${W}AI Models${N}"
      echo -e "  Planner:           ${W}$COPILOT_MODEL_PLANNER${N}"
      echo -e "  Generator (contract): ${W}$COPILOT_MODEL_GENERATOR_CONTRACT${N}"
      echo -e "  Generator (impl):  ${W}$COPILOT_MODEL_GENERATOR_IMPL${N}"
      echo -e "  Evaluator (contract): ${W}$COPILOT_MODEL_EVALUATOR_CONTRACT${N}"
      echo -e "  Evaluator (QA):    ${W}$COPILOT_MODEL_EVALUATOR_QA${N}"
      [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]] && echo -e "\n  Custom prompts:    ${W}$PROMPTS_DIR${N}"
      ;;
    set)
      local key="${2:-}" val="${3:-}"
      [[ -z "$key" || -z "$val" ]] && { log_err "Usage: harn config set KEY VALUE"; exit 1; }
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "No .harn_config file. Run ${W}harn init${N} first."
        exit 1
      fi
      if grep -q "^${key}=" "$CONFIG_FILE"; then
        sed -i '' "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE"
      else
        echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
      fi
      log_ok "${W}${key}${N} = \"${val}\" set"
      ;;
    regen)
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err ".harn_config file not found. Run ${W}harn init${N} first."
        exit 1
      fi
      local ai_cmd; ai_cmd=$(_detect_ai_cli)
      if [[ -z "$ai_cmd" ]]; then
        log_err "No AI CLI found. Install copilot or claude."
        exit 1
      fi
      local hp="${HINT_PLANNER:-}" hg="${HINT_GENERATOR:-}" he="${HINT_EVALUATOR:-}" gg="${GIT_GUIDE:-}"
      if [[ -z "$hp" && -z "$hg" && -z "$he" && -z "$gg" ]]; then
        log_warn "No HINT_* / GIT_GUIDE values in config. Nothing to regenerate."
        log_info "To add hints: ${W}harn config set HINT_PLANNER \"hint content\"${N}"
        exit 0
      fi
      log_step "Regenerating custom prompts"
      log_info "Regenerating prompts with AI CLI (${W}${ai_cmd}${N})..."
      _generate_custom_prompts "$hp" "$hg" "$he" "$gg"
      local cpd=".harn/prompts"
      if ! grep -q "^CUSTOM_PROMPTS_DIR=" "$CONFIG_FILE"; then
        echo "CUSTOM_PROMPTS_DIR=\"${cpd}\"" >> "$CONFIG_FILE"
      else
        sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
      fi
      load_config
      log_ok "Custom prompts regenerated: ${W}$PROMPTS_DIR${N}"
      ;;
    *)
      log_err "Unknown config subcommand: $sub"
      echo -e "Usage: harn config [show|set KEY VALUE|regen]"
      exit 1
      ;;
  esac
}

cmd_runs() {
  echo -e "${W}Harness runs:${N}"
  local current_id; current_id=$(current_run_id)
  for d in "$HARN_DIR/runs"/*/; do
    [[ -d "$d" ]] || continue
    local id prompt marker
    id=$(basename "$d")
    prompt=$(head -c 70 "$d/prompt.txt" 2>/dev/null || echo "(no prompt)")
    marker=""; [[ "$id" == "$current_id" ]] && marker=" ${G}← current${N}"
    echo -e "  ${W}$id${N}: $prompt$marker"
  done
}

cmd_resume() {
  local run_id="${1:-}"
  [[ -z "$run_id" ]] && { log_err "Usage: harn resume <run-id>"; exit 1; }
  local run_dir="$HARN_DIR/runs/$run_id"
  [[ ! -d "$run_dir" ]] && { log_err "Run not found: $run_id"; exit 1; }
  ln -sfn "$run_dir" "$HARN_DIR/current"
  log_ok "Resumed: $run_id"
  cmd_status
}

cmd_tail() {
  local log="$HARN_DIR/current.log"

  # current.log symlink missing or broken → fall back to most recent run log
  if [[ ! -e "$log" ]]; then
    local latest_log
    latest_log=$(ls -t "$HARN_DIR/runs"/*/run.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]]; then
      log_warn "No current.log — falling back to latest run log: $latest_log"
      ln -sfn "$latest_log" "$HARN_DIR/current.log"
      log="$latest_log"
    else
      log_err "No active log. Start a run first: harn auto"
      exit 1
    fi
  fi

  echo -e "${W}Tailing log:${N} $log  ${B}(Ctrl-C to stop)${N}"
  tail -f "$log"
}

usage() {
  _print_banner
  cat <<EOF
${D}  $(pwd)${N}

  ${W}Usage${N}  harn <command>

  ${C}Setup${N}
    init                  Initial setup (first run or reconfigure)
    config                Show current configuration
    config set KEY VALUE  Update a specific setting
    config regen          Regenerate custom prompts from HINT_* values

  ${C}Backlog${N}
    backlog               List pending items
    add                   Add new backlog item (AI-assisted)
    discover              Analyze codebase and discover new items

  ${C}Run${N}
    start                 Select an item and run the full loop
    auto                  Auto-detect: resume / start / discover
    all                   Run all pending items sequentially (retro at end)

  ${C}Step by step${N}
    plan                  Re-run planner
    contract              Scope negotiation
    implement             Run generator
    evaluate              Run evaluator
    next                  Advance to next sprint

  ${C}Monitoring${N}
    status                Current run status
    tail                  Live log output
    runs                  List all runs
    resume <id>           Resume a previous run
    stop                  Stop the loop

  ${D}Tip: You can inject extra instructions between steps during a loop run.${N}
  ${D}    HARN_MODEL_GENERATOR_IMPL=claude-sonnet-4.6 harn start${N}

EOF
}

# ── Global option parsing (flags before command) ──────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      break
      ;;
    --planner-model)
      COPILOT_MODEL_PLANNER="${2:-}"
      shift 2
      ;;
    --generator-contract-model)
      COPILOT_MODEL_GENERATOR_CONTRACT="${2:-}"
      shift 2
      ;;
    --generator-impl-model)
      COPILOT_MODEL_GENERATOR_IMPL="${2:-}"
      shift 2
      ;;
    --evaluator-contract-model)
      COPILOT_MODEL_EVALUATOR_CONTRACT="${2:-}"
      shift 2
      ;;
    --evaluator-qa-model)
      COPILOT_MODEL_EVALUATOR_QA="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      log_err "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

validate_role_models

# ── Config load / first-run detection ────────────────────────────────────────
_cmd="${1:-help}"
case "$_cmd" in
  init|help|--help|-h) : ;;  # commands that can run without config
  *)
    if [[ ! -f "$CONFIG_FILE" ]]; then
      _print_banner
      echo -e "  ${Y}⚠${N}  No ${W}.harn_config${N} found in this directory."
      echo -e "     Starting initial setup...\n"
      cmd_init
    else
      load_config
    fi
    ;;
esac

cmd_doctor() {
  echo -e "\n${W}╔══════════════════════════════════════╗${N}"
  echo -e "${W}║            harn doctor               ║${N}"
  echo -e "${W}╚══════════════════════════════════════╝${N}\n"

  # ── Version ─────────────────────────────────────────────────────────────────
  echo -e "${W}▸ Version${N}"
  echo -e "  harn:         ${C}$HARN_VERSION${N}"
  echo -e "  bash:         ${C}${BASH_VERSION:-unknown}${N}"
  echo ""

  # ── AI CLIs ─────────────────────────────────────────────────────────────────
  echo -e "${W}▸ AI Backends${N}"
  local backend_ok=0

  if command -v copilot &>/dev/null; then
    local cp_ver; cp_ver=$(copilot --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} copilot:      ${C}${cp_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${R}✗${N} copilot:      not found"
    echo -e "    Install: ${W}gh extension install github/gh-copilot${N}"
  fi

  if command -v claude &>/dev/null; then
    local cl_ver; cl_ver=$(claude --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} claude:       ${C}${cl_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${R}✗${N} claude:       not found"
    echo -e "    Install: ${W}npm install -g @anthropic-ai/claude-code${N}"
  fi

  if [[ -n "${AI_BACKEND:-}" ]]; then
    echo -e "  Active backend: ${W}${AI_BACKEND}${N}"
  elif [[ $backend_ok -eq 0 ]]; then
    echo -e "  ${R}⚠ No AI backend available — run: harn init${N}"
  fi
  echo ""

  # ── Git ─────────────────────────────────────────────────────────────────────
  echo -e "${W}▸ Git${N}"
  if command -v git &>/dev/null; then
    local git_ver; git_ver=$(git --version 2>/dev/null | head -1)
    echo -e "  ${G}✓${N} git:          ${C}${git_ver}${N}"
  else
    echo -e "  ${R}✗${N} git:          not found"
  fi

  if command -v gh &>/dev/null; then
    local gh_ver; gh_ver=$(gh --version 2>/dev/null | head -1)
    local gh_auth; gh_auth=$(gh auth status 2>&1 | grep -i "logged in" | head -1 | sed 's/^[[:space:]]*//')
    echo -e "  ${G}✓${N} gh:           ${C}${gh_ver}${N}"
    if [[ -n "$gh_auth" ]]; then
      echo -e "  ${G}✓${N} gh auth:      ${C}${gh_auth}${N}"
    else
      echo -e "  ${Y}?${N} gh auth:      not authenticated — run: ${W}gh auth login${N}"
    fi
  else
    echo -e "  ${R}✗${N} gh:           not found — PR features disabled"
    echo -e "    Install: ${W}brew install gh${N}"
  fi

  if [[ -n "${ROOT_DIR:-}" ]] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    local branch; branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local remote; remote=$(git -C "$ROOT_DIR" remote -v 2>/dev/null | head -1 | awk '{print $2}')
    echo -e "  Project repo: ${C}${branch}${N} @ ${remote:-none}"
  fi
  echo ""

  # ── Harness config ───────────────────────────────────────────────────────────
  echo -e "${W}▸ harn Config${N}"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "  ${G}✓${N} .harn_config:     found  (${W}$CONFIG_FILE${N})"
    echo -e "  Git integration:  ${W}${GIT_ENABLED:-false}${N}"
    [[ "$GIT_ENABLED" == "true" ]] && {
      echo -e "  Base branch:      ${W}${GIT_BASE_BRANCH:-not set}${N}"
      echo -e "  PR target branch: ${W}${GIT_PR_TARGET_BRANCH:-not set}${N}"
    }
    echo -e "  Sprint count:     ${W}${SPRINT_COUNT:-2}${N}"
    echo -e "  AI backend:       ${W}${AI_BACKEND:-auto}${N}"
  else
    echo -e "  ${D}○${N} .harn_config:     not configured  (run ${W}harn init${N} to set up)"
  fi

  if [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]]; then
    echo -e "  Custom prompts:   ${W}${PROMPTS_DIR}${N}"
  fi
  echo ""

  # ── Models ───────────────────────────────────────────────────────────────────
  echo -e "${W}▸ Models${N}"
  echo -e "  Planner:              ${W}${COPILOT_MODEL_PLANNER:-default}${N}"
  echo -e "  Generator (contract): ${W}${COPILOT_MODEL_GENERATOR_CONTRACT:-default}${N}"
  echo -e "  Generator (impl):     ${W}${COPILOT_MODEL_GENERATOR_IMPL:-default}${N}"
  echo -e "  Evaluator (contract): ${W}${COPILOT_MODEL_EVALUATOR_CONTRACT:-default}${N}"
  echo -e "  Evaluator (QA):       ${W}${COPILOT_MODEL_EVALUATOR_QA:-default}${N}"
  echo ""

  # ── Active run ───────────────────────────────────────────────────────────────
  echo -e "${W}▸ Active Run${N}"
  local run_id; run_id=$(current_run_id)
  if [[ -n "$run_id" ]]; then
    local run_dir="$HARN_DIR/runs/$run_id"
    local slug; slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || echo "unknown")
    local sprint_num; sprint_num=$(current_sprint_num "$run_dir")
    echo -e "  ${G}✓${N} Run:          ${W}${run_id}${N}  (${slug})"
    echo -e "  Sprint:       ${W}${sprint_num}${N}"
  else
    echo -e "  No active run"
  fi
  echo ""

  # ── Dependencies ─────────────────────────────────────────────────────────────
  echo -e "${W}▸ Other Dependencies${N}"
  local all_ok=1
  for dep in python3 node; do
    if command -v "$dep" &>/dev/null; then
      local dver; dver=$($dep --version 2>/dev/null | head -1)
      echo -e "  ${G}✓${N} ${dep}:       ${C}${dver}${N}"
    else
      echo -e "  ${Y}?${N} ${dep}:       not found (optional)"
      all_ok=0
    fi
  done
  echo ""

  if [[ $backend_ok -eq 1 ]]; then
    echo -e "${G}All critical checks passed.${N}\n"
  else
    echo -e "${R}⚠ One or more critical checks failed. Run: harn init${N}\n"
  fi
}

cmd_auth() {
  local sub="${1:-status}"
  case "$sub" in
    status)
      echo -e "\n${W}▸ GitHub CLI auth status${N}"
      if command -v gh &>/dev/null; then
        gh auth status 2>&1 | while IFS= read -r line; do echo "  $line"; done
      else
        log_err "gh CLI not found. Install: https://cli.github.com"
      fi
      echo ""
      ;;
    login)
      echo -e "\n${W}GitHub CLI login${N}"
      if ! command -v gh &>/dev/null; then
        log_err "gh CLI not found. Install: brew install gh"
        return 1
      fi
      gh auth login
      ;;
    logout)
      echo -e "\n${W}GitHub CLI logout${N}"
      if ! command -v gh &>/dev/null; then
        log_err "gh CLI not found"
        return 1
      fi
      gh auth logout
      ;;
    token)
      # Show current token or refresh
      if ! command -v gh &>/dev/null; then
        log_err "gh CLI not found"
        return 1
      fi
      gh auth token
      ;;
    *)
      echo -e "Usage: ${W}harn auth${N} [status|login|logout|token]"
      echo -e "  ${W}status${N}   Show current GitHub authentication status"
      echo -e "  ${W}login${N}    Log in to GitHub via browser or token"
      echo -e "  ${W}logout${N}   Log out from GitHub"
      echo -e "  ${W}token${N}    Show the current auth token"
      ;;
  esac
}

# ── Bug report suggestion ─────────────────────────────────────────────────────

HARN_CMD_ARGS=("$@")
_HARN_ERR_LINE=""
_HARN_ERR_CMD=""
_HARN_SILENT_EXIT=0

# Record location of last bash error
trap '_HARN_ERR_LINE=$LINENO; _HARN_ERR_CMD=$BASH_COMMAND' ERR

_suggest_bug_report() {
  local error_msg="${1:-Unexpected error}"
  [[ $_HARN_SILENT_EXIT -eq 1 ]] && return 0

  echo ""
  echo -e "${Y}⚠  harn encountered an unexpected error.${N}"
  echo -e "   ${D}${error_msg}${N}"
  echo ""
  printf "   File a bug report on GitHub? [y/N]: "

  local ans=""
  if command -v python3 &>/dev/null; then
    ans=$(python3 -c '
import sys, tty, termios
fd = open("/dev/tty","rb+",buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    b = fd.read(1)
    c = b.decode("utf-8","replace") if b else ""
    fd.write((c + "\r\n").encode()); fd.flush()
    print(c, end="")
except Exception: pass
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    fd.close()
' 2>/dev/null)
  else
    read -r ans
  fi
  echo ""
  [[ "$ans" != "y" && "$ans" != "Y" ]] && return 0

  # Gather context
  local os_info; os_info=$(uname -s -r 2>/dev/null || echo "unknown")
  local log_tail=""
  [[ -f "${LOG_FILE:-}" ]] && log_tail=$(tail -30 "$LOG_FILE" 2>/dev/null || echo "")
  local cmd_args="${HARN_CMD_ARGS[*]:-unknown}"
  local err_loc=""
  [[ -n "$_HARN_ERR_LINE" ]] && err_loc=" (line $_HARN_ERR_LINE: \`$_HARN_ERR_CMD\`)"

  local issue_title="Bug: ${error_msg:0:80}"
  local issue_body
  issue_body=$(cat <<ISSUE_EOF
## Bug Report

**harn version:** \`$HARN_VERSION\`
**OS:** \`$os_info\`
**Command:** \`harn $cmd_args\`
**Error:** $error_msg$err_loc

## Recent Log

\`\`\`
$log_tail
\`\`\`

---
*Auto-generated by \`harn\` error reporter*
ISSUE_EOF
)

  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    echo -e "  ${D}Creating GitHub issue...${N}"
    local issue_url
    issue_url=$(gh issue create \
      --repo "Tyrannoapartment/harn" \
      --title "$issue_title" \
      --body "$issue_body" \
      --label "bug" 2>/dev/null)
    if [[ -n "$issue_url" ]]; then
      log_ok "Issue filed: ${W}${issue_url}${N}"
    else
      echo -e "  ${Y}Could not create issue. File manually:${N}"
      echo -e "  ${W}https://github.com/Tyrannoapartment/harn/issues/new${N}"
    fi
  else
    echo -e "  ${Y}gh CLI not authenticated. File manually:${N}"
    echo -e "  ${W}https://github.com/Tyrannoapartment/harn/issues/new${N}"
    echo ""
    echo -e "  Title: ${W}${issue_title}${N}"
  fi
  echo ""
}

_harn_on_exit() {
  local ec=$?
  # Only trigger for truly unexpected exits (not normal user-facing exits)
  # exit 0 = success, exit 1 = handled error, exit 130 = Ctrl+C
  if [[ $ec -gt 1 && $ec -ne 130 && $_HARN_SILENT_EXIT -eq 0 ]]; then
    _suggest_bug_report "Unexpected exit (code $ec)${_HARN_ERR_LINE:+ at line $_HARN_ERR_LINE}"
  fi
}
trap '_harn_on_exit' EXIT

# ── Routing ───────────────────────────────────────────────────────────────────
case "${1:-help}" in
  init)      cmd_init ;;
  auto)      cmd_auto ;;
  all)       cmd_all ;;
  discover)  cmd_discover ;;
  add)       cmd_add ;;
  start)     cmd_start ;;
  plan)      cmd_plan ;;
  contract)  cmd_contract ;;
  implement) cmd_implement ;;
  evaluate)  cmd_evaluate ;;
  next)      cmd_next "${2:-}" ;;
  stop)      cmd_stop ;;
  config)    cmd_config "${2:-show}" "${3:-}" "${4:-}" ;;
  backlog)   cmd_backlog ;;
  status)    cmd_status ;;
  auth)      cmd_auth "${2:-status}" ;;
  doctor)    cmd_doctor ;;
  tail)      cmd_tail ;;
  runs)      cmd_runs ;;
  resume)    cmd_resume "${2:-}" ;;
  help|--help|-h) usage ;;
  *) log_err "Unknown command: $1"; usage; exit 1 ;;
esac
