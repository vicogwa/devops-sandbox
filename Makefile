# Makefile — DevOps Sandbox Platform
# All actions go through here. Don't invoke scripts directly.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT_DIR := $(shell pwd)
PLATFORM := $(ROOT_DIR)/platform
ENV_FILE := $(ROOT_DIR)/.env

# Load .env if it exists
-include $(ENV_FILE)
export

# ── Bootstrap ─────────────────────────────────────────────────────────────────

.PHONY: build
build: ## Build the demo app image and API image
	@echo "→ Building sandbox-demo-app image..."
	docker build -t sandbox-demo-app:latest $(ROOT_DIR)/demo-app
	@echo "→ Building sandbox-api image..."
	docker build -t sandbox-api:latest -f $(PLATFORM)/Dockerfile.api $(ROOT_DIR)
	@echo "✓ Images built"

.PHONY: init
init: ## Initialize directory structure and .env
	@mkdir -p envs logs/archived nginx/conf.d monitor
	@if [[ ! -f .env ]]; then \
		cp .env.example .env; \
		echo "✓ Created .env from .env.example — review and edit if needed"; \
	else \
		echo "  .env already exists, skipping"; \
	fi
	@chmod +x platform/*.sh
	@echo "✓ Initialized"

# ── Platform lifecycle ─────────────────────────────────────────────────────────

.PHONY: up
up: init ## Start Nginx, API, health poller, and cleanup daemon
	@echo "→ Starting platform services..."
	docker compose up -d nginx api
	@echo "→ Starting cleanup daemon..."
	@mkdir -p logs
	nohup bash $(PLATFORM)/cleanup_daemon.sh > logs/daemon.out 2>&1 &
	@echo "→ Starting health poller..."
	nohup python3 $(ROOT_DIR)/monitor/health_poller.py > logs/poller.out 2>&1 &
	@echo ""
	@echo "✓ Platform is up"
	@echo "  Nginx:  http://localhost:${NGINX_PORT:-80}"
	@echo "  API:    http://localhost:${API_PORT:-5050}"
	@echo "  Logs:   make logs-platform"

.PHONY: down
down: ## Stop everything and destroy all active environments
	@echo "→ Destroying all active environments..."
	@for f in envs/*.json; do \
		[[ -f "$$f" ]] || continue; \
		ENV_ID=$$(python3 -c "import json; print(json.load(open('$$f'))['id'])"); \
		echo "  Destroying $$ENV_ID..."; \
		bash $(PLATFORM)/destroy_env.sh "$$ENV_ID" || true; \
	done
	@echo "→ Stopping platform services..."
	docker compose down
	@echo "→ Killing daemon and poller..."
	pkill -f cleanup_daemon.sh 2>/dev/null || true
	pkill -f health_poller.py  2>/dev/null || true
	@echo "✓ Platform stopped"

# ── Environment management ────────────────────────────────────────────────────

.PHONY: create
create: ## Create a new environment (prompts for name and TTL)
	@read -p "Environment name: " NAME; \
	read -p "TTL in seconds [1800]: " TTL; \
	TTL=$${TTL:-1800}; \
	bash $(PLATFORM)/create_env.sh "$$NAME" "$$TTL"

.PHONY: destroy
destroy: ## Destroy a specific environment  (usage: make destroy ENV=env-abc123)
ifndef ENV
	$(error ENV is required. Usage: make destroy ENV=env-abc123)
endif
	bash $(PLATFORM)/destroy_env.sh "$(ENV)"

# ── Observability ─────────────────────────────────────────────────────────────

.PHONY: logs
logs: ## Tail application logs for an environment (usage: make logs ENV=env-abc123)
ifndef ENV
	$(error ENV is required. Usage: make logs ENV=env-abc123)
endif
	@LOG="logs/$(ENV)/app.log"; \
	ARCHIVE="logs/archived/$(ENV)/app.log"; \
	if [[ -f "$$LOG" ]]; then \
		tail -f "$$LOG"; \
	elif [[ -f "$$ARCHIVE" ]]; then \
		echo "(archived)"; tail -100 "$$ARCHIVE"; \
	else \
		echo "No log found for $(ENV)"; exit 1; \
	fi

.PHONY: health
health: ## Show health status for all active environments
	@echo "Active environment health status:"
	@echo "──────────────────────────────────────────────────────────────"
	@FOUND=0; \
	for f in envs/*.json; do \
		[[ -f "$$f" ]] || continue; FOUND=1; \
		ENV_ID=$$(python3 -c "import json; print(json.load(open('$$f'))['id'])"); \
		STATUS=$$(python3 -c "import json; print(json.load(open('$$f')).get('status','?'))"); \
		TTL_REM=$$(python3 -c "import json,time; d=json.load(open('$$f')); print(max(0,d['created_at']+d['ttl']-int(time.time())))"); \
		LAST=$$(tail -1 "logs/$$ENV_ID/health.log" 2>/dev/null || echo "no data"); \
		echo "  $$ENV_ID | status=$$STATUS | ttl_remaining=$${TTL_REM}s"; \
		echo "  last check: $$LAST"; \
		echo ""; \
	done; \
	[[ $$FOUND -eq 0 ]] && echo "  No active environments."

.PHONY: logs-platform
logs-platform: ## Tail cleanup daemon and health poller logs
	@tail -f logs/cleanup.log logs/poller.out 2>/dev/null || echo "No platform logs yet"

# ── Chaos ─────────────────────────────────────────────────────────────────────

.PHONY: simulate
simulate: ## Trigger an outage simulation (usage: make simulate ENV=env-abc123 MODE=crash)
ifndef ENV
	$(error ENV is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
ifndef MODE
	$(error MODE is required. Values: crash|pause|network|recover|stress)
endif
	bash $(PLATFORM)/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

# ── Housekeeping ──────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Wipe all state, logs, and archives (non-destructive of running containers)
	@echo "→ Wiping state and logs..."
	rm -rf envs/*.json logs/archived/* logs/*.log logs/*/
	@echo "→ Wiping Nginx env configs..."
	rm -f nginx/conf.d/env-*.conf
	@echo "✓ Clean"

.PHONY: ps
ps: ## Show all platform-related Docker containers and networks
	@echo "=== Containers ==="
	docker ps --filter "label=sandbox.managed" --format \
		"table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Label \"sandbox.env\"}}"
	@echo ""
	@echo "=== Networks ==="
	docker network ls --filter "label=sandbox.managed=true" --format \
		"table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "DevOps Sandbox Platform"
	@echo "Usage: make <target> [ENV=...] [MODE=...]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
