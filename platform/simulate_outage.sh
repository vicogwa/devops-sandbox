#!/usr/bin/env bash
# simulate_outage.sh — Inject failures into a running sandbox environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)   ENV_ID="$2";  shift 2 ;;
    --mode)  MODE="$2";    shift 2 ;;
    *)       echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$ENV_ID" ]] && { echo "Error: --env required" >&2; exit 1; }
[[ -z "$MODE"   ]] && { echo "Error: --mode required" >&2; exit 1; }

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
[[ -f "$STATE_FILE" ]] || { echo "Error: Unknown environment $ENV_ID" >&2; exit 1; }

# Parse with grep/sed
CONTAINER=$(grep '"container"' "$STATE_FILE" | sed 's/.*: *"\(.*\)".*/\1/')
NETWORK=$(grep '"network"'     "$STATE_FILE" | sed 's/.*: *"\(.*\)".*/\1/')
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"

# Safety guard
PROTECTED_CONTAINERS=("$NGINX_CONTAINER" "sandbox-api" "sandbox-daemon")
for PROTECTED in "${PROTECTED_CONTAINERS[@]}"; do
  if [[ "$CONTAINER" == "$PROTECTED" ]]; then
    echo "ABORT: Refusing to simulate outage on protected container: $CONTAINER" >&2
    exit 2
  fi
done

LABEL_CHECK=$(docker inspect "$CONTAINER" \
  --format '{{index .Config.Labels "sandbox.managed"}}' 2>/dev/null || echo "")
if [[ "$LABEL_CHECK" != "true" ]]; then
  echo "ABORT: Container $CONTAINER is not a managed sandbox container" >&2
  exit 2
fi

log_event() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [outage/$MODE] $*"
}

update_status() {
  local NEW_STATUS="$1"
  TEMP="$(mktemp)"
  sed 's/"status": *"[^"]*"/"status": "'"$NEW_STATUS"'"/' "$STATE_FILE" > "$TEMP"
  mv "$TEMP" "$STATE_FILE"
}

case "$MODE" in
  crash)
    log_event "Sending SIGKILL to $CONTAINER"
    docker kill "$CONTAINER"
    update_status "crashed"
    log_event "Container killed. Health monitor should detect failure within 90s."
    ;;
  pause)
    log_event "Pausing $CONTAINER"
    docker pause "$CONTAINER"
    update_status "paused"
    ;;
  network)
    log_event "Disconnecting $CONTAINER from network $NETWORK"
    docker network disconnect "$NETWORK" "$CONTAINER"
    update_status "network-isolated"
    ;;
  stress)
    log_event "Spiking CPU on $CONTAINER for 60s"
    docker exec -d "$CONTAINER" stress-ng --cpu 0 --timeout 60s
    update_status "stressed"
    ;;
  recover)
    CURRENT_STATUS=$(grep '"status"' "$STATE_FILE" | sed 's/.*: *"\(.*\)".*/\1/')
    log_event "Recovering from status: $CURRENT_STATUS"
    case "$CURRENT_STATUS" in
      crashed)         docker start "$CONTAINER" ;;
      paused)          docker unpause "$CONTAINER" ;;
      network-isolated) docker network connect "$NETWORK" "$CONTAINER" ;;
      stressed)        docker exec "$CONTAINER" pkill stress-ng 2>/dev/null || true ;;
    esac
    update_status "running"
    log_event "Recovery complete"
    ;;
  *)
    echo "Error: Unknown mode '$MODE'" >&2; exit 1 ;;
esac

echo "Simulation '$MODE' applied to $ENV_ID"