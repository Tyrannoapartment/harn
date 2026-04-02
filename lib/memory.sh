# lib/memory.sh — Project memory (cross-session learnings)
# Sourced by harn.sh — do not execute directly

MEMORY_FILE="$HARN_DIR/memory.md"

_memory_load() {
  [[ -f "$MEMORY_FILE" ]] && cat "$MEMORY_FILE" || echo ""
}

_memory_append() {
  local entry="$1"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M')
  mkdir -p "$(dirname "$MEMORY_FILE")"
  if [[ ! -f "$MEMORY_FILE" ]]; then
    echo "# Project Memory" > "$MEMORY_FILE"
    echo "" >> "$MEMORY_FILE"
    echo "Auto-collected learnings from sprint runs." >> "$MEMORY_FILE"
    echo "" >> "$MEMORY_FILE"
  fi
  {
    echo "### $ts"
    echo ""
    echo "$entry"
    echo ""
  } >> "$MEMORY_FILE"
  log_info "💾 ${I18N_MEMORY_SAVED:-Memory saved}"
}

# Inject project memory into an agent prompt
_memory_inject() {
  local content
  content=$(_memory_load)
  [[ -z "$content" ]] && return
  # Limit to last 3000 chars to avoid bloating prompts
  local trimmed
  trimmed=$(echo "$content" | tail -c 3000)
  cat <<EOF
## Project Memory (cross-session learnings)

$trimmed

---
EOF
}

# Extract learnings from retrospective output and save to memory
_memory_extract_from_retro() {
  local retro_file="$1"
  [[ ! -f "$retro_file" ]] && return
  local summary
  summary=$(awk '/^=== retro-summary ===$/{f=1;next} /^=== /{f=0} f{print}' "$retro_file")
  [[ -z "$summary" ]] && return
  _memory_append "$summary"
}

# Extract learnings from a failed sprint (common pitfalls)
_memory_extract_from_failure() {
  local sprint_dir="$1"
  [[ ! -f "$sprint_dir/qa-report.md" ]] && return
  local iteration
  iteration=$(sprint_iteration "$sprint_dir")
  [[ "$iteration" -lt 2 ]] && return
  local failures
  failures=$(grep -i 'FAIL\|error\|issue\|problem' "$sprint_dir/qa-report.md" | head -5)
  [[ -z "$failures" ]] && return
  _memory_append "**Sprint failure pattern (iteration $iteration):**
$failures"
}
