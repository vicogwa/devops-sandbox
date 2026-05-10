# devops-sandbox

A self-service platform for spinning up isolated, short-lived application environments on a single Linux VM. Each environment gets its own Docker network, a dynamically registered Nginx route, forwarded logs, and a health monitor. A TTL-based cleanup daemon reaps expired environments automatically. A chaos engineering mode lets you inject failures and observe recovery.

Think of it as a stripped-down internal Heroku with a chaos toggle — built entirely with Docker, Bash, Python, and Nginx.

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │               Linux VM                      │
                        │                                             │
  Browser / curl        │   ┌──────────────────────────────────────┐  │
      │                 │   │          Nginx (Docker)               │  │
      └────── :80 ──────┼──►│  /env-abc123/ → localhost:8101       │  │
                        │   │  /env-def456/ → localhost:8102       │  │
                        │   │  /api/        → localhost:5050       │  │
                        │   └──────────┬──────────────────────────┘  │
                        │              │ conf.d/*.conf (auto-written) │
                        │              │                              │
                        │   ┌──────────▼──────────────────────────┐  │
                        │   │        Control API (Flask)           │  │
                        │   │        localhost:5050                │  │
                        │   │   POST /envs → create_env.sh        │  │
                        │   │   DELETE /envs/:id → destroy_env.sh │  │
                        │   │   POST /envs/:id/outage             │  │
                        │   └──────────────────────────────────────┘  │
                        │                                             │
                        │   ┌──────────────────────────────────────┐  │
                        │   │     Cleanup Daemon (Bash loop)       │  │
                        │   │     Runs every 60s                   │  │
                        │   │     Destroys expired envs by TTL     │  │
                        │   └──────────────────────────────────────┘  │
                        │                                             │
                        │   ┌──────────────────────────────────────┐  │
                        │   │     Health Poller (Python)           │  │
                        │   │     Polls /health every 30s          │  │
                        │   │     Marks env 'degraded' after 3     │  │
                        │   │     consecutive failures             │  │
                        │   └──────────────────────────────────────┘  │
                        │                                             │
                        │   ┌─────────────┐   ┌─────────────┐       │
                        │   │  app-env-   │   │  app-env-   │       │
                        │   │  abc123     │   │  def456     │  ...  │
                        │   │  :8101      │   │  :8102      │       │
                        │   │  net-env-   │   │  net-env-   │       │
                        │   │  abc123     │   │  def456     │       │
                        │   └─────────────┘   └─────────────┘       │
                        │                                             │
                        │   State: envs/<id>.json  Logs: logs/<id>/  │
                        └─────────────────────────────────────────────┘
```

### Key design decisions

**Dynamic port allocation** — `create_env.sh` scans upward from `PLATFORM_BASE_PORT` (default 8100) to find the next available host port. No port collisions, no hardcoded values.

**Nginx as the front door** — every environment gets a `conf.d/<id>.conf` written at creation time and deleted on destroy. Nginx reloads after each operation. The container itself never restarts.

**Atomic state writes** — all state file updates go through a `write-to-tmp → mv` pattern. A half-written JSON file is never left behind if the process is interrupted.

**Log-shipping via `docker logs -f`** — the PID is stored in the state file and killed on destroy. No zombie `docker logs` processes.

**Safety guard on chaos** — `simulate_outage.sh` checks the `sandbox.managed` label and refuses to run against any container that isn't a user environment. The Nginx and API containers are explicitly named in a blocklist as a second layer.

---

## Prerequisites

- Linux VM (Ubuntu 22.04+ recommended), single machine
- Docker Engine 24+ and Docker Compose v2
- Python 3.10+
- `bash`, `make`, `openssl`, `ss` (iproute2)
- Ports 80 and 5050 available on the host

---

## Quick start

From zero to a running environment in under 5 commands:

```bash
# 1. Clone and enter the repo
git clone https://github.com/YOUR_USERNAME/devops-sandbox.git && cd devops-sandbox

# 2. Bootstrap config and build images
make init && make build

# 3. Start the platform
make up

# 4. Create your first environment
make create
# → prompts: name=myapp, TTL=300

# 5. Hit the environment
curl http://localhost/env-myapp-<id>/
```

The API is also available directly:

```bash
curl -X POST http://localhost:5050/envs \
  -H "Content-Type: application/json" \
  -d '{"name": "myapp", "ttl": 300}'
```

---

## Full demo walkthrough

### 1. Create an environment

```bash
make create
# name: demo
# ttl: 300

# Output:
# ✓ Environment ready
#   ID:      env-demo-a1b2c3d4
#   URL:     http://localhost/env-demo-a1b2c3d4/
#   TTL:     300s (expires 2024-01-15T10:05:00Z)
```

### 2. Deploy / verify the app

```bash
curl http://localhost/env-demo-a1b2c3d4/
# {"message":"Hello from sandbox environment: demo","env_id":"env-demo-a1b2c3d4","uptime":3}

curl http://localhost/env-demo-a1b2c3d4/health
# {"status":"ok","env_id":"env-demo-a1b2c3d4","uptime":6,"time":"2024-01-15T10:00:06Z"}
```

### 3. Check health status

```bash
make health

# Active environment health status:
# ──────────────────────────────────────────────────────────────
#   env-demo-a1b2c3d4 | status=running | ttl_remaining=284s
#   last check: {"timestamp":"...","http_status":200,"latency_ms":4.2,"ok":true}
```

Or via the API:

```bash
curl http://localhost:5050/envs/env-demo-a1b2c3d4/health
```

### 4. Simulate an outage

```bash
make simulate ENV=env-demo-a1b2c3d4 MODE=crash

# Simulation 'crash' applied to env-demo-a1b2c3d4 (app-env-demo-a1b2c3d4)
```

### 5. Observe degraded state

Wait ~90 seconds. The health poller will detect the crash and mark the env degraded:

```bash
make health
# env-demo-a1b2c3d4 | status=degraded | ttl_remaining=195s
# last check: {"timestamp":"...","http_status":0,"latency_ms":5001.0,"ok":false,"error":"..."}
```

Or watch the poller output live:

```bash
tail -f logs/poller.out
# [2024-01-15T10:01:30Z] FAIL (1/3): env-demo-a1b2c3d4 — HTTP 0
# [2024-01-15T10:02:00Z] FAIL (2/3): env-demo-a1b2c3d4 — HTTP 0
# [2024-01-15T10:02:30Z] FAIL (3/3): env-demo-a1b2c3d4 — HTTP 0
# [2024-01-15T10:02:30Z] ⚠ DEGRADED: env-demo-a1b2c3d4 has failed 3 consecutive checks
```

### 6. Recover

```bash
make simulate ENV=env-demo-a1b2c3d4 MODE=recover
# → Restarts the container

# Next health poll will mark it running again
make health
# env-demo-a1b2c3d4 | status=running | ttl_remaining=130s
```

### 7. Auto-destroy on TTL expiry

Once the TTL elapses, the cleanup daemon destroys the environment automatically:

```bash
tail -f logs/cleanup.log
# [2024-01-15T10:05:00Z] TTL expired for env-demo-a1b2c3d4 (was: running, overdue by 2s) — destroying
# [2024-01-15T10:05:01Z] Killed log forwarder PID 18432
# [2024-01-15T10:05:01Z] Removed containers for env-demo-a1b2c3d4
# [2024-01-15T10:05:02Z] Removed network net-env-demo-a1b2c3d4
# [2024-01-15T10:05:02Z] Nginx reloaded after removing env-demo-a1b2c3d4
# [2024-01-15T10:05:02Z] Logs archived to logs/archived/env-demo-a1b2c3d4
# [2024-01-15T10:05:02Z] Environment env-demo-a1b2c3d4 destroyed successfully
```

### Manual destroy

```bash
make destroy ENV=env-demo-a1b2c3d4
```

---

## API reference

| Method   | Path                    | Body                        | Description                        |
|----------|-------------------------|-----------------------------|------------------------------------|
| `POST`   | `/envs`                 | `{"name":"x","ttl":300}`    | Create environment                 |
| `GET`    | `/envs`                 | —                           | List active envs with TTL remaining|
| `DELETE` | `/envs/:id`             | —                           | Destroy environment                |
| `GET`    | `/envs/:id/logs`        | —                           | Last 100 lines of `app.log`        |
| `GET`    | `/envs/:id/health`      | —                           | Last 10 health check records       |
| `POST`   | `/envs/:id/outage`      | `{"mode":"crash"}`          | Trigger chaos simulation           |

Outage modes: `crash`, `pause`, `network`, `recover`, `stress`

---

## Makefile targets

```
make up                       Start Nginx + daemon + API + health poller
make down                     Stop everything, destroy all envs
make build                    Build Docker images
make init                     Initialize directories and .env
make create                   Create new env (interactive prompt)
make destroy ENV=<id>         Destroy specific env
make logs ENV=<id>            Tail env application logs
make health                   Show all env health statuses
make simulate ENV=<id> MODE=<mode>   Run outage simulation
make ps                       Show platform containers and networks
make logs-platform            Tail daemon and poller logs
make clean                    Wipe all state, logs, and archives
```

---

## Environment state file

Each environment is represented as a JSON file at `envs/<id>.json`:

```json
{
  "id": "env-myapp-a1b2c3d4",
  "name": "myapp",
  "container": "app-env-myapp-a1b2c3d4",
  "network": "net-env-myapp-a1b2c3d4",
  "host_port": 8101,
  "created_at": 1705312800,
  "ttl": 1800,
  "status": "running",
  "log_pid": 18432
}
```

Status values: `running`, `degraded`, `crashed`, `paused`, `network-isolated`, `stressed`

---

## Log structure

```
logs/
├── cleanup.log              Daemon activity log
├── poller.out               Health poller stdout
├── daemon.out               Cleanup daemon stdout
├── <env-id>/
│   ├── app.log              Forwarded container stdout/stderr
│   └── health.log           JSONL health check records
└── archived/
    └── <env-id>/            Copied here on destroy, never purged automatically
```

---

## Known limitations

- **Single host only.** The port-mapping approach assumes all app containers and the Nginx container live on the same VM. No distributed mode.
- **`docker logs -f` PID tracking is best-effort.** If the API container is restarted mid-session, the log-shipping PID stored in state will be stale. The log forwarder won't be restarted automatically. A proper solution would use Loki or Fluentd (Approach B).
- **Nginx reload on every create/destroy.** On high-frequency creation, this becomes a bottleneck. For >50 concurrent environments, switch to `nginx -s reload` with a debounce or a dedicated nginx-manager process.
- **No authentication on the API.** All endpoints are open. Intended for internal/demo use only — add basic auth or a token header before exposing externally.
- **`stress` mode requires `stress-ng` in the app container.** The demo app image does not install it by default. Add it to `demo-app/Dockerfile` if you want to test CPU stress.
- **TTL precision is ±60s** because the daemon sleeps between passes. A 30-minute TTL expires somewhere between 30:00 and 31:00 minutes.
- **Date parsing uses GNU `date`** (Linux). On macOS, `date -d` doesn't exist. The platform is Linux-only by design.
