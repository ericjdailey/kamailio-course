#!/bin/bash
set -euo pipefail

TIMESTAMP() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(TIMESTAMP)] $1" >&2; }

###########################################
# CONFIG / ENVIRONMENT
###########################################
#
# This script toggles which dialplan include file is active in
# /etc/asterisk/extensions.conf, then reloads Asterisk dialplan.
#
# Expected in extensions.conf:
#   - one include line referencing: <CUSTOMER_NAME>-normal.conf
#   - one include line referencing: <CUSTOMER_NAME>-downtime.conf
#
# The "active state" is determined by which include line is NOT commented
# (Asterisk config comments typically start with ';').
#
###########################################

if [ -f /etc/integration_state.env ]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/integration_state.env
  set +a
fi

API_BASE_URL="${API_BASE_URL:-}"
INTEGRATION_ID="${INTEGRATION_ID:-}"
API_KEY="${API_KEY:-}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-60}"  # Default to 60 seconds between checks
DRY_RUN=false
DAEMON_MODE=true

# Dialplan switching config
CUSTOMER_NAME="${CUSTOMER_NAME:-}"
EXTENSIONS_CONF="${EXTENSIONS_CONF:-/etc/asterisk/extensions.conf}"
ASTERISK_CLI_CMD="${ASTERISK_CLI_CMD:-asterisk -rx}"
ASTERISK_RELOAD_CMD="${ASTERISK_RELOAD_CMD:-dialplan reload}"

###########################################
# Parse args
###########################################
for arg in "$@"; do
  case $arg in
    dry_run=*)
      DRY_RUN="${arg#*=}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --daemon)
      DAEMON_MODE=true
      ;;
    --one-shot)
      DAEMON_MODE=false
      ;;
    sleep_interval=*)
      SLEEP_INTERVAL="${arg#*=}"
      ;;
    customer_name=*)
      CUSTOMER_NAME="${arg#*=}"
      ;;
    extensions_conf=*)
      EXTENSIONS_CONF="${arg#*=}"
      ;;
    *)
      ;;
  esac
done

###########################################
# Validate required environment variables
###########################################
VALIDATION_FAILED=false

if ! command -v curl >/dev/null 2>&1; then
  log "ERROR: curl is required"
  VALIDATION_FAILED=true
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required"
  VALIDATION_FAILED=true
fi

if [ -z "$API_BASE_URL" ]; then
  log "ERROR: API_BASE_URL is required"
  log "  Set via environment variable or in /etc/integration_state.env"
  VALIDATION_FAILED=true
fi

if [ -z "$INTEGRATION_ID" ]; then
  log "ERROR: INTEGRATION_ID is required"
  log "  Set via environment variable or in /etc/integration_state.env"
  VALIDATION_FAILED=true
fi

if [ -z "$API_KEY" ]; then
  log "ERROR: API_KEY is required (or ensure IAM credentials are available)"
  log "  Set via environment variable or in /etc/integration_state.env"
  VALIDATION_FAILED=true
fi

if [ -z "$CUSTOMER_NAME" ]; then
  log "ERROR: CUSTOMER_NAME is required"
  log "  Used to locate include lines: <CUSTOMER_NAME>-normal.conf and <CUSTOMER_NAME>-downtime.conf"
  VALIDATION_FAILED=true
fi

if [ ! -f "$EXTENSIONS_CONF" ]; then
  log "ERROR: EXTENSIONS_CONF not found: $EXTENSIONS_CONF"
  VALIDATION_FAILED=true
fi

if ! command -v asterisk >/dev/null 2>&1; then
  log "WARNING: asterisk CLI not found in PATH; dialplan reload will fail unless ASTERISK_CLI_CMD is adjusted"
fi

if [ "$VALIDATION_FAILED" = true ]; then
  log ""
  log "Configuration file location: /etc/integration_state.env"
  exit 1
fi

NORMAL_INCLUDE_FILE="${CUSTOMER_NAME}-normal.conf"
DOWNTIME_INCLUDE_FILE="${CUSTOMER_NAME}-downtime.conf"

log "Running integration_dialplan_state_manager.sh (dry_run=$DRY_RUN, daemon=$DAEMON_MODE)"
log "Using extensions.conf: $EXTENSIONS_CONF"
log "Normal include: $NORMAL_INCLUDE_FILE"
log "Downtime include: $DOWNTIME_INCLUDE_FILE"

###########################################
# SIGNAL HANDLING FOR GRACEFUL SHUTDOWN
###########################################
RUNNING=true

