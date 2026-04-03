# PRD: harn Web UI

## Overview

`harn` is currently a terminal-first AI multi-agent sprint loop tool. The next product direction is to make `harn` launch and reconnect to a localhost web application by default, so users can manage the full workflow from a browser-based UI instead of a TTY-driven REPL.

The web experience should preserve the current `harn` identity and core Bash engine, while replacing unstable terminal UI behavior with a modern, ChatGPT-style interface:

- fixed header
- scrollable main conversation/log area
- fixed bottom composer
- visible backlog / sprint / run state
- settings and control actions in UI

The local web app should allow users to do everything they can do today in the CLI, while making logs, markdown, sprint state, backlog state, and settings easier to understand and control.

The runtime model should change from a foreground terminal UI to a local background service:

- `harn` starts or reconnects to a per-project localhost service
- the browser is only a client; work continues even if the page is closed
- re-running `harn` reopens the current local session and shows active work
- `harn exit` shuts down the local service and stops all active background work
- the web UI must also expose a visible shutdown action equivalent to `harn exit`

## Project Context

`harn` is not a generic chat app. It is a local AI sprint orchestration tool built around a Bash engine that drives a Planner -> Generator -> Evaluator loop against a target project.

Today, the product already has these core responsibilities:

- read a project backlog and pick work items
- generate plan/spec/sprint artifacts
- run multi-step sprint execution loops
- persist state under `.harn/` in the target project
- track backlog transitions across `Pending`, `In Progress`, and `Done`
- invoke AI backends and role-specific models
- preserve run artifacts such as `spec.md`, `contract.md`, `implementation.md`, `qa-report.md`, and `handoff.md`
- support operational controls like `start`, `auto`, `all`, `discover`, `add`, `stop`, `resume`, and `clear`

The current system already has a strong execution engine and filesystem-based state model. The weak point is the terminal UI layer. This project is therefore a UI/runtime transition, not a workflow rewrite.

## AS-IS -> TO-BE

This section is intended to make the migration target explicit for an implementation agent.

### AS-IS

- `harn` is terminal-first
- the primary interaction model is a TTY REPL plus CLI subcommands
- UI behavior depends on cursor control, raw mode, terminal rendering, and scroll-region tricks
- long-running work is tied to a local shell-oriented runtime model
- `.harn/` is the main persisted source of truth for run state and artifacts
- backlog, sprint, and logs are inspectable but awkward to browse
- markdown display quality is limited by terminal rendering
- reconnecting after leaving the interface is not a clean browser-native workflow
- operational actions exist, but discoverability and state visibility are weak

### TO-BE

- `harn` becomes localhost-web-first
- the primary interaction model is a browser UI with a chat/composer surface and side panels
- the UI uses a ChatGPT-like layout with shadcn-style shell/components
- terminal-specific rendering constraints are removed from the main UX
- a per-project local background service becomes the runtime owner for active work
- the browser becomes a reconnectable client for that service
- closing the browser does not stop work
- running `harn` again reopens and reattaches to the current local session
- `harn exit` and a web shutdown control terminate the service and all active work
- `.harn/` remains the primary persisted source of truth in Phase 1
- backlog, current run, sprint history, artifacts, settings, and logs are first-class UI surfaces
- the existing Bash orchestration engine is preserved behind a web/API layer in Phase 1

### Transition Rules

The following migration rules should be treated as hard constraints:

- preserve the current Planner -> Generator -> Evaluator workflow
- preserve `.harn/` artifact/state semantics unless a specific migration is defined
- preserve CLI command capability even if web becomes the default entrypoint
- move UI concerns to the browser, not orchestration concerns
- introduce a local background service without introducing a hosted backend
- keep the implementation local-first and single-user in Phase 1

## Problem

The current TTY UI has structural limits:

