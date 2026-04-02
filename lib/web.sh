# lib/web.sh — Web server lifecycle: cmd_web, cmd_exit
# Sourced by harn.sh — do not execute directly

WEB_DEFAULT_PORT=4747

_web_pid_file() { echo "$HARN_DIR/web.pid"; }
_web_port_file() { echo "$HARN_DIR/web.port"; }

_web_find_free_port() {
  local port="$WEB_DEFAULT_PORT"
  while lsof -i ":$port" &>/dev/null 2>&1; do
    port=$(( port + 1 ))
    [[ $port -gt 5000 ]] && { log_err "No free port found in range"; return 1; }
  done
  echo "$port"
}

_web_is_running() {
  local pid_file
  pid_file=$(_web_pid_file)
  [[ ! -f "$pid_file" ]] && return 1
  local pid
  pid=$(cat "$pid_file" 2>/dev/null) || return 1
  [[ -z "$pid" ]] && return 1
  kill -0 "$pid" 2>/dev/null
}

_web_get_port() {
  local port_file
  port_file=$(_web_port_file)
  cat "$port_file" 2>/dev/null || echo "$WEB_DEFAULT_PORT"
}

_web_get_url() {
  echo "http://localhost:$(_web_get_port)"
}

_web_open_browser() {
  local url="$1"
  if command -v open &>/dev/null; then
    open "$url" &>/dev/null &
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url" &>/dev/null &
  fi
}

_web_wait_ready() {
  local url="$1"
  local tries=0
  while ! curl -sf "$url/api/health" &>/dev/null; do
    sleep 0.2
    tries=$(( tries + 1 ))
    [[ $tries -gt 30 ]] && return 1
  done
  return 0
}

cmd_web() {
  # Reconnect to existing session
  if _web_is_running; then
    local url
    url=$(_web_get_url)
    echo -e "\n  ${G}●${N} harn web already running at ${W}$url${N}"
    echo -e "  Opening browser...\n"
    _web_open_browser "$url"
    echo -e "  ${Y}harn exit${N}  — shut down the local session\n"
    return 0
  fi

  # Start new session
  local port
  port=$(_web_find_free_port) || return 1

  log_step "Refreshing model cache..."
  refresh_model_cache

  log_step "Starting harn web..."

  local pid_file port_file log_file
  pid_file=$(_web_pid_file)
  port_file=$(_web_port_file)
  log_file="$HARN_DIR/web.log"

  # Launch server as background daemon
  nohup python3 "$SCRIPT_DIR/server/harn_server.py" \
    --root "$ROOT_DIR" \
    --script-dir "$SCRIPT_DIR" \
    --port "$port" \
    > "$log_file" 2>&1 &

  local server_pid=$!
  echo "$server_pid" > "$pid_file"
  echo "$port" > "$port_file"

  local url="http://localhost:$port"

  if ! _web_wait_ready "$url"; then
    log_err "Web server failed to start (see $log_file)"
    rm -f "$pid_file" "$port_file"
    return 1
  fi

  echo -e "\n  ${G}●${N} harn web running at ${W}$url${N}"
  echo -e "  Opening browser...\n"
  _web_open_browser "$url"
  echo -e "  ${Y}harn exit${N}  — shut down the local session"
  echo -e "  Logs → $log_file\n"
}

cmd_exit() {
  if ! _web_is_running; then
    local pid_file
    pid_file=$(_web_pid_file)
    if [[ ! -f "$pid_file" ]]; then
      log_warn "No active harn web session found for this project."
    else
      log_warn "Session PID file found but process is not running. Cleaning up."
      rm -f "$(_web_pid_file)" "$(_web_port_file)"
    fi
    return 0
  fi

  local pid url
  pid=$(cat "$(_web_pid_file)" 2>/dev/null)
  url=$(_web_get_url)

  log_step "Shutting down harn web session..."

  # Ask server to stop gracefully (kills active subprocess too)
  curl -sf -X POST "$url/api/shutdown" &>/dev/null || true
  sleep 0.5

  # Kill process if still alive
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$(_web_pid_file)" "$(_web_port_file)"
  log_info "harn web session terminated."
}
