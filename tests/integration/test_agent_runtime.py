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

def qualification_fixture():
    """Offline server used by runtime.zig tests; never executes returned tools."""
    executable = Path(sys.argv[0])
    scenario = Path(str(executable) + ".scenario").read_text()
    flags = "--host --port --api-key-file --alias --ctx-size --parallel --threads --threads-batch --threads-http --batch-size --ubatch-size --gpu-layers --jinja --reasoning-format"
    if "--help" in sys.argv:
        if scenario == "no_jinja":
            flags = flags.replace(" --jinja", "")
        if scenario == "missing_auth":
            flags = flags.replace("--api-key-file", "--unsupported-auth")
        print(flags)
        return
    if "--version" in sys.argv:
        print("deterministic-chat-tool-qualification")
        return
    def option(name):
        return sys.argv[sys.argv.index(name) + 1]
    assert option("--host") == "127.0.0.1"
    assert ("--jinja" in sys.argv) == (scenario != "no_jinja")
    key = Path(option("--api-key-file")).read_text()
    log_path = Path(str(executable) + ".requests.jsonl")
    class Handler(http.server.BaseHTTPRequestHandler):
        def reply(self, status, value):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)
        def authorized(self):
            if scenario == "no_auth" or self.headers.get("Authorization") == "Bearer " + key:
                return True
            self.reply(401, {"error": "unauthorized"})
            return False
        def do_GET(self):
            if self.authorized():
                self.reply(200, {"data": [{"id": "pearl-local"}]})
        def do_POST(self):
            if not self.authorized():
                return
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if self.path == "/tokenize":
                self.reply(200, {"tokens": [1, 2, 3]})
                return
            if scenario == "no_auth":
                self.reply(200, {})
                return
            assert self.path == "/v1/chat/completions", self.path
            messages = payload["messages"]
            followup = any(m["role"] == "tool" for m in messages)
            kind = "followup" if followup else "tools" if payload.get("tools") else "chat"
            with log_path.open("a") as log:
                log.write(json.dumps({"kind": kind, "payload": payload}) + "\n")
            call = {"index": 0, "id": "fixture-search", "type": "function", "function": {"name": "search_web", "arguments": '{"query":"RAM storage"}'}}
            finish = "stop"
            if kind == "chat":
                assert "tools" not in payload
                assert all(m.get("tool_calls") is None for m in messages)
                if scenario == "chat_http" or (scenario == "unhealthy_after_tools" and self.server.tool_attempted):
                    self.reply(503, {"error": "chat unavailable"})
                    return
                delta = {"tool_calls": [call]} if scenario == "tool_in_chat" else {"content": " \t\n" if scenario == "empty_chat" else "Hello from the local chat fixture."}
                self.server.chat_checked = True
            else:
                assert self.server.chat_checked, "tools were checked before chat"
                self.server.tool_attempted = True
                if kind == "followup":
                    assert "tools" not in payload
                    assert messages[-1]["tool_call_id"] == "fixture-search"
                    assert json.loads(messages[-1]["content"])[0]["id"] == 1
                    delta = {"content": "" if scenario == "bad_followup" else "RAM is temporary; storage retains files. [1]"}
                elif scenario in ("http_tools", "unhealthy_after_tools"):
                    self.reply(400, {"error": "tools unsupported"})
                    return
                elif scenario == "no_tools":
                    delta = {"content": "I can chat but cannot call tools."}
                else:
                    if scenario == "malformed_arguments":
                        call["function"]["arguments"] = "{broken"
                    elif scenario == "unexpected_tool":
                        call["function"]["name"] = "execute_shell"
                    elif scenario == "truncated_tools":
                        finish = "length"
                    delta = {"tool_calls": [call]}
            frames = [{"choices": [{"delta": delta, "finish_reason": finish}]}]
            data = ("".join("data: " + json.dumps(frame) + "\n\n" for frame in frames) + "data: [DONE]\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *_):
            pass
    server = http.server.HTTPServer(("127.0.0.1", int(option("--port"))), Handler)
    server.chat_checked = False
    server.tool_attempted = False
    server.serve_forever()

# Native tests copy this file to a private executable with a scenario sidecar.
# Dispatch before importing the UI harness: qualification needs no compositor.
if __name__ == "__main__" and Path(sys.argv[0]).name == "qualification-fixture":
    qualification_fixture()
    sys.exit(0)

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
            os.link(args.model.resolve(), models / "LFM3-1.7B-Q4_K_M.gguf")
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
                return dict(enabled=True, read_pages=False, default_provider_id="google", model_id="custom", custom_model=str(models / "LFM3-1.7B-Q4_K_M.gguf"), runtime=dict(source="custom", executable=str(executable)),
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
                # Former forced-search cases must now accept the model's direct
                # answer, even while search tools are available to the model.
                for scenario in ("fallback_search", "fallback_repair", "fallback_invalid", "fallback_empty", "fallback_repeat"):
                    selected = config(scenario, mode="cpu")
                    question = "What does fixture fallback search say about RAM and storage?"
                    if scenario == "fallback_empty":
                        question += " empty"
                    before = len(Search.requests)
                    request("ask", config=selected, question=question)
                    state = idle()
                    assert not state["error_code"] and len(state["turns"]) == 1, state
                    assert state["turns"][0]["answer"] == "RAM is temporary working memory; storage retains files.", state
                    assert state["sources"] == 0, state
                    assert len(Search.requests) == before, (scenario, Search.requests)
                    # The fixture logs only completions for this question, not
                    # runtime qualification or template/tokenization requests.
                    requests = [json.loads(line) for line in Path(selected["runtime"]["executable"] + ".requests.jsonl").read_text().splitlines()]
                    assert len(requests) == 1, (scenario, requests)
                    assert requests[0].get("tools"), (scenario, requests)
                    messages = requests[0]["messages"]
                    assert [msg["content"] for msg in messages if msg["role"] == "user"] == [question], (scenario, messages)
                    assert not any(msg["role"] == "tool" or msg.get("tool_calls") for msg in messages), (scenario, messages)
                    checks["direct_answer_" + scenario.removeprefix("fallback_")] = {"inference_requests": 1, "search_requests": 0, "sources": 0}
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
                before = len(Search.requests)
                request("ask", config=config("mid_fail", fallback=False), question="Find fixture GPU failure evidence?")
                failed = idle()
                assert failed["error_code"] == "InferenceFailed" and not failed["runtime"], failed
                assert failed["cpu_retry_available"] and failed["draft_chars"] > 0, failed
                assert len(failed["turns"]) == 1 and failed["sources"] == 1, failed
                assert not failed["status"].startswith("Answer complete."), failed
                assert len(Search.requests) == before + 1, Search.requests
                checks["mid_answer_failure_preserves_cpu_retry_and_sources"] = True
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
