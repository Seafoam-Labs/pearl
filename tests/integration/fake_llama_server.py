#!/usr/bin/python3
"""Protocol fixture only. Simulates a mistralrs server and devices; never performs GPU inference."""
import http.server
import json
import os
from pathlib import Path
import sys
import time

scenario = Path(sys.argv[0]).stem
serve_flags = "-f, --quantized-file --host --port --max-model-len --no-ui --cpu --max-seqs --disable-metrics --disable-access-log -n, --n-gpu-layers --gpu-memory-utilization"
main_help = "mistralrs fixture\nCommands: serve run doctor tune\n  serve [embedding]  OpenAI-compatible local server"
if "--help" in sys.argv:
    if "slow" in scenario:
        time.sleep(10)
    if "serve" in sys.argv:
        print(serve_flags.replace("--max-seqs", "--unsupported-seqs") if "missing" in scenario else serve_flags)
    else:
        print(main_help)
    sys.exit(0)
if "--version" in sys.argv:
    print("mistralrs arbitrary-unlisted-build-" + scenario)
    sys.exit(0)
if "doctor" in sys.argv:
    print("mistralrs doctor\nDevices:\n  Vulkan0: NVIDIA Fixture (8192 MiB, 7000 MiB free)")
    sys.exit(0)

def option(name):
    return sys.argv[sys.argv.index(name) + 1]

assert "serve" in sys.argv
assert option("--host") == "127.0.0.1"
assert option("--max-seqs") == "1"
assert "--no-ui" in sys.argv and "--disable-metrics" in sys.argv and "--disable-access-log" in sys.argv
assert "-f" in sys.argv or "--quantized-file" in sys.argv
if scenario == "threads_explicit":
    assert os.environ.get("RAYON_NUM_THREADS") == "8"
    assert option("--max-model-len") == "16384"
elif scenario == "threads_automatic":
    assert "RAYON_NUM_THREADS" not in os.environ
gpu = "--cpu" not in sys.argv
if gpu:
    if "-n" in sys.argv:
        assert option("-n") == "0:16"
    if "startup_fail" in scenario:
        sys.exit(1)
    if "unverified" not in scenario:
        print("mistralrs: offloaded 16/16 layers to GPU", file=sys.stderr, flush=True)
else:
    assert "--cpu" in sys.argv

class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # mistral.rs ignores Authorization headers; no authentication exists.
        if self.path == "/health" or self.path == "/":
            self.reply(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self.reply(200, {"data": [{"id": "pearl-local"}]})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if scenario.startswith("benchmark_"):
            with Path(sys.argv[0] + ".requests.jsonl").open("a") as log:
                log.write(json.dumps({"path": self.path, "payload": payload}) + "\n")
        assert self.path == "/v1/chat/completions", self.path
        messages = payload.get("messages", [])
        if scenario.startswith("benchmark_"):
            self.server.completions = getattr(self.server, "completions", 0) + 1
            # Chat health, tool call, then consumption of fixed local evidence.
            measuring = self.server.completions > 3
            evidence = any(m["role"] == "tool" or m.get("content", "").startswith(("Search evidence", "Previous search evidence")) for m in messages)
            current_evidence = any(m["role"] == "tool" for m in messages)
            if measuring and ("slow" in scenario or "delayed_answer" in scenario):
                time.sleep(10)
            if measuring and gpu and "mid_fail" in scenario and evidence:
                self.reply(503, {"error": "simulated device loss"})
                return
            if not evidence and payload.get("tools") and not (measuring and "direct" in scenario):
                delta = {"tool_calls": [{"index": 0, "id": "local-search", "type": "function", "function": {"name": "search_web", "arguments": '{"query":"local benchmark evidence"}'}}]}
            else:
                question = " ".join(m.get("content", "") for m in messages if m["role"] == "user")
                returning = any(m["role"] == "user" and m.get("content", "").startswith("The return trip takes 13") for m in messages)
                answer = "The return trip takes 60 minutes." if returning else "The trip takes 47 minutes." if "depot timetable" in question else "RAM is temporary working memory; storage retains saved files."
                if current_evidence:
                    answer += " [1]"
                if measuring and current_evidence and "invalid" in scenario:
                    answer = "Unsupported answer. [99]"
                if measuring and current_evidence and "repair" in scenario and payload.get("tools"):
                    answer = "Uncited answer."
                if not measuring and not payload.get("tools") and not evidence:
                    answer = "Hello from the local chat fixture."
                delta = {"content": answer}
            self.stream(delta, finish="length" if measuring and "truncated" in scenario else "stop", telemetry=True)
            return
        if scenario == "threads_explicit" and any("fixture GPU failure" in msg.get("content", "") for msg in messages):
            assert payload["max_tokens"] == 2048
        real_question = any("fixture GPU failure" in msg.get("content", "") for msg in messages)
        has_tool = any(msg["role"] == "tool" for msg in messages)
        fallback_question = next((msg["content"] for msg in messages if msg["role"] == "user" and msg.get("content", "").startswith("What does fixture fallback search")), None)
        if fallback_question:
            # This formerly triggered host-forced search. A direct answer is
            # now valid and must finish without a second completion or search.
            with Path(sys.argv[0] + ".requests.jsonl").open("a") as log:
                log.write(json.dumps(payload) + "\n")
            self.stream({"content": "RAM is temporary working memory; storage retains files."})
            return
        if real_question and "slow_answer" in scenario:
            time.sleep(20)
        if gpu and "mid_" in scenario and real_question and has_tool:
            self.reply(503, {"error": "simulated device loss"})
            return
        repeat = not gpu and "mid_repeat" in scenario and real_question and sum(msg["role"] == "tool" for msg in messages) == 1
        if not payload.get("tools") and not has_tool:
            delta = {"content": "Hello from the local chat fixture."}
        elif has_tool and not repeat:
            delta = {"content": "RAM is temporary working memory; storage retains files. [1]"}
        else:
            delta = {"tool_calls": [{"index": 0, "id": "fixture-search", "type": "function", "function": {"name": "search_web", "arguments": '{"query":"RAM storage"}'}}]}
            if repeat:
                delta["tool_calls"][0]["function"]["arguments"] = '{ "query" : " RAM storage " }'
        self.stream(delta)

    def stream(self, delta, finish="stop", telemetry=False):
        frames = [{"choices": [{"delta": {"reasoning_content": "Internal test reasoning, never a visible answer."}}]}, {"choices": [{"delta": delta, "finish_reason": finish}]}]
        if telemetry:
            frames.append({"choices": [], "usage": {"prompt_tokens": 40, "completion_tokens": 30, "completion_tokens_details": {"reasoning_tokens": 10}, "avg_tok_per_sec": 30.0}, "timings": {"prompt_ms": 2.0, "predicted_ms": 50.0}})
        data = ("".join("data: " + json.dumps(frame) + "\n\n" for frame in frames) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

http.server.HTTPServer(("127.0.0.1", int(option("--port"))), Handler).serve_forever()
