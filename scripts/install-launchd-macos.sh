#!/bin/zsh
set -euo pipefail

BRIDGE_LABEL="com.whatsapp-mcp.bridge"
MONITOR_LABEL="com.whatsapp-mcp.bridge-monitor"
TRANSCRIBE_LABEL="com.whatsapp-mcp.transcribe-backlog"
CLEANUP_LABEL="com.whatsapp-mcp.media-cleanup"

# Transcription backlog: how far back to look and how many voice notes to
# transcribe per run. Override by exporting these before running the installer.
TRANSCRIBE_HOURS="${WHATSAPP_MCP_TRANSCRIBE_HOURS:-36}"
TRANSCRIBE_LIMIT="${WHATSAPP_MCP_TRANSCRIBE_LIMIT:-60}"
TRANSCRIBE_INTERVAL="${WHATSAPP_MCP_TRANSCRIBE_INTERVAL:-7200}"
CLEANUP_INTERVAL="${WHATSAPP_MCP_CLEANUP_INTERVAL:-259200}"

fail() {
  print -r -- "Error: $1" >&2
  exit 1
}

require_macos_user() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "launchd installation is only supported on macOS."
  [[ "${EUID:-$(id -u)}" != "0" ]] || fail "Do not run this installer with sudo; it installs per-user LaunchAgents."
}

shell_quote() {
  local value="$1"
  printf "'"
  printf "%s" "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

xml_escape() {
  printf "%s" "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_export() {
  local name="$1"
  local value="$2"
  printf "export %s=%s\n" "$name" "$(shell_quote "$value")" >> "$ENV_FILE"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ '^[0-9]+$' ]] || fail "WHATSAPP_BRIDGE_PORT must be a number, got: $port"
  (( port >= 1 && port <= 65535 )) || fail "WHATSAPP_BRIDGE_PORT must be between 1 and 65535, got: $port"
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ '^[0-9]+$' ]] || fail "$name must be a non-negative integer, got: $value"
  (( value > 0 )) || fail "$name must be greater than 0, got: $value"
}

bootout_label() {
  local domain="$1"
  local label="$2"
  launchctl bootout "$domain/$label" 2>/dev/null || true
}

require_macos_user

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_DIR="$REPO_ROOT/whatsapp-bridge"
BRIDGE_BINARY="$BRIDGE_DIR/whatsapp-bridge"

[[ -d "$BRIDGE_DIR" ]] || fail "Could not find bridge directory: $BRIDGE_DIR"

PORT="${WHATSAPP_BRIDGE_PORT:-8080}"
validate_port "$PORT"
API_URL="${WHATSAPP_API_URL:-http://127.0.0.1:${PORT}/api}"

SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-mcp"
STATE_DIR="$SUPPORT_DIR/state"
LOG_DIR="$HOME/Library/Logs/whatsapp-mcp"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
ENV_FILE="$SUPPORT_DIR/launchd.env"
RUNNER_SCRIPT="$SUPPORT_DIR/run-whatsapp-bridge.sh"
MONITOR_SCRIPT="$SUPPORT_DIR/monitor-whatsapp-bridge.sh"
BRIDGE_PLIST="$LAUNCH_AGENTS_DIR/$BRIDGE_LABEL.plist"
MONITOR_PLIST="$LAUNCH_AGENTS_DIR/$MONITOR_LABEL.plist"
TRANSCRIBE_PLIST="$LAUNCH_AGENTS_DIR/$TRANSCRIBE_LABEL.plist"
CLEANUP_PLIST="$LAUNCH_AGENTS_DIR/$CLEANUP_LABEL.plist"

SERVER_DIR="$REPO_ROOT/whatsapp-mcp-server"
VENV_PYTHON="$SERVER_DIR/.venv/bin/python"
TRANSCRIBE_SCRIPT="$SCRIPT_DIR/transcribe-backlog.py"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-media.sh"

