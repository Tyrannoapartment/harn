# lib/discover.sh — Task discovery and backlog item creation
# Sourced by harn.sh — do not execute directly

# ── New task discovery ─────────────────────────────────────────────────────────

cmd_discover() {
  log_step "$I18N_DISCOVER_STEP"

  mkdir -p "$HARN_DIR"
  LOG_FILE="$HARN_DIR/harn.log"

  local out_file="$HARN_DIR/discovery-$(date +%Y%m%d-%H%M%S).md"
  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt
  prompt="You are a senior engineer analyzing the **Servan** project codebase.

> **Language instruction**: Write all descriptions, goals, and reasoning in **English**. Slugs, code, and file paths stay in English.

## Servan Architecture

Servan is a Dart/Flutter monorepo — AI Report Dispatcher.
Bounded contexts: Report, Transform, Dispatch, Device, Auth, Feedback.
Key packages: packages/domain, packages/application, packages/infrastructure, packages/features/*, services/backend, services/mcp, apps/mobile.

## Current Backlog (do NOT duplicate these)

\`\`\`
$current_backlog
\`\`\`

## Your Task

Scan the codebase for:
1. TODO / FIXME / HACK comments
2. Incomplete features (stub, placeholder, not-implemented)
3. Critical paths with no tests
4. Architecture violations or layer rule violations
5. New features that add user value

Pick the **2–4 highest-value items** not already in the backlog above.

## Output Format

Output ONLY this block — nothing else:

=== new-items ===
- [ ] **slug-for-item**
  English description (1–2 lines): what to do and why.

- [ ] **another-slug**
  English description.

Rules:
- slug: hyphenated-lowercase, max 50 chars
- 2–4 items only
- No duplicates with existing backlog"

  local discover_backend
  discover_backend="${AI_BACKEND_PLANNER:-$(_detect_ai_cli)}"
  if ! _ai_generate "$discover_backend" "$prompt" "$out_file" "$COPILOT_MODEL_PLANNER" "quiet"; then
    log_warn "$(printf "$I18N_DISCOVER_NO_ITEMS" "$out_file")"
    return 0
  fi

  # Extract content after section marker
  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "$(printf "$I18N_DISCOVER_NO_ITEMS" "$out_file")"
    return 0
  fi

  # Create default structure if backlog file doesn't exist
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "$I18N_DISCOVER_BACKLOG_CREATED $BACKLOG_FILE"
  fi

  # Add to Pending section via temp file (pipe + heredoc stdin conflict workaround)
  local items_tmp; items_tmp=$(mktemp)
  printf '%s' "${new_items}" > "$items_tmp"
  python3 - "$BACKLOG_FILE" "$items_tmp" <<'PYEOF'
import sys, re

path = sys.argv[1]
items_file = sys.argv[2]
new_items_text = open(items_file, encoding='utf-8').read().strip()
if not new_items_text:
    sys.exit(0)

content = open(path, encoding='utf-8').read()
lines = content.splitlines()

pending_start = None
for i, line in enumerate(lines):
    if re.match(r'^## Pending\s*$', line):
        pending_start = i
    elif pending_start is not None and re.match(r'^## ', line):
        break

insert_lines = [''] + new_items_text.splitlines() + ['']

if pending_start is None:
    lines += ['', '## Pending'] + insert_lines
else:
    lines[pending_start + 1:pending_start + 1] = insert_lines

open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF
  rm -f "$items_tmp"

  log_ok "$I18N_DISCOVER_ADDED"
  echo ""
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r line; do
    echo -e "  ${Y}$line${N}"
  done
  echo ""
  log_info "$I18N_DISCOVER_HINT"
}

# ── Add backlog item ───────────────────────────────────────────────────────────

cmd_add() {
  log_step "$I18N_ADD_STEP"

  # Create default structure if backlog file doesn't exist
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    mkdir -p "$(dirname "$BACKLOG_FILE")"
    cat > "$BACKLOG_FILE" <<'BEOF'
# Sprint Backlog

## In Progress

## Pending

## Done
BEOF
    log_info "$I18N_ADD_BACKLOG_CREATED $BACKLOG_FILE"
  fi

  echo -e ""
  echo -e "${B}  ╭─ $I18N_ADD_BOX_TITLE${N}"
  echo -e "${B}  │${N}  $I18N_ADD_BOX_DESC"
  echo -e "${B}  │${N}  $I18N_ADD_BOX_AI"
  echo -e "${B}  │${N}  ${D}$I18N_ADD_BOX_HINT${N}"
  echo -e "${B}  ╰${N}"

  local user_input
  user_input=$(_input_multiline)

  if [[ -z "$user_input" ]]; then
    log_warn "$I18N_ADD_CANCELLED"
    return 0
  fi

  local ai_cmd; ai_cmd=$(_detect_ai_cli)
  if [[ -z "$ai_cmd" ]]; then
    log_err "$I18N_ADD_NO_CLI"
    exit 1
  fi

  local current_backlog=""
  [[ -f "$BACKLOG_FILE" ]] && current_backlog=$(cat "$BACKLOG_FILE")

  local prompt
  prompt="You are a sprint backlog manager.

> **Language**: Write all descriptions in English. Slugs, code, and file names stay in English.

## Current Backlog
\`\`\`
${current_backlog}
\`\`\`

## User Request
${user_input}

## Task
Generate 1–3 backlog items based on the request above.
Do not duplicate existing backlog items.

## Output Format (output ONLY this block — nothing else)

=== new-items ===
- [ ] **slug-for-item**
  English description (1–2 lines): what to do and why.

Rules:
- slug: hyphenated-lowercase, max 50 chars
- Description indented 2 spaces directly below the item
- 1–3 items only"

  log_info "$(printf "$I18N_ADD_GENERATING" "$ai_cmd")"

  local out_file="$HARN_DIR/add-$(date +%Y%m%d-%H%M%S).md"
  mkdir -p "$HARN_DIR"

  if ! _ai_generate "$ai_cmd" "$prompt" "$out_file"; then
    log_err "$I18N_ADD_FAILED"
    return 1
  fi

  local new_items
  new_items=$(awk '/^=== new-items ===$/{f=1;next} f{print}' "$out_file")

  if [[ -z "$new_items" ]]; then
    log_warn "$(printf "$I18N_ADD_NO_ITEMS" "$out_file")"
    return 0
  fi

  # Add to Pending section via temp file (pipe + heredoc stdin conflict workaround)
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

# Find ## Pending section
pending_start = None
for i, line in enumerate(lines):
    if re.match(r'^## Pending\s*$', line):
        pending_start = i
        break

insert_lines = [''] + new_items_text.splitlines() + ['']

if pending_start is None:
    lines += ['', '## Pending'] + insert_lines
else:
    lines[pending_start + 1:pending_start + 1] = insert_lines

open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PYEOF
  rm -f "$items_tmp"

  echo ""
  log_ok "$I18N_ADD_DONE"
  echo "$new_items" | grep -E '^\- \[ \] \*\*' | while IFS= read -r item; do
    echo -e "  ${C}▸${N} $item"
  done
  echo ""
  log_info "$I18N_ADD_HINT"
}

# ── Auto mode ──────────────────────────────────────────────────────────────────
