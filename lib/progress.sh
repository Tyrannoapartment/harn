# lib/progress.sh — Enhanced progress display
# Sourced by harn.sh — do not execute directly

_HARN_RUN_START_TIME=""

_progress_init() {
  _HARN_RUN_START_TIME=$(date +%s)
}

_progress_elapsed() {
  [[ -z "$_HARN_RUN_START_TIME" ]] && { echo "0:00"; return; }
  local now elapsed min sec
  now=$(date +%s)
  elapsed=$(( now - _HARN_RUN_START_TIME ))
  min=$(( elapsed / 60 ))
  sec=$(( elapsed % 60 ))
  printf '%d:%02d' "$min" "$sec"
}

# Generate a visual progress bar string
# Usage: _progress_bar <current> <total> [width]
_progress_bar() {
  local current="$1" total="$2" width="${3:-20}"
  [[ "$total" -le 0 ]] && return
  local pct filled bar i
  pct=$(( current * 100 / total ))
  filled=$(( current * width / total ))
  bar=""
  for i in $(seq 1 "$width"); do
    if [[ $i -le $filled ]]; then bar="${bar}█"
    else bar="${bar}░"; fi
  done
  echo "${G}${bar}${N} ${G}${pct}%${N}"
}

# Display comprehensive run progress box
_print_run_progress() {
  local run_dir="$1"
  [[ ! -d "$run_dir" ]] && return

  local sprint_num total_sprints elapsed
  sprint_num=$(current_sprint_num "$run_dir")
  total_sprints=$(count_sprints_in_backlog "$run_dir/sprint-backlog.md")
  [[ "$total_sprints" -le 0 ]] && total_sprints=1
  elapsed=$(_progress_elapsed)

  # Count sprint statuses
  local passed=0 failed=0 in_prog=0 pending_count=0
  for s in "$run_dir/sprints"/*/; do
    [[ -d "$s" ]] || continue
    case "$(sprint_status "$s")" in
      pass)        passed=$(( passed + 1 )) ;;
      fail)        failed=$(( failed + 1 )) ;;
      in-progress) in_prog=$(( in_prog + 1 )) ;;
      *)           pending_count=$(( pending_count + 1 )) ;;
    esac
  done

  local completed_count
  completed_count="$passed"

  local bar
  bar=$(_progress_bar "$completed_count" "$total_sprints" 20)

  local slug
  slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || echo "?")

  _log_raw ""
  _log_raw "  ${C}╭─ Progress ──────────────────────────────────────────────╮${N}"
  _log_raw "  ${C}│${N}  ${W}${slug}${N}"
  _log_raw "  ${C}│${N}  Sprint ${W}${sprint_num}${N}/${total_sprints}  completed ${W}${completed_count}${N}/${total_sprints}  ${bar}  ⏱  ${elapsed}"
  _log_raw "  ${C}│${N}  ${G}✓ ${passed} pass${N}  ${R}✗ ${failed} fail${N}  ${Y}↻ ${in_prog} active${N}  ${D}⏳ ${pending_count} pending${N}"
  _log_raw "  ${C}╰─────────────────────────────────────────────────────────╯${N}"
  _log_raw ""
}

# Show all-mode batch progress
_print_batch_progress() {
  local current="$1" total="$2" slug="$3"
  local bar
  bar=$(_progress_bar "$current" "$total" 16)
  _log_raw ""
  _log_raw "  ${C}╭─ Batch ${current}/${total} ─────────────────────────╮${N}"
  _log_raw "  ${C}│${N}  ${G}${bar}${N}  ${W}${slug}${N}"
  _log_raw "  ${C}╰──────────────────────────────────────────╯${N}"
}
