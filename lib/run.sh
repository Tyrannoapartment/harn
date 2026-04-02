# lib/run.sh — Run directory and sprint state management
# Sourced by harn.sh — do not execute directly

# ── Run management ──────────────────────────────────────────────────────────────
mkdir -p "$HARN_DIR/runs"

current_run_id() {
  [[ -L "$HARN_DIR/current" ]] && basename "$(readlink "$HARN_DIR/current")" || echo ""
}

require_run_dir() {
  local id
  id=$(current_run_id)
  [[ -z "$id" ]] && { log_err "No active run. Use: harn start"; exit 1; }
  echo "$HARN_DIR/runs/$id"
}

# Must be called in the current shell, not a subshell
sync_run_log() {
  local id
  id=$(current_run_id)
  [[ -z "$id" ]] && return 0
  LOG_FILE="$HARN_DIR/runs/$id/run.log"
  touch "$LOG_FILE"
  ln -sfn "$LOG_FILE" "$HARN_DIR/current.log"
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

# ── Real-time markdown color renderer ─────────────────────────────────────────
# Pipe stdin → md_stream.py → colored rendering stdout
# Saved to log file without ANSI codes, displayed with color in terminal
