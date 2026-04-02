# lib/doctor.sh — Diagnostics and auth
# Sourced by harn.sh — do not execute directly

cmd_doctor() {
  echo -e "\n${W}╔══════════════════════════════════════╗${N}"
  printf "${W}║  %-36s║${N}\n" "  $I18N_DOCTOR_TITLE"
  echo -e "${W}╚══════════════════════════════════════╝${N}\n"

  # ── Version ─────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_VERSION}${N}"
  echo -e "  harn:         ${C}$HARN_VERSION${N}"
  echo -e "  bash:         ${C}${BASH_VERSION:-unknown}${N}"
  echo ""

  # ── AI CLIs ─────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_BACKENDS}${N}"
  local backend_ok=0

  if command -v copilot &>/dev/null; then
    local cp_ver; cp_ver=$(copilot --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} copilot:      ${C}${cp_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} copilot:      ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v claude &>/dev/null; then
    local cl_ver; cl_ver=$(claude --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} claude:       ${C}${cl_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} claude:       ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v codex &>/dev/null; then
    local cx_ver; cx_ver=$(codex --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} codex:        ${C}${cx_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} codex:        ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v gemini &>/dev/null; then
    local gm_ver; gm_ver=$(gemini --version 2>/dev/null | head -1 || echo "installed")
    echo -e "  ${G}✓${N} gemini:       ${C}${gm_ver}${N}"
    backend_ok=1
  else
    echo -e "  ${D}–${N} gemini:       ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if [[ -n "${AI_BACKEND:-}" ]]; then
    echo -e "  ${I18N_DOCTOR_ACTIVE_BACKEND}: ${W}${AI_BACKEND}${N}"
  elif [[ $backend_ok -eq 0 ]]; then
    echo -e "  ${R}⚠ ${I18N_DOCTOR_NO_BACKEND}${N}"
  fi
  echo ""

  # ── Git ─────────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_GIT_SECTION}${N}"
  if command -v git &>/dev/null; then
    local git_ver; git_ver=$(git --version 2>/dev/null | head -1)
    echo -e "  ${G}✓${N} git:          ${C}${git_ver}${N}"
  else
    echo -e "  ${R}✗${N} git:          ${I18N_DOCTOR_NOT_FOUND}"
  fi

  if command -v gh &>/dev/null; then
    local gh_ver; gh_ver=$(gh --version 2>/dev/null | head -1)
    local gh_auth; gh_auth=$(gh auth status 2>&1 | grep -i "logged in" | head -1 | sed 's/^[[:space:]]*//')
    echo -e "  ${G}✓${N} gh:           ${C}${gh_ver}${N}"
    if [[ -n "$gh_auth" ]]; then
      echo -e "  ${G}✓${N} gh auth:      ${C}${gh_auth}${N}"
    else
      echo -e "  ${Y}?${N} gh auth:      ${I18N_DOCTOR_GH_AUTH_WARN}"
    fi
  else
    echo -e "  ${R}✗${N} gh:           ${I18N_DOCTOR_GH_NOT_FOUND}"
    echo -e "    ${I18N_DOCTOR_INSTALL}: ${W}brew install gh${N}"
  fi

  if [[ -n "${ROOT_DIR:-}" ]] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    local branch; branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local remote; remote=$(git -C "$ROOT_DIR" remote -v 2>/dev/null | head -1 | awk '{print $2}')
    echo -e "  ${I18N_DOCTOR_PROJECT_REPO}: ${C}${branch}${N} @ ${remote:-none}"
  fi
  echo ""

  # ── Harness config ───────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_CONFIG_SECTION}${N}"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "  ${G}✓${N} .harn_config:     ${I18N_DOCTOR_CONFIG_FOUND}  (${W}$CONFIG_FILE${N})"
    echo -e "  ${I18N_DOCTOR_GIT_INTEGRATION}:  ${W}${GIT_ENABLED:-false}${N}"
    echo -e "  ${I18N_DOCTOR_SPRINT_COUNT}:     ${W}${SPRINT_COUNT:-1}${N} (set per run at start)"
    echo -e "  ${I18N_DOCTOR_AI_BACKEND}:       ${W}${AI_BACKEND:-auto}${N}"
    echo -e "  Backend AI:        ${W}${AI_BACKEND_AUXILIARY:-${AI_BACKEND:-auto}}${N} / ${W}${MODEL_AUXILIARY:-auto}${N}"
  else
    echo -e "  ${D}○${N} .harn_config:     ${I18N_DOCTOR_CONFIG_NOT_FOUND}"
  fi

  if [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]]; then
    echo -e "  ${I18N_DOCTOR_CUSTOM_PROMPTS}:   ${W}${PROMPTS_DIR}${N}"
  fi
  echo ""

  # ── Models ───────────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_MODELS}${N}"
  echo -e "  Backend AI:          ${W}${MODEL_AUXILIARY:-auto}${N}"
  echo -e "  Planner:              ${W}${COPILOT_MODEL_PLANNER:-default}${N}"
  echo -e "  Generator (contract): ${W}${COPILOT_MODEL_GENERATOR_CONTRACT:-default}${N}"
  echo -e "  Generator (impl):     ${W}${COPILOT_MODEL_GENERATOR_IMPL:-default}${N}"
  echo -e "  Evaluator (contract): ${W}${COPILOT_MODEL_EVALUATOR_CONTRACT:-default}${N}"
  echo -e "  Evaluator (QA):       ${W}${COPILOT_MODEL_EVALUATOR_QA:-default}${N}"
  echo ""

  # ── Active run ───────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_ACTIVE_RUN}${N}"
  local run_id; run_id=$(current_run_id)
  if [[ -n "$run_id" ]]; then
    local run_dir="$HARN_DIR/runs/$run_id"
    local slug; slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || echo "unknown")
    local sprint_num; sprint_num=$(current_sprint_num "$run_dir")
    echo -e "  ${G}✓${N} Run:          ${W}${run_id}${N}  (${slug})"
    echo -e "  ${I18N_DOCTOR_SPRINT}:       ${W}${sprint_num}${N}"
  else
    echo -e "  ${I18N_DOCTOR_NO_RUN}"
  fi
  echo ""

  # ── Dependencies ─────────────────────────────────────────────────────────────
  echo -e "${W}▸ ${I18N_DOCTOR_DEPS}${N}"
  local all_ok=1
  for dep in python3 node; do
    if command -v "$dep" &>/dev/null; then
      local dver; dver=$($dep --version 2>/dev/null | head -1)
      echo -e "  ${G}✓${N} ${dep}:       ${C}${dver}${N}"
    else
      echo -e "  ${Y}?${N} ${dep}:       ${I18N_DOCTOR_NOT_FOUND} (${I18N_DOCTOR_OPTIONAL})"
      all_ok=0
    fi
  done
  echo ""

  if [[ $backend_ok -eq 1 ]]; then
    echo -e "${G}${I18N_DOCTOR_ALL_OK}${N}\n"
  else
    echo -e "${R}⚠ ${I18N_DOCTOR_FAIL_MSG}${N}\n"
  fi
}

