#!/usr/bin/env python3
"""claude --output-format stream-json 실시간 파서
JSON 이벤트 스트림에서 텍스트 토큰을 추출해 실시간으로 출력한다.
tool_use / tool_result 진행 상황도 간단히 표시한다.
"""
import sys, json, io

C = '\033[0;36m'   # cyan (tool 표시용)
Y = '\033[1;33m'   # yellow
N = '\033[0m'

stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace')

# 파일 끝에 개행이 붙었는지 추적 (마지막에 보장)
last_char_was_newline = True

for raw in stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        # JSON 아닌 줄 (에러 메시지 등) 그대로 출력
        sys.stdout.write(raw + '\n')
        sys.stdout.flush()
        last_char_was_newline = True
        continue

    t = obj.get('type', '')

    # ── 텍스트 토큰 (실시간 스트리밍) ────────────────────────────────────────
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
            # 도구 결과 간략 표시
            content = event.get('content', '')
            preview = str(content)[:80].replace('\n', ' ')
            sys.stdout.write(f'{Y}  → {preview}{N}\n')
            sys.stdout.flush()
            last_char_was_newline = True

    # ── 최종 결과 ─────────────────────────────────────────────────────────────
    elif t == 'result':
        if not last_char_was_newline:
            sys.stdout.write('\n')
            sys.stdout.flush()
        # result 자체는 이미 위에서 텍스트 토큰으로 출력됨 — 중복 출력 안 함

    # ── 에러 ──────────────────────────────────────────────────────────────────
    elif t == 'error':
        msg = obj.get('error', {}).get('message', str(obj))
        sys.stdout.write(f'\n[ERROR] {msg}\n')
        sys.stdout.flush()
        last_char_was_newline = True