- fixed header, fixed input, and middle-only scrolling are hard to maintain reliably
- Markdown rendering is limited and inconsistent
- long AI logs can be too noisy or too hidden depending on mode
- screen clearing, scrollback, and cursor handling are fragile
- selecting actions, viewing sprint history, and inspecting artifacts is awkward
- model / backend / backlog / run state visibility is not strong enough
- there is no clean browser-style reconnect model for long-running local work

These constraints are causing repeated UX bugs and slowing feature work.

## Goal

When a user runs `harn`, a localhost web app opens automatically and becomes the main control surface for the product.

The UI should let the user:

- enter natural-language requests
- run `start`, `auto`, `all`, `discover`, `add`, `stop`, `resume`, `clear`
- inspect backlog items and state transitions
- inspect current run, sprint state, and past runs
- inspect generated artifacts like `spec.md`, `contract.md`, `implementation.md`, `qa-report.md`, `handoff.md`
- inspect logs in real time
- change AI backend and model settings
- clear `.harn` run/log state from the UI
- close and reopen the web UI without interrupting active work
- terminate the full local session explicitly with `harn exit` or a UI shutdown button

## Non-Goals

- replacing the underlying Bash orchestration engine in the first phase
- introducing remote hosting or multi-user collaboration
- redesigning the backlog / sprint file formats in the first phase
- changing the core Planner -> Generator -> Evaluator workflow in the first phase

## Users

Primary users:

- solo developers using `harn` locally on macOS
- developers who want a more visual interface for AI-assisted sprint execution

Secondary users:

- contributors debugging sprint state, logs, backlog movement, and model configuration

## User Experience Vision

The browser UI should feel closer to ChatGPT than to a terminal dashboard, using a shadcn-style application shell and controls:

- top branding/header remains fixed
- center area shows messages, logs, markdown, system status, and results
- bottom composer remains fixed and usable at all times
- side panels or tabs expose backlog, runs, sprints, settings, memory, prompts

Branding should preserve the current `harn` visual identity shown in the terminal banner:

- same logo feel
- same name and version visibility
- same project context summary
- same AI/run/backlog summary at the top

## Core User Flows

### 1. Launch

1. User runs `harn`
2. `harn` starts or reconnects to a localhost service for the current project
3. `harn` opens the browser automatically if possible
4. If browser auto-open fails, `harn` prints the local URL
5. The user lands in the web app
6. If a run is already active, the page restores that active state instead of creating a new one

### 1A. Reconnect after closing the browser

1. User closes the browser tab or window
2. The localhost service and active work keep running
3. Later, the user runs `harn` again
4. `harn` reconnects to the existing local service
5. The browser reopens on the current project session
6. The UI restores current run, logs, and sprint state

### 2. Natural-language request

1. User types a natural-language request in the composer
2. The app interprets the request using Backend AI
3. The app routes to the appropriate action
4. The app streams progress and logs
5. Backlog / run / sprint state updates in the UI

### 3. Start from backlog

1. User opens Backlog panel
2. User selects a pending backlog item
3. User clicks Start or uses natural language
4. The item moves to `In Progress`
5. The current run and sprint list appear
6. On completion, the item moves to `Done`

### 4. Inspect current sprint and artifacts

1. User opens Current Run or Sprint panel
2. User selects a sprint
3. User views:
   - contract
   - implementation
   - QA report
   - handoff
4. User sees current sprint status and iteration count

### 5. Change settings

1. User opens Settings
2. User changes backend and model per role
3. User changes Backend AI model
4. User updates `.harn_config`
5. Changes are applied to future actions

### 6. Clear state

1. User opens a clear/reset action from UI
2. App stops active run if necessary
3. `.harn/runs`, current symlinks, and log files are cleared
4. `.harn/memory.md`, `.harn/prompts`, and `.harn_config` are preserved

### 7. Exit the full session

