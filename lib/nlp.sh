# lib/nlp.sh — Natural language command router
# Sourced by harn.sh — do not execute directly

# ── Helpers ────────────────────────────────────────────────────────────────────

_nlp_backlog_context() {
  [[ -f "$BACKLOG_FILE" ]] || return 0
  echo "Current backlog (first 80 lines):"
  head -80 "$BACKLOG_FILE" 2>/dev/null || echo "(empty)"
}

_nlp_run_context() {
  local run_id; run_id=$(current_run_id 2>/dev/null) || return 0
  [[ -z "$run_id" ]] && return 0
  local run_dir="$HARN_DIR/runs/$run_id"
  local sprint_n; sprint_n=$(current_sprint_num "$run_dir" 2>/dev/null)
  echo "Active run: $run_id | item: $(cat "$run_dir/prompt.txt" 2>/dev/null) | sprint: $sprint_n"
}

_nlp_config_context() {
  [[ -f "$CONFIG_FILE" ]] || echo "(no config yet)"
  grep -E '^(MODEL_|BACKLOG_|AI_)' "$CONFIG_FILE" 2>/dev/null | head -20
}

# ── Direct backlog add (non-interactive) ───────────────────────────────────────
# Generates slug + description from user input, saves directly without prompting.

_nlp_add_item() {
  local user_input="$1"
  local ai_cmd; ai_cmd=$(_detect_ai_cli)

  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt="You are a sprint backlog manager.

User request: \"${user_input}\"

Current backlog:
\`\`\`
${current_backlog}
\`\`\`

Generate 1–3 concise backlog items. Do NOT duplicate existing items.
Respond with ONLY this block:

=== new-items ===
- [ ] **slug-here**
  Description: what to implement and why (1–2 lines).

Rules: slug = hyphenated-lowercase ≤50 chars, description indented 2 spaces."

  local out_file; out_file=$(mktemp)
  log_info "${I18N_NLP_GENERATING:-Generating backlog items...}"

  if ! _ai_generate "$ai_cmd" "$prompt" "$out_file"; then
    log_err "${I18N_NLP_FAILED:-Failed}"
    rm -f "$out_file"; return 1
  fi

  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")
  rm -f "$out_file"

  if [[ -z "$new_items" ]]; then
    log_warn "${I18N_NLP_NO_ITEMS:-No items generated}"
    return 0
  fi

  # Preview items and confirm
  echo ""
  log_ok "${I18N_NLP_ITEMS_PREVIEW:-Items to add:}"
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r line; do
    echo -e "  ${C}▸${N} $line"
  done
  echo ""

  local confirm
  confirm=$(_pick_menu "${I18N_NLP_CONFIRM_ADD:-Add to backlog?}" 0 \
    "${I18N_NLP_YES:-Yes, add}" \
    "${I18N_NLP_NO:-Cancel}")

  [[ "$confirm" != "${I18N_NLP_YES:-Yes, add}" ]] && { log_warn "${I18N_NLP_CANCELLED:-Cancelled}"; return 0; }

  # Create backlog file if needed
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    mkdir -p "$(dirname "$BACKLOG_FILE")"
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
  fi

  # Insert into ## Pending
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
pending_start = None
for i, line in enumerate(lines):
    if re.match(r'^## Pending\s*$', line):
        pending_start = i; break
insert_lines = [''] + new_items_text.splitlines() + ['']
if pending_start is None:
    lines += ['', '## Pending'] + insert_lines
else:
    lines[pending_start + 1:pending_start + 1] = insert_lines
open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF
  rm -f "$items_tmp"
  log_ok "${I18N_ADD_DONE:-Added to backlog}"
}

# ── Config change with arrow-key selection ─────────────────────────────────────
# AI identifies which config key + options → user picks with arrow keys.

_nlp_config_suggest() {
  local user_input="$1"
  local ai_cmd; ai_cmd=$(_detect_ai_cli)

  local config_content; config_content=$(_nlp_config_context)

  local known_keys="MODEL_PLANNER, MODEL_GENERATOR_CONTRACT, MODEL_GENERATOR_IMPL, MODEL_EVALUATOR_CONTRACT, MODEL_EVALUATOR_QA, BACKLOG_FILE, MAX_ITERATIONS"
  local model_choices="claude-opus-4.6, claude-sonnet-4.6, claude-haiku-4.5, claude-opus-4.5, claude-sonnet-4.5"

  local prompt="You are a configuration assistant for harn (AI sprint CLI).

User request: \"${user_input}\"

Current config:
${config_content}

Known config keys: ${known_keys}
Available models: ${model_choices}

Identify which setting the user wants to change and suggest options.

Respond with EXACTLY this format (one line):
CONFIG_SUGGEST: key=<KEY> label=<human label> current=<current value or none> options=<opt1>,<opt2>,<opt3>

Examples:
- User wants to change generator model → CONFIG_SUGGEST: key=MODEL_GENERATOR_IMPL label=Generator model current=claude-opus-4.6 options=claude-opus-4.6,claude-sonnet-4.6,claude-haiku-4.5
- User wants to change all models → CONFIG_SUGGEST: key=ALL_MODELS label=All role models current=mixed options=claude-opus-4.6 (all roles),claude-sonnet-4.6 (all roles),claude-haiku-4.5 (all roles)
- User wants to change max retries → CONFIG_SUGGEST: key=MAX_ITERATIONS label=Max sprint retries current=3 options=1,2,3,5,10"

  local result_file; result_file=$(mktemp)
  log_info "${I18N_NLP_ANALYZING:-Analyzing request...}"

  if ! _ai_generate "$ai_cmd" "$prompt" "$result_file"; then
    log_err "${I18N_NLP_FAILED:-Failed}"; rm -f "$result_file"; return 1
  fi

  local suggestion
  suggestion=$(grep 'CONFIG_SUGGEST:' "$result_file" | head -1 | sed 's/.*CONFIG_SUGGEST:[[:space:]]*//')
  rm -f "$result_file"

  if [[ -z "$suggestion" ]]; then
    log_err "${I18N_NLP_NO_MATCH:-Could not determine config change}"; return 1
  fi

  # Parse fields
  local cfg_key cfg_label cfg_current cfg_options
  cfg_key=$(echo "$suggestion"     | grep -oE 'key=[^ ]+' | sed 's/key=//')
  cfg_label=$(echo "$suggestion"   | grep -oE 'label=[^=]+(?= current=)' | sed 's/label=//' || \
              echo "$suggestion"   | sed 's/.*label=//;s/ current=.*//')
  cfg_current=$(echo "$suggestion" | grep -oE 'current=[^ ]+' | sed 's/current=//')
  cfg_options=$(echo "$suggestion" | grep -oE 'options=.+$' | sed 's/options=//')

  if [[ -z "$cfg_key" || -z "$cfg_options" ]]; then
    log_err "Incomplete config suggestion"; return 1
  fi

  # Build options array
  IFS=',' read -ra opts <<< "$cfg_options"

  # Show current value context
  echo ""
  echo -e "  ${W}${cfg_label:-$cfg_key}${N}  ${D}현재: ${cfg_current:-없음}${N}"

  # Arrow-key selection
  local selected
  selected=$(_pick_menu "${I18N_NLP_SELECT_VALUE:-Select new value:}" 0 "${opts[@]}")

  if [[ -z "$selected" ]]; then
    log_warn "${I18N_NLP_CANCELLED:-Cancelled}"; return 0
  fi

  # Special case: "all roles" shorthand
  if [[ "$cfg_key" == "ALL_MODELS" || "$selected" == *"(all roles)"* ]]; then
    local model_val
    model_val=$(echo "$selected" | sed 's/ (all roles)//')
    for role_key in MODEL_PLANNER MODEL_GENERATOR_CONTRACT MODEL_GENERATOR_IMPL MODEL_EVALUATOR_CONTRACT MODEL_EVALUATOR_QA; do
      cmd_config set "$role_key" "$model_val"
    done
    log_ok "$(printf "${I18N_NLP_CONFIG_APPLIED:-Applied: all models → %s}" "${W}${model_val}${N}")"
  else
    cmd_config set "$cfg_key" "$selected"
    log_ok "$(printf "${I18N_NLP_CONFIG_APPLIED:-Applied: %s → %s}" "${W}${cfg_key}${N}" "${W}${selected}${N}")"
  fi
}

# ── Main router ────────────────────────────────────────────────────────────────

cmd_do() {
  local user_input="$*"

  if [[ -z "$user_input" ]]; then
    log_err "${I18N_NLP_USAGE:-Usage: harn do \"<natural language request>\"}"
    return 1
  fi

  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  [[ -z "$ai_cmd" ]] && { log_err "No AI CLI found"; return 1; }

  local backlog_ctx; backlog_ctx=$(_nlp_backlog_context)
  local run_ctx; run_ctx=$(_nlp_run_context)

  local routing_prompt="You are a command router for harn (AI multi-agent sprint development CLI).

User request: \"$user_input\"

Context:
${backlog_ctx}
${run_ctx}

Choose the BEST action type and respond with EXACTLY one line:

Option A — Run a command:
COMMAND: <cmd> [args]
Available: auto, all, start [slug], discover, backlog, status, stop, plan, config show, team [N] <task>, doctor

Option B — Add backlog item (user describes something to build/fix, no slug given yet):
ADD_ITEM: <natural description>

Option C — Change a config setting (user wants to modify behavior/models/settings):
CONFIG_SUGGEST: <natural description of what to change>

Decision rules:
- \"가장 우선순위 높은거 시작해줘\" / \"start highest priority\" → COMMAND: auto
- \"auth 기능 만들어줘\" / \"add X feature\" / anything to build → ADD_ITEM: ...
- \"모델 바꿔줘\" / \"change model\" / \"설정 수정\" / anything about settings → CONFIG_SUGGEST: ...
- \"전부 실행\" / \"run all\" → COMMAND: all
- \"현재 상태\" / \"status\" → COMMAND: status
- \"auth-refactor 시작\" (known slug) → COMMAND: start auth-refactor

Examples:
- \"백로그에서 가장 우선순위 높은것 진행해줘\" → COMMAND: auto
- \"JWT 인증 기능 추가해줘\" → ADD_ITEM: JWT authentication feature
- \"generator 모델을 sonnet으로 바꿔줘\" → CONFIG_SUGGEST: change generator implementation model
- \"planner 모델 바꾸고 싶어\" → CONFIG_SUGGEST: change planner model
- \"모든 모델 haiku로 설정해줘\" → CONFIG_SUGGEST: set all role models to haiku
- \"최대 재시도 횟수 늘려줘\" → CONFIG_SUGGEST: change max iterations
- \"3명이서 로그인 기능 만들어\" → COMMAND: team 3 implement login feature
- \"멈춰\" → COMMAND: stop"

  log_step "${I18N_NLP_ANALYZING:-Analyzing request...}"
  log_info "${D}\"$user_input\"${N}"

  local result_file; result_file=$(mktemp)

  if ! _ai_generate "$ai_cmd" "$routing_prompt" "$result_file"; then
    log_err "${I18N_NLP_FAILED:-Failed to analyze request}"
    rm -f "$result_file"; return 1
  fi

  local raw_result; raw_result=$(cat "$result_file")
  rm -f "$result_file"

  # Detect action type
  local action_type action_content
  if echo "$raw_result" | grep -q 'ADD_ITEM:'; then
    action_type="ADD_ITEM"
    action_content=$(echo "$raw_result" | grep 'ADD_ITEM:' | head -1 | sed 's/.*ADD_ITEM:[[:space:]]*//')
  elif echo "$raw_result" | grep -q 'CONFIG_SUGGEST:'; then
    action_type="CONFIG_SUGGEST"
    action_content=$(echo "$raw_result" | grep 'CONFIG_SUGGEST:' | head -1 | sed 's/.*CONFIG_SUGGEST:[[:space:]]*//')
  elif echo "$raw_result" | grep -q 'COMMAND:'; then
    action_type="COMMAND"
    action_content=$(echo "$raw_result" | grep 'COMMAND:' | head -1 | sed 's/.*COMMAND:[[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  else
    log_err "${I18N_NLP_NO_MATCH:-Could not determine the right action}"
    return 1
  fi

  echo ""

  case "$action_type" in
    ADD_ITEM)
      log_ok "$(printf "${I18N_NLP_ROUTED:-→ Add backlog: %s}" "${W}${action_content}${N}")"
      echo ""
      _nlp_add_item "$action_content"
      ;;

    CONFIG_SUGGEST)
      log_ok "$(printf "${I18N_NLP_ROUTED:-→ Config change: %s}" "${W}${action_content}${N}")"
      _nlp_config_suggest "$action_content"
      ;;

    COMMAND)
      log_ok "$(printf "${I18N_NLP_ROUTED:-→ Running: %s}" "${W}${action_content}${N}")"
      echo ""
      local cmd="${action_content%% *}"
      local args="${action_content#* }"
      [[ "$args" == "$cmd" ]] && args=""
      case "$cmd" in
        auto)      cmd_auto ;;
        all)       cmd_all ;;
        start)     cmd_start "$args" ;;
        discover)  cmd_discover ;;
        add)       cmd_add ;;
        backlog)   cmd_backlog ;;
        status)    cmd_status ;;
        stop)      cmd_stop ;;
        plan)      cmd_plan ;;
        team)      cmd_team "$args" ;;
        config)    cmd_config "${args:-show}" ;;
        doctor)    cmd_doctor ;;
        *)         log_err "Unknown command: $cmd"; return 1 ;;
      esac
      ;;
  esac
}
