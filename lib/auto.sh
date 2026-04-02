# lib/auto.sh — Auto/all modes, status, config, runs
# Sourced by harn.sh — do not execute directly

# ── Auto mode ──────────────────────────────────────────────────────────────────

cmd_auto() {
  log_step "$I18N_AUTO_STEP"
  _HARN_AUTO_SPRINTS=1

  local run_id run_dir
  run_id=$(current_run_id)

  # 1. Resume in-progress run if present
  if [[ -n "$run_id" ]]; then
    run_dir="$HARN_DIR/runs/$run_id"
    if [[ ! -f "$run_dir/completed" ]]; then
      local sprint_num sprint cur_status
      sprint_num=$(current_sprint_num "$run_dir")
      sprint="$run_dir/sprints/$(printf '%03d' "$sprint_num")"
      cur_status=$(sprint_status "$sprint" 2>/dev/null || echo "pending")

      if [[ "$cur_status" != "cancelled" ]]; then
        log_info "$(printf "$I18N_AUTO_RESUMING" "$run_id" "$sprint_num" "$cur_status")"
        _run_sprint_loop 10
        return 0
      else
        log_info "$I18N_AUTO_CANCELLED"
      fi
    else
      log_info "$(printf "$I18N_AUTO_COMPLETED" "$run_id")"
    fi
  fi

  # 2. Start next pending backlog item if available
  local next_slug
  next_slug=$(backlog_next_slug)

  if [[ -n "$next_slug" ]]; then
    log_info "$(printf "$I18N_AUTO_STARTING" "$next_slug")"
    rm -f "$HARN_DIR/current"   # reset previous run pointer
    cmd_start "$next_slug"
    return 0
  fi

  # 3. Backlog empty → analyze codebase and add new items
  log_warn "$I18N_AUTO_EMPTY"
  cmd_discover

  # If discovery produced new items, start immediately
  next_slug=$(backlog_next_slug)
  if [[ -n "$next_slug" ]]; then
    log_info "$(printf "$I18N_AUTO_FIRST_DISCOVERED" "$next_slug")"
    rm -f "$HARN_DIR/current"
    cmd_start "$next_slug"
  fi
}

cmd_all() {
  _HARN_AUTO_SPRINTS=1

  if [[ ! -f "$BACKLOG_FILE" ]]; then
    log_err "$I18N_ALL_NO_BACKLOG $BACKLOG_FILE"
    exit 1
  fi

  local slugs
  slugs=$(backlog_pending_slugs)

  if [[ -z "$slugs" ]]; then
    log_warn "$I18N_ALL_NO_PENDING"
    log_info "$I18N_ALL_HINT"
    return 0
  fi

  local slug_array=()
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && slug_array+=("$slug")
  done <<< "$slugs"

  local total_items="${#slug_array[@]}"
  log_step "$I18N_ALL_STEP ${W}${total_items}${N} item(s)"
  echo ""
  local i=1
  for slug in "${slug_array[@]}"; do
    echo -e "  ${D}$i.${N} ${Y}$slug${N}"
    i=$(( i + 1 ))
  done
  echo ""

  # Suppress per-item retrospective — run all at end
  HARN_SKIP_RETRO="true"

  local completed_run_dirs=()
  local failed_slugs=()
  local item_num=0

  for slug in "${slug_array[@]}"; do
    item_num=$(( item_num + 1 ))
    log_step "$(printf "$I18N_ALL_STARTING" "$item_num" "$total_items" "$slug")"
    _print_batch_progress "$item_num" "$total_items" "$slug"

    # Reset run pointer (so cmd_start creates a new run)
    rm -f "$HARN_DIR/current"

    if cmd_start "$slug"; then
      # Record just-completed run directory
      local finished_run
      finished_run=$(ls -dt "$HARN_DIR/runs/"*/ 2>/dev/null | head -1)
      finished_run="${finished_run%/}"
      [[ -n "$finished_run" ]] && completed_run_dirs+=("$finished_run")
      log_ok "$(printf "$I18N_ALL_COMPLETE_ITEM" "$item_num" "$total_items" "$slug")"
    else
      log_err "$(printf "$I18N_ALL_FAILED_ITEM" "$item_num" "$total_items" "$slug")"
      failed_slugs+=("$slug")
    fi
    echo ""
  done

  HARN_SKIP_RETRO="false"

  # ── Completion banner ────────────────────────────────────────────────────────
  local done_count="${#completed_run_dirs[@]}"
  local fail_count="${#failed_slugs[@]}"

  _log_raw ""
  _log_raw "${G}  ╔══════════════════════════════════════════════════════════╗${N}"
  _log_raw "${G}  ║  ✓  All ${total_items} item(s) processed   (success: ${done_count}  failed: ${fail_count})${N}"
  _log_raw "${G}  ╚══════════════════════════════════════════════════════════╝${N}"

  if [[ $fail_count -gt 0 ]]; then
    log_warn "$I18N_ALL_FAILED_ITEMS ${failed_slugs[*]}"
    log_info "$I18N_ALL_RETRY_HINT"
  fi

  # ── Retrospective: run sequentially for all completed items ─────────────────
  if [[ $done_count -gt 0 ]]; then
    log_step "$(printf "$I18N_ALL_RETRO_STEP" "$done_count")"
    for run_dir in "${completed_run_dirs[@]}"; do
      local item_slug
      item_slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || basename "$run_dir")
      log_info "$(printf "$I18N_ALL_RETRO_ITEM" "$item_slug")"
      cmd_retrospective "$run_dir" || true
    done
  fi
}

