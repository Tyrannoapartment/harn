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

HARN_VERSION="1.6.0"

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
CUSTOM_PROMPTS_DIR=""
SPRINT_COUNT=1
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
AI_BACKEND_AUXILIARY=""
AI_BACKEND_PLANNER=""
AI_BACKEND_GENERATOR_CONTRACT=""
AI_BACKEND_GENERATOR_IMPL=""
AI_BACKEND_EVALUATOR_CONTRACT=""
AI_BACKEND_EVALUATOR_QA=""

# Role-specific model defaults (can be overridden via config or env)
MODEL_AUXILIARY=""
COPILOT_MODEL_PLANNER="claude-haiku-4.5"
COPILOT_MODEL_GENERATOR_CONTRACT="claude-sonnet-4.6"
COPILOT_MODEL_GENERATOR_IMPL="claude-opus-4.6"
COPILOT_MODEL_EVALUATOR_CONTRACT="claude-haiku-4.5"
COPILOT_MODEL_EVALUATOR_QA="claude-sonnet-4.5"

# ── Log setup ──────────────────────────────────────────────────────────────────
mkdir -p "$HARN_DIR"
LOG_FILE="$HARN_DIR/harn.log"

# ── Source lib modules (order matters — respects dependency chain) ─────────────
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/error.sh"
source "$SCRIPT_DIR/lib/guidance.sh"
source "$SCRIPT_DIR/lib/input.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ai.sh"
source "$SCRIPT_DIR/lib/init.sh"
source "$SCRIPT_DIR/lib/backlog.sh"
source "$SCRIPT_DIR/lib/run.sh"
source "$SCRIPT_DIR/lib/invoke.sh"
source "$SCRIPT_DIR/lib/commands.sh"
source "$SCRIPT_DIR/lib/git.sh"
source "$SCRIPT_DIR/lib/retro.sh"
source "$SCRIPT_DIR/lib/sprint.sh"
source "$SCRIPT_DIR/lib/discover.sh"
source "$SCRIPT_DIR/lib/auto.sh"
source "$SCRIPT_DIR/lib/doctor.sh"
source "$SCRIPT_DIR/lib/memory.sh"
source "$SCRIPT_DIR/lib/routing.sh"
source "$SCRIPT_DIR/lib/progress.sh"
source "$SCRIPT_DIR/lib/update.sh"
source "$SCRIPT_DIR/lib/team.sh"
source "$SCRIPT_DIR/lib/nlp.sh"
source "$SCRIPT_DIR/lib/web.sh"

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
_cmd="${1:-_welcome}"
case "$_cmd" in
  _welcome|web|exit|init|help|--help|-h|version|--version|-V)
    if [[ "$_cmd" == "_welcome" && -f "$CONFIG_FILE" ]]; then
      load_config
    elif [[ "$_cmd" == "web" || "$_cmd" == "exit" ]] && [[ -f "$CONFIG_FILE" ]]; then
      load_config
    fi
    ;;  # commands that can run without config
  *)
    if [[ ! -f "$CONFIG_FILE" ]]; then
      if [[ "$_cmd" == "doctor" ]]; then
        :
      else
        _print_banner
        echo -e "  ${Y}⚠${N}  ${I18N_NO_CONFIG_WARN}"
        echo -e "     ${I18N_NO_CONFIG_SETUP}\n"
        cmd_init
      fi
    else
      load_config
    fi
    ;;
esac

# ── Routing ───────────────────────────────────────────────────────────────────
# Auto-update check (non-blocking, cached 24h)
_check_update

case "${1:-_welcome}" in
  web)       cmd_web ;;
  exit)      cmd_exit ;;
  init)      cmd_init ;;
  auto)      shift; cmd_auto "$@" ;;
  all)       shift; cmd_all "$@" ;;
  discover)  cmd_discover ;;
  add)       cmd_add ;;
  start)     shift; cmd_start "$@" ;;
  plan)      cmd_plan ;;
  contract)  cmd_contract ;;
  implement) cmd_implement ;;
  evaluate)  cmd_evaluate ;;
  next)      cmd_next "${2:-}" ;;
  stop)      cmd_stop ;;
  clear)     cmd_clear ;;
  config)    cmd_config "${2:-show}" "${3:-}" "${4:-}" ;;
  model)     cmd_model ;;
  inbox)     cmd_inbox "${2:-show}" ;;
  backlog)   cmd_backlog ;;
  status)    cmd_status ;;
  auth)      cmd_auth "${2:-status}" ;;
  doctor)    cmd_doctor ;;
  tail)      cmd_tail ;;
  runs)      cmd_runs ;;
  resume)    cmd_resume "${2:-}" ;;
  do)        shift; cmd_do "$@" ;;
  version|--version|-V) echo "harn $HARN_VERSION" ;;
  help|--help|-h) usage ;;
  _welcome)
    if [[ -f "$CONFIG_FILE" ]]; then
      cmd_web
    else
      _welcome
    fi
    ;;
  *) log_err "Unknown command: $1"; usage; exit 1 ;;
esac
