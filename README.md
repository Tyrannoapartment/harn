# harn

AI multi-agent sprint orchestrator. Takes a backlog item and drives it to completion through a **Planner → Generator → Evaluator** loop.

---

## Install

```bash
npm install -g @tyrannoapartment/harn
```

**Requirements:** `node` ≥ 18, `python3`, and one of: `copilot` · `claude` · `codex` · `gemini`

---

## Quick Start

```bash
cd /path/to/your/project
harn web        # opens dashboard at http://localhost:7111
```

Or use the CLI directly:

```bash
harn auto       # resume → start next → discover (smart entry point)
harn start      # pick a backlog item and run the full loop
```

---

## Web Dashboard

`harn web` launches a local dashboard with four panels:

| Panel | What it does |
|-------|-------------|
| **Backlog** | Manage Pending / In Progress / Done items, add new items with slug + description + plan |
| **Console** | AI assistant chat — multi-tab, tab rename, AI logo + model badge per response |
| **Runs** | Sprint history and status |
| **Settings** | AI backend, per-role model selection, language, git |

The console assistant understands natural language:
```
start the next backlog item
add api-refactor to the backlog
what's the current sprint status?
```

---

## CLI Commands

```bash
harn web [--port 8080]   # web dashboard
harn auto                # smart entry: resume → start → discover
harn all                 # run all pending items sequentially
harn start [slug]        # run a specific item
harn add                 # add a backlog item
harn discover            # analyze codebase and suggest items
harn do "<request>"      # natural language command
harn status              # current run state
harn stop                # stop the running loop
harn runs                # list run history
harn doctor              # check dependencies
harn config              # show / edit config
harn memory              # show project memory
```

---

## Sprint Loop

```
[Planner]   spec.md + sprint-plan.md
     │
     ▼  per sprint ──────────────────────────────────────────────────┐
     │  [Generator]  propose scope                                   │
     │  [Evaluator]  APPROVED / NEEDS_REVISION                       │
     │       ↓                                                       │
     │  [Generator]  implement                                       │
     │  [Evaluator]  VERDICT: PASS → next sprint                     │
     │               VERDICT: FAIL → retry (up to MAX_ITERATIONS)    │
     └───────────────────────────────────────────────────────────────┘
     │
     ▼  last sprint passes
[Evaluator]  handoff.md · backlog → Done · retrospective
```

---

## AI Backends

Auto-detected in order: `copilot` → `claude` → `codex` → `gemini`

| CLI | Install |
|-----|---------|
| GitHub Copilot | `gh extension install github/gh-copilot` |
| Claude Code | `npm install -g @anthropic-ai/claude-code` |
| OpenAI Codex | `npm install -g @openai/codex` |
| Gemini | `npm install -g @google/gemini-cli` |

```bash
harn config set AI_BACKEND claude
```

---

## Configuration

Config lives at `.harn/config` in your project root. Created automatically on first run or via `harn init`.

```ini
AI_BACKEND=copilot

COPILOT_MODEL_PLANNER=claude-haiku-4.5
COPILOT_MODEL_GENERATOR_CONTRACT=claude-sonnet-4.6
COPILOT_MODEL_GENERATOR_IMPL=claude-opus-4.6
COPILOT_MODEL_EVALUATOR_CONTRACT=claude-haiku-4.5
COPILOT_MODEL_EVALUATOR_QA=claude-sonnet-4.5

MAX_ITERATIONS=5
GIT_ENABLED=false
```

---

## Backlog Format

Backlog is stored in `.harn/sprints/` as three files: `pending.md`, `in-progress.md`, `done.md`.

```markdown
## Pending
- [ ] **slug-no-spaces**
  Short description of the feature
  plan: one-line execution plan
```

Add items via the web dashboard or `harn add`.

---

## Project Context

Create `.harn/context.md` — all agents read it automatically.

---

## Custom Prompts

Place `planner.md`, `generator.md`, or `evaluator.md` in `.harn/prompts/` to override built-in prompts.  
`harn init` can generate them from hints you provide.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Fork from `develop`, PR targets `develop`.

## License

[MIT](LICENSE)