cmd_status() {
  local run_id run_dir sprint_num
  run_id=$(current_run_id)
  if [[ -z "$run_id" ]]; then
    log_warn "$I18N_STATUS_NO_RUN"
    return 0
  fi
  run_dir="$HARN_DIR/runs/$run_id"
  sprint_num=$(current_sprint_num "$run_dir")

  echo -e "${W}$I18N_STATUS_RUN_ID${N}    $run_id"
  echo -e "${W}$I18N_STATUS_ITEM${N}      $(cat "$run_dir/prompt.txt" 2>/dev/null || echo "(unknown)")"
  echo -e "${W}$I18N_STATUS_SPRINT${N} $sprint_num"

  echo ""
  echo -e "${W}$I18N_STATUS_SPRINTS${N}"
  local any=0
  for s in "$run_dir/sprints"/*/; do
    [[ -d "$s" ]] || continue
    any=1
    local sn status iter icon
    sn=$(basename "$s"); status=$(sprint_status "$s"); iter=$(sprint_iteration "$s")
    icon="⏳"
    [[ "$status" == "pass" ]]        && icon="${G}✓${N}"
    [[ "$status" == "fail" ]]        && icon="${R}✗${N}"
    [[ "$status" == "in-progress" ]] && icon="${Y}↻${N}"
    [[ "$status" == "cancelled" ]]   && icon="${R}⊘${N}"

    local status_label="pending"
    [[ "$status" == "pass" ]]        && status_label="passed"
    [[ "$status" == "fail" ]]        && status_label="failed"
    [[ "$status" == "in-progress" ]] && status_label="in-progress"
    [[ "$status" == "cancelled" ]]   && status_label="cancelled"

    echo -e "  Sprint $sn  $icon $status_label  (iterations: $iter)"
  done
  [[ $any -eq 0 ]] && echo "  $I18N_STATUS_NO_SPRINTS"
}

cmd_config() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      echo -e "${W}$I18N_CONFIG_TITLE${N}  (${CONFIG_FILE})"
      echo -e "${I18N_CONFIG_PROJECT}${W}$ROOT_DIR${N}"
      echo -e "${I18N_CONFIG_LANGUAGE}${W}$HARN_LANG${N}  ($I18N_LANG_NAME)"
      echo -e "${I18N_CONFIG_BACKLOG_KEY}${W}$BACKLOG_FILE${N}"
      echo -e "${I18N_CONFIG_MAX_RETRIES_KEY}${W}$MAX_ITERATIONS${N}"
      echo -e "${I18N_CONFIG_GIT_KEY}${W}$GIT_ENABLED${N}"
      echo ""
      echo -e "${W}$I18N_CONFIG_AI_MODELS${N}"
      echo -e "  Planner:           ${W}$COPILOT_MODEL_PLANNER${N}"
      echo -e "  Generator (contract): ${W}$COPILOT_MODEL_GENERATOR_CONTRACT${N}"
      echo -e "  Generator (impl):  ${W}$COPILOT_MODEL_GENERATOR_IMPL${N}"
      echo -e "  Evaluator (contract): ${W}$COPILOT_MODEL_EVALUATOR_CONTRACT${N}"
      echo -e "  Evaluator (QA):    ${W}$COPILOT_MODEL_EVALUATOR_QA${N}"
      [[ -n "${CUSTOM_PROMPTS_DIR:-}" ]] && echo -e "\n${I18N_CONFIG_CUSTOM_PROMPTS_KEY}${W}$PROMPTS_DIR${N}"
      ;;
    set)
      local key="${2:-}" val="${3:-}"
      [[ -z "$key" || -z "$val" ]] && { log_err "$I18N_CONFIG_SET_USAGE"; exit 1; }
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "$I18N_CONFIG_NO_FILE"
        exit 1
      fi
      # LANG → write as LANG_OVERRIDE
      local cfg_key="$key"
      [[ "$key" == "LANG" ]] && cfg_key="LANG_OVERRIDE"
      if grep -q "^${cfg_key}=" "$CONFIG_FILE"; then
        sed -i '' "s|^${cfg_key}=.*|${cfg_key}=\"${val}\"|" "$CONFIG_FILE"
      else
        echo "${cfg_key}=\"${val}\"" >> "$CONFIG_FILE"
      fi
      log_ok "${W}${cfg_key}${N} = \"${val}\" set"
      ;;
    regen)
      if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "$I18N_CONFIG_SET_FILE_NOT_FOUND"
        exit 1
      fi
      local ai_cmd; ai_cmd=$(_detect_ai_cli)
      if [[ -z "$ai_cmd" ]]; then
        log_err "$I18N_CONFIG_NO_CLI"
        exit 1
      fi
      local hp="${HINT_PLANNER:-}" hg="${HINT_GENERATOR:-}" he="${HINT_EVALUATOR:-}" gg="${GIT_GUIDE:-}"
      if [[ -z "$hp" && -z "$hg" && -z "$he" && -z "$gg" ]]; then
        log_warn "$I18N_CONFIG_NO_HINTS"
        log_info "$I18N_CONFIG_HINT_HOW"
        exit 0
      fi
      log_step "$I18N_CONFIG_REGEN_STEP"
      log_info "$(printf "$I18N_CONFIG_REGEN_INFO" "$ai_cmd")"
      _generate_custom_prompts "$hp" "$hg" "$he" "$gg"
      local cpd=".harn/prompts"
      if ! grep -q "^CUSTOM_PROMPTS_DIR=" "$CONFIG_FILE"; then
        echo "CUSTOM_PROMPTS_DIR=\"${cpd}\"" >> "$CONFIG_FILE"
      else
        sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
      fi
      load_config
      log_ok "$(printf "$I18N_CONFIG_REGEN_DONE" "$PROMPTS_DIR")"
      ;;
    *)
      log_err "$I18N_CONFIG_UNKNOWN_SUB $sub"
      echo -e "$I18N_CONFIG_USAGE"
      exit 1
      ;;
  esac
}

cmd_model() {
  local ROLES=(
    "Planner"
    "Generator (contract)"
    "Generator (impl)"
    "Evaluator (contract)"
    "Evaluator (QA)"
  )
  local MODEL_KEYS=(
    "MODEL_PLANNER"
    "MODEL_GENERATOR_CONTRACT"
    "MODEL_GENERATOR_IMPL"
    "MODEL_EVALUATOR_CONTRACT"
    "MODEL_EVALUATOR_QA"
  )
  local BACKEND_KEYS=(
    "AI_BACKEND_PLANNER"
    "AI_BACKEND_GENERATOR_CONTRACT"
    "AI_BACKEND_GENERATOR_IMPL"
    "AI_BACKEND_EVALUATOR_CONTRACT"
    "AI_BACKEND_EVALUATOR_QA"
  )
  local CURRENT_MODELS=(
    "$COPILOT_MODEL_PLANNER"
    "$COPILOT_MODEL_GENERATOR_CONTRACT"
    "$COPILOT_MODEL_GENERATOR_IMPL"
    "$COPILOT_MODEL_EVALUATOR_CONTRACT"
    "$COPILOT_MODEL_EVALUATOR_QA"
  )
  local CURRENT_BACKENDS=(
    "${AI_BACKEND_PLANNER:-${AI_BACKEND:-copilot}}"
    "${AI_BACKEND_GENERATOR_CONTRACT:-${AI_BACKEND:-copilot}}"
    "${AI_BACKEND_GENERATOR_IMPL:-${AI_BACKEND:-copilot}}"
    "${AI_BACKEND_EVALUATOR_CONTRACT:-${AI_BACKEND:-copilot}}"
    "${AI_BACKEND_EVALUATOR_QA:-${AI_BACKEND:-copilot}}"
  )

  echo ""
  echo -e "  ${W}AI 모델 설정${N}"
  echo ""
  echo -e "  Planner:              ${D}${CURRENT_BACKENDS[0]} / ${CURRENT_MODELS[0]}${N}"
  echo -e "  Generator (contract): ${D}${CURRENT_BACKENDS[1]} / ${CURRENT_MODELS[1]}${N}"
  echo -e "  Generator (impl):     ${D}${CURRENT_BACKENDS[2]} / ${CURRENT_MODELS[2]}${N}"
  echo -e "  Evaluator (contract): ${D}${CURRENT_BACKENDS[3]} / ${CURRENT_MODELS[3]}${N}"
  echo -e "  Evaluator (QA):       ${D}${CURRENT_BACKENDS[4]} / ${CURRENT_MODELS[4]}${N}"
  echo ""

  local role_choice
  role_choice=$(_pick_menu "어떤 역할의 모델을 수정할까요?" 0 "${ROLES[@]}") || return 0

  local ri=0
  for i in "${!ROLES[@]}"; do
    [[ "${ROLES[$i]}" == "$role_choice" ]] && { ri=$i; break; }
  done

  local picked current_backend current_model
  current_backend="${CURRENT_BACKENDS[$ri]}"
  current_model="${CURRENT_MODELS[$ri]}"
  if [[ ! -f "$MODEL_CACHE_DIR/${current_backend}.txt" ]]; then
    refresh_model_cache
  fi
  picked=$(_pick_role_model "$role_choice" "$current_backend" "$current_model") || return 0

  local new_backend new_model
  read -r new_backend new_model <<< "$picked"

  cmd_config set "${BACKEND_KEYS[$ri]}" "$new_backend"
  cmd_config set "${MODEL_KEYS[$ri]}" "$new_model"
  load_config

  log_ok "${role_choice} → ${W}${new_backend}${N} / ${W}${new_model}${N}"
}

cmd_runs() {
  local current_id; current_id=$(current_run_id)
  for d in "$HARN_DIR/runs"/*/; do
    [[ -d "$d" ]] || continue
    local id prompt marker
    id=$(basename "$d")
    prompt=$(head -c 70 "$d/prompt.txt" 2>/dev/null || echo "(no prompt)")
    marker=""; [[ "$id" == "$current_id" ]] && marker=" ${G}← current${N}"
    echo -e "  ${W}$id${N}: $prompt$marker"
  done
}

