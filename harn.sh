#!/usr/bin/env bash
# harn — AI 멀티 에이전트 스프린트 개발 루프
#
#   기획자  → 개발자 → 평가자 루프를 자동화해 백로그 항목을 스프린트 단위로 구현
#
# 사용법:  harn <command>
#   harn start      백로그 항목 선택 후 실행
#   harn auto       자동 모드 (재개 / 시작 / 발굴)
#   harn backlog    대기 항목 표시
#   harn status     현재 상태
#   harn help       전체 도움말

set -euo pipefail

HARN_VERSION="1.0.0"

# 심볼릭 링크를 해석해 스크립트의 실제 위치를 찾음
_THIS="${BASH_SOURCE[0]}"
while [[ -L "$_THIS" ]]; do _THIS="$(readlink "$_THIS")"; done
SCRIPT_DIR="$(cd "$(dirname "$_THIS")" && pwd)"
ROOT_DIR="$(pwd)"
HARNESS_DIR="$ROOT_DIR/.harness"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
CONFIG_FILE="$ROOT_DIR/.harness_config"

# 기본값 (config 로드 전)
BACKLOG_FILE="$ROOT_DIR/docs/planner/sprint-backlog.md"
BACKLOG_FILE_DISPLAY="${BACKLOG_FILE}"
MAX_ITERATIONS=5
GIT_ENABLED="false"
GIT_BASE_BRANCH="main"
GIT_UPSTREAM_REMOTE="upstream"
GIT_PLAN_PREFIX="plan/"
GIT_FEAT_PREFIX="feat/"
GIT_AUTO_PUSH="false"
GIT_AUTO_PR="false"
GIT_PR_DRAFT="true"
GIT_AUTO_MERGE="false"
CUSTOM_PROMPTS_DIR=""

# 회고 억제 플래그 (harn all 에서 개별 항목 회고 방지용)
HARN_SKIP_RETRO="false"

# 역할별 모델 기본값 (config 또는 env 로 오버라이드 가능)
COPILOT_MODEL_PLANNER="claude-haiku-4.5"
COPILOT_MODEL_GENERATOR_CONTRACT="claude-sonnet-4.6"
COPILOT_MODEL_GENERATOR_IMPL="claude-opus-4.6"
COPILOT_MODEL_EVALUATOR_CONTRACT="claude-haiku-4.5"
COPILOT_MODEL_EVALUATOR_QA="claude-sonnet-4.5"

# ── 로그 설정 ──────────────────────────────────────────────────────────────────
mkdir -p "$HARNESS_DIR"
LOG_FILE="$HARNESS_DIR/harness.log"

# ── 색상 & 스타일 ──────────────────────────────────────────────────────────────
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

# 사용자 지시사항 세션 버퍼
USER_EXTRA_INSTRUCTIONS=""

# ── 로그 함수 ──────────────────────────────────────────────────────────────────
_ts()      { date '+%H:%M:%S'; }
_log_raw() { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"; }

log_info() { _log_raw "  ${D}$(_ts)${N}  $*"; }
log_ok()   { _log_raw "  ${G}✓${N}  $*"; }
log_warn() { _log_raw "  ${Y}⚠${N}  $*"; }
log_err()  { _log_raw "  ${R}✗${N}  $*" >&2; }

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
  # 터미널 출력 + 로그 파일 기록 (ANSI 제거)
  echo -e "$output"
  echo -e "$output" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

log_agent_done() {
  _log_raw ""
  _log_raw "${D}  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌${N}"
}

# ── 배너 ───────────────────────────────────────────────────────────────────────
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
subtitle = "AI 멀티 에이전트 스프린트 루프"

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

# ── 스프린트 진행률 ────────────────────────────────────────────────────────────
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

# ── 사용자 지시사항 입력 ────────────────────────────────────────────────────────
_ask_user_instructions() {
  local context="${1:-다음 에이전트}"

  # 비대화형 환경(파이프, CI 등)이면 스킵
  [[ ! -t 1 ]] && return 0

  echo -e "" >/dev/tty
  echo -e "${B}  ╭─ 💬 추가 지시사항${N}" >/dev/tty
  echo -e "${B}  │${N}  ${W}${context}${N}에게 전달할 내용을 입력하세요." >/dev/tty
  echo -e "${B}  │${N}  ${D}빈 줄 = 건너뛰기  ·  여러 줄 입력 가능${N}" >/dev/tty
  echo -e "${B}  ╰${N}" >/dev/tty

  local content
  content=$(_input_multiline)

  if [[ -n "$content" ]]; then
    USER_EXTRA_INSTRUCTIONS="${USER_EXTRA_INSTRUCTIONS}
## 사용자 지시사항 ($(_ts))

${content}"
    echo -e "  ${G}✓${N}  다음 에이전트에 전달됩니다." >/dev/tty
    echo -e "" >/dev/tty
  fi
}

# ── Python readline 기반 입력 헬퍼 ─────────────────────────────────────────────
# readline/libedit을 통해 한국어 등 멀티바이트 문자의 백스페이스를 올바르게 처리

# 단일 줄 입력 — raw mode + 직접 wide-char 백스페이스 처리
# (macOS libedit은 한국어 2컬럼 문자 백스페이스를 잘못 처리함)
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
    pass
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
fd.close()
result = "".join(chars)
if result: print(result, end="")
'
}

# 여러 줄 입력 (빈 줄로 완료) — raw mode + wide-char 백스페이스
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

# ── 역할별 모델 설정 ─────────────────────────────────────────────────────────

validate_role_models() {
  : # 모든 역할이 copilot 고정 — 별도 검증 불필요
}

print_model_config() {
  echo -e "${W}Harness Role Model Config${N}"
  echo -e "  planner               : ${W}copilot / $COPILOT_MODEL_PLANNER${N}       (env: HARNESS_COPILOT_MODEL_PLANNER)"
  echo -e "  generator (contract)  : ${W}copilot / $COPILOT_MODEL_GENERATOR_CONTRACT${N}  (env: HARNESS_COPILOT_MODEL_GENERATOR_CONTRACT)"
  echo -e "  generator (implement) : ${W}copilot / $COPILOT_MODEL_GENERATOR_IMPL${N}     (env: HARNESS_COPILOT_MODEL_GENERATOR_IMPL)"
  echo -e "  evaluator (contract)  : ${W}copilot / $COPILOT_MODEL_EVALUATOR_CONTRACT${N}  (env: HARNESS_COPILOT_MODEL_EVALUATOR_CONTRACT)"
  echo -e "  evaluator (qa)        : ${W}copilot / $COPILOT_MODEL_EVALUATOR_QA${N}       (env: HARNESS_COPILOT_MODEL_EVALUATOR_QA)"
}

# ── 설정 로드 ──────────────────────────────────────────────────────────────────

load_config() {
  [[ ! -f "$CONFIG_FILE" ]] && return

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # 상대 경로로 저장된 BACKLOG_FILE → 절대 경로 변환
  if [[ -n "${BACKLOG_FILE:-}" && "${BACKLOG_FILE}" != /* ]]; then
    BACKLOG_FILE="$ROOT_DIR/$BACKLOG_FILE"
  fi
  BACKLOG_FILE_DISPLAY="$BACKLOG_FILE"

  # config 파일의 MODEL_* 변수 → 내부 COPILOT_MODEL_* 에 적용 (env 오버라이드 우선)
  COPILOT_MODEL_PLANNER="${HARNESS_COPILOT_MODEL_PLANNER:-${MODEL_PLANNER:-$COPILOT_MODEL_PLANNER}}"
  COPILOT_MODEL_GENERATOR_CONTRACT="${HARNESS_COPILOT_MODEL_GENERATOR_CONTRACT:-${MODEL_GENERATOR_CONTRACT:-$COPILOT_MODEL_GENERATOR_CONTRACT}}"
  COPILOT_MODEL_GENERATOR_IMPL="${HARNESS_COPILOT_MODEL_GENERATOR_IMPL:-${MODEL_GENERATOR_IMPL:-$COPILOT_MODEL_GENERATOR_IMPL}}"
  COPILOT_MODEL_EVALUATOR_CONTRACT="${HARNESS_COPILOT_MODEL_EVALUATOR_CONTRACT:-${MODEL_EVALUATOR_CONTRACT:-$COPILOT_MODEL_EVALUATOR_CONTRACT}}"
  COPILOT_MODEL_EVALUATOR_QA="${HARNESS_COPILOT_MODEL_EVALUATOR_QA:-${MODEL_EVALUATOR_QA:-$COPILOT_MODEL_EVALUATOR_QA}}"

  # 커스텀 프롬프트 디렉터리 적용
  if [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]]; then
    local custom_abs="$CUSTOM_PROMPTS_DIR"
    [[ "${CUSTOM_PROMPTS_DIR}" != /* ]] && custom_abs="$ROOT_DIR/$CUSTOM_PROMPTS_DIR"
    [[ -d "$custom_abs" ]] && PROMPTS_DIR="$custom_abs"
  fi
}

# ── 커스텀 프롬프트 생성 ───────────────────────────────────────────────────────

# AI CLI를 감지해 반환 (copilot 우선, 없으면 claude)
_detect_ai_cli() {
  if command -v copilot &>/dev/null; then echo "copilot"
  elif command -v claude &>/dev/null; then echo "claude"
  else echo ""
  fi
}

# AI CLI로 단일 프롬프트 생성
_ai_generate() {
  local ai_cmd="$1" prompt_text="$2" out_file="$3"
  case "$ai_cmd" in
    copilot) copilot --yolo -p "$prompt_text" > "$out_file" 2>/dev/null ;;
    claude)  claude -p "$prompt_text" > "$out_file" 2>/dev/null ;;
  esac
}

# 에이전트별 지침 + Git 지침을 바탕으로 커스텀 프롬프트 파일 생성
_generate_custom_prompts() {
  local hint_planner="$1" hint_generator="$2" hint_evaluator="$3" git_guide="$4"
  local custom_dir="$ROOT_DIR/.harness/prompts"
  mkdir -p "$custom_dir"

  local ai_cmd
  ai_cmd=$(_detect_ai_cli)

  local roles="planner generator evaluator"
  for role in $roles; do
    local base="$PROMPTS_DIR/${role}.md"
    local out="$custom_dir/${role}.md"

    # 역할별 힌트 선택
    local hint=""
    case "$role" in
      planner)   hint="$hint_planner" ;;
      generator) hint="$hint_generator" ;;
      evaluator) hint="$hint_evaluator" ;;
    esac

    # 추가 지침 조합
    local extra=""
    [[ -n "$git_guide" ]] && extra="${extra}
**Git 워크플로우 지침**: ${git_guide}"
    [[ -n "$hint"      ]] && extra="${extra}
**특별 지침**: ${hint}"

    # 지침 없으면 기본 프롬프트 복사
    if [[ -z "$extra" ]]; then
      cp "$base" "$out"
      continue
    fi

    local role_kr
    case "$role" in
      planner)   role_kr="기획자" ;;
      generator) role_kr="개발자" ;;
      evaluator) role_kr="평가자" ;;
    esac

    log_info "${role_kr} 프롬프트 생성 중..."

    if [[ -n "$ai_cmd" ]]; then
      local gen_prompt
      gen_prompt="아래는 ${role_kr} 에이전트의 기본 프롬프트입니다.

$(cat "$base")

---

다음 지침을 프롬프트에 자연스럽게 통합하여 수정된 프롬프트 전체를 출력하세요.
마크다운 코드블록(\`\`\`) 없이 프롬프트 내용만 출력하세요.

추가할 지침:
${extra}"

      if _ai_generate "$ai_cmd" "$gen_prompt" "$out"; then
        log_ok "${role_kr} 프롬프트 생성됨: ${W}$out${N}"
      else
        log_warn "${role_kr} 프롬프트 생성 실패 — 기본 프롬프트에 지침 추가"
        cp "$base" "$out"
        printf "\n\n## 추가 지침\n%s\n" "$extra" >> "$out"
      fi
    else
      # AI CLI 없으면 기본 프롬프트 뒤에 지침 직접 추가
      cp "$base" "$out"
      printf "\n\n## 추가 지침\n%s\n" "$extra" >> "$out"
      log_ok "${role_kr} 프롬프트 생성됨 (수동 추가): ${W}$out${N}"
    fi
  done
}

# ── 초기화 마법사 ──────────────────────────────────────────────────────────────

cmd_init() {
  echo -e "\n${W}══════════════════════════════════════════${N}"
  echo -e "${W}  harn 초기 설정${N}"
  echo -e "${W}══════════════════════════════════════════${N}"
  echo -e "프로젝트 루트: ${W}$ROOT_DIR${N}"
  echo -e "설정 파일:     ${W}$CONFIG_FILE${N}\n"

  if [[ -f "$CONFIG_FILE" ]]; then
    printf "${Y}이미 설정 파일이 존재합니다. 덮어쓰시겠습니까? [y/N]: ${N}"
    local ow; ow=$(_input_readline)
    echo ""
    [[ "$ow" == "y" || "$ow" == "Y" ]] || { log_info "초기화 취소됨"; return 0; }
  fi

  # ── 프로젝트 기본 설정 ───────────────────────────────────────────────────────
  local bf_default="docs/planner/sprint-backlog.md"
  printf "백로그 파일 경로 (프로젝트 루트 기준) [%s]: " "$bf_default"
  local bf_input; bf_input=$(_input_readline); echo ""
  local bf="${bf_input:-$bf_default}"

  printf "QA 최대 재시도 횟수 [5]: "
  local mi_input; mi_input=$(_input_readline); echo ""
  local mi="${mi_input:-5}"

  # ── AI 모델 설정 ─────────────────────────────────────────────────────────────
  echo -e "\n${W}AI 모델 설정${N} (엔터 = 기본값 사용)"
  printf "기획자 모델       [claude-haiku-4.5]: "
  local mp; mp=$(_input_readline); echo ""; mp="${mp:-claude-haiku-4.5}"

  printf "개발자 모델(협의) [claude-sonnet-4.6]: "
  local mgc; mgc=$(_input_readline); echo ""; mgc="${mgc:-claude-sonnet-4.6}"

  printf "개발자 모델(구현) [claude-opus-4.6]: "
  local mgi; mgi=$(_input_readline); echo ""; mgi="${mgi:-claude-opus-4.6}"

  printf "평가자 모델(협의) [claude-haiku-4.5]: "
  local mec; mec=$(_input_readline); echo ""; mec="${mec:-claude-haiku-4.5}"

  printf "평가자 모델(QA)   [claude-sonnet-4.5]: "
  local meq; meq=$(_input_readline); echo ""; meq="${meq:-claude-sonnet-4.5}"

  # ── Git 통합 ─────────────────────────────────────────────────────────────────
  echo -e "\n${W}Git 통합${N}"
  printf "Git 통합 활성화? [y/N]: "
  local git_yn; git_yn=$(_input_readline); echo ""
  local git_en="false"
  local git_branch="main" git_upstream_remote="upstream" git_auto_push="false" git_auto_pr="false" git_pr_draft="true" git_guide=""

  if [[ "$git_yn" == "y" || "$git_yn" == "Y" ]]; then
    git_en="true"
    printf "베이스 브랜치 [main]: "
    local gb; gb=$(_input_readline); echo ""; git_branch="${gb:-main}"

    printf "Upstream 리모트 이름 [upstream]: "
    local gur; gur=$(_input_readline); echo ""; git_upstream_remote="${gur:-upstream}"

    printf "자동 Push? [y/N]: "
    local gp; gp=$(_input_readline); echo ""
    [[ "$gp" == "y" || "$gp" == "Y" ]] && git_auto_push="true"

    printf "자동 PR 생성? [y/N]: "
    local gpr; gpr=$(_input_readline); echo ""
    [[ "$gpr" == "y" || "$gpr" == "Y" ]] && git_auto_pr="true"

    if [[ "$git_auto_pr" == "true" ]]; then
      printf "PR을 Draft로 생성? [Y/n]: "
      local gprd; gprd=$(_input_readline); echo ""
      [[ "$gprd" == "n" || "$gprd" == "N" ]] && git_pr_draft="false"
    fi

    echo -e "\n${B}Git 워크플로우 지침${N}"
    echo -e "  브랜치 전략, 커밋 컨벤션, PR 규칙 등을 자유롭게 입력하세요."
    echo -e "  이 지침은 모든 에이전트 프롬프트에 반영됩니다. (엔터 = 없음)"
    printf "> "
    git_guide=$(_input_readline); echo ""
  fi

  # ── 에이전트별 특별 지침 ──────────────────────────────────────────────────────
  echo -e "\n${W}에이전트별 특별 지침${N}"
  echo -e "  프로젝트 아키텍처, 기술 스택, 코딩 규칙 등을 입력하세요."
  echo -e "  입력한 지침은 AI CLI가 기본 프롬프트에 자연스럽게 통합합니다. (엔터 = 없음)\n"

  printf "기획자(Planner)   — 스펙/스프린트 계획 관련 지침: "
  local hint_planner; hint_planner=$(_input_readline); echo ""

  printf "개발자(Generator) — 구현 관련 지침: "
  local hint_generator; hint_generator=$(_input_readline); echo ""

  printf "평가자(Evaluator) — QA/검증 관련 지침: "
  local hint_evaluator; hint_evaluator=$(_input_readline); echo ""

  # ── 설정 파일 작성 ───────────────────────────────────────────────────────────
  local cpd=""
  cat > "$CONFIG_FILE" <<CFGEOF
# harn 설정 파일 — $(date '+%Y-%m-%d %H:%M:%S')
# 프로젝트: $ROOT_DIR

# === 프로젝트 설정 ===
BACKLOG_FILE="${bf}"
MAX_ITERATIONS=${mi}

# === AI 모델 설정 ===
MODEL_PLANNER="${mp}"
MODEL_GENERATOR_CONTRACT="${mgc}"
MODEL_GENERATOR_IMPL="${mgi}"
MODEL_EVALUATOR_CONTRACT="${mec}"
MODEL_EVALUATOR_QA="${meq}"

# === Git 통합 ===
GIT_ENABLED="${git_en}"
GIT_BASE_BRANCH="${git_branch}"
GIT_UPSTREAM_REMOTE="${git_upstream_remote}"
GIT_PLAN_PREFIX="plan/"
GIT_FEAT_PREFIX="feat/"
GIT_AUTO_PUSH="${git_auto_push}"
GIT_AUTO_PR="${git_auto_pr}"
GIT_PR_DRAFT="${git_pr_draft}"
GIT_AUTO_MERGE="false"

# === 에이전트 지침 (harn init 으로 재생성 가능) ===
GIT_GUIDE="${git_guide}"
HINT_PLANNER="${hint_planner}"
HINT_GENERATOR="${hint_generator}"
HINT_EVALUATOR="${hint_evaluator}"

# === 커스텀 프롬프트 ===
CUSTOM_PROMPTS_DIR="${cpd}"
CFGEOF

  log_ok "설정 파일 생성됨: ${W}$CONFIG_FILE${N}"

  # ── 커스텀 프롬프트 생성 ──────────────────────────────────────────────────────
  if [[ -n "$hint_planner" || -n "$hint_generator" || -n "$hint_evaluator" || -n "$git_guide" ]]; then
    echo ""
    local ai_cmd; ai_cmd=$(_detect_ai_cli)
    if [[ -n "$ai_cmd" ]]; then
      log_info "AI CLI(${W}${ai_cmd}${N})로 커스텀 프롬프트를 생성합니다..."
    else
      log_warn "AI CLI를 찾을 수 없어 기본 프롬프트에 지침을 직접 추가합니다."
    fi
    _generate_custom_prompts "$hint_planner" "$hint_generator" "$hint_evaluator" "$git_guide"
    cpd=".harness/prompts"
    # config에 CUSTOM_PROMPTS_DIR 업데이트
    sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
  fi

  # 방금 생성한 config 로드
  load_config

  echo ""
  log_ok "초기화 완료!"
  echo -e "  ${W}harn backlog${N}  — 백로그 항목 확인"
  echo -e "  ${W}harn start${N}    — 루프 시작"
  echo ""
}

# ── 백로그 헬퍼 ───────────────────────────────────────────────────────────────

# 대기 중인 항목 slug 목록 (진행 중 → 대기 순)
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

# slug에 해당하는 전체 설명 블록 반환
backlog_item_text() {
  local slug="$1"
  [[ ! -f "$BACKLOG_FILE" ]] && echo "(백로그를 찾을 수 없음)" && return
  python3 - "$BACKLOG_FILE" "$slug" <<'EOF'
import re, sys

content = open(sys.argv[1]).read()
slug = sys.argv[2]

pattern = r'(- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*[^\n]*\n(?:[ \t]+[^\n]*\n)*)'
match = re.search(pattern, content)
if match:
    print(match.group(1).strip())
else:
    print(f'(백로그에서 "{slug}" 항목을 찾을 수 없음)')
EOF
}

# 다음 항목 선택: 진행 중 → 대기 순
backlog_next_slug() {
  backlog_pending_slugs | head -1
}

# 백로그 항목을 완료 처리 [x]
backlog_mark_done() {
  local slug="$1"
  [[ ! -f "$BACKLOG_FILE" ]] && return
  sed -i '' "s/- \[ \] \*\*${slug}\*\*/- [x] **${slug}**/" "$BACKLOG_FILE"
  log_ok "백로그: ${W}$slug${N} 완료 처리됨"
}

# 선택된 백로그 항목에 plan 라인을 upsert (In Progress 항목 우선)
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

# ── 실행 관리 ──────────────────────────────────────────────────────────────────
mkdir -p "$HARNESS_DIR/runs"

current_run_id() {
  [[ -L "$HARNESS_DIR/current" ]] && basename "$(readlink "$HARNESS_DIR/current")" || echo ""
}

require_run_dir() {
  local id
  id=$(current_run_id)
  [[ -z "$id" ]] && { log_err "활성 실행 없음. 사용: harn start"; exit 1; }
  echo "$HARNESS_DIR/runs/$id"
}

# LOG_FILE을 서브셸이 아닌 현재 셸에서 직접 호출해야 함
sync_run_log() {
  local id
  id=$(current_run_id)
  [[ -z "$id" ]] && return 0
  LOG_FILE="$HARNESS_DIR/runs/$id/run.log"
  touch "$LOG_FILE"
  ln -sfn "$LOG_FILE" "$HARNESS_DIR/current.log"
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

# ── 실시간 마크다운 컬러 렌더러 ───────────────────────────────────────────────
# 파이프 stdin → md_stream.py → 컬러 렌더링 stdout
# 로그 파일엔 ANSI 코드 없이 저장, 터미널엔 컬러로 출력
_md_stream() {
  python3 -u "$SCRIPT_DIR/parser/md_stream.py"
}

# ── 에이전트 호출 ──────────────────────────────────────────────────────────────
invoke_copilot() {
  local prompt_input="$1" output_file="$2" role="${3:-구현 중...}" prompt_mode="${4:-file}" copilot_model="${5:-}" copilot_effort="${6:-}"
  local prompt_text="$prompt_input"
  if [[ "$prompt_mode" == "file" ]]; then
    prompt_text="$(cat "$prompt_input")"
  fi

  local copilot_label="copilot"
  [[ -n "$copilot_model" ]] && copilot_label="copilot ($copilot_model)"
  log_agent_start "$copilot_label" "$role" "출력 → $(basename "$output_file")"

  local -a copilot_cmd=(copilot --add-dir "$ROOT_DIR" --yolo -p "$prompt_text")
  [[ -n "$copilot_effort" ]] && copilot_cmd+=(--effort "$copilot_effort")
  local use_env_model_fallback="false"
  if [[ -n "$copilot_model" ]]; then
    if copilot_supports_model_flag; then
      copilot_cmd+=(--model "$copilot_model")
    else
      # 구버전 CLI 폴백: COPILOT_MODEL 환경변수로 모델 지정
      use_env_model_fallback="true"
      log_warn "copilot --model 미지원으로 COPILOT_MODEL 폴백 사용: $copilot_model"
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
    log_warn "copilot 이 비정상 종료됨 (exit $exit_code) — 출력: $(basename "$output_file")"
  fi
  log_agent_done "$copilot_label"
  return $exit_code
}

invoke_role() {
  local role_key="$1" prompt_input="$2" output_file="$3" role_label="$4" prompt_mode="${5:-inline}" copilot_model="${6:-}"
  local copilot_effort=""
  [[ "$role_key" == "generator" ]] && copilot_effort="high"
  invoke_copilot "$prompt_input" "$output_file" "$role_label" "$prompt_mode" "$copilot_model" "$copilot_effort"
}

# ── 커맨드 ─────────────────────────────────────────────────────────────────────

cmd_backlog() {
  [[ ! -f "$BACKLOG_FILE" ]] && { log_err "백로그를 찾을 수 없음: $BACKLOG_FILE"; exit 1; }
  echo -e "${W}대기 중인 백로그 항목:${N}"
  local slugs
  slugs=$(backlog_pending_slugs)
  if [[ -z "$slugs" ]]; then
    echo "  (없음 — 모두 완료!)"
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
  echo -e "실행: ${W}harn start${N} — 백로그 항목 선택 후 전체 루프 실행"
}

cmd_start() {
  local slug_or_prompt="${1:-}"
  local max_sprints="${2:-10}"
  local max_sprints_arg="${2:-}"

  # 인수 없으면 백로그 목록 보여주고 번호 입력받기
  if [[ -z "$slug_or_prompt" ]]; then
    if [[ ! -f "$BACKLOG_FILE" ]]; then
      log_err "백로그 파일을 찾을 수 없습니다: $BACKLOG_FILE"
      exit 1
    fi

    local slugs
    slugs=$(backlog_pending_slugs)
    if [[ -z "$slugs" ]]; then
      log_warn "백로그에 대기 중인 항목이 없습니다. 항목을 먼저 추가하세요."
      log_info "발굴하려면: harn discover"
      exit 1
    fi

    echo -e "\n${W}백로그 항목 선택${N}"
    echo -e "${B}──────────────────────────────${N}"
    local i=1
    local slug_array=()
    while IFS= read -r s; do
      echo -e "  ${W}$i.${N} ${Y}$s${N}"
      slug_array+=("$s")
      i=$(( i + 1 ))
    done <<< "$slugs"
    echo ""
    printf "번호 입력 (1–${#slug_array[@]}): "
    local choice; choice=$(_input_readline); echo ""

    if [[ "$choice" =~ ^[0-9]+$ ]] && \
       [[ "$choice" -ge 1 ]] && \
       [[ "$choice" -le "${#slug_array[@]}" ]]; then
      slug_or_prompt="${slug_array[$(( choice - 1 ))]}"
      log_info "선택됨: ${W}$slug_or_prompt${N}"
    else
      log_err "잘못된 입력: $choice"
      exit 1
    fi
  fi

  local run_id
  run_id=$(date +%Y%m%d-%H%M%S)
  local run_dir="$HARNESS_DIR/runs/$run_id"

  mkdir -p "$run_dir/sprints"
  echo "$slug_or_prompt" > "$run_dir/prompt.txt"
  echo "1" > "$run_dir/current_sprint"

  # 이번 실행 전용 로그 (current.log → 이번 실행 로그로 심볼릭 링크)
  local run_log="$run_dir/run.log"
  ln -sfn "$run_log" "$HARNESS_DIR/current.log"
  LOG_FILE="$run_log"

  {
    echo "════════════════════════════════════════════════════════════"
    echo "  Servan Sprint Harness"
    echo "  실행 ID  : $run_id"
    echo "  항목     : $slug_or_prompt"
    echo "  시작     : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════"
  } | tee -a "$LOG_FILE"

  ln -sfn "$run_dir" "$HARNESS_DIR/current"
  log_ok "실행 생성됨: $run_id  (${W}$slug_or_prompt${N})"
  log_info "로그 실시간 확인: ${W}harn tail${N}  →  $run_log"

  if ! cmd_plan; then
    log_err "초기 기획 단계에서 실패했습니다. 로그를 확인한 뒤 재시도하세요: $run_log"
    return 1
  fi

  # start 인자로 최대 스프린트를 주지 않았다면, 백로그 기준으로 자동 계산해
  # '시작부터 완료까지' 한 번에 진행되도록 기본값을 보정한다.
  if [[ -z "$max_sprints_arg" ]]; then
    local planned_total
    planned_total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    if [[ "$planned_total" -gt 0 ]]; then
      max_sprints="$planned_total"
    fi
  fi

  log_step "자동 실행 시작"
  log_info "초기화가 완료되어 스프린트 루프를 자동으로 실행합니다 (contract → implement → evaluate → next, 최대 ${max_sprints} 스프린트)."

  if ! _run_sprint_loop "$max_sprints"; then
    log_err "자동 스프린트 루프가 중단되었습니다. 실패 지점을 확인한 뒤 'harn resume $(basename "$run_dir")'로 재개하세요."
    return 1
  fi

  if [[ -f "$run_dir/completed" ]]; then
    log_ok "harn start 전체 자동 실행 완료"
  else
    log_warn "최대 스프린트 수(${max_sprints})에 도달해 자동 실행을 종료했습니다. 계속하려면 'harn start'를 실행하세요."
  fi
}

cmd_plan() {
  local run_dir
  run_dir=$(require_run_dir)
  local slug_or_prompt
  slug_or_prompt=$(cat "$run_dir/prompt.txt")

  log_step "기획 단계"

  local context_block
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    local item_text
    item_text=$(backlog_item_text "$slug_or_prompt")
    context_block="## 백로그 항목

\`\`\`
$item_text
\`\`\`

## 전체 백로그 (참고용)

$(cat "$BACKLOG_FILE")
"
  else
    context_block="## 요청 내용

$slug_or_prompt"
  fi

  local prompt
  prompt="$(cat "$PROMPTS_DIR/planner.md")

---

$context_block

---

## 출력 지침

아래 세 섹션 마커를 정확히 사용하여 출력하세요:

=== plan.text ===
[한 줄 계획 텍스트. 마크다운 없이 평문으로 작성]

=== spec.md ===
[제품 스펙 내용]

=== sprint-backlog.md ===
[스프린트 백로그 내용]"

  local raw="$run_dir/plan-raw.md"
  invoke_role "planner" "$prompt" "$raw" "기획자 — 백로그 항목을 스프린트 스펙으로 확장" "inline" "$COPILOT_MODEL_PLANNER"

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
    log_warn "plan.text를 찾지 못해 slug/prompt를 plan 텍스트로 대체합니다"
  fi
  echo "$plan_text" > "$run_dir/plan.txt"

  if [[ ! -s "$run_dir/spec.md" ]]; then
    cp "$raw" "$run_dir/spec.md"
    log_warn "섹션 마커를 찾을 수 없음 — 전체 출력을 spec.md로 저장"
  fi

  log_ok "스펙 → $run_dir/spec.md"
  log_ok "스프린트 백로그 → $run_dir/sprint-backlog.md"
  log_ok "플랜 텍스트 → $run_dir/plan.txt"

  # 기획 완료 → 백로그 항목 Pending → In Progress 이동
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    python3 - "$BACKLOG_FILE" "$slug_or_prompt" <<'PYEOF'
import re, sys
path, slug = sys.argv[1], sys.argv[2]
content = open(path).read()

# Pending 섹션에서 In Progress 섹션으로 이동
item_pattern = re.compile(
    r'(- \[ \] \*\*' + re.escape(slug) + r'\*\*[^\n]*(?:\n[ \t]+[^\n]*)*)',
    re.MULTILINE
)
match = item_pattern.search(content)
if not match:
    print(f'항목을 찾을 수 없음: {slug}')
    sys.exit(0)

item_text = match.group(1)
# 원래 위치에서 제거
content = content[:match.start()] + content[match.end():]

# In Progress 섹션 아래에 추가 (없으면 생성)
if '## In Progress' in content:
    content = content.replace('## In Progress\n', '## In Progress\n' + item_text + '\n')
else:
    content = '## In Progress\n' + item_text + '\n\n' + content

open(path, 'w').write(content)
print(f'✓ {slug} → In Progress')
PYEOF
    log_ok "백로그: ${W}$slug_or_prompt${N} → In Progress"

    if backlog_upsert_plan_line "$slug_or_prompt" "$plan_text"; then
      log_ok "백로그 plan 라인 업데이트: ${W}$slug_or_prompt${N}"
    else
      case "$?" in
        2) log_warn "백로그 plan 업데이트 실패: slug를 찾지 못함 (${W}$slug_or_prompt${N})" ;;
        3) log_info "백로그 plan 라인 변경 없음 (이미 최신)" ;;
        *) log_warn "백로그 plan 업데이트 중 예외 발생 (slug=${W}$slug_or_prompt${N})" ;;
      esac
    fi

  fi

  # Git 브랜치 생성, 백로그 커밋, Draft PR 생성
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    _git_setup_plan_branch "$slug_or_prompt" "$run_dir" "$plan_text"
  fi

  log_ok "기획 완료"
}

cmd_contract() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ -f "$sprint/contract.md" ]] && {
    log_warn "스코프이 이미 존재합니다. 재작성하려면 $sprint/contract.md 를 삭제하세요."
    return 0
  }

  log_step "스프린트 $sprint_num — 스코프 협의"

  local prev_context=""
  for s in "$run_dir/sprints"/*/; do
    [[ "$s" == "$sprint"/ ]] && continue
    [[ -d "$s" ]] || continue
    local sn; sn=$(basename "$s")
    prev_context+="### 스프린트 $sn
$(cat "$s/handoff.md" 2>/dev/null || cat "$s/contract.md" 2>/dev/null || echo "(정보 없음)")

"
  done

  local gen_prompt_file="$sprint/contract-gen-prompt.md"
  cat > "$gen_prompt_file" <<EOF
$(cat "$PROMPTS_DIR/generator.md")

---

## 제품 스펙

$(cat "$run_dir/spec.md")

## 스프린트 백로그

$(cat "$run_dir/sprint-backlog.md" 2>/dev/null || echo "")

## 이전 스프린트 컨텍스트

$prev_context

---

## 작업 지시

당신은 **개발자(Generator)**입니다. **스프린트 $sprint_num**에 대한 상세 스코프을 제안하세요.

포함 항목:
1. **스프린트 목표** — 한 문장
2. **구현할 기능** — 구체적인 산출물
3. **PASS 기준** — 번호 매김, 구체적, 검증 가능
4. **패키지/파일** — 생성 또는 수정할 항목
5. **범위 외** — 명시적으로 제외되는 항목

구체적으로 작성하세요. 평가자가 각 PASS 기준을 개별 검토합니다.
EOF

  # 사용자 추가 지시사항 주입
  if [[ -n "$USER_EXTRA_INSTRUCTIONS" ]]; then
    printf "\n\n---\n%s\n" "$USER_EXTRA_INSTRUCTIONS" >> "$gen_prompt_file"
    USER_EXTRA_INSTRUCTIONS=""
  fi

  invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal.md" "개발자 — 스프린트 $sprint_num 스코프 제안" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT"

  log_info "평가자가 스코프을 검토 중..."
  local eval_prompt
  eval_prompt="$(cat "$PROMPTS_DIR/evaluator.md")

---

## 작업: 스프린트 스코프 검토

### 스프린트 $sprint_num 스코프 제안

$(cat "$sprint/contract-proposal.md")

**명확하고 검증 가능하면**: 독립 줄에 \`APPROVED\`를 쓰고 간단히 확인하세요.
**수정이 필요하면**: 독립 줄에 \`NEEDS_REVISION\`을 쓰고 구체적인 수정 사항을 나열하세요."

  invoke_role "evaluator" "$eval_prompt" "$sprint/contract-review.md" "평가자 — 스프린트 $sprint_num 스코프 검토" "inline" "$COPILOT_MODEL_EVALUATOR_CONTRACT"

  if grep -qi 'APPROVED' "$sprint/contract-review.md"; then
    cp "$sprint/contract-proposal.md" "$sprint/contract.md"
    log_ok "스프린트 $sprint_num 스코프 승인됨"
  else
    log_warn "스코프 수정 필요 — 수정 중..."
    cat >> "$gen_prompt_file" <<EOF

---

## 평가자 피드백

$(cat "$sprint/contract-review.md")

위 피드백을 반영하여 스코프을 수정해 주세요.
EOF
    invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal-v2.md" "개발자 — 스프린트 $sprint_num 스코프 수정" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT"
    cp "$sprint/contract-proposal-v2.md" "$sprint/contract.md"
    log_ok "스프린트 $sprint_num 스코프 수정 완료"
  fi

  log_info "다음 단계: harn implement"
}

cmd_implement() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ ! -f "$sprint/contract.md" ]] && {
    log_err "스프린트 $sprint_num 의 스코프이 없습니다. 실행: harn contract"
    exit 1
  }

  local iteration
  iteration=$(( $(sprint_iteration "$sprint") + 1 ))
  echo "$iteration" > "$sprint/iteration"

  log_step "스프린트 $sprint_num — 개발 (반복 $iteration)"

  local qa_feedback=""
  if [[ $iteration -gt 1 && -f "$sprint/qa-report.md" ]]; then
    qa_feedback="## 평가자 피드백 (반복 $((iteration - 1)))

$(cat "$sprint/qa-report.md")

**위의 FAIL 기준을 모두 해결하세요.**"
  fi

  local prev_handoff=""
  local prev_num=$(( sprint_num - 1 ))
  if [[ -d "$run_dir/sprints/$(printf '%03d' "$prev_num")" ]]; then
    prev_handoff="## 이전 스프린트 인계서

$(cat "$run_dir/sprints/$(printf '%03d' "$prev_num")/handoff.md" 2>/dev/null || echo "(없음)")"
  fi

  local prompt_file="$sprint/gen-prompt-iter${iteration}.md"
  cat > "$prompt_file" <<EOF
$(cat "$PROMPTS_DIR/generator.md")

---

## 제품 스펙

$(cat "$run_dir/spec.md")

## 스프린트 $sprint_num 스코프

$(cat "$sprint/contract.md")

$prev_handoff

$qa_feedback

---

## 작업 지시

위 스코프에 따라 **스프린트 $sprint_num**을 구현하세요.
구현 완료 후 끝에 요약을 작성하세요:

=== 구현 요약 ===
- 구현한 내용
- 생성/수정한 주요 파일
- 알려진 제약 사항
EOF

  # 사용자 추가 지시사항 주입
  if [[ -n "$USER_EXTRA_INSTRUCTIONS" ]]; then
    printf "\n\n---\n%s\n" "$USER_EXTRA_INSTRUCTIONS" >> "$prompt_file"
    USER_EXTRA_INSTRUCTIONS=""
  fi

  echo "in-progress" > "$sprint/status"

  # 최초 구현: Opus (IMPL), QA FAIL 재시도: Sonnet (CONTRACT)
  local impl_model="$COPILOT_MODEL_GENERATOR_IMPL"
  [[ $iteration -gt 1 ]] && impl_model="$COPILOT_MODEL_GENERATOR_CONTRACT"

  invoke_role "generator" "$prompt_file" "$sprint/implementation-iter${iteration}.md" "개발자 — 스프린트 $sprint_num 구현 (반복 $iteration)" "file" "$impl_model"
  cp "$sprint/implementation-iter${iteration}.md" "$sprint/implementation.md"

  log_ok "스프린트 $sprint_num 구현 완료 (반복 $iteration)"

  # 구현 결과 Git 커밋
  _git_commit_sprint_impl "$sprint_num" "$sprint"

  log_info "다음 단계: harn evaluate"
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
    log_err "스프린트 $sprint_num 의 구현 결과가 없습니다. 실행: harn implement"
    exit 1
  }

  log_step "스프린트 $sprint_num — 검증 (반복 $iteration)"

  log_info "자동 검사 실행 중..."
  local test_results="$sprint/test-results.txt"
  {
    cd "$ROOT_DIR"

    echo "=== dart analyze ==="
    dart analyze 2>&1 | tail -30 || true
    echo ""

    # 마지막 스프린트(테스트 스프린트)이면 서비스 기동 + E2E 검증 실행
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    if [[ "$sprint_num" -eq "$total" ]]; then

      echo "=== flutter test (단위/위젯 테스트) ==="
      flutter test --reporter compact 2>&1 | tail -50 || true
      echo ""

      # ── 백엔드 서버 기동 ──────────────────────────────────────────
      echo "=== 백엔드 서버 시작 (port 8080) ==="
      local backend_pid=""
      if [[ -f "$ROOT_DIR/services/backend/bin/main.dart" ]]; then
        PORT=8080 dart run "$ROOT_DIR/services/backend/bin/main.dart" \
          >> "$sprint/backend.log" 2>&1 &
        backend_pid=$!
        echo "백엔드 PID: $backend_pid"
        # 준비 대기 (최대 30초)
        local i=0
        while [[ $i -lt 30 ]]; do
          curl -sf http://localhost:8080/health > /dev/null 2>&1 && break || true
          sleep 1; i=$(( i + 1 ))
        done
        curl -sf http://localhost:8080/health > /dev/null 2>&1 \
          && echo "백엔드 준비 완료" \
          || echo "백엔드 헬스체크 실패 — 로그: $sprint/backend.log"
      fi
      echo ""

      # ── MCP 서버 기동 (HTTP 모드) ─────────────────────────────────
      echo "=== MCP 서버 시작 (port 8181) ==="
      local mcp_pid=""
      if [[ -f "$ROOT_DIR/services/mcp/bin/server_http.dart" ]]; then
        PORT=8181 dart run "$ROOT_DIR/services/mcp/bin/server_http.dart" \
          >> "$sprint/mcp.log" 2>&1 &
        mcp_pid=$!
        echo "MCP PID: $mcp_pid"
        sleep 3
        echo "MCP 서버 기동됨"
      fi
      echo ""

      # ── Flutter 웹 앱 기동 ────────────────────────────────────────
      echo "=== Flutter 웹 앱 시작 (port 3000) ==="
      local flutter_pid=""
      local flutter_app_dir="$ROOT_DIR/apps/mobile"
      [[ -d "$ROOT_DIR/apps/web" ]] && flutter_app_dir="$ROOT_DIR/apps/web"
      cd "$flutter_app_dir"
      flutter run -d web-server \
        --web-port 3000 \
        --dart-define=API_BASE_URL=http://localhost:8080 \
        >> "$sprint/flutter-web.log" 2>&1 &
      flutter_pid=$!
      echo "Flutter 웹 PID: $flutter_pid"
      # 준비 대기 (최대 120초)
      local j=0
      while [[ $j -lt 120 ]]; do
        curl -sf http://localhost:3000 > /dev/null 2>&1 && break || true
        sleep 1; j=$(( j + 1 ))
      done
      curl -sf http://localhost:3000 > /dev/null 2>&1 \
        && echo "Flutter 웹 준비 완료 — http://localhost:3000" \
        || echo "Flutter 웹 기동 실패 — 로그: $sprint/flutter-web.log"
      cd "$ROOT_DIR"
      echo ""

      # 기동된 서비스 URL 기록 (평가자가 Playwright MCP 로 접근)
      {
        echo "BACKEND_URL=http://localhost:8080"
        echo "MCP_URL=http://localhost:8181"
        echo "APP_URL=http://localhost:3000"
        [[ -n "$backend_pid" ]] && echo "BACKEND_PID=$backend_pid"
        [[ -n "$mcp_pid" ]]    && echo "MCP_PID=$mcp_pid"
        [[ -n "$flutter_pid" ]] && echo "FLUTTER_PID=$flutter_pid"
      } > "$sprint/e2e-env.txt"
      echo "=== E2E 환경 준비 완료 ==="
      cat "$sprint/e2e-env.txt"
      echo ""
    fi
  } > "$test_results"
  log_info "검사 완료 → $test_results"

  # E2E 환경 컨텍스트 (마지막 스프린트인 경우)
  local e2e_context=""
  if [[ -f "$sprint/e2e-env.txt" ]]; then
    e2e_context="
### E2E 테스트 환경
\`\`\`
$(cat "$sprint/e2e-env.txt")
\`\`\`

위 URL로 기동된 서비스가 있습니다.
**Playwright MCP 툴**을 사용해 http://localhost:3000 앱을 직접 테스트하세요.
- browser_navigate, browser_click, browser_snapshot, browser_screenshot 등 사용 가능
- 백엔드 API는 http://localhost:8080 으로 접근 가능
- 테스트 결과를 리포트에 포함하세요"
  fi

  local eval_prompt
  eval_prompt="$(cat "$PROMPTS_DIR/evaluator.md")

---

## 스프린트 $sprint_num 검증

### 스코프
$(cat "$sprint/contract.md")

### 구현 요약
$(cat "$sprint/implementation.md")

### 자동 검사 결과
\`\`\`
$(cat "$test_results")
\`\`\`
$e2e_context

리포트 마지막 줄에 정확히 한 줄로 작성하세요:
\`VERDICT: PASS\`  또는  \`VERDICT: FAIL\`"

  local eval_exit_code=0
  invoke_role "evaluator" "$eval_prompt" "$sprint/qa-report.md" "평가자 — 스프린트 $sprint_num 검증 (반복 $iteration)" "inline" "$COPILOT_MODEL_EVALUATOR_QA" || eval_exit_code=$?

  # E2E 테스트용 백그라운드 프로세스 정리
  if [[ -f "$sprint/e2e-env.txt" ]]; then
    log_info "E2E 환경 종료 중..."
    while IFS='=' read -r key val; do
      case "$key" in
        BACKEND_PID|MCP_PID|FLUTTER_PID)
          kill "$val" 2>/dev/null && log_info "$key ($val) 종료됨" || true ;;
      esac
    done < "$sprint/e2e-env.txt"
  fi

  if [[ $eval_exit_code -ne 0 ]]; then
    echo "fail" > "$sprint/status"
    log_err "스프린트 $sprint_num: 평가자 실행 오류 (exit $eval_exit_code) — 루프를 중단합니다"
    log_info "수동 재개: 문제 수정 후 harn evaluate  또는  harn implement"
    return 1
  fi

  if grep -qiE 'VERDICT[[:space:]]*:[[:space:]]*PASS' "$sprint/qa-report.md"; then
    echo "pass" > "$sprint/status"
    log_ok "스프린트 $sprint_num: ${G}통과${N}"
    log_info "다음 단계: harn next"
  else
    echo "fail" > "$sprint/status"
    local cur_iter
    cur_iter=$(sprint_iteration "$sprint")
    log_warn "스프린트 $sprint_num: QA ${Y}FAIL${N} (반복 $cur_iter / $MAX_ITERATIONS) — 자동 재시도 중... (리포트: $sprint/qa-report.md)"
  fi
}

# 내부용: 스프린트 카운터만 증가 (auto 내부 스프린트 전환에 사용)
_sprint_advance() {
  local run_dir="$1"
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local next_num=$(( sprint_num + 1 ))
  echo "$next_num" > "$run_dir/current_sprint"
  log_info "스프린트 $next_num 으로 전환"
}

cmd_next() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  log_step "작업 마무리"

  # 최종 요약 작성
  invoke_role "evaluator" "$(cat "$PROMPTS_DIR/evaluator.md")

## 작업: 최종 완료 요약

### 스코프
$(cat "$sprint/contract.md" 2>/dev/null || echo '(없음)')

### 구현 요약
$(cat "$sprint/implementation.md" 2>/dev/null || echo '(없음)')

### QA 리포트
$(cat "$sprint/qa-report.md" 2>/dev/null || echo '(없음)')

전체 작업에 대한 완료 요약(최대 300자)을 작성하세요:
1. 구현된 내용 요약
2. 주요 변경 파일
3. 알려진 한계 또는 후속 과제" \
    "$sprint/handoff.md" "평가자 — 최종 완료 요약" "inline" "$COPILOT_MODEL_EVALUATOR_QA"

  # 백로그 → Done 이동
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
    log_ok "백로그: ${W}$slug_or_prompt${N} → Done"
  fi

  # 완료 플래그 (auto 재개 방지)
  touch "$run_dir/completed"
  rm -f "$HARNESS_DIR/current"

  log_ok "${G}작업 완전 완료: $slug_or_prompt${N}"
}

cmd_stop() {
  local pid_file="$HARNESS_DIR/harness.pid"

  if [[ ! -f "$pid_file" ]]; then
    log_warn "실행 중인 하네스를 찾을 수 없음 (PID 파일 없음)"
    log_info "이미 종료됐거나 harn start 로 시작하지 않은 경우입니다."
    return 0
  fi

  local pid
  pid=$(cat "$pid_file")

  if ! kill -0 "$pid" 2>/dev/null; then
    log_warn "프로세스 PID=$pid 가 이미 종료됨 — PID 파일 정리"
    rm -f "$pid_file"
    return 0
  fi

  log_info "하네스 중지 중... (PID: ${W}$pid${N})"

  # 프로세스 그룹 전체에 SIGTERM (claude/copilot 자식 프로세스 포함)
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 2

  # 아직 살아있으면 SIGKILL
  if kill -0 "$pid" 2>/dev/null; then
    log_warn "SIGTERM 후에도 실행 중 — SIGKILL 전송"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"

  # 현재 스프린트를 cancelled 로 표시
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
    log_ok "실행 ${W}$(basename "$run_dir")${N} 중지됨"
  else
    log_ok "하네스 중지됨"
  fi
}

# Git remote URL을 owner/repo 형식으로 변환
# 예) https://github.com/org/repo.git  →  org/repo
#     git@github.com:org/repo.git      →  org/repo
_git_url_to_nwo() {
  local url="$1"
  echo "$url" \
    | sed 's|\.git$||' \
    | sed 's|^https://[^/]*/||' \
    | sed 's|^git@[^:]*:||'
}

# ── Git 기획 브랜치 생성 & Draft PR ──────────────────────────────────────────
# cmd_plan 완료 후 호출: 브랜치 생성 → 백로그 커밋 → Draft PR 생성
_git_setup_plan_branch() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local slug="$1" run_dir="$2" plan_text="$3"
  local branch="${GIT_PLAN_PREFIX}${slug}"
  local upstream="${GIT_UPSTREAM_REMOTE:-upstream}"

  log_step "Git: 기획 브랜치 생성"

  # 현재 브랜치 확인
  local current_branch
  current_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    log_warn "Git: HEAD를 확인할 수 없어 브랜치 생성을 건너뜁니다"
    return 0
  fi

  # 브랜치 생성 또는 체크아웃
  if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    log_warn "브랜치 ${W}$branch${N} 이미 존재 — 체크아웃합니다"
    git -C "$ROOT_DIR" checkout "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done
  else
    git -C "$ROOT_DIR" checkout -b "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done
    log_ok "브랜치 생성됨: ${W}$branch${N}"
  fi

  # 백로그 파일 커밋 (변경이 있을 때만)
  if [[ -f "$BACKLOG_FILE" ]]; then
    git -C "$ROOT_DIR" add "$BACKLOG_FILE"
    if ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
      git -C "$ROOT_DIR" commit -m "plan: ${slug} — 기획 시작 (sprint backlog 업데이트)" \
        2>&1 | while IFS= read -r line; do log_info "$line"; done
      log_ok "스프린트 백로그 커밋 완료"
    else
      log_info "백로그 파일 변경 없음 — 커밋 생략"
    fi
  fi

  # 브랜치를 origin(fork)에 Push (PR 생성을 위해 필수)
  if ! git -C "$ROOT_DIR" push -u origin "$branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_warn "Push 실패 — Draft PR 생성을 건너뜁니다. 수동으로 push 후 PR을 생성하세요."
    log_info "브랜치: ${W}$branch${N}"
    return 0
  fi
  log_ok "브랜치 Push 완료: origin/${W}$branch${N}"

  # Draft PR 생성 — upstream 리모트의 저장소를 대상으로
  local pr_title="[Plan] ${slug}: ${plan_text}"
  local pr_body
  pr_body=$(cat "$run_dir/spec.md" 2>/dev/null || echo "$plan_text")

  local draft_flag="--draft"
  [[ "$GIT_PR_DRAFT" == "false" ]] && draft_flag=""

  # upstream 리모트 URL → owner/repo 형식으로 변환해 --repo 에 전달
  local upstream_url upstream_nwo
  upstream_url=$(git -C "$ROOT_DIR" remote get-url "$upstream" 2>/dev/null || echo "")
  upstream_nwo=$(_git_url_to_nwo "$upstream_url")

  # fork PR 시 --head 는 fork_owner:branch 형식 필요
  # origin URL 에서 fork owner 추출
  local origin_url fork_owner head_ref
  origin_url=$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || echo "")
  fork_owner=$(_git_url_to_nwo "$origin_url" | cut -d'/' -f1)
  head_ref="$branch"
  [[ -n "$upstream_url" && -n "$fork_owner" ]] && head_ref="${fork_owner}:${branch}"

  log_info "Draft PR 생성 중... (base: ${upstream_nwo:-$upstream}/${GIT_BASE_BRANCH}, head: ${head_ref})"
  local pr_out pr_repo_flag=""
  [[ -n "$upstream_nwo" ]] && pr_repo_flag="--repo $upstream_nwo"

  # shellcheck disable=SC2086
  if pr_out=$(gh pr create \
      $pr_repo_flag \
      --base "$GIT_BASE_BRANCH" \
      --head "$head_ref" \
      --title "$pr_title" \
      --body "$pr_body" \
      $draft_flag 2>&1); then
    log_ok "Draft PR 생성됨: ${W}$pr_out${N}"
    echo "$pr_out" > "$run_dir/pr-url.txt"
  else
    log_warn "PR 생성 실패 — 수동으로 생성하세요"
    log_info "브랜치: origin/${W}$branch${N}  →  ${upstream_nwo:-$upstream}/${W}$GIT_BASE_BRANCH${N}"
    log_info "오류: $pr_out"
  fi
}

# cmd_implement 완료 후 호출: 구현 변경사항 커밋 & push
_git_commit_sprint_impl() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local sprint_num="$1" sprint_dir_path="$2"
  local iteration
  iteration=$(cat "$sprint_dir_path/iteration" 2>/dev/null || echo "1")

  # contract.md 에서 스프린트 목표 한 줄 추출
  local sprint_goal
  sprint_goal=$(grep -m1 '^\*\*Goal\*\*\|^Goal:' "$sprint_dir_path/contract.md" 2>/dev/null \
    | sed 's/^\*\*Goal\*\*[: ]*//;s/^Goal[: ]*//' | xargs)
  [[ -z "$sprint_goal" ]] && sprint_goal="스프린트 ${sprint_num} 구현"

  local commit_msg="feat(sprint-${sprint_num}): ${sprint_goal}"
  [[ "$iteration" -gt 1 ]] && commit_msg="${commit_msg} (retry ${iteration})"

  log_step "Git: 스프린트 $sprint_num 구현 커밋"

  cd "$ROOT_DIR"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    log_info "커밋할 변경사항 없음 — 개발자가 파일을 수정하지 않은 것 같습니다"
    return 0
  fi

  git commit -m "$commit_msg" \
    2>&1 | while IFS= read -r line; do log_info "$line"; done
  log_ok "커밋 완료: ${W}${commit_msg}${N}"

  if [[ "$GIT_AUTO_PUSH" == "true" ]]; then
    local cur_branch
    cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    git push origin "$cur_branch" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
    log_ok "Push 완료: origin/${W}${cur_branch}${N}"
  fi
}

# ── Git 머지 헬퍼 ─────────────────────────────────────────────────────────────
_git_merge_to_base() {
  [[ "$GIT_ENABLED" != "true" ]]    && return 0
  [[ "$GIT_AUTO_MERGE" != "true" ]] && return 0   # (A) GIT_AUTO_MERGE 게이트

  local feat_branch base_branch upstream
  feat_branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  base_branch="$GIT_BASE_BRANCH"
  upstream="${GIT_UPSTREAM_REMOTE:-upstream}"

  if [[ -z "$feat_branch" || "$feat_branch" == "$base_branch" || "$feat_branch" == "HEAD" ]]; then
    log_warn "Git: 머지할 feature 브랜치를 특정할 수 없습니다 (현재: ${feat_branch:-unknown})"
    return 0
  fi

  log_step "Git 마무리: ${W}${feat_branch}${N} → ${W}${upstream}/${base_branch}${N}"

  # upstream NWO 결정 (gh pr merge --repo 에 필요)
  local upstream_url upstream_nwo
  upstream_url=$(git -C "$ROOT_DIR" remote get-url "$upstream" 2>/dev/null || echo "")
  upstream_nwo=$(_git_url_to_nwo "$upstream_url")

  # 미커밋 변경사항 커밋 (백로그 Done 상태 등 포함)
  cd "$ROOT_DIR"
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log_info "미커밋 변경사항을 자동 커밋합니다..."
    git add -A
    git commit -m "chore: harn 자동 커밋 — 스프린트 완료" \
      2>&1 | while IFS= read -r line; do log_info "$line"; done
  fi

  # feature 브랜치를 origin에 push (PR 최신화 필수)
  log_info "PR 최신화: origin/${W}${feat_branch}${N} push 중..."
  if ! git push origin "$feat_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_warn "Push 실패 — 수동으로 PR을 머지하세요"
    return 1
  fi
  log_ok "Push 완료: origin/${W}${feat_branch}${N}"

  # (B) gh pr merge —merge (not squash): GitHub PR 를 통해 머지
  local pr_url_file pr_url pr_repo_flag=""
  pr_url_file="$(require_run_dir 2>/dev/null)/pr-url.txt"
  pr_url=$(cat "$pr_url_file" 2>/dev/null || echo "")
  [[ -n "$upstream_nwo" ]] && pr_repo_flag="--repo $upstream_nwo"

  local merge_target="${pr_url:-$feat_branch}"
  log_info "PR 머지 중... (not squash): ${W}${merge_target}${N}"

  # shellcheck disable=SC2086
  if gh pr merge "$merge_target" \
      $pr_repo_flag \
      --merge 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "PR 머지 완료: ${W}${feat_branch}${N} → ${upstream_nwo:-$upstream}/${W}${base_branch}${N}"
  else
    log_warn "gh pr merge 실패 — 수동으로 GitHub에서 PR을 머지한 뒤 계속하세요"
    log_info "PR: ${pr_url:-https://github.com/${upstream_nwo}/pulls}"
    return 1
  fi

  # develop 으로 복귀
  log_info "베이스 브랜치로 복귀: ${W}${base_branch}${N}"
  git checkout "$base_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done

  # (C) git pull (not rebase) — 머지된 커밋 동기화
  log_info "${W}${upstream}/${base_branch}${N} pull 중..."
  if git pull "$upstream" "$base_branch" 2>&1 | while IFS= read -r line; do log_info "$line"; done; then
    log_ok "pull 완료: ${upstream}/${W}${base_branch}${N}"
  else
    log_warn "pull 실패 — 수동으로 ${upstream}/${base_branch} 를 pull 하세요"
    return 1
  fi
}

# ── 회고 ──────────────────────────────────────────────────────────────────────
cmd_retrospective() {
  local run_dir="$1"
  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_warn "AI CLI 없음 — 회고 건너뜀"
    return 0
  fi

  log_step "회고 (Retrospective)"

  # ── 컨텍스트 수집 ─────────────────────────────────────────────────────────
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

## 이번 작업 데이터

**백로그 항목**: ${backlog_item}

**스프린트 요약**:
${sprint_summary}

**현재 기획자 프롬프트**:
$(cat "$PROMPTS_DIR/planner.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/planner.md")

**현재 개발자 프롬프트**:
$(cat "$PROMPTS_DIR/generator.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/generator.md")

**현재 평가자 프롬프트**:
$(cat "$PROMPTS_DIR/evaluator.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/evaluator.md")"

  local retro_out="$run_dir/retrospective.md"
  log_info "AI(${W}${ai_cmd}${N})가 회고 분석 중..."
  if ! _ai_generate "$ai_cmd" "$prompt" "$retro_out"; then
    log_warn "회고 생성 실패 — 건너뜁니다"
    return 0
  fi

  # ── 요약 출력 ─────────────────────────────────────────────────────────────
  local summary
  summary=$(awk '/^=== retro-summary ===$/{f=1;next} /^=== /{f=0} f{print}' "$retro_out")
  if [[ -n "$summary" ]]; then
    echo ""
    echo -e "${W}  회고 요약${N}"
    echo -e "${D}  ────────────────────────────────────${N}"
    echo "$summary" | while IFS= read -r line; do
      echo -e "  $line"
    done
    echo ""
  fi

  # ── 프롬프트 개선 제안 검토 ────────────────────────────────────────────────
  local roles="planner generator evaluator"
  local role_names=("planner:기획자" "generator:개발자" "evaluator:평가자")
  local any_applied=false

  for role_pair in "${role_names[@]}"; do
    local role="${role_pair%%:*}"
    local role_kr="${role_pair##*:}"

    local suggestion
    suggestion=$(awk "/^=== prompt-suggestion:${role} ===$/{f=1;next} /^=== /{f=0} f{print}" "$retro_out" | sed '/^$/d')

    [[ -z "$suggestion" || "$suggestion" == "none" ]] && continue

    echo -e "${C}  ╭─ 💡 ${role_kr} 프롬프트 개선 제안${N}"
    echo "$suggestion" | while IFS= read -r line; do
      echo -e "${C}  │${N}  $line"
    done
    echo -e "${C}  ╰${N}"
    echo ""
    printf "  이 제안을 ${W}${role_kr}${N} 프롬프트에 추가할까요? [y/N]: "
    local yn; yn=$(_input_readline); echo ""

    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
      # 커스텀 프롬프트 파일 또는 기본 파일에 추가
      local target_prompt="$PROMPTS_DIR/${role}.md"
      if [[ ! -f "$target_prompt" ]]; then
        # 커스텀 디렉터리에 없으면 기본 파일 복사 후 추가
        mkdir -p "$PROMPTS_DIR"
        cp "$SCRIPT_DIR/prompts/${role}.md" "$target_prompt"
      fi
      printf '\n\n## 회고 개선사항 (%s)\n\n%s\n' "$(date '+%Y-%m-%d')" "$suggestion" >> "$target_prompt"
      log_ok "${role_kr} 프롬프트에 추가됨: ${W}${target_prompt}${N}"
      any_applied=true
    else
      log_info "${role_kr} 제안 건너뜀"
    fi
  done

  if [[ "$any_applied" == "true" ]]; then
    # 커스텀 프롬프트 디렉터리 config 반영
    if [[ "$PROMPTS_DIR" != "$SCRIPT_DIR/prompts" ]]; then
      local rel_dir="${PROMPTS_DIR#$ROOT_DIR/}"
      sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${rel_dir}\"|" "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "프롬프트 개선사항이 적용되었습니다."
  fi

  log_ok "회고 완료 — 결과: ${W}${retro_out}${N}"
}

# ── 스프린트 루프 본체 ────────────────────────────────────────────────────────
_run_sprint_loop() {
  local max_sprints="${1:-10}"
  local run_dir
  run_dir=$(require_run_dir)

  # current.log 심볼릭 링크 항상 최신화 (재개 시에도 tail 이 동작하도록)
  local run_log="$run_dir/run.log"
  touch "$run_log"
  ln -sfn "$run_log" "$HARNESS_DIR/current.log"
  LOG_FILE="$run_log"

  # PID 저장 (harn stop 이 이 프로세스를 찾을 수 있도록)
  echo "$$" > "$HARNESS_DIR/harness.pid"
  trap 'rm -f "$HARNESS_DIR/harness.pid"' EXIT
  trap 'rm -f "$HARNESS_DIR/harness.pid"; log_warn "하네스가 사용자에 의해 중단되었습니다."; exit 130' INT
  trap 'rm -f "$HARNESS_DIR/harness.pid"; log_warn "하네스가 종료 신호를 받았습니다."; exit 143' TERM

  log_step "루프 시작 (최대 $max_sprints 스프린트)"

  for _ in $(seq 1 "$max_sprints"); do
    local sprint_num
    sprint_num=$(current_sprint_num "$run_dir")
    local sprint
    sprint=$(sprint_dir "$run_dir" "$sprint_num")

    # 진행률 표시
    local total_planned
    total_planned=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    _print_sprint_progress "$sprint_num" "${total_planned:-$max_sprints}"

    if [[ ! -f "$sprint/contract.md" ]]; then
      cmd_contract
    fi

    # 재개 시 이미 완료된 반복 횟수를 초기값으로 사용
    local iter
    iter=$(sprint_iteration "$sprint")

    if [[ "$(sprint_status "$sprint")" == "pass" ]]; then
      log_info "스프린트 $sprint_num 이미 통과됨 — 다음으로 진행"
    elif [[ $iter -ge $MAX_ITERATIONS ]]; then
      log_warn "스프린트 $sprint_num 최대 반복 횟수($MAX_ITERATIONS) 이미 도달 — 강제 진행"
    else
      while [[ $iter -lt $MAX_ITERATIONS ]]; do
        cmd_implement
        iter=$(sprint_iteration "$sprint")
        if ! cmd_evaluate; then
          log_err "평가자 프로세스 오류로 루프를 중단합니다. 문제 수정 후 harn evaluate 를 실행하세요."
          return 1
        fi
        [[ "$(sprint_status "$sprint")" == "pass" ]] && break
      done
      if [[ "$(sprint_status "$sprint")" != "pass" ]]; then
        log_warn "스프린트 $sprint_num: 최대 반복 횟수($MAX_ITERATIONS) 도달 — QA 미통과 상태로 강제 진행"
      fi
    fi

    # 전체 스프린트 완료 여부 확인
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")

    if [[ $total -gt 0 && $sprint_num -ge $total ]]; then
      # ── 마지막 스프린트 완료: 최종 정리 후 종료 ──────────────────────────
      _log_raw ""
      _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
      _log_raw "${G}  ║  ✓  전체 ${total}개 스프린트 완료!${N}"
      _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"
      cmd_next          # handoff 작성 + 백로그 Done + completed 플래그
      _git_merge_to_base
      if [[ "$HARN_SKIP_RETRO" != "true" ]]; then
        cmd_retrospective "$run_dir"
      fi
      break
    else
      # ── 중간 스프린트 완료: 카운터만 올리고 다음 스프린트로 ─────────────
      log_info "스프린트 $sprint_num 완료 — 스프린트 $(( sprint_num + 1 )) 으로 전환"
      _sprint_advance "$run_dir"
    fi
  done
}

# ── 신규 작업 발굴 ─────────────────────────────────────────────────────────────

cmd_discover() {
  log_step "백로그 발굴 — 코드베이스 분석"

  mkdir -p "$HARNESS_DIR"
  LOG_FILE="$HARNESS_DIR/harness.log"

  local out_file="$HARNESS_DIR/discovery-$(date +%Y%m%d-%H%M%S).md"
  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt
  prompt="You are a senior engineer analyzing the **Servan** project codebase.

> **Language instruction**: Write all descriptions, goals, and reasoning in **Korean**. Slugs, code, and file paths stay in English.

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
1. TODO / FIXME / HACK 주석
2. 불완전한 기능 (stub, placeholder, not-implemented)
3. 테스트가 없는 핵심 경로
4. 아키텍처 위반 또는 레이어 규칙 미준수
5. 사용자 가치를 높이는 신규 기능

Pick the **2–4 highest-value items** not already in the backlog above.

## Output Format

Output ONLY this block — nothing else:

=== new-items ===
- [ ] **slug-for-item**
  한글 설명 (1–2줄): 무엇을, 왜 해야 하는지.

- [ ] **another-slug**
  한글 설명.

Rules:
- slug: hyphenated-lowercase, max 50 chars
- 2–4 items only
- No duplicates with existing backlog"

  invoke_role "planner" "$prompt" "$out_file" "분석가 — 신규 백로그 항목 발굴" "inline" "$COPILOT_MODEL_PLANNER"

  # 섹션 마커 이후 내용 추출
  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "새 항목을 추출하지 못했습니다 — $out_file 를 확인하세요."
    return 0
  fi

  # 백로그 파일이 없으면 기본 구조 생성
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "백로그 파일 생성됨: $BACKLOG_FILE"
  fi

  # ## Pending 섹션에 직접 삽입 (stdin으로 항목 전달)
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

  log_ok "새 항목이 백로그에 추가됨"
  echo ""
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r line; do
    echo -e "  ${Y}$line${N}"
  done
  echo ""
  log_info "확인: harn backlog   /   바로 시작: harn auto"
}

# ── 백로그 항목 추가 ───────────────────────────────────────────────────────────

cmd_add() {
  log_step "백로그 항목 추가"

  # 백로그 파일 없으면 기본 구조 생성
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    mkdir -p "$(dirname "$BACKLOG_FILE")"
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "백로그 파일 생성됨: $BACKLOG_FILE"
  fi

  echo -e ""
  echo -e "${B}  ╭─ ✚ 새 백로그 항목${N}"
  echo -e "${B}  │${N}  구현하고 싶은 기능이나 작업을 자유롭게 설명하세요."
  echo -e "${B}  │${N}  AI가 slug와 설명을 생성해 백로그에 추가합니다."
  echo -e "${B}  │${N}  ${D}여러 줄 입력 가능  ·  빈 줄로 완료${N}"
  echo -e "${B}  ╰${N}"

  local user_input
  user_input=$(_input_multiline)

  if [[ -z "$user_input" ]]; then
    log_warn "입력 없음 — 취소됨"
    return 0
  fi

  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_err "AI CLI를 찾을 수 없습니다. copilot 또는 claude 를 설치하세요."
    exit 1
  fi

  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt
  prompt="당신은 스프린트 백로그 관리자입니다.

> **Language**: 설명은 한국어, slug·코드·파일명은 영어로 작성하세요.

## 현재 백로그
\`\`\`
${current_backlog}
\`\`\`

## 사용자 요청
${user_input}

## 작업
위 요청을 바탕으로 백로그 항목을 1~3개 생성하세요.
기존 백로그와 중복되지 않도록 하세요.

## 출력 형식 (이 형식만 출력, 다른 텍스트 없음)

=== new-items ===
- [ ] **slug-for-item**
  한국어 설명 (1~2줄): 무엇을, 왜 해야 하는지.

Rules:
- slug: hyphenated-lowercase, max 50 chars
- 설명은 항목 바로 아래 들여쓰기(2칸)
- 1~3개만 생성"

  log_info "AI(${W}${ai_cmd}${N})가 백로그 항목을 생성 중..."

  local out_file="$HARNESS_DIR/add-$(date +%Y%m%d-%H%M%S).md"
  mkdir -p "$HARNESS_DIR"

  if ! _ai_generate "$ai_cmd" "$prompt" "$out_file"; then
    log_err "AI 생성 실패"
    return 1
  fi

  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "항목을 추출하지 못했습니다 — $out_file 를 확인하세요."
    return 0
  fi

  # Pending 섹션에 추가 (stdin으로 항목 전달 — 따옴표 충돌 방지)
  printf '%s' "${new_items}" | python3 - "$BACKLOG_FILE" <<'PYEOF'
import sys, re

path = sys.argv[1]
new_items_text = sys.stdin.read().strip()
if not new_items_text:
    sys.exit(0)

content = open(path, encoding='utf-8').read()
lines = content.splitlines()

# ## Pending 섹션의 끝 위치를 찾아 직접 삽입
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
    # ## Pending 섹션 없음 — 파일 끝에 추가
    lines += ['', '## Pending'] + insert_lines
else:
    # ## Pending 헤더 바로 다음에 삽입
    insert_at = pending_start + 1
    lines[insert_at:insert_at] = insert_lines

open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF

  echo ""
  log_ok "백로그에 추가됨:"
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r item; do
    echo -e "  ${C}▸${N} $item"
  done
  echo ""
  log_info "확인: ${W}harn backlog${N}   /   바로 시작: ${W}harn start${N}"
}

# ── 자동 모드 ──────────────────────────────────────────────────────────────────

cmd_auto() {
  log_step "자동 모드"

  local run_id run_dir
  run_id=$(current_run_id)

  # 1. 진행 중인 실행이 있으면 재개
  if [[ -n "$run_id" ]]; then
    run_dir="$HARNESS_DIR/runs/$run_id"
    if [[ ! -f "$run_dir/completed" ]]; then
      local sprint_num sprint cur_status
      sprint_num=$(current_sprint_num "$run_dir")
      sprint="$run_dir/sprints/$(printf '%03d' "$sprint_num")"
      cur_status=$(sprint_status "$sprint" 2>/dev/null || echo "pending")

      if [[ "$cur_status" != "cancelled" ]]; then
        log_info "진행 중인 실행 재개: ${W}$run_id${N}  (스프린트 $sprint_num · $cur_status)"
        _run_sprint_loop 10
        return 0
      else
        log_info "마지막 실행이 중단됨 — 새 항목을 찾습니다"
      fi
    else
      log_info "마지막 실행 완료됨 (${W}$run_id${N}) — 다음 항목을 찾습니다"
    fi
  fi

  # 2. 백로그에 대기 항목이 있으면 시작
  local next_slug
  next_slug=$(backlog_next_slug)

  if [[ -n "$next_slug" ]]; then
    log_info "백로그 다음 항목 시작: ${W}$next_slug${N}"
    rm -f "$HARNESS_DIR/current"   # 완료/중단된 이전 run 포인터 초기화
    cmd_start "$next_slug"
    return 0
  fi

  # 3. 백로그 비어있음 → 코드베이스 분석 후 새 항목 추가
  log_warn "백로그가 비어있습니다."
  cmd_discover

  # 발굴 후 새 항목이 생겼으면 바로 시작
  next_slug=$(backlog_next_slug)
  if [[ -n "$next_slug" ]]; then
    log_info "발굴된 첫 번째 항목 시작: ${W}$next_slug${N}"
    rm -f "$HARNESS_DIR/current"
    cmd_start "$next_slug"
  fi
}

cmd_all() {
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    log_err "백로그 파일을 찾을 수 없습니다: $BACKLOG_FILE"
    exit 1
  fi

  local slugs
  slugs=$(backlog_pending_slugs)

  if [[ -z "$slugs" ]]; then
    log_warn "백로그에 대기 중인 항목이 없습니다."
    log_info "항목을 추가하려면: ${W}harn discover${N}  또는  ${W}harn add${N}"
    return 0
  fi

  local slug_array=()
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && slug_array+=("$slug")
  done <<< "$slugs"

  local total_items="${#slug_array[@]}"
  log_step "전체 자동 실행 — ${W}${total_items}${N}개 항목"
  echo ""
  local i=1
  for slug in "${slug_array[@]}"; do
    echo -e "  ${D}$i.${N} ${Y}$slug${N}"
    i=$(( i + 1 ))
  done
  echo ""

  # 개별 항목 실행 중 회고 억제 — 맨 마지막에 한꺼번에 진행
  HARN_SKIP_RETRO="true"

  local completed_run_dirs=()
  local failed_slugs=()
  local item_num=0

  for slug in "${slug_array[@]}"; do
    item_num=$(( item_num + 1 ))
    log_step "[$item_num/$total_items] 항목 시작: ${W}$slug${N}"

    # 이전 run 포인터 초기화 (cmd_start 가 새 run을 생성하도록)
    rm -f "$HARNESS_DIR/current"

    if cmd_start "$slug"; then
      # 방금 완료된 run 디렉터리 기록
      local finished_run
      finished_run=$(ls -dt "$HARNESS_DIR/runs/"*/ 2>/dev/null | head -1)
      finished_run="${finished_run%/}"
      [[ -n "$finished_run" ]] && completed_run_dirs+=("$finished_run")
      log_ok "[$item_num/$total_items] 완료: ${W}$slug${N}"
    else
      log_err "[$item_num/$total_items] 실패: ${W}$slug${N} — 다음 항목으로 계속합니다"
      failed_slugs+=("$slug")
    fi
    echo ""
  done

  HARN_SKIP_RETRO="false"

  # ── 전체 완료 배너 ────────────────────────────────────────────────────────
  local done_count="${#completed_run_dirs[@]}"
  local fail_count="${#failed_slugs[@]}"

  _log_raw ""
  _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
  _log_raw "${G}  ║  ✓  전체 ${total_items}개 항목 처리 완료   (성공: ${done_count}  실패: ${fail_count})${N}"
  _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"

  if [[ $fail_count -gt 0 ]]; then
    log_warn "실패 항목: ${failed_slugs[*]}"
    log_info "실패 항목은 수동으로 재실행하세요: ${W}harn start <slug>${N}"
  fi

  # ── 회고: 완료된 모든 항목에 대해 순차 진행 ──────────────────────────────
  if [[ $done_count -gt 0 ]]; then
    log_step "회고 진행 (${done_count}개 항목)"
    for run_dir in "${completed_run_dirs[@]}"; do
      local item_slug
      item_slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || basename "$run_dir")
      log_info "회고: ${W}$item_slug${N}"
      cmd_retrospective "$run_dir" || true
    done
  fi
}

cmd_status() {
  local run_id sprint_num
  run_id=$(current_run_id)
  sprint_num=$(current_sprint_num "$run_dir")

  echo -e "${W}실행 ID:${N}   $run_id"
  echo -e "${W}항목:${N}      $(cat "$run_dir/prompt.txt")"
  echo -e "${W}현재 스프린트:${N} $sprint_num"

  echo ""
  echo -e "${W}스프린트 목록:${N}"
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

    local status_kr="대기"
    [[ "$status" == "pass" ]]        && status_kr="통과"
    [[ "$status" == "fail" ]]        && status_kr="실패"
    [[ "$status" == "in-progress" ]] && status_kr="진행 중"
    [[ "$status" == "cancelled" ]]   && status_kr="중단됨"

    echo -e "  스프린트 $sn  $icon $status_kr  (반복: $iter)"
  done
  [[ $any -eq 0 ]] && echo "  (스프린트 없음)"
}

cmd_config() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      echo -e "${W}Harness 설정${N}  (${CONFIG_FILE})"
      echo -e "  프로젝트:          ${W}$ROOT_DIR${N}"
      echo -e "  백로그 파일:       ${W}$BACKLOG_FILE${N}"
      echo -e "  최대 재시도:       ${W}$MAX_ITERATIONS${N}"
      echo -e "  Git 통합:          ${W}$GIT_ENABLED${N}"
      [[ "$GIT_ENABLED" == "true" ]] && {
        echo -e "  베이스 브랜치:     ${W}$GIT_BASE_BRANCH${N}"
        echo -e "  자동 Push:         ${W}$GIT_AUTO_PUSH${N}"
        echo -e "  자동 PR:           ${W}$GIT_AUTO_PR${N}"
      }
      echo ""
      echo -e "${W}AI 모델${N}"
      echo -e "  기획자:            ${W}$COPILOT_MODEL_PLANNER${N}"
      echo -e "  개발자(협의):      ${W}$COPILOT_MODEL_GENERATOR_CONTRACT${N}"
      echo -e "  개발자(구현):      ${W}$COPILOT_MODEL_GENERATOR_IMPL${N}"
      echo -e "  평가자(협의):      ${W}$COPILOT_MODEL_EVALUATOR_CONTRACT${N}"
      echo -e "  평가자(QA):        ${W}$COPILOT_MODEL_EVALUATOR_QA${N}"
      [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]] && echo -e "\n  커스텀 프롬프트:   ${W}$PROMPTS_DIR${N}"
      ;;
    set)
      local key="${2:-}" val="${3:-}"
      [[ -z "$key" || -z "$val" ]] && { log_err "사용법: harn config set KEY VALUE"; exit 1; }
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err ".harness_config 파일이 없습니다. 먼저 ${W}harn init${N} 을 실행하세요."
        exit 1
      fi
      if grep -q "^${key}=" "$CONFIG_FILE"; then
        sed -i '' "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE"
      else
        echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
      fi
      log_ok "${W}${key}${N} = \"${val}\" 설정됨"
      ;;
    regen)
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err ".harness_config 파일이 없습니다. 먼저 ${W}harn init${N} 을 실행하세요."
        exit 1
      fi
      local ai_cmd; ai_cmd=$(_detect_ai_cli)
      if [[ -z "$ai_cmd" ]]; then
        log_err "AI CLI를 찾을 수 없습니다. copilot 또는 claude 를 설치하세요."
        exit 1
      fi
      local hp="${HINT_PLANNER:-}" hg="${HINT_GENERATOR:-}" he="${HINT_EVALUATOR:-}" gg="${GIT_GUIDE:-}"
      if [[ -z "$hp" && -z "$hg" && -z "$he" && -z "$gg" ]]; then
        log_warn "config에 HINT_* / GIT_GUIDE 값이 없습니다. 재생성할 내용이 없습니다."
        log_info "힌트를 추가하려면: ${W}harn config set HINT_PLANNER \"힌트 내용\"${N}"
        exit 0
      fi
      log_step "커스텀 프롬프트 재생성"
      log_info "AI CLI(${W}${ai_cmd}${N})로 프롬프트를 재생성합니다..."
      _generate_custom_prompts "$hp" "$hg" "$he" "$gg"
      local cpd=".harness/prompts"
      if ! grep -q "^CUSTOM_PROMPTS_DIR=" "$CONFIG_FILE"; then
        echo "CUSTOM_PROMPTS_DIR=\"${cpd}\"" >> "$CONFIG_FILE"
      else
        sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
      fi
      load_config
      log_ok "커스텀 프롬프트 재생성 완료: ${W}$PROMPTS_DIR${N}"
      ;;
    *)
      log_err "알 수 없는 config 서브명령: $sub"
      echo -e "사용법: harn config [show|set KEY VALUE|regen]"
      exit 1
      ;;
  esac
}

cmd_runs() {
  echo -e "${W}하네스 실행 목록:${N}"
  local current_id; current_id=$(current_run_id)
  for d in "$HARNESS_DIR/runs"/*/; do
    [[ -d "$d" ]] || continue
    local id prompt marker
    id=$(basename "$d")
    prompt=$(head -c 70 "$d/prompt.txt" 2>/dev/null || echo "(프롬프트 없음)")
    marker=""; [[ "$id" == "$current_id" ]] && marker=" ${G}← 현재${N}"
    echo -e "  ${W}$id${N}: $prompt$marker"
  done
}

cmd_resume() {
  local run_id="${1:-}"
  [[ -z "$run_id" ]] && { log_err "사용법: harn resume <run-id>"; exit 1; }
  local run_dir="$HARNESS_DIR/runs/$run_id"
  [[ ! -d "$run_dir" ]] && { log_err "실행을 찾을 수 없음: $run_id"; exit 1; }
  ln -sfn "$run_dir" "$HARNESS_DIR/current"
  log_ok "재개됨: $run_id"
  cmd_status
}

cmd_tail() {
  local log="$HARNESS_DIR/current.log"

  # current.log 심볼릭 링크가 없거나 끊긴 경우 → 가장 최근 run 로그로 폴백
  if [[ ! -e "$log" ]]; then
    local latest_log
    latest_log=$(ls -t "$HARNESS_DIR/runs"/*/run.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]]; then
      log_warn "current.log 없음 — 최근 실행 로그로 대체: $latest_log"
      ln -sfn "$latest_log" "$HARNESS_DIR/current.log"
      log="$latest_log"
    else
      log_err "활성 로그 없음. 먼저 실행을 시작하세요: harn auto"
      exit 1
    fi
  fi

  echo -e "${W}로그 실시간 출력:${N} $log  ${B}(Ctrl-C 로 중지)${N}"
  tail -f "$log"
}

usage() {
  _print_banner
  cat <<EOF
${D}  $(pwd)${N}

  ${W}사용법${N}  harn <command>

  ${C}설정${N}
    init                  초기 설정 (최초 1회 또는 재설정)
    config                현재 설정 출력
    config set KEY VALUE  특정 설정값 변경
    config regen          HINT_* 기반으로 커스텀 프롬프트 재생성

  ${C}백로그${N}
    backlog               대기 항목 목록
    add                   새 백로그 항목 추가 (AI 보조)
    discover              코드베이스 분석 후 항목 자동 발굴

  ${C}실행${N}
    start                 항목 선택 후 전체 루프 실행
    auto                  재개 / 시작 / 발굴 자동 판단
    all                   대기 중인 모든 항목 순차 실행 (회고는 마지막에)

  ${C}단계별${N}
    plan                  기획자 재실행
    contract              스코프 협의
    implement             개발자 실행
    evaluate              평가자 실행
    next                  다음 스프린트

  ${C}모니터링${N}
    status                현재 실행 상태
    tail                  실시간 로그
    runs                  실행 목록
    resume <id>           이전 실행 재개
    stop                  루프 중지

  ${D}팁: 루프 실행 중 각 단계 사이에 추가 지시사항을 입력할 수 있습니다.${N}
  ${D}    HARNESS_COPILOT_MODEL_GENERATOR_IMPL=claude-sonnet-4.6 harn start${N}

EOF
}

# ── 전역 옵션 파싱 (명령어 앞 플래그) ────────────────────────────────────────
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
      log_err "알 수 없는 옵션: $1"
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

validate_role_models

# ── 설정 로드 / 첫 실행 감지 ──────────────────────────────────────────────────
_cmd="${1:-help}"
case "$_cmd" in
  init|help|--help|-h) : ;;  # config 없이 실행 가능한 명령
  *)
    if [[ ! -f "$CONFIG_FILE" ]]; then
      _print_banner
      echo -e "  ${Y}⚠${N}  이 디렉터리에 ${W}.harness_config${N}가 없습니다."
      echo -e "     초기 설정을 시작합니다...\n"
      cmd_init
    else
      load_config
    fi
    ;;
esac

# ── 라우팅 ────────────────────────────────────────────────────────────────────
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
  tail)      cmd_tail ;;
  runs)      cmd_runs ;;
  resume)    cmd_resume "${2:-}" ;;
  help|--help|-h) usage ;;
  *) log_err "알 수 없는 명령: $1"; usage; exit 1 ;;
esac
