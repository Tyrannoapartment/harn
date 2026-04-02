#!/usr/bin/env python3
"""Real-time markdown color renderer — harn pipeline only"""
import sys, re, io, unicodedata

W='\033[1;37m'; B='\033[0;34m'; C='\033[0;36m'
Y='\033[1;33m'; G='\033[0;32m'; D='\033[2m'; N='\033[0m'

# Handle non-UTF-8 bytes gracefully (e.g. claude --verbose JSON output)
stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace')

def display_width(s):
    """Return the visual column width of a string (CJK = 2, others = 1)."""
    w = 0
    for ch in s:
        eaw = unicodedata.east_asian_width(ch)
        w += 2 if eaw in ('W', 'F') else 1
    return w

def ljust_display(s, width):
    """Left-justify s in a field of given display width."""
    pad = width - display_width(s)
    return s + ' ' * max(pad, 0)

def is_table_row(line):
    s = line.strip()
    return s.startswith('|') and s.endswith('|') and len(s) > 1

def is_separator_row(line):
    s = line.strip()
    if not (s.startswith('|') and s.endswith('|')):
        return False
    cells = [c.strip() for c in s.strip('|').split('|')]
    return cells and all(re.match(r'^:?-+:?$', c) for c in cells if c)

def render_table(rows):
    """Render buffered markdown table rows with box-drawing characters."""
    parsed = []   # list of (cells | None for separator)
    header_end = None

    for i, row in enumerate(rows):
        if is_separator_row(row):
            if header_end is None:
                header_end = i  # first separator = end of header
            parsed.append(None)
        else:
            cells = [c.strip() for c in row.strip().strip('|').split('|')]
            parsed.append(cells)

    if not parsed:
        return

    n_cols = max((len(r) for r in parsed if r is not None), default=1)

    # Calculate column widths (display width, not byte count)
    col_widths = [1] * n_cols
    for row in parsed:
        if row is None:
            continue
        for j, cell in enumerate(row):
            if j < n_cols:
                col_widths[j] = max(col_widths[j], display_width(cell))

    def border(l, m, r):
        return C + l + m.join('─' * (w + 2) for w in col_widths) + r + N

    def make_row_str(cells, bold=False):
        parts = []
        for j in range(n_cols):
            cell = cells[j] if j < len(cells) else ''
            pad  = ' ' + ljust_display(cell, col_widths[j]) + ' '
            parts.append((W if bold else '') + pad + (N if bold else ''))
        return C + '│' + N + (C + '│' + N).join(parts) + C + '│' + N

    print(border('┌', '┬', '┐'), flush=True)

    for i, row in enumerate(parsed):
        if row is None:
            print(border('├', '┼', '┤'), flush=True)
        else:
            is_header = (header_end is not None and i < header_end)
            print(make_row_str(row, bold=is_header), flush=True)

    print(border('└', '┴', '┘'), flush=True)


table_buf = []
in_code_block = False
code_lang = ""

def flush_table():
    global table_buf
    if table_buf:
        render_table(table_buf)
        table_buf = []

for raw in stdin:
    try:
        line = raw.rstrip('\n')

        if not in_code_block and is_table_row(line):
            table_buf.append(line)
            continue

        # Non-table line: flush any buffered table first
        flush_table()

        if line.startswith('```'):
            if in_code_block:
                in_code_block = False
                code_lang = ""
                print(D + '╰' + '─' * 58 + N, flush=True)
            else:
                in_code_block = True
                code_lang = line[3:].strip()
                label = f" code {code_lang} " if code_lang else " code "
                print(D + '╭' + label + '─' * max(2, 58 - len(label)) + N, flush=True)
            continue

        if in_code_block:
            print(D + '│ ' + N + C + line + N, flush=True)
            continue

        # Headers
        if   line.startswith('#### '): line = Y  + line[5:]  + N
        elif line.startswith('### '):  line = C  + line[4:]  + N
        elif line.startswith('## '):   line = B  + line[3:]  + N
        elif line.startswith('# '):    line = W  + line[2:]  + N
        # Blockquote
        elif line.startswith('> '):    line = Y + '│' + N + ' ' + line[2:]
        # Horizontal rule
        elif re.match(r'^-{3,}$', line) or re.match(r'^={3,}$', line):
            line = B + '─' * 50 + N
        # Checkboxes
        elif line.startswith('- [x] '): line = '  ' + G + '✓' + N + ' ' + line[6:]
        elif line.startswith('- [ ] '): line = '  ○ ' + line[6:]
        # Unordered lists
        elif re.match(r'^\s*[-*] ', line):
            indent = len(line) - len(line.lstrip(' '))
            body = line.lstrip()[2:]
            line = (' ' * indent) + C + '•' + N + ' ' + body
        # Ordered lists
        elif re.match(r'^\s*\d+\. ', line):
            m = re.match(r'^(\s*)(\d+)\.\s+(.*)$', line)
            if m:
                line = f"{m.group(1)}{C}{m.group(2)}.{N} {m.group(3)}"

        # Inline: **bold**
        line = re.sub(r'\*\*([^*]+)\*\*', W + r'\1' + N, line)
        # Inline: `code`
        line = re.sub(r'`([^`]+)`', C + r'\1' + N, line)
        # Inline: [label](url)
        line = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', W + r'\1' + N + D + ' <' + r'\2' + '>' + N, line)

        print(line, flush=True)
    except Exception:
        # On render failure, print raw line — never crash
        flush_table()
        sys.stdout.write(raw)
        sys.stdout.flush()

# Flush any remaining table at EOF
flush_table()
