# harn

**AI multi-agent sprint development loop orchestrator**

Automates a **Planner → Generator → Evaluator** loop that takes a backlog item and drives it to completion through sprints.

---

## Requirements

| Tool | Purpose |
|------|---------|
| `python3` | Backlog parsing, markdown rendering |
| `copilot` or `claude` | AI agent execution |

```bash
# GitHub Copilot CLI
npm install -g @githubnext/github-copilot-cli

# or Claude Code CLI
# https://claude.ai/code
```

---

## Installation

### Homebrew (recommended)

> Coming soon — tap setup in progress.

### curl

```bash
curl -fsSL https://raw.githubusercontent.com/Tyrannoapartment/harn/main/install.sh | bash
```

### Manual

```bash
git clone https://github.com/Tyrannoapartment/harn.git
cd harn
bash install.sh
```

#### Options

```bash
bash install.sh             # user install  (~/.local/share/harn, ~/.local/bin/harn)
bash install.sh --global    # system-wide   (/usr/local/lib/harn, /usr/local/bin/harn)
HARN_PREFIX=/opt bash install.sh   # custom prefix
```

> **PATH note**: After a user install, add `~/.local/bin` to PATH if it isn't already:
> ```bash
> echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
> ```

### Uninstall

```bash
bash uninstall.sh           # remove user install
bash uninstall.sh --global  # remove system-wide install
```

---

## Quick Start

```bash
cd /path/to/your/project

# First run launches the setup wizard automatically
harn start
```

---

## Commands

### Setup

| Command | Description |
|---------|-------------|
| `harn init` | Initial setup wizard (or re-run to reconfigure) |
| `harn config` | Show current config |
| `harn config set KEY VALUE` | Update a config value |
| `harn config regen` | Regenerate custom prompts from HINT_* in config |

### Backlog & Execution

| Command | Description |
|---------|-------------|
| `harn backlog` | Show pending backlog items |
| `harn auto` | Resume if in-progress, start if pending, discover if empty |
| `harn start` | Select a backlog item and run the full loop |
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
| `harn version` | Show version |

---

## Full Workflow

```
harn start
```

```
Select backlog item
    │
    ▼
[Planner]  spec.md + sprint-backlog.md
    │  Model: MODEL_PLANNER
    │  Git:   create plan/<slug> branch
    │         commit backlog → In Progress
    │         push to origin
    │         open Draft PR  (fork → upstream)
    │
    ▼  sprint loop ──────────────────────────────────────────────────────┐
    │                                                                    │
    │  ┌─ Scope negotiation (1 round) ──────────────────────────────┐   │
    │  │  [Generator]  propose scope       MODEL_GENERATOR_CONTRACT  │   │
    │  │      ↓                                                      │   │
    │  │  [Evaluator]  APPROVED → contract.md                        │   │
    │  │               NEEDS_REVISION → Generator revises            │   │
    │  └────────────────────────────────────────────────────────────┘   │
    │                                                                    │
    │  ┌─ Implement → Evaluate  (up to MAX_ITERATIONS) ─────────────┐   │
    │  │  [Generator]  implement           MODEL_GENERATOR_IMPL      │   │
    │  │      ↓   Git: commit + push                                 │   │
    │  │  [Evaluator]  dart analyze / flutter test / E2E             │   │
    │  │               VERDICT: PASS → next sprint                   │   │
    │  │               VERDICT: FAIL → Generator retries             │   │
    │  │                               (MODEL_GENERATOR_CONTRACT)    │   │
    │  └────────────────────────────────────────────────────────────┘   │
    └────────────────────────────────────────────────────────────────────┘
    │
    ▼  (last sprint passes)
[Evaluator]  write handoff.md
backlog item → Done  +  git commit
    │  Git (when GIT_AUTO_MERGE=true):
    │        git push origin <branch>
    │        gh pr merge --merge
    │        git checkout <base>
    │        git pull upstream <base>
    │
    ▼
[Evaluator]  retrospective + prompt improvement suggestions
```

> **QA FAIL retry model**: `MODEL_GENERATOR_CONTRACT` (sonnet) — iteration 1 uses `MODEL_GENERATOR_IMPL` (opus); retries use the lighter model.

> **Auto-merge**: only runs when `GIT_AUTO_MERGE=true`. Defaults to `false` — merge the PR manually on GitHub.

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
HARNESS_COPILOT_MODEL_GENERATOR_IMPL=claude-sonnet-4.6 harn start
```

---

## Configuration (.harness_config)

Auto-generated on first run or `harn init`.

```bash
# .harness_config

BACKLOG_FILE="docs/planner/sprint-backlog.md"
MAX_ITERATIONS=5

MODEL_PLANNER="claude-haiku-4.5"
MODEL_GENERATOR_CONTRACT="claude-sonnet-4.6"
MODEL_GENERATOR_IMPL="claude-opus-4.6"
MODEL_EVALUATOR_CONTRACT="claude-haiku-4.5"
MODEL_EVALUATOR_QA="claude-sonnet-4.5"

GIT_ENABLED="false"
GIT_BASE_BRANCH="main"
GIT_UPSTREAM_REMOTE="upstream"
GIT_AUTO_PUSH="false"
GIT_AUTO_PR="false"
GIT_PR_DRAFT="true"
GIT_AUTO_MERGE="false"
```

Update values:

```bash
harn config set MAX_ITERATIONS 3
harn config set GIT_ENABLED true
harn config set MODEL_GENERATOR_IMPL claude-sonnet-4.6
```

---

## Project Context

Place a context file at `.harness/context.md` in your project. All agents read it automatically.

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
mkdir -p .harness/prompts
cp ~/.local/share/harn/prompts/generator.md .harness/prompts/
# edit, then:
harn config set CUSTOM_PROMPTS_DIR ".harness/prompts"
# or regenerate from HINT_* values in config:
harn config regen
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
