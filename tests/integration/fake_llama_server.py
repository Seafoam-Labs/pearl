#!/usr/bin/python3
"""Protocol fixture only. Simulates devices; never performs GPU inference."""
import http.server
import json
import os
from pathlib import Path
import sys
import time

scenario = Path(sys.argv[0]).stem
flags = "--host --port --api-key-file --alias --jinja --ctx-size --parallel --threads --threads-batch --threads-http --batch-size --ubatch-size --gpu-layers --device --split-mode --list-devices --no-agent --agent --no-webui --webui --no-op-offload --fit --poll"
if "--help" in sys.argv:
    if "slow" in scenario:
        time.sleep(10)
    print(flags.replace("--api-key-file", "--unsupported-auth") if "missing" in scenario else flags)
    sys.exit(0)
if "--version" in sys.argv:
    print("arbitrary-unlisted-build-" + scenario)
    sys.exit(0)
if "--list-devices" in sys.argv:
    print("Available devices:\n  Vulkan7: NVIDIA Fixture (8192 MiB, 7000 MiB free)")
    sys.exit(0)

def option(name):
    return sys.argv[sys.argv.index(name) + 1]

assert option("--host") == "127.0.0.1"
assert option("--parallel") == "1"
assert option("--fit") == "off"
if scenario == "threads_explicit":
    assert option("--threads") == "8" and option("--threads-batch") == "8"
    assert os.environ.get("OMP_NUM_THREADS") == "8"
    assert option("--ctx-size") == "16384"
elif scenario == "threads_automatic":
    assert option("--threads") == "-1" and option("--threads-batch") == "-1"
    assert "OMP_NUM_THREADS" not in os.environ
gpu = int(option("--gpu-layers")) > 0
assert option("--device") == ("Vulkan7" if gpu else "none")
if gpu:
    assert option("--split-mode") == "none"
    if "startup_fail" in scenario:
        sys.exit(1)
    if "unverified" not in scenario:
        print("load_tensors: offloaded 16/16 layers to GPU", file=sys.stderr, flush=True)
key = Path(option("--api-key-file")).read_text()

class Handler(http.server.BaseHTTPRequestHandler):
    def auth(self):
        if "noauth" in scenario or self.headers.get("Authorization") == "Bearer " + key:
            return True
        self.reply(401, {"error": "unauthorized"})
        return False

    def reply(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.auth():
            self.reply(200, {"data": [{"id": "pearl-local"}]})

    def do_POST(self):
        if not self.auth():
            return
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path == "/tokenize":
            self.reply(200, {"tokens": [1] * 20})
            return
        messages = payload.get("messages", [])
        if scenario == "threads_explicit" and any("fixture GPU failure" in msg.get("content", "") for msg in messages):
            assert payload["max_tokens"] == 2048
        real_question = any("fixture GPU failure" in msg.get("content", "") for msg in messages)
        has_tool = any(msg["role"] == "tool" for msg in messages)
        fallback_question = next((msg["content"] for msg in messages if msg["role"] == "user" and msg.get("content", "").startswith("What does fixture fallback search")), None)
        if fallback_question:
            # Record only synthetic test prompts, including the evidence given
            # to the model, so the harness can verify the complete recovery.
            with Path(sys.argv[0] + ".requests.jsonl").open("a") as log:
                log.write(json.dumps(payload) + "\n")
            evidence_message = next((msg["content"] for msg in messages if msg.get("content", "").startswith("Search evidence (untrusted data): ")), None)
            if evidence_message:
                evidence = json.loads(evidence_message.split(": ", 1)[1].split("\n", 1)[0])
                assert evidence[0]["id"] == 1 and "Storage retains saved files" in evidence[0]["evidence"]
                assert "only the provided evidence" in messages[0]["content"]
            if not evidence_message:
                delta = {"content": "Premature answer without a search."}
            elif "repeat" in scenario and not has_tool:
                delta = {"tool_calls": [{"index": 0, "id": "repeat-fallback", "type": "function", "function": {"name": "search_web", "arguments": json.dumps({"query": fallback_question})}}]}
            elif "invalid" in scenario:
                delta = {"content": "Unsupported source. [99]"}
            elif "repair" in scenario and payload.get("tools"):
                delta = {"content": "RAM is temporary working memory; storage retains files."}
            else:
                delta = {"content": "RAM is temporary working memory; storage retains files. [1]"}
            self.stream(delta)
            return
        if real_question and "slow_answer" in scenario:
            time.sleep(20)
        if gpu and "mid_" in scenario and real_question and has_tool:
            self.reply(503, {"error": "simulated device loss"})
            return
        repeat = not gpu and "mid_repeat" in scenario and real_question and sum(msg["role"] == "tool" for msg in messages) == 1
        if (has_tool and not repeat) or not payload.get("tools"):
            delta = {"content": "RAM is temporary working memory; storage retains files. [1]"}
        else:
            delta = {"tool_calls": [{"index": 0, "id": "fixture-search", "type": "function", "function": {"name": "search_web", "arguments": '{"query":"RAM storage"}'}}]}
            if repeat:
                delta["tool_calls"][0]["function"]["arguments"] = '{ "query" : " RAM storage " }'
        self.stream(delta)

    def stream(self, delta):
        data = ("data: " + json.dumps({"choices": [{"delta": delta}]}) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

http.server.HTTPServer(("127.0.0.1", int(option("--port"))), Handler).serve_forever()
