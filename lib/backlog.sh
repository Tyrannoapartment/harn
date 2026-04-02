# lib/backlog.sh — Backlog file operations
# Sourced by harn.sh — do not execute directly

# ── Backlog helpers ───────────────────────────────────────────────────────────

# Pending item slug list (in-progress → pending order)
_ensure_backlog_file() {
  [[ -f "$BACKLOG_FILE" ]] && return 0
  log_warn "Backlog file not found: ${W}$BACKLOG_FILE${N}"
  log_info "Creating default backlog file..."
  mkdir -p "$(dirname "$BACKLOG_FILE")"
  cat > "$BACKLOG_FILE" <<'BACKLOG_EOF'
# Sprint Backlog

## Pending
<!-- Add backlog items below. Format:
- [ ] **slug-name**
  Brief description of the feature or task.
-->

## In Progress

## Done
BACKLOG_EOF
  log_ok "Created: ${W}$BACKLOG_FILE${N}"
  log_info "Add items with: ${W}harn add${N}  or edit the file directly"
  echo ""
}

backlog_pending_slugs() {
  [[ ! -f "$BACKLOG_FILE" ]] && return
  python3 - "$BACKLOG_FILE" <<'EOF'
import re, sys

content = open(sys.argv[1]).read()
sections = re.split(r'^## ', content, flags=re.MULTILINE)

in_progress = []
pending = []
for section in sections:
    name = section.split('\n', 1)[0].strip().lower()
    items = re.findall(r'- \[ \] \*\*([^*]+)\*\*', section)
    if 'in progress' in name:
        in_progress.extend(items)
    elif 'pending' in name:
        pending.extend(items)

for slug in in_progress + pending:
    print(slug)
EOF
}

# Return the full description block for a given slug
backlog_item_text() {
  local slug="$1"
  [[ ! -f "$BACKLOG_FILE" ]] && echo "(backlog not found)" && return
  python3 - "$BACKLOG_FILE" "$slug" <<'EOF'
import re, sys

content = open(sys.argv[1]).read()
slug = sys.argv[2]

pattern = r'(- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*[^\n]*\n(?:[ \t]+[^\n]*\n)*)'
match = re.search(pattern, content)
if match:
    print(match.group(1).strip())
else:
    print(f'(item "{slug}" not found in backlog)')
EOF
}

# Select next item: in-progress → pending order
backlog_next_slug() {
  backlog_pending_slugs | head -1
}

# Mark backlog item as done [x]
backlog_mark_done() {
  local slug="$1"
  [[ ! -f "$BACKLOG_FILE" ]] && return
  sed -i '' "s/- \[ \] \*\*${slug}\*\*/- [x] **${slug}**/" "$BACKLOG_FILE"
  log_ok "Backlog: ${W}$slug${N} marked as done"
}

# Upsert plan line for selected backlog item (In Progress items take priority)
backlog_upsert_plan_line() {
  local slug="$1"
  local plan_text="$2"

  [[ ! -f "$BACKLOG_FILE" ]] && return 2

  python3 - "$BACKLOG_FILE" "$slug" "$plan_text" <<'PYEOF'
import re
import sys

path, slug, plan_text = sys.argv[1], sys.argv[2], sys.argv[3].strip()
content = open(path, encoding='utf-8').read()
lines = content.splitlines()

slug_pattern = re.compile(r'^- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*')
plan_pattern = re.compile(r'^\s+plan:\s*')

candidates = []
i = 0
current_section = ''
while i < len(lines):
    line = lines[i]
    if line.startswith('## '):
        current_section = line[3:].strip().lower()
        i += 1
        continue

    if slug_pattern.match(line):
        start = i
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            if nxt.startswith('## '):
                break
            if nxt.startswith('- ['):
                break
            j += 1
        candidates.append((current_section, start, j))
        i = j
        continue

    i += 1

if not candidates:
    print(f'NOT_FOUND:{slug}')
    sys.exit(2)

target = None
for cand in candidates:
    if 'in progress' in cand[0]:
        target = cand
        break
if target is None:
    target = candidates[0]

_, start, end = target
item_lines = lines[start:end]
new_plan_line = f'  plan: {plan_text}'

changed = False
plan_idx = None
for idx in range(1, len(item_lines)):
    if plan_pattern.match(item_lines[idx]):
        plan_idx = idx
        break

if plan_idx is not None:
    if item_lines[plan_idx] != new_plan_line:
        item_lines[plan_idx] = new_plan_line
        changed = True
else:
    item_lines.insert(1, new_plan_line)
    changed = True

if not changed:
    print('UNCHANGED')
    sys.exit(3)

lines[start:end] = item_lines
new_content = '\n'.join(lines) + ('\n' if content.endswith('\n') else '')
open(path, 'w', encoding='utf-8').write(new_content)
print('UPDATED')
PYEOF
}

# ── Run management ──────────────────────────────────────────────────────────────
mkdir -p "$HARN_DIR/runs"
