# lib/init.sh — Initialization wizard
# Sourced by harn.sh — do not execute directly

# ── Initialization wizard ──────────────────────────────────────────────────────

cmd_init() {
  # ── Language selection (first!) ────────────────────────────────────────────
  echo -e "\n${W}Language / 언어${N}"
  local _lang_choice
  _lang_choice=$(python3 - "" \
    "en:English" \
    "ko:한국어" \
    "" "" "" \
    <<'PYEOF'
import sys, os, tty, termios

options  = [a for a in sys.argv[2:] if a]  # filter empty sentinel args
labels   = [o.split(":",1)[1] for o in options]
values   = [o.split(":",1)[0] for o in options]
selected = 0
n = len(labels)

fd = open("/dev/tty", "rb+", buffering=0)
old = termios.tcgetattr(fd)
tty.setraw(fd)

def render():
    out = b""
    for i, lb in enumerate(labels):
        lb_enc = lb.encode()
        if i == selected:
            out += b"  \033[1;32m\xe2\x9d\xaf " + lb_enc + b"\033[0m\r\n"
        else:
            out += b"    \033[2m" + lb_enc + b"\033[0m\r\n"
    return out

try:
    fd.write(render())
    fd.write(f"\033[{n}A".encode())
    fd.flush()
    while True:
        fd.write(render())
        fd.write(f"\033[{n}A".encode())
        fd.flush()
        b = fd.read(1)
        if not b:
            break
        byte = b[0]
        if byte in (13, 10):  # Enter
            break
        elif byte == 3:  # Ctrl+C
            fd.write(f"\033[{n}B\r\n".encode())
            fd.flush()
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            fd.close()
            sys.exit(1)
        elif byte == 27:
            b2 = fd.read(1)
            if b2 == b"[":
                b3 = fd.read(1)
                if b3 == b"A":
                    selected = (selected - 1) % n
                elif b3 == b"B":
                    selected = (selected + 1) % n
finally:
    fd.write(f"\033[{n}B\r\n".encode())
    fd.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    fd.close()

print(values[selected])
PYEOF
  ) || { echo ""; return 0; }
  local selected_lang="${_lang_choice}"
  HARN_LANG="$selected_lang"
  _i18n_load
  # Update PROMPTS_DIR to match selected lang
  local _ldir="$SCRIPT_DIR/prompts/$HARN_LANG"
  [[ -d "$_ldir" ]] && PROMPTS_DIR="$_ldir" || PROMPTS_DIR="$SCRIPT_DIR/prompts/en"
  echo ""

  # ── Header (now in selected language) ─────────────────────────────────────
  echo -e "${W}══════════════════════════════════════════${N}"
  echo -e "${W}  ${I18N_INIT_TITLE}${N}"
  echo -e "${W}══════════════════════════════════════════${N}"
  echo -e "Project root: ${W}$ROOT_DIR${N}"
  echo -e "Config file:  ${W}$CONFIG_FILE${N}\n"

  if [[ -f "$CONFIG_FILE" ]]; then
    printf "${Y}${I18N_INIT_OVERWRITE}${N}"
    local ow; ow=$(_input_readline)
    echo ""
    [[ "$ow" == "y" || "$ow" == "Y" ]] || { log_info "$I18N_INIT_CANCELLED"; return 0; }
  fi

  # ── Project basic settings ───────────────────────────────────────────────────
  local bf_default="$I18N_INIT_BACKLOG_DEFAULT"
  printf "%s [%s]: " "$I18N_INIT_BACKLOG_PROMPT" "$bf_default"
  local bf_input; bf_input=$(_input_readline); echo ""
  local bf="${bf_input:-$bf_default}"

  printf "%s [5]: " "$I18N_INIT_MAX_QA_PROMPT"
  local mi_input; mi_input=$(_input_readline); echo ""
  local mi="${mi_input:-5}"

  # ── AI CLI detection ──────────────────────────────────────────────────────────
  _check_ai_cli_installed || return 1
  _select_ai_backend
  refresh_model_cache

  # ── AI model settings (per role) ──────────────────────────────────────────────
  echo -e "\n${W}${I18N_INIT_AI_MODELS}${N} — ${I18N_INIT_AI_MODELS_HINT}"
  echo -e "  ${D}${I18N_INIT_AI_MODELS_HINT}${N}\n"

  local max_aux_default
  max_aux_default=$(_get_models_for_backend "${AI_BACKEND:-copilot}" | head -1)
  local aux_model aux_backend _tmp_aux
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "  ${W}Backend AI${N}  ${D}— 사용자의 자연어 파악, 백로그 생성, 설정 추천, init 프롬프트 생성 같은 보조 작업${N}"
  else
    echo -e "  ${W}Backend AI${N}  ${D}— auxiliary tasks like natural-language parsing, backlog generation, config suggestion, and init prompt generation${N}"
  fi
  _tmp_aux=$(_pick_role_model "Backend AI" "${AI_BACKEND:-copilot}" "${max_aux_default:-claude-haiku-4.5}") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r aux_backend aux_model <<< "$_tmp_aux"

  local mp mp_backend _tmp_p
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Planner${N}  ${D}— 백로그 항목을 읽고 스펙과 스프린트 계획을 작성하는 역할${N}"
  else
    echo -e "\n  ${W}Planner${N}  ${D}— reads backlog item, writes product spec & sprint breakdown${N}"
  fi
  _tmp_p=$(_pick_role_model "Planner" "${AI_BACKEND:-copilot}" "claude-haiku-4.5") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mp_backend mp <<< "$_tmp_p"

  local mgc mgc_backend _tmp_gc
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Generator (contract)${N}  ${D}— 스프린트 스코프를 제안하고 코딩 전 Evaluator와 협상하는 역할${N}"
  else
    echo -e "\n  ${W}Generator (contract)${N}  ${D}— proposes sprint scope; negotiates with Evaluator before coding starts${N}"
  fi
  _tmp_gc=$(_pick_role_model "Generator (contract)" "${AI_BACKEND:-copilot}" "claude-sonnet-4.6") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mgc_backend mgc <<< "$_tmp_gc"

  local mgi mgi_backend _tmp_gi
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Generator (impl)${N}  ${D}— 실제 코드를 작성하는 역할; 가장 중요한 역할이므로 최고 성능 모델 추천${N}"
  else
    echo -e "\n  ${W}Generator (impl)${N}  ${D}— writes the actual code; most important role, use the strongest model${N}"
  fi
  _tmp_gi=$(_pick_role_model "Generator (impl)" "${AI_BACKEND:-copilot}" "claude-opus-4.6") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mgi_backend mgi <<< "$_tmp_gi"

  local mec mec_backend _tmp_ec
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Evaluator (contract)${N}  ${D}— 스프린트 스코프 제안을 검토하고 승인 또는 수정을 요청하는 역할${N}"
  else
    echo -e "\n  ${W}Evaluator (contract)${N}  ${D}— reviews sprint scope proposal, approves or requests revision${N}"
  fi
  _tmp_ec=$(_pick_role_model "Evaluator (contract)" "${AI_BACKEND:-copilot}" "claude-haiku-4.5") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r mec_backend mec <<< "$_tmp_ec"

  local meq meq_backend _tmp_eq
  if [[ "$HARN_LANG" == "ko" ]]; then
    echo -e "\n  ${W}Evaluator (QA)${N}  ${D}— 구현을 검토하고 테스트를 실행하여 PASS 또는 FAIL 판정을 내리는 역할${N}"
  else
    echo -e "\n  ${W}Evaluator (QA)${N}  ${D}— reviews implementation, runs tests, issues PASS or FAIL verdict${N}"
  fi
  _tmp_eq=$(_pick_role_model "Evaluator (QA)" "${AI_BACKEND:-copilot}" "claude-sonnet-4.5") \
    || { echo ""; log_info "$I18N_INIT_CANCELLED"; return 0; }
  read -r meq_backend meq <<< "$_tmp_eq"

  # ── Git integration ─────────────────────────────────────────────────────────────
  echo -e "\n${W}${I18N_INIT_GIT_SECTION}${N}"
  printf "%s" "$I18N_INIT_GIT_ENABLE_PROMPT"
  local git_yn; git_yn=$(_input_readline); echo ""
  local git_en="false"
  local git_guide=""

  if [[ "$git_yn" == "y" || "$git_yn" == "Y" ]]; then
    git_en="true"

    echo -e "\n${B}${I18N_INIT_GIT_GUIDE_TITLE}${N}"
    echo -e "  ${I18N_INIT_GIT_GUIDE_HINT}"
    printf "> "
    git_guide=$(_input_readline); echo ""
  fi

  # ── Per-agent special instructions ──────────────────────────────────────────
  echo -e "\n${W}${I18N_INIT_HINTS_TITLE}${N}"
  echo -e "  ${I18N_INIT_HINTS_HINT}\n"

  printf "%s" "$I18N_INIT_HINT_PLANNER"
  local hint_planner; hint_planner=$(_input_readline); echo ""

  printf "%s" "$I18N_INIT_HINT_GENERATOR"
  local hint_generator; hint_generator=$(_input_readline); echo ""

  printf "%s" "$I18N_INIT_HINT_EVALUATOR"
  local hint_evaluator; hint_evaluator=$(_input_readline); echo ""

  # ── Write config file ───────────────────────────────────────────────────────
  local cpd=""
  cat > "$CONFIG_FILE" <<CFGEOF
# harn config file — $(date '+%Y-%m-%d %H:%M:%S')
# project: $ROOT_DIR

# === Project settings ===
LANG_OVERRIDE="${selected_lang}"
BACKLOG_FILE="${bf}"
MAX_ITERATIONS=${mi}

# === AI backend ===
AI_BACKEND="${AI_BACKEND}"
AI_BACKEND_AUXILIARY="${aux_backend}"
AI_BACKEND_PLANNER="${mp_backend}"
AI_BACKEND_GENERATOR_CONTRACT="${mgc_backend}"
AI_BACKEND_GENERATOR_IMPL="${mgi_backend}"
AI_BACKEND_EVALUATOR_CONTRACT="${mec_backend}"
AI_BACKEND_EVALUATOR_QA="${meq_backend}"

# === AI model settings ===
MODEL_AUXILIARY="${aux_model}"
MODEL_PLANNER="${mp}"
MODEL_GENERATOR_CONTRACT="${mgc}"
MODEL_GENERATOR_IMPL="${mgi}"
MODEL_EVALUATOR_CONTRACT="${mec}"
MODEL_EVALUATOR_QA="${meq}"

# === Git integration ===
GIT_ENABLED="${git_en}"

# === Agent instructions (regenerate with harn init) ===
GIT_GUIDE="${git_guide}"
HINT_PLANNER="${hint_planner}"
HINT_GENERATOR="${hint_generator}"
HINT_EVALUATOR="${hint_evaluator}"

# === Custom prompts ===
CUSTOM_PROMPTS_DIR="${cpd}"
CFGEOF

  log_ok "${I18N_INIT_CONFIG_SAVED}: ${W}$CONFIG_FILE${N}"

  # ── Custom prompt generation ──────────────────────────────────────────────────
  if [[ -n "$hint_planner" || -n "$hint_generator" || -n "$hint_evaluator" || -n "$git_guide" ]]; then
    echo ""
    local ai_cmd; ai_cmd=$(_detect_ai_cli)
    if [[ -n "$ai_cmd" ]]; then
      log_info "${I18N_INIT_GEN_PROMPTS}(${W}${ai_cmd}${N})..."
    else
      log_warn "AI CLI not found — adding instructions directly to base prompts."
    fi
    _generate_custom_prompts "$hint_planner" "$hint_generator" "$hint_evaluator" "$git_guide"
    cpd=".harn/prompts"
    # Update CUSTOM_PROMPTS_DIR in config
    sed -i '' "s|^CUSTOM_PROMPTS_DIR=.*|CUSTOM_PROMPTS_DIR=\"${cpd}\"|" "$CONFIG_FILE"
  fi

  # Load the newly created config
  load_config

  echo ""
  log_ok "$I18N_INIT_COMPLETE"
  echo -e "$I18N_INIT_HINT_BACKLOG"
  echo -e "$I18N_INIT_HINT_START"
  echo ""
}
