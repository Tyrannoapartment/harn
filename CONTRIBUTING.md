# Contributing to harn

Thank you for your interest in contributing! harn is an AI multi-agent sprint orchestrator — contributions of all kinds are welcome.

## How to Contribute

### Reporting Bugs

Open a [bug report](https://github.com/Tyrannoapartment/harn/issues/new?template=bug_report.yml). Include:
- harn version (`harn version`)
- OS and shell version
- Steps to reproduce
- Actual vs expected behavior

### Suggesting Features

Open a [feature request](https://github.com/Tyrannoapartment/harn/issues/new?template=feature_request.yml) describing the problem you want to solve and your proposed solution.

### Submitting Code

1. **Fork** the repository and create a branch from `develop`:
   ```bash
   git checkout -b feat/your-feature develop
   ```

2. **Make your changes** — keep them focused and minimal.

3. **Follow commit conventions** ([Conventional Commits](https://www.conventionalcommits.org)):
   ```
   feat: add new command
   fix: correct branch detection logic
   docs: update README install section
   chore: bump version to 1.1.0
   ```

4. **Test manually** — run `bash -n harn.sh` (syntax check) and test the affected commands in a real project.

5. **Open a PR** targeting the `develop` branch. Fill out the PR template fully.

## Branch Strategy

| Branch    | Purpose                        |
|-----------|--------------------------------|
| `main`    | Stable releases only           |
| `develop` | Integration branch for PRs     |
| `feat/*`  | Feature branches (from develop)|
| `fix/*`   | Bug fix branches (from develop)|

## Code Style

- **Bash**: follow the existing style — `set -euo pipefail`, 2-space indent, `local` for all function variables
- **Python**: standard library only, compatible with Python 3.8+
- **Prompts**: written in English; keep section markers (`=== ... ===`) intact

## Project Structure

```
harn.sh          # Main orchestrator (~1800+ lines)
install.sh       # Installer
uninstall.sh     # Uninstaller
parser/
  md_stream.py   # Real-time markdown colorizer
  stream_parser.py # JSON stream parser for claude CLI
prompts/
  planner.md     # Planner agent system prompt
  generator.md   # Generator agent system prompt
  evaluator.md   # Evaluator agent system prompt
  retrospective.md # Retrospective agent system prompt
```

## Questions?

Open a [discussion](https://github.com/Tyrannoapartment/harn/discussions) or a [blank issue](https://github.com/Tyrannoapartment/harn/issues/new).