trap_handler() {
  log "Received signal, shutting down gracefully..."
  RUNNING=false
}

trap trap_handler SIGTERM SIGINT SIGQUIT

###########################################
# AUTH HANDLING (IAM → API KEY FALLBACK)
###########################################
auth_request() {
  local url="$1"
  local method="${2:-GET}"
  local data="${3:-}"

  #
  # IAM attempt (SigV4 using AWS CLI)
  #
  if command -v aws >/dev/null 2>&1; then
    if token=$(aws sts get-caller-identity --output json 2>/dev/null); then
      log "IAM auth OK, using SigV4"

      if [ -n "$data" ]; then
        iam_response=$(curl -s --fail \
          --aws-sigv4 "aws:amz:us-east-1:execute-api" \
          -X "$method" \
          -H "Content-Type: application/json" \
          --data "$data" \
          "$url") && echo "$iam_response" && return 0
      else
        iam_response=$(curl -s --fail \
          --aws-sigv4 "aws:amz:us-east-1:execute-api" \
          -X "$method" \
          "$url") && echo "$iam_response" && return 0
      fi
    else
      log "IAM auth failed"
    fi
  fi

  #
  # API KEY fallback
  #
  if [ -n "$API_KEY" ]; then
    log "Using API Key fallback"
    if [ -n "$data" ]; then
      curl -s --fail -X "$method" \
        -H "X-API-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        --data "$data" \
        "$url"
    else
      curl -s --fail -X "$method" \
        -H "X-API-Key: $API_KEY" \
        "$url"
    fi
  else
    log "ERROR: No API key available and IAM failed"
    exit 1
  fi
}

###########################################
# GET DESIRED STATE (normal|downtime)
###########################################
normalize_state() {
  # Accept legacy "bypass" as downtime.
  # Also accept already-normalized "normal" / "downtime".
  local raw="$1"
  case "$raw" in
    normal) echo "normal" ;;
    downtime) echo "downtime" ;;
    bypass) echo "downtime" ;;
    *) echo "unknown" ;;
  esac
}

get_desired_state() {
  local url="$API_BASE_URL/integrations/$INTEGRATION_ID"
  local raw
  raw="$(auth_request "$url" "GET" | jq -r '.status')"
  normalize_state "$raw"
}

###########################################
# DETERMINE CURRENT STATE FROM extensions.conf
###########################################
get_current_state() {
  # Returns: normal | downtime | unknown | conflict
  awk -v normal="$NORMAL_INCLUDE_FILE" -v down="$DOWNTIME_INCLUDE_FILE" '
    function is_commented(line) { return (line ~ /^[ \t]*;/) }
    function looks_like_include(line) { return (tolower(line) ~ /include/) }
    BEGIN { normal_found=0; down_found=0; normal_active=0; down_active=0; }
    {
      line=$0
      if (index(line, normal) && looks_like_include(line)) {
        normal_found=1
        if (!is_commented(line)) normal_active=1
      }
      if (index(line, down) && looks_like_include(line)) {
        down_found=1
        if (!is_commented(line)) down_active=1
      }
    }
    END {
      if (!normal_found || !down_found) { print "unknown"; exit 0 }
      if (normal_active && down_active) { print "conflict"; exit 0 }
      if (normal_active && !down_active) { print "normal"; exit 0 }
      if (!normal_active && down_active) { print "downtime"; exit 0 }
      print "unknown"
    }
  ' "$EXTENSIONS_CONF"
}

