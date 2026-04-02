#!/usr/bin/env python3
"""harn web server — per-project localhost service for harn web UI."""

import argparse
import http.server
import json
import os
import queue
import re
import signal
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlparse
import urllib.parse

# ── Globals ────────────────────────────────────────────────────────────────────

ROOT_DIR = None
SCRIPT_DIR = None
HARN_DIR = None
CONFIG_FILE = None

active_proc = None
active_proc_lock = threading.Lock()

sse_clients = []
sse_clients_lock = threading.Lock()

server_should_stop = threading.Event()
server_instance = None

# ── SSE Broadcasting ───────────────────────────────────────────────────────────

def broadcast_sse(event_type, data):
    payload = f"event: {event_type}\ndata: {json.dumps(data)}\n\n"
    dead = []
    with sse_clients_lock:
        for q in list(sse_clients):
            try:
                q.put_nowait(payload)
            except Exception:
                dead.append(q)
        for q in dead:
            try:
                sse_clients.remove(q)
            except ValueError:
                pass

# ── State Reading ──────────────────────────────────────────────────────────────

def read_config():
    cfg = {}
    if CONFIG_FILE and os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, _, v = line.partition('=')
                    cfg[k.strip()] = v.strip().strip('"\'')
    return cfg

def read_backlog(cfg=None):
    if cfg is None:
        cfg = read_config()
    backlog_path = cfg.get('BACKLOG_FILE', os.path.join(ROOT_DIR, 'sprint-backlog.md'))
    result = {'pending': [], 'in_progress': [], 'done': [], 'path': backlog_path,
              'exists': os.path.exists(backlog_path)}
    if not result['exists']:
        return result

    content = open(backlog_path, encoding='utf-8', errors='replace').read()
    current_section = None
    current_item = None

    for line in content.split('\n'):
        if re.match(r'^## Pending', line):
            current_section = 'pending'
            current_item = None
        elif re.match(r'^## In Progress', line):
            current_section = 'in_progress'
            current_item = None
        elif re.match(r'^## Done', line):
            current_section = 'done'
            current_item = None
        elif current_section:
            m = re.match(r'^- \[[ x]\] \*\*(.+?)\*\*(.*)$', line)
            if m:
                slug = m.group(1)
                rest = m.group(2).strip()
                current_item = {'slug': slug, 'description': rest, 'plan': None}
                result[current_section].append(current_item)
            elif current_item and re.match(r'^\s+plan:\s*', line):
                mp = re.match(r'^\s+plan:\s*(.*)', line)
                current_item['plan'] = mp.group(1).strip()
            elif current_item and re.match(r'^\s+\S', line):
                # Indented description line (not plan)
                stripped = line.strip()
                if current_item['description']:
                    current_item['description'] += '\n' + stripped
                else:
                    current_item['description'] = stripped
            elif line and not line.startswith(' ') and not line.startswith('\t'):
                current_item = None  # End of item block

    return result

def list_runs():
    runs_dir = os.path.join(HARN_DIR, 'runs')
    if not os.path.exists(runs_dir):
        return []
    runs = []
    for d in sorted(os.listdir(runs_dir), reverse=True):
        if os.path.isdir(os.path.join(runs_dir, d)):
            runs.append(d)
    return runs

def get_run_detail(run_id):
    # Validate run_id to prevent path traversal
    if not re.match(r'^[\w\-]+$', run_id):
        return None
    run_path = os.path.join(HARN_DIR, 'runs', run_id)
    if not os.path.exists(run_path):
        return None

    detail = {'id': run_id, 'sprints': [], 'completed': False}

    for fname in ['prompt.txt', 'plan.txt']:
        fpath = os.path.join(run_path, fname)
        if os.path.exists(fpath):
            detail[fname.replace('.', '_')] = open(fpath, encoding='utf-8', errors='replace').read().strip()

    detail['completed'] = os.path.exists(os.path.join(run_path, 'completed'))

    sprints_dir = os.path.join(run_path, 'sprints')
    if os.path.exists(sprints_dir):
        for sprint_num in sorted(os.listdir(sprints_dir)):
            sprint_path = os.path.join(sprints_dir, sprint_num)
            if not os.path.isdir(sprint_path):
                continue
            sprint = {'num': sprint_num, 'status': 'pending', 'iteration': '1',
                      'files': []}
            for key in ('status', 'iteration'):
                fp = os.path.join(sprint_path, key)
                if os.path.exists(fp):
                    sprint[key] = open(fp).read().strip()
            sprint['files'] = [
                f for f in ('contract.md', 'implementation.md', 'qa-report.md')
                if os.path.exists(os.path.join(sprint_path, f))
            ]
            detail['sprints'].append(sprint)

    return detail

