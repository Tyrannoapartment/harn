# lib/guidance.sh — Mid-run guidance listener and inbox
# Sourced by harn.sh — do not execute directly

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
  local prompt="다음 메시지의 의도를 implement, evaluate, plan, context 중 정확히 하나로만 답해줘 (단어 하나만):

메시지: $msg

- implement: 구현/코드/API/UI/기능 관련
- evaluate: 테스트/검증/QA/확인 관련
- plan: 계획/스프린트/목표/변경 관련
- context: 위에 해당없는 배경지식/설정"

  local result="" tmp_file
  tmp_file=$(mktemp)
  if _ai_generate "" "$prompt" "$tmp_file" "quiet" >/dev/null 2>&1; then
    result=$(tr -d '[:space:]' < "$tmp_file" | tr '[:upper:]' '[:lower:]')
  fi
  rm -f "$tmp_file"

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
