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

backlog_move_item_section() {
  local slug="$1"
  local target_section="$2"
  local mark_done="${3:-false}"

  [[ ! -f "$BACKLOG_FILE" ]] && return 1

  python3 - "$BACKLOG_FILE" "$slug" "$target_section" "$mark_done" <<'PYEOF'
import re
import sys

path, slug, target_section, mark_done = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].lower() == 'true'
content = open(path, encoding='utf-8').read()
lines = content.splitlines()

slug_pattern = re.compile(r'^- \[[ x]\] \*\*' + re.escape(slug) + r'\*\*')

sections = []
current_name = None
current_start = None
for idx, line in enumerate(lines):
    if line.startswith('## '):
        if current_name is not None:
            sections.append((current_name, current_start, idx))
        current_name = line[3:].strip()
        current_start = idx
if current_name is not None:
    sections.append((current_name, current_start, len(lines)))

item_start = None
item_end = None
for _, sec_start, sec_end in sections:
    i = sec_start + 1
    while i < sec_end:
        if slug_pattern.match(lines[i]):
            item_start = i
            j = i + 1
            while j < sec_end and not lines[j].startswith('- [') and not lines[j].startswith('## '):
                j += 1
            item_end = j
            break
        i += 1
    if item_start is not None:
        break

if item_start is None:
    print(f'NOT_FOUND:{slug}')
    sys.exit(2)

item_lines = lines[item_start:item_end]
if mark_done:
    item_lines[0] = re.sub(r'^- \[ \]', '- [x]', item_lines[0], count=1)

del lines[item_start:item_end]

target_index = None
for sec_name, sec_start, _ in sections:
    if sec_name.strip().lower() == target_section.strip().lower():
        target_index = sec_start + 1
        break

if target_index is None:
    if lines and lines[-1] != '':
        lines.append('')
    lines.append(f'## {target_section}')
    target_index = len(lines)

insert_block = item_lines[:]
if target_index < len(lines) and lines[target_index:target_index + 1] != ['']:
    insert_block.append('')
lines[target_index:target_index] = insert_block

new_content = '\n'.join(lines)
if content.endswith('\n'):
    new_content += '\n'
open(path, 'w', encoding='utf-8').write(new_content)
print('MOVED')
PYEOF
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
