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

HARN_VERSION="1.5.1"

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
HARN_LANG=""          # set by _detect_lang(); ko | en

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
    codex*)   ansi_color=$'\033[0;33m' ;;  # yellow
    gemini*)  ansi_color=$'\033[0;35m' ;;  # magenta
    *)        ansi_color=$'\033[0;36m' ;;  # cyan
  esac
  local output
  output=$(python3 -c '
import sys, unicodedata, fcntl, termios, struct, os

def get_cols():
    for fd in (1, 0, 2):
        try:
            buf = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)
            _, cols = struct.unpack("HH", buf[:4])
            if cols > 0:
                return cols
        except Exception:
            pass
    try:
        import subprocess
        r = subprocess.run(["tput", "cols"], capture_output=True, text=True)
        v = int(r.stdout.strip())
        if v > 0:
            return v
    except Exception:
        pass
    return 80

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
cols   = get_cols()

reset  = "\033[0m"
bold_w = "\033[1;37m"
dim    = "\033[2m"

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

# ── Guidance (mid-run messages) ───────────────────────────────────────────────

GUIDANCE_LISTENER_PID=""

_stop_guidance_listener() {
  local pid="${1:-$GUIDANCE_LISTENER_PID}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    # Wait briefly for terminal restore
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
      sleep 0.1; ((i++))
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  GUIDANCE_LISTENER_PID=""
}

# Inline Python script for the guidance listener
# Written to a temp file and sourced/run as a Python subprocess
_guidance_listener_py() {
python3 -u - "$1" << 'PYEOF'
import sys, os, signal, select, termios, datetime, fcntl, struct, time

inbox_file = sys.argv[1]

def get_size():
    try:
        buf = fcntl.ioctl(1, termios.TIOCGWINSZ, b'\x00' * 8)
        rows, cols = struct.unpack('HH', buf[:4])
        return (rows or 24), (cols or 80)
    except Exception:
        return 24, 80

try:
    tfd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
    orig_attrs = termios.tcgetattr(tfd)
except Exception:
    sys.exit(0)

def restore():
    try:
        rows, cols = get_size()
        os.write(tfd, b'\033[r')
        os.write(tfd, f'\033[{rows-1};1H\033[2K\033[{rows};1H\033[2K'.encode())
        os.write(tfd, b'\033[?25h')
        termios.tcsetattr(tfd, termios.TCSANOW, orig_attrs)
    except Exception:
        pass

def set_cbreak():
    mode = list(termios.tcgetattr(tfd))
    # Disable ECHO and ICANON, keep OPOST intact
    mode[3] = mode[3] & ~(termios.ECHO | termios.ICANON | termios.IEXTEN)
    mode[6][termios.VMIN] = 1
    mode[6][termios.VTIME] = 0
    termios.tcsetattr(tfd, termios.TCSANOW, mode)

_first_draw = True

def get_cursor_row():
    """Query terminal for current cursor row via DSR. Returns row (1-based) or None."""
    try:
        import re
        os.write(tfd, b'\033[6n')
        resp = b''
        deadline = time.time() + 0.3
        while time.time() < deadline:
            r2, _, _ = select.select([tfd], [], [], 0.05)
            if r2:
                resp += os.read(tfd, 32)
                if b'R' in resp:
                    break
        m = re.search(rb'\033\[(\d+);(\d+)R', resp)
        if m:
            return int(m.group(1))
    except Exception:
        pass
    return None

def draw_bar(buf=''):
    global _first_draw
    try:
        rows, cols = get_size()
        # Set scroll region (top 1 to rows-2, leaving bottom 2 for input bar)
        os.write(tfd, f'\033[1;{rows-2}r'.encode())
        # Save cursor
        os.write(tfd, b'\033[s')
        # Draw separator line (row rows-1)
        sep = ('─' * cols)
        os.write(tfd, f'\033[{rows-1};1H\033[2K\033[2m{sep}\033[0m'.encode())
        # Draw input row (row rows)
        os.write(tfd, f'\033[{rows};1H\033[2K'.encode())
        prompt_str = '  \033[1;35m💬\033[0m  \033[1m>\033[0m  '
        prompt_visible = 8  # visual width of prompt
        avail = cols - prompt_visible - 1
        display = buf[-avail:] if len(buf) > avail else buf
        os.write(tfd, (prompt_str + display).encode('utf-8', 'replace'))
        # Restore cursor
        os.write(tfd, b'\033[u')
        # On first draw: if the cursor is outside the scroll region (i.e. in the
        # protected bottom rows) clamp it to rows-2 so agent output doesn't
        # overwrite the input bar. We query the actual cursor position first so
        # we only clamp when necessary — unconditional clamping would scroll the
        # log_agent_start box off-screen when it was already in the safe area.
        if _first_draw:
            _first_draw = False
            cur_row = get_cursor_row()
            if cur_row is not None and cur_row >= rows - 1:
                os.write(tfd, f'\033[{rows-2};1H'.encode())
    except OSError:
        pass

def on_sigterm(sig, frame):
    restore()
    sys.exit(0)

def on_sigwinch(sig, frame):
    try:
        draw_bar(current_buf[0])
    except Exception:
        pass

signal.signal(signal.SIGTERM, on_sigterm)
signal.signal(signal.SIGINT, signal.SIG_IGN)
try:
    signal.signal(signal.SIGWINCH, on_sigwinch)
except Exception:
    pass

set_cbreak()

current_buf = ['']  # mutable for sigwinch handler
draw_bar()

pending = b''
try:
    while True:
        try:
            r, _, _ = select.select([tfd], [], [], 1.0)
        except Exception:
            time.sleep(0.2)
            continue
        if not r:
            continue
        try:
            chunk = os.read(tfd, 64)
        except OSError:
            break
        if not chunk:
            break
        pending += chunk
        while pending:
            b0 = pending[0]
            if b0 < 0x80:
                char = chr(b0)
                pending = pending[1:]
            elif b0 < 0xE0:
                if len(pending) < 2: break
                char = pending[:2].decode('utf-8', 'replace')
                pending = pending[2:]
            elif b0 < 0xF0:
                if len(pending) < 3: break
                char = pending[:3].decode('utf-8', 'replace')
                pending = pending[3:]
            else:
                if len(pending) < 4: break
                char = pending[:4].decode('utf-8', 'replace')
                pending = pending[4:]

            code = b0 if b0 < 0x80 else -1

            if code in (13, 10):  # Enter
                if current_buf[0].strip():
                    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
                    with open(inbox_file, 'a') as f:
                        f.write(f'[{ts}] {current_buf[0]}\n')
                current_buf[0] = ''
                draw_bar()
            elif code in (127, 8):  # Backspace
                if current_buf[0]:
                    current_buf[0] = current_buf[0][:-1]
                    draw_bar(current_buf[0])
            elif code == 3:  # Ctrl+C
                break
            elif code == 27:  # ESC sequence — skip
                pending = pending  # already advanced
            elif code >= 32 or code < 0:  # printable / multibyte
                current_buf[0] += char
                draw_bar(current_buf[0])
finally:
    restore()
PYEOF
}

_start_guidance_listener() {
  local inbox_file="$1"
  _guidance_listener_py "$inbox_file" &
  GUIDANCE_LISTENER_PID=$!
  disown "$GUIDANCE_LISTENER_PID" 2>/dev/null || true
}

_has_guidance() {
  local role_type="$1"
  local run_dir
  run_dir=$(readlink -f "$HARN_DIR/current" 2>/dev/null) || return 1
  [[ -f "$run_dir/guidance-${role_type}.md" && -s "$run_dir/guidance-${role_type}.md" ]] && return 0
  [[ -f "$run_dir/guidance-context.md" && -s "$run_dir/guidance-context.md" ]] && return 0
  return 1
}

_inject_guidance() {
  local role_type="$1"
  local run_dir
  run_dir=$(readlink -f "$HARN_DIR/current" 2>/dev/null) || return 0
  local block=""
  local role_file="$run_dir/guidance-${role_type}.md"
  if [[ -f "$role_file" && -s "$role_file" ]]; then
    block+="$(cat "$role_file")"$'\n'
    [[ "$role_type" != "context" ]] && > "$role_file"
  fi
  local ctx_file="$run_dir/guidance-context.md"
  if [[ -f "$ctx_file" && -s "$ctx_file" ]]; then
    block+="$(cat "$ctx_file")"$'\n'
  fi
  if [[ -n "$block" ]]; then
    printf '## User Guidance (Mid-run Instructions)\n\nThe user sent these instructions while the previous agent was running — incorporate them:\n\n%s\n---\n\n' "$block"
  fi
}

_classify_guidance() {
  local msg="$1"
  local ai_cmd
  ai_cmd=$(_detect_ai_cli 2>/dev/null) || ai_cmd="copilot"
  local prompt="다음 메시지의 의도를 implement, evaluate, plan, context 중 정확히 하나로만 답해줘 (단어 하나만):

메시지: $msg

- implement: 구현/코드/API/UI/기능 관련
- evaluate: 테스트/검증/QA/확인 관련
- plan: 계획/스프린트/목표/변경 관련
- context: 위에 해당없는 배경지식/설정"

  local result=""
  case "$ai_cmd" in
    copilot) result=$(copilot --yolo -p "$prompt" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]') ;;
    claude)  result=$(claude -p "$prompt" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]') ;;
  esac

  case "${result:0:10}" in
    *implement*) echo "implement" ;;
    *evaluate*)  echo "evaluate"  ;;
    *plan*)      echo "plan"      ;;
    *context*)   echo "context"   ;;
    *)
      local lower; lower=$(echo "$msg" | tr '[:upper:]' '[:lower:]')
      if   echo "$lower" | grep -qiE 'test|테스트|검증|qa|verify|coverage'; then echo "evaluate"
      elif echo "$lower" | grep -qiE 'plan|계획|sprint|스프린트|목표|변경계획'; then echo "plan"
      elif echo "$lower" | grep -qiE 'code|코드|구현|api|ui|함수|컴포넌트|기능'; then echo "implement"
      else echo "implement"
      fi
      ;;
  esac
}

_process_inbox() {
  local inbox_file="$1"
  [[ ! -f "$inbox_file" || ! -s "$inbox_file" ]] && return 0
  local run_dir
  run_dir=$(readlink -f "$HARN_DIR/current" 2>/dev/null) || return 0

  local content; content=$(cat "$inbox_file")
  > "$inbox_file"  # clear inbox

  # Display received messages box
  local term_cols; term_cols=$(tput cols 2>/dev/null || echo 80)
  local inner=$((term_cols - 6))
  local W="\033[1;37m" D="\033[2m" M="\033[1;35m" N="\033[0m"
  local bar; bar=$(printf '  ╭─ %b💬 수신된 메시지%b ' "$M" "$N"; printf '─%.0s' $(seq 1 $((inner - 12))); printf '╮')
  echo -e "\n$bar"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local ts="${line%%\]*}]"
    local msg="${line#*\] }"
    printf '  │  %b%s%b  %b%s%b\n' "$D" "$ts" "$N" "$W" "$msg" "$N"
    # Classify
    local intent; intent=$(_classify_guidance "$msg")
    echo "$line" >> "$run_dir/guidance-${intent}.md"
  done <<< "$content"
  echo -e "  ╰$(printf '─%.0s' $(seq 1 $((inner + 2))))╯"

  # Show routing summary
  local -A labels=([implement]="Generator" [evaluate]="Evaluator" [plan]="Planner" [context]="모든 에이전트")
  for t in implement evaluate plan context; do
    local gf="$run_dir/guidance-${t}.md"
    [[ -f "$gf" && -s "$gf" ]] && echo -e "  ${D}→ ${t}  (${labels[$t]}에 전달)${N}"
  done
  echo ""
}

cmd_inbox() {
  local sub="${1:-show}"
  local run_dir
  run_dir=$(readlink -f "$HARN_DIR/current" 2>/dev/null) || { log_err "No active run."; return 1; }

  case "$sub" in
    clear)
      for t in implement evaluate plan context; do
        > "$run_dir/guidance-${t}.md" 2>/dev/null || true
      done
      > "$run_dir/inbox.md" 2>/dev/null || true
      log_ok "Guidance queue cleared."
      ;;
    show|*)
      local any=0
      for t in implement evaluate plan context; do
        local gf="$run_dir/guidance-${t}.md"
        if [[ -f "$gf" && -s "$gf" ]]; then
          echo -e "\n  ${W}[${t}]${N}"
          while IFS= read -r line; do
            echo -e "  ${D}$line${N}"
          done < "$gf"
          any=1
        fi
      done
      local inbox_f="$run_dir/inbox.md"
      if [[ -f "$inbox_f" && -s "$inbox_f" ]]; then
        echo -e "\n  ${Y}[inbox — 미분류]${N}"
        cat "$inbox_f"
        any=1
      fi
      [[ $any -eq 0 ]] && echo -e "  ${D}(대기 중인 메시지 없음)${N}"
      ;;
  esac
}


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
  echo -e "${B}  ╭─ ${I18N_INSTRUCTIONS_TITLE}${N}" >/dev/tty
  printf "${B}  │${N}  $(printf "$I18N_INSTRUCTIONS_ENTER" "${W}${context}${N}")\n" >/dev/tty
  echo -e "${B}  │${N}  ${D}${I18N_INSTRUCTIONS_HINT}${N}" >/dev/tty
  echo -e "${B}  ╰${N}" >/dev/tty

  local content
  content=$(_input_multiline)

  if [[ -n "$content" ]]; then
    USER_EXTRA_INSTRUCTIONS="${USER_EXTRA_INSTRUCTIONS}
## User Instructions ($(_ts))

${content}"
    echo -e "  ${G}${I18N_INSTRUCTIONS_PASSED}${N}" >/dev/tty
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
except (KeyboardInterrupt, OSError):
    cancelled = True
finally:
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception:
        pass
try:
    fd.close()
except Exception:
    pass
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
except (KeyboardInterrupt, OSError):
    pass
finally:
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception:
        pass
try:
    fd.close()
except Exception:
    pass
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
    if prompt:
        fd.write(f"\r\n  \033[1m{prompt}\033[0m\r\n".encode())
        fd.write(b"  \033[2m(\xe2\x86\x91\xe2\x86\x93 navigate  Enter select  Ctrl+Q cancel)\033[0m\r\n\r\n")
    else:
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