1. User runs `harn exit` in the terminal or clicks Shutdown in the web UI
2. App asks for confirmation if active work exists
3. The local service stops accepting new work
4. Active background work is stopped cleanly
5. Browser clients disconnect and show a terminated-session state
6. A later `harn` invocation starts a fresh service again

## Product Scope

### In Scope

- localhost web server started by `harn`
- per-project local background service lifecycle
- browser UI opened from CLI
- ChatGPT-style layout with shadcn-style controls
- natural-language composer
- live logs
- markdown rendering
- backlog view
- sprint list and sprint detail view
- runs history view
- settings view
- clear/reset action
- stop/resume controls
- run artifact inspection
- state synced from `.harn` and `.harn_config`
- reconnect to active local session on repeated `harn`
- explicit full shutdown via CLI and UI

### Out of Scope for Phase 1

- cloud sync
- remote sessions
- authentication
- replacing Bash engine
- mobile web optimization beyond reasonable responsiveness

## Functional Requirements

### Launch and Session

- `harn` must start or reconnect to a local web service by default
- `harn web` must also be supported as an explicit web entry command
- `harn` should open the browser automatically when possible
- browser auto-open is the default and expected behavior
- the app must run fully on localhost
- the app must target the current working directory as the active project
- the localhost service must be able to continue work when the browser is closed
- re-running `harn` in the same project must reconnect to the existing service when one exists
- `harn exit` must terminate the localhost service for the current project
- `harn exit` must also stop active background work owned by that local service
- the web UI must expose a shutdown control equivalent to `harn exit`

### Header

The fixed header must show:

- `harn` branding
- current version
- project path
- AI backend summary
- active run summary
- backlog counts

### Composer

The fixed composer must support:

- natural-language input
- send action
- clear current draft
- disabled/loading state while appropriate
- multiline editing
- Shadcn-like visual styling consistent with the rest of the app

### Main Feed

The main feed must support:

- user messages
- system routing messages
- live AI logs
- markdown result rendering
- error rendering
- action result summaries
- only the current active work in the main live surface

### Backlog

The backlog view must show:

- Pending
- In Progress
- Done

The backlog view must support:

- selecting backlog items
- starting an item
- seeing plan text if present
- confirming state transitions visually

### Runs and Sprints

The app must show:

- active run
- prior runs
- sprint list per run
- sprint status
- sprint iteration count

The app must allow viewing:

- `plan.txt`
- `spec.md`
- `sprint-plan.md`
- `contract.md`
- `implementation.md`
- `qa-report.md`
- `handoff.md`

### Settings

The settings view must support:

- AI backend selection
- Backend AI backend/model selection
- Planner model selection
- Generator contract model selection
- Generator implementation model selection
- Evaluator contract model selection
- Evaluator QA model selection
- backlog path
- retry count
- Git integration toggle
- prompt regeneration where applicable
- direct editing of prompts
- direct editing of project memory

### Command Equivalents

The UI must expose actions equivalent to:

- `start`
- `auto`
- `all`
- `discover`
- `add`
- `stop`
- `resume`
- `clear`
- `doctor`

### Logging

The UI must:

- stream logs live
- keep the main feed focused on the current active work
- show past logs and prior reports in the left sidebar and its detail views
- preserve raw logs in `.harn`
- distinguish system events from AI output

### Markdown Rendering

Markdown rendering should feel GitHub-like:

- headings
- lists
- checkboxes
- code fences
- blockquotes
- tables
- inline code
- links

### State Management

The app must read from:

- `.harn/`
- `.harn_config`

The app must reflect:

- current run symlink
- current log
- runs directory
- sprint status files
- backlog contents
- memory
- prompts

The app must also track:

- whether a local service already exists for the current project
- whether background work is active even if no browser is connected
- whether the current browser is attached to a running or terminated session

## Non-Functional Requirements

