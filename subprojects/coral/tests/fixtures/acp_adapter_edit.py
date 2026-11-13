#!/usr/bin/env python3
"""Deterministic ACP v1 edit adapter for Coral backend tests.

Exercises a multi-step edit: tool_call / tool_call_update notifications plus
fs/read_text_file and fs/write_text_file (the latter routed through the
client's review flow). Never touches the filesystem or network directly.

Run: python3 tests/fixtures/acp_adapter_edit.py --mode default
"""

import argparse
import json
import sys

MODES = ("default", "omit-capabilities")

_next_id = 0


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def respond(rid, result):
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def respond_error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def client_request(method, params):
    global _next_id
    _next_id += 1
    rid = _next_id
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == rid and ("result" in msg or "error" in msg):
            return msg.get("result"), msg.get("error")


def update(session_id, payload):
    notify("session/update", {"sessionId": session_id, "update": payload})


def handle_initialize(rid, params, mode):
    if params.get("protocolVersion") != 1:
        respond_error(rid, -32602, "unsupported protocol version")
        return
    if mode == "omit-capabilities":
        respond(rid, {"protocolVersion": 1})
        return
    respond(rid, {
        "protocolVersion": 1,
        "agentCapabilities": {
            "loadSession": False,
            "promptCapabilities": {"image": False, "audio": False, "embeddedContext": True},
        },
    })


def handle_prompt(rid, params):
    session_id = params.get("sessionId", "s-edit")
    path = "file.txt"
    prompt = params.get("prompt", [])
    if prompt and isinstance(prompt, list) and prompt[0].get("text"):
        path = prompt[0]["text"]

    update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "tc1",
                        "title": "Edit file", "kind": "edit", "status": "pending"})

    result, err = client_request("fs/read_text_file", {"sessionId": session_id, "path": path})
    if err:
        update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "failed"})
        respond(rid, {"stopReason": "refusal"})
        return
    content = (result or {}).get("content", "")

    update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "in_progress"})

    _, werr = client_request("fs/write_text_file", {
        "sessionId": session_id, "path": path, "content": content + "\n// edited",
    })
    if werr:
        update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "failed"})
        respond(rid, {"stopReason": "refusal"})
        return

    update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "completed"})
    update(session_id, {"sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "Edited " + path}})
    respond(rid, {"stopReason": "end_turn"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=MODES, default="default")
    args = parser.parse_args()
    mode = args.mode

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method = msg.get("method")
        rid = msg.get("id")
        params = msg.get("params", {})
        if method == "initialize":
            handle_initialize(rid, params, mode)
        elif method == "session/new":
            respond(rid, {"sessionId": "s-edit"})
        elif method == "session/prompt":
            handle_prompt(rid, params)
        elif method == "session/cancel":
            pass
        elif rid is not None:
            respond_error(rid, -32601, "method not found")


if __name__ == "__main__":
    main()
