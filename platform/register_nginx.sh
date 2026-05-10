#!/usr/bin/env bash
# register_nginx.sh — Write per-env Nginx config and reload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

ENV_ID="${1:?ENV_ID required}"
HOST_PORT="${2:?HOST_PORT required}"
CONF_FILE="$ROOT_DIR/nginx/conf.d/${ENV_ID}.conf"

cat > "$CONF_FILE" << NGINX
# Auto-generated — do not edit manually
# Environment: $ENV_ID
location /${ENV_ID}/ {
    proxy_pass         http://host.docker.internal:${HOST_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Host            \$host;
    proxy_set_header   X-Real-IP       \$remote_addr;
    proxy_set_header   X-Sandbox-Env   ${ENV_ID};
    proxy_read_timeout 30s;
}
NGINX

NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
  docker exec "$NGINX_CONTAINER" nginx -s reload
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Nginx reloaded for $ENV_ID"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Warning: Nginx container not running" >&2
fi