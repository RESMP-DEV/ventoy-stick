#!/usr/bin/env python3
"""Linux launcher for ccr-rust; direct port of the Mac serve.py / serve-glm-workers.py pair.

Usage: ccr-serve main    -> config.json    on 127.0.0.1:3456 (zai+azure+minimax)
       ccr-serve workers -> glm-workers.json on 127.0.0.1:3457 (GLM-only, native Responses)

Credentials stay in ~/.claude-code-router/runtime-credentials.json (mode 0600 enforced).
"""
import json
import os
import sys
from pathlib import Path

root = Path.home() / ".claude-code-router"
credentials = root / "runtime-credentials.json"

mode = sys.argv[1] if len(sys.argv) > 1 else "workers"
if mode not in ("main", "workers"):
    raise SystemExit(f"unknown mode: {mode}")

if not credentials.exists():
    raise SystemExit("missing runtime-credentials.json (run bootstrap --finish-secrets)")
if credentials.stat().st_mode & 0o077:
    raise SystemExit("runtime-credentials.json must be mode 0600")

values = json.loads(credentials.read_text())
env = os.environ.copy()

if mode == "main":
    for name in ("CCR_ZAI_API_KEY", "CCR_AZURE_API_KEY", "CCR_MINIMAX_API_KEY"):
        v = values.get(name)
        if not isinstance(v, str) or not v:
            raise SystemExit(f"Invalid runtime credential entry: {name}")
        env[name] = v
    config = root / "config.json"
    args = ["start", "--host", "127.0.0.1", "--port", "3456"]
else:
    key = values.get("CCR_ZAI_API_KEY")
    if not isinstance(key, str) or not key:
        raise SystemExit("Missing CCR_ZAI_API_KEY")
    env["CCR_ZAI_API_KEY"] = key
    config = root / "glm-workers.json"
    args = ["start", "--host", "127.0.0.1", "--port", "3457"]

binary = str(Path.home() / ".cargo/bin/ccr-rust")
os.execve(binary, [binary, "--config", str(config), *args], env)
