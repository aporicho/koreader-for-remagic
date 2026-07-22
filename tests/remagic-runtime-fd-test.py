#!/usr/bin/env python3
"""Exercise the production LuaJIT lifecycle FD path over SOCK_SEQPACKET."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile


def fail(message: str, process: subprocess.CompletedProcess[str] | None = None) -> None:
    if process is not None:
        if process.stdout:
            print(process.stdout, file=sys.stderr, end="")
        if process.stderr:
            print(process.stderr, file=sys.stderr, end="")
    raise SystemExit(f"FAIL: {message}")


if len(sys.argv) != 4:
    fail("usage: remagic-runtime-fd-test.py LUAJIT MOCK PATCH")

luajit, mock, patch = sys.argv[1:]
parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
parent.setblocking(False)
child.setblocking(True)

generation = 3719679425990660
command = {
    "protocol": 2,
    "request_id": "direct-fd-background",
    "body": {
        "command": "enter_background",
        "app_id": "koreader",
        "generation": generation,
        "foreground_epoch": 1,
    },
}
parent.send((json.dumps(command, separators=(",", ":")) + "\n").encode())

with tempfile.TemporaryDirectory() as runtime:
    environment = os.environ.copy()
    environment.update(
        REMAGIC_APP_PID="4321",
        REMAGIC_APP_GENERATION=str(generation),
        REMAGIC_RUNTIME_DIR=runtime,
        REMAGIC_LIFECYCLE_FD=str(child.fileno()),
        REMAGIC_KOREADER_POLL_SECONDS="0.05",
        REMAGIC_KOREADER_LIFECYCLE_HELPER=str(
            Path(patch).resolve().parent.parent / "scripts" / "koreader-lifecycle"
        ),
    )
    try:
        result = subprocess.run(
            [luajit, mock, patch, "direct_fd"],
            env=environment,
            pass_fds=(child.fileno(),),
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        fail(f"LuaJIT blocked while polling the lifecycle FD: {error}")
    finally:
        child.close()

    if result.returncode != 0:
        fail(f"LuaJIT direct-FD mock returned {result.returncode}", result)
    if Path(runtime, "koreader-ready").exists():
        fail("direct-FD transport created a legacy readiness marker", result)

frames: list[dict[str, object]] = []
while True:
    try:
        payload = parent.recv(256 * 1024)
    except BlockingIOError:
        continue
    if not payload:
        break
    for line in payload.decode().splitlines():
        frames.append(json.loads(line))
parent.close()

events = [frame.get("body", {}).get("event") for frame in frames]
for required in ("ready", "state_saved", "background_ready"):
    if required not in events:
        fail(f"direct-FD lifecycle output omitted {required}: {events}")

print("remagic runtime direct-FD LuaJIT test passed")
