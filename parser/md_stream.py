#!/usr/bin/env python3
"""Real-time markdown color renderer — harn pipeline only"""
import sys, re, io

W='\033[1;37m'; B='\033[0;34m'; C='\033[0;36m'
Y='\033[1;33m'; G='\033[0;32m'; N='\033[0m'

# Handle non-UTF-8 bytes gracefully (e.g. claude --verbose JSON output)
stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace')

for raw in stdin:
    try:
        line = raw.rstrip('\n')
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
        # Code block fence
        elif line.startswith('```'):   line = C + line + N
        # Checkboxes
        elif line.startswith('- [x] '): line = '  ' + G + '✓' + N + ' ' + line[6:]
        elif line.startswith('- [ ] '): line = '  ○ ' + line[6:]

        # Inline: **bold**
        line = re.sub(r'\*\*([^*]+)\*\*', W + r'\1' + N, line)
        # Inline: `code`
        line = re.sub(r'`([^`]+)`', C + r'\1' + N, line)

        print(line, flush=True)
    except Exception:
        # On render failure, print raw line — never crash
        sys.stdout.write(raw)
        sys.stdout.flush()