cmd_auth() {
  local sub="${1:-status}"
  case "$sub" in
    status)
      echo -e "\n${W}▸ GitHub CLI auth status${N}"
      if command -v gh &>/dev/null; then
        gh auth status 2>&1 | while IFS= read -r line; do echo "  $line"; done
      else
        log_err "gh CLI not found. Install: https://cli.github.com"
      fi
      echo ""
      ;;
    login)
      echo -e "\n${W}GitHub CLI login${N}"
      if ! command -v gh &>/dev/null; then
        log_err "gh CLI not found. Install: brew install gh"
        return 1
      fi
      gh auth login
      ;;
    logout)
      echo -e "\n${W}GitHub CLI logout${N}"
      if ! command -v gh &>/dev/null; then
        log_err "gh CLI not found"
        return 1
      fi
      gh auth logout
      ;;
    token)
      # Show current token or refresh
      if ! command -v gh &>/dev/null; then
        log_err "gh CLI not found"
        return 1
      fi
      gh auth token
      ;;
    *)
      echo -e "Usage: ${W}harn auth${N} [status|login|logout|token]"
      echo -e "  ${W}status${N}   Show current GitHub authentication status"
      echo -e "  ${W}login${N}    Log in to GitHub via browser or token"
      echo -e "  ${W}logout${N}   Log out from GitHub"
      echo -e "  ${W}token${N}    Show the current auth token"
      ;;
  esac
}
