#!/usr/bin/env python3
"""Real-time parser for claude --output-format stream-json
Extracts text tokens from the JSON event stream and prints them in real time.
Also briefly shows tool_use / tool_result progress.
"""
import sys, json, io

C = '\033[0;36m'   # cyan (tool indicator)
Y = '\033[1;33m'   # yellow
N = '\033[0m'

stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace')

# Track whether the last character written was a newline (to ensure final newline)
last_char_was_newline = True

for raw in stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        # Non-JSON line (error messages etc.) — print as-is
        sys.stdout.write(raw + '\n')
        sys.stdout.flush()
        last_char_was_newline = True
        continue

    t = obj.get('type', '')

    # ── Text tokens (real-time streaming) ────────────────────────────────────
    if t == 'stream_event':
        event = obj.get('event', {})
        et = event.get('type', '')

        if et == 'content_block_delta':
            delta = event.get('delta', {})
            if delta.get('type') == 'text_delta':
                text = delta.get('text', '')
                if text:
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    last_char_was_newline = text.endswith('\n')

        elif et == 'content_block_start':
            block = event.get('content_block', {})
            if block.get('type') == 'tool_use':
                name = block.get('name', '?')
                if not last_char_was_newline:
                    sys.stdout.write('\n')
                sys.stdout.write(f'{C}[🔧 {name}]{N}\n')
                sys.stdout.flush()
                last_char_was_newline = True

        elif et == 'tool_result':
            # Brief tool result preview
            content = event.get('content', '')
            preview = str(content)[:80].replace('\n', ' ')
            sys.stdout.write(f'{Y}  → {preview}{N}\n')
            sys.stdout.flush()
            last_char_was_newline = True

    # ── Final result ──────────────────────────────────────────────────────────
    elif t == 'result':
        if not last_char_was_newline:
            sys.stdout.write('\n')
            sys.stdout.flush()
        # result body is already printed via text tokens above — skip to avoid duplication

    # ── Error ─────────────────────────────────────────────────────────────────
    elif t == 'error':
        msg = obj.get('error', {}).get('message', str(obj))
        sys.stdout.write(f'\n[ERROR] {msg}\n')
        sys.stdout.flush()
        last_char_was_newline = True
