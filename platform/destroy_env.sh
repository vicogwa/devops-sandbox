#!/usr/bin/env bash
# destroy_env.sh — Tear down a sandbox environment completely

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_ID="${1:?Usage: $0 <env_id>}"
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No state file found for $ENV_ID" >&2
  exit 1
fi

LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
ARCHIVE_DIR="$ROOT_DIR/logs/archived/$ENV_ID"
NGINX_CONF="$ROOT_DIR/nginx/conf.d/${ENV_ID}.conf"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Destroying environment: $ENV_ID"

# Parse state with grep/sed instead of python
CONTAINER=$(grep '"container"' "$STATE_FILE" | sed 's/.*: *"\(.*\)".*/\1/')
NETWORK=$(grep '"network"'   "$STATE_FILE" | sed 's/.*: *"\(.*\)".*/\1/')
LOG_PID=$(grep '"log_pid"'   "$STATE_FILE" | sed 's/.*: *\([0-9]*\).*/\1/')

# 1. Kill log-shipping process
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" 2>/dev/null; then
  kill "$LOG_PID" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Killed log forwarder PID $LOG_PID"
fi
pkill -f "docker logs -f $CONTAINER" 2>/dev/null || true

# 2. Stop and remove labeled containers
CONTAINER_IDS=$(docker ps -aq --filter "label=sandbox.env=$ENV_ID" 2>/dev/null || true)
if [[ -n "$CONTAINER_IDS" ]]; then
  echo "$CONTAINER_IDS" | xargs docker rm -f >/dev/null 2>&1 || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Removed containers for $ENV_ID"
fi

# 3. Remove Docker network
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK}$"; then
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Removed network $NETWORK"
fi

# 4. Delete Nginx config and reload
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
    docker exec "$NGINX_CONTAINER" nginx -s reload
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Nginx reloaded"
  fi
fi

# 5. Archive logs
if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  cp -r "$LOG_DIR/." "$ARCHIVE_DIR/" 2>/dev/null || true
  rm -rf "$LOG_DIR"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Logs archived to $ARCHIVE_DIR"
fi

# 6. Remove state file
rm -f "$STATE_FILE"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Environment $ENV_ID destroyed successfully"