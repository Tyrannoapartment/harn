# lib/retro.sh — Retrospective analysis
# Sourced by harn.sh — do not execute directly

# ── Retrospective ──────────────────────────────────────────────────────────────
cmd_retrospective() {
  local run_dir="$1"
  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_warn "$I18N_RETRO_NO_CLI"
    return 0
  fi

  log_step "$I18N_RETRO_STEP"

  # ── Context collection ─────────────────────────────────────────────────────
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

## Current Run Data

**Backlog item**: ${backlog_item}

**Sprint summary**:
${sprint_summary}

**Current planner prompt**:
$(cat "$PROMPTS_DIR/planner.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/planner.md")

**Current generator prompt**:
$(cat "$PROMPTS_DIR/generator.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/generator.md")

**Current evaluator prompt**:
$(cat "$PROMPTS_DIR/evaluator.md" 2>/dev/null || cat "$SCRIPT_DIR/prompts/evaluator.md")"

  local retro_out="$run_dir/retrospective.md"
  log_info "$(printf "$I18N_RETRO_ANALYZING" "$ai_cmd")"
  if ! _ai_generate "$ai_cmd" "$prompt" "$retro_out"; then
    log_warn "$I18N_RETRO_FAILED"
    return 0
  fi

  # ── Auto-save learnings to project memory ──────────────────────────────────
  _memory_extract_from_retro "$retro_out"

  # ── Print summary ──────────────────────────────────────────────────────────
  local summary
  summary=$(awk '/^=== retro-summary ===$/{f=1;next} /^=== /{f=0} f{print}' "$retro_out")
  if [[ -n "$summary" ]]; then
    echo ""
    echo -e "${W}${I18N_RETRO_SUMMARY_TITLE}${N}"
    echo -e "${D}  ────────────────────────────────────${N}"
    echo "$summary" | while IFS= read -r line; do
      echo -e "  $line"
    done
    echo ""
  fi

  # ── Review prompt improvement suggestions ────────────────────────────────────
  local roles="planner generator evaluator"
  local role_names=("planner:Planner" "generator:Generator" "evaluator:Evaluator")
  local any_applied=false

  for role_pair in "${role_names[@]}"; do
    local role="${role_pair%%:*}"
    local role_kr="${role_pair##*:}"

    local suggestion
    suggestion=$(awk "/^=== prompt-suggestion:${role} ===$/{f=1;next} /^=== /{f=0} f{print}" "$retro_out" | sed '/^$/d')

    [[ -z "$suggestion" || "$suggestion" == "none" ]] && continue

    echo -e "${C}  ╭─ 💡 ${role_kr} prompt improvement suggestion${N}"
    echo "$suggestion" | while IFS= read -r line; do
      echo -e "${C}  │${N}  $line"
    done
    echo -e "${C}  ╰${N}"
    echo ""
    printf "$(printf "$I18N_RETRO_PROMPT_ADD" "$role_kr")"
    local yn; yn=$(_input_readline); echo ""

    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
      # Add to custom prompt file or base file
      local target_prompt="$PROMPTS_DIR/${role}.md"
      if [[ ! -f "$target_prompt" ]]; then
        # Not in custom directory — copy base file then add
        mkdir -p "$PROMPTS_DIR"
        cp "$SCRIPT_DIR/prompts/${role}.md" "$target_prompt"
      fi
      printf '\n\n## Retrospective Improvements (%s)\n\n%s\n' "$(date '+%Y-%m-%d')" "$suggestion" >> "$target_prompt"
      log_ok "$(printf "$I18N_RETRO_ADDED" "$role_kr" "$target_prompt")"
      any_applied=true
    else
      log_info "$(printf "$I18N_RETRO_SKIPPED" "$role_kr")"
    fi
  done

  if [[ "$any_applied" == "true" ]]; then
    # Reflect custom prompt directory in config
    if [[ "$PROMPTS_DIR" != "$SCRIPT_DIR/prompts" ]]; then
      local rel_dir="${PROMPTS_DIR#$ROOT_DIR/}"
      sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${rel_dir}\"|" "$CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "$I18N_RETRO_APPLIED"
  fi

  log_ok "$(printf "$I18N_RETRO_COMPLETE" "$retro_out")"
}

