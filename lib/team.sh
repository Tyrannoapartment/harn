# lib/team.sh — Team mode (tmux-based parallel agent execution)
# Sourced by harn.sh — do not execute directly

cmd_team() {
  local input="$*"

  # Parse "N:task" or "N task" format
  local agent_count=2 task=""
  if [[ "$input" =~ ^([0-9]+)[[:space:]:]+(.+)$ ]]; then
    agent_count="${BASH_REMATCH[1]}"
    task="${BASH_REMATCH[2]}"
  elif [[ -n "$input" ]]; then
    task="$input"
  fi

  if ! command -v tmux &>/dev/null; then
    log_err "${I18N_TEAM_NO_TMUX:-tmux is required for team mode. Install: brew install tmux}"
    return 1
  fi

  if [[ -z "$task" ]]; then
    log_err "${I18N_TEAM_USAGE:-Usage: harn team [count] <task description>}"
    return 1
  fi

  [[ "$agent_count" -lt 1 ]] && agent_count=2
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

Task: ${task}"

  for i in $(seq 1 "$agent_count"); do
    local worker_prompt="${prompt_base}

You are Worker ${i} of ${agent_count}. Focus on approximately 1/${agent_count} of the work."

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