def current_run_id():
    current_link = os.path.join(HARN_DIR, 'current')
    if os.path.islink(current_link):
        return os.path.basename(os.readlink(current_link))
    return None

def read_harn_version():
    harn_sh = os.path.join(SCRIPT_DIR, 'harn.sh')
    if os.path.exists(harn_sh):
        for line in open(harn_sh):
            m = re.match(r'HARN_VERSION="(.+)"', line)
            if m:
                return m.group(1)
    return 'unknown'

def get_status():
    cfg = read_config()
    runs = list_runs()
    curr = current_run_id()

    harn_running = False
    harn_pid_file = os.path.join(HARN_DIR, 'harn.pid')
    if os.path.exists(harn_pid_file):
        try:
            pid = int(open(harn_pid_file).read().strip())
            os.kill(pid, 0)
            harn_running = True
        except Exception:
            pass

    web_running = False
    with active_proc_lock:
        web_running = (active_proc is not None and active_proc.poll() is None)

    return {
        'project': ROOT_DIR,
        'version': read_harn_version(),
        'config': cfg,
        'current_run': curr,
        'run_count': len(runs),
        'harn_running': harn_running,
        'command_running': web_running,
        'server_running': True,
    }

FALLBACK_MODELS = {
    'copilot': [
        'claude-haiku-4.5', 'claude-sonnet-4.5', 'claude-sonnet-4.6',
        'claude-opus-4.5', 'claude-opus-4.6',
        'gpt-4.1', 'gpt-4o', 'gpt-4o-mini', 'o1', 'o3-mini',
    ],
    'claude': [
        'claude-haiku-4.5', 'claude-sonnet-4.5', 'claude-sonnet-4.6',
        'claude-opus-4.5', 'claude-opus-4.6',
    ],
    'codex': [
        'gpt-5.4', 'gpt-5.4-mini', 'gpt-5.3-codex', 'gpt-5.2-codex',
        'gpt-5.2', 'gpt-5.1-codex-max', 'gpt-5.1-codex-mini',
    ],
    'gemini': [
        'gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.0-flash',
        'gemini-1.5-pro', 'gemini-1.5-flash',
    ],
}

def read_model_cache():
    """Read model cache from .harn/model-cache/ directory.
    Falls back to hardcoded model list if cache file is empty or missing."""
    model_cache_dir = os.path.join(HARN_DIR, 'model-cache')
    result = {'backends': [], 'models': {}}

    backends_file = os.path.join(model_cache_dir, 'backends.txt')
    if os.path.exists(backends_file):
        with open(backends_file, encoding='utf-8') as f:
            result['backends'] = [l.strip() for l in f if l.strip()]

    for backend in ['copilot', 'claude', 'codex', 'gemini']:
        cache_file = os.path.join(model_cache_dir, f'{backend}.txt')
        models = []
        if os.path.exists(cache_file):
            with open(cache_file, encoding='utf-8') as f:
                models = [l.strip() for l in f if l.strip()]
        # If cache is empty or missing, use fallback list
        if not models:
            models = FALLBACK_MODELS.get(backend, [])
        if models and backend in result['backends']:
            result['models'][backend] = models
        elif models and os.path.exists(cache_file):
            # File exists (even if empty) → backend is installed
            result['models'][backend] = models
            if backend not in result['backends']:
                result['backends'].append(backend)

    return result

def read_artifact(run_id, filename):
    if not re.match(r'^[\w\-]+$', run_id):
        return None
    allowed = {'plan.txt', 'spec.md', 'sprint-backlog.md', 'handoff.md'}
    if filename not in allowed:
        return None
    fpath = os.path.join(HARN_DIR, 'runs', run_id, filename)
    if os.path.exists(fpath):
        return open(fpath, encoding='utf-8', errors='replace').read()
    return None

