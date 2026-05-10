#!/usr/bin/env bash
# create_env.sh — Spin up an isolated sandbox environment
# Usage: ./create_env.sh <name> [ttl_seconds]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_NAME="${1:-}"
TTL="${2:-${DEFAULT_TTL:-1800}}"

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <name> [ttl_seconds]" >&2
  exit 1
fi

# Sanitize name
ENV_NAME="${ENV_NAME//[^a-zA-Z0-9-]/-}"
ENV_ID="env-$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]')-$(openssl rand -hex 4)"
NETWORK_NAME="net-$ENV_ID"
CONTAINER_NAME="app-$ENV_ID"
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
CREATED_AT=$(date -u +%s)
BASE_PORT="${PLATFORM_BASE_PORT:-8100}"

# Pick an available host port
HOST_PORT=$BASE_PORT
while docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$HOST_PORT->"; do
  HOST_PORT=$((HOST_PORT + 1))
done

mkdir -p "$LOG_DIR"
mkdir -p "$ROOT_DIR/envs"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Creating environment: $ENV_ID (TTL: ${TTL}s)"

# 1. Dedicated Docker network
docker network create "$NETWORK_NAME" \
  --label sandbox.env="$ENV_ID" \
  --label sandbox.managed=true \
  >/dev/null

# 2. Start the demo app container
docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --label sandbox.env="$ENV_ID" \
  --label sandbox.managed=true \
  --label sandbox.name="$ENV_NAME" \
  -p "${HOST_PORT}:3000" \
  -e ENV_ID="$ENV_ID" \
  -e ENV_NAME="$ENV_NAME" \
  sandbox-demo-app:latest \
  >/dev/null

# 3. Write state file atomically (pure bash, no python)
TEMP_STATE="$(mktemp)"
cat > "$TEMP_STATE" << STATEOF
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "container": "$CONTAINER_NAME",
  "network": "$NETWORK_NAME",
  "host_port": $HOST_PORT,
  "created_at": $CREATED_AT,
  "ttl": $TTL,
  "status": "running",
  "log_pid": null
}
STATEOF
mv "$TEMP_STATE" "$STATE_FILE"

# 4. Register Nginx route
"$SCRIPT_DIR/register_nginx.sh" "$ENV_ID" "$HOST_PORT"

# 5. Start log shipping
LOG_FILE="$LOG_DIR/app.log"
docker logs -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 &
LOG_PID=$!

# Update log PID in state atomically using sed (no python needed)
TEMP_STATE="$(mktemp)"
sed 's/"log_pid": null/"log_pid": '"$LOG_PID"'/' "$STATE_FILE" > "$TEMP_STATE"
mv "$TEMP_STATE" "$STATE_FILE"

NGINX_PORT="${NGINX_PORT:-80}"
ENV_URL="http://localhost:${NGINX_PORT}/${ENV_ID}/"

echo ""
echo "✓ Environment ready"
echo "  ID:      $ENV_ID"
echo "  Name:    $ENV_NAME"
echo "  URL:     $ENV_URL"
echo "  Direct:  http://localhost:${HOST_PORT}"
echo "  TTL:     ${TTL}s"
echo ""