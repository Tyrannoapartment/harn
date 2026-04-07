# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**harn** is a multi-agent sprint development loop orchestrator written in Bash. It automates a **Planner → Designer → Generator → Evaluator** loop that takes a backlog item and drives it to completion through AI agents (GitHub Copilot CLI or Claude CLI).

Dependencies: `python3`, and either `copilot` (GitHub Copilot CLI) or `claude` CLI.

Published as npm package `@tyrannoapartment/harn`.

## Development Commands

```bash
# Install locally (creates a symlink, so edits are live immediately)
bash install.sh

# Syntax check all files
bash -n harn.sh && for f in lib/*.sh; do bash -n "$f"; done

# Run a command directly without installing
bash harn.sh help
bash harn.sh backlog
```

There is no test suite for harn itself — test manually in a real project after changes.

## Architecture

### Core files

- **`harn.sh`** — Thin entry point (~200 lines). Bootstrap variables, source `lib/` modules, parse CLI flags, route to commands.
- **`lib/`** — Modular bash library (23 files, ~5,000 lines total). Each file owns a single concern:
  - `core.sh` — Colors, logging, banner
  - `error.sh` — Error handling, exit traps
  - `guidance.sh` — Mid-run guidance listener, inbox
  - `input.sh` — User input helpers (Python readline), sprint progress
  - `config.sh` — Language detection, i18n, config loading
  - `ai.sh` — AI CLI detection, backend selection, generation
  - `init.sh` — Initialization wizard
  - `backlog.sh` — Backlog file operations
  - `run.sh` — Run directory and sprint state
  - `invoke.sh` — Agent invocation, context injection, output rendering
  - `commands.sh` — Sprint commands (plan, contract, implement, evaluate, next)
  - `git.sh` — Git commit helpers with structured commit protocol
  - `retro.sh` — Retrospective analysis
  - `sprint.sh` — Sprint loop orchestration
  - `discover.sh` — Task discovery and backlog item creation
  - `auto.sh` — Auto/all modes, status, config, runs
  - `doctor.sh` — Diagnostics and auth
  - `memory.sh` — Project memory (cross-session learnings in `.harn/memory.md`)
  - `routing.sh` — Intelligent model routing (keyword-based upgrade/downgrade)
  - `progress.sh` — Enhanced progress display (visual bar, time, sprint stats)
  - `update.sh` — Auto-update check (npm version compare, 24h cache)
  - `team.sh` — Team mode (tmux-based parallel agent execution)
  - `nlp.sh` — Natural language command router (`harn do "..."`)
- **`parser/md_stream.py`** — Real-time markdown colorizer piped from agent stdout.
- **`parser/stream_parser.py`** — Real-time JSON stream parser for `claude --output-format stream-json`.
- **`prompts/`** — System prompts for each agent role: `planner.md`, `generator.md`, `evaluator.md`, `retrospective.md`. Language variants (en/ko) in subdirectories.

### Runtime state

All state for a run lives under `.harn/` in the **target project directory** (not this repo):

```
.harn/
  harn.log               # global log
  harn.pid               # PID while _run_sprint_loop is active
  current -> runs/<id>   # symlink to active run
  current.log            # symlink to active run log
  prompts/               # custom prompts (override built-in prompts/)
  runs/<YYYYMMDD-HHMMSS>/
    prompt.txt           # selected backlog slug
    plan.txt             # one-line plan text
    spec.md              # product spec from planner
    sprint-plan.md    # sprint definitions
    current_sprint       # current sprint number
    sprints/
      001/
        contract.md       # agreed sprint scope
        implementation.md # generator output
        qa-report.md      # evaluator verdict
        status            # pending|in-progress|pass|fail|cancelled
        iteration         # retry count
    handoff.md           # completion summary (written by evaluator on final PASS)
    run.log              # execution log for this run
```

### Sprint loop flow

```
cmd_start
  └─ cmd_plan (Planner: backlog item → spec.md + scope plans with needs_design flag)
      └─ _run_sprint_loop
          ├─ cmd_design (Designer creates design spec via Figma MCP — only if needs_design: true)
          ├─ cmd_contract (Generator proposes scope → Evaluator approves/revises)
          ├─ cmd_implement (Generator implements; retries up to MAX_ITERATIONS on FAIL)
          ├─ cmd_evaluate (Evaluator QA; runs build/test/lint/E2E)
          └─ cmd_next (Evaluator writes handoff; backlog item → Done)
              └─ cmd_retrospective (optional: analyze run, suggest prompt improvements)
```

### Agent invocation

