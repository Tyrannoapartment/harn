# lib/update.sh — Auto-update check (npm version compare)
# Sourced by harn.sh — do not execute directly

_UPDATE_CACHE_FILE="$HARN_DIR/.update-check"
_UPDATE_CACHE_TTL=86400  # 24 hours

_check_update() {
  # Skip if disabled or non-interactive
  [[ "${HARN_NO_UPDATE_CHECK:-}" == "true" ]] && return 0
  [[ ! -t 1 ]] && return 0

  # Check cache
  if [[ -f "$_UPDATE_CACHE_FILE" ]]; then
    local cached_time
    cached_time=$(head -1 "$_UPDATE_CACHE_FILE" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    if [[ $(( now - cached_time )) -lt $_UPDATE_CACHE_TTL ]]; then
      local cached_ver
      cached_ver=$(tail -1 "$_UPDATE_CACHE_FILE" 2>/dev/null || echo "")
      if [[ -n "$cached_ver" ]] && _version_gt "$cached_ver" "$HARN_VERSION"; then
        _show_update_notice "$cached_ver"
      fi
      return 0
    fi
  fi

  # Background async check (don't block startup)
  (
    local latest
    latest=$(npm view @tyrannoapartment/harn version 2>/dev/null || echo "")
    if [[ -n "$latest" ]]; then
      mkdir -p "$(dirname "$_UPDATE_CACHE_FILE")"
      printf '%s\n%s\n' "$(date +%s)" "$latest" > "$_UPDATE_CACHE_FILE"
    fi
  ) &
  disown 2>/dev/null || true
}

# Compare semver: returns 0 (true) if $1 > $2
_version_gt() {
  local v1="$1" v2="$2"
  [[ "$v1" == "$v2" ]] && return 1
  local IFS=.
  local i a=($v1) b=($v2)
  for ((i=0; i<3; i++)); do
    local x="${a[$i]:-0}" y="${b[$i]:-0}"
    [[ "$x" -gt "$y" ]] && return 0
    [[ "$x" -lt "$y" ]] && return 1
  done
  return 1
}

_show_update_notice() {
  local latest="$1"
  echo -e "  ${Y}⚡${N} ${I18N_UPDATE_AVAILABLE:-Update available}: ${W}${HARN_VERSION}${N} → ${G}${latest}${N}"
  echo -e "     ${D}npm update -g @tyrannoapartment/harn${N}"
  echo ""
}