# Detect language: env HARN_LANG → config LANG_OVERRIDE → $LANG/$LC_ALL → en
_detect_lang() {
  # 1. Explicit env var
  if [[ -n "${HARN_LANG:-}" ]]; then
    HARN_LANG="${HARN_LANG}"
    return
  fi
  # 2. Config file override (read directly — load_config may not have run yet)
  if [[ -f "$CONFIG_FILE" ]]; then
    local cfg_lang
    cfg_lang=$(grep -E '^LANG_OVERRIDE=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    if [[ -n "$cfg_lang" ]]; then
      HARN_LANG="$cfg_lang"
      return
    fi
  fi
  # 3. System locale
  local sys_locale="${LANG:-${LC_ALL:-}}"
  if [[ "$sys_locale" == ko* ]]; then
    HARN_LANG="ko"
    return
  fi
  # 4. Default
  HARN_LANG="en"
}

# Set UI string variables based on HARN_LANG
_i18n_load() {
  if [[ "$HARN_LANG" == "ko" ]]; then
    I18N_LANG_NAME="한국어"
    I18N_INIT_LANG_PROMPT="사용 언어"
    I18N_INIT_BACKLOG_PROMPT="백로그 파일 경로 (프로젝트 루트 기준)"
    I18N_INIT_BACKLOG_DEFAULT="sprint-backlog.md"
    I18N_INIT_MAX_QA_PROMPT="최대 QA 재시도 횟수"
    I18N_INIT_GIT_PROMPT="Git 통합 활성화"
    I18N_INIT_SAVED="설정이 저장됐어요"
    I18N_DOCTOR_TITLE="harn 환경 진단"
    I18N_DOCTOR_OK="정상"
    I18N_DOCTOR_WARN="경고"
    I18N_DOCTOR_FAIL="실패"
    I18N_CONFIG_SET_DONE="설정 저장됨"
    I18N_CONFIG_SET_USAGE="사용법: harn config set <key> <value>"
    I18N_LANG_SELECT="사용할 언어를 선택하세요"
    # usage()
    I18N_USAGE_TITLE="사용법"
    I18N_USAGE_CMD="harn <명령어>"
    I18N_USAGE_SETUP="설정"
    I18N_USAGE_BACKLOG="백로그"
    I18N_USAGE_RUN="실행"
    I18N_USAGE_STEPS="단계별 실행"
    I18N_USAGE_MONITOR="모니터링"
    I18N_USAGE_INIT="초기 설정 (첫 실행 또는 재설정)"
    I18N_USAGE_CONFIG="현재 설정 보기"
    I18N_USAGE_CONFIG_SET="특정 설정 변경"
    I18N_USAGE_CONFIG_REGEN="HINT_* 값으로 커스텀 프롬프트 재생성"
    I18N_USAGE_BACKLOG_CMD="백로그 항목 목록"
    I18N_USAGE_ADD="새 백로그 항목 추가 (AI 보조)"
    I18N_USAGE_DISCOVER="코드베이스 분석 후 작업 발굴"
    I18N_USAGE_START="항목 선택 후 전체 루프 실행"
    I18N_USAGE_AUTO="자동 감지: 재개 / 시작 / 발굴"
    I18N_USAGE_ALL="대기 중인 항목 전부 순차 실행 (마지막에 회고)"
    I18N_USAGE_PLAN="플래너 재실행"
    I18N_USAGE_CONTRACT="스코프 협상"
    I18N_USAGE_IMPLEMENT="제너레이터 실행"
    I18N_USAGE_EVALUATE="이밸류에이터 실행"
    I18N_USAGE_NEXT="다음 스프린트로 이동"
    I18N_USAGE_STATUS="현재 실행 상태"
    I18N_USAGE_TAIL="실시간 로그 출력"
    I18N_USAGE_RUNS="전체 실행 목록"
    I18N_USAGE_RESUME="이전 실행 재개"
    I18N_USAGE_STOP="루프 중단"
    I18N_USAGE_TIP="루프 실행 중에도 단계 사이에 추가 지시사항을 넣을 수 있어요."
    # doctor
    I18N_DOCTOR_VERSION="버전"
    I18N_DOCTOR_BACKENDS="AI 백엔드"
    I18N_DOCTOR_NOT_FOUND="설치되지 않음"
    I18N_DOCTOR_INSTALL="설치"
    I18N_DOCTOR_ACTIVE_BACKEND="활성 백엔드"
    I18N_DOCTOR_NO_BACKEND="AI 백엔드 없음 — harn init 실행 필요"
    I18N_DOCTOR_GIT_SECTION="Git"
    I18N_DOCTOR_GH_AUTH_WARN="인증 안 됨 — gh auth login 실행 필요"
    I18N_DOCTOR_GH_NOT_FOUND="설치되지 않음 — PR 기능 비활성화"
    I18N_DOCTOR_PROJECT_REPO="프로젝트 저장소"
    I18N_DOCTOR_CONFIG_SECTION="harn 설정"
    I18N_DOCTOR_CONFIG_FOUND="설정 파일 있음"
    I18N_DOCTOR_CONFIG_NOT_FOUND="설정 안 됨 (harn init 실행 필요)"
    I18N_DOCTOR_GIT_INTEGRATION="Git 통합"
    I18N_DOCTOR_BASE_BRANCH="기본 브랜치"
    I18N_DOCTOR_PR_TARGET="PR 타겟 브랜치"
    I18N_DOCTOR_SPRINT_COUNT="스프린트 수"
    I18N_DOCTOR_AI_BACKEND="AI 백엔드"
    I18N_DOCTOR_CUSTOM_PROMPTS="커스텀 프롬프트"
    I18N_DOCTOR_MODELS="모델"
    I18N_DOCTOR_ACTIVE_RUN="현재 실행"
    I18N_DOCTOR_SPRINT="스프린트"
    I18N_DOCTOR_NO_RUN="현재 실행 없음"
    I18N_DOCTOR_DEPS="기타 의존성"
    I18N_DOCTOR_OPTIONAL="선택사항"
    I18N_DOCTOR_ALL_OK="모든 핵심 검사 통과."
    I18N_DOCTOR_FAIL_MSG="하나 이상의 핵심 검사 실패. harn init 실행 필요"
    # no-config warning
    I18N_NO_CONFIG_WARN=".harn_config 파일이 없습니다."
    I18N_NO_CONFIG_SETUP="초기 설정을 시작합니다..."
    # cmd_init
    I18N_INIT_TITLE="harn 초기 설정"
    I18N_INIT_OVERWRITE="설정 파일이 이미 있습니다. 덮어쓸까요? [y/N]: "
    I18N_INIT_CANCELLED="초기화 취소됨"
    I18N_INIT_AI_MODELS="AI 모델 설정"
    I18N_INIT_AI_MODELS_HINT="↑↓ 방향키로 이동, Enter로 선택, Ctrl+Q로 취소"
    I18N_INIT_SPRINT_STRUCTURE="스프린트 구조"
    I18N_INIT_SPRINT_COUNT_PROMPT="스프린트 수 [2]: "
    I18N_INIT_SPRINT_ROLES_HINT="각 스프린트의 목표/역할을 입력하세요 (Enter = 기본값 사용)"
    I18N_INIT_SPRINT_ROLE_PROMPT="스프린트 %s 역할: "
    I18N_INIT_SPRINT_INVALID="잘못된 스프린트 수 '%s' — 기본값 2로 설정"
    I18N_INIT_GIT_SECTION="Git 통합"
    I18N_INIT_GIT_ENABLE_PROMPT="Git 통합을 활성화할까요? [y/N]: "
    I18N_INIT_GIT_BASE_PROMPT="기본 작업 브랜치 (또는 'current'로 현재 브랜치 사용) [main]: "
    I18N_INIT_GIT_TARGET_PROMPT="PR 대상 브랜치 (PR이 머지될 브랜치) [%s]: "
    I18N_INIT_GIT_AUTOPUSH_PROMPT="자동 push? [y/N]: "
    I18N_INIT_GIT_AUTOPR_PROMPT="자동 PR 생성? [y/N]: "
    I18N_INIT_GIT_DRAFT_PROMPT="Draft PR로 생성? [Y/n]: "
    I18N_INIT_GIT_GUIDE_TITLE="Git 워크플로우 가이드라인"
    I18N_INIT_GIT_GUIDE_HINT="브랜치 전략, 커밋 컨벤션, PR 규칙 등을 입력하세요.\n  에이전트 프롬프트에 반영됩니다. (Enter = 건너뜀)"
    I18N_INIT_HINTS_TITLE="에이전트별 특별 지시사항"
    I18N_INIT_HINTS_HINT="프로젝트 아키텍처, 기술 스택, 코딩 컨벤션 등을 입력하세요.\n  AI CLI가 기본 프롬프트에 자연스럽게 통합합니다. (Enter = 건너뜀)"
    I18N_INIT_HINT_PLANNER="Planner   — 스펙/스프린트 계획 지시사항: "
    I18N_INIT_HINT_GENERATOR="Generator — 구현 지시사항: "
    I18N_INIT_HINT_EVALUATOR="Evaluator — QA/평가 지시사항: "
    I18N_INIT_CONFIG_SAVED="설정 파일 생성됨"
    I18N_INIT_GEN_PROMPTS="AI CLI로 커스텀 프롬프트 생성 중"
    I18N_INIT_COMPLETE="초기화 완료!"
    I18N_INIT_HINT_BACKLOG="  harn backlog  — 백로그 항목 보기"
    I18N_INIT_HINT_START="  harn start    — 루프 시작"
    # AI CLI check / backend selection
    I18N_NO_AI_CLI="AI CLI를 찾을 수 없어요."
    I18N_NO_AI_CLI_HINT="harn은 GitHub Copilot CLI, Claude CLI, OpenAI Codex CLI, 또는 Gemini CLI가 필요합니다."
    I18N_AI_BACKEND_TITLE="기본 AI 백엔드"
    I18N_AI_USING_COPILOT="${G}✓${N} ${W}copilot${N} 사용 (GitHub Copilot CLI 감지됨)"
    I18N_AI_USING_CLAUDE="${G}✓${N} ${W}claude${N} 사용 (Anthropic Claude CLI 감지됨)"
    I18N_AI_USING_CODEX="${G}✓${N} ${W}codex${N} 사용 (OpenAI Codex CLI 감지됨)"
    I18N_AI_USING_GEMINI="${G}✓${N} ${W}gemini${N} 사용 (Google Gemini CLI 감지됨)"
    # cmd_backlog
    I18N_BACKLOG_TITLE="대기 중인 백로그 항목:"
    I18N_BACKLOG_EMPTY="(없음 — 모두 완료!)"
    I18N_BACKLOG_RUN="실행: ${W}harn start${N} — 항목을 선택해 전체 루프를 시작하세요"
    # cmd_start
    I18N_START_SELECT_ITEM="백로그 항목 선택"
    I18N_START_NO_PENDING="대기 중인 항목이 없습니다. 먼저 항목을 추가하세요."
    I18N_START_DISCOVER_HINT="항목 발굴: harn discover"
    I18N_START_ENTER_NUM="번호를 입력하세요 (1–%s): "
    I18N_START_SELECTED="선택됨:"
    I18N_START_INVALID="잘못된 입력:"
    I18N_START_RUN_CREATED="실행 생성됨:"
    I18N_START_VIEW_LOG="실시간 로그 보기: ${W}harn tail${N}  →"
    I18N_START_PLAN_FAILED="플래닝 단계에서 실패했습니다. 로그를 확인하고 재시도하세요:"
    I18N_START_AUTO_LOOP="자동 실행 시작"
    I18N_START_LOOP_DETAIL="초기화 완료. 스프린트 루프를 자동으로 실행합니다 (contract → implement → evaluate → next, 최대 %s 스프린트)."
    I18N_START_LOOP_INTERRUPTED="스프린트 루프가 중단됐습니다. 실패 지점을 확인하고 재개하세요: 'harn resume %s'"
    I18N_START_COMPLETE="harn start 전체 자동 실행 완료"
    I18N_START_MAX_SPRINT="최대 스프린트 수(%s)에 도달했습니다. 계속하려면 'harn start'를 실행하세요."
    # cmd_plan
    I18N_PLAN_STEP="플래닝 단계"
    I18N_PLAN_TEXT_NOT_FOUND="plan.text를 찾을 수 없음 — 슬러그/프롬프트를 플랜 텍스트로 사용"
    I18N_PLAN_MARKERS_NOT_FOUND="섹션 마커를 찾을 수 없음 — 전체 출력을 spec.md로 저장"
    I18N_PLAN_ITEM_IN_PROGRESS="백로그: ${W}%s${N} → 진행 중"
    I18N_PLAN_LINE_UPDATED="백로그 플랜 라인 업데이트됨:"
    I18N_PLAN_LINE_FAILED="백로그 플랜 업데이트 실패: 슬러그를 찾을 수 없음"
    I18N_PLAN_LINE_UNCHANGED="백로그 플랜 라인 변경 없음 (이미 최신)"
    I18N_PLAN_LINE_EXCEPTION="백로그 플랜 업데이트 중 오류 발생"
    I18N_PLAN_COMPLETE="플래닝 완료"
    # cmd_contract
    I18N_CONTRACT_EXISTS="스코프가 이미 존재합니다. 재생성하려면 삭제하세요:"
    I18N_CONTRACT_STEP="스프린트 %s — 스코프 협상"
    I18N_CONTRACT_REVIEWING="이밸류에이터가 스코프 검토 중..."
    I18N_CONTRACT_APPROVED="스프린트 %s 스코프 승인됨"
    I18N_CONTRACT_NEEDS_REVISION="스코프 수정 필요 — 수정 중..."
    I18N_CONTRACT_REVISED="스프린트 %s 스코프 수정 완료"
    I18N_CONTRACT_NEXT="다음 단계: harn implement"
    # cmd_implement
    I18N_IMPL_NO_SCOPE="스프린트 %s의 스코프가 없습니다. 실행: harn contract"
    I18N_IMPL_STEP="스프린트 %s — 개발 (반복 %s)"
    I18N_IMPL_COMPLETE="스프린트 %s 구현 완료 (반복 %s)"
    I18N_IMPL_NEXT="다음 단계: harn evaluate"
    # cmd_evaluate
    I18N_EVAL_NO_IMPL="스프린트 %s의 구현체가 없습니다. 실행: harn implement"
    I18N_EVAL_STEP="스프린트 %s — 평가 (반복 %s)"
    I18N_EVAL_RUNNING_CHECKS="자동화 검사 실행 중..."
    I18N_EVAL_CHECKS_DONE="검사 완료 →"
    I18N_EVAL_SHUTTING_DOWN="E2E 환경 종료 중..."
    I18N_EVAL_EXEC_ERROR="스프린트 %s: 이밸류에이터 실행 오류 (종료 코드 %s) — 루프 중단"
    I18N_EVAL_MANUAL_RESUME="수동 재개: 문제를 수정한 후 harn evaluate 또는 harn implement를 실행하세요"
    I18N_EVAL_PASS="스프린트 %s: ${G}PASS${N}"
    I18N_EVAL_NEXT="다음 단계: harn next"
    I18N_EVAL_FAIL="스프린트 %s: QA ${Y}FAIL${N} (반복 %s / %s) — 자동 재시도 중... (리포트: %s)"
    # cmd_next
    I18N_NEXT_STEP="마무리"
    I18N_NEXT_DONE="백로그: ${W}%s${N} → 완료"
    I18N_NEXT_COMPLETE="${G}태스크 완전 완료: %s${N}"
    # _sprint_advance
    I18N_SPRINT_SWITCH="스프린트 %s로 전환"
    # cmd_stop
    I18N_STOP_NO_PID="실행 중인 프로세스를 찾을 수 없습니다 (PID 파일 없음)"
    I18N_STOP_ALREADY_HINT="이미 중단됐거나 harn start로 시작되지 않은 프로세스입니다."
    I18N_STOP_STALE_PID="PID=%s 프로세스가 이미 중단됨 — PID 파일 정리 중"
    I18N_STOP_STOPPING="프로세스 중단 중... (PID: ${W}%s${N})"
    I18N_STOP_SIGKILL="SIGTERM 후에도 실행 중 — SIGKILL 전송 중"
    I18N_STOP_RUN_STOPPED="실행 중단됨"
    I18N_STOP_DONE="프로세스 중단됨"
    # git helpers
    I18N_GIT_NO_HEAD="Git: HEAD를 확인할 수 없음 — 건너뜀"
    I18N_GIT_CURRENT_BRANCH="Git: 현재 브랜치에서 작업 중 ${W}%s${N} (base=current 모드)"
    I18N_GIT_CREATING_BRANCH="Git: 플래닝 브랜치 생성 중"
    I18N_GIT_NO_HEAD_BRANCH="Git: HEAD를 확인할 수 없음 — 브랜치 생성 건너뜀"
    I18N_GIT_BRANCH_EXISTS="브랜치 ${W}%s${N} 이미 존재 — 체크아웃 중"
    I18N_GIT_BRANCH_CREATED="브랜치 생성됨: ${W}%s${N}"
    I18N_GIT_BACKLOG_COMMITTED="스프린트 백로그 커밋됨"
    I18N_GIT_BACKLOG_UNCHANGED="백로그 파일 변경 없음 — 커밋 건너뜀"
    I18N_GIT_PUSH_FAILED_PR="Push 실패 — Draft PR 생성 건너뜀. 수동으로 Push 후 PR을 생성하세요."
    I18N_GIT_BRANCH_PUSHED="브랜치 Push됨: origin/${W}%s${N}"
    I18N_GIT_PR_CREATING="Draft PR 생성 중... (base: ${W}%s${N}, head: ${W}%s${N})"
    I18N_GIT_PR_CREATED="Draft PR 생성됨:"
    I18N_GIT_PR_FAILED="PR 생성 실패 — 수동으로 생성하세요"
    I18N_GIT_PR_CREATE_FAILED="gh pr create 실패 — 수동으로 PR을 생성하세요 (%s → %s)"
    I18N_GIT_IMPL_COMMIT="Git: 스프린트 %s 구현 커밋"
    I18N_GIT_NO_CHANGES="커밋할 변경 사항 없음 — 제너레이터가 파일을 수정하지 않았을 수 있습니다"
    I18N_GIT_COMMIT_DONE="커밋 완료: ${W}%s${N}"
    I18N_GIT_PUSH_DONE="Push 완료: origin/${W}%s${N}"
    I18N_GIT_PUSH_FAILED="Push 실패 — 실행: git push origin %s"
    I18N_GIT_NO_HEAD_PUSH="Git: HEAD를 확인할 수 없음 — Push 건너뜀"
    I18N_GIT_SPRINT_PASS_PUSH="Git: 스프린트 %s 통과 — origin/${W}%s${N}에 Push 중"
    I18N_GIT_NO_FEAT_BRANCH="Git: 병합할 피처 브랜치를 찾을 수 없음 (현재: %s)"
    I18N_GIT_FINALIZE="Git 최종화: ${W}%s${N} → ${W}%s${N}"
    I18N_GIT_AUTO_COMMIT="미커밋 변경 사항 자동 커밋 중..."
    I18N_GIT_UPDATE_PR="PR 업데이트 중: origin/${W}%s${N} Push 중..."
    I18N_GIT_PUSH_FAILED_MANUAL="Push 실패 — PR을 수동으로 병합하세요"
    I18N_GIT_PR_MERGING="PR 병합 중 (non-squash): ${W}%s${N}"
    I18N_GIT_PR_MERGED="PR 병합 완료: ${W}%s${N} → ${W}%s${N}"
    I18N_GIT_PR_MERGE_FAILED="gh pr merge 실패 — GitHub에서 수동으로 병합 후 계속하세요"
    I18N_GIT_RETURN_BASE="기본 브랜치로 돌아가는 중: ${W}%s${N}"
    I18N_GIT_PULLING="Pull 중: origin/${W}%s${N}..."
    I18N_GIT_PULL_DONE="Pull 완료: origin/${W}%s${N}"
    I18N_GIT_PULL_FAILED="Pull 실패 — 실행: git pull origin %s"
    # cmd_retrospective
    I18N_RETRO_NO_CLI="AI CLI 없음 — 회고 건너뜀"
    I18N_RETRO_STEP="회고"
    I18N_RETRO_ANALYZING="AI(${W}%s${N}) 회고 분석 중..."
    I18N_RETRO_FAILED="회고 생성 실패 — 건너뜀"
    I18N_RETRO_SUMMARY_TITLE="  회고 요약"
    I18N_RETRO_PROMPT_ADD="  %s 프롬프트에 이 제안을 추가할까요? [y/N]: "
    I18N_RETRO_ADDED="%s 프롬프트에 추가됨: ${W}%s${N}"
    I18N_RETRO_SKIPPED="%s 제안 건너뜀"
    I18N_RETRO_APPLIED="프롬프트 개선 사항 적용됨."
    I18N_RETRO_COMPLETE="회고 완료 — 결과: ${W}%s${N}"
    # _run_sprint_loop
    I18N_LOOP_STARTED="루프 시작 (최대 %s 스프린트)"
    I18N_LOOP_INTERRUPTED="사용자에 의해 중단됨."
    I18N_LOOP_TERMINATED="종료 신호를 받았습니다."
    I18N_LOOP_SPRINT_PASSED="스프린트 %s 이미 완료 — 다음으로 이동"
    I18N_LOOP_SPRINT_MAX_ITER="스프린트 %s가 최대 반복 횟수(%s)에 도달 — 강제 진행"
    I18N_LOOP_EVAL_ERROR="이밸류에이터 오류 — 루프 중단. 문제를 수정한 후 harn evaluate를 실행하세요."
    I18N_LOOP_MAX_ITER_ADVANCE="스프린트 %s: 최대 반복 횟수(%s) 도달 — QA 통과 없이 강제 진행"
    I18N_LOOP_ALL_COMPLETE="${G}전체 %s 스프린트 완료!${N}"
    I18N_LOOP_SPRINT_DONE="스프린트 %s 완료 — 스프린트 %s로 전환"
    # cmd_discover
    I18N_DISCOVER_STEP="백로그 발굴 — 코드베이스 분석"
    I18N_DISCOVER_NO_ITEMS="새 항목을 추출할 수 없습니다 — 확인하세요: %s"
    I18N_DISCOVER_BACKLOG_CREATED="백로그 파일 생성됨:"
    I18N_DISCOVER_ADDED="백로그에 새 항목 추가됨"
    I18N_DISCOVER_HINT="확인: harn backlog   /   지금 시작: harn auto"
    # cmd_add
    I18N_ADD_STEP="백로그 항목 추가"
    I18N_ADD_BACKLOG_CREATED="백로그 파일 생성됨:"
    I18N_ADD_BOX_TITLE="✚ 새 백로그 항목"
    I18N_ADD_BOX_DESC="구현하려는 기능 또는 작업을 설명하세요."
    I18N_ADD_BOX_AI="AI가 슬러그와 설명을 생성해 백로그에 추가합니다."
    I18N_ADD_BOX_HINT="여러 줄 입력 가능  ·  빈 줄로 종료"
    I18N_ADD_CANCELLED="입력 없음 — 취소됨"
    I18N_ADD_NO_CLI="AI CLI를 찾을 수 없습니다. copilot 또는 claude를 설치하세요."
    I18N_ADD_GENERATING="AI(${W}%s${N}) 백로그 항목 생성 중..."
    I18N_ADD_FAILED="AI 생성 실패"
    I18N_ADD_NO_ITEMS="항목을 추출할 수 없습니다 — 확인하세요: %s"
    I18N_ADD_DONE="백로그에 추가됨:"
    I18N_ADD_HINT="확인: ${W}harn backlog${N}   /   지금 시작: ${W}harn start${N}"
    # cmd_auto
    I18N_AUTO_STEP="자동 모드"
    I18N_AUTO_RESUMING="진행 중인 실행 재개: ${W}%s${N}  (스프린트 %s · %s)"
    I18N_AUTO_CANCELLED="마지막 실행이 취소됨 — 다음 항목을 찾는 중"
    I18N_AUTO_COMPLETED="마지막 실행 완료 (${W}%s${N}) — 다음 항목을 찾는 중"
    I18N_AUTO_STARTING="다음 백로그 항목 시작: ${W}%s${N}"
    I18N_AUTO_EMPTY="백로그가 비어 있습니다."
    I18N_AUTO_FIRST_DISCOVERED="첫 번째 발굴 항목 시작: ${W}%s${N}"
    # cmd_all
    I18N_ALL_NO_BACKLOG="백로그 파일을 찾을 수 없습니다:"
    I18N_ALL_NO_PENDING="대기 중인 항목이 없습니다."
    I18N_ALL_HINT="항목 추가: ${W}harn discover${N}  또는  ${W}harn add${N}"
    I18N_ALL_STEP="전체 자동 실행 —"
    I18N_ALL_STARTING="[%s/%s] 항목 시작: ${W}%s${N}"
    I18N_ALL_COMPLETE_ITEM="[%s/%s] 완료: ${W}%s${N}"
    I18N_ALL_FAILED_ITEM="[%s/%s] 실패: ${W}%s${N} — 다음 항목으로 계속"
    I18N_ALL_FAILED_ITEMS="실패한 항목:"
    I18N_ALL_RETRY_HINT="실패 항목 수동 재실행: ${W}harn start <slug>${N}"
    I18N_ALL_RETRO_STEP="회고 실행 중 (%s개 항목)"
    I18N_ALL_RETRO_ITEM="회고: ${W}%s${N}"
    # cmd_status
    I18N_STATUS_NO_RUN="활성 실행 없음. 시작하려면: ${W}harn start${N}"
    I18N_STATUS_RUN_ID="실행 ID:"
    I18N_STATUS_ITEM="항목:"
    I18N_STATUS_SPRINT="현재 스프린트:"
    I18N_STATUS_SPRINTS="스프린트:"
    I18N_STATUS_NO_SPRINTS="(스프린트 없음)"
    # cmd_config show
    I18N_CONFIG_TITLE="harn 설정"
    I18N_CONFIG_PROJECT="  프로젝트:           "
    I18N_CONFIG_LANGUAGE="  언어:               "
    I18N_CONFIG_BACKLOG_KEY="  백로그 파일:        "
    I18N_CONFIG_MAX_RETRIES_KEY="  최대 재시도:        "
    I18N_CONFIG_GIT_KEY="  Git 통합:           "
    I18N_CONFIG_BASE_BRANCH_KEY="  기본 작업 브랜치:   "
    I18N_CONFIG_PR_TARGET_KEY="  PR 타겟 브랜치:     "
    I18N_CONFIG_AUTO_PUSH_KEY="  자동 Push:          "
    I18N_CONFIG_AUTO_PR_KEY="  자동 PR:            "
    I18N_CONFIG_AI_MODELS="AI 모델"
    I18N_CONFIG_CUSTOM_PROMPTS_KEY="  커스텀 프롬프트:    "
    I18N_CONFIG_NO_FILE=".harn_config 파일이 없습니다. ${W}harn init${N}을 먼저 실행하세요."
    I18N_CONFIG_SET_FILE_NOT_FOUND=".harn_config 파일이 없습니다. ${W}harn init${N}을 먼저 실행하세요."
    I18N_CONFIG_NO_CLI="AI CLI를 찾을 수 없습니다. copilot 또는 claude를 설치하세요."
    I18N_CONFIG_NO_HINTS="설정에 HINT_* / GIT_GUIDE 값이 없습니다. 재생성할 내용이 없습니다."
    I18N_CONFIG_HINT_HOW="힌트 추가 방법: ${W}harn config set HINT_PLANNER \"내용\"${N}"
    I18N_CONFIG_REGEN_STEP="커스텀 프롬프트 재생성 중"
    I18N_CONFIG_REGEN_INFO="AI CLI(${W}%s${N})로 프롬프트 재생성 중..."
    I18N_CONFIG_REGEN_DONE="커스텀 프롬프트 재생성됨: ${W}%s${N}"
    I18N_CONFIG_UNKNOWN_SUB="알 수 없는 서브명령어:"
    I18N_CONFIG_USAGE="사용법: harn config [show|set KEY VALUE|regen]"
    # cmd_runs
    I18N_RUNS_TITLE="harn 실행 목록:"
    # cmd_resume
    I18N_RESUME_USAGE="사용법: harn resume <run-id>"
    I18N_RESUME_NOT_FOUND="실행을 찾을 수 없습니다:"
    I18N_RESUME_OK="재개됨:"
    # cmd_tail
    I18N_TAIL_FALLBACK="current.log 없음 — 최근 실행 로그로 대체:"
    I18N_TAIL_NO_LOG="활성 로그 없음. 먼저 실행하세요: harn auto"
    I18N_TAIL_TAILING="로그 실시간 출력:"
    # cmd_base
    I18N_BASE_NO_BRANCH="현재 브랜치를 확인할 수 없습니다"
    I18N_BASE_NO_CONFIG=".harn_config 파일이 없습니다. 실행: ${W}harn init${N}"
    I18N_BASE_SET_CURRENT="기본 브랜치 → ${W}current${N}  ${D}(현재 브랜치: %s)${N}"
    I18N_BASE_SET_CURRENT_HINT="harn이 런타임에 활성 브랜치를 기본으로 사용합니다"
    I18N_BASE_SET="기본 브랜치 설정됨 → ${W}%s${N}  ${D}(이전: %s)${N}"
    # _ask_user_instructions
    I18N_INSTRUCTIONS_TITLE="💬 추가 지시사항"
    I18N_INSTRUCTIONS_ENTER="%s에게 전달할 지시사항을 입력하세요."
    I18N_INSTRUCTIONS_HINT="빈 줄 = 건너뜀  ·  여러 줄 입력 가능"
    I18N_INSTRUCTIONS_PASSED="✓  다음 에이전트에게 전달됩니다."
  else
    I18N_LANG_NAME="English"
    I18N_INIT_LANG_PROMPT="Language"
    I18N_INIT_BACKLOG_PROMPT="Backlog file path (relative to project root)"
    I18N_INIT_BACKLOG_DEFAULT="sprint-backlog.md"
    I18N_INIT_MAX_QA_PROMPT="Max QA retry count"
    I18N_INIT_GIT_PROMPT="Enable Git integration"
    I18N_INIT_SAVED="Configuration saved"
    I18N_DOCTOR_TITLE="harn environment check"
    I18N_DOCTOR_OK="OK"
    I18N_DOCTOR_WARN="WARN"
    I18N_DOCTOR_FAIL="FAIL"
    I18N_CONFIG_SET_DONE="Config saved"
    I18N_CONFIG_SET_USAGE="Usage: harn config set <key> <value>"
    I18N_LANG_SELECT="Select language"
    # usage()
    I18N_USAGE_TITLE="Usage"
    I18N_USAGE_CMD="harn <command>"
    I18N_USAGE_SETUP="Setup"
    I18N_USAGE_BACKLOG="Backlog"
    I18N_USAGE_RUN="Run"
    I18N_USAGE_STEPS="Step by step"
    I18N_USAGE_MONITOR="Monitoring"
    I18N_USAGE_INIT="Initial setup (first run or reconfigure)"
    I18N_USAGE_CONFIG="Show current configuration"
    I18N_USAGE_CONFIG_SET="Update a specific setting"
    I18N_USAGE_CONFIG_REGEN="Regenerate custom prompts from HINT_* values"
    I18N_USAGE_BACKLOG_CMD="List pending items"
    I18N_USAGE_ADD="Add new backlog item (AI-assisted)"
    I18N_USAGE_DISCOVER="Analyze codebase and discover new items"
    I18N_USAGE_START="Select an item and run the full loop"
    I18N_USAGE_AUTO="Auto-detect: resume / start / discover"
    I18N_USAGE_ALL="Run all pending items sequentially (retro at end)"
    I18N_USAGE_PLAN="Re-run planner"
    I18N_USAGE_CONTRACT="Scope negotiation"
    I18N_USAGE_IMPLEMENT="Run generator"
    I18N_USAGE_EVALUATE="Run evaluator"
    I18N_USAGE_NEXT="Advance to next sprint"
    I18N_USAGE_STATUS="Current run status"
    I18N_USAGE_TAIL="Live log output"
    I18N_USAGE_RUNS="List all runs"
    I18N_USAGE_RESUME="Resume a previous run"
    I18N_USAGE_STOP="Stop the loop"
    I18N_USAGE_TIP="You can inject extra instructions between steps during a loop run."
    # doctor
    I18N_DOCTOR_VERSION="Version"
    I18N_DOCTOR_BACKENDS="AI Backends"
    I18N_DOCTOR_NOT_FOUND="not found"
    I18N_DOCTOR_INSTALL="Install"
    I18N_DOCTOR_ACTIVE_BACKEND="Active backend"
    I18N_DOCTOR_NO_BACKEND="No AI backend available — run: harn init"
    I18N_DOCTOR_GIT_SECTION="Git"
    I18N_DOCTOR_GH_AUTH_WARN="not authenticated — run: gh auth login"
    I18N_DOCTOR_GH_NOT_FOUND="not found — PR features disabled"
    I18N_DOCTOR_PROJECT_REPO="Project repo"
    I18N_DOCTOR_CONFIG_SECTION="harn Config"
    I18N_DOCTOR_CONFIG_FOUND="found"
    I18N_DOCTOR_CONFIG_NOT_FOUND="not configured  (run harn init to set up)"
    I18N_DOCTOR_GIT_INTEGRATION="Git integration"
    I18N_DOCTOR_BASE_BRANCH="Base branch"
    I18N_DOCTOR_PR_TARGET="PR target branch"
    I18N_DOCTOR_SPRINT_COUNT="Sprint count"
    I18N_DOCTOR_AI_BACKEND="AI backend"
    I18N_DOCTOR_CUSTOM_PROMPTS="Custom prompts"
    I18N_DOCTOR_MODELS="Models"
    I18N_DOCTOR_ACTIVE_RUN="Active Run"
    I18N_DOCTOR_SPRINT="Sprint"
    I18N_DOCTOR_NO_RUN="No active run"
    I18N_DOCTOR_DEPS="Other Dependencies"
    I18N_DOCTOR_OPTIONAL="optional"
    I18N_DOCTOR_ALL_OK="All critical checks passed."
    I18N_DOCTOR_FAIL_MSG="One or more critical checks failed. Run: harn init"
    # no-config warning
    I18N_NO_CONFIG_WARN="No .harn_config found in this directory."
    I18N_NO_CONFIG_SETUP="Starting initial setup..."
    # cmd_init
    I18N_INIT_TITLE="harn initial setup"
    I18N_INIT_OVERWRITE="Config file already exists. Overwrite? [y/N]: "
    I18N_INIT_CANCELLED="Initialization cancelled"
    I18N_INIT_AI_MODELS="AI model settings"
    I18N_INIT_AI_MODELS_HINT="Use ↑↓ arrows to navigate, Enter to select, Ctrl+Q to cancel init"
    I18N_INIT_SPRINT_STRUCTURE="Sprint structure"
    I18N_INIT_SPRINT_COUNT_PROMPT="Number of sprints [2]: "
    I18N_INIT_SPRINT_ROLES_HINT="Describe the goal/role of each sprint (Enter = use default label)"
    I18N_INIT_SPRINT_ROLE_PROMPT="  Sprint %s role: "
    I18N_INIT_SPRINT_INVALID="Invalid sprint count '%s' — defaulting to 2"
    I18N_INIT_GIT_SECTION="Git integration"
    I18N_INIT_GIT_ENABLE_PROMPT="Enable Git integration? [y/N]: "
    I18N_INIT_GIT_BASE_PROMPT="Base working branch (branch off from, or 'current' to always use active branch) [main]: "
    I18N_INIT_GIT_TARGET_PROMPT="PR target branch (where PRs are merged into) [%s]: "
    I18N_INIT_GIT_AUTOPUSH_PROMPT="Auto push? [y/N]: "
    I18N_INIT_GIT_AUTOPR_PROMPT="Auto PR creation? [y/N]: "
    I18N_INIT_GIT_DRAFT_PROMPT="Create PR as Draft? [Y/n]: "
    I18N_INIT_GIT_GUIDE_TITLE="Git workflow guidelines"
    I18N_INIT_GIT_GUIDE_HINT="Enter branching strategy, commit conventions, PR rules, etc.\n  These guidelines will be reflected in all agent prompts. (Enter = skip)"
    I18N_INIT_HINTS_TITLE="Per-agent special instructions"
    I18N_INIT_HINTS_HINT="Enter project architecture, tech stack, coding conventions, etc.\n  The AI CLI will naturally integrate these into the base prompts. (Enter = skip)"
    I18N_INIT_HINT_PLANNER="Planner   — spec/sprint planning instructions: "
    I18N_INIT_HINT_GENERATOR="Generator — implementation instructions: "
    I18N_INIT_HINT_EVALUATOR="Evaluator — QA/evaluation instructions: "
    I18N_INIT_CONFIG_SAVED="Config file created"
    I18N_INIT_GEN_PROMPTS="Generating custom prompts with AI CLI"
    I18N_INIT_COMPLETE="Initialization complete!"
    I18N_INIT_HINT_BACKLOG="  harn backlog  — view backlog items"
    I18N_INIT_HINT_START="  harn start    — start the loop"
    # AI CLI check / backend selection
    I18N_NO_AI_CLI="${R}✗ No AI CLI found.${N}"
    I18N_NO_AI_CLI_HINT="harn requires GitHub Copilot CLI, Claude CLI, OpenAI Codex CLI, or Gemini CLI."
    I18N_AI_BACKEND_TITLE="Default AI backend"
    I18N_AI_USING_COPILOT="${G}✓${N} Using ${W}copilot${N} (GitHub Copilot CLI detected)"
    I18N_AI_USING_CLAUDE="${G}✓${N} Using ${W}claude${N} (Anthropic Claude CLI detected)"
    I18N_AI_USING_CODEX="${G}✓${N} Using ${W}codex${N} (OpenAI Codex CLI detected)"
    I18N_AI_USING_GEMINI="${G}✓${N} Using ${W}gemini${N} (Google Gemini CLI detected)"
    # cmd_backlog
    I18N_BACKLOG_TITLE="Pending backlog items:"
    I18N_BACKLOG_EMPTY="(none — all done!)"
    I18N_BACKLOG_RUN="Run: ${W}harn start${N} — select a backlog item and run the full loop"
    # cmd_start
    I18N_START_SELECT_ITEM="Select backlog item"
    I18N_START_NO_PENDING="No pending items in backlog. Add an item first."
    I18N_START_DISCOVER_HINT="To discover items: harn discover"
    I18N_START_ENTER_NUM="Enter number (1–%s): "
    I18N_START_SELECTED="Selected:"
    I18N_START_INVALID="Invalid input:"
    I18N_START_RUN_CREATED="Run created:"
    I18N_START_VIEW_LOG="View live log: ${W}harn tail${N}  →"
    I18N_START_PLAN_FAILED="Failed at initial planning stage. Check the log and retry:"
    I18N_START_AUTO_LOOP="Starting automated run"
    I18N_START_LOOP_DETAIL="Initialization complete. Running sprint loop automatically (contract → implement → evaluate → next, up to %s sprints)."
    I18N_START_LOOP_INTERRUPTED="Automated sprint loop was interrupted. Check the failure point and resume with 'harn resume %s'."
    I18N_START_COMPLETE="harn start full automated run complete"
    I18N_START_MAX_SPRINT="Reached max sprint count (%s). Automated run ended. Run 'harn start' to continue."
    # cmd_plan
    I18N_PLAN_STEP="Planning phase"
    I18N_PLAN_TEXT_NOT_FOUND="plan.text not found — using slug/prompt as plan text"
    I18N_PLAN_MARKERS_NOT_FOUND="Section markers not found — saving full output as spec.md"
    I18N_PLAN_ITEM_IN_PROGRESS="Backlog: ${W}%s${N} → In Progress"
    I18N_PLAN_LINE_UPDATED="Backlog plan line updated:"
    I18N_PLAN_LINE_FAILED="Backlog plan update failed: slug not found"
    I18N_PLAN_LINE_UNCHANGED="Backlog plan line unchanged (already up to date)"
    I18N_PLAN_LINE_EXCEPTION="Exception during backlog plan update"
    I18N_PLAN_COMPLETE="Planning complete"
    # cmd_contract
    I18N_CONTRACT_EXISTS="Scope already exists. Delete %s to recreate it."
    I18N_CONTRACT_STEP="Sprint %s — scope negotiation"
    I18N_CONTRACT_REVIEWING="Evaluator reviewing scope..."
    I18N_CONTRACT_APPROVED="Sprint %s scope approved"
    I18N_CONTRACT_NEEDS_REVISION="Scope needs revision — revising..."
    I18N_CONTRACT_REVISED="Sprint %s scope revision complete"
    I18N_CONTRACT_NEXT="Next step: harn implement"
    # cmd_implement
    I18N_IMPL_NO_SCOPE="No scope for sprint %s. Run: harn contract"
    I18N_IMPL_STEP="Sprint %s — development (iteration %s)"
    I18N_IMPL_COMPLETE="Sprint %s implementation complete (iteration %s)"
    I18N_IMPL_NEXT="Next step: harn evaluate"
    # cmd_evaluate
    I18N_EVAL_NO_IMPL="No implementation for sprint %s. Run: harn implement"
    I18N_EVAL_STEP="Sprint %s — evaluation (iteration %s)"
    I18N_EVAL_RUNNING_CHECKS="Running automated checks..."
    I18N_EVAL_CHECKS_DONE="Checks complete →"
    I18N_EVAL_SHUTTING_DOWN="Shutting down E2E environment..."
    I18N_EVAL_EXEC_ERROR="Sprint %s: evaluator execution error (exit %s) — stopping loop"
    I18N_EVAL_MANUAL_RESUME="Manual resume: fix the issue then run harn evaluate  or  harn implement"
    I18N_EVAL_PASS="Sprint %s: ${G}PASS${N}"
    I18N_EVAL_NEXT="Next step: harn next"
    I18N_EVAL_FAIL="Sprint %s: QA ${Y}FAIL${N} (iteration %s / %s) — retrying automatically... (report: %s)"
    # cmd_next
    I18N_NEXT_STEP="Finishing up"
    I18N_NEXT_DONE="Backlog: ${W}%s${N} → Done"
    I18N_NEXT_COMPLETE="${G}Task fully complete: %s${N}"
    # _sprint_advance
    I18N_SPRINT_SWITCH="Switching to sprint %s"
    # cmd_stop
    I18N_STOP_NO_PID="No running harness found (PID file missing)"
    I18N_STOP_ALREADY_HINT="Already stopped or was not started with harn start."
    I18N_STOP_STALE_PID="Process PID=%s already stopped — cleaning up PID file"
    I18N_STOP_STOPPING="Stopping harness... (PID: ${W}%s${N})"
    I18N_STOP_SIGKILL="Still running after SIGTERM — sending SIGKILL"
    I18N_STOP_RUN_STOPPED="Run stopped"
    I18N_STOP_DONE="Harness stopped"
    # git helpers
    I18N_GIT_NO_HEAD="Git: Cannot determine HEAD — skipping"
    I18N_GIT_CURRENT_BRANCH="Git: Working on current branch ${W}%s${N} (base=current mode)"
    I18N_GIT_CREATING_BRANCH="Git: Creating planning branch"
    I18N_GIT_NO_HEAD_BRANCH="Git: Cannot determine HEAD — skipping branch creation"
    I18N_GIT_BRANCH_EXISTS="Branch ${W}%s${N} already exists — checking out"
    I18N_GIT_BRANCH_CREATED="Branch created: ${W}%s${N}"
    I18N_GIT_BACKLOG_COMMITTED="Sprint backlog committed"
    I18N_GIT_BACKLOG_UNCHANGED="Backlog file unchanged — skipping commit"
    I18N_GIT_PUSH_FAILED_PR="Push failed — skipping Draft PR creation. Push manually and create a PR."
    I18N_GIT_BRANCH_PUSHED="Branch pushed: origin/${W}%s${N}"
    I18N_GIT_PR_CREATING="Creating Draft PR... (base: ${W}%s${N}, head: ${W}%s${N})"
    I18N_GIT_PR_CREATED="Draft PR created:"
    I18N_GIT_PR_FAILED="PR creation failed — create it manually"
    I18N_GIT_PR_CREATE_FAILED="gh pr create failed — create PR manually (%s → %s)"
    I18N_GIT_IMPL_COMMIT="Git: Sprint %s implementation commit"
    I18N_GIT_NO_CHANGES="No changes to commit — generator may not have modified any files"
    I18N_GIT_COMMIT_DONE="Commit done: ${W}%s${N}"
    I18N_GIT_PUSH_DONE="Push done: origin/${W}%s${N}"
    I18N_GIT_PUSH_FAILED="Push failed — run: git push origin %s"
    I18N_GIT_NO_HEAD_PUSH="Git: Cannot determine HEAD — skipping push"
    I18N_GIT_SPRINT_PASS_PUSH="Git: Sprint %s passed — pushing to origin/${W}%s${N}"
    I18N_GIT_NO_FEAT_BRANCH="Git: Cannot identify feature branch to merge (current: %s)"
    I18N_GIT_FINALIZE="Git finalize: ${W}%s${N} → ${W}%s${N}"
    I18N_GIT_AUTO_COMMIT="Auto-committing uncommitted changes..."
    I18N_GIT_UPDATE_PR="Updating PR: pushing origin/${W}%s${N}..."
    I18N_GIT_PUSH_FAILED_MANUAL="Push failed — merge the PR manually"
    I18N_GIT_PR_MERGING="Merging PR (not squash): ${W}%s${N}"
    I18N_GIT_PR_MERGED="PR merge complete: ${W}%s${N} → ${W}%s${N}"
    I18N_GIT_PR_MERGE_FAILED="gh pr merge failed — merge the PR on GitHub manually and then continue"
    I18N_GIT_RETURN_BASE="Returning to base branch: ${W}%s${N}"
    I18N_GIT_PULLING="Pulling origin/${W}%s${N}..."
    I18N_GIT_PULL_DONE="Pull complete: origin/${W}%s${N}"
    I18N_GIT_PULL_FAILED="Pull failed — run: git pull origin %s"
    # cmd_retrospective
    I18N_RETRO_NO_CLI="No AI CLI — skipping retrospective"
    I18N_RETRO_STEP="Retrospective"
    I18N_RETRO_ANALYZING="AI(${W}%s${N}) analyzing retrospective..."
    I18N_RETRO_FAILED="Retrospective generation failed — skipping"
    I18N_RETRO_SUMMARY_TITLE="  Retrospective Summary"
    I18N_RETRO_PROMPT_ADD="  Add this suggestion to the ${W}%s${N} prompt? [y/N]: "
    I18N_RETRO_ADDED="Added to %s prompt: ${W}%s${N}"
    I18N_RETRO_SKIPPED="%s suggestion skipped"
    I18N_RETRO_APPLIED="Prompt improvements applied."
    I18N_RETRO_COMPLETE="Retrospective complete — results: ${W}%s${N}"
    # _run_sprint_loop
    I18N_LOOP_STARTED="Loop started (up to %s sprints)"
    I18N_LOOP_INTERRUPTED="Harness interrupted by user."
    I18N_LOOP_TERMINATED="Harness received termination signal."
    I18N_LOOP_SPRINT_PASSED="Sprint %s already passed — moving to next"
    I18N_LOOP_SPRINT_MAX_ITER="Sprint %s already reached max iterations (%s) — forcing advance"
    I18N_LOOP_EVAL_ERROR="Evaluator process error — stopping loop. Fix the issue and run harn evaluate."
    I18N_LOOP_MAX_ITER_ADVANCE="Sprint %s: max iterations (%s) reached — forcing advance without QA pass"
    I18N_LOOP_ALL_COMPLETE="${G}All %s sprints complete!${N}"
    I18N_LOOP_SPRINT_DONE="Sprint %s done — switching to sprint %s"
    # cmd_discover
    I18N_DISCOVER_STEP="Backlog discovery — codebase analysis"
    I18N_DISCOVER_NO_ITEMS="Could not extract new items — check %s."
    I18N_DISCOVER_BACKLOG_CREATED="Backlog file created:"
    I18N_DISCOVER_ADDED="New items added to backlog"
    I18N_DISCOVER_HINT="Check: harn backlog   /   Start now: harn auto"
    # cmd_add
    I18N_ADD_STEP="Adding backlog item"
    I18N_ADD_BACKLOG_CREATED="Backlog file created:"
    I18N_ADD_BOX_TITLE="✚ New backlog item"
    I18N_ADD_BOX_DESC="Describe the feature or task you want to implement."
    I18N_ADD_BOX_AI="AI will generate a slug and description and add it to the backlog."
    I18N_ADD_BOX_HINT="Multi-line input supported  ·  Empty line to finish"
    I18N_ADD_CANCELLED="No input — cancelled"
    I18N_ADD_NO_CLI="AI CLI not found. Install copilot or claude."
    I18N_ADD_GENERATING="AI(${W}%s${N}) generating backlog items..."
    I18N_ADD_FAILED="AI generation failed"
    I18N_ADD_NO_ITEMS="Could not extract items — check %s."
    I18N_ADD_DONE="Added to backlog:"
    I18N_ADD_HINT="Check: ${W}harn backlog${N}   /   Start now: ${W}harn start${N}"
    # cmd_auto
    I18N_AUTO_STEP="Auto mode"
    I18N_AUTO_RESUMING="Resuming in-progress run: ${W}%s${N}  (sprint %s · %s)"
    I18N_AUTO_CANCELLED="Last run was cancelled — looking for next item"
    I18N_AUTO_COMPLETED="Last run completed (${W}%s${N}) — looking for next item"
    I18N_AUTO_STARTING="Starting next backlog item: ${W}%s${N}"
    I18N_AUTO_EMPTY="Backlog is empty."
    I18N_AUTO_FIRST_DISCOVERED="Starting first discovered item: ${W}%s${N}"
    # cmd_all
    I18N_ALL_NO_BACKLOG="Backlog file not found:"
    I18N_ALL_NO_PENDING="No pending items in backlog."
    I18N_ALL_HINT="To add items: ${W}harn discover${N}  or  ${W}harn add${N}"
    I18N_ALL_STEP="Full automated run —"
    I18N_ALL_STARTING="[%s/%s] Starting item: ${W}%s${N}"
    I18N_ALL_COMPLETE_ITEM="[%s/%s] Complete: ${W}%s${N}"
    I18N_ALL_FAILED_ITEM="[%s/%s] Failed: ${W}%s${N} — continuing with next item"
    I18N_ALL_FAILED_ITEMS="Failed items:"
    I18N_ALL_RETRY_HINT="Re-run failed items manually: ${W}harn start <slug>${N}"
    I18N_ALL_RETRO_STEP="Running retrospective (%s item(s))"
    I18N_ALL_RETRO_ITEM="Retrospective: ${W}%s${N}"
    # cmd_status
    I18N_STATUS_NO_RUN="No active run. Start with: ${W}harn start${N}"
    I18N_STATUS_RUN_ID="Run ID:"
    I18N_STATUS_ITEM="Item:"
    I18N_STATUS_SPRINT="Current sprint:"
    I18N_STATUS_SPRINTS="Sprints:"
    I18N_STATUS_NO_SPRINTS="(no sprints)"
    # cmd_config show
    I18N_CONFIG_TITLE="harn Configuration"
    I18N_CONFIG_PROJECT="  Project:           "
    I18N_CONFIG_LANGUAGE="  Language:          "
    I18N_CONFIG_BACKLOG_KEY="  Backlog file:      "
    I18N_CONFIG_MAX_RETRIES_KEY="  Max retries:       "
    I18N_CONFIG_GIT_KEY="  Git integration:   "
    I18N_CONFIG_BASE_BRANCH_KEY="  Base working branch: "
    I18N_CONFIG_PR_TARGET_KEY="  PR target branch:  "
    I18N_CONFIG_AUTO_PUSH_KEY="  Auto push:         "
    I18N_CONFIG_AUTO_PR_KEY="  Auto PR:           "
    I18N_CONFIG_AI_MODELS="AI Models"
    I18N_CONFIG_CUSTOM_PROMPTS_KEY="  Custom prompts:    "
    I18N_CONFIG_NO_FILE="No .harn_config file. Run ${W}harn init${N} first."
    I18N_CONFIG_SET_FILE_NOT_FOUND=".harn_config file not found. Run ${W}harn init${N} first."
    I18N_CONFIG_NO_CLI="No AI CLI found. Install copilot or claude."
    I18N_CONFIG_NO_HINTS="No HINT_* / GIT_GUIDE values in config. Nothing to regenerate."
    I18N_CONFIG_HINT_HOW="To add hints: ${W}harn config set HINT_PLANNER \"hint content\"${N}"
    I18N_CONFIG_REGEN_STEP="Regenerating custom prompts"
    I18N_CONFIG_REGEN_INFO="Regenerating prompts with AI CLI (${W}%s${N})..."
    I18N_CONFIG_REGEN_DONE="Custom prompts regenerated: ${W}%s${N}"
    I18N_CONFIG_UNKNOWN_SUB="Unknown config subcommand:"
    I18N_CONFIG_USAGE="Usage: harn config [show|set KEY VALUE|regen]"
    # cmd_runs
    I18N_RUNS_TITLE="Harness runs:"
    # cmd_resume
    I18N_RESUME_USAGE="Usage: harn resume <run-id>"
    I18N_RESUME_NOT_FOUND="Run not found:"
    I18N_RESUME_OK="Resumed:"
    # cmd_tail
    I18N_TAIL_FALLBACK="No current.log — falling back to latest run log:"
    I18N_TAIL_NO_LOG="No active log. Start a run first: harn auto"
    I18N_TAIL_TAILING="Tailing log:"
    # cmd_base
    I18N_BASE_NO_BRANCH="Cannot determine current branch"
    I18N_BASE_NO_CONFIG="No .harn_config found. Run: ${W}harn init${N}"
    I18N_BASE_SET_CURRENT="Base branch → ${W}current${N}  ${D}(resolves to: %s)${N}"
    I18N_BASE_SET_CURRENT_HINT="harn will work on whichever branch is active at runtime"
    I18N_BASE_SET="Base branch → ${W}%s${N}  ${D}(was: %s)${N}"
    # _ask_user_instructions
    I18N_INSTRUCTIONS_TITLE="💬 Additional instructions"
    I18N_INSTRUCTIONS_ENTER="Enter instructions to pass to %s."
    I18N_INSTRUCTIONS_HINT="Empty line = skip  ·  Multi-line input supported"
    I18N_INSTRUCTIONS_PASSED="✓  Will be passed to the next agent."
  fi
}

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

  # Re-detect language after config is sourced (LANG_OVERRIDE now available)
  _detect_lang
  _i18n_load
  # Set lang-aware PROMPTS_DIR (builtin: $SCRIPT_DIR/prompts/$HARN_LANG, fallback to en)
  local lang_dir="$SCRIPT_DIR/prompts/$HARN_LANG"
  if [[ -d "$lang_dir" ]]; then
    PROMPTS_DIR="$lang_dir"
  else
    PROMPTS_DIR="$SCRIPT_DIR/prompts/en"
  fi

  # Apply custom prompts directory (overrides lang-aware dir)
  if [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]]; then
    local custom_abs="$CUSTOM_PROMPTS_DIR"
    [[ "${CUSTOM_PROMPTS_DIR}" != /* ]] && custom_abs="$ROOT_DIR/$CUSTOM_PROMPTS_DIR"
    if [[ -d "$custom_abs/$HARN_LANG" ]]; then
      PROMPTS_DIR="$custom_abs/$HARN_LANG"
    elif [[ -d "$custom_abs" ]]; then
      PROMPTS_DIR="$custom_abs"
    fi
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
  # Auto-detect in preference order
  if command -v copilot &>/dev/null; then echo "copilot"
  elif command -v claude  &>/dev/null; then echo "claude"
  elif command -v codex   &>/dev/null; then echo "codex"
  elif command -v gemini  &>/dev/null; then echo "gemini"
  else echo ""
  fi
}

# Check which AI CLIs are installed; print a guidance message if none
_check_ai_cli_installed() {
  local has_copilot=false has_claude=false has_codex=false has_gemini=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  command -v codex   &>/dev/null && has_codex=true
  command -v gemini  &>/dev/null && has_gemini=true

  if [[ "$has_copilot" == "false" && "$has_claude" == "false" && "$has_codex" == "false" && "$has_gemini" == "false" ]]; then
    echo -e "\n${I18N_NO_AI_CLI}"
    echo -e "  ${I18N_NO_AI_CLI_HINT}\n"
    return 1
  fi
  return 0
}

# Interactive AI backend selection; sets AI_BACKEND variable
_select_ai_backend() {
  local has_copilot=false has_claude=false has_codex=false has_gemini=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  command -v codex   &>/dev/null && has_codex=true
  command -v gemini  &>/dev/null && has_gemini=true

  # Build menu from installed CLIs
  local available=()
  [[ "$has_copilot" == "true" ]] && available+=("copilot  (GitHub Copilot CLI)")
  [[ "$has_claude"  == "true" ]] && available+=("claude   (Anthropic Claude CLI)")
  [[ "$has_codex"   == "true" ]] && available+=("codex    (OpenAI Codex CLI)")
  [[ "$has_gemini"  == "true" ]] && available+=("gemini   (Google Gemini CLI)")

  if [[ ${#available[@]} -eq 0 ]]; then
    return 1
  elif [[ ${#available[@]} -eq 1 ]]; then
    # Only one available — auto-select and show message
    local only="${available[0]%%\ *}"
    AI_BACKEND="$only"
    case "$only" in
      copilot) echo -e "\n${I18N_AI_USING_COPILOT}" ;;
      claude)  echo -e "\n${I18N_AI_USING_CLAUDE}"  ;;
      codex)   echo -e "\n${I18N_AI_USING_CODEX}"   ;;
      gemini)  echo -e "\n${I18N_AI_USING_GEMINI}"  ;;
    esac
  else
    local choice
    choice=$(_pick_menu "$I18N_AI_BACKEND_TITLE" 0 "${available[@]}") || return 1
    AI_BACKEND="${choice%%\ *}"
  fi
}

_get_models_for_backend() {
  local backend="$1"
  case "$backend" in
    claude)
      printf '%s\n' \
        "claude-haiku-4.5" "claude-sonnet-4.5" "claude-sonnet-4.6" \
        "claude-opus-4.5"  "claude-opus-4.6"
      ;;
    codex)
      printf '%s\n' \
        "codex-mini-latest" "o4-mini" "o3" "o3-mini" "gpt-4.1" "gpt-4o"
      ;;
    gemini)
      printf '%s\n' \
        "gemini-2.5-pro" "gemini-2.5-flash" "gemini-2.0-flash" \
        "gemini-1.5-pro" "gemini-1.5-flash"
      ;;
    copilot|*)  # copilot supports both claude and GPT models
      printf '%s\n' \
        "claude-haiku-4.5" "claude-sonnet-4.5" "claude-sonnet-4.6" \
        "claude-opus-4.5"  "claude-opus-4.6" \
        "gpt-4.1" "gpt-4o" "gpt-4o-mini" "o1" "o3-mini"
      ;;
  esac
}

# Select AI backend + model for a role interactively.
# Prints "backend model" on success, exits 1 on cancel.
_pick_role_model() {
  local role_label="$1" default_backend="${2:-copilot}" default_model="$3"

  local has_copilot=false has_claude=false has_codex=false has_gemini=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  command -v codex   &>/dev/null && has_codex=true
  command -v gemini  &>/dev/null && has_gemini=true
  [[ "$has_copilot" == "false" && "$has_claude" == "false" && "$has_codex" == "false" && "$has_gemini" == "false" ]] && {
    log_err "No AI CLI found. Run: harn init"; return 1
  }

  # Build flat combined list: "backend / model"
  local options=()
  [[ "$has_copilot" == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("copilot / $m"); done < <(_get_models_for_backend "copilot")
  [[ "$has_claude"  == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("claude / $m");  done < <(_get_models_for_backend "claude")
  [[ "$has_codex"   == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("codex / $m");   done < <(_get_models_for_backend "codex")
  [[ "$has_gemini"  == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("gemini / $m");  done < <(_get_models_for_backend "gemini")

  # Find default index
  local def_i=0
  local default_str="${default_backend} / ${default_model}"
  for i in "${!options[@]}"; do
    [[ "${options[$i]}" == "$default_str" ]] && { def_i=$i; break; }
  done

  local selected
  # Pass empty prompt — title already printed by caller with description
  selected=$(_pick_menu "" "$def_i" "${options[@]}") || return 1

  # Parse "backend / model" → "backend model"
  local backend="${selected%% /*}"
  local model="${selected##*/ }"
  printf "%s %s" "$backend" "$model"
}

