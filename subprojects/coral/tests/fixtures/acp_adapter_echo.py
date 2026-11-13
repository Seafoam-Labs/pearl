#!/usr/bin/env python3
"""Deterministic ACP v1 echo adapter for Coral backend tests.

Line-delimited JSON-RPC 2.0 over stdio. Stdout is exclusively protocol JSON
(or deliberate fault bytes in malformed mode). Never touches the filesystem
or network. Modes exercise negotiation, omitted capabilities, permission
allow/deny/cancel, fs/terminal callbacks, disconnect, late responses, and
malformed/fragmented input.

Run: python3 tests/fixtures/acp_adapter_echo.py --mode default
"""

import argparse
import json
import sys
import time

MODES = (
    "default", "omit-capabilities", "permission", "fs", "terminal",
    "malformed", "fragment", "disconnect", "slow", "late",
)

_next_id = 0
_cancelled = False
_last_prompt_id = None


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def send_fragmented(obj):
    data = json.dumps(obj, separators=(",", ":")) + "\n"
    third = max(1, len(data) // 3)
    for i in range(0, len(data), third):
        sys.stdout.write(data[i:i + third])
        sys.stdout.flush()
        time.sleep(0.005)


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def respond(rid, result):
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def respond_error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def client_request(method, params):
    """Send a request to the client and block for its response."""
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


def chunk(session_id, text):
    notify("session/update", {
        "sessionId": session_id,
        "update": {"sessionUpdate": "agent_message_chunk",
                   "content": {"type": "text", "text": text}},
    })


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


def handle_prompt(rid, params, mode):
    global _last_prompt_id
    _last_prompt_id = rid
    session_id = params.get("sessionId", "s-echo")
    text = ""
    prompt = params.get("prompt", [])
    if prompt and isinstance(prompt, list):
        text = prompt[0].get("text", "")

    if mode == "disconnect":
        # Abruptly exit mid-prompt without responding.
        sys.exit(0)

    if mode == "slow":
        time.sleep(5)
        chunk(session_id, text)
        respond(rid, {"stopReason": "end_turn"})
        return

    if mode == "malformed":
        sys.stdout.write("this is not json\n")
        sys.stdout.write("{bad json\n")
        sys.stdout.flush()

    if mode == "permission":
        result, err = client_request("session/request_permission", {
            "sessionId": session_id,
            "toolCall": {"toolCallId": "tc1", "title": "Run command", "kind": "execute"},
            "options": [
                {"optionId": "allow", "name": "Allow", "kind": "allow"},
                {"optionId": "deny", "name": "Deny", "kind": "deny"},
            ],
        })
        outcome = (result or {}).get("outcome", {})
        if outcome.get("outcome") == "selected":
            if outcome.get("optionId") == "allow":
                chunk(session_id, text)
                respond(rid, {"stopReason": "end_turn"})
            else:
                respond(rid, {"stopReason": "refusal"})
        else:
            respond(rid, {"stopReason": "cancelled"})
        return

    if mode == "fs":
        result, err = client_request("fs/read_text_file", {"sessionId": session_id, "path": "file.txt"})
        content = (result or {}).get("content", "")
        _, werr = client_request("fs/write_text_file", {
            "sessionId": session_id, "path": "file.txt", "content": "edited:" + content,
        })
        if werr:
            respond(rid, {"stopReason": "refusal"})
            return
        chunk(session_id, text)
        respond(rid, {"stopReason": "end_turn"})
        return

    if mode == "terminal":
        created, _ = client_request("terminal/create", {
            "sessionId": session_id, "command": "echo", "args": ["hi"],
        })
        tid = (created or {}).get("terminalId", "t1")
        out, _ = client_request("terminal/output", {"sessionId": session_id, "terminalId": tid})
        client_request("terminal/wait_for_exit", {"sessionId": session_id, "terminalId": tid})
        client_request("terminal/release", {"sessionId": session_id, "terminalId": tid})
        chunk(session_id, (out or {}).get("output", ""))
        respond(rid, {"stopReason": "end_turn"})
        return

    # default / fragment / late / malformed fall through to echo.
    if mode == "fragment":
        send_fragmented({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": session_id,
            "update": {"sessionUpdate": "agent_message_chunk",
                       "content": {"type": "text", "text": text}},
        }})
        send_fragmented({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return

    chunk(session_id, text)
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
            respond(rid, {"sessionId": "s-echo"})
        elif method == "session/prompt":
            handle_prompt(rid, params, mode)
        elif method == "session/cancel":
            global _cancelled
            _cancelled = True
            if mode == "late" and _last_prompt_id is not None:
                # Late duplicate response after the prompt already completed.
                respond(_last_prompt_id, {"stopReason": "end_turn"})
        elif rid is not None:
            # Unexpected client request.
            respond_error(rid, -32601, "method not found")


if __name__ == "__main__":
    main()