cmd_resume() {
  local run_id="${1:-}"
  [[ -z "$run_id" ]] && { log_err "$I18N_RESUME_USAGE"; exit 1; }
  local run_dir="$HARN_DIR/runs/$run_id"
  [[ ! -d "$run_dir" ]] && { log_err "$I18N_RESUME_NOT_FOUND $run_id"; exit 1; }
  ln -sfn "$run_dir" "$HARN_DIR/current"
  log_ok "$I18N_RESUME_OK $run_id"
  cmd_status
}

cmd_tail() {
  local log="$HARN_DIR/current.log"

  # current.log symlink missing or broken → fall back to most recent run log
  if [[ ! -e "$log" ]]; then
    local latest_log
    latest_log=$(ls -t "$HARN_DIR/runs"/*/run.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]]; then
      log_warn "$I18N_TAIL_FALLBACK $latest_log"
      ln -sfn "$latest_log" "$HARN_DIR/current.log"
      log="$latest_log"
    else
      log_err "$I18N_TAIL_NO_LOG"
      exit 1
    fi
  fi

  echo -e "${W}$I18N_TAIL_TAILING${N} $log  ${B}(Ctrl-C to stop)${N}"
  tail -f "$log"
}

usage() {
  _print_banner
  cat <<EOF
  ${W}${I18N_USAGE_TITLE}${N}  harn ${D}<command> [options]${N}

  ${C}${I18N_USAGE_SETUP}${N}
    ${W}init${N}                  ${D}${I18N_USAGE_INIT}${N}
    ${W}config${N}                ${D}${I18N_USAGE_CONFIG}${N}
    ${W}config set${N} KEY VALUE  ${D}${I18N_USAGE_CONFIG_SET}${N}
    ${W}config regen${N}          ${D}${I18N_USAGE_CONFIG_REGEN}${N}

  ${C}${I18N_USAGE_BACKLOG}${N}
    ${W}backlog${N}               ${D}${I18N_USAGE_BACKLOG_CMD}${N}
    ${W}add${N}                   ${D}${I18N_USAGE_ADD}${N}
    ${W}discover${N}              ${D}${I18N_USAGE_DISCOVER}${N}

  ${C}${I18N_USAGE_RUN}${N}
    ${W}start${N}                 ${D}${I18N_USAGE_START}${N}
    ${W}auto${N}                  ${D}${I18N_USAGE_AUTO}${N}
    ${W}all${N}                   ${D}${I18N_USAGE_ALL}${N}

  ${C}${I18N_USAGE_STEPS}${N}
    ${W}plan${N}                  ${D}${I18N_USAGE_PLAN}${N}
    ${W}contract${N}              ${D}${I18N_USAGE_CONTRACT}${N}
    ${W}implement${N}             ${D}${I18N_USAGE_IMPLEMENT}${N}
    ${W}evaluate${N}              ${D}${I18N_USAGE_EVALUATE}${N}
    ${W}next${N}                  ${D}${I18N_USAGE_NEXT}${N}

  ${C}${I18N_USAGE_MONITOR}${N}
    ${W}status${N}                ${D}${I18N_USAGE_STATUS}${N}
    ${W}tail${N}                  ${D}${I18N_USAGE_TAIL}${N}
    ${W}runs${N}                  ${D}${I18N_USAGE_RUNS}${N}
    ${W}resume${N} <id>           ${D}${I18N_USAGE_RESUME}${N}
    ${W}stop${N}                  ${D}${I18N_USAGE_STOP}${N}

  ${C}${I18N_USAGE_SMART:-Smart}${N}
    ${W}do${N} "<request>"        ${D}${I18N_USAGE_DO:-Natural language command (AI routes to action)}${N}
    ${W}team${N} [N] <task>       ${D}${I18N_USAGE_TEAM:-Parallel agents via tmux (N = agent count)}${N}

  ${D}Tip: ${I18N_USAGE_TIP}${N}
  ${D}    HARN_MODEL_GENERATOR_IMPL=claude-sonnet-4.6 harn start${N}

EOF
}

# Welcome screen — shown when `harn` is run with no arguments
_welcome_header() {
  _print_banner

  local has_config="false"
  [[ -f "$CONFIG_FILE" ]] && has_config="true"

  echo -e "  ${D}$(pwd)${N}"
  echo ""

  if [[ "$has_config" == "true" ]]; then
    local backend
    backend=$(_detect_ai_cli 2>/dev/null || echo "")
    [[ -n "$backend" ]] && echo -e "  ${G}●${N} ${D}AI:${N} ${W}${backend}${N}" \
                        || echo -e "  ${R}●${N} ${D}AI:${N} ${D}not configured${N}"

    local run_id
    run_id=$(current_run_id 2>/dev/null || echo "")
    if [[ -n "$run_id" ]]; then
      local run_dir="$HARN_DIR/runs/$run_id"
      local slug; slug=$(cat "$run_dir/prompt.txt" 2>/dev/null || echo "?")
      local sprint_num; sprint_num=$(current_sprint_num "$run_dir" 2>/dev/null || echo "1")
      local sprint; sprint=$(sprint_dir "$run_dir" "$sprint_num" 2>/dev/null || echo "")
      local cur_status="pending"
      [[ -n "$sprint" ]] && cur_status=$(sprint_status "$sprint" 2>/dev/null || echo "pending")
      local status_icon="${Y}↻${N}"
      case "$cur_status" in
        pass) status_icon="${G}✓${N}" ;; fail) status_icon="${R}✗${N}" ;;
      esac
      echo -e "  ${status_icon} ${D}Run:${N} ${W}${slug}${N}  ${D}sprint ${sprint_num} · ${cur_status}${N}"
    else
      echo -e "  ${D}○ No active run${N}"
    fi

    if [[ -f "$BACKLOG_FILE" ]]; then
      local pending_count=0 in_progress_count=0 done_count=0
      pending_count=$(grep -c '^\- \[ \] \*\*' "$BACKLOG_FILE" 2>/dev/null || true)
      in_progress_count=$(awk '/^## In Progress/,/^## /' "$BACKLOG_FILE" 2>/dev/null | grep -c '^\- \[' || true)
      done_count=$(awk '/^## Done/,/^## /' "$BACKLOG_FILE" 2>/dev/null | grep -c '^\- \[' || true)
      echo -e "  ${D}◇ Backlog:${N} ${W}${pending_count}${N} ${D}pending${N}  ${Y}${in_progress_count}${N} ${D}active${N}  ${G}${done_count}${N} ${D}done${N}"
    fi
    echo ""
  else
    echo -e "  ${Y}⚠${N}  ${D}Not initialized. Run${N} ${W}/init${N} ${D}to get started.${N}"
    echo ""
  fi
}
_repl_slash_help() {
  echo ""
  echo -e "  ${W}┌─ harn 명령어 ──────────────────────────────────┐${N}"
  echo ""

  echo -e "  ${C}🚀 실행${N}"
  echo -e "    ${W}/auto${N}              ${D}자동 감지: 재개/시작/발굴${N}"
  echo -e "    ${W}/all${N}               ${D}대기 항목 전부 순차 실행${N}"
  echo -e "    ${W}/start${N} [slug]      ${D}특정 백로그 항목 시작${N}"
  echo -e "    ${W}/stop${N}              ${D}실행 루프 중단${N}"
  echo ""

  echo -e "  ${C}📋 백로그${N}"
  echo -e "    ${W}/backlog${N}           ${D}백로그 목록 보기${N}"
  echo -e "    ${W}/add${N}               ${D}새 항목 추가 (대화형)${N}"
  echo -e "    ${W}/discover${N}          ${D}코드베이스 분석 후 작업 발굴${N}"
  echo ""

  echo -e "  ${C}🔍 모니터링${N}"
  echo -e "    ${W}/status${N}            ${D}현재 실행 상태 요약${N}"
  echo -e "    ${W}/runs${N}              ${D}전체 실행 목록${N}"
  echo ""

  echo -e "  ${C}⚙️  단계별 실행${N}"
  echo -e "    ${W}/plan${N}              ${D}플래너 재실행${N}"
  echo -e "    ${W}/implement${N}         ${D}제너레이터 실행${N}"
  echo -e "    ${W}/evaluate${N}          ${D}이밸류에이터 실행${N}"
  echo -e "    ${W}/next${N}              ${D}다음 스프린트로 이동${N}"
  echo ""

  echo -e "  ${C}🛠  설정 & 환경${N}"
  echo -e "    ${W}/config${N} [set K V]  ${D}설정 보기 / 변경${N}"
  echo -e "    ${W}/init${N}              ${D}초기 설정 (재설정 포함)${N}"
  echo -e "    ${W}/doctor${N}            ${D}환경 진단${N}"
  echo ""

  echo -e "  ${C}🤖 스마트${N}"
  echo -e "    ${W}/team${N} [N] <task>   ${D}N개 병렬 에이전트 실행${N}"
  echo ""

  echo -e "  ${C}❓ 기타${N}"
  echo -e "    ${W}/help${N}              ${D}이 도움말 보기${N}"
  echo -e "    ${W}/exit${N}              ${D}종료${N}"
  echo ""

  echo -e "  ${D}┈┈ 또는 자연어로 입력하세요 ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈${N}"
  echo -e "  ${D}  \"JWT 로그인 기능 만들어줘\"${N}"
  echo -e "  ${D}  \"generator 모델 sonnet으로 바꿔줘\"${N}"
  echo -e "  ${D}  \"가장 우선순위 높은 작업 진행해줘\"${N}"
  echo ""
}

# Interactive REPL — full-screen TUI entry point when `harn` is run with no args
# Uses alternate screen buffer so original terminal is restored on exit.
# Layout:
#   rows 1..(rows-2) — scroll region (banner + command output)
#   row (rows-1)     — separator with hint text
#   row (rows)       — input prompt (fixed at absolute bottom)
_welcome() {
  # Non-interactive environments (stdout piped/redirected): just print header and exit
  if [[ ! -t 1 ]]; then
    _welcome_header
    return 0
  fi

  # Get terminal size BEFORE entering alternate screen
  local _tui_rows _tui_cols
  _tui_rows=$(stty size </dev/tty 2>/dev/null | awk '{print $1}')
  _tui_cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
  [[ -z "$_tui_rows" || "$_tui_rows" -lt 10 ]] && _tui_rows=24
  [[ -z "$_tui_cols" || "$_tui_cols" -lt 20 ]] && _tui_cols=80
  local _input_row=$_tui_rows
  local _sep_row=$(( _tui_rows - 1 ))
  local _scroll_end=$(( _tui_rows - 2 ))

  # Enter alternate screen buffer
  printf '\033[?1049h' >/dev/tty
  printf '\033[2J\033[H' >/dev/tty

  # Draw banner & project info (all output to /dev/tty to stay in alt screen)
  _welcome_header >/dev/tty

  # Draw chrome (separator with hint)
  _tui_draw_chrome() {
    printf '\033[%d;1H\033[2K' "$_sep_row" >/dev/tty
    printf '  \033[2m── 자연어 입력 또는 /명령어  ·  /help 도움말  ·  Ctrl+C 종료 ' >/dev/tty
    local _pad=$(( _tui_cols - 58 ))
    [[ $_pad -gt 0 ]] && printf '─%.0s' $(seq 1 $_pad) >/dev/tty
    printf '\033[0m' >/dev/tty
    # Clear input row
    printf '\033[%d;1H\033[2K' "$_input_row" >/dev/tty
  }
  _tui_draw_chrome

  # Set scroll region: content area only (rows 1 to rows-2)
  printf '\033[1;%dr' "$_scroll_end" >/dev/tty
  # Position cursor inside scroll region for future command output
  printf '\033[%d;1H' "$_scroll_end" >/dev/tty

  # Cleanup function — restore terminal on exit
  _tui_cleanup() {
    printf '\033[r' >/dev/tty 2>/dev/null || true
    printf '\033[?1049l' >/dev/tty 2>/dev/null || true
  }
  trap '_tui_cleanup; _harn_on_exit' EXIT

  # ── Slash-command dispatch ─────────────────────────────────────────────────
  _repl_dispatch_slash() {
    local input="$1"
    local slash_cmd="${input#/}"
    local cmd="${slash_cmd%% *}"
    local args="${slash_cmd#* }"
    [[ "$args" == "$cmd" ]] && args=""

    # Temporarily reset scroll region so command output uses full content area
    printf '\033[1;%dr' "$_scroll_end" >/dev/tty
    printf '\033[%d;1H' "$_scroll_end" >/dev/tty

    case "$cmd" in
      help|h|"?")  _repl_slash_help >/dev/tty ;;
      auto)        cmd_auto ;;
      all)         cmd_all ;;
      start)       cmd_start $args ;;
      backlog|bl)  cmd_backlog >/dev/tty ;;
      add)         cmd_add ;;
      discover)    cmd_discover ;;
      status|st)   cmd_status >/dev/tty ;;
      stop)        cmd_stop ;;
      plan)        cmd_plan ;;
      implement)   cmd_implement ;;
      evaluate)    cmd_evaluate ;;
      next)        cmd_next ;;
      config)      cmd_config ${args:-show} >/dev/tty ;;
      model)       cmd_model ;;
      doctor)      cmd_doctor >/dev/tty ;;
      init)        cmd_init ;;
      runs)        cmd_runs >/dev/tty ;;
      team)        cmd_team $args ;;
      exit|quit|q) return 99 ;;
      *)           echo -e "  ${R}✗${N}  Unknown: /${cmd}  (/help)" >/dev/tty ;;
    esac

    # Redraw chrome after command (may have been overwritten)
    _tui_draw_chrome
  }

  # ── REPL loop ──────────────────────────────────────────────────────────────
  local _repl_running=true
  trap '_repl_running=false; _tui_cleanup' INT

  export HARN_TUI_INPUT_ROW=$_input_row

  while $_repl_running; do
    local line
    line=$(_input_repl_line 2>/dev/null) || { break; }

    # Trim whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" == /* ]]; then
      local _rc=0
      set +e
      _repl_dispatch_slash "$line"
      _rc=$?
      set -e
      [[ $_rc -eq 99 ]] && break
    else
      local _rc2=0
      printf '\033[1;%dr' "$_scroll_end" >/dev/tty
      printf '\033[%d;1H' "$_scroll_end" >/dev/tty
      set +e
      cmd_do "$line"
      _rc2=$?
      set -e
      _tui_draw_chrome
    fi
  done

  unset HARN_TUI_INPUT_ROW
  trap - INT
  _tui_cleanup
  trap '_harn_on_exit' EXIT
  echo -e "  ${D}bye${N}"
}