# Generate a single prompt using the AI CLI
_ai_generate() {
  local ai_cmd="$1" prompt_text="$2" out_file="$3"
  local err_file; err_file=$(mktemp)
  local rc=0
  case "$ai_cmd" in
    copilot) copilot --yolo -p "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
    claude)  claude -p "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
    codex)   codex -q "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
    gemini)  gemini -p "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
  esac
  if [[ $rc -ne 0 ]]; then
    local err_msg; err_msg=$(cat "$err_file" 2>/dev/null | head -5)
    rm -f "$err_file"
    [[ -n "$err_msg" ]] && log_warn "  ${D}${err_msg}${N}"
    return $rc
  fi
  rm -f "$err_file"
  return 0
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
  # ── Language selection (first!) ────────────────────────────────────────────
  echo -e "\n${W}Language / 언어${N}"
  local _lang_choice
  _lang_choice=$(python3 - "" \
    "en:English" \
    "ko:한국어" \
    "" "" "" \
    <<'PYEOF'
import sys, os, tty, termios

options  = [a for a in sys.argv[2:] if a]  # filter empty sentinel args
labels   = [o.split(":",1)[1] for o in options]
values   = [o.split(":",1)[0] for o in options]
selected = 0
n = len(labels)

fd = open("/dev/tty", "rb+", buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)

def render():
    out = b""
    for i, lb in enumerate(labels):
        lb_enc = lb.encode()
        if i == selected:
            out += b"  \033[1;32m\xe2\x9d\xaf " + lb_enc + b"\033[0m\r\n"
        else:
            out += b"    \033[2m" + lb_enc + b"\033[0m\r\n"
    return out

try:
    fd.write(render())
    fd.write(f"\033[{n}A".encode())
    fd.flush()
    while True:
        fd.write(render())
        fd.write(f"\033[{n}A".encode())
        fd.flush()
        b = fd.read(1)
        if not b:
            break
        byte = b[0]
        if byte in (13, 10):  # Enter
            break
        elif byte == 3:  # Ctrl+C
            fd.write(f"\033[{n}B\r\n".encode())
            fd.flush()
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            fd.close()
            sys.exit(1)
        elif byte == 27:
            b2 = fd.read(1)
            if b2 == b"[":
                b3 = fd.read(1)
                if b3 == b"A":
                    selected = (selected - 1) % n
                elif b3 == b"B":
                    selected = (selected + 1) % n
finally:
    fd.write(f"\033[{n}B\r\n".encode())
    fd.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    fd.close()

print(values[selected])
PYEOF
  ) || { echo ""; return 0; }
  local selected_lang="${_lang_choice}"
  HARN_LANG="$selected_lang"
  _i18n_load
  # Update PROMPTS_DIR to match selected lang
  local _ldir="$SCRIPT_DIR/prompts/$HARN_LANG"
  [[ -d "$_ldir" ]] && PROMPTS_DIR="$_ldir" || PROMPTS_DIR="$SCRIPT_DIR/prompts/en"
  echo ""

  # ── Header (now in selected language) ─────────────────────────────────────
  echo -e "${W}══════════════════════════════════════════${N}"
  echo -e "${W}  ${I18N_INIT_TITLE}${N}"
  echo -e "${W}══════════════════════════════════════════${N}"
  echo -e "Project root: ${W}$ROOT_DIR${N}"
  echo -e "Config file:  ${W}$CONFIG_FILE${N}\n"

  if [[ -f "$CONFIG_FILE" ]]; then
    printf "${Y}${I18N_INIT_OVERWRITE}${N}"
    local ow; ow=$(_input_readline)
    echo ""
    [[ "$ow" == "y" || "$ow" == "Y" ]] || { log_info "$I18N_INIT_CANCELLED"; return 0; }
  fi

  # ── Project basic settings ───────────────────────────────────────────────────
  local bf_default="$I18N_INIT_BACKLOG_DEFAULT"
  printf "%s [%s]: " "$I18N_INIT_BACKLOG_PROMPT" "$bf_default"
  local bf_input; bf_input=$(_input_readline); echo ""
  local bf="${bf_input:-$bf_default}"

  printf "%s [5]: " "$I18N_INIT_MAX_QA_PROMPT"
  local mi_input; mi_input=$(_input_readline); echo ""
  local mi="${mi_input:-5}"

  # ── AI CLI detection ──────────────────────────────────────────────────────────
  _check_ai_cli_installed || return 1
  _select_ai_backend

  # ── AI model settings (per role) ──────────────────────────────────────────────
  echo -e "\n${W}${I18N_INIT_AI_MODELS}${N} — ${I18N_INIT_AI_MODELS_HINT}"
  echo -e "  ${D}${I18N_INIT_AI_MODELS_HINT}${N}\n"

  local mp mp_backend _tmp_p
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "  ${W}Planner${N}  ${D}— 백로그 항목을 읽고 스펙과 스프린트 계획을 작성하는 역할${N}"
  else
    echo -e "  ${W}Planner${N}  ${D}— reads backlog item, writes product spec & sprint breakdown${N}"
  fi
  _tmp_p=$(_pick_role_model "Planner" "${AI_BACKEND:-copilot}" "claude-haiku-4.5") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mp_backend mp <<< "$_tmp_p"

  local mgc mgc_backend _tmp_gc
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Generator (contract)${N}  ${D}— 스프린트 스코프를 제안하고 코딩 전 Evaluator와 협상하는 역할${N}"
  else
    echo -e "\n  ${W}Generator (contract)${N}  ${D}— proposes sprint scope; negotiates with Evaluator before coding starts${N}"
  fi
  _tmp_gc=$(_pick_role_model "Generator (contract)" "${AI_BACKEND:-copilot}" "claude-sonnet-4.6") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mgc_backend mgc <<< "$_tmp_gc"

  local mgi mgi_backend _tmp_gi
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Generator (impl)${N}  ${D}— 실제 코드를 작성하는 역할; 가장 중요한 역할이므로 최고 성능 모델 추천${N}"
  else
    echo -e "\n  ${W}Generator (impl)${N}  ${D}— writes the actual code; most important role, use the strongest model${N}"
  fi
  _tmp_gi=$(_pick_role_model "Generator (impl)" "${AI_BACKEND:-copilot}" "claude-opus-4.6") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mgi_backend mgi <<< "$_tmp_gi"

  local mec mec_backend _tmp_ec
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Evaluator (contract)${N}  ${D}— 스프린트 스코프 제안을 검토하고 승인 또는 수정을 요청하는 역할${N}"
  else
    echo -e "\n  ${W}Evaluator (contract)${N}  ${D}— reviews sprint scope proposal, approves or requests revision${N}"
  fi
  _tmp_ec=$(_pick_role_model "Evaluator (contract)" "${AI_BACKEND:-copilot}" "claude-haiku-4.5") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mec_backend mec <<< "$_tmp_ec"

  local meq meq_backend _tmp_eq
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Evaluator (QA)${N}  ${D}— 구현을 검토하고 테스트를 실행하여 PASS 또는 FAIL 판정을 내리는 역할${N}"
  else
    echo -e "\n  ${W}Evaluator (QA)${N}  ${D}— reviews implementation, runs tests, issues PASS or FAIL verdict${N}"
  fi
  _tmp_eq=$(_pick_role_model "Evaluator (QA)" "${AI_BACKEND:-copilot}" "claude-sonnet-4.5") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r meq_backend meq <<< "$_tmp_eq"

  # ── Sprint structure ──────────────────────────────────────────────────────────
  echo -e "\n${W}${I18N_INIT_SPRINT_STRUCTURE}${N}"
  printf "%s" "$I18N_INIT_SPRINT_COUNT_PROMPT"
  local sc_input; sc_input=$(_input_readline); echo ""
  local sc="${sc_input:-2}"

  # Validate: must be a positive integer
  if ! [[ "$sc" =~ ^[1-9][0-9]*$ ]]; then
    # shellcheck disable=SC2059
    log_warn "$(printf "$I18N_INIT_SPRINT_INVALID" "$sc")"
    sc=2
  fi

  # If not default 2, ask what each sprint should do
  local sprint_roles_arr=()
  if [[ "$sc" -ne 2 ]]; then
    echo -e "  ${D}${I18N_INIT_SPRINT_ROLES_HINT}${N}"
    for ((i=1; i<=sc; i++)); do
      local padded; padded=$(printf "%03d" "$i")
      printf "$I18N_INIT_SPRINT_ROLE_PROMPT" "$padded"
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
  echo -e "\n${W}${I18N_INIT_GIT_SECTION}${N}"
  printf "%s" "$I18N_INIT_GIT_ENABLE_PROMPT"
  local git_yn; git_yn=$(_input_readline); echo ""
  local git_en="false"
  local git_branch="main" git_pr_target="main" git_auto_push="false" git_auto_pr="false" git_pr_draft="true" git_guide=""

  if [[ "$git_yn" == "y" || "$git_yn" == "Y" ]]; then
    git_en="true"
    printf "%s" "$I18N_INIT_GIT_BASE_PROMPT"
    local gb; gb=$(_input_readline); echo ""; git_branch="${gb:-main}"

    printf "$I18N_INIT_GIT_TARGET_PROMPT" "$git_branch"
    local gpt; gpt=$(_input_readline); echo ""; git_pr_target="${gpt:-$git_branch}"

    printf "%s" "$I18N_INIT_GIT_AUTOPUSH_PROMPT"
    local gp; gp=$(_input_readline); echo ""
    [[ "$gp" == "y" || "$gp" == "Y" ]] && git_auto_push="true"

    printf "%s" "$I18N_INIT_GIT_AUTOPR_PROMPT"
    local gpr; gpr=$(_input_readline); echo ""
    [[ "$gpr" == "y" || "$gpr" == "Y" ]] && git_auto_pr="true"

    if [[ "$git_auto_pr" == "true" ]]; then
      printf "%s" "$I18N_INIT_GIT_DRAFT_PROMPT"
      local gprd; gprd=$(_input_readline); echo ""
      [[ "$gprd" == "n" || "$gprd" == "N" ]] && git_pr_draft="false"
    fi

    echo -e "\n${B}${I18N_INIT_GIT_GUIDE_TITLE}${N}"
    echo -e "  ${I18N_INIT_GIT_GUIDE_HINT}"
    printf "> "
    git_guide=$(_input_readline); echo ""
  fi

  # ── Per-agent special instructions ──────────────────────────────────────────
  echo -e "\n${W}${I18N_INIT_HINTS_TITLE}${N}"
  echo -e "  ${I18N_INIT_HINTS_HINT}\n"

  printf "%s" "$I18N_INIT_HINT_PLANNER"
  local hint_planner; hint_planner=$(_input_readline); echo ""

  printf "%s" "$I18N_INIT_HINT_GENERATOR"
  local hint_generator; hint_generator=$(_input_readline); echo ""

  printf "%s" "$I18N_INIT_HINT_EVALUATOR"
  local hint_evaluator; hint_evaluator=$(_input_readline); echo ""

  # ── Write config file ───────────────────────────────────────────────────────
  local cpd=""
  cat > "$CONFIG_FILE" <<CFGEOF
