# lib/ai.sh — AI CLI detection, backend selection, generation
# Sourced by harn.sh — do not execute directly

# ── Custom prompt generation ───────────────────────────────────────────────────

MODEL_CACHE_DIR="$HARN_DIR/model-cache"

_model_cache_file() {
  local backend="$1"
  echo "$MODEL_CACHE_DIR/${backend}.txt"
}

_write_model_cache() {
  local backend="$1"
  shift
  mkdir -p "$MODEL_CACHE_DIR"
  local cache_file
  cache_file=$(_model_cache_file "$backend")
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" | awk 'NF && !seen[$0]++' > "$cache_file"
  else
    : > "$cache_file"
  fi
}

_read_model_cache() {
  local backend="$1"
  local cache_file
  cache_file=$(_model_cache_file "$backend")
  [[ -f "$cache_file" ]] || return 1
  awk 'NF && !seen[$0]++' "$cache_file"
}

_discover_models_with_timeout() {
  local backend="$1"
  python3 - "$backend" <<'PYEOF'
import subprocess
import sys
import re

backend = sys.argv[1]

COMMANDS = {
    "claude": [["claude", "models"]],
    "gemini": [["gemini", "models", "list"], ["gemini", "list-models"]],
}

PATTERNS = {
    "claude": re.compile(r"(claude-[A-Za-z0-9.\-]+)"),
    "gemini": re.compile(r"(gemini-[A-Za-z0-9.\-]+)"),
}

for cmd in COMMANDS.get(backend, []):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except Exception:
        continue
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    models = []
    seen = set()
    for match in PATTERNS.get(backend, re.compile("$^")).findall(text):
        if match not in seen:
            seen.add(match)
            models.append(match)
    if models:
        sys.stdout.write("\n".join(models))
        sys.exit(0)
sys.exit(1)
PYEOF
}

refresh_model_cache() {
  mkdir -p "$MODEL_CACHE_DIR"
  local backend
  local -a backends=()
  command -v copilot &>/dev/null && backends+=("copilot")
  command -v claude  &>/dev/null && backends+=("claude")
  command -v codex   &>/dev/null && backends+=("codex")
  command -v gemini  &>/dev/null && backends+=("gemini")

  for backend in "${backends[@]}"; do
    local models=""
    case "$backend" in
      claude|gemini)
        models=$(_discover_models_with_timeout "$backend" 2>/dev/null || true)
        ;;
    esac
    if [[ -n "$models" ]]; then
      _write_model_cache "$backend" $models
    else
      _write_model_cache "$backend" $(_get_models_for_backend_fallback "$backend")
    fi
  done
}

# Detect AI CLI: config/env override → auto-detect
_detect_ai_cli() {
  # Explicit override via env or loaded config
  local backend="${AI_BACKEND:-}"
  if [[ -n "$backend" ]]; then
    echo "$backend"; return
  fi
  # Auto-detect in preference order
  if command -v copilot &>/dev/null; then echo "copilot"
  elif command -v claude  &>/dev/null; then echo "claude"
  elif command -v codex   &>/dev/null; then echo "codex"
  elif command -v gemini  &>/dev/null; then echo "gemini"
  else echo ""
  fi
}

# Check which AI CLIs are installed; print a guidance message if none
_check_ai_cli_installed() {
  local has_copilot=false has_claude=false has_codex=false has_gemini=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  command -v codex   &>/dev/null && has_codex=true
  command -v gemini  &>/dev/null && has_gemini=true

  if [[ "$has_copilot" == "false" && "$has_claude" == "false" && "$has_codex" == "false" && "$has_gemini" == "false" ]]; then
    echo -e "\n${I18N_NO_AI_CLI}"
    echo -e "  ${I18N_NO_AI_CLI_HINT}\n"
    return 1
  fi
  return 0
}