###########################################
# APPLY STATE IN extensions.conf
###########################################
apply_state_to_extensions_conf() {
  local desired_state="$1" # normal|downtime

  if [ "$desired_state" != "normal" ] && [ "$desired_state" != "downtime" ]; then
    log "ERROR: cannot apply unknown desired state: $desired_state"
    return 1
  fi

  # Ensure file contains both markers before writing.
  local counts
  counts="$(awk -v normal="$NORMAL_INCLUDE_FILE" -v down="$DOWNTIME_INCLUDE_FILE" '
    function looks_like_include(line) { return (tolower(line) ~ /include/) }
    BEGIN { n=0; d=0; }
    {
      if (index($0, normal) && looks_like_include($0)) n++
      if (index($0, down) && looks_like_include($0)) d++
    }
    END { printf("%d %d\n", n, d); }
  ' "$EXTENSIONS_CONF")"

  local n_count d_count
  n_count="$(echo "$counts" | awk '{print $1}')"
  d_count="$(echo "$counts" | awk '{print $2}')"

  if [ "$n_count" -lt 1 ] || [ "$d_count" -lt 1 ]; then
    log "ERROR: could not find required include lines in $EXTENSIONS_CONF"
    log "  Needed lines referencing: $NORMAL_INCLUDE_FILE and $DOWNTIME_INCLUDE_FILE"
    log "  Found counts: normal=$n_count downtime=$d_count"
    return 1
  fi

  log "Updating $EXTENSIONS_CONF to state: $desired_state"

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would edit $EXTENSIONS_CONF and run Asterisk dialplan reload"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  # Toggle commenting on ONLY the two include lines.
  awk -v normal="$NORMAL_INCLUDE_FILE" -v down="$DOWNTIME_INCLUDE_FILE" -v desired="$desired_state" '
    function is_commented(line) { return (line ~ /^[ \t]*;/) }
    function looks_like_include(line) { return (tolower(line) ~ /include/) }
    function comment_line(line,   indent, rest) {
      if (is_commented(line)) return line
      match(line, /^[ \t]*/)
      indent=substr(line, RSTART, RLENGTH)
      rest=substr(line, RLENGTH+1)
      return indent ";" rest
    }
    function uncomment_line(line,   indent, rest) {
      match(line, /^[ \t]*/)
      indent=substr(line, RSTART, RLENGTH)
      rest=substr(line, RLENGTH+1)
      sub(/^;[ \t]*/, "", rest)
      return indent rest
    }
    {
      line=$0
      if (index(line, normal) && looks_like_include(line)) {
        if (desired=="normal") line=uncomment_line(line); else line=comment_line(line)
      } else if (index(line, down) && looks_like_include(line)) {
        if (desired=="downtime") line=uncomment_line(line); else line=comment_line(line)
      }
      print line
    }
  ' "$EXTENSIONS_CONF" > "$tmp"

  # Backup then replace atomically.
  local backup="${EXTENSIONS_CONF}.$(date +%Y%m%d%H%M%S).bak"
  cp -a "$EXTENSIONS_CONF" "$backup"
  mv "$tmp" "$EXTENSIONS_CONF"
  log "Wrote $EXTENSIONS_CONF (backup: $backup)"
}

###########################################
# RELOAD DIALPLAN
###########################################
reload_dialplan() {
  log "Reloading Asterisk dialplan: $ASTERISK_RELOAD_CMD"
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would run: $ASTERISK_CLI_CMD \"$ASTERISK_RELOAD_CMD\""
    return 0
  fi

  # shellcheck disable=SC2086
  $ASTERISK_CLI_CMD "$ASTERISK_RELOAD_CMD" >/dev/null
}

###########################################
# HEARTBEAT
###########################################
send_heartbeat() {
  local state="$1"
  local ts
  ts=$(date +%s)
  local url="$API_BASE_URL/integrations/$INTEGRATION_ID/heartbeat"

  data=$(printf '{"current_state":"%s","ts":%d}' "$state" "$ts")

  log "Sending heartbeat: $data"
  auth_request "$url" "POST" "$data" >/dev/null || log "Heartbeat failed"
}

###########################################
# MAIN LOGIC
###########################################
run_check() {
  local desired_state
  desired_state="$(get_desired_state)"

  local current_state
  current_state="$(get_current_state)"

  log "Desired state: $desired_state"
  log "Current state: $current_state"

  if [ "$desired_state" = "unknown" ]; then
    log "ERROR: API returned unknown desired state; no changes will be applied"
    send_heartbeat "$current_state"
    return 1
  fi

  if [ "$current_state" = "conflict" ]; then
    log "WARNING: both include lines appear active; will force desired state: $desired_state"
  fi

  if [ "$current_state" = "$desired_state" ]; then
    log "State already correct, no changes needed"
  else
    apply_state_to_extensions_conf "$desired_state"
    reload_dialplan
    current_state="$(get_current_state)"
    log "State after reload: $current_state"
  fi

  # Always heartbeat (even if unknown/conflict)
  send_heartbeat "$current_state"
}

# Main execution
if [ "$DAEMON_MODE" = true ]; then
  log "Starting in daemon mode (check interval: ${SLEEP_INTERVAL}s)"

  while [ "$RUNNING" = true ]; do
    run_check || log "Check failed, will retry in ${SLEEP_INTERVAL}s"

    # Sleep with interrupt checking (allows quick shutdown)
    for _ in $(seq 1 "$SLEEP_INTERVAL"); do
      [ "$RUNNING" = false ] && break
      sleep 1
    done
  done

  log "Daemon stopped"
else
  log "Running in one-shot mode"
  run_check
fi

