# harn — Copilot Instructions

## What This Is

**harn** is a multi-agent sprint development loop orchestrator written in Bash. It automates a **Planner → Generator → Evaluator** loop that takes a backlog item and drives it to completion through AI agents.

Dependencies: `python3`, and either `copilot` (GitHub Copilot CLI) or `claude` CLI.

## Architecture

### Core files

- **`harn.sh`** — Single-file orchestrator (~1800 lines). Handles all commands, agent invocation, run state, and config.
- **`parser/md_stream.py`** — Real-time markdown colorizer piped from agent stdout.
- **`parser/stream_parser.py`** — Real-time JSON stream parser for `claude --output-format stream-json`.
- **`prompts/`** — System prompts for each agent role: `planner.md`, `generator.md`, `evaluator.md`, `retrospective.md`.

### Runtime state

All state for a run lives under `.harness/` in the **target project directory** (not this repo):

```
.harness/
  harness.log          # global log
  current -> runs/<id> # symlink to active run
  current.log          # symlink to active run log
  runs/<YYYYMMDD-HHMMSS>/
    prompt.txt         # selected backlog slug
    plan.txt           # one-line plan text
    spec.md            # product spec from planner
    sprint-plan.md  # sprint definitions from planner
    sprints/
      001/
        contract.md       # agreed sprint scope
        implementation.md # generator output
        qa-report.md      # evaluator verdict
        status            # pending|in-progress|pass|fail|cancelled
        iteration         # retry count
        handoff.md        # completion summary
```

### Sprint loop flow

```
cmd_start
  └─ cmd_plan (Planner: backlog item → spec.md + sprint-plan.md)
      └─ _run_sprint_loop
          ├─ cmd_contract (Generator proposes scope → Evaluator approves/revises)
          ├─ cmd_implement (Generator implements; retries up to MAX_ITERATIONS on FAIL)
          ├─ cmd_evaluate (Evaluator QA; runs dart analyze + flutter test on last sprint)
          └─ cmd_next (Evaluator writes handoff; backlog item → Done)
```

### Agent invocation

All agents run through `invoke_role()` → `invoke_copilot()`:

```bash
copilot --add-dir "$ROOT_DIR" --yolo -p "$prompt_text" [--model <model>] [--effort high]
```

- Generator always gets `--effort high`
- Model falls back to `COPILOT_MODEL` env var on older CLI versions
- Output is piped through `tee` to both the run log and `_md_stream` (colorizer)

Two distinct agent invocation paths:
- **Sprint agents** (`invoke_role` → `invoke_copilot`): always use `copilot` CLI with `--add-dir`
- **Lightweight generation** (`_ai_generate`): used by `cmd_add`, `cmd_discover`, and `harn init`; auto-detects `copilot` first, falls back to `claude`

## Key Conventions

### Language
All UI output and agent prompts are in **Korean**. Code identifiers, file paths, and package names stay in English. This applies to all agent prompt files too.

### Backlog format

The backlog markdown file uses these exact section headers:

```markdown
## Pending
- [ ] **slug-with-no-spaces**
  description text
  plan: one-line plan after planning

## In Progress
## Done
```

Slugs must have no spaces — they're used as programmatic identifiers. When `cmd_plan` runs, the item moves from Pending → In Progress; when `cmd_next` runs, it moves to Done.

### Agent output section markers

Agents are expected to output **exact section markers** that `awk` parses:

- Planner: `=== plan.text ===`, `=== spec.md ===`, `=== sprint-plan.md ===`
- Retrospective: `=== retro-summary ===`, `=== prompt-suggestion:planner ===`, etc.
- Evaluator verdict: must end with exactly `VERDICT: PASS` or `VERDICT: FAIL` on its own line
- Contract review: must contain `APPROVED` or `NEEDS_REVISION` on its own line

Do not change these markers — the harness depends on exact string matching.

### Model configuration priority

`HARNESS_COPILOT_MODEL_<ROLE>` env var > `.harness_config` `MODEL_<ROLE>` > hardcoded defaults

Default models: Planner=`claude-haiku-4.5`, Generator(contract)=`claude-sonnet-4.6`, Generator(impl)=`claude-opus-4.6`, Evaluator(contract)=`claude-haiku-4.5`, Evaluator(QA)=`claude-sonnet-4.5`

### Custom prompts

If `.harness/prompts/` exists in the target project, those files override the built-in `prompts/` files. `harn init` generates them by AI-merging the base prompts with user-provided hints.

### Python for wide-char input

Korean text input (backspace handling) is done via raw-mode Python (`_input_readline`, `_input_multiline`) because macOS libedit mishandles multi-byte character widths. Don't replace these with `read -r`.

### E2E evaluation (last sprint only)

`cmd_evaluate` has hardcoded logic for the final sprint: it starts backend (`services/backend/bin/main.dart` on port 8080), MCP server (`services/mcp/bin/server_http.dart` on port 8181), and Flutter web app (port 3000), then passes URLs to the Evaluator agent for Playwright-based testing. This is designed for Dart/Flutter target projects.

### Per-run model override (CLI flags)

Models can be overridden per-invocation with flags before the command:

```bash
harn --generator-impl-model claude-sonnet-4.6 start
harn --planner-model claude-haiku-4.5 --evaluator-qa-model claude-sonnet-4.6 start
```

Available flags: `--planner-model`, `--generator-contract-model`, `--generator-impl-model`, `--evaluator-contract-model`, `--evaluator-qa-model`.

### High-level commands

- **`harn auto`** — Smart entry point: resumes in-progress run → starts next pending item → runs `discover` if backlog is empty
- **`harn all`** — Runs all pending backlog items sequentially; suppresses per-item retrospectives (`HARN_SKIP_RETRO=true`) and runs a single retrospective at the end
- **`harn discover`** — Analyzes the codebase with `_ai_generate` and appends new items to the `## Pending` section of the backlog
- **`harn add`** — Interactive prompt: describe a feature in free text, AI generates 1–3 slug/description pairs and inserts them into the backlog
- **`harn start <slug>`** — Can optionally pass a slug directly to skip the interactive selection

### Inter-step user instructions

During a running sprint loop, the harness pauses between steps and reads `USER_EXTRA_INSTRUCTIONS` from stdin. Users can inject additional context that gets appended to the next agent's prompt.

## Running / Testing harn Itself

```bash
# Install locally
bash install.sh

# Reinstall after changes (symlinks to source, so edits are live)
bash install.sh

# Test a command directly without installing
bash harn.sh help
bash harn.sh backlog
```

Because `install.sh` creates a symlink (`harn → $LIB_DIR/harn.sh`), edits to `harn.sh` take effect immediately after install — no reinstall needed.

There is no test suite for the harness itself.