validate_positive_int "WHATSAPP_MCP_TRANSCRIBE_HOURS" "$TRANSCRIBE_HOURS"
validate_positive_int "WHATSAPP_MCP_TRANSCRIBE_LIMIT" "$TRANSCRIBE_LIMIT"
validate_positive_int "WHATSAPP_MCP_TRANSCRIBE_INTERVAL" "$TRANSCRIBE_INTERVAL"
validate_positive_int "WHATSAPP_MCP_CLEANUP_INTERVAL" "$CLEANUP_INTERVAL"

USER_ID="$(id -u)"
LAUNCHD_DOMAIN="gui/$USER_ID"

mkdir -p "$SUPPORT_DIR" "$STATE_DIR" "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

if command -v go >/dev/null 2>&1; then
  print -r -- "Building WhatsApp bridge..."
  (cd "$BRIDGE_DIR" && go build -o "$BRIDGE_BINARY" .)
elif [[ ! -x "$BRIDGE_BINARY" ]]; then
  fail "Go is not available and no executable bridge binary exists at $BRIDGE_BINARY."
fi

[[ -x "$BRIDGE_BINARY" ]] || fail "Bridge binary is not executable: $BRIDGE_BINARY"

print -r -- "Stopping existing whatsapp-mcp LaunchAgents if present..."
bootout_label "$LAUNCHD_DOMAIN" "$CLEANUP_LABEL"
bootout_label "$LAUNCHD_DOMAIN" "$TRANSCRIBE_LABEL"
bootout_label "$LAUNCHD_DOMAIN" "$MONITOR_LABEL"
bootout_label "$LAUNCHD_DOMAIN" "$BRIDGE_LABEL"

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2 || true
  fail "Port $PORT is already in use after stopping existing whatsapp-mcp LaunchAgents."
fi

old_umask="$(umask)"
umask 077
: > "$ENV_FILE"
umask "$old_umask"
write_export "WHATSAPP_MCP_REPO_ROOT" "$REPO_ROOT"
write_export "WHATSAPP_BRIDGE_DIR" "$BRIDGE_DIR"
write_export "WHATSAPP_BRIDGE_BINARY" "$BRIDGE_BINARY"
write_export "WHATSAPP_BRIDGE_PORT" "$PORT"
write_export "WHATSAPP_API_URL" "$API_URL"
write_export "WHATSAPP_MCP_LOG_DIR" "$LOG_DIR"
write_export "WHATSAPP_MCP_STATE_DIR" "$STATE_DIR"

for optional_var in WEBHOOK_URL FORWARD_SELF WHATSAPP_BRIDGE_TOKEN WHATSAPP_MEDIA_ROOTS; do
  if [[ -v "$optional_var" ]]; then
    write_export "$optional_var" "${(P)optional_var}"
  fi
done
chmod 600 "$ENV_FILE"

cat > "$RUNNER_SCRIPT" <<EOF
#!/bin/zsh
set -euo pipefail

source $(shell_quote "$ENV_FILE")
cd "\$WHATSAPP_BRIDGE_DIR"
exec "\$WHATSAPP_BRIDGE_BINARY"
EOF
chmod 755 "$RUNNER_SCRIPT"

cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/zsh
set -euo pipefail

source $(shell_quote "$ENV_FILE")

BRIDGE_LABEL="$BRIDGE_LABEL"
STATE_DIR="\${WHATSAPP_MCP_STATE_DIR:-\$HOME/Library/Application Support/whatsapp-mcp/state}"
LOG_DIR="\${WHATSAPP_MCP_LOG_DIR:-\$HOME/Library/Logs/whatsapp-mcp}"
TOKEN_FILE="\$WHATSAPP_BRIDGE_DIR/store/.bridge-token"
BRIDGE_LOG="\$LOG_DIR/bridge.out.log"

mkdir -p "\$STATE_DIR"

notify() {
  local title="\$1"
  local msg="\$2"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "\$title" -message "\$msg" >/dev/null 2>&1 || true
  else
    osascript \\
      -e 'on run argv' \\
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \\
      -e 'end run' \\
      "\$title" "\$msg" >/dev/null 2>&1 || true
  fi
}

alert_once() {
  local key="\$1"
  local title="\$2"
  local msg="\$3"
  local marker="\$STATE_DIR/\$key.alerted"
  if [[ ! -f "\$marker" ]]; then
    notify "\$title" "\$msg"
    : > "\$marker"
  fi
}

