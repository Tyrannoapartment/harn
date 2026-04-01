# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**harn** is a multi-agent sprint development loop orchestrator written in Bash. It automates a **Planner → Generator → Evaluator** loop that takes a backlog item and drives it to completion through AI agents (GitHub Copilot CLI or Claude CLI).

Dependencies: `python3`, and either `copilot` (GitHub Copilot CLI) or `claude` CLI.

Published as npm package `@tyrannoapartment/harn`.

## Development Commands

```bash
# Install locally (creates a symlink, so edits are live immediately)
bash install.sh

# Syntax check harn.sh
bash -n harn.sh

# Run a command directly without installing
bash harn.sh help
bash harn.sh backlog
```

There is no test suite for harn itself — test manually in a real project after changes.

## Architecture

### Core files

- **`harn.sh`** — Single-file orchestrator (~4,200 lines). All commands, agent invocation, run state, config, and git workflow live here.
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
    sprint-backlog.md    # sprint definitions
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
  └─ cmd_plan (Planner: backlog item → spec.md + sprint-backlog.md)
      └─ _run_sprint_loop
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

- Planner: `=== plan.text ===`, `=== spec.md ===`, `=== sprint-backlog.md ===`
- Evaluator verdict: must end with exactly `VERDICT: PASS` or `VERDICT: FAIL` on its own line
- Contract review: must contain `APPROVED` or `NEEDS_REVISION` on its own line
- Retrospective: `=== retro-summary ===`, `=== prompt-suggestion:planner ===`, `=== prompt-suggestion:generator ===`, `=== prompt-suggestion:evaluator ===`

### Language

UI output language is auto-detected via `_detect_lang()` (Korean/English). All agent prompt files must be authored in **English**. Code identifiers, file paths, and package names stay in English.

### Backlog format

```markdown
## Pending
- [ ] **slug-with-no-spaces**
  description text
  plan: one-line plan after planning

## In Progress
## Done
```

Slugs must have no spaces — they're used as programmatic identifiers.

### Model configuration priority

CLI flag > `HARN_MODEL_<ROLE>` env var > `.harn_config` `MODEL_<ROLE>` > hardcoded defaults

Default models: Planner=`claude-haiku-4.5`, Generator(contract)=`claude-sonnet-4.6`, Generator(impl)=`claude-opus-4.6`, Evaluator(contract)=`claude-haiku-4.5`, Evaluator(QA)=`claude-sonnet-4.5`

Per-invocation override:
```bash
harn --generator-impl-model claude-sonnet-4.6 start
```

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
