#!/usr/bin/env python3
"""Real suggested-model compatibility with local search; no downloads or live APIs."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from pearl_session import PrivateSession, wait_for
from test_agent_ui import Search, memory_snapshot

MODELS = [
    ("qwen3-4b-instruct-2507-q4km", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
    ("liquid-lfm25-26b-q4km", "LFM2.5-2.6B-Q4_K_M.gguf"),
    ("liquid-lfm25-12b-instruct-q4km", "LFM2.5-1.2B-Instruct-Q4_K_M.gguf"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--agent", type=Path, default=ROOT / "zig-out/test/pearl-agent-test")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--aqueous", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Search)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    report = {"scope": "Real models, CPU, local search fixtures; compatibility check, not a comparative benchmark", "models": {}}
    try:
        with PrivateSession(args.output / "session", aqueous=args.aqueous) as session:
            directory = Path(session.env["XDG_DATA_HOME"]) / "pearl/assistant/models"
            directory.mkdir(parents=True)
            for _, filename in MODELS:
                source = args.models_dir.resolve() / filename
                try:
                    os.link(source, directory / filename)
                except OSError as error:
                    if error.errno != 18:
                        raise
                    shutil.copyfile(source, directory / filename)
            parent, child = socket.socketpair()
            parent.settimeout(15)
            with (args.output / "agent.log").open("w") as log:
                proc = subprocess.Popen([str(args.agent.resolve()), "--shell-fd=3"], env=session.env,
                    pass_fds=tuple({3, child.fileno()}), preexec_fn=lambda: os.dup2(child.fileno(), 3), stdout=log, stderr=log)
                child.close()
                reader = parent.makefile("rb")
                seq = 0
                def request(op, **kwargs):
                    nonlocal seq
                    seq += 1
                    parent.sendall(json.dumps(dict(agent=1, id=seq, op=op, **kwargs)).encode() + b"\n")
                    while True:
                        line = reader.readline()
                        assert line, (proc.poll(), (args.output / "agent.log").read_text())
                        reply = json.loads(line)
                        if reply["id"] == seq:
                            assert reply["ok"], reply
                            return reply.get("state")
                def idle():
                    return wait_for(lambda: (value if not (value := request("test_state"))["busy"] else False), 930)
                try:
                    for model_id, _ in MODELS:
                        started = time.monotonic()
                        before = len(Search.requests)
                        config = dict(enabled=True, model_id=model_id, read_pages=False, default_provider_id="google",
                            runtime=dict(source="custom", executable=str(args.runtime.resolve())),
                            providers=[dict(id="google", kind="google", endpoint=f"http://127.0.0.1:{server.server_port}")])
                        request("ask", config=config, question="What is the difference between RAM and storage?")
                        state = idle()
                        result = dict(state=state, seconds=round(time.monotonic() - started, 3), memory=memory_snapshot(proc.pid), search_requests=len(Search.requests) - before)
                        answer = state["turns"][0]["answer"] if state["turns"] else ""
                        result["passed"] = not state["error_code"] and "[1]" in answer and "<think>" not in answer and len(Search.requests) > before
                        if result["passed"]:
                            request("test_submit", question="Will adding RAM give me more space for saved files? Use the existing evidence.")
                            followup = idle()
                            result["followup"] = followup
                            result["followup_cited"] = len(followup["turns"]) == 2 and "[1]" in followup["turns"][1]["answer"]
                            # A checked results-only fallback is an allowed
                            # outcome; record it separately from a cited answer.
                            result["passed"] = len(followup["turns"]) == 2 and not followup["error_code"] and (result["followup_cited"] or "could not produce a valid source-cited summary" in followup["turns"][1]["answer"])
                        report["models"][model_id] = result
                        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                        print(model_id, "PASS" if result["passed"] else "FAIL", state["error_code"], flush=True)
                        request("release_runtime")
                    request("clear")
                finally:
                    reader.close()
                    parent.close()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        assert all(item["passed"] for item in report["models"].values()), report
    finally:
        server.shutdown()
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