- local-first only
- no required external hosted service for UI
- stable under long-running AI tasks
- browser close must not terminate active work
- service reconnect must be reliable across repeated `harn` launches
- shutdown behavior must be explicit and deterministic
- no TTY/raw-cursor dependency for core UX
- page refresh should recover current state
- must work on macOS development environment first
- should be reasonably responsive on desktop widths

## Technical Direction

Phase 1 should keep the current Bash orchestration engine and add a web layer on top.

Suggested architecture:

- CLI launcher:
  - `harn` starts or reconnects to a per-project localhost service
  - opens browser or prints URL
  - `harn exit` stops that service and its active work
- local background service:
  - owns active runs for one project
  - survives browser close
  - manages subprocess lifecycle, logs, and reconnect state
- local server:
  - thin API around Bash actions and `.harn` state
  - SSE or WebSocket for log streaming
- frontend:
  - SPA or lightweight single-page web app
  - chat-style main feed
  - sidebar/tabs for backlog, sprints, runs, settings
  - shutdown action in UI chrome

CLI entry behavior:

- `harn` opens the web UI by default
- `harn web` is also supported
- browser auto-open is enabled by default

## Proposed Information Architecture

- Header
- Main feed
- Composer
- Left sidebar or tabs:
  - Backlog
  - Current Run
  - Sprints
  - Runs
  - Settings
  - Logs
  - Memory / Prompts

Session policy:

- multi-tab support is out of scope
- only one active browser tab/session is supported in Phase 1
- if another tab is opened, the product may warn, reject, or replace the existing UI session instead of supporting concurrent multi-tab control

The `doctor` experience must be available as a web panel, not terminal-only.

## Data Sources

Primary filesystem sources:

- `.harn/current`
- `.harn/current.log`
- `.harn/harn.log`
- `.harn/runs/*`
- `.harn/memory.md`
- `.harn/prompts/*`
- `.harn_config`
- backlog file path from config
- local service pid/state metadata if introduced

## Error Handling Requirements

The UI should present friendly messages for:

- missing config
- missing backlog
- no active run
- no active local service
- AI CLI missing
- model capacity exhausted
- fallback model retries
- failed artifact generation
- failed backlog state movement
- stop / resume / clear errors
- reconnect errors
- shutdown errors

## Migration Strategy

Phase 1:

- keep terminal CLI commands working
- add web mode as the default `harn` experience
- keep Bash engine as source of truth
- expose existing command behavior through a local server
- introduce a per-project background service and reconnect model

Phase 2:

- reduce reliance on terminal REPL
- move more UI state and interactions to browser-native patterns

## Success Criteria

- running `harn` opens a usable localhost app
- closing the browser does not stop active work
- running `harn` again reconnects to the same local session when one exists
- `harn exit` fully terminates the local session and active work
- users can run the full sprint loop without terminal REPL interaction
- users can inspect backlog, run state, sprint artifacts, and settings from the web app
- markdown and logs are easier to read than in the current TTY UI
- backlog transitions are clearly visible in the UI
- support burden from terminal rendering bugs drops significantly

## TODO

- Decide server stack: Node vs Python
- Decide frontend stack
- Define localhost port strategy
- Define per-project local service lifecycle
- Define reconnect detection and attach flow for repeated `harn`
- Define `harn exit` semantics and process ownership rules
- Design API for reading `.harn` state
- Design API for command execution
- Design log streaming transport
- Define event model for UI updates
- Create wireframes for:
  - chat/log view
  - backlog panel
  - sprint detail view
  - runs history
  - settings
- Define clear/reset semantics in UI
- Define stop/resume UX
- Define shutdown UX and confirmation rules
- Define markdown rendering approach
- Define settings save/apply behavior
- Define artifact viewer behavior
- Define fallback/error messaging behavior
- Define startup/loading states
- Define reconnect/loading states for already-running sessions
- Define empty-state UX for uninitialized projects
- Define how team mode should appear in web UI if preserved
- Define rollout plan from terminal-first to web-first
- Define single-tab enforcement or replacement behavior
