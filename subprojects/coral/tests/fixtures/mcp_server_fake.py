#!/usr/bin/env python3
"""Deterministic fake MCP server for Coral backend tests.

Line-delimited JSON-RPC 2.0 over stdio. Implements initialize,
notifications/initialized, tools/list and tools/call. The `write_file` tool is
deliberately non-read-only but performs NO host write (it only reports what it
would do), so tests can exercise approval gating without side effects.

Run: python3 tests/fixtures/mcp_server_fake.py --mode default
"""

import argparse
import json
import sys

MODES = ("default", "malformed")


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(rid, result):
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def respond_error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


TOOLS = [
    {
        "name": "echo",
        "description": "Echo text back (read-only).",
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "write_file",
        "description": "Pretend to write a file (non-read-only, no side effect).",
        "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
        "annotations": {"readOnlyHint": False},
    },
]


def handle_initialize(rid):
    respond(rid, {
        "protocolVersion": "2024-11-05",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "fake-mcp", "version": "0.1"},
    })


def handle_call(rid, params):
    name = params.get("name")
    args = params.get("arguments", {})
    if name == "echo":
        respond(rid, {"content": [{"type": "text", "text": args.get("text", "")}], "isError": False})
    elif name == "write_file":
        respond(rid, {"content": [{"type": "text", "text": "would write " + args.get("path", "")}], "isError": False})
    else:
        respond_error(rid, -32602, "unknown tool")


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
        if mode == "malformed":
            sys.stdout.write("garbage line\n")
            sys.stdout.flush()
        if method == "initialize":
            handle_initialize(rid)
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            respond(rid, {"tools": TOOLS})
        elif method == "tools/call":
            handle_call(rid, params)
        elif rid is not None:
            respond_error(rid, -32601, "method not found")


if __name__ == "__main__":
    main()