# harn config file — $(date '+%Y-%m-%d %H:%M:%S')
# project: $ROOT_DIR

# === Project settings ===
LANG_OVERRIDE="${selected_lang}"
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

  log_ok "${I18N_INIT_CONFIG_SAVED}: ${W}$CONFIG_FILE${N}"

  # ── Custom prompt generation ──────────────────────────────────────────────────
  if [[ -n "$hint_planner" || -n "$hint_generator" || -n "$hint_evaluator" || -n "$git_guide" ]]; then
    echo ""
    local ai_cmd; ai_cmd=$(_detect_ai_cli)
    if [[ -n "$ai_cmd" ]]; then
      log_info "${I18N_INIT_GEN_PROMPTS}(${W}${ai_cmd}${N})..."
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
  log_ok "$I18N_INIT_COMPLETE"
  echo -e "$I18N_INIT_HINT_BACKLOG"
  echo -e "$I18N_INIT_HINT_START"
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

  # Determine guidance type for this role
  local guidance_type
  case "$role_detail" in
    planner*)            guidance_type="plan"      ;;
    generator_contract)  guidance_type="implement"  ;;
    generator_impl)      guidance_type="implement"  ;;
    evaluator*)          guidance_type="evaluate"   ;;
    *)                   guidance_type="implement"  ;;
  esac

  # Inject any pending guidance into the prompt
  if _has_guidance "$guidance_type"; then
    local guidance_block; guidance_block=$(_inject_guidance "$guidance_type")
    if [[ -n "$guidance_block" ]]; then
      if [[ "$prompt_mode" == "file" ]]; then
        local tmp_guided; tmp_guided=$(mktemp)
        printf '%s\n\n' "$guidance_block" > "$tmp_guided"
        cat "$prompt_input" >> "$tmp_guided"
        prompt_input="$tmp_guided"
        prompt_mode="file"
      else
        prompt_input="${guidance_block}"$'\n\n'"${prompt_input}"
      fi
      log_info "💬 사용자 지시사항 포함됨"
    fi
  fi

  # Determine backend for this specific role (needed before log_agent_start)
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

  # Log agent start BEFORE launching the guidance listener.
  # This avoids a race condition where log_agent_start() pushes the terminal
  # cursor into the bottom rows before the scroll region is established,
  # causing subsequent agent output to overwrite the input bar.
  local _role_label
  case "$backend" in
    claude)  _role_label="claude";  [[ -n "$model" ]] && _role_label="claude ($model)"  ;;
    codex)   _role_label="codex";   [[ -n "$model" ]] && _role_label="codex ($model)"   ;;
    gemini)  _role_label="gemini";  [[ -n "$model" ]] && _role_label="gemini ($model)"  ;;
    copilot|*) _role_label="copilot"; [[ -n "$model" ]] && _role_label="copilot ($model)" ;;
  esac
  log_agent_start "$_role_label" "$role_label" "output → $(basename "$output_file")"

  local exit_code=0
  case "$backend" in
    claude)
      local prompt_text="$prompt_input"
      [[ "$prompt_mode" == "file" ]] && prompt_text="$(cat "$prompt_input")"
      local -a claude_cmd=(claude -p "$prompt_text")
      [[ -n "$model" ]] && claude_cmd+=(--model "$model")
      "${claude_cmd[@]}" 2>&1 \
        | tee "$output_file" \
        | tee -a "$LOG_FILE" \
        | _md_stream || exit_code=${PIPESTATUS[0]}
      [[ $exit_code -ne 0 ]] && log_warn "claude exited abnormally (exit $exit_code)"
      log_agent_done "$_role_label"
      ;;
    codex)
      local prompt_text="$prompt_input"
      [[ "$prompt_mode" == "file" ]] && prompt_text="$(cat "$prompt_input")"
      local -a codex_cmd=(codex -q "$prompt_text")
      [[ -n "$model" ]] && codex_cmd+=(--model "$model")
      "${codex_cmd[@]}" 2>&1 \
        | tee "$output_file" \
        | tee -a "$LOG_FILE" \
        | _md_stream || exit_code=${PIPESTATUS[0]}
      [[ $exit_code -ne 0 ]] && log_warn "codex exited abnormally (exit $exit_code)"
      log_agent_done "$_role_label"
      ;;
    gemini)
      local prompt_text="$prompt_input"
      [[ "$prompt_mode" == "file" ]] && prompt_text="$(cat "$prompt_input")"
      local -a gemini_cmd=(gemini -p "$prompt_text")
      [[ -n "$model" ]] && gemini_cmd+=(--model "$model")
      "${gemini_cmd[@]}" 2>&1 \
        | tee "$output_file" \
        | tee -a "$LOG_FILE" \
        | _md_stream || exit_code=${PIPESTATUS[0]}
      [[ $exit_code -ne 0 ]] && log_warn "gemini exited abnormally (exit $exit_code)"
      log_agent_done "$_role_label"
      ;;
    copilot|*)
      local copilot_effort=""
      [[ "$role_key" == "generator" ]] && copilot_effort="high"
      invoke_copilot "$prompt_input" "$output_file" "$role_label" "$prompt_mode" "$model" "$copilot_effort"
      exit_code=$?
      ;;
  esac

  return $exit_code
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_backlog() {
  _ensure_backlog_file
  echo -e "${W}${I18N_BACKLOG_TITLE}${N}"
  local slugs
  slugs=$(backlog_pending_slugs)
  if [[ -z "$slugs" ]]; then
    echo "  ${I18N_BACKLOG_EMPTY}"
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
  echo -e "$I18N_BACKLOG_RUN"
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
      log_warn "$I18N_START_NO_PENDING"
      log_info "$I18N_START_DISCOVER_HINT"
      exit 1
    fi

    echo -e "\n${W}${I18N_START_SELECT_ITEM}${N}"
    echo -e "${B}──────────────────────────────${N}"
    local i=1
    local slug_array=()
    while IFS= read -r s; do
      echo -e "  ${W}$i.${N} ${Y}$s${N}"
      slug_array+=("$s")
      i=$(( i + 1 ))
    done <<< "$slugs"
    echo ""
    printf "$(printf "$I18N_START_ENTER_NUM" "${#slug_array[@]}")"
    local choice; choice=$(_input_readline); echo ""

    if [[ "$choice" =~ ^[0-9]+$ ]] && \
       [[ "$choice" -ge 1 ]] && \
       [[ "$choice" -le "${#slug_array[@]}" ]]; then
      slug_or_prompt="${slug_array[$(( choice - 1 ))]}"
      log_info "$I18N_START_SELECTED ${W}$slug_or_prompt${N}"
    else
      log_err "$I18N_START_INVALID $choice"
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
  log_ok "$I18N_START_RUN_CREATED $run_id  (${W}$slug_or_prompt${N})"
  log_info "$I18N_START_VIEW_LOG  $run_log"

  if ! cmd_plan; then
    log_err "$I18N_START_PLAN_FAILED $run_log"
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

  log_step "$I18N_START_AUTO_LOOP"
  log_info "$(printf "$I18N_START_LOOP_DETAIL" "$max_sprints")"

  if ! _run_sprint_loop "$max_sprints"; then
    log_err "$(printf "$I18N_START_LOOP_INTERRUPTED" "$(basename "$run_dir")")"
    return 1
  fi

  if [[ -f "$run_dir/completed" ]]; then
    log_ok "$I18N_START_COMPLETE"
  else
    log_warn "$(printf "$I18N_START_MAX_SPRINT" "$max_sprints")"
  fi
}

cmd_plan() {
  local run_dir
  run_dir=$(require_run_dir)
  local slug_or_prompt
  slug_or_prompt=$(cat "$run_dir/prompt.txt")

  log_step "$I18N_PLAN_STEP"

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
    log_warn "$I18N_PLAN_TEXT_NOT_FOUND"
  fi
  echo "$plan_text" > "$run_dir/plan.txt"

  if [[ ! -s "$run_dir/spec.md" ]]; then
    cp "$raw" "$run_dir/spec.md"
    log_warn "$I18N_PLAN_MARKERS_NOT_FOUND"
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
    log_ok "$(printf "$I18N_PLAN_ITEM_IN_PROGRESS" "$slug_or_prompt")"

    if backlog_upsert_plan_line "$slug_or_prompt" "$plan_text"; then
      log_ok "$I18N_PLAN_LINE_UPDATED ${W}$slug_or_prompt${N}"
    else
      case "$?" in
        2) log_warn "$I18N_PLAN_LINE_FAILED (${W}$slug_or_prompt${N})" ;;
        3) log_info "$I18N_PLAN_LINE_UNCHANGED" ;;
        *) log_warn "$I18N_PLAN_LINE_EXCEPTION (slug=${W}$slug_or_prompt${N})" ;;
      esac
    fi

  fi

  # Create Git branch, commit backlog, create Draft PR
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    _git_setup_plan_branch "$slug_or_prompt" "$run_dir" "$plan_text"
  fi

  log_ok "$I18N_PLAN_COMPLETE"
}

