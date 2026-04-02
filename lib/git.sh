# lib/git.sh — Git commit helpers
# Sourced by harn.sh — do not execute directly

# ── Git helpers (commit-only) ─────────────────────────────────────────────────

# Called after cmd_plan: commit backlog file
_git_plan_commit() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0
  local slug="$1"
  if [[ -f "$BACKLOG_FILE" ]]; then
    cd "$ROOT_DIR"
    git add "$BACKLOG_FILE"
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit -m "plan: ${slug} — planning started" \
        2>&1 | while IFS= read -r line; do log_info "$line"; done
      log_ok "$I18N_GIT_BACKLOG_COMMITTED"
    else
      log_info "$I18N_GIT_BACKLOG_UNCHANGED"
    fi
  fi
}

# Called after cmd_implement: commit implementation changes with structured context
_git_commit_sprint_impl() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  local sprint_num="$1" sprint_dir_path="$2"
  local iteration
  iteration=$(cat "$sprint_dir_path/iteration" 2>/dev/null || echo "1")

  local sprint_goal
  sprint_goal=$(grep -m1 '^\*\*Goal\*\*\|^Goal:' "$sprint_dir_path/contract.md" 2>/dev/null \
    | sed 's/^\*\*Goal\*\*[: ]*//;s/^Goal[: ]*//' | xargs)
  [[ -z "$sprint_goal" ]] && sprint_goal="Sprint ${sprint_num} implementation"

  # Build structured commit message (omc-style commit protocol)
  local commit_msg="feat(sprint-${sprint_num}): ${sprint_goal}"
  [[ "$iteration" -gt 1 ]] && commit_msg="${commit_msg} (retry ${iteration})"

  # Extract decision context from implementation output
  local impl_file="$sprint_dir_path/implementation.md"
  if [[ -f "$impl_file" ]]; then
    local constraints=""
    constraints=$(grep -i 'constraint\|limitation\|caveat\|trade-off' "$impl_file" 2>/dev/null | head -3 | sed 's/^[[:space:]]*/  /' || true)
    local scope_info=""
    scope_info=$(grep -i 'out of scope\|not included\|excluded' "$impl_file" 2>/dev/null | head -2 | sed 's/^[[:space:]]*/  /' || true)

    commit_msg="${commit_msg}

Sprint: ${sprint_num} | Iteration: ${iteration}"
    [[ -n "$constraints" ]] && commit_msg="${commit_msg}
Constraints:
${constraints}"
    [[ -n "$scope_info" ]] && commit_msg="${commit_msg}
Scope-excluded:
${scope_info}"
    commit_msg="${commit_msg}
Confidence: $([ "$iteration" -le 1 ] && echo "high" || echo "medium")"
  fi

  log_step "$(printf "$I18N_GIT_IMPL_COMMIT" "$sprint_num")"

  cd "$ROOT_DIR"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    log_info "$I18N_GIT_NO_CHANGES"
    return 0
  fi

  git commit -m "$commit_msg" \
    2>&1 | while IFS= read -r line; do log_info "$line"; done
  log_ok "$(printf "$I18N_GIT_COMMIT_DONE" "feat(sprint-${sprint_num}): ${sprint_goal}")"
}

# Called at run completion: commit any remaining changes
_git_final_commit() {
  [[ "$GIT_ENABLED" != "true" ]] && return 0

  log_step "$I18N_GIT_FINAL_COMMIT"
  cd "$ROOT_DIR"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    log_info "$I18N_GIT_NO_CHANGES"
    return 0
  fi

  local commit_msg="chore: harn sprint complete"
  git commit -m "$commit_msg" \
    2>&1 | while IFS= read -r line; do log_info "$line"; done
  log_ok "$(printf "$I18N_GIT_COMMIT_DONE" "$commit_msg")"
}