def backlog_add_item(slug, description):
    """Add a new pending item to the backlog markdown file."""
    if not re.match(r'^[\w\-]+$', slug) or len(slug) > 80:
        return False, 'Invalid slug (use letters, numbers, hyphens only)'
    cfg = read_config()
    backlog_path = cfg.get('BACKLOG_FILE', os.path.join(ROOT_DIR, 'sprint-backlog.md'))
    if not os.path.exists(backlog_path):
        with open(backlog_path, 'w', encoding='utf-8') as f:
            f.write('## Pending\n\n## In Progress\n\n## Done\n')
    content = open(backlog_path, encoding='utf-8').read()
    new_item = f'- [ ] **{slug}**\n  {description}\n'
    if '## Pending\n' in content:
        idx = content.index('## Pending\n') + len('## Pending\n')
        # Skip blank lines immediately after heading
        while idx < len(content) and content[idx] == '\n':
            idx += 1
        content = content[:idx] + new_item + '\n' + content[idx:]
    else:
        content = f'## Pending\n\n{new_item}\n' + content
    with open(backlog_path, 'w', encoding='utf-8') as f:
        f.write(content)
    return True, 'ok'

def backlog_update_item(slug, new_slug=None, new_description=None, new_plan=None):
    """Update a backlog item's slug, description, and/or plan."""
    if not re.match(r'^[\w\-]+$', slug):
        return False, 'Invalid slug'
    if new_slug and not re.match(r'^[\w\-]+$', new_slug):
        return False, 'Invalid new slug (use letters, numbers, hyphens only)'
    cfg = read_config()
    backlog_path = cfg.get('BACKLOG_FILE', os.path.join(ROOT_DIR, 'sprint-backlog.md'))
    if not os.path.exists(backlog_path):
        return False, 'Backlog file not found'
    lines = open(backlog_path, encoding='utf-8').read().split('\n')
    result = []
    i = 0
    found = False
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^(- \[[ x]\] )\*\*(.+?)\*\*(.*)$', line)
        if m and m.group(2) == slug:
            found = True
            effective_slug = new_slug if new_slug else slug
            result.append(f'{m.group(1)}**{effective_slug}**')
            i += 1
            # Skip all old indented lines (description + plan)
            while i < len(lines) and re.match(r'^\s+', lines[i]):
                i += 1
            # Write new description
            if new_description:
                result.append(f'  {new_description}')
            elif new_description is None:
                # Preserve old inline description if any
                old_inline = m.group(3).strip()
                if old_inline:
                    result.append(f'  {old_inline}')
            # Write new plan
            if new_plan:
                result.append(f'  plan: {new_plan}')
        else:
            result.append(line)
            i += 1
    if not found:
        return False, 'Item not found'
    with open(backlog_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(result))
    return True, 'ok'


def ai_enhance_backlog_item(slug, description, plan, instruction):
    """Call an available AI CLI to improve a backlog item based on user instruction."""
    prompt = (
        'You are helping improve a software sprint backlog item.\n\n'
        f'Current item:\n'
        f'- Slug (kebab-case identifier, no spaces): {slug}\n'
        f'- Description: {description or "(empty)"}\n'
        f'- Plan: {plan or "(empty)"}\n\n'
        f'User instruction: {instruction}\n\n'
        'Return ONLY a valid JSON object with exactly these three fields:\n'
        '{"slug": "new-slug", "description": "improved description", "plan": "improved plan or empty string"}\n\n'
        'Rules: slug must be kebab-case (letters, numbers, hyphens only, no spaces). '
        'Keep description concise. Keep plan concise (1 sentence or empty string).'
    )
    cache_dir = os.path.join(HARN_DIR, 'model-cache')
    backends_file = os.path.join(cache_dir, 'backends.txt')
    backends = []
    if os.path.exists(backends_file):
        with open(backends_file, encoding='utf-8') as f:
            backends = [l.strip() for l in f if l.strip()]
    env = {**os.environ, 'NO_COLOR': '1', 'TERM': 'dumb'}
    for backend in ['copilot', 'claude', 'codex', 'gemini']:
        if backend not in backends:
            continue
        try:
            if backend == 'codex':
                proc = subprocess.run(
                    ['codex', 'exec', '-'], input=prompt,
                    capture_output=True, text=True, timeout=60, cwd=ROOT_DIR, env=env
                )
            elif backend == 'copilot':
                proc = subprocess.run(
                    ['copilot', '--yolo', '-p', prompt],
                    capture_output=True, text=True, timeout=60, cwd=ROOT_DIR, env=env
                )
            else:
                proc = subprocess.run(
                    [backend, '-p', prompt],
                    capture_output=True, text=True, timeout=60, cwd=ROOT_DIR, env=env
                )
            output = proc.stdout.strip()
            if not output:
                continue
            json_match = re.search(r'\{[^{}]+\}', output, re.DOTALL)
            if json_match:
                data = json.loads(json_match.group())
                new_slug = data.get('slug', '').strip()
                if new_slug and re.match(r'^[\w\-]+$', new_slug):
                    return {
                        'ok': True,
                        'slug': new_slug,
                        'description': data.get('description', ''),
                        'plan': data.get('plan', ''),
                    }
        except Exception:
            continue
    return {'ok': False, 'error': 'AI 백엔드를 사용할 수 없거나 생성에 실패했습니다'}