# Interactive AI backend selection; sets AI_BACKEND variable
_select_ai_backend() {
  local has_copilot=false has_claude=false has_codex=false has_gemini=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  command -v codex   &>/dev/null && has_codex=true
  command -v gemini  &>/dev/null && has_gemini=true

  # Build menu from installed CLIs
  local available=()
  [[ "$has_copilot" == "true" ]] && available+=("copilot  (GitHub Copilot CLI)")
  [[ "$has_claude"  == "true" ]] && available+=("claude   (Anthropic Claude CLI)")
  [[ "$has_codex"   == "true" ]] && available+=("codex    (OpenAI Codex CLI)")
  [[ "$has_gemini"  == "true" ]] && available+=("gemini   (Google Gemini CLI)")

  if [[ ${#available[@]} -eq 0 ]]; then
    return 1
  elif [[ ${#available[@]} -eq 1 ]]; then
    # Only one available — auto-select and show message
    local only="${available[0]%%\ *}"
    AI_BACKEND="$only"
    case "$only" in
      copilot) echo -e "\n${I18N_AI_USING_COPILOT}" ;;
      claude)  echo -e "\n${I18N_AI_USING_CLAUDE}"  ;;
      codex)   echo -e "\n${I18N_AI_USING_CODEX}"   ;;
      gemini)  echo -e "\n${I18N_AI_USING_GEMINI}"  ;;
    esac
  else
    local choice
    choice=$(_pick_menu "$I18N_AI_BACKEND_TITLE" 0 "${available[@]}") || return 1
    AI_BACKEND="${choice%%\ *}"
  fi
}

_get_models_for_backend_fallback() {
  local backend="$1"
  case "$backend" in
    claude)
      printf '%s\n' \
        "claude-haiku-4.5" "claude-sonnet-4.5" "claude-sonnet-4.6" \
        "claude-opus-4.5"  "claude-opus-4.6"
      ;;
    codex)
      printf '%s\n' \
        "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex" "gpt-5.2-codex" \
        "gpt-5.2" "gpt-5.1-codex-max" "gpt-5.1-codex-mini"
      ;;
    gemini)
      printf '%s\n' \
        "gemini-2.5-pro" "gemini-2.5-flash" "gemini-2.0-flash" \
        "gemini-1.5-pro" "gemini-1.5-flash"
      ;;
    copilot|*)  # copilot supports both claude and GPT models
      printf '%s\n' \
        "claude-haiku-4.5" "claude-sonnet-4.5" "claude-sonnet-4.6" \
        "claude-opus-4.5"  "claude-opus-4.6" \
        "gpt-4.1" "gpt-4o" "gpt-4o-mini" "o1" "o3-mini"
      ;;
  esac
}

_get_models_for_backend() {
  local backend="$1"
  local cached_models=""
  cached_models=$(_read_model_cache "$backend" 2>/dev/null || true)
  if [[ -n "$cached_models" ]]; then
    printf '%s\n' "$cached_models"
    return
  fi

  local models=""

  case "$backend" in
    claude)
      # Preferred source: Claude CLI's own model listing command.
      # This may fail when the user is not logged in; fall back to a bundled list.
      models=$(claude models 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | \
        awk '
          /^[[:space:]]*claude-/ { print $1; next }
          /^[[:space:]]*[[:alnum:]-]+[[:space:]]+claude-/ { print $2; next }
        ' | awk '!seen[$0]++')
      ;;
    gemini)
      # Gemini CLI variants differ by release; try a couple of discovery commands.
      models=$(
        { gemini models list 2>/dev/null || gemini list-models 2>/dev/null || true; } | \
        sed 's/\x1b\[[0-9;]*m//g' | \
        awk '
          /^[[:space:]]*gemini-/ { print $1; next }
          /gemini-[0-9]/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^gemini-/) print $i
          }
        ' | awk '!seen[$0]++'
      )
      ;;
    codex)
      # Codex CLI does not currently expose a stable "list models" command.
      # Keep a fallback catalog for the picker.
      models=""
      ;;
    copilot)
      # Copilot CLI does not expose a stable public list-models command in --help.
      # Keep a fallback catalog for the picker.
      models=""
      ;;
  esac

  if [[ -n "$models" ]]; then
    printf '%s\n' "$models" | awk 'NF'
  else
    _get_models_for_backend_fallback "$backend"
  fi
}

