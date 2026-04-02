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
# Expects env HARN_TUI_COMPOSER_TOP / HARN_TUI_COMPOSER_HEIGHT.
# Dropdown appears above the fixed bottom composer.
# Does NOT touch scroll regions — the caller (TUI) owns that.
# Stdout: entered line; prints __HARN_REPL_CANCELLED__ on ESC line-cancel; exits 1 on Ctrl+C/Ctrl+Q
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
    ("/clear",      ".harn 상태 초기화"),
    ("/help",       "도움말"),
    ("/exit",       "종료"),
]
NEEDS_ARGS = {"/start", "/config", "/resume"}
MAX_SHOWN  = 8

fd  = open("/dev/tty", "rb+", buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)

try:
    rows, cols = os.get_terminal_size(fd.fileno())
except Exception:
    rows, cols = 24, 80

composer_height = int(os.environ.get("HARN_TUI_COMPOSER_HEIGHT", "4"))
composer_top = int(os.environ.get("HARN_TUI_COMPOSER_TOP", str(max(1, rows - composer_height + 1))))
composer_bottom = composer_top + composer_height - 1
content_rows = max(1, composer_height - 2)
inner_width = max(20, cols - 2)
max_shown = min(MAX_SHOWN, max(1, composer_top - 2))

chars     = []
buf_b     = b""
comp      = False
ci        = 0
vs        = 0
cm        = []
cdrawlen  = 0
cancelled = False
line_cancelled = False

def get_typed():  return "".join(chars)

def wrap_text(text, width):
    if width <= 1:
        return [text]
    lines = []
    cur = ""
    cur_w = 0
    for ch in text:
        ch_w = cw(ch)
        if cur and cur_w + ch_w > width:
            lines.append(cur)
            cur = ch
            cur_w = ch_w
        else:
            cur += ch
            cur_w += ch_w
    lines.append(cur)
    return lines or [""]

def get_matches():
    t = get_typed().lower()
    if not t.startswith("/"): return []
    return [(c, d) for c, d in CMDS if c.startswith(t)]

def render_input():
    text = get_typed()
    wrapped = wrap_text(text, inner_width - 4)
    visible = wrapped[-content_rows:]

    out = []
    bg = "\033[48;5;238m"
    fg = "\033[38;5;252m"
    muted = "\033[38;5;245m"
    reset = "\033[0m"
    fill = " " * max(0, cols)

    for i in range(content_rows):
        row = composer_top + 1 + i
        line = visible[i] if i < len(visible) else ""
        prefix = "› " if i == 0 else "  "
        line_pad = max(0, inner_width - len(prefix) - twc(line))
        if not text and i == 0:
            placeholder = "메시지 또는 /명령어를 입력하세요"
            placeholder_pad = " " * max(0, inner_width - len(prefix) - twc(placeholder))
            out.append(
                (f"\033[{row};1H\033[2K{bg}{fill}{reset}"
                 + f"\033[{row};1H{bg}{fg}{prefix}{muted}{placeholder}"
                 + placeholder_pad
                 + reset).encode("utf-8")
            )
        else:
            out.append(
                (f"\033[{row};1H\033[2K{bg}{fill}{reset}"
                 + f"\033[{row};1H{bg}{fg}{prefix}{line}"
                 + (" " * line_pad)
                 + reset).encode("utf-8")
            )

    status = "ESC clear · Enter send · " + os.getcwd()
    if twc(status) > max(0, cols):
        status = status[-max(0, cols):]
    out.append(f"\033[{composer_bottom};1H\033[2K\033[38;5;245m{status}{reset}".encode("utf-8"))

    cursor_line = visible[-1] if visible else ""
    cursor_row = composer_top + min(max(1, len(visible)), content_rows)
    if not text:
        cursor_row = composer_top + 1
        cursor_col = 3
    else:
        prefix = "› " if len(visible) == 1 else "  "
        cursor_col = 1 + len(prefix) + twc(cursor_line)
    out.append(f"\033[{cursor_row};{max(1, cursor_col)}H".encode("utf-8"))
    fd.write(b"".join(out))
    fd.flush()