cmd_contract() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ -f "$sprint/contract.md" ]] && {
    log_warn "$I18N_CONTRACT_EXISTS $sprint/contract.md"
    return 0
  }

  log_step "$(printf "$I18N_CONTRACT_STEP" "$sprint_num")"

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

  log_info "$I18N_CONTRACT_REVIEWING"
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
    log_ok "$(printf "$I18N_CONTRACT_APPROVED" "$sprint_num")"
  else
    log_warn "$I18N_CONTRACT_NEEDS_REVISION"
    cat >> "$gen_prompt_file" <<EOF

---

## Evaluator Feedback

$(cat "$sprint/contract-review.md")

Please revise the scope incorporating the above feedback.
EOF
    invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal-v2.md" "Generator — Sprint $sprint_num scope revision" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT" "generator_contract"
    cp "$sprint/contract-proposal-v2.md" "$sprint/contract.md"
    log_ok "$(printf "$I18N_CONTRACT_REVISED" "$sprint_num")"
  fi

  log_info "$I18N_CONTRACT_NEXT"
}

cmd_implement() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ ! -f "$sprint/contract.md" ]] && {
    log_err "$(printf "$I18N_IMPL_NO_SCOPE" "$sprint_num")"
    exit 1
  }

  local iteration
  iteration=$(( $(sprint_iteration "$sprint") + 1 ))
  echo "$iteration" > "$sprint/iteration"

  log_step "$(printf "$I18N_IMPL_STEP" "$sprint_num" "$iteration")"

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

  log_ok "$(printf "$I18N_IMPL_COMPLETE" "$sprint_num" "$iteration")"

  # Git commit implementation results
  _git_commit_sprint_impl "$sprint_num" "$sprint"

  log_info "$I18N_IMPL_NEXT"
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
    log_err "$(printf "$I18N_EVAL_NO_IMPL" "$sprint_num")"
    exit 1
  }

  log_step "$(printf "$I18N_EVAL_STEP" "$sprint_num" "$iteration")"

  log_info "$I18N_EVAL_RUNNING_CHECKS"
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
  log_info "$I18N_EVAL_CHECKS_DONE $test_results"

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
    log_info "$I18N_EVAL_SHUTTING_DOWN"
    while IFS='=' read -r key val; do
      [[ "$key" == *_PID ]] && kill "$val" 2>/dev/null && log_info "$key ($val) stopped" || true
    done < "$sprint/e2e-env.txt"
  fi

  if [[ $eval_exit_code -ne 0 ]]; then
    echo "fail" > "$sprint/status"
    log_err "$(printf "$I18N_EVAL_EXEC_ERROR" "$sprint_num" "$eval_exit_code")"
    log_info "$I18N_EVAL_MANUAL_RESUME"
    return 1
  fi

  if grep -qiE 'VERDICT[[:space:]]*:[[:space:]]*PASS' "$sprint/qa-report.md"; then
    echo "pass" > "$sprint/status"
    log_ok "$(printf "$I18N_EVAL_PASS" "$sprint_num")"
    _git_push_sprint_pass "$sprint_num"
    log_info "$I18N_EVAL_NEXT"
  else
    echo "fail" > "$sprint/status"
    local cur_iter
    cur_iter=$(sprint_iteration "$sprint")
    log_warn "$(printf "$I18N_EVAL_FAIL" "$sprint_num" "$cur_iter" "$MAX_ITERATIONS" "$sprint/qa-report.md")"
  fi
}

