# lib/commands.sh — Sprint commands (plan, contract, implement, evaluate, next)
# Sourced by harn.sh — do not execute directly

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_backlog() {
  _ensure_backlog_file
  echo -e "${W}${I18N_BACKLOG_TITLE}${N}"
  local slugs
  slugs=$(backlog_pending_slugs)
  if [[ -z "$slugs" ]]; then
    echo "  ${I18N_BACKLOG_EMPTY}"
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
  echo -e "$I18N_BACKLOG_RUN"
}

cmd_start() {
  local slug_or_prompt="${1:-}"
  # Internal: when set (by cmd_all/cmd_auto), skip sprint count prompt and use this value
  local _auto_sprint_count="${_HARN_AUTO_SPRINTS:-}"
  local max_sprints="${2:-10}"
  local max_sprints_arg="${2:-}"

  # No argument — show backlog list and prompt for a number
  if [[ -z "$slug_or_prompt" ]]; then
    _ensure_backlog_file

    local slugs
    slugs=$(backlog_pending_slugs)
    if [[ -z "$slugs" ]]; then
      log_warn "$I18N_START_NO_PENDING"
      log_info "$I18N_START_DISCOVER_HINT"
      exit 1
    fi

    echo -e "\n${W}${I18N_START_SELECT_ITEM}${N}"
    echo -e "${B}──────────────────────────────${N}"
    local i=1
    local slug_array=()
    while IFS= read -r s; do
      echo -e "  ${W}$i.${N} ${Y}$s${N}"
      slug_array+=("$s")
      i=$(( i + 1 ))
    done <<< "$slugs"
    echo ""
    printf "$(printf "$I18N_START_ENTER_NUM" "${#slug_array[@]}")"
    local choice; choice=$(_input_readline); echo ""

    if [[ "$choice" =~ ^[0-9]+$ ]] && \
       [[ "$choice" -ge 1 ]] && \
       [[ "$choice" -le "${#slug_array[@]}" ]]; then
      slug_or_prompt="${slug_array[$(( choice - 1 ))]}"
      log_info "$I18N_START_SELECTED ${W}$slug_or_prompt${N}"
    else
      log_err "$I18N_START_INVALID $choice"
      exit 1
    fi
  fi

  # ── Ask sprint count (skip in auto/all mode) ────────────────────────────────
  if [[ -n "$_auto_sprint_count" ]]; then
    SPRINT_COUNT="$_auto_sprint_count"
  else
    echo ""
    printf "%s" "$I18N_START_SPRINT_COUNT_PROMPT"
    local sc_input; sc_input=$(_input_readline); echo ""
    local sc="${sc_input:-1}"
    if ! [[ "$sc" =~ ^[1-9][0-9]*$ ]]; then
      log_warn "$I18N_START_SPRINT_COUNT_INVALID"
      sc=1
    fi
    SPRINT_COUNT="$sc"
  fi

  local run_id
  run_id=$(date +%Y%m%d-%H%M%S)
  local run_dir="$HARN_DIR/runs/$run_id"

  mkdir -p "$run_dir/sprints"
  echo "$slug_or_prompt" > "$run_dir/prompt.txt"
  echo "1" > "$run_dir/current_sprint"
  echo "$SPRINT_COUNT" > "$run_dir/sprint_count"

  # This run's dedicated log (current.log → symlink to this run's log)
  local run_log="$run_dir/run.log"
  ln -sfn "$run_log" "$HARN_DIR/current.log"
  LOG_FILE="$run_log"

  {
    echo "════════════════════════════════════════════════════════════"
    echo "  harn Sprint Harness"
    echo "  Run ID   : $run_id"
    echo "  Item     : $slug_or_prompt"
    echo "  Started  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════"
  } | tee -a "$LOG_FILE"

  ln -sfn "$run_dir" "$HARN_DIR/current"
  log_ok "$I18N_START_RUN_CREATED $run_id  (${W}$slug_or_prompt${N})"
  log_info "$I18N_START_VIEW_LOG  $run_log"

  if ! cmd_plan; then
    log_err "$I18N_START_PLAN_FAILED $run_log"
    return 1
  fi

  # If max sprints not specified as start argument, auto-calculate from backlog
  # to proceed from start to finish in one go.
  if [[ -z "$max_sprints_arg" ]]; then
    local planned_total
    planned_total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    if [[ "$planned_total" -gt 0 ]]; then
      max_sprints="$planned_total"
    fi
  fi

  log_step "$I18N_START_AUTO_LOOP"
  log_info "$(printf "$I18N_START_LOOP_DETAIL" "$max_sprints")"

  if ! _run_sprint_loop "$max_sprints"; then
    log_err "$(printf "$I18N_START_LOOP_INTERRUPTED" "$(basename "$run_dir")")"
    return 1
  fi

  if [[ -f "$run_dir/completed" ]]; then
    log_ok "$I18N_START_COMPLETE"
  else
    log_warn "$(printf "$I18N_START_MAX_SPRINT" "$max_sprints")"
  fi
}

cmd_plan() {
  local run_dir
  run_dir=$(require_run_dir)
  local slug_or_prompt
  slug_or_prompt=$(cat "$run_dir/prompt.txt")

  log_step "$I18N_PLAN_STEP"

  local context_block
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    local item_text
    item_text=$(backlog_item_text "$slug_or_prompt")
    context_block="## Backlog Item

\`\`\`
$item_text
\`\`\`

## Full Backlog (for reference)

$(cat "$BACKLOG_FILE")
"
  else
    context_block="## Request

$slug_or_prompt"
  fi

  local prompt
  # Build sprint structure instruction block — read count from run state
  local sprint_count_for_plan
  sprint_count_for_plan=$(cat "$run_dir/sprint_count" 2>/dev/null || echo "${SPRINT_COUNT:-1}")
  local sprint_instruction
  if [[ "$sprint_count_for_plan" -eq 1 ]]; then
    sprint_instruction="## Sprint Structure\n\nProduce exactly 1 sprint:\n- Sprint 001: Complete the full implementation including all layers and tests.\n"
  else
    sprint_instruction="## Sprint Structure (follow exactly)\n\nDivide the work into exactly ${sprint_count_for_plan} sprints. Each sprint must cover a distinct, self-contained scope of the overall task. Divide by feature area, layer, or logical component — not by implementation-vs-tests. Every sprint should be independently buildable and include its own tests.\n\n"
    for ((i=1; i<=sprint_count_for_plan; i++)); do
      sprint_instruction+="- Sprint $(printf '%03d' "$i"): [Scope $i of ${sprint_count_for_plan} — define based on the task]\n"
    done
  fi

  prompt="$(cat "$PROMPTS_DIR/planner.md")

---

$(printf '%b' "$sprint_instruction")

---

$context_block

---

## Output Instructions

Use the following section markers exactly in your output:

=== plan.text ===
[One-line plan text. Plain text, no markdown]

=== spec.md ===
[Product spec content]

=== sprint-backlog.md ===
[Sprint backlog content]"

  local raw="$run_dir/plan-raw.md"
  invoke_role "planner" "$prompt" "$raw" "Planner — expand backlog item into sprint spec" "inline" "$COPILOT_MODEL_PLANNER" "planner"

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
    log_warn "$I18N_PLAN_TEXT_NOT_FOUND"
  fi
  echo "$plan_text" > "$run_dir/plan.txt"

  if [[ ! -s "$run_dir/spec.md" ]]; then
    cp "$raw" "$run_dir/spec.md"
    log_warn "$I18N_PLAN_MARKERS_NOT_FOUND"
  fi

  log_ok "Spec → $run_dir/spec.md"
  log_ok "Sprint backlog → $run_dir/sprint-backlog.md"
  log_ok "Plan text → $run_dir/plan.txt"

  # Planning done → move backlog item from Pending → In Progress
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    python3 - "$BACKLOG_FILE" "$slug_or_prompt" <<'PYEOF'
import re, sys
path, slug = sys.argv[1], sys.argv[2]
content = open(path).read()

# Move from Pending to In Progress section
item_pattern = re.compile(
    r'(- \[ \] \*\*' + re.escape(slug) + r'\*\*[^\n]*(?:\n[ \t]+[^\n]*)*)',
    re.MULTILINE
)
match = item_pattern.search(content)
if not match:
    print(f'Item not found: {slug}')
    sys.exit(0)

item_text = match.group(1)
# Remove from original location
content = content[:match.start()] + content[match.end():]

# Add under In Progress section (create if missing)
if '## In Progress' in content:
    content = content.replace('## In Progress\n', '## In Progress\n' + item_text + '\n')
else:
    content = '## In Progress\n' + item_text + '\n\n' + content

open(path, 'w').write(content)
print(f'✓ {slug} → In Progress')
PYEOF
    log_ok "$(printf "$I18N_PLAN_ITEM_IN_PROGRESS" "$slug_or_prompt")"

    if backlog_upsert_plan_line "$slug_or_prompt" "$plan_text"; then
      log_ok "$I18N_PLAN_LINE_UPDATED ${W}$slug_or_prompt${N}"
    else
      case "$?" in
        2) log_warn "$I18N_PLAN_LINE_FAILED (${W}$slug_or_prompt${N})" ;;
        3) log_info "$I18N_PLAN_LINE_UNCHANGED" ;;
        *) log_warn "$I18N_PLAN_LINE_EXCEPTION (slug=${W}$slug_or_prompt${N})" ;;
      esac
    fi

  fi

  # Commit backlog file if git is enabled
  if [[ -f "$BACKLOG_FILE" ]] && [[ "$slug_or_prompt" != *" "* ]]; then
    _git_plan_commit "$slug_or_prompt"
  fi

  log_ok "$I18N_PLAN_COMPLETE"
}

cmd_contract() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ -f "$sprint/contract.md" ]] && {
    log_warn "$I18N_CONTRACT_EXISTS $sprint/contract.md"
    return 0
  }

  log_step "$(printf "$I18N_CONTRACT_STEP" "$sprint_num")"

  local prev_context=""
  for s in "$run_dir/sprints"/*/; do
    [[ "$s" == "$sprint"/ ]] && continue
    [[ -d "$s" ]] || continue
    local sn; sn=$(basename "$s")
    prev_context+="### Sprint $sn
$(cat "$s/handoff.md" 2>/dev/null || cat "$s/contract.md" 2>/dev/null || echo "(no info)")

"
  done

  local gen_prompt_file="$sprint/contract-gen-prompt.md"
  cat > "$gen_prompt_file" <<EOF
$(cat "$PROMPTS_DIR/generator.md")

---

## Product Spec

$(cat "$run_dir/spec.md")

## Sprint Backlog

$(cat "$run_dir/sprint-backlog.md" 2>/dev/null || echo "")

## Previous Sprint Context

$prev_context

---

## Task Instructions

You are the **Generator (Developer)**. Propose a detailed scope for **Sprint $sprint_num**.

Include:
1. **Sprint Goal** — one sentence
2. **Features to implement** — concrete deliverables
3. **PASS Criteria** — numbered, specific, verifiable
4. **Packages/Files** — items to create or modify
5. **Out of scope** — explicitly excluded items

Be specific. The evaluator will review each PASS criterion individually.
EOF

  # Inject user extra instructions
  if [[ -n "$USER_EXTRA_INSTRUCTIONS" ]]; then
    printf "\n\n---\n%s\n" "$USER_EXTRA_INSTRUCTIONS" >> "$gen_prompt_file"
    USER_EXTRA_INSTRUCTIONS=""
  fi

  invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal.md" "Generator — Sprint $sprint_num scope proposal" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT" "generator_contract"

  log_info "$I18N_CONTRACT_REVIEWING"
  local eval_prompt
  eval_prompt="$(cat "$PROMPTS_DIR/evaluator.md")

---

## Task: Sprint Scope Review

### Sprint $sprint_num Scope Proposal

$(cat "$sprint/contract-proposal.md")

**If clear and verifiable**: write \`APPROVED\` on its own line with a brief confirmation.
**If revision needed**: write \`NEEDS_REVISION\` on its own line and list specific revisions needed."

  invoke_role "evaluator" "$eval_prompt" "$sprint/contract-review.md" "Evaluator — Sprint $sprint_num scope review" "inline" "$COPILOT_MODEL_EVALUATOR_CONTRACT" "evaluator_contract"

  if grep -qi 'APPROVED' "$sprint/contract-review.md"; then
    cp "$sprint/contract-proposal.md" "$sprint/contract.md"
    log_ok "$(printf "$I18N_CONTRACT_APPROVED" "$sprint_num")"
  else
    log_warn "$I18N_CONTRACT_NEEDS_REVISION"
    cat >> "$gen_prompt_file" <<EOF

---

## Evaluator Feedback

$(cat "$sprint/contract-review.md")

Please revise the scope incorporating the above feedback.
EOF
    invoke_role "generator" "$gen_prompt_file" "$sprint/contract-proposal-v2.md" "Generator — Sprint $sprint_num scope revision" "file" "$COPILOT_MODEL_GENERATOR_CONTRACT" "generator_contract"
    cp "$sprint/contract-proposal-v2.md" "$sprint/contract.md"
    log_ok "$(printf "$I18N_CONTRACT_REVISED" "$sprint_num")"
  fi

  log_info "$I18N_CONTRACT_NEXT"
}

cmd_implement() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  [[ ! -f "$sprint/contract.md" ]] && {
    log_err "$(printf "$I18N_IMPL_NO_SCOPE" "$sprint_num")"
    exit 1
  }

  local iteration
  iteration=$(( $(sprint_iteration "$sprint") + 1 ))
  echo "$iteration" > "$sprint/iteration"

  log_step "$(printf "$I18N_IMPL_STEP" "$sprint_num" "$iteration")"

  local qa_feedback=""
  if [[ $iteration -gt 1 && -f "$sprint/qa-report.md" ]]; then
    qa_feedback="## Evaluator Feedback (iteration $((iteration - 1)))

$(cat "$sprint/qa-report.md")

**Resolve all FAIL criteria listed above.**"
  fi

  local prev_handoff=""
  local prev_num=$(( sprint_num - 1 ))
  if [[ -d "$run_dir/sprints/$(printf '%03d' "$prev_num")" ]]; then
    prev_handoff="## Previous Sprint Handoff

$(cat "$run_dir/sprints/$(printf '%03d' "$prev_num")/handoff.md" 2>/dev/null || echo "(none)")"
  fi

  local prompt_file="$sprint/gen-prompt-iter${iteration}.md"
  cat > "$prompt_file" <<EOF
$(cat "$PROMPTS_DIR/generator.md")

---

## Product Spec

$(cat "$run_dir/spec.md")

## Sprint $sprint_num Scope

$(cat "$sprint/contract.md")

$prev_handoff

$qa_feedback

---

## Task Instructions

Implement **Sprint $sprint_num** according to the scope above.
After implementation, write a summary at the end:

=== Implementation Summary ===
- What was implemented
- Key files created/modified
- Known constraints
EOF

  # Inject user extra instructions
  if [[ -n "$USER_EXTRA_INSTRUCTIONS" ]]; then
    printf "\n\n---\n%s\n" "$USER_EXTRA_INSTRUCTIONS" >> "$prompt_file"
    USER_EXTRA_INSTRUCTIONS=""
  fi

  echo "in-progress" > "$sprint/status"

  # First implementation: Opus (IMPL), QA FAIL retry: Sonnet (CONTRACT)
  local impl_model="$COPILOT_MODEL_GENERATOR_IMPL"
  [[ $iteration -gt 1 ]] && impl_model="$COPILOT_MODEL_GENERATOR_CONTRACT"

  invoke_role "generator" "$prompt_file" "$sprint/implementation-iter${iteration}.md" "Generator — Sprint $sprint_num implementation (iteration $iteration)" "file" "$impl_model" "generator_impl"
  cp "$sprint/implementation-iter${iteration}.md" "$sprint/implementation.md"

  log_ok "$(printf "$I18N_IMPL_COMPLETE" "$sprint_num" "$iteration")"

  # Git commit implementation results
  _git_commit_sprint_impl "$sprint_num" "$sprint"

  log_info "$I18N_IMPL_NEXT"
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
    log_err "$(printf "$I18N_EVAL_NO_IMPL" "$sprint_num")"
    exit 1
  }

  log_step "$(printf "$I18N_EVAL_STEP" "$sprint_num" "$iteration")"

  log_info "$I18N_EVAL_RUNNING_CHECKS"
  local test_results="$sprint/test-results.txt"
  {
    cd "$ROOT_DIR"

    # ── Static analysis / lint ──────────────────────────────────────────────
    if [[ -n "${LINT_COMMAND:-}" ]]; then
      echo "=== lint: $LINT_COMMAND ==="
      eval "$LINT_COMMAND" 2>&1 | tail -30 || true
    elif [[ -f "pubspec.yaml" ]] && command -v dart &>/dev/null; then
      echo "=== dart analyze ==="
      dart analyze 2>&1 | tail -30 || true
    elif [[ -f "package.json" ]] && command -v npx &>/dev/null; then
      echo "=== eslint / tsc ==="
      (npx tsc --noEmit 2>&1 | tail -20 || true)
    elif command -v go &>/dev/null && [[ -f "go.mod" ]]; then
      echo "=== go vet ==="
      go vet ./... 2>&1 | tail -20 || true
    else
      echo "(lint: no LINT_COMMAND configured — skipped)"
    fi
    echo ""

    # ── Unit / integration tests (last sprint only) ──────────────────────────
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    if [[ "$sprint_num" -eq "$total" ]]; then

      if [[ -n "${TEST_COMMAND:-}" ]]; then
        echo "=== tests: $TEST_COMMAND ==="
        eval "$TEST_COMMAND" 2>&1 | tail -50 || true
      elif [[ -f "pubspec.yaml" ]] && command -v flutter &>/dev/null; then
        echo "=== flutter test ==="
        flutter test --reporter compact 2>&1 | tail -50 || true
      elif [[ -f "package.json" ]] && grep -q '"test"' package.json; then
        echo "=== npm test ==="
        npm test --if-present 2>&1 | tail -50 || true
      elif [[ -f "Cargo.toml" ]] && command -v cargo &>/dev/null; then
        echo "=== cargo test ==="
        cargo test 2>&1 | tail -50 || true
      elif command -v pytest &>/dev/null; then
        echo "=== pytest ==="
        pytest 2>&1 | tail -50 || true
      elif [[ -f "go.mod" ]] && command -v go &>/dev/null; then
        echo "=== go test ==="
        go test ./... 2>&1 | tail -50 || true
      else
        echo "(tests: no TEST_COMMAND configured — skipped)"
        echo "Set TEST_COMMAND in .harn_config to enable automated tests"
      fi
      echo ""

      # ── E2E environment (optional) ─────────────────────────────────────────
      if [[ -n "${E2E_COMMAND:-}" ]]; then
        echo "=== E2E setup: $E2E_COMMAND ==="
        eval "$E2E_COMMAND" 2>&1 | tail -30 || true
        echo "=== E2E environment ready ==="
        echo ""
      fi
    fi
  } > "$test_results"
  log_info "$I18N_EVAL_CHECKS_DONE $test_results"

  # E2E environment context (last sprint only)
  local e2e_context=""
  if [[ -f "$sprint/e2e-env.txt" ]]; then
    e2e_context="
### E2E Test Environment
\`\`\`
$(cat "$sprint/e2e-env.txt")
\`\`\`

The services started at the URLs above are running.
Use **Playwright MCP tools** to test the app at http://localhost:3000 directly.
- Available tools: browser_navigate, browser_click, browser_snapshot, browser_screenshot
- Backend API available at http://localhost:8080
- Include test results in the report"
  fi

  local eval_prompt
  eval_prompt="$(cat "$PROMPTS_DIR/evaluator.md")

---

## Sprint $sprint_num QA

### Scope
$(cat "$sprint/contract.md")

### Implementation Summary
$(cat "$sprint/implementation.md")

### Automated Check Results
\`\`\`
$(cat "$test_results")
\`\`\`
$e2e_context

Write exactly one line at the end of the report:
\`VERDICT: PASS\`  or  \`VERDICT: FAIL\`"

  local eval_exit_code=0
  invoke_role "evaluator" "$eval_prompt" "$sprint/qa-report.md" "Evaluator — Sprint $sprint_num QA (iteration $iteration)" "inline" "$COPILOT_MODEL_EVALUATOR_QA" "evaluator_qa" || eval_exit_code=$?

  # Clean up background processes tracked in e2e-env.txt (if any)
  if [[ -f "$sprint/e2e-env.txt" ]]; then
    log_info "$I18N_EVAL_SHUTTING_DOWN"
    while IFS='=' read -r key val; do
      [[ "$key" == *_PID ]] && kill "$val" 2>/dev/null && log_info "$key ($val) stopped" || true
    done < "$sprint/e2e-env.txt"
  fi

  if [[ $eval_exit_code -ne 0 ]]; then
    echo "fail" > "$sprint/status"
    log_err "$(printf "$I18N_EVAL_EXEC_ERROR" "$sprint_num" "$eval_exit_code")"
    log_info "$I18N_EVAL_MANUAL_RESUME"
    return 1
  fi

  if grep -qiE 'VERDICT[[:space:]]*:[[:space:]]*PASS' "$sprint/qa-report.md"; then
    # ── Continuation Enforcement: verify actual file changes ──────────────────
    local has_changes="true"
    if command -v git &>/dev/null && [[ -d "$ROOT_DIR/.git" ]]; then
      cd "$ROOT_DIR"
      local changed_files
      changed_files=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')
      local untracked
      untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$changed_files" -eq 0 && "$untracked" -eq 0 ]]; then
        has_changes="false"
      fi
    fi

    if [[ "$has_changes" == "false" ]]; then
      echo "fail" > "$sprint/status"
      log_warn "$(printf "${I18N_EVAL_NO_CHANGES:-PASS verdict but no actual file changes detected — overriding to FAIL (Sprint %s)}" "$sprint_num")"
      # Save to memory for future learning
      _memory_append "Sprint $sprint_num: PASS verdict overridden to FAIL — no actual file changes." 2>/dev/null || true
    else
      echo "pass" > "$sprint/status"
      log_ok "$(printf "$I18N_EVAL_PASS" "$sprint_num")"
      log_info "$I18N_EVAL_NEXT"
    fi
  else
    echo "fail" > "$sprint/status"
    local cur_iter
    cur_iter=$(sprint_iteration "$sprint")
    log_warn "$(printf "$I18N_EVAL_FAIL" "$sprint_num" "$cur_iter" "$MAX_ITERATIONS" "$sprint/qa-report.md")"
    # Save failure pattern to memory for future learning
    _memory_extract_from_failure "$sprint" 2>/dev/null || true
  fi
}

# Internal: only increments sprint counter (used for sprint transitions in auto mode)
_sprint_advance() {
  local run_dir="$1"
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local next_num=$(( sprint_num + 1 ))
  echo "$next_num" > "$run_dir/current_sprint"
  log_info "$(printf "$I18N_SPRINT_SWITCH" "$next_num")"
}

cmd_next() {
  local run_dir
  run_dir=$(require_run_dir)
  local sprint_num
  sprint_num=$(current_sprint_num "$run_dir")
  local sprint
  sprint=$(sprint_dir "$run_dir" "$sprint_num")

  log_step "$I18N_NEXT_STEP"

  # Write final completion summary
  invoke_role "evaluator" "$(cat "$PROMPTS_DIR/evaluator.md")

## Task: Final Completion Summary

### Scope
$(cat "$sprint/contract.md" 2>/dev/null || echo '(none)')

### Implementation Summary
$(cat "$sprint/implementation.md" 2>/dev/null || echo '(none)')

### QA Report
$(cat "$sprint/qa-report.md" 2>/dev/null || echo '(none)')

Write a completion summary for the full work (max 300 chars):
1. Summary of what was implemented
2. Key changed files
3. Known limitations or follow-up tasks" \
    "$sprint/handoff.md" "Evaluator — final completion summary" "inline" "$COPILOT_MODEL_EVALUATOR_QA" "evaluator_qa"

  # Backlog → Done move
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
    log_ok "$(printf "$I18N_NEXT_DONE" "$slug_or_prompt")"
  fi

  # Completion flag (prevents auto resumption)
  touch "$run_dir/completed"
  rm -f "$HARN_DIR/current"

  log_ok "$(printf "$I18N_NEXT_COMPLETE" "$slug_or_prompt")"
}

cmd_stop() {
  local pid_file="$HARN_DIR/harn.pid"

  if [[ ! -f "$pid_file" ]]; then
    log_warn "$I18N_STOP_NO_PID"
    log_info "$I18N_STOP_ALREADY_HINT"
    return 0
  fi

  local pid
  pid=$(cat "$pid_file")

  if ! kill -0 "$pid" 2>/dev/null; then
    log_warn "$(printf "$I18N_STOP_STALE_PID" "$pid")"
    rm -f "$pid_file"
    return 0
  fi

  log_info "$(printf "$I18N_STOP_STOPPING" "$pid")"

  # Send SIGTERM to the entire process group (including claude/copilot child processes)
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 2

  # If still alive, send SIGKILL
  if kill -0 "$pid" 2>/dev/null; then
    log_warn "$I18N_STOP_SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"

  # Mark current sprint as cancelled
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
    log_ok "$I18N_STOP_RUN_STOPPED: ${W}$(basename "$run_dir")${N}"
  else
    log_ok "$I18N_STOP_DONE"
  fi
}

