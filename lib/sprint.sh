# lib/sprint.sh — Sprint loop orchestration
# Sourced by harn.sh — do not execute directly

# ── Sprint loop main body ─────────────────────────────────────────────────────
_run_sprint_loop() {
  local max_sprints="${1:-10}"
  local run_dir
  run_dir=$(require_run_dir)

  # Always update current.log symlink (so tail works on resume too)
  local run_log="$run_dir/run.log"
  touch "$run_log"
  ln -sfn "$run_log" "$HARN_DIR/current.log"
  LOG_FILE="$run_log"

  # Initialize progress timer
  _progress_init

  # Save PID (so harn stop can find this process)
  echo "$$" > "$HARN_DIR/harn.pid"
  trap 'rm -f "$HARN_DIR/harn.pid"' EXIT
  trap 'rm -f "$HARN_DIR/harn.pid"; log_warn "$I18N_LOOP_INTERRUPTED"; exit 130' INT
  trap 'rm -f "$HARN_DIR/harn.pid"; log_warn "$I18N_LOOP_TERMINATED"; exit 143' TERM

  log_step "$(printf "$I18N_LOOP_STARTED" "$max_sprints")"

  for _ in $(seq 1 "$max_sprints"); do
    local sprint_num
    sprint_num=$(current_sprint_num "$run_dir")
    local sprint
    sprint=$(sprint_dir "$run_dir" "$sprint_num")

    # Show progress (enhanced box)
    local total_planned
    total_planned=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
    _print_run_progress "$run_dir"

    if [[ ! -f "$sprint/contract.md" ]]; then
      cmd_contract
    fi

    # Use already-completed iteration count as initial value on resume
    local iter
    iter=$(sprint_iteration "$sprint")

    if [[ "$(sprint_status "$sprint")" == "pass" ]]; then
      log_info "$(printf "$I18N_LOOP_SPRINT_PASSED" "$sprint_num")"
    elif [[ $iter -ge $MAX_ITERATIONS ]]; then
      log_warn "$(printf "$I18N_LOOP_SPRINT_MAX_ITER" "$sprint_num" "$MAX_ITERATIONS")"
    else
      while [[ $iter -lt $MAX_ITERATIONS ]]; do
        cmd_implement
        iter=$(sprint_iteration "$sprint")
        if ! cmd_evaluate; then
          log_err "$I18N_LOOP_EVAL_ERROR"
          return 1
        fi
        [[ "$(sprint_status "$sprint")" == "pass" ]] && break
      done
      if [[ "$(sprint_status "$sprint")" != "pass" ]]; then
        log_warn "$(printf "$I18N_LOOP_MAX_ITER_ADVANCE" "$sprint_num" "$MAX_ITERATIONS")"
      fi
    fi

    # Check if all sprints are complete
    local total
    total=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")

    if [[ $total -gt 0 && $sprint_num -ge $total ]]; then
      # ── Last sprint done: final cleanup and exit ────────────────────────────
      _log_raw ""
      _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
      _log_raw "${G}  ║  ✓  $(printf "$I18N_LOOP_ALL_COMPLETE" "$total")${N}"
      _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"
      cmd_next          # write handoff + move backlog to Done + set completed flag
      _git_final_commit
      if [[ "$HARN_SKIP_RETRO" != "true" ]]; then
        cmd_retrospective "$run_dir"
      fi
      break
    else
      # ── Intermediate sprint done: increment counter and move to next sprint ─
      log_info "$(printf "$I18N_LOOP_SPRINT_DONE" "$sprint_num" "$(( sprint_num + 1 ))")"
      _sprint_advance "$run_dir"
    fi
  done
}

# ── New task discovery ─────────────────────────────────────────────────────────
