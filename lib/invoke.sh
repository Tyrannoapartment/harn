# lib/invoke.sh — Agent invocation and output rendering
# Sourced by harn.sh — do not execute directly

# ── Real-time markdown color renderer ─────────────────────────────────────────
# Pipe stdin → md_stream.py → colored rendering stdout
# Saved to log file without ANSI codes, displayed with color in terminal
_md_stream() {
  python3 -u "$SCRIPT_DIR/parser/md_stream.py"
}

_stream_agent_output() {
  cat
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
      | _stream_agent_output || exit_code=${PIPESTATUS[0]}
  else
    "${copilot_cmd[@]}" 2>&1 \
      | tee "$output_file" \
      | tee -a "$LOG_FILE" \
      | _stream_agent_output || exit_code=${PIPESTATUS[0]}
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

  # ── Context Injection: prepend project memory ────────────────────────────────
  local memory_block=""
  memory_block=$(_memory_inject 2>/dev/null || true)
  if [[ -n "$memory_block" ]]; then
    if [[ "$prompt_mode" == "file" ]]; then
      local tmp_mem; tmp_mem=$(mktemp)
      printf '%s\n\n' "$memory_block" > "$tmp_mem"
      cat "$prompt_input" >> "$tmp_mem"
      prompt_input="$tmp_mem"
    else
      prompt_input="${memory_block}"$'\n\n'"${prompt_input}"
    fi
  fi

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

  # ── Intelligent Model Routing ────────────────────────────────────────────────
  if [[ -n "$model" ]]; then
    local prompt_text_for_routing="$prompt_input"
    [[ "$prompt_mode" == "file" ]] && prompt_text_for_routing=$(head -c 2000 "$prompt_input" 2>/dev/null || true)
    model=$(_route_model "$model" "$prompt_text_for_routing" "$role_detail")
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
        | _stream_agent_output || exit_code=${PIPESTATUS[0]}
      [[ $exit_code -ne 0 ]] && log_warn "claude exited abnormally (exit $exit_code)"
      log_agent_done "$_role_label"
      ;;
    codex)
      local prompt_text="$prompt_input"
      [[ "$prompt_mode" == "file" ]] && prompt_text="$(cat "$prompt_input")"
      local -a codex_cmd=(codex exec)
      [[ -n "$model" ]] && codex_cmd+=(-m "$model")
      codex_cmd+=(-)
      echo "$prompt_text" | "${codex_cmd[@]}" 2>&1 \
        | tee "$output_file" \
        | tee -a "$LOG_FILE" \
        | _stream_agent_output || exit_code=${PIPESTATUS[0]}
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
        | _stream_agent_output || exit_code=${PIPESTATUS[0]}
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
