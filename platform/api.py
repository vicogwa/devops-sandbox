#!/usr/bin/env python3
"""
platform/api.py — Control plane API for the DevOps sandbox platform.

Endpoints:
  POST   /envs              Create environment
  GET    /envs              List active environments with TTL remaining
  DELETE /envs/:id          Destroy environment
  GET    /envs/:id/logs     Last 100 lines of app.log
  GET    /envs/:id/health   Last 10 health check records
  POST   /envs/:id/outage   Trigger outage simulation
"""

import json
import os
import subprocess
import time
from pathlib import Path
from collections import deque

from flask import Flask, jsonify, request, abort

ROOT_DIR = Path(__file__).resolve().parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM_DIR = ROOT_DIR / "platform"

app = Flask(__name__)
app.config["JSON_SORT_KEYS"] = False


# ── Helpers ───────────────────────────────────────────────────────────────────

def load_all_states() -> list[dict]:
    states = []
    for f in ENVS_DIR.glob("*.json"):
        try:
            states.append(json.loads(f.read_text()))
        except (json.JSONDecodeError, OSError):
            continue
    return states


def load_state(env_id: str) -> dict | None:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return None
    try:
        return json.loads(state_file.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def ttl_remaining(state: dict) -> int:
    return max(0, state["created_at"] + state["ttl"] - int(time.time()))


def run_script(script: str, *args: str) -> tuple[int, str, str]:
    script_path = PLATFORM_DIR / script
    result = subprocess.run(
        ["bash", str(script_path), *args],
        capture_output=True,
        text=True,
        cwd=str(ROOT_DIR),
    )
    return result.returncode, result.stdout, result.stderr


def tail_file(path: Path, n: int) -> list[str]:
    if not path.exists():
        return []
    try:
        lines = path.read_text().splitlines()
        return list(deque(lines, maxlen=n))
    except OSError:
        return []


# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/envs")
def create_env():
    body = request.get_json(silent=True) or {}
    name = body.get("name", "").strip()
    ttl = body.get("ttl", int(os.getenv("DEFAULT_TTL", 1800)))

    if not name:
        abort(400, description="'name' is required")

    if not isinstance(ttl, int) or ttl < 60:
        abort(400, description="'ttl' must be an integer >= 60")

    returncode, stdout, stderr = run_script("create_env.sh", name, str(ttl))

    if returncode != 0:
        return jsonify({"error": "Failed to create environment", "detail": stderr}), 500

    # Parse env ID from output
    env_id = None
    for line in stdout.splitlines():
        if "ID:" in line:
            env_id = line.split("ID:")[-1].strip()
            break

    state = load_state(env_id) if env_id else None
    return jsonify({
        "id": env_id,
        "ttl_remaining": ttl_remaining(state) if state else ttl,
        "url": next((l.split("URL:")[-1].strip() for l in stdout.splitlines() if "URL:" in l), None),
        "output": stdout,
    }), 201


@app.get("/envs")
def list_envs():
    states = load_all_states()
    now = int(time.time())
    result = []
    for s in sorted(states, key=lambda x: x["created_at"]):
        result.append({
            "id": s["id"],
            "name": s["name"],
            "status": s.get("status", "unknown"),
            "ttl_remaining": ttl_remaining(s),
            "expires_at": s["created_at"] + s["ttl"],
            "host_port": s.get("host_port"),
        })
    return jsonify(result)


@app.delete("/envs/<env_id>")
def destroy_env(env_id: str):
    if not load_state(env_id):
        abort(404, description=f"Environment {env_id} not found")

    returncode, stdout, stderr = run_script("destroy_env.sh", env_id)
    if returncode != 0:
        return jsonify({"error": "Destroy failed", "detail": stderr}), 500

    return jsonify({"destroyed": env_id, "output": stdout})


@app.get("/envs/<env_id>/logs")
def get_logs(env_id: str):
    if not load_state(env_id):
        # Check archives too
        archive_log = LOGS_DIR / "archived" / env_id / "app.log"
        log_file = archive_log
    else:
        log_file = LOGS_DIR / env_id / "app.log"

    lines = tail_file(log_file, 100)
    return jsonify({"env_id": env_id, "lines": lines, "count": len(lines)})


@app.get("/envs/<env_id>/health")
def get_health(env_id: str):
    health_log = LOGS_DIR / env_id / "health.log"
    lines = tail_file(health_log, 10)

    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            records.append({"raw": line})

    state = load_state(env_id)
    return jsonify({
        "env_id": env_id,
        "status": state.get("status", "unknown") if state else "unknown",
        "last_checks": records,
    })


@app.post("/envs/<env_id>/outage")
def trigger_outage(env_id: str):
    if not load_state(env_id):
        abort(404, description=f"Environment {env_id} not found")

    body = request.get_json(silent=True) or {}
    mode = body.get("mode", "").strip()
    valid_modes = ("crash", "pause", "network", "recover", "stress")

    if mode not in valid_modes:
        abort(400, description=f"'mode' must be one of: {', '.join(valid_modes)}")

    returncode, stdout, stderr = run_script(
        "simulate_outage.sh", "--env", env_id, "--mode", mode
    )

    if returncode == 2:
        return jsonify({"error": "Safety guard triggered", "detail": stderr}), 403
    if returncode != 0:
        return jsonify({"error": "Simulation failed", "detail": stderr}), 500

    return jsonify({"env_id": env_id, "mode": mode, "output": stdout})


# ── Error handlers ────────────────────────────────────────────────────────────

@app.errorhandler(400)
@app.errorhandler(403)
@app.errorhandler(404)
@app.errorhandler(500)
def handle_error(e):
    return jsonify({"error": e.description}), e.code


# ── Entrypoint ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ENVS_DIR.mkdir(parents=True, exist_ok=True)
    port = int(os.getenv("API_PORT", 5050))
    app.run(host="0.0.0.0", port=port, debug=False)