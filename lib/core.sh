# lib/core.sh — Colors, logging, banner
# Sourced by harn.sh — do not execute directly

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

_print_banner() {
  python3 - "$HARN_VERSION" <<'PYEOF'
import sys, os, struct, fcntl, termios

version = sys.argv[1] if len(sys.argv) > 1 else ""

def get_cols():
    for fd in (1, 0, 2):
        try:
            buf = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)
            _, cols = struct.unpack("HH", buf[:4])
            if cols > 0:
                return cols
        except Exception:
            pass
    return 80

cols = get_cols()

# Colors
R  = "\033[0m"
B  = "\033[1m"
D  = "\033[2m"
C  = "\033[0;36m"
G  = "\033[0;32m"
M  = "\033[0;35m"
W  = "\033[1;37m"
Y  = "\033[0;33m"

# ASCII logo — compact, modern
logo = [
    f"{M}  ██╗  ██╗ █████╗ ██████╗ ███╗   ██╗{R}",
    f"{M}  ██║  ██║██╔══██╗██╔══██╗████╗  ██║{R}",
    f"{W}  ███████║███████║██████╔╝██╔██╗ ██║{R}",
    f"{C}  ██╔══██║██╔══██║██╔══██╗██║╚██╗██║{R}",
    f"{C}  ██║  ██║██║  ██║██║  ██║██║ ╚████║{R}",
    f"{D}  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝{R}",
]

print()
for line in logo:
    print(line)
print()
print(f"  {W}harn{R} {D}v{version}{R}  {D}·{R}  {D}AI Multi-Agent Sprint Loop{R}")
print()
PYEOF
}