clear_alert() {
  local key="\$1"
  rm -f "\$STATE_DIR/\$key.alerted"
}

USER_ID="\$(id -u)"
if ! launchctl print "gui/\$USER_ID/\$BRIDGE_LABEL" >/dev/null 2>&1; then
  alert_once "down" "WhatsApp Bridge Down" "The bridge LaunchAgent is not loaded."
  exit 0
fi
clear_alert "down"

TOKEN="\${WHATSAPP_BRIDGE_TOKEN:-}"
if [[ -z "\$TOKEN" && -r "\$TOKEN_FILE" ]]; then
  TOKEN="\$(tr -d '[:space:]' < "\$TOKEN_FILE")"
fi

if [[ -z "\$TOKEN" ]]; then
  alert_once "token" "WhatsApp Bridge Token Missing" "No WHATSAPP_BRIDGE_TOKEN is configured and \$TOKEN_FILE is unreadable."
  exit 0
fi
clear_alert "token"

API_URL="\${WHATSAPP_API_URL%/}"
response="\$(curl -sS -m 5 -H "Authorization: Bearer \$TOKEN" -w \$'\n%{http_code}' "\$API_URL/health" 2>/dev/null || true)"
if [[ -z "\$response" ]]; then
  alert_once "api" "WhatsApp Bridge API Unreachable" "The health endpoint did not respond at \$API_URL/health."
  exit 0
fi
http_code="\${response##*\$'\n'}"
HEALTH="\${response%\$'\n'*}"
if [[ "\$http_code" == "401" || "\$http_code" == "403" ]]; then
  alert_once "token" "WhatsApp Bridge Token Invalid" "The health endpoint rejected the configured token. Re-sync WHATSAPP_BRIDGE_TOKEN or \$TOKEN_FILE."
  exit 0
fi
if [[ "\$http_code" != "200" && "\$http_code" != "503" ]]; then
  alert_once "api" "WhatsApp Bridge API Unreachable" "Unexpected HTTP \$http_code from \$API_URL/health."
  exit 0
fi
clear_alert "api"

connected=false
if print -r -- "\$HEALTH" | grep -Eq '"connected"[[:space:]]*:[[:space:]]*true'; then
  connected=true
fi

if [[ "\$connected" == "true" ]]; then
  clear_alert "relink"
  clear_alert "qr"
else
  alert_once "relink" "WhatsApp Relink Needed" "The bridge is running but WhatsApp is disconnected. Check logs and scan a QR code if prompted."
  if [[ -f "\$BRIDGE_LOG" ]]; then
    if tail -n 200 "\$BRIDGE_LOG" 2>/dev/null | grep -Eiq 'Scan this QR code|Device logged out|QR code timed out|Timeout waiting for QR code scan'; then
      alert_once "qr" "WhatsApp QR Action Needed" "The bridge logs indicate that phone linking is required."
    else
      clear_alert "qr"
    fi
  fi
fi
EOF
chmod 755 "$MONITOR_SCRIPT"

cat > "$BRIDGE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$BRIDGE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>$(xml_escape "$RUNNER_SCRIPT")</string>
    </array>
    <key>WorkingDirectory</key><string>$(xml_escape "$BRIDGE_DIR")</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/bridge.out.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/bridge.err.log")</string>
  </dict>
</plist>
EOF

cat > "$MONITOR_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$MONITOR_LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>$(xml_escape "$MONITOR_SCRIPT")</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>60</integer>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/monitor.out.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/monitor.err.log")</string>
  </dict>
</plist>
EOF

# Voice-note transcription backlog. Keeps the transcript cache warm so that
# reading a chat does not have to transcribe inline (list_messages only
# transcribes a handful of voice notes per call). Needs the Python venv, so it
# is skipped with a warning when dependencies have not been installed yet.
install_transcribe_job=false
if [[ ! -f "$TRANSCRIBE_SCRIPT" ]]; then
  print -r -- "Note: $TRANSCRIBE_SCRIPT not found; skipping $TRANSCRIBE_LABEL." >&2
