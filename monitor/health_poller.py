#!/usr/bin/env python3
"""
monitor/health_poller.py — Poll active environment /health endpoints every 30s.
Marks environments as 'degraded' after 3 consecutive failures.
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

ROOT_DIR = Path(__file__).resolve().parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
POLL_INTERVAL = 30
FAILURE_THRESHOLD = 3

# Track consecutive failures per env in memory
failure_counts: dict[str, int] = {}


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state(state_file: Path) -> dict | None:
    try:
        with open(state_file) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def update_status(state_file: Path, new_status: str) -> None:
    try:
        state = load_state(state_file)
        if state is None:
            return
        state["status"] = new_status
        tmp = state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2))
        tmp.rename(state_file)
    except OSError as e:
        print(f"[{utc_now()}] ERROR: Could not update state for {state_file.stem}: {e}",
              file=sys.stderr)


def poll_env(state: dict, state_file: Path) -> None:
    env_id = state["id"]
    host_port = state.get("host_port")
    current_status = state.get("status", "unknown")

    if current_status in ("destroyed", "crashed", "paused", "network-isolated"):
        return  # Don't poll envs that are intentionally offline

    if not host_port:
        return

    health_log = LOGS_DIR / env_id / "health.log"
    health_log.parent.mkdir(parents=True, exist_ok=True)

    url = f"http://localhost:{host_port}/health"
    start = time.monotonic()
    http_status = 0
    error_msg = ""

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "sandbox-health-poller/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            http_status = resp.status
    except urllib.error.HTTPError as e:
        http_status = e.code
        error_msg = str(e)
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        http_status = 0
        error_msg = str(e)

    latency_ms = round((time.monotonic() - start) * 1000, 1)
    success = 200 <= http_status < 400

    record = {
        "timestamp": utc_now(),
        "env_id": env_id,
        "http_status": http_status,
        "latency_ms": latency_ms,
        "ok": success,
    }
    if error_msg:
        record["error"] = error_msg

    with open(health_log, "a") as f:
        f.write(json.dumps(record) + "\n")

    if success:
        if failure_counts.get(env_id, 0) > 0:
            print(f"[{utc_now()}] RECOVERED: {env_id} is healthy again")
            update_status(state_file, "running")
        failure_counts[env_id] = 0
    else:
        failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
        count = failure_counts[env_id]
        print(f"[{utc_now()}] FAIL ({count}/{FAILURE_THRESHOLD}): {env_id} "
              f"— HTTP {http_status} ({latency_ms}ms){' — ' + error_msg if error_msg else ''}")

        if count >= FAILURE_THRESHOLD:
            print(f"[{utc_now()}] ⚠ DEGRADED: {env_id} has failed {count} consecutive checks")
            if current_status not in ("degraded", "crashed", "paused"):
                update_status(state_file, "degraded")


def main() -> None:
    print(f"[{utc_now()}] Health poller started (interval: {POLL_INTERVAL}s, "
          f"threshold: {FAILURE_THRESHOLD})")

    ENVS_DIR.mkdir(parents=True, exist_ok=True)

    while True:
        state_files = list(ENVS_DIR.glob("*.json"))

        if not state_files:
            time.sleep(POLL_INTERVAL)
            continue

        for state_file in state_files:
            state = load_state(state_file)
            if state:
                try:
                    poll_env(state, state_file)
                except Exception as e:
                    print(f"[{utc_now()}] ERROR polling {state_file.stem}: {e}",
                          file=sys.stderr)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
