# lib/team.sh — Team mode helpers (tmux-based parallel agent execution)
# Sourced by harn.sh — do not execute directly

TEAM_WORKSTREAMS=(
  "Planning and scope definition"
  "Core implementation"
  "Tests and QA hardening"
  "Refactor and cleanup"
  "Documentation and handoff"
  "Backend and API work"
  "Frontend and UX work"
  "Tooling and infrastructure"
)

_parse_team_option() {
  HARN_TEAM_COUNT=0
  HARN_PARSED_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --team=*)
        HARN_TEAM_COUNT="${1#--team=}"
        ;;
      --team)
        HARN_TEAM_COUNT="${2:-2}"
        shift
        ;;
      --[0-9]*)
        HARN_TEAM_COUNT="${1#--}"
        ;;
      *)
        HARN_PARSED_ARGS+=("$1")
        ;;
    esac
    shift
  done
}

_select_team_workstreams() {
  local agent_count="$1"
  local picked
  picked=$(_pick_multi_menu "병렬 에이전트가 맡을 일을 선택하세요" "$agent_count" "${TEAM_WORKSTREAMS[@]}") || return 1
  printf '%s\n' "$picked"
}

_launch_team_session() {
  local agent_count="$1" task="$2"
  shift 2
  local workstreams=("$@")

  if ! command -v tmux &>/dev/null; then
    log_err "${I18N_TEAM_NO_TMUX:-tmux is required for team mode. Install: brew install tmux}"
    return 1
  fi

  if [[ -z "$task" || "$agent_count" -lt 1 ]]; then
    log_err "${I18N_TEAM_USAGE:-Usage: harn <start|auto|all> --team=N}"
    return 1
  fi

  [[ "$agent_count" -gt 8 ]] && { log_warn "Max 8 agents allowed. Using 8."; agent_count=8; }

  local ai_cmd
  ai_cmd=$(_detect_ai_cli)
  [[ -z "$ai_cmd" ]] && { log_err "No AI CLI found"; return 1; }

  local session_name="harn-team-$(date +%H%M%S)"

  log_step "$(printf "${I18N_TEAM_LAUNCHING:-Launching %d parallel agents}" "$agent_count")"
  log_info "${D}Task: ${task}${N}"

  # Create tmux session
  tmux new-session -d -s "$session_name" -x 200 -y 50 2>/dev/null || {
    log_err "Failed to create tmux session"
    return 1
  }

  local prompt_base
  prompt_base="You are part of a ${agent_count}-agent parallel team working on the same codebase.
Coordinate by checking existing files before creating new ones.
Avoid duplicate work.

Project directory: ${ROOT_DIR}

Task: ${task}

Selected workstreams:
$(printf -- '- %s\n' "${workstreams[@]}")"

  for i in $(seq 1 "$agent_count"); do
    local stream="${workstreams[$(( i - 1 ))]:-General implementation}"
    local worker_prompt="${prompt_base}

You are Worker ${i} of ${agent_count}.
Primary workstream: ${stream}
Stay within your workstream and avoid duplicating the work of other workers."

    local cmd_str=""
    case "$ai_cmd" in
      copilot) cmd_str="copilot --add-dir \"$ROOT_DIR\" --yolo -p \"$worker_prompt\"" ;;
      claude)  cmd_str="claude -p \"$worker_prompt\"" ;;
      codex)   cmd_str="echo \"$worker_prompt\" | codex exec -" ;;
      gemini)  cmd_str="gemini -p \"$worker_prompt\"" ;;
    esac

    if [[ $i -eq 1 ]]; then
      tmux send-keys -t "$session_name" "$cmd_str" Enter
    else
      tmux split-window -t "$session_name"
      tmux send-keys -t "$session_name" "$cmd_str" Enter
      tmux select-layout -t "$session_name" tiled 2>/dev/null || true
    fi
  done

  log_ok "$(printf "${I18N_TEAM_STARTED:-Team session started: %s}" "$session_name")"
  log_info "  ${D}tmux attach -t $session_name${N}"

  # Auto-attach in interactive mode
  if [[ -t 0 && -t 1 ]]; then
    tmux attach -t "$session_name"
  fi
}
