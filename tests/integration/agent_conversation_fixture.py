#!/usr/bin/python3
"""Offline protocol fixture for conversation_tests.zig, not a model substitute.

The native tests copy this executable beside a JSON plan in a private temporary
folder. Only synthetic requests are logged; authentication headers are never
persisted. Replies and token counts are supplied by Zig, not inferred from the
question, so the tests check controller contracts rather than model quality.
"""
import http.server
import json
from pathlib import Path
import sys
import time


executable = Path(sys.argv[0])
plan = json.loads(Path(str(executable) + ".plan").read_text())
flags = "--host --port --api-key-file --alias --ctx-size --parallel --threads --threads-batch --threads-http --batch-size --ubatch-size --gpu-layers --jinja"
if "--help" in sys.argv:
    print(flags)
    sys.exit(0)
if "--version" in sys.argv:
    print("pearl-offline-conversation-fixture-v1")
    sys.exit(0)


def option(name):
    return sys.argv[sys.argv.index(name) + 1]


assert option("--host") == "127.0.0.1"
assert option("--gpu-layers") == "0"
assert option("--parallel") == "1"
key = Path(option("--api-key-file")).read_text()
log_path = Path(str(executable) + ".requests.jsonl")
release = Path(str(executable) + ".release")


def call(name, arguments, identifier):
    return {"index": 0, "id": identifier, "type": "function",
            "function": {"name": name, "arguments": arguments}}


class Handler(http.server.BaseHTTPRequestHandler):
    def record(self, kind, payload):
        with log_path.open("a") as log:
            log.write(json.dumps({"kind": kind, "payload": payload}) + "\n")

    def reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") == "Bearer " + key:
            return True
        self.reply(401, {"error": "unauthorized"})
        return False

    def do_GET(self):
        if self.authorized():
            assert self.path == "/v1/models"
            self.reply(200, {"data": [{"id": "pearl-local"}]})

    def do_POST(self):
        if not self.authorized():
            return
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/apply-template":
            self.record("template", payload)
            assert payload["add_generation_prompt"] is True
            self.server.template = payload
            # Deliberately distinguish the rendered prompt from message JSON.
            self.server.prompt = "<|fixture-template|>" + json.dumps(
                {"messages": payload["messages"], "tools": payload.get("tools")},
                sort_keys=True, ensure_ascii=False) + "<|assistant|>"
            self.reply(200, {"prompt": self.server.prompt})
            return
        if self.path == "/tokenize":
            self.record("tokenize", payload)
            assert payload["parse_special"] is True
            assert payload["add_special"] is False
            if self.server.template is None:
                assert payload["content"] == "Pearl local compatibility check"
                count = 8
            else:
                assert payload["content"] == self.server.prompt
                counts = plan["token_counts"]
                index = self.server.tokenizations
                assert index < len(counts), "unexpected prompt measurement"
                count = counts[index]
                self.server.tokenizations += 1
            self.reply(200, {"tokens": [1] * count})
            return
        assert self.path == "/v1/chat/completions"
        assert payload["stream"] is True and payload["temperature"] == 0
        index = self.server.completions
        self.server.completions += 1
        if index < 3:
            self.record("qualification", payload)
            if index == 0:
                assert "tools" not in payload
                self.stream({"content": "" if plan["qualification"] == "failed" else "Hello."})
            elif index == 1:
                assert len(payload["tools"]) == 2
                if plan["qualification"] == "chat_only":
                    self.stream({"content": "Tools are unsupported."})
                else:
                    self.stream({"tool_calls": [call("search_web", '{"query":"RAM storage"}', "qualification")]})
            else:
                assert "tools" not in payload
                if plan["qualification"] == "chat_only":
                    assert not any(m["role"] == "tool" for m in payload["messages"])
                    self.stream({"content": "Chat still works."})
                else:
                    assert payload["messages"][-1]["tool_call_id"] == "qualification"
                    self.stream({"content": "RAM is temporary; storage retains data. [1]"})
            return
        self.record("completion", payload)
        assert self.server.template is not None
        assert payload["messages"] == self.server.template["messages"], "template/message mismatch"
        assert payload.get("tools") == self.server.template.get("tools"), "template/tool mismatch"
        assert index - 3 < len(plan["replies"]), "unexpected extra inference"
        reply = plan["replies"][index - 3]
        if reply["status"] != 200:
            self.reply(reply["status"], {"error": "synthetic inference failure"})
            return
        delta = {"content": reply["text"]}
        if reply["name"]:
            delta["tool_calls"] = [call(reply["name"], reply["arguments"], reply["id"])]
        self.stream(delta, reply["finish"], reply["gated"])

    def stream(self, delta, finish="stop", gated=False):
        def frame(value):
            return ("data: " + json.dumps({"choices": [value]}) + "\n\n").encode()
        # The first visible chunk is held independently of final completion.
        first = frame({"delta": {"reasoning_content": "Private reasoning [99]."}})
        first += frame({"delta": delta})
        last = frame({"delta": {}, "finish_reason": finish}) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(first) + len(last)))
        self.end_headers()
        try:
            self.wfile.write(first)
            self.wfile.flush()
            if gated:
                deadline = time.monotonic() + 5
                while not release.exists() and time.monotonic() < deadline:
                    time.sleep(0.005)
                if not release.exists():
                    return  # Bounded incomplete stream if the observer never releases it.
            self.wfile.write(last)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the native cancellable stops an active stream.

    def log_message(self, *_):
        pass


server = http.server.HTTPServer(("127.0.0.1", int(option("--port"))), Handler)
server.completions = 0
server.tokenizations = 0
server.template = None
server.prompt = None
server.serve_forever()