# Select AI backend + model for a role interactively.
# Prints "backend model" on success, exits 1 on cancel.
_pick_role_model() {
  local role_label="$1" default_backend="${2:-copilot}" default_model="$3"

  local has_copilot=false has_claude=false has_codex=false has_gemini=false
  command -v copilot &>/dev/null && has_copilot=true
  command -v claude  &>/dev/null && has_claude=true
  command -v codex   &>/dev/null && has_codex=true
  command -v gemini  &>/dev/null && has_gemini=true
  [[ "$has_copilot" == "false" && "$has_claude" == "false" && "$has_codex" == "false" && "$has_gemini" == "false" ]] && {
    log_err "No AI CLI found. Run: harn init"; return 1
  }

  # Build flat combined list: "backend / model"
  local options=()
  [[ "$has_copilot" == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("copilot / $m"); done < <(_get_models_for_backend "copilot")
  [[ "$has_claude"  == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("claude / $m");  done < <(_get_models_for_backend "claude")
  [[ "$has_codex"   == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("codex / $m");   done < <(_get_models_for_backend "codex")
  [[ "$has_gemini"  == "true" ]] && while IFS= read -r m; do [[ -n "$m" ]] && options+=("gemini / $m");  done < <(_get_models_for_backend "gemini")

  # Find default index
  local def_i=0
  local default_str="${default_backend} / ${default_model}"
  for i in "${!options[@]}"; do
    [[ "${options[$i]}" == "$default_str" ]] && { def_i=$i; break; }
  done

  local selected
  # Pass empty prompt — title already printed by caller with description
  selected=$(_pick_menu "" "$def_i" "${options[@]}") || return 1

  # Parse "backend / model" → "backend model"
  local backend="${selected%% /*}"
  local model="${selected##*/ }"
  printf "%s %s" "$backend" "$model"
}

# Generate a single prompt using the AI CLI
_ai_generate() {
  local ai_cmd="$1" prompt_text="$2" out_file="$3"
  local err_file; err_file=$(mktemp)
  local rc=0
  case "$ai_cmd" in
    copilot) copilot --yolo -p "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
    claude)  claude -p "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
    codex)   echo "$prompt_text" | codex exec - > "$out_file" 2>"$err_file" || rc=$? ;;
    gemini)  gemini -p "$prompt_text" > "$out_file" 2>"$err_file" || rc=$? ;;
  esac
  if [[ $rc -ne 0 ]]; then
    local err_msg; err_msg=$(cat "$err_file" 2>/dev/null | head -5)
    rm -f "$err_file"
    [[ -n "$err_msg" ]] && log_warn "  ${D}${err_msg}${N}"
    return $rc
  fi
  rm -f "$err_file"
  return 0
}

# Generate custom prompt files based on per-agent instructions + Git guidelines
_generate_custom_prompts() {
  local hint_planner="$1" hint_generator="$2" hint_evaluator="$3" git_guide="$4"
  local custom_dir="$ROOT_DIR/.harn/prompts"
  mkdir -p "$custom_dir"

  local ai_cmd
  ai_cmd=$(_detect_ai_cli)

  local roles="planner generator evaluator"
  for role in $roles; do
    local base="$PROMPTS_DIR/${role}.md"
    local out="$custom_dir/${role}.md"

    # Select role-specific hint
    local hint=""
    case "$role" in
      planner)   hint="$hint_planner" ;;
      generator) hint="$hint_generator" ;;
      evaluator) hint="$hint_evaluator" ;;
    esac

    # Combine additional instructions
    local extra=""
    [[ -n "$git_guide" ]] && extra="${extra}
**Git workflow guidelines**: ${git_guide}"
    [[ -n "$hint"      ]] && extra="${extra}
**Special instructions**: ${hint}"

    # No instructions — copy base prompt
    if [[ -z "$extra" ]]; then
      cp "$base" "$out"
      continue
    fi

    local role_kr
    case "$role" in
      planner)   role_kr="Planner" ;;
      generator) role_kr="Generator" ;;
      evaluator) role_kr="Evaluator" ;;
    esac

    log_info "Generating ${role_kr} prompt..."

    if [[ -n "$ai_cmd" ]]; then
      local gen_prompt
      gen_prompt="Below is the base prompt for the ${role_kr} agent.

$(cat "$base")

---

Naturally integrate the following instructions into the prompt and output the entire revised prompt.
Output only the prompt content — no markdown code blocks (\`\`\`).

Instructions to add:
${extra}"

      if _ai_generate "$ai_cmd" "$gen_prompt" "$out"; then
        log_ok "${role_kr} prompt generated: ${W}$out${N}"
      else
        log_warn "${role_kr} prompt generation failed — adding instructions to base prompt"
        cp "$base" "$out"
        printf "\n\n## Additional instructions\n%s\n" "$extra" >> "$out"
      fi
    else
      # No AI CLI — append instructions directly to base prompt
      cp "$base" "$out"
      printf "\n\n## Additional instructions\n%s\n" "$extra" >> "$out"
      log_ok "${role_kr} prompt generated (manual): ${W}$out${N}"
    fi
  done
}