def read_sprint_artifact(run_id, sprint_num, filename):
    if not re.match(r'^[\w\-]+$', run_id):
        return None
    if not re.match(r'^\d+$', sprint_num):
        return None
    allowed = {'contract.md', 'implementation.md', 'qa-report.md'}
    if filename not in allowed:
        return None
    fpath = os.path.join(HARN_DIR, 'runs', run_id, 'sprints', sprint_num, filename)
    if os.path.exists(fpath):
        return open(fpath, encoding='utf-8', errors='replace').read()
    return None

# ── Command Execution ──────────────────────────────────────────────────────────

ALLOWED_COMMANDS = {
    'start', 'auto', 'all', 'discover', 'add', 'stop', 'clear',
    'resume', 'doctor', 'status', 'backlog', 'runs', 'do',
    'config', 'model', 'inbox', 'team', 'init',
}

ANSI_ESCAPE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

def strip_ansi(text):
    return ANSI_ESCAPE.sub('', text)

def run_harn_command(cmd_args):
    global active_proc

    with active_proc_lock:
        if active_proc is not None and active_proc.poll() is None:
            broadcast_sse('error', {'message': 'Another command is already running. Stop it first.'})
            return

    harn_script = os.path.join(SCRIPT_DIR, 'harn.sh')
    env = os.environ.copy()
    env['HARN_WEB_MODE'] = '1'
    env['TERM'] = 'dumb'
    env['NO_COLOR'] = '1'
    env.pop('COLORTERM', None)

    full_cmd = ['bash', harn_script] + cmd_args

    broadcast_sse('command_start', {'cmd': ' '.join(cmd_args)})

    try:
        proc = subprocess.Popen(
            full_cmd,
            cwd=ROOT_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=env,
        )

        with active_proc_lock:
            active_proc = proc

        for line in iter(proc.stdout.readline, ''):
            broadcast_sse('log', {'line': strip_ansi(line.rstrip('\n'))})

        proc.stdout.close()
        proc.wait()
        exit_code = proc.returncode

        broadcast_sse('command_done', {
            'cmd': ' '.join(cmd_args),
            'exit_code': exit_code,
            'success': exit_code == 0,
        })

        # Push updated state after command completes
        try:
            broadcast_sse('state_update', get_status())
        except Exception:
            pass

    except Exception as e:
        broadcast_sse('error', {'message': str(e)})
    finally:
        with active_proc_lock:
            active_proc = None

# ── HTTP Handler ───────────────────────────────────────────────────────────────

class HarnHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # suppress request logging to keep harn output clean

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, text, status=200):
        body = text.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # Serve UI
        if path in ('/', '/index.html'):
            html_file = os.path.join(SCRIPT_DIR, 'web', 'index.html')
            if os.path.exists(html_file):
                self.send_html(open(html_file, encoding='utf-8').read())
            else:
                self.send_html('<h1>harn web UI not found</h1>', 404)
            return

        if path in ('/favicon.ico', '/robots.txt'):
            self.send_response(204)
            self.end_headers()
            return

        # API routes
        if path == '/api/health':
            self.send_json({'ok': True})

        elif path == '/api/status':
            self.send_json(get_status())

        elif path == '/api/backlog':
            self.send_json(read_backlog())

        elif path == '/api/runs':
            runs = list_runs()
            curr = current_run_id()
            details = []
            for r in runs:
                d = get_run_detail(r)
                if d:
                    details.append({
                        'id': r,
                        'current': r == curr,
                        'completed': d.get('completed', False),
                        'prompt_txt': d.get('prompt_txt', ''),
                        'sprint_count': len(d.get('sprints', [])),
                    })
            self.send_json({'runs': details, 'current': curr})

        elif re.match(r'^/api/runs/([^/]+)$', path):
            m = re.match(r'^/api/runs/([^/]+)$', path)
            detail = get_run_detail(m.group(1))
            self.send_json(detail) if detail else self.send_json({'error': 'not found'}, 404)

        elif re.match(r'^/api/runs/([^/]+)/file/(.+)$', path):
            m = re.match(r'^/api/runs/([^/]+)/file/(.+)$', path)
            content = read_artifact(m.group(1), m.group(2))
            if content is not None:
                self.send_json({'content': content, 'filename': m.group(2)})
            else:
                self.send_json({'error': 'not found'}, 404)

        elif re.match(r'^/api/runs/([^/]+)/sprints/([^/]+)/file/(.+)$', path):
            m = re.match(r'^/api/runs/([^/]+)/sprints/([^/]+)/file/(.+)$', path)
            content = read_sprint_artifact(m.group(1), m.group(2), m.group(3))
            if content is not None:
                self.send_json({'content': content, 'filename': m.group(3)})
            else:
                self.send_json({'error': 'not found'}, 404)

        elif path == '/api/config':
            raw = ''
            if CONFIG_FILE and os.path.exists(CONFIG_FILE):
                raw = open(CONFIG_FILE, encoding='utf-8').read()
            self.send_json({'config': read_config(), 'raw': raw})

        elif path == '/api/models':
            self.send_json(read_model_cache())

        elif path == '/api/models/refresh':
            # Re-run refresh_model_cache via harn.sh and return updated cache
            harn_script = os.path.join(SCRIPT_DIR, 'harn.sh')
            try:
                subprocess.run(
                    ['bash', '-c', f'source "{harn_script}" --source-only 2>/dev/null || true; '
                     f'HARN_DIR="{HARN_DIR}" bash -c \'source "{os.path.join(SCRIPT_DIR, "lib", "ai.sh")}" 2>/dev/null; refresh_model_cache\''],
                    cwd=ROOT_DIR, capture_output=True, text=True, timeout=30,
                    env={**os.environ, 'HARN_DIR': HARN_DIR, 'SCRIPT_DIR': SCRIPT_DIR,
                         'ROOT_DIR': ROOT_DIR, 'LOG_FILE': '/dev/null'}
                )
            except Exception:
                pass
            self.send_json(read_model_cache())

        elif path == '/api/memory':
            memory_file = os.path.join(HARN_DIR, 'memory.md')
            content = open(memory_file, encoding='utf-8').read() if os.path.exists(memory_file) else ''
            self.send_json({'content': content})

        elif path == '/api/backlog/raw':
            cfg = read_config()
            backlog_path = cfg.get('BACKLOG_FILE', os.path.join(ROOT_DIR, 'sprint-backlog.md'))
            raw = open(backlog_path, encoding='utf-8').read() if os.path.exists(backlog_path) else ''
            self.send_json({'raw': raw, 'path': backlog_path})

        elif path == '/api/logs/stream':
            self._handle_sse()

        else:
            self.send_json({'error': 'not found'}, 404)

    def do_PATCH(self):
        self.do_POST()

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else b'{}'

        try:
            data = json.loads(body) if body.strip() else {}
        except json.JSONDecodeError:
            self.send_json({'error': 'invalid json'}, 400)
            return

        if path == '/api/command':
            cmd_args = data.get('args', [])
            if not cmd_args or not isinstance(cmd_args, list):
                self.send_json({'error': 'args (list) required'}, 400)
                return
            if cmd_args[0] not in ALLOWED_COMMANDS:
                self.send_json({'error': f'command not allowed: {cmd_args[0]}'}, 400)
                return
            t = threading.Thread(target=run_harn_command, args=(cmd_args,), daemon=True)
            t.start()
            self.send_json({'ok': True, 'cmd': cmd_args})

        elif path == '/api/command/stop':
            with active_proc_lock:
                if active_proc and active_proc.poll() is None:
                    active_proc.terminate()
                    broadcast_sse('command_done', {'cmd': 'stop', 'exit_code': -1, 'success': False,
                                                   'message': 'Stopped by user'})
                    self.send_json({'ok': True})
                else:
                    self.send_json({'ok': False, 'message': 'No active command'})

        elif path == '/api/backlog/add':
            slug = data.get('slug', '').strip()
            description = data.get('description', '').strip()
            if not slug:
                self.send_json({'error': 'slug required'}, 400)
                return
            ok, msg = backlog_add_item(slug, description)
            if ok:
                self.send_json({'ok': True})
            else:
                self.send_json({'error': msg}, 400)

        elif re.match(r'^/api/backlog/([^/]+)$', path) and self.command == 'PATCH':
            m = re.match(r'^/api/backlog/([^/]+)$', path)
            slug = urllib.parse.unquote(m.group(1))
            new_slug = data.get('new_slug', '').strip() or None
            description = data.get('description', None)
            if description is not None:
                description = description.strip()
            plan = data.get('plan', None)
            if plan is not None:
                plan = plan.strip()
            ok, msg = backlog_update_item(slug, new_slug=new_slug, new_description=description, new_plan=plan)
            if ok:
                self.send_json({'ok': True})
            else:
                self.send_json({'error': msg}, 400)

        elif path == '/api/backlog/enhance':
            slug = data.get('slug', '').strip()
            description = data.get('description', '').strip()
            plan = data.get('plan', '').strip()
            instruction = data.get('instruction', '').strip()
            if not slug or not instruction:
                self.send_json({'error': 'slug and instruction required'}, 400)
                return
            result = ai_enhance_backlog_item(slug, description, plan, instruction)
            self.send_json(result)

        elif path == '/api/config':
            raw = data.get('raw', '')
            if CONFIG_FILE:
                with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
                    f.write(raw)
                self.send_json({'ok': True})
            else:
                self.send_json({'error': 'config path not set'}, 500)

        elif path == '/api/memory':
            content = data.get('content', '')
            memory_file = os.path.join(HARN_DIR, 'memory.md')
            os.makedirs(HARN_DIR, exist_ok=True)
            with open(memory_file, 'w', encoding='utf-8') as f:
                f.write(content)
            self.send_json({'ok': True})

        elif path == '/api/shutdown':
            broadcast_sse('shutdown', {'message': 'Server shutting down'})
            self.send_json({'ok': True})
            threading.Thread(target=_do_shutdown, daemon=True).start()

        else:
            self.send_json({'error': 'not found'}, 404)

    def _handle_sse(self):
        q = queue.Queue()
        with sse_clients_lock:
            sse_clients.append(q)

        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.end_headers()

        try:
            self.wfile.write(b': connected\n\n')
            self.wfile.flush()
        except Exception:
            with sse_clients_lock:
                try:
                    sse_clients.remove(q)
                except ValueError:
                    pass
            return

        try:
            while not server_should_stop.is_set():
                try:
                    payload = q.get(timeout=15)
                    self.wfile.write(payload.encode('utf-8'))
                    self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b': ping\n\n')
                    self.wfile.flush()
        except Exception:
            pass
        finally:
            with sse_clients_lock:
                try:
                    sse_clients.remove(q)
                except ValueError:
                    pass