# Internal: only increments sprint counter (used for sprint transitions in auto mode)
_sprint_advance() {
  local run_dir="$1"
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local next_num=$(( sprint_num + 1 ))
  echo "$next_num" > "$run_dir/current_sprint"
  log_info "$(printf "$I18N_SPRINT_SWITCH" "$next_num")"
}

cmd_next() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  log_step "$I18N_NEXT_STEP"

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
    log_ok "$(printf "$I18N_NEXT_DONE" "$slug_or_prompt")"
  fi

  # Completion flag (prevents auto resumption)
  touch "$run_dir/completed"
  rm -f "$HARN_DIR/current"

  log_ok "$(printf "$I18N_NEXT_COMPLETE" "$slug_or_prompt")"
}

cmd_stop() {
  local pid_file="$HARN_DIR/harn.pid"

  if [[ ! -f "$pid_file" ]]; then
    log_warn "$I18N_STOP_NO_PID"
    log_info "$I18N_STOP_ALREADY_HINT"
    return 0
  fi

  local pid
  pid=$(cat "$pid_file")

  if ! kill -0 "$pid" 2>/dev/null; then
    log_warn "$(printf "$I18N_STOP_STALE_PID" "$pid")"
    rm -f "$pid_file"
    return 0
  fi

  log_info "$(printf "$I18N_STOP_STOPPING" "$pid")"

  # Send SIGTERM to the entire process group (including claude/copilot child processes)
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 2

  # If still alive, send SIGKILL
  if kill -0 "$pid" 2>/dev/null; then
    log_warn "$I18N_STOP_SIGKILL"
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
    log_ok "$I18N_STOP_RUN_STOPPED: ${W}$(basename "$run_dir")${N}"
  else
    log_ok "$I18N_STOP_DONE"
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
_resolve_base_branch() {
  # If GIT_BASE_BRANCH is "current", resolve to actual current branch
  if [[ "${GIT_BASE_BRANCH:-}" == "current" ]]; then
    git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
  else
    echo "${GIT_BASE_BRANCH:-main}"
  fi
}

_git_setup_plan_branch() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local slug="$1" run_dir="$2" plan_text="$3"
  local pr_target="${GIT_PR_TARGET_BRANCH:-$GIT_BASE_BRANCH}"
  local base_branch; base_branch=$(_resolve_base_branch)

  # In "current" mode: stay on current branch, no new branch creation
  if [[ "${GIT_BASE_BRANCH:-}" == "current" ]]; then
    local cur_branch; cur_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -z "$cur_branch" || "$cur_branch" == "HEAD" ]]; then
      log_warn "$I18N_GIT_NO_HEAD"
      return 0
    fi
    log_step "$(printf "$I18N_GIT_CURRENT_BRANCH" "$cur_branch")"
    # Still commit backlog file if changed
    if [[ -f "$BACKLOG_FILE" ]]; then
      git -C "$ROOT_DIR" add "$BACKLOG_FILE"
      if ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
        git -C "$ROOT_DIR" commit -m "plan: ${slug} — planning started" \
          2>&1 | while IFS= read -r line; do log_info "$line"; done
      fi
    fi
    # Push current branch
    git -C "$ROOT_DIR" push -u origin "$cur_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done || true
    # Create Draft PR to pr_target if different from current branch
    if [[ "$cur_branch" != "$pr_target" ]] && command -v gh &>/dev/null; then
      local pr_title="[Plan] ${slug}: ${plan_text}"
      local pr_body; pr_body=$(cat "$run_dir/spec.md" 2>/dev/null || echo "$plan_text")
      local draft_flag="--draft"; [[ "$GIT_PR_DRAFT" == "false" ]] && draft_flag=""
      local pr_url
      if pr_url=$(gh pr create \
        --base "$pr_target" \
        --head "$cur_branch" \
        --title "$pr_title" \
        --body "$pr_body" \
        $draft_flag 2>/dev/null); then
        log_ok "$I18N_GIT_PR_CREATED ${W}${pr_url}${N}"
        echo "$pr_url" > "$run_dir/pr-url.txt"
      else
        log_warn "$(printf "$I18N_GIT_PR_CREATE_FAILED" "$cur_branch" "$pr_target")"
      fi
    fi
    return 0
  fi

  local branch="${GIT_PLAN_PREFIX}${slug}"

  log_step "$I18N_GIT_CREATING_BRANCH"

  # Check current branch
  local current_branch
  current_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    log_warn "$I18N_GIT_NO_HEAD_BRANCH"
    return 0
  fi

  # Create or checkout branch
  if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    log_warn "$(printf "$I18N_GIT_BRANCH_EXISTS" "$branch")"
    git -C "$ROOT_DIR" checkout "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done
  else
    git -C "$ROOT_DIR" checkout -b "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done
    log_ok "$(printf "$I18N_GIT_BRANCH_CREATED" "$branch")"
  fi

  # Commit backlog file (only if changed)
  if [[ -f "$BACKLOG_FILE" ]]; then
    git -C "$ROOT_DIR" add "$BACKLOG_FILE"
    if ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
      git -C "$ROOT_DIR" commit -m "plan: ${slug} — planning started (sprint backlog updated)" \
        2>&1 | while IFS= read -r line; do log_info "$line"; done
      log_ok "$I18N_GIT_BACKLOG_COMMITTED"
    else
      log_info "$I18N_GIT_BACKLOG_UNCHANGED"
    fi
  fi

  # Push branch to origin
  if ! git -C "$ROOT_DIR" push -u origin "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_warn "$I18N_GIT_PUSH_FAILED_PR"
    log_info "Branch: ${W}$branch${N}"
    return 0
  fi
  log_ok "$(printf "$I18N_GIT_BRANCH_PUSHED" "$branch")"

  # Create Draft PR
  local pr_title="[Plan] ${slug}: ${plan_text}"
  local pr_body
  pr_body=$(cat "$run_dir/spec.md" 2>/dev/null || echo "$plan_text")

  local draft_flag="--draft"
  [[ "$GIT_PR_DRAFT" == "false" ]] && draft_flag=""

  log_info "$(printf "$I18N_GIT_PR_CREATING" "$pr_target" "$branch")"
  local pr_out

  # shellcheck disable=SC2086
  if pr_out=$(gh pr create \
      --base "$pr_target" \
      --head "$branch" \
      --title "$pr_title" \
      --body "$pr_body" \
      $draft_flag 2>&1); then
    log_ok "$I18N_GIT_PR_CREATED ${W}$pr_out${N}"
    echo "$pr_out" > "$run_dir/pr-url.txt"
  else
    log_warn "$I18N_GIT_PR_FAILED"
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

  log_step "$(printf "$I18N_GIT_IMPL_COMMIT" "$sprint_num")"

  cd "$ROOT_DIR"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    log_info "$I18N_GIT_NO_CHANGES"
    return 0
  fi

  git commit -m "$commit_msg" \
    2>&1 | while IFS= read -r line; do log_info "$line"; done
  log_ok "$(printf "$I18N_GIT_COMMIT_DONE" "$commit_msg")"

  if [[ "$GIT_AUTO_PUSH" == "true" ]]; then
    local cur_branch
    cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    git push origin "$cur_branch" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
    log_ok "$(printf "$I18N_GIT_PUSH_DONE" "$cur_branch")"
  fi
}

