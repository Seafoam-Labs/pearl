#!/usr/bin/env python3
"""Assistant acceptance in private HOME, D-Bus and headless Wayland.

Uses a local search fixture and an explicitly supplied GGUF. No live provider,
user credentials, or model downloads. The real runtime must already be staged.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC, capture


def memory_snapshot(pid):
    """RSS/HWM for this test's owned process tree, not system-wide memory."""
    queue, seen, rows = [pid], set(), []
    while queue:
        current = queue.pop()
        if current in seen:
            continue
        seen.add(current)
        root = Path(f"/proc/{current}")
        try:
            fields = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines() if ":" in line)
            rows.append({"role": "agent" if current == pid else "runtime", "rss_kib": int(fields["VmRSS"].split()[0]), "high_water_kib": int(fields["VmHWM"].split()[0]), "threads": int(fields["Threads"])})
            for task in (root / "task").iterdir():
                queue += [int(v) for v in (task / "children").read_text().split()]
        except (FileNotFoundError, KeyError):
            pass
    return rows


class Search(http.server.BaseHTTPRequestHandler):
    requests = []

    def do_GET(self):
        self.requests.append(self.path)
        assert "engines=google" in self.path, self.path
        body = json.dumps({"results": [{"title": "Memory and storage", "url": "https://example.org/memory", "content": "RAM holds working data temporarily and loses contents when power is removed. Storage retains saved files between sessions."}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--agent", type=Path, default=ROOT / "zig-out/test/pearl-agent-test")
    p.add_argument("--model", type=Path, required=True)
    p.add_argument("--runtime", type=Path, help="Use this local llama-server instead of the Pearl package")
    p.add_argument("--aqueous", type=Path)
    p.add_argument("--output", type=Path, default=ROOT / "artifacts/assistant/latest")
    args = p.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Search)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    report = {"status": "running", "checks": {}}
    checks = report["checks"]
    try:
        with PrivateSession(args.output / "session", aqueous=args.aqueous) as session:
            model_dir = Path(session.env["XDG_DATA_HOME"]) / "pearl/assistant/models"
            model_dir.mkdir(parents=True)
            os.link(args.model.resolve(), model_dir / "LFM2.5-350M-Q4_K_M.gguf")
            parent, child = socket.socketpair()
            parent.settimeout(10)
            log = (args.output / "agent.log").open("w")
            process = subprocess.Popen([str(args.agent.resolve()), "--shell-fd=3"],
                env=dict(session.env, G_DEBUG="fatal-warnings"),
                pass_fds=tuple({3, child.fileno()}),
                preexec_fn=lambda: os.dup2(child.fileno(), 3),
                stdout=log, stderr=log)
            child.close()
            reader = parent.makefile("rb")
            seq = 0

            def request(op, **kwargs):
                nonlocal seq
                seq += 1
                parent.sendall(json.dumps(dict(agent=1, id=seq, op=op, **kwargs)).encode() + b"\n")
                value = json.loads(reader.readline())
                while value["id"] == 0:
                    value = json.loads(reader.readline())
                assert value["id"] == seq and value["ok"], value
                return value.get("state")

            def state():
                if process.poll() is not None:
                    raise AssertionError(("agent exited", process.returncode, (args.output / "agent.log").read_text()))
                return request("test_state")

            try:
                initial = state()
                assert not initial["visible"] and not initial["runtime"] and not Search.requests, initial
                checks["no_inference_or_network_before_ask"] = True
                config = dict(enabled=True, read_pages=False, idle_unload_seconds=15, default_provider_id="google",
                    runtime=dict(source="custom", executable=str(args.runtime.resolve())) if args.runtime else dict(source="packaged"),
                    providers=[dict(id="google", kind="google", name="Google", endpoint=f"http://127.0.0.1:{server.server_port}")])
                started = time.monotonic()
                request("ask", question="What is the difference between RAM and storage?", config=config)
                result = wait_for(lambda: (v if not (v := state())["busy"] else False), 90)
                assert len(result["turns"]) == 1 and result["sources"] == 1, result
                assert Search.requests, result
                assert "[1]" in result["turns"][0]["answer"], result
                checks["real_model_google_tool_round_trip"] = result
                report["fixture_measurements"] = {"cold_answer_seconds": round(time.monotonic() - started, 3), "processes_after_answer": memory_snapshot(process.pid), "scope": "Local search fixture on this test host; not low-end hardware qualification."}
                ipc = IPC(session)
                windows = [w for w in ipc.state() if w["kind"] == "window" and w.get("app_id") == "org.aqueous.Pearl.Agent"]
                assert len(windows) == 1, windows
                assert windows[0]["floating"], windows
                assert windows[0]["geometry"]["width"] < 700, windows
                checks["floating_native_window"] = windows[0]["geometry"]
                capture(session, args.output / "conversation")
                request("test_submit", question="Will adding RAM give me more space for saved files?")
                followup = wait_for(lambda: (v if not (v := state())["busy"] else False), 90)
                assert len(followup["turns"]) == 2, followup
                checks["followup_preserves_session_history"] = followup
                request("test_hide")
                assert not state()["visible"]
                request("resume", config=config)
                assert state()["visible"] and len(state()["turns"]) == 2
                checks["hide_and_resume_preserves_history"] = True
                request("test_submit", question="Explain the difference in more detail.")
                request("suspend")
                locked = wait_for(lambda: (v if not (v := state())["busy"] else False), 15)
                assert locked["suspended"] and not locked["visible"] and not locked["runtime"], locked
                checks["lock_cancels_and_unloads"] = True
                request("resume", config=config)
                assert not state()["suspended"]
                request("clear")
                assert not state()["turns"] and not state()["runtime"]
                checks["clear_erases_history"] = True
                request("ask", question="What is RAM?", config=config)
                wait_for(lambda: state()["busy"], 5)
                request("clear")
                cleared = wait_for(lambda: (v if not (v := state())["busy"] else False), 15)
                assert not cleared["turns"] and cleared["draft_chars"] == 0 and cleared["sources"] == 0, cleared
                checks["clear_during_work_does_not_restore_erased_prompt"] = True
                request("ask", question="What is RAM?", config=config)
                wait_for(lambda: state()["busy"], 5)
                reader.close()
                parent.close()
                process.wait(timeout=10)
                assert process.returncode == 0, process.returncode
                checks["parent_disconnect_exits"] = True
            finally:
                reader.close()
                parent.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                log.close()
        report["status"] = "passed"
    finally:
        server.shutdown()
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
