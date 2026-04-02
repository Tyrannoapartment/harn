# lib/routing.sh — Intelligent model routing based on prompt analysis
# Sourced by harn.sh — do not execute directly

# Escalation keywords → upgrade model tier
_ROUTING_ESCALATION="critical|security|architecture|production|migration|breaking|vulnerability|performance|refactor|database"
# Simplification keywords → downgrade model tier
_ROUTING_SIMPLE="find|list|search|format|rename|typo|comment|docs|readme|changelog"

# Analyze prompt and optionally upgrade/downgrade the model
# Usage: model=$(_route_model "current-model" "prompt text" "role")
_route_model() {
  local current_model="$1" prompt_text="$2" role="${3:-}"

  # Disabled by config or env
  [[ "${MODEL_ROUTING:-true}" != "true" ]] && { echo "$current_model"; return; }

  # Sample first 2000 chars, lowercase
  local sample
  sample=$(printf '%s' "$prompt_text" | head -c 2000 | tr '[:upper:]' '[:lower:]')

  # Check escalation
  if echo "$sample" | grep -qiE "$_ROUTING_ESCALATION"; then
    local upgraded="$current_model"
    case "$current_model" in
      *haiku*)
        upgraded="${current_model/haiku/sonnet}"
        log_info "🔼 ${I18N_ROUTING_UPGRADED:-Model upgraded}: ${D}${current_model}${N} → ${W}${upgraded}${N}" >&2
        ;;
      *sonnet*)
        upgraded="${current_model/sonnet/opus}"
        log_info "🔼 ${I18N_ROUTING_UPGRADED:-Model upgraded}: ${D}${current_model}${N} → ${W}${upgraded}${N}" >&2
        ;;
      *) upgraded="$current_model" ;;
    esac
    echo "$upgraded"
    return
  fi

  # Check simplification
  if echo "$sample" | grep -qiE "^[[:space:]]*(${_ROUTING_SIMPLE})"; then
    local downgraded="$current_model"
    case "$current_model" in
      *opus*)
        downgraded="${current_model/opus/sonnet}"
        log_info "🔽 ${I18N_ROUTING_DOWNGRADED:-Model downgraded}: ${D}${current_model}${N} → ${W}${downgraded}${N}" >&2
        ;;
      *sonnet*)
        downgraded="${current_model/sonnet/haiku}"
        log_info "🔽 ${I18N_ROUTING_DOWNGRADED:-Model downgraded}: ${D}${current_model}${N} → ${W}${downgraded}${N}" >&2
        ;;
      *) downgraded="$current_model" ;;
    esac
    echo "$downgraded"
    return
  fi

  echo "$current_model"
}
