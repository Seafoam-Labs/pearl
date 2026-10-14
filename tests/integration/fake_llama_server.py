#!/usr/bin/python3
"""Protocol fixture only. Simulates devices; never performs GPU inference."""
import http.server
import json
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
        real_question = any("fixture GPU failure" in msg.get("content", "") for msg in messages)
        has_tool = any(msg["role"] == "tool" for msg in messages)
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
        data = ("data: " + json.dumps({"choices": [{"delta": delta}]}) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

http.server.HTTPServer(("127.0.0.1", int(option("--port"))), Handler).serve_forever()
