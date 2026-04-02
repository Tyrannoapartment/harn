# harn

**AI multi-agent sprint development loop orchestrator**

Automates a **Planner → Generator → Evaluator** loop that takes a backlog item and drives it to completion through sprints.

---

## Requirements

| Tool | Purpose |
|------|---------|
| `python3` | Backlog parsing, markdown rendering |
| `copilot`, `claude`, `codex`, or `gemini` | AI agent execution (at least one required) |

---

## Installation

### via npm (recommended)

```bash
npm install -g @tyrannoapartment/harn
```

After install, the version is printed automatically. You can also check anytime:

```bash
harn --version
```

### Manual (git clone)

```bash
git clone https://github.com/Tyrannoapartment/harn.git
cd harn
chmod +x harn.sh
ln -s "$(pwd)/harn.sh" /usr/local/bin/harn
```

### Uninstall

```bash
npm uninstall -g @tyrannoapartment/harn
```

---

## Quick Start

```bash
cd /path/to/your/project

# Check dependencies first (works even without config)
harn doctor

# First run launches the setup wizard automatically
harn start
```

---

## Commands

### Setup

| Command | Description |
|---------|-------------|
| `harn init` | Initial setup wizard (or re-run to reconfigure) |
| `harn doctor` | Check dependencies and configuration |
| `harn config` | Show current config |
| `harn config set KEY VALUE` | Update a config value |
| `harn config regen` | Regenerate custom prompts from HINT_* in config |
| `harn --version` | Show installed version |

### Backlog & Execution

| Command | Description |
|---------|-------------|
| `harn backlog` | Show pending backlog items |
| `harn auto` | Resume if in-progress, start if pending, discover if empty |
| `harn all` | Run all pending backlog items sequentially (1 sprint each) |
| `harn start` | Select a backlog item, set sprint count, and run the full loop |
| `harn discover` | Analyze codebase and suggest new backlog items |
| `harn add` | Manually add a backlog item |

### Step-by-step

| Command | Description |
|---------|-------------|
| `harn plan` | Re-run planner for the current run |
| `harn contract` | Sprint scope negotiation |
| `harn implement` | Run generator |
| `harn evaluate` | Run evaluator (auto-retries on FAIL) |
| `harn next` | Advance to next sprint |

### Monitoring

| Command | Description |
|---------|-------------|
| `harn status` | Show current run state |
| `harn tail` | Stream live log output |
| `harn runs` | List all runs |
| `harn resume <id>` | Resume a previous run |
| `harn stop` | Stop the running loop |

---

## Full Workflow

```
harn start
```

```
Select backlog item
    │
    ▼
Prompt: "Number of sprints [1]:"
    │  (harn auto / harn all always use 1 sprint)
    │
    ▼
[Planner]  spec.md + sprint-backlog.md
    │  Model: MODEL_PLANNER
    │  Divides the task into N self-contained scopes (one per sprint)
    │  Git (when GIT_ENABLED=true): commit backlog → In Progress
    │
    ▼  sprint loop ──────────────────────────────────────────────────────┐
    │                                                                    │
    │  ┌─ Scope negotiation (1 round) ──────────────────────────────┐    │
    │  │  [Generator]  propose scope       MODEL_GENERATOR_CONTRACT │    │
    │  │      ↓                                                     │    │
    │  │  [Evaluator]  APPROVED → contract.md                       │    │
    │  │               NEEDS_REVISION → Generator revises           │    │
    │  └────────────────────────────────────────────────────────────┘    │
    │                                                                    │
    │  ┌─ Implement → Evaluate  (up to MAX_ITERATIONS) ─────────────┐    │
    │  │  [Generator]  implement           MODEL_GENERATOR_IMPL     │    │
    │  │      ↓   Git (when GIT_ENABLED=true): commit changes       │    │
    │  │  [Evaluator]  lint / test / E2E                            │    │
    │  │               VERDICT: PASS → next sprint                  │    │
    │  │               VERDICT: FAIL → Generator retries            │    │
    │  │                               (MODEL_GENERATOR_CONTRACT)   │    │
    │  └────────────────────────────────────────────────────────────┘    │
    └────────────────────────────────────────────────────────────────────┘
    │
    ▼  (last sprint passes)
[Evaluator]  write handoff.md
backlog item → Done
    │  Git (when GIT_ENABLED=true): final commit
    │
    ▼
[Evaluator]  retrospective + prompt improvement suggestions
```

> **QA FAIL retry model**: `MODEL_GENERATOR_CONTRACT` (sonnet) — iteration 1 uses `MODEL_GENERATOR_IMPL` (opus); retries use the lighter model.

> **Sprint count**: defaults to 1. For multi-sprint runs, the Planner divides the task by feature area or logical component — not implementation vs. tests. Each sprint is independently buildable and testable.

---

## Supported AI Backends

harn auto-detects installed CLIs in this order: `copilot` → `claude` → `codex` → `gemini`.

| CLI | Install |
|-----|---------|
| GitHub Copilot CLI (`copilot`) | `gh extension install github/gh-copilot` |
| Anthropic Claude Code (`claude`) | `npm install -g @anthropic-ai/claude-code` |
| OpenAI Codex CLI (`codex`) | `npm install -g @openai/codex` |
| Google Gemini CLI (`gemini`) | `npm install -g @google/gemini-cli` |

Override the backend per-run or in config:

```bash
harn config set AI_BACKEND claude
```

---

## AI Models (defaults)

| Role | Default model |
|------|--------------|
| Planner | `claude-haiku-4.5` |
| Generator — scope | `claude-sonnet-4.6` |
| Generator — implementation | `claude-opus-4.6` |
| Evaluator — scope review | `claude-haiku-4.5` |
| Evaluator — QA | `claude-sonnet-4.5` |

Override at runtime:

```bash
HARN_MODEL_GENERATOR_IMPL=claude-sonnet-4.6 harn start
```

---

## Configuration (.harn_config)

Auto-generated on first run or `harn init`. Sprint count is **not** stored here — it is asked each time you run `harn start`.

```bash
# .harn_config

BACKLOG_FILE="docs/planner/sprint-backlog.md"
MAX_ITERATIONS=5

AI_BACKEND="copilot"

MODEL_PLANNER="claude-haiku-4.5"
MODEL_GENERATOR_CONTRACT="claude-sonnet-4.6"
MODEL_GENERATOR_IMPL="claude-opus-4.6"
MODEL_EVALUATOR_CONTRACT="claude-haiku-4.5"
MODEL_EVALUATOR_QA="claude-sonnet-4.5"

GIT_ENABLED="false"
```

Update values:

```bash
harn config set MAX_ITERATIONS 3
harn config set GIT_ENABLED true
harn config set MODEL_GENERATOR_IMPL claude-sonnet-4.6

# Configure test commands (auto-detected if not set)
harn config set LINT_COMMAND "npm run lint"
harn config set TEST_COMMAND "npm test"
harn config set E2E_COMMAND "docker-compose up -d && sleep 5"
```

---

## Project Context

Place a context file at `.harn/context.md` in your project. All agents read it automatically.

```markdown
## Project Overview
...

## Architecture
...

## Tech Stack
...

## Development Rules
...
```

---

## Custom Prompts

Place `planner.md`, `generator.md`, `evaluator.md` in `CUSTOM_PROMPTS_DIR` to override built-in prompts.

```bash
mkdir -p .harn/prompts
cp ~/.local/share/harn/prompts/generator.md .harn/prompts/
# edit, then:
harn config set CUSTOM_PROMPTS_DIR ".harn/prompts"
# or regenerate from HINT_* values in config:
harn config regen
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