_git_push_sprint_pass() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local sprint_num="$1"
  local cur_branch
  cur_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [[ -z "$cur_branch" || "$cur_branch" == "HEAD" ]]; then
    log_warn "$I18N_GIT_NO_HEAD_PUSH"
    return 0
  fi

  log_step "$(printf "$I18N_GIT_SPRINT_PASS_PUSH" "$sprint_num" "$cur_branch")"
  cd "$ROOT_DIR"

  # Commit any uncommitted changes (e.g. qa-report.md, status files)
  git add -A
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "qa(sprint-${sprint_num}): evaluator PASS — sprint complete" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
  fi

  if git push origin "$cur_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "$(printf "$I18N_GIT_PUSH_DONE" "$cur_branch")"
  else
    log_warn "$(printf "$I18N_GIT_PUSH_FAILED" "$cur_branch")"
  fi
}


_git_merge_to_base() {
  [[ "$GIT_ENABLED" != "true" ]]    && return 0
  [[ "$GIT_AUTO_MERGE" != "true" ]] && return 0

  local feat_branch base_branch pr_target
  feat_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  base_branch=$(_resolve_base_branch)
  pr_target="${GIT_PR_TARGET_BRANCH:-$base_branch}"

  if [[ -z "$feat_branch" || "$feat_branch" == "$base_branch" || "$feat_branch" == "HEAD" ]]; then
    log_warn "$(printf "$I18N_GIT_NO_FEAT_BRANCH" "${feat_branch:-unknown}")"
    return 0
  fi

  log_step "$(printf "$I18N_GIT_FINALIZE" "$feat_branch" "$pr_target")"

  # Commit uncommitted changes (including backlog Done status, etc.)
  cd "$ROOT_DIR"
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log_info "$I18N_GIT_AUTO_COMMIT"
    git add -A
    git commit -m "chore: harn auto-commit — sprint complete" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
  fi

  # Push feature branch to origin
  log_info "$(printf "$I18N_GIT_UPDATE_PR" "$feat_branch")"
  if ! git push origin "$feat_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_warn "$I18N_GIT_PUSH_FAILED_MANUAL"
    return 1
  fi
  log_ok "$(printf "$I18N_GIT_PUSH_DONE" "$feat_branch")"

  # gh pr merge — not squash
  local pr_url_file pr_url
  pr_url_file="$(require_run_dir 2>/dev/null)/pr-url.txt"
  pr_url=$(cat "$pr_url_file" 2>/dev/null || echo "")

  local merge_target="${pr_url:-$feat_branch}"
  log_info "$(printf "$I18N_GIT_PR_MERGING" "$merge_target")"

  if gh pr merge "$merge_target" --merge 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "$(printf "$I18N_GIT_PR_MERGED" "$feat_branch" "$pr_target")"
  else
    log_warn "$I18N_GIT_PR_MERGE_FAILED"
    log_info "PR: ${pr_url:-}"
    return 1
  fi

  # Return to base branch and pull
  log_info "$(printf "$I18N_GIT_RETURN_BASE" "$base_branch")"
  git checkout "$base_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done

  log_info "$(printf "$I18N_GIT_PULLING" "$base_branch")"
  if git pull origin "$base_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "$(printf "$I18N_GIT_PULL_DONE" "$base_branch")"
  else
    log_warn "$(printf "$I18N_GIT_PULL_FAILED" "$base_branch")"
    return 1
  fi
}

# ── Retrospective ──────────────────────────────────────────────────────────────
cmd_retrospective() {
  local run_dir="$1"
  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_warn "$I18N_RETRO_NO_CLI"
    return 0
  fi

  log_step "$I18N_RETRO_STEP"

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
  log_info "$(printf "$I18N_RETRO_ANALYZING" "$ai_cmd")"
  if ! _ai_generate "$ai_cmd" "$prompt" "$retro_out"; then
    log_warn "$I18N_RETRO_FAILED"
    return 0
  fi

  # ── Print summary ──────────────────────────────────────────────────────────
  local summary
  summary=$(awk '/^=== retro-summary ===$/{f=1;next} /^=== /{f=0} f{print}' "$retro_out")
  if [[ -n "$summary" ]]; then
    echo ""
    echo -e "${W}${I18N_RETRO_SUMMARY_TITLE}${N}"
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
    printf "$(printf "$I18N_RETRO_PROMPT_ADD" "$role_kr")"
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
      log_ok "$(printf "$I18N_RETRO_ADDED" "$role_kr" "$target_prompt")"
      any_applied=true
    else
      log_info "$(printf "$I18N_RETRO_SKIPPED" "$role_kr")"
    fi
  done

  if [[ "$any_applied" == "true" ]]; then
    # Reflect custom prompt directory in config
    if [[ "$PROMPTS_DIR" != "$SCRIPT_DIR/prompts" ]]; then
      local rel_dir="${PROMPTS_DIR#$ROOT_DIR/}"
      sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${rel_dir}\"|" "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "$I18N_RETRO_APPLIED"
  fi

  log_ok "$(printf "$I18N_RETRO_COMPLETE" "$retro_out")"
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
  trap 'rm -f "$HARN_DIR/harn.pid"; log_warn "$I18N_LOOP_INTERRUPTED"; exit 130' INT
  trap 'rm -f "$HARN_DIR/harn.pid"; log_warn "$I18N_LOOP_TERMINATED"; exit 143' TERM

  log_step "$(printf "$I18N_LOOP_STARTED" "$max_sprints")"

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
      log_info "$(printf "$I18N_LOOP_SPRINT_PASSED" "$sprint_num")"
    elif [[ $iter -ge $MAX_ITERATIONS ]]; then
      log_warn "$(printf "$I18N_LOOP_SPRINT_MAX_ITER" "$sprint_num" "$MAX_ITERATIONS")"
    else
      while [[ $iter -lt $MAX_ITERATIONS ]]; do
        cmd_implement
        iter=$(sprint_iteration "$sprint")
        if ! cmd_evaluate; then
          log_err "$I18N_LOOP_EVAL_ERROR"
          return 1
        fi
        [[ "$(sprint_status "$sprint")" == "pass" ]] && break
      done
      if [[ "$(sprint_status "$sprint")" != "pass" ]]; then
        log_warn "$(printf "$I18N_LOOP_MAX_ITER_ADVANCE" "$sprint_num" "$MAX_ITERATIONS")"
      fi
    fi

    # Check if all sprints are complete
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")

    if [[ $total -gt 0 && $sprint_num -ge $total ]]; then
      # ── Last sprint done: final cleanup and exit ────────────────────────────
      _log_raw ""
      _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
      _log_raw "${G}  ║  ✓  $(printf "$I18N_LOOP_ALL_COMPLETE" "$total")${N}"
      _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"
      cmd_next          # write handoff + move backlog to Done + set completed flag
      _git_merge_to_base
      if [[ "$HARN_SKIP_RETRO" != "true" ]]; then
        cmd_retrospective "$run_dir"
      fi
      break
    else
      # ── Intermediate sprint done: increment counter and move to next sprint ─
      log_info "$(printf "$I18N_LOOP_SPRINT_DONE" "$sprint_num" "$(( sprint_num + 1 ))")"
      _sprint_advance "$run_dir"
    fi
  done
}

# ── New task discovery ─────────────────────────────────────────────────────────

cmd_discover() {
  log_step "$I18N_DISCOVER_STEP"

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
    log_warn "$(printf "$I18N_DISCOVER_NO_ITEMS" "$out_file")"
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
    log_info "$I18N_DISCOVER_BACKLOG_CREATED $BACKLOG_FILE"
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

  log_ok "$I18N_DISCOVER_ADDED"
  echo ""
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r line; do
    echo -e "  ${Y}$line${N}"
  done
  echo ""
  log_info "$I18N_DISCOVER_HINT"
}

# ── Add backlog item ───────────────────────────────────────────────────────────

cmd_add() {
  log_step "$I18N_ADD_STEP"

  # Create default structure if backlog file doesn't exist
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    mkdir -p "$(dirname "$BACKLOG_FILE")"
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "$I18N_ADD_BACKLOG_CREATED $BACKLOG_FILE"
  fi

  echo -e ""
  echo -e "${B}  ╭─ $I18N_ADD_BOX_TITLE${N}"
  echo -e "${B}  │${N}  $I18N_ADD_BOX_DESC"
  echo -e "${B}  │${N}  $I18N_ADD_BOX_AI"
  echo -e "${B}  │${N}  ${D}$I18N_ADD_BOX_HINT${N}"
  echo -e "${B}  ╰${N}"

  local user_input
  user_input=$(_input_multiline)

  if [[ -z "$user_input" ]]; then
    log_warn "$I18N_ADD_CANCELLED"
    return 0
  fi

  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_err "$I18N_ADD_NO_CLI"
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

  log_info "$(printf "$I18N_ADD_GENERATING" "$ai_cmd")"

  local out_file="$HARN_DIR/add-$(date +%Y%m%d-%H%M%S).md"
  mkdir -p "$HARN_DIR"

  if ! _ai_generate "$ai_cmd" "$prompt" "$out_file"; then
    log_err "$I18N_ADD_FAILED"
    return 1
  fi

  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "$(printf "$I18N_ADD_NO_ITEMS" "$out_file")"
    return 0
  fi

  # Add to Pending section via temp file (pipe + heredoc stdin conflict workaround)
  local items_tmp; items_tmp=$(mktemp)
  printf '%s' "${new_items}" > "$items_tmp"
  python3 - "$BACKLOG_FILE" "$items_tmp" <<'PYEOF'
import sys, re

path       = sys.argv[1]
items_file = sys.argv[2]
new_items_text = open(items_file, encoding='utf-8').read().strip()
if not new_items_text:
    sys.exit(0)

content = open(path, encoding='utf-8').read()
lines = content.splitlines()

# Find ## Pending section
pending_start = None
for i, line in enumerate(lines):
    if re.match(r'^## Pending\s*$', line):
        pending_start = i
        break

insert_lines = [''] + new_items_text.splitlines() + ['']

if pending_start is None:
    lines += ['', '## Pending'] + insert_lines
else:
    lines[pending_start + 1:pending_start + 1] = insert_lines

open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF
  rm -f "$items_tmp"

  echo ""
  log_ok "$I18N_ADD_DONE"
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r item; do
    echo -e "  ${C}▸${N} $item"
  done
  echo ""
  log_info "$I18N_ADD_HINT"
}

# ── Auto mode ──────────────────────────────────────────────────────────────────

cmd_auto() {
  log_step "$I18N_AUTO_STEP"

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
        log_info "$(printf "$I18N_AUTO_RESUMING" "$run_id" "$sprint_num" "$cur_status")"
        _run_sprint_loop 10
        return 0
      else
        log_info "$I18N_AUTO_CANCELLED"
      fi
    else
      log_info "$(printf "$I18N_AUTO_COMPLETED" "$run_id")"
    fi
  fi

  # 2. Start next pending backlog item if available
  local next_slug
  next_slug=$(backlog_next_slug)

  if [[ -n "$next_slug" ]]; then
    log_info "$(printf "$I18N_AUTO_STARTING" "$next_slug")"
    rm -f "$HARN_DIR/current"   # reset previous run pointer
    cmd_start "$next_slug"
    return 0
  fi

  # 3. Backlog empty → analyze codebase and add new items
  log_warn "$I18N_AUTO_EMPTY"
  cmd_discover

  # If discovery produced new items, start immediately
  next_slug=$(backlog_next_slug)
  if [[ -n "$next_slug" ]]; then
    log_info "$(printf "$I18N_AUTO_FIRST_DISCOVERED" "$next_slug")"
    rm -f "$HARN_DIR/current"
    cmd_start "$next_slug"
  fi
}

cmd_all() {
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    log_err "$I18N_ALL_NO_BACKLOG $BACKLOG_FILE"
    exit 1
  fi

  local slugs
  slugs=$(backlog_pending_slugs)

  if [[ -z "$slugs" ]]; then
    log_warn "$I18N_ALL_NO_PENDING"
    log_info "$I18N_ALL_HINT"
    return 0
  fi

  local slug_array=()
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && slug_array+=("$slug")
  done <<< "$slugs"

  local total_items="${#slug_array[@]}"
  log_step "$I18N_ALL_STEP ${W}${total_items}${N} item(s)"
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
    log_step "$(printf "$I18N_ALL_STARTING" "$item_num" "$total_items" "$slug")"

    # Reset run pointer (so cmd_start creates a new run)
    rm -f "$HARN_DIR/current"

    if cmd_start "$slug"; then
      # Record just-completed run directory
      local finished_run
      finished_run=$(ls -dt "$HARN_DIR/runs/"*/ 2>/dev/null | head -1)
      finished_run="${finished_run%/}"
      [[ -n "$finished_run" ]] && completed_run_dirs+=("$finished_run")
      log_ok "$(printf "$I18N_ALL_COMPLETE_ITEM" "$item_num" "$total_items" "$slug")"
    else
      log_err "$(printf "$I18N_ALL_FAILED_ITEM" "$item_num" "$total_items" "$slug")"
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
    log_warn "$I18N_ALL_FAILED_ITEMS ${failed_slugs[*]}"
    log_info "$I18N_ALL_RETRY_HINT"
  fi

  # ── Retrospective: run sequentially for all completed items ─────────────────
  if [[ $done_count -gt 0 ]]; then
    log_step "$(printf "$I18N_ALL_RETRO_STEP" "$done_count")"
    for run_dir in "${completed_run_dirs[@]}"; do
      local item_slug
      item_slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || basename "$run_dir")
      log_info "$(printf "$I18N_ALL_RETRO_ITEM" "$item_slug")"
      cmd_retrospective "$run_dir" || true
    done
  fi
}