# ── Shutdown ───────────────────────────────────────────────────────────────────

def _do_shutdown():
    global server_instance
    time.sleep(0.3)

    # Stop active harn background process
    harn_pid_file = os.path.join(HARN_DIR, 'harn.pid')
    if os.path.exists(harn_pid_file):
        try:
            pid = int(open(harn_pid_file).read().strip())
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass

    # Stop active web-invoked command
    with active_proc_lock:
        if active_proc and active_proc.poll() is None:
            try:
                active_proc.terminate()
            except Exception:
                pass

    server_should_stop.set()
    if server_instance:
        threading.Thread(target=server_instance.shutdown, daemon=True).start()

# ── Server ─────────────────────────────────────────────────────────────────────

class HarnServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

def main():
    global ROOT_DIR, SCRIPT_DIR, HARN_DIR, CONFIG_FILE, server_instance

    parser = argparse.ArgumentParser(description='harn web server')
    parser.add_argument('--root', required=True, help='Target project root directory')
    parser.add_argument('--script-dir', required=True, help='harn install directory')
    parser.add_argument('--port', type=int, default=4747, help='Port to listen on')
    args = parser.parse_args()

    ROOT_DIR = os.path.abspath(args.root)
    SCRIPT_DIR = os.path.abspath(args.script_dir)
    HARN_DIR = os.path.join(ROOT_DIR, '.harn')
    CONFIG_FILE = os.path.join(ROOT_DIR, '.harn_config')

    os.makedirs(HARN_DIR, exist_ok=True)

    server_instance = HarnServer(('127.0.0.1', args.port), HarnHandler)

    def handle_signal(sig, frame):
        _do_shutdown()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    server_instance.serve_forever()

if __name__ == '__main__':
    main()