elif [[ ! -x "$VENV_PYTHON" ]]; then
  print -r -- "Note: no Python venv at $VENV_PYTHON; skipping $TRANSCRIBE_LABEL." >&2
  print -r -- "      Run 'uv sync' in whatsapp-mcp-server/, then re-run this installer." >&2
else
  install_transcribe_job=true
  cat > "$TRANSCRIBE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$TRANSCRIBE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>$(xml_escape "$VENV_PYTHON")</string>
      <string>$(xml_escape "$TRANSCRIBE_SCRIPT")</string>
      <string>--hours</string>
      <string>$(xml_escape "$TRANSCRIBE_HOURS")</string>
      <string>--limit</string>
      <string>$(xml_escape "$TRANSCRIBE_LIMIT")</string>
    </array>
    <key>WorkingDirectory</key><string>$(xml_escape "$REPO_ROOT")</string>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>$TRANSCRIBE_INTERVAL</integer>
    <key>Nice</key><integer>10</integer>
    <key>LowPriorityIO</key><true/>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/transcribe.out.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/transcribe.err.log")</string>
  </dict>
</plist>
EOF
fi

# Media cache eviction. Deletes images/videos/stickers older than 3 days;
# voice notes and documents are kept.
install_cleanup_job=false
if [[ ! -f "$CLEANUP_SCRIPT" ]]; then
  print -r -- "Note: $CLEANUP_SCRIPT not found; skipping $CLEANUP_LABEL." >&2
else
  install_cleanup_job=true
  cat > "$CLEANUP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>$CLEANUP_LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>$(xml_escape "$CLEANUP_SCRIPT")</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>WHATSAPP_BRIDGE_DIR</key><string>$(xml_escape "$BRIDGE_DIR")</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>$CLEANUP_INTERVAL</integer>
    <key>LowPriorityIO</key><true/>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR/media-cleanup.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR/media-cleanup.log")</string>
  </dict>
</plist>
EOF
fi

print -r -- "Loading whatsapp-mcp LaunchAgents..."
launchctl bootstrap "$LAUNCHD_DOMAIN" "$BRIDGE_PLIST"
launchctl enable "$LAUNCHD_DOMAIN/$BRIDGE_LABEL"
launchctl kickstart -k "$LAUNCHD_DOMAIN/$BRIDGE_LABEL"

launchctl bootstrap "$LAUNCHD_DOMAIN" "$MONITOR_PLIST"
launchctl enable "$LAUNCHD_DOMAIN/$MONITOR_LABEL"
launchctl kickstart -k "$LAUNCHD_DOMAIN/$MONITOR_LABEL"

if [[ "$install_transcribe_job" == "true" ]]; then
  launchctl bootstrap "$LAUNCHD_DOMAIN" "$TRANSCRIBE_PLIST"
  launchctl enable "$LAUNCHD_DOMAIN/$TRANSCRIBE_LABEL"
  # No -k here: never kill a transcription run that is already in progress.
  launchctl kickstart "$LAUNCHD_DOMAIN/$TRANSCRIBE_LABEL"
fi

if [[ "$install_cleanup_job" == "true" ]]; then
  launchctl bootstrap "$LAUNCHD_DOMAIN" "$CLEANUP_PLIST"
  launchctl enable "$LAUNCHD_DOMAIN/$CLEANUP_LABEL"
  launchctl kickstart -k "$LAUNCHD_DOMAIN/$CLEANUP_LABEL"
fi

print -r -- "Installed whatsapp-mcp LaunchAgents:"
print -r -- "  $BRIDGE_LABEL"
print -r -- "  $MONITOR_LABEL"
if [[ "$install_transcribe_job" == "true" ]]; then
  print -r -- "  $TRANSCRIBE_LABEL (every ${TRANSCRIBE_INTERVAL}s, --hours $TRANSCRIBE_HOURS --limit $TRANSCRIBE_LIMIT)"
fi
if [[ "$install_cleanup_job" == "true" ]]; then
  print -r -- "  $CLEANUP_LABEL (every ${CLEANUP_INTERVAL}s)"
fi
print -r -- "Logs: $LOG_DIR"
