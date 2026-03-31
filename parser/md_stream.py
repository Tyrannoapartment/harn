#!/usr/bin/env python3
"""실시간 마크다운 컬러 렌더러 — harness 파이프라인 전용"""
import sys, re, io

W='\033[1;37m'; B='\033[0;34m'; C='\033[0;36m'
Y='\033[1;33m'; G='\033[0;32m'; N='\033[0m'

# 비 UTF-8 바이트를 대체 문자로 처리 (claude --verbose JSON 등)
stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace')

for raw in stdin:
    try:
        line = raw.rstrip('\n')
        # 헤더
        if   line.startswith('#### '): line = Y  + line[5:]  + N
        elif line.startswith('### '):  line = C  + line[4:]  + N
        elif line.startswith('## '):   line = B  + line[3:]  + N
        elif line.startswith('# '):    line = W  + line[2:]  + N
        # 인용
        elif line.startswith('> '):    line = Y + '│' + N + ' ' + line[2:]
        # 구분선
        elif re.match(r'^-{3,}$', line) or re.match(r'^={3,}$', line):
            line = B + '─' * 50 + N
        # 코드 블록 경계
        elif line.startswith('```'):   line = C + line + N
        # 체크박스
        elif line.startswith('- [x] '): line = '  ' + G + '✓' + N + ' ' + line[6:]
        elif line.startswith('- [ ] '): line = '  ○ ' + line[6:]

        # 인라인: **굵게**
        line = re.sub(r'\*\*([^*]+)\*\*', W + r'\1' + N, line)
        # 인라인: `코드`
        line = re.sub(r'`([^`]+)`', C + r'\1' + N, line)

        print(line, flush=True)
    except Exception:
        # 렌더링 실패 시 원본 출력 (절대 크래시 안 함)
        sys.stdout.write(raw)
        sys.stdout.flush()
