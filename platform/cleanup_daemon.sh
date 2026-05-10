#!/usr/bin/env bash
# cleanup_daemon.sh — Background TTL reaper for expired environments
# Run with: nohup ./platform/cleanup_daemon.sh &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || true

LOG_FILE="${ROOT_DIR}/${DAEMON_LOG:-logs/cleanup.log}"
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$ROOT_DIR/envs"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"
}

log "Cleanup daemon started (PID $$)"

while true; do
  NOW=$(date -u +%s)

  for STATE_FILE in "$ROOT_DIR"/envs/*.json; do
    [[ -f "$STATE_FILE" ]] || continue

    ENV_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['id'])" 2>/dev/null || true)
    CREATED_AT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['created_at'])" 2>/dev/null || true)
    TTL=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['ttl'])" 2>/dev/null || true)
    STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','unknown'))" 2>/dev/null || true)

    [[ -z "$ENV_ID" || -z "$CREATED_AT" || -z "$TTL" ]] && continue

    EXPIRES_AT=$((CREATED_AT + TTL))
    REMAINING=$((EXPIRES_AT - NOW))

    if [[ $NOW -ge $EXPIRES_AT ]]; then
      log "TTL expired for $ENV_ID (was: $STATUS, overdue by $((NOW - EXPIRES_AT))s) — destroying"
      "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >> "$LOG_FILE" 2>&1 || \
        log "ERROR: Failed to destroy $ENV_ID"
    elif [[ $REMAINING -le 60 ]]; then
      log "WARNING: $ENV_ID expires in ${REMAINING}s"
    fi
  done

  sleep 60
done