cmd_status() {
  local run_id run_dir sprint_num
  run_id=$(current_run_id)
  if [[ -z "$run_id" ]]; then
    log_warn "$I18N_STATUS_NO_RUN"
    return 0
  fi
  run_dir="$HARN_DIR/runs/$run_id"
  sprint_num=$(current_sprint_num "$run_dir")

  echo -e "${W}$I18N_STATUS_RUN_ID${N}    $run_id"
  echo -e "${W}$I18N_STATUS_ITEM${N}      $(cat "$run_dir/prompt.txt" 2>/dev/null || echo "(unknown)")"
  echo -e "${W}$I18N_STATUS_SPRINT${N} $sprint_num"

  echo ""
  echo -e "${W}$I18N_STATUS_SPRINTS${N}"
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
  [[ $any -eq 0 ]] && echo "  $I18N_STATUS_NO_SPRINTS"
}

cmd_config() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      echo -e "${W}$I18N_CONFIG_TITLE${N}  (${CONFIG_FILE})"
      echo -e "${I18N_CONFIG_PROJECT}${W}$ROOT_DIR${N}"
      echo -e "${I18N_CONFIG_LANGUAGE}${W}$HARN_LANG${N}  ($I18N_LANG_NAME)"
      echo -e "${I18N_CONFIG_BACKLOG_KEY}${W}$BACKLOG_FILE${N}"
      echo -e "${I18N_CONFIG_MAX_RETRIES_KEY}${W}$MAX_ITERATIONS${N}"
      echo -e "${I18N_CONFIG_GIT_KEY}${W}$GIT_ENABLED${N}"
      [[ "$GIT_ENABLED" == "true" ]] && {
        echo -e "${I18N_CONFIG_BASE_BRANCH_KEY}${W}$GIT_BASE_BRANCH${N}$( [[ "$GIT_BASE_BRANCH" == "current" ]] && echo "  ${D}(= current git branch at runtime)${N}" )"
        echo -e "${I18N_CONFIG_PR_TARGET_KEY}${W}${GIT_PR_TARGET_BRANCH:-$GIT_BASE_BRANCH}${N}"
        echo -e "${I18N_CONFIG_AUTO_PUSH_KEY}${W}$GIT_AUTO_PUSH${N}"
        echo -e "${I18N_CONFIG_AUTO_PR_KEY}${W}$GIT_AUTO_PR${N}"
      }
      echo ""
      echo -e "${W}$I18N_CONFIG_AI_MODELS${N}"
      echo -e "  Planner:           ${W}$COPILOT_MODEL_PLANNER${N}"
      echo -e "  Generator (contract): ${W}$COPILOT_MODEL_GENERATOR_CONTRACT${N}"
      echo -e "  Generator (impl):  ${W}$COPILOT_MODEL_GENERATOR_IMPL${N}"
      echo -e "  Evaluator (contract): ${W}$COPILOT_MODEL_EVALUATOR_CONTRACT${N}"
      echo -e "  Evaluator (QA):    ${W}$COPILOT_MODEL_EVALUATOR_QA${N}"
      [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]] && echo -e "\n${I18N_CONFIG_CUSTOM_PROMPTS_KEY}${W}$PROMPTS_DIR${N}"
      ;;
    set)
      local key="${2:-}" val="${3:-}"
      [[ -z "$key" || -z "$val" ]] && { log_err "$I18N_CONFIG_SET_USAGE"; exit 1; }
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "$I18N_CONFIG_NO_FILE"
        exit 1
      fi
      # LANG → write as LANG_OVERRIDE
      local cfg_key="$key"
      [[ "$key" == "LANG" ]] && cfg_key="LANG_OVERRIDE"
      if grep -q "^${cfg_key}=" "$CONFIG_FILE"; then
        sed -i '' "s|^${cfg_key}=.*|${cfg_key}=\"${val}\"|" "$CONFIG_FILE"
      else
        echo "${cfg_key}=\"${val}\"" >> "$CONFIG_FILE"
      fi
      log_ok "${W}${cfg_key}${N} = \"${val}\" set"
      ;;
    regen)
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "$I18N_CONFIG_SET_FILE_NOT_FOUND"
        exit 1
      fi
      local ai_cmd; ai_cmd=$(_detect_ai_cli)
      if [[ -z "$ai_cmd" ]]; then
        log_err "$I18N_CONFIG_NO_CLI"
        exit 1
      fi
      local hp="${HINT_PLANNER:-}" hg="${HINT_GENERATOR:-}" he="${HINT_EVALUATOR:-}" gg="${GIT_GUIDE:-}"
      if [[ -z "$hp" && -z "$hg" && -z "$he" && -z "$gg" ]]; then
        log_warn "$I18N_CONFIG_NO_HINTS"
        log_info "$I18N_CONFIG_HINT_HOW"
        exit 0
      fi
      log_step "$I18N_CONFIG_REGEN_STEP"
      log_info "$(printf "$I18N_CONFIG_REGEN_INFO" "$ai_cmd")"
      _generate_custom_prompts "$hp" "$hg" "$he" "$gg"
      local cpd=".harn/prompts"
      if ! grep -q "^CUSTOM_PROMPTS_DIR=" "$CONFIG_FILE"; then
        echo "CUSTOM_PROMPTS_DIR=\"${cpd}\"" >> "$CONFIG_FILE"
      else
        sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
      fi
      load_config
      log_ok "$(printf "$I18N_CONFIG_REGEN_DONE" "$PROMPTS_DIR")"
      ;;
    *)
      log_err "$I18N_CONFIG_UNKNOWN_SUB $sub"
      echo -e "$I18N_CONFIG_USAGE"
      exit 1
      ;;
  esac
}

cmd_runs() {
  echo -e "${W}$I18N_RUNS_TITLE${N}"
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
  [[ -z "$run_id" ]] && { log_err "$I18N_RESUME_USAGE"; exit 1; }
  local run_dir="$HARN_DIR/runs/$run_id"
  [[ ! -d "$run_dir" ]] && { log_err "$I18N_RESUME_NOT_FOUND $run_id"; exit 1; }
  ln -sfn "$run_dir" "$HARN_DIR/current"
  log_ok "$I18N_RESUME_OK $run_id"
  cmd_status
}

cmd_tail() {
  local log="$HARN_DIR/current.log"

  # current.log symlink missing or broken → fall back to most recent run log
  if [[ ! -e "$log" ]]; then
    local latest_log
    latest_log=$(ls -t "$HARN_DIR/runs"/*/run.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]]; then
      log_warn "$I18N_TAIL_FALLBACK $latest_log"
      ln -sfn "$latest_log" "$HARN_DIR/current.log"
      log="$latest_log"
    else
      log_err "$I18N_TAIL_NO_LOG"
      exit 1
    fi
  fi

  echo -e "${W}$I18N_TAIL_TAILING${N} $log  ${B}(Ctrl-C to stop)${N}"
  tail -f "$log"
}

usage() {
  _print_banner
  cat <<EOF
${D}  $(pwd)${N}

  ${W}${I18N_USAGE_TITLE}${N}  ${I18N_USAGE_CMD}

  ${C}${I18N_USAGE_SETUP}${N}
    init                  ${I18N_USAGE_INIT}
    config                ${I18N_USAGE_CONFIG}
    config set KEY VALUE  ${I18N_USAGE_CONFIG_SET}
    config regen          ${I18N_USAGE_CONFIG_REGEN}

  ${C}${I18N_USAGE_BACKLOG}${N}
    backlog               ${I18N_USAGE_BACKLOG_CMD}
    add                   ${I18N_USAGE_ADD}
    discover              ${I18N_USAGE_DISCOVER}

  ${C}${I18N_USAGE_RUN}${N}
    start                 ${I18N_USAGE_START}
    auto                  ${I18N_USAGE_AUTO}
    all                   ${I18N_USAGE_ALL}

  ${C}${I18N_USAGE_STEPS}${N}
    plan                  ${I18N_USAGE_PLAN}
    contract              ${I18N_USAGE_CONTRACT}
    implement             ${I18N_USAGE_IMPLEMENT}
    evaluate              ${I18N_USAGE_EVALUATE}
    next                  ${I18N_USAGE_NEXT}

  ${C}${I18N_USAGE_MONITOR}${N}
    status                ${I18N_USAGE_STATUS}
    tail                  ${I18N_USAGE_TAIL}
    runs                  ${I18N_USAGE_RUNS}
    resume <id>           ${I18N_USAGE_RESUME}
    stop                  ${I18N_USAGE_STOP}

  ${D}Tip: ${I18N_USAGE_TIP}${N}
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

# Initial lang detection (before config loads — ensures UI strings are available)
_detect_lang
_i18n_load
# Set initial PROMPTS_DIR from detected lang
_lang_dir="$SCRIPT_DIR/prompts/$HARN_LANG"
if [[ -d "$_lang_dir" ]]; then
  PROMPTS_DIR="$_lang_dir"
else
  PROMPTS_DIR="$SCRIPT_DIR/prompts/en"
fi
unset _lang_dir

# ── Config load / first-run detection ────────────────────────────────────────
_cmd="${1:-help}"
case "$_cmd" in
  init|help|--help|-h) : ;;  # commands that can run without config
  *)
    if [[ ! -f "$CONFIG_FILE" ]]; then
      _print_banner
      echo -e "  ${Y}⚠${N}  ${I18N_NO_CONFIG_WARN}"
      echo -e "     ${I18N_NO_CONFIG_SETUP}\n"
      cmd_init
    else
      load_config
    fi
    ;;
esac

cmd_doctor() {
  echo -e "\n${W}╔══════════════════════════════════════╗${N}"
  printf "${W}║  %-36s║${N}\n" "  $I18N_DOCTOR_TITLE"
  echo -e "${W}╚══════════════════════════════════════╝${N}\n"

  # ── Version ─────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_VERSION}${N}"
  echo -e "  harn:         ${C}$HARN_VERSION${N}"
  echo -e "  bash:         ${C}${BASH_VERSION:-unknown}${N}"
  echo ""

  # ── AI CLIs ─────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_BACKENDS}${N}"
  local backend_ok=0

  if command -v copilot &>/dev/null; then
    local cp_ver; cp_ver=$(copilot --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} copilot:      ${C}${cp_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} copilot:      ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v claude &>/dev/null; then
    local cl_ver; cl_ver=$(claude --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} claude:       ${C}${cl_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} claude:       ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v codex &>/dev/null; then
    local cx_ver; cx_ver=$(codex --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} codex:        ${C}${cx_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} codex:        ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v gemini &>/dev/null; then
    local gm_ver; gm_ver=$(gemini --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} gemini:       ${C}${gm_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} gemini:       ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if [[ -n "${AI_BACKEND:-}" ]]; then
    echo -e "  ${I18N_DOCTOR_ACTIVE_BACKEND}: ${W}${AI_BACKEND}${N}"
  elif [[ $backend_ok -eq 0 ]]; then
    echo -e "  ${R}⚠ ${I18N_DOCTOR_NO_BACKEND}${N}"
  fi
  echo ""

  # ── Git ─────────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_GIT_SECTION}${N}"
  if command -v git &>/dev/null; then
    local git_ver; git_ver=$(git --version 2>/dev/null | head -1)
    echo -e "  ${G}✓${N} git:          ${C}${git_ver}${N}"
  else
    echo -e "  ${R}✗${N} git:          ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v gh &>/dev/null; then
    local gh_ver; gh_ver=$(gh --version 2>/dev/null | head -1)
    local gh_auth; gh_auth=$(gh auth status 2>&1 | grep -i "logged in" | head -1 | sed 's/^[[:space:]]*//')
    echo -e "  ${G}✓${N} gh:           ${C}${gh_ver}${N}"
    if [[ -n "$gh_auth" ]]; then
      echo -e "  ${G}✓${N} gh auth:      ${C}${gh_auth}${N}"
    else
      echo -e "  ${Y}?${N} gh auth:      ${I18N_DOCTOR_GH_AUTH_WARN}"
    fi
  else
    echo -e "  ${R}✗${N} gh:           ${I18N_DOCTOR_GH_NOT_FOUND}"
    echo -e "    ${I18N_DOCTOR_INSTALL}: ${W}brew install gh${N}"
  fi

  if [[ -n "${ROOT_DIR:-}" ]] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    local branch; branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local remote; remote=$(git -C "$ROOT_DIR" remote -v 2>/dev/null | head -1 | awk '{print $2}')
    echo -e "  ${I18N_DOCTOR_PROJECT_REPO}: ${C}${branch}${N} @ ${remote:-none}"
  fi
  echo ""

  # ── Harness config ───────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_CONFIG_SECTION}${N}"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "  ${G}✓${N} .harn_config:     ${I18N_DOCTOR_CONFIG_FOUND}  (${W}$CONFIG_FILE${N})"
    echo -e "  ${I18N_DOCTOR_GIT_INTEGRATION}:  ${W}${GIT_ENABLED:-false}${N}"
    [[ "$GIT_ENABLED" == "true" ]] && {
      echo -e "  ${I18N_DOCTOR_BASE_BRANCH}:      ${W}${GIT_BASE_BRANCH:-not set}${N}"
      echo -e "  ${I18N_DOCTOR_PR_TARGET}: ${W}${GIT_PR_TARGET_BRANCH:-not set}${N}"
    }
    echo -e "  ${I18N_DOCTOR_SPRINT_COUNT}:     ${W}${SPRINT_COUNT:-2}${N}"
    echo -e "  ${I18N_DOCTOR_AI_BACKEND}:       ${W}${AI_BACKEND:-auto}${N}"
  else
    echo -e "  ${D}○${N} .harn_config:     ${I18N_DOCTOR_CONFIG_NOT_FOUND}"
  fi

  if [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]]; then
    echo -e "  ${I18N_DOCTOR_CUSTOM_PROMPTS}:   ${W}${PROMPTS_DIR}${N}"
  fi
  echo ""

  # ── Models ───────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_MODELS}${N}"
  echo -e "  Planner:              ${W}${COPILOT_MODEL_PLANNER:-default}${N}"
  echo -e "  Generator (contract): ${W}${COPILOT_MODEL_GENERATOR_CONTRACT:-default}${N}"
  echo -e "  Generator (impl):     ${W}${COPILOT_MODEL_GENERATOR_IMPL:-default}${N}"
  echo -e "  Evaluator (contract): ${W}${COPILOT_MODEL_EVALUATOR_CONTRACT:-default}${N}"
  echo -e "  Evaluator (QA):       ${W}${COPILOT_MODEL_EVALUATOR_QA:-default}${N}"
  echo ""

  # ── Active run ───────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_ACTIVE_RUN}${N}"
  local run_id; run_id=$(current_run_id)
  if [[ -n "$run_id" ]]; then
    local run_dir="$HARN_DIR/runs/$run_id"
    local slug; slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || echo "unknown")
    local sprint_num; sprint_num=$(current_sprint_num "$run_dir")
    echo -e "  ${G}✓${N} Run:          ${W}${run_id}${N}  (${slug})"
    echo -e "  ${I18N_DOCTOR_SPRINT}:       ${W}${sprint_num}${N}"
  else
    echo -e "  ${I18N_DOCTOR_NO_RUN}"
  fi
  echo ""

  # ── Dependencies ─────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_DEPS}${N}"
  local all_ok=1
  for dep in python3 node; do
    if command -v "$dep" &>/dev/null; then
      local dver; dver=$($dep --version 2>/dev/null | head -1)
      echo -e "  ${G}✓${N} ${dep}:       ${C}${dver}${N}"
    else
      echo -e "  ${Y}?${N} ${dep}:       ${I18N_DOCTOR_NOT_FOUND} (${I18N_DOCTOR_OPTIONAL})"
      all_ok=0
    fi
  done
  echo ""

  if [[ $backend_ok -eq 1 ]]; then
    echo -e "${G}${I18N_DOCTOR_ALL_OK}${N}\n"
  else
    echo -e "${R}⚠ ${I18N_DOCTOR_FAIL_MSG}${N}\n"
  fi
}

cmd_base() {
  local target="${1:-}"

  if [[ -z "$target" ]]; then
    # No argument — set to current branch
    target=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -z "$target" || "$target" == "HEAD" ]]; then
      log_err "$I18N_BASE_NO_BRANCH"
      return 1
    fi
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_err "$I18N_BASE_NO_CONFIG"
    return 1
  fi

  local prev="${GIT_BASE_BRANCH:-main}"
  if grep -q "^GIT_BASE_BRANCH=" "$CONFIG_FILE"; then
    sed -i '' "s|^GIT_BASE_BRANCH=.*|GIT_BASE_BRANCH=\"${target}\"|" "$CONFIG_FILE"
  else
    echo "GIT_BASE_BRANCH=\"${target}\"" >> "$CONFIG_FILE"
  fi

  if [[ "$target" == "current" ]]; then
    local actual; actual=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    log_ok "$(printf "$I18N_BASE_SET_CURRENT" "$actual")"
    log_info "$I18N_BASE_SET_CURRENT_HINT"
  else
    log_ok "$(printf "$I18N_BASE_SET" "$target" "$prev")"
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
  inbox)     cmd_inbox "${2:-show}" ;;
  base)      cmd_base "${2:-}" ;;
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