Two distinct paths:
- **Sprint agents** (`invoke_role` → `invoke_copilot`): always use the detected AI CLI with `--add-dir`; Generator always gets `--effort high`.
- **Lightweight generation** (`_ai_generate`): used by `cmd_add`, `cmd_discover`, `harn init`; auto-detects copilot first, falls back to claude.

## Key Conventions

### Agent output section markers

Agents output **exact section markers** parsed by `awk`. Do not change these strings:

- Planner: `=== plan.text ===`, `=== spec.md ===`, `=== sprint-plan.md ===`
- Designer: `=== design.md ===` (design specification for UI/UX scopes)
- Evaluator verdict: must end with exactly `VERDICT: PASS` or `VERDICT: FAIL` on its own line
- Contract review: must contain `APPROVED` or `NEEDS_REVISION` on its own line
- Retrospective: `=== retro-summary ===`, `=== prompt-suggestion:planner ===`, `=== prompt-suggestion:generator ===`, `=== prompt-suggestion:evaluator ===`

### Language

UI output language is auto-detected via `_detect_lang()` (Korean/English). All agent prompt files must be authored in **English**. Code identifiers, file paths, and package names stay in English.

### Backlog format

Each backlog item is a standalone markdown file stored in `.harn/sprint/<status>/<slug>.md`:

```
.harn/sprint/pending/feature-auth.md
.harn/sprint/in-progress/api-refactor.md
.harn/sprint/done/fix-login-bug.md
```

File format (Jira-style ticket):

```markdown
# slug-name

## Summary
One-line summary of this ticket.

## Description
Detailed description of the backlog item.
Can be multi-line with full markdown.

## Affected Files
- src/path/to/file.ts
- web/src/components/Component.tsx

## Implementation Guide
Step-by-step implementation approach.

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Plan
Planner-written plan (appended by the planner agent after planning).
```

Slugs must have no spaces — they're used as file names and programmatic identifiers. Moving items between states is done by moving the file between directories.

### Model configuration priority

CLI flag > `HARN_MODEL_<ROLE>` env var > `.harn_config` `MODEL_<ROLE>` > hardcoded defaults

Default models: Planner=`claude-haiku-4.5`, Designer=`claude-sonnet-4.6`, Generator(contract)=`claude-sonnet-4.6`, Generator(impl)=`claude-opus-4.6`, Evaluator(contract)=`claude-haiku-4.5`, Evaluator(QA)=`claude-sonnet-4.5`

Per-invocation override:
```bash
harn --generator-impl-model claude-sonnet-4.6 start
```

### Intelligent model routing

When `MODEL_ROUTING=true` (default), harn auto-detects keywords in prompts and adjusts the model tier:
- **Escalation** (critical, security, architecture, etc.) → haiku→sonnet→opus
- **Simplification** (find, list, search, docs, etc.) → opus→sonnet→haiku

Disable with `MODEL_ROUTING=false` in `.harn_config` or env.

### Project memory

Cross-session learnings are saved to `.harn/memory.md`. Sources:
- Retrospective summaries (auto-saved after each retro)
- Sprint failure patterns (saved when iteration > 1)

Memory is automatically injected into every agent prompt via context injection in `invoke_role()`.

### Natural language commands

`harn do "<request>"` uses AI to parse natural language into the appropriate harn command:
```bash
harn do "백로그에서 우선순위 높은것 진행해줘"  # → harn auto
harn do "코드 분석해서 할일 찾아"              # → harn discover
harn do "3명이서 로그인 기능 만들어"           # → harn team 3 implement login
```

### Team mode (tmux)

`harn team [N] <task>` launches N parallel AI agents in tmux panes:
```bash
harn team 3 "implement user authentication"
```
Requires `tmux` to be installed. Max 8 agents.

### Auto-update check

On startup, harn checks npm for newer versions (cached 24h, non-blocking). Disable with `HARN_NO_UPDATE_CHECK=true`.

### Continuation enforcement

When the evaluator returns `VERDICT: PASS`, harn verifies actual file changes via `git diff`. If no changes are detected, the verdict is overridden to FAIL to prevent false passes.

### Custom prompts

If `.harn/prompts/` exists in the target project, those files override built-in `prompts/` files. `harn init` can AI-generate them by merging base prompts with user-provided hints.

### Python for wide-char input

`_input_readline` and `_input_multiline` use raw-mode Python because macOS libedit mishandles multi-byte character widths. Do not replace these with `read -r`.

### Bash style

- `set -euo pipefail` at top
- 2-space indent
- `local` for all function variables

## Contributing

- Fork from `develop` branch, not `main`
- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`)
- Run `bash -n harn.sh` before committing
- PR targets `develop`
- npm publish is triggered automatically on git tag `v*` via `.github/workflows/publish.yml`
