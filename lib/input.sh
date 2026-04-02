# lib/input.sh — User input helpers and sprint progress
# Sourced by harn.sh — do not execute directly

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

# REPL input line with slash-command autocomplete (TUI-aware)
# Expects env HARN_TUI_INPUT_ROW = the 1-based terminal row for the input line.
# If not set, defaults to terminal height.
# Dropdown appears above the input line using absolute positioning.
# Does NOT touch scroll regions — the caller (TUI) owns that.
# Stdout: entered line; exits 1 on Ctrl+C/Ctrl+Q
_input_repl_line() {
  python3 -c '
import sys, tty, termios, unicodedata, os
import select

def cw(c):
    return 2 if unicodedata.east_asian_width(c) in ("W","F") else 1
def twc(s):
    return sum(cw(c) for c in s)

CMDS = [
    ("/auto",       "자동 감지: 재개/시작/발굴"),
    ("/all",        "대기 항목 전부 실행"),
    ("/start",      "슬러그로 항목 시작"),
    ("/backlog",    "백로그 목록"),
    ("/add",        "새 항목 추가"),
    ("/discover",   "코드베이스 분석"),
    ("/status",     "현재 상태"),
    ("/stop",       "실행 중단"),
    ("/plan",       "플래너 재실행"),
    ("/implement",  "제너레이터 실행"),
    ("/evaluate",   "이밸류에이터 실행"),
    ("/next",       "다음 스프린트"),
    ("/config",     "설정 보기/변경"),
    ("/model",      "AI 백엔드/모델 변경"),
    ("/doctor",     "환경 진단"),
    ("/init",       "초기 설정"),
    ("/runs",       "실행 목록"),
    ("/team",       "병렬 에이전트"),
    ("/help",       "도움말"),
    ("/exit",       "종료"),
]
NEEDS_ARGS = {"/start", "/config", "/team", "/resume"}
MAX_SHOWN  = 8
PROMPT     = "  \u276f "
PROMPT_W   = 4

fd  = open("/dev/tty", "rb+", buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)

try:
    rows, cols = os.get_terminal_size(fd.fileno())
except Exception:
    rows, cols = 24, 80

# The row where the input line lives (set by TUI, or bottom of terminal)
input_row = int(os.environ.get("HARN_TUI_INPUT_ROW", str(rows)))
max_shown = min(MAX_SHOWN, max(1, input_row - 3))

# Draw initial prompt at the input row
fd.write(f"\033[{input_row};1H\033[K{PROMPT}".encode())
fd.flush()

chars     = []
buf_b     = b""
comp      = False
ci        = 0
vs        = 0
cm        = []
cdrawlen  = 0
cancelled = False

def get_typed():  return "".join(chars)
def cur_col():    return PROMPT_W + twc(get_typed()) + 1

def get_matches():
    t = get_typed().lower()
    if not t.startswith("/"): return []
    return [(c, d) for c, d in CMDS if c.startswith(t)]

def erase_comp():
    global cdrawlen
    if cdrawlen == 0: return
    start = input_row - cdrawlen
    out   = []
    for i in range(cdrawlen):
        out.append(f"\033[{start + i};1H\033[K".encode())
    out.append(f"\033[{input_row};{cur_col()}H".encode())
    fd.write(b"".join(out)); fd.flush()
    cdrawlen = 0

def draw_comp(m, idx):
    global cdrawlen, vs
    erase_comp()
    if not m: return

    if idx < vs: vs = idx
    elif idx >= vs + max_shown: vs = idx - max_shown + 1

    shown = m[vs : vs + max_shown]
    above = vs
    below = len(m) - vs - len(shown)

    lines = []
    lines.append(b"  \033[2m" + ("\u2500" * 40).encode("utf-8") + b"\033[0m")
    if above > 0:
        lines.append(f"  \033[2m\u2191 {above}개 위\033[0m".encode("utf-8"))
    for i, (cmd, desc) in enumerate(shown):
        if vs + i == idx:
            lines.append(f"  \033[36m\u276f\033[0m \033[1m{cmd}\033[0m  \033[2m{desc}\033[0m".encode("utf-8"))
        else:
            lines.append(f"    \033[2m{cmd}  {desc}\033[0m".encode("utf-8"))
    if below > 0:
        lines.append(f"  \033[2m\u2193 {below}개 아래\033[0m".encode("utf-8"))

    n = len(lines)
    start_row = input_row - n
    if start_row < 1:
        lines = lines[1 - start_row :]; n = len(lines); start_row = 1

    out = []
    for i, line in enumerate(lines):
        out.append(f"\033[{start_row + i};1H\033[K".encode())
        out.append(line)
    out.append(f"\033[{input_row};{cur_col()}H".encode())
    fd.write(b"".join(out)); fd.flush()
    cdrawlen = n

def replace_input(new_text):
    fd.write(f"\033[{input_row};{PROMPT_W + 1}H\033[K".encode())
    chars.clear(); chars.extend(list(new_text))
    if new_text: fd.write(new_text.encode("utf-8"))
    fd.flush()

try:
    while True:
        b = fd.read(1)
        if not b: break
        byte = b[0]

        if byte in (13, 10):
            erase_comp()
            if comp and cm:
                sel = cm[ci][0]; replace_input(sel)
                comp = False; cm = []; ci = 0; vs = 0
                if sel not in NEEDS_ARGS: break
                else: chars.append(" "); fd.write(b" "); fd.flush(); comp = False; cm = []
            else: break

        elif byte in (127, 8):
            if chars:
                c = chars.pop(); w = cw(c)
                fd.write(b"\x08" * w + b" " * w + b"\x08" * w); fd.flush()
            t = get_typed()
            if t.startswith("/"):
                cm = get_matches(); ci = min(ci, max(0, len(cm)-1)); vs = 0
                comp = bool(cm); draw_comp(cm, ci)
            else: erase_comp(); comp = False; cm = []; ci = 0; vs = 0

        elif byte in (3, 17): erase_comp(); raise KeyboardInterrupt

        elif byte == 9:
            if comp and cm:
                sel = cm[ci][0]; erase_comp(); replace_input(sel)
                cm = get_matches(); ci = 0; vs = 0
                comp = bool(cm); draw_comp(cm, ci)

        elif byte == 27:
            ready, _, _ = select.select([fd], [], [], 0.08)
            if not ready:
                erase_comp()
                cancelled = True
                break
            b2 = fd.read(1)
            if b2 == b"[":
                b3 = fd.read(1)
                if comp and cm:
                    n_items = len(cm)
                    if   b3 == b"A": ci = (ci - 1) % n_items; draw_comp(cm, ci)
                    elif b3 == b"B": ci = (ci + 1) % n_items; draw_comp(cm, ci)
            else:
                erase_comp(); comp = False; cm = []; ci = 0; vs = 0

        elif byte >= 32:
            buf_b += b
            try:
                c = buf_b.decode("utf-8"); chars.append(c); buf_b = b""
                fd.write(c.encode("utf-8")); fd.flush()
                t = get_typed()
                if t.startswith("/"):
                    cm = get_matches(); ci = 0; vs = 0
                    comp = bool(cm); draw_comp(cm, ci)
                else:
                    if comp: erase_comp(); comp = False; cm = []; ci = 0; vs = 0
            except UnicodeDecodeError: pass

except (KeyboardInterrupt, OSError):
    cancelled = True

finally:
    erase_comp()
    fd.write(f"\033[{input_row};1H\033[K".encode())
    fd.flush()
    try: termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception: pass
    try: fd.close()
    except Exception: pass

if cancelled: sys.exit(1)
r = get_typed()
if r: print(r, end="")
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
import select

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
            ready, _, _ = select.select([fd], [], [], 0.08)
            if not ready:
                cancelled = True
                break
            b2 = fd.read(1)
            if b2 == b"[":
                b3 = fd.read(1)
                if   b3 == b"A": idx = (idx - 1) % n
                elif b3 == b"B": idx = (idx + 1) % n
                elif b3 in (b"5", b"6"): fd.read(1)
            else:
                cancelled = True
                break
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
