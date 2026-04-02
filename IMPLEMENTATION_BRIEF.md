# Implementation Brief: harn Web Transition

## Purpose

This brief exists to translate the product requirements in [PRD.md](/Users/giyeongum/Documents/Projects/harness/PRD.md) into implementation constraints for an execution agent.

The goal is not to redesign `harn` from scratch. The goal is to preserve the current orchestration engine and replace the unstable terminal-first UX with a localhost web application and per-project background service model.

## What harn Is

`harn` is a local AI sprint orchestration tool written primarily in Bash.

Its core behavior today:

- reads and updates a backlog
- plans work into sprint artifacts
- runs a Planner -> Generator -> Evaluator loop
- persists run state under `.harn/` in the target project
- invokes AI CLIs for different roles
- keeps artifacts such as `plan.txt`, `spec.md`, `sprint-backlog.md`, `contract.md`, `implementation.md`, `qa-report.md`, and `handoff.md`

The existing Bash engine is the core product. The current terminal UI is not.

## Source Of Truth

For Phase 1, these remain the source of truth:

- `.harn/` in the target project
- `.harn_config`
- existing backlog file configured by the project
- current Bash command behavior in `harn.sh` and `lib/*.sh`

Do not invent a separate database as the primary state store in Phase 1.

## Non-Negotiable Constraints

- Keep the existing Planner -> Generator -> Evaluator workflow.
- Keep existing CLI commands working.
- Keep `.harn/` semantics intact unless a specific migration is intentionally defined.
- Keep the product local-first.
- Do not introduce a hosted backend.
- Do not replace the Bash engine in Phase 1.
- Treat the web layer as a UI/runtime shell around the current engine.

## AS-IS Runtime

- `harn` is terminal-first.
- Interaction is via CLI commands and a terminal REPL.
- Some UX relies on terminal cursor control and raw mode behavior.
- Long-running work is effectively shell-oriented.
- `.harn/` already persists the important run state.

## TO-BE Runtime

- `harn` opens a localhost web UI by default.
- `harn web` also opens the same web UI explicitly.
- A per-project local background service owns the active session.
- The browser is a reconnectable client, not the owner of work execution.
- Closing the browser must not stop active work.
- Running `harn` again in the same project must reconnect to the existing local session if present.
- `harn exit` must stop the local service and active work for that project.
- The web UI must provide a visible shutdown action equivalent to `harn exit`.

## UX Target

The UI should feel like a ChatGPT-style application using a shadcn-style layout and components:

- fixed top header
- fixed bottom composer
- central live work feed
- left sidebar or equivalent navigation for backlog, runs, sprints, logs, settings, prompts, and memory

Main feed rule:

- the main feed is always about the current active work
- historical logs, reports, and artifacts live in the sidebar and its detail panels

Session rule:

- Phase 1 does not support concurrent multi-tab control

## Expected Architecture Direction

Recommended Phase 1 split:

- CLI layer:
  - `harn` starts or reconnects to the local web service
  - `harn web` explicitly opens the web UI
  - `harn exit` shuts down the service and active work
- local background service:
  - one project session per working directory
  - owns subprocesses and lifecycle
  - exposes API endpoints and a streaming channel
- web client:
  - renders the UI
  - subscribes to live updates
  - reads and mutates state through the local service

## Implementation Priorities

### Priority 1: Runtime foundation

- define per-project local service startup
- define reconnect behavior
- define shutdown behavior for `harn exit`
- define browser auto-open behavior

### Priority 2: Read-only visibility

- show header summary from current project state
- show current run and sprint state
- show backlog state
- show logs and artifacts

### Priority 3: Core actions

- natural-language composer
- `start`
- `auto`
- `all`
- `discover`
- `add`
- `stop`
- `resume`
- `clear`
- `doctor`

### Priority 4: Editing/configuration

- settings editing
- model/backend editing
- prompt editing
- memory editing

## Suggested MVP

An acceptable first MVP should:

- launch a localhost service from `harn`
- open the browser automatically
- reconnect on repeated `harn`
- expose a working chat/composer shell
- show current active work in the main feed
- show backlog, current run, sprints, and logs in side panels
- support `start`, `stop`, `clear`, and `doctor`
- support `harn exit`

The MVP does not need to solve every design detail before becoming usable.

## Avoid These Mistakes

- Do not reimplement the sprint engine in another language immediately.
- Do not make the browser tab the owner of background work.
- Do not move primary state out of `.harn/` without a migration plan.
- Do not optimize for multi-user or remote access.
- Do not break existing CLI usage while adding the web path.
- Do not treat this as a greenfield chat product.

## Recommended First Deliverable

Before deep implementation, produce a short technical proposal that includes:

- chosen server stack
- chosen frontend stack
- file/directory layout
- service lifecycle design
- reconnect model
- API surface for state read and command execution
- streaming model for live logs
- shutdown model for `harn exit`

Then implement in small vertical slices instead of building the whole UI at once.

## Acceptance Mindset

A good implementation should make it possible to say:

- I can run `harn` and land in a localhost UI
- my work keeps running if I close the browser
- I can come back by running `harn` again
- I can inspect current and past sprint state visually
- I can issue work requests from the web UI
- I can shut everything down cleanly with `harn exit` or the UI shutdown control
