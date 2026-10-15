#!/usr/bin/env python3
"""Runtime protocol/failure tests. GPU devices and offload are simulated."""
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
from test_agent_ui import Search

class RuntimeSearch(Search):
    def do_GET(self):
        if "empty" not in self.path:
            return super().do_GET()
        self.requests.append(self.path)
        body = b'{"results":[]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--agent", type=Path, default=ROOT / "zig-out/test/pearl-agent-test")
    parser.add_argument("--aqueous", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/assistant/gpu-runtime/protocol")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RuntimeSearch)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    checks = {}
    report = {"status": "running", "scope": "Simulated runtime/device contract, not physical GPU qualification", "checks": checks}
    try:
        with PrivateSession(args.output / "session", aqueous=args.aqueous) as session:
            models = Path(session.env["XDG_DATA_HOME"]) / "pearl/assistant/models"
            models.mkdir(parents=True)
            os.link(args.model.resolve(), models / "LFM2.5-350M-Q4_K_M.gguf")
            parent, child = socket.socketpair()
            parent.settimeout(15)
            log = (args.output / "agent.log").open("w")
            proc = subprocess.Popen([str(args.agent.resolve()), "--shell-fd=3"], env=session.env,
                pass_fds=tuple({3, child.fileno()}), preexec_fn=lambda: os.dup2(child.fileno(), 3), stdout=log, stderr=log)
            child.close()
            reader = parent.makefile("rb")
            seq = 0
            latest = {}
            def request(op, **kw):
                nonlocal seq, latest
                seq += 1
                parent.sendall(json.dumps(dict(agent=1, id=seq, op=op, **kw)).encode() + b"\n")
                while True:
                    line = reader.readline()
                    assert line, (proc.poll(), (args.output / "agent.log").read_text())
                    reply = json.loads(line)
                    if reply.get("compute"):
                        latest = reply["compute"]
                    if reply["id"] == seq:
                        assert reply["ok"], reply
                        return reply.get("state")
            def idle():
                return wait_for(lambda: (v if not (v := request("test_state"))["busy"] else False), 30)
            def config(scenario, mode="gpu", fallback=True):
                location = session.base / "runtime with spaces"
                location.mkdir(exist_ok=True)
                executable = location / scenario
                shutil.copyfile(Path(__file__).with_name("fake_llama_server.py"), executable)
                executable.chmod(0o755)
                return dict(enabled=True, read_pages=False, default_provider_id="google", runtime=dict(source="custom", executable=str(executable)),
                    compute=dict(mode=mode, backend="vulkan", device_id="vulkan:NVIDIA Fixture:8192", allow_cpu_fallback=fallback),
                    providers=[dict(id="google", kind="google", endpoint=f"http://127.0.0.1:{server.server_port}")])
            try:
                assert not request("test_state")["runtime"] and not Search.requests
                checks["disabled_no_runtime_or_search"] = True
                for scenario in ("threads_explicit", "threads_automatic"):
                    selected = config(scenario, mode="cpu")
                    if scenario == "threads_explicit":
                        selected.update(cpu_threads=8, context_tokens=16384, answer_tokens=2048)
                    request("ask", config=selected, question="Find fixture GPU failure evidence?")
                    state = idle()
                    assert len(state["turns"]) == 1 and "[1]" in state["turns"][0]["answer"], state
                    assert not latest["enforced_memory"], latest
                    checks[scenario] = True
                    request("release_runtime")
                for scenario, expected_calls in [("fallback_search", 3), ("fallback_repair", 4), ("fallback_invalid", 4), ("fallback_empty", 2), ("fallback_repeat", 4)]:
                    selected = config(scenario, mode="cpu")
                    question = "What does fixture fallback search say about RAM and storage?"
                    if scenario == "fallback_empty":
                        question += " empty"
                    before = len(Search.requests)
                    request("ask", config=selected, question=question)
                    state = idle()
                    assert not state["error_code"] and len(state["turns"]) == 1, state
                    answer = state["turns"][0]["answer"]
                    if scenario == "fallback_empty":
                        assert "No usable search results" in answer, state
                    elif scenario == "fallback_invalid":
                        assert "could not produce a valid source-cited summary" in answer and "[99]" not in answer, state
                    else:
                        assert answer == "RAM is temporary working memory; storage retains files. [1]", state
                    assert len(Search.requests) == before + 1, (scenario, Search.requests)
                    requests = [json.loads(line) for line in Path(selected["runtime"]["executable"] + ".requests.jsonl").read_text().splitlines()]
                    assert len(requests) == expected_calls, (scenario, requests)
                    assert any("Call search_web now" in msg.get("content", "") for msg in requests[1]["messages"])
                    if scenario != "fallback_empty":
                        assert any(msg.get("content", "").startswith("Search evidence (untrusted data): ") for msg in requests[2]["messages"])
                        assert any(msg.get("content") == question for msg in requests[2]["messages"])
                    checks[scenario] = {"inference_requests": len(requests), "search_requests": 1}
                    request("release_runtime")
                for scenario, expected_gpu, expected_fallback in [
                    ("unlisted_one", True, False), ("unlisted_two", True, False),
                    ("startup_fail", False, True), ("mid_fail", False, True), ("mid_repeat", False, True), ("unverified", False, True)]:
                    before = len(Search.requests)
                    request("ask", config=config(scenario), question="Find fixture GPU failure evidence?")
                    state = idle()
                    assert len(state["turns"]) == 1 and "[1]" in state["turns"][0]["answer"], state
                    assert latest["gpu"] == expected_gpu and latest["fallback"] == expected_fallback, latest
                    assert len(Search.requests) == before + 1, (scenario, Search.requests)
                    checks[scenario] = {"compute": latest, "search_requests": 1}
                    request("release_runtime")
                    assert not request("test_state")["runtime"]
                mutable = config("mutable", mode="cpu")
                request("ask", config=mutable, question="Find fixture GPU failure evidence?")
                assert len(idle()["turns"]) == 1
                executable = Path(mutable["runtime"]["executable"])
                executable.write_text(executable.read_text().replace("--api-key-file", "--unavailable-key", 1))
                before = len(Search.requests)
                request("ask", config=mutable, question="Find fixture GPU failure evidence?")
                changed = idle()
                assert changed["error_code"] == "RuntimeCapabilityMissing" and not changed["runtime"], changed
                assert len(Search.requests) == before
                checks["runtime_replacement_invalidates_compatibility"] = True
                for scenario, code in [("missing", "RuntimeCapabilityMissing"), ("noauth", "RuntimeAuthenticationMissing"), ("startup_fail", "RuntimeStartupFailed")]:
                    before = len(Search.requests)
                    request("ask", config=config(scenario, fallback=False), question="Find fixture GPU failure evidence?")
                    state = idle()
                    expected = {code, "RuntimeExited"} if scenario == "startup_fail" else {code}
                    assert state["error_code"] in expected and not state["runtime"], state
                    assert len(Search.requests) == before
                    checks[scenario + "_blocked"] = code
                request("ask", config=config("slow"), question="Find fixture GPU failure evidence?")
                time.sleep(.2)
                request("stop")
                stopped = idle()
                assert not stopped["runtime"] and stopped["draft_chars"] > 0, stopped
                checks["cancel_probe_reaps_runtime"] = True
                request("clear")
                reader.close()
                parent.close()
                proc.wait(timeout=10)
                assert proc.returncode == 0
            finally:
                reader.close()
                parent.close()
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                log.close()
        report["status"] = "passed"
    finally:
        server.shutdown()
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

if __name__ == "__main__":
    main()