def erase_comp():
    global cdrawlen
    if cdrawlen == 0: return
    start = composer_top - cdrawlen
    out   = []
    for i in range(cdrawlen):
        out.append(f"\033[{start + i};1H\033[K".encode())
    fd.write(b"".join(out)); fd.flush()
    cdrawlen = 0
    render_input()

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
    start_row = composer_top - n
    if start_row < 1:
        lines = lines[1 - start_row :]; n = len(lines); start_row = 1

    out = []
    for i, line in enumerate(lines):
        out.append(f"\033[{start_row + i};1H\033[K".encode())
        out.append(line)
    fd.write(b"".join(out)); fd.flush()
    cdrawlen = n
    render_input()

def replace_input(new_text):
    chars.clear(); chars.extend(list(new_text))
    render_input()

render_input()

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
                chars.pop()
                render_input()
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
                if comp:
                    erase_comp(); comp = False; cm = []; ci = 0; vs = 0
                    continue
                erase_comp()
                replace_input("")
                line_cancelled = True
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
                render_input()
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
    for row in range(composer_top, composer_bottom + 1):
        fd.write(f"\033[{row};1H\033[K".encode())
    fd.flush()
    try: termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except Exception: pass
    try: fd.close()
    except Exception: pass

if cancelled: sys.exit(1)
if line_cancelled:
    print("__HARN_REPL_CANCELLED__", end="")
    sys.exit(0)
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

# Multi-select menu with space toggle / enter confirm.
# Usage: _pick_multi_menu "prompt" max_select item1 item2 ...
# Stdout: selected items, newline-separated; exits 1 on cancel.
_pick_multi_menu() {
  local menu_prompt="$1" max_select="${2:-1}"
  shift 2
  local items=("$@")
  [[ ${#items[@]} -eq 0 ]] && return 1
  python3 -c '
import sys, tty, termios, select

prompt = sys.argv[1]
max_select = int(sys.argv[2]) if len(sys.argv) > 2 else 1
items = sys.argv[3:]
n = len(items)
if n == 0:
    sys.exit(1)

idx = 0
selected = set()
fd = open("/dev/tty", "rb+", buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)

def render():
    out = []
    title = f"  \033[1m{prompt}\033[0m\r\n"
    hint = f"  \033[2m(↑↓ move  Space toggle  Enter confirm  ESC cancel  max {max_select})\033[0m\r\n\r\n"
    out.append(title.encode())
    out.append(hint.encode())
    for i, item in enumerate(items):
        mark = "\033[32m●\033[0m" if i in selected else "\033[2m○\033[0m"
        prefix = "\033[36m❯\033[0m" if i == idx else " "
        style_start = "\033[1m" if i == idx else "\033[2m"
        style_end = "\033[0m"
        out.append(f"  {prefix} {mark} {style_start}{item}{style_end}\r\n".encode())
    return b"".join(out)

try:
    total_lines = n + 3
    fd.write(render())
    fd.write(f"\033[{total_lines}A".encode())
    fd.flush()
    while True:
      fd.write(render())
      fd.write(f"\033[{total_lines}A".encode())
      fd.flush()
      b = fd.read(1)
      if not b:
          break
      byte = b[0]
      if byte in (13, 10):
          if selected:
              break
      elif byte == 32:
          if idx in selected:
              selected.remove(idx)
          elif len(selected) < max_select:
              selected.add(idx)
      elif byte in (3, 17):
          selected.clear()
          raise KeyboardInterrupt
      elif byte == 27:
          ready, _, _ = select.select([fd], [], [], 0.08)
          if not ready:
              selected.clear()
              raise KeyboardInterrupt
          b2 = fd.read(1)
          if b2 == b"[":
              b3 = fd.read(1)
              if b3 == b"A":
                  idx = (idx - 1) % n
              elif b3 == b"B":
                  idx = (idx + 1) % n
finally:
    try:
        fd.write(f"\033[{total_lines}B\r\n".encode())
        fd.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        fd.close()
    except Exception:
        pass

if not selected:
    sys.exit(1)

for i in sorted(selected):
    print(items[i])
' "$menu_prompt" "$max_select" "${items[@]}"
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
