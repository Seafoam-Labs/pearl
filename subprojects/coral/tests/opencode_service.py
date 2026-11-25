#!/usr/bin/env python3
"""Verify OpenCode's next-call model switch using an isolated service and local model endpoint."""
import base64
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


class ModelEndpoint(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        call = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.calls.append(call["model"])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if len(self.server.calls) == 1:
            self.server.started.set()
            if not self.server.release.wait(15):
                return
            reader = next(tool["function"] for tool in call["tools"] if tool["function"]["name"] == "read")
            key = next(key for key in reader["parameters"]["properties"] if "path" in key.lower())
            delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "local-read", "type": "function",
                     "function": {"name": "read", "arguments": json.dumps({key: str(self.server.document)})}}]}
            reason = "tool_calls"
        else:
            delta, reason = {"role": "assistant", "content": "Reviewed the fixture."}, "stop"
        for data, finish in [(delta, None), ({}, reason)]:
            chunk = {"id": "local-stream", "object": "chat.completion.chunk", "created": 1, "model": call["model"],
                     "choices": [{"index": 0, "delta": data, "finish_reason": finish}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def wait_for(read, description):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError("Timed out waiting for " + description)


def verify(root):
    project = root / "project"
    project.mkdir()
    document = project / "selection.txt"
    document.write_text("Selected editor range.\n")
    env = {key:os.environ[key] for key in ("PATH","LANG","LC_ALL","USER","HOME","SHELL") if key in os.environ}
    for kind in ("DATA","CONFIG","STATE","CACHE"):
        directory = root / kind.lower()
        directory.mkdir()
        env["XDG_" + kind + "_HOME"] = str(directory)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    env.update(XDG_RUNTIME_DIR=str(runtime), OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_DISABLE_AUTOUPDATE="1",
               CORAL_TEST_MODEL_KEY="loopback-fixture")
    provider = ThreadingHTTPServer(("127.0.0.1", 0), ModelEndpoint)
    provider.daemon_threads = True
    provider.calls, provider.document = [], document
    provider.started, provider.release = threading.Event(), threading.Event()
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    settings = {"name":"Coral fixture","package":"@ai-sdk/openai-compatible","env":["CORAL_TEST_MODEL_KEY"],
                "settings":{"baseURL":f"http://127.0.0.1:{provider.server_port}/v1","apiKey":"loopback-fixture"},
                "models":{key:{"name":key.title(),"type":"chat","modelID":key,"disabled":False} for key in ("birch","cedar")}}
    config = root / "config/opencode"
    config.mkdir()
    (config / "opencode.json").write_text(json.dumps({"model":"coral-test/birch","providers":{"coral-test":settings}}))
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"http://127.0.0.1:{port}"
    service = subprocess.Popen(["opencode","serve","--hostname","127.0.0.1","--port",str(port)], cwd=project, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        password = next(line.split("server password ")[-1].strip() for line in service.stdout if "server password " in line)
        auth = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
        def api(path, body=None, method=None):
            request = Request(endpoint + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                              headers={"Authorization":auth,"Content-Type":"application/json"})
            with urlopen(request, timeout=10) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        location = {"directory":str(project)}
        session = api("/api/session", {"title":"Local model contract","location":location,
                      "permissions":[{"action":"read","resource":"*","effect":"ask"}]})["data"]["id"]
        path = "/api/session/" + session
        def switch(model):
            api(path + "/model", {"model":{"providerID":"coral-test","id":model}})
            assert api(path)["data"]["model"]["id"] == model
        switch("birch")
        api(path + "/prompt", {"id":"msg_coral_fixture_read","text":"Read selection.txt and review the selected text."})
        assert provider.started.wait(15), "The first model did not receive the prompt"
        switch("cedar")
        assert provider.calls == ["birch"]
        provider.release.set()
        permission = wait_for(lambda: api(path + "/permission")["data"], "read permission")[0]
        assert permission["action"] == "read" and permission["sessionID"] == session
        assert permission["resources"] == ["selection.txt"] and permission["source"]["type"] == "tool"
        api(path + "/permission/" + permission["id"] + "/reply", {"decision":"once"})
        wait_for(lambda: len(provider.calls) >= 2, "the next model call")
        assert provider.calls[:2] == ["birch","cedar"], provider.calls
        wait_for(lambda: any(m["type"]=="idle" for m in api(path + "/message")["data"]), "the session to finish")
        query = "?" + urlencode({"location[directory]": str(project)})
        def listed_models():
            rows = api("/api/model" + query)["data"]
            return {row["id"] for row in rows if row["providerID"] == "coral-test" and row.get("enabled")}
        wait_for(lambda: {"birch", "cedar"} <= listed_models(), "both configured chat models in the location catalog")
        default = api("/api/model/default" + query)["data"]
        assert default and (default["id"], default["providerID"]) == ("birch", "coral-test"), default
        queued = {"id":"msg_coral_fixture_queued","text":"Review the next change.","resume":False}
        api(path+"/prompt",queued)
        api(path+"/prompt",queued)
        assert [m["id"] for m in api(path+"/inbox")["data"]].count(queued["id"]) == 1
        api(path+"/inbox/"+queued["id"],method="DELETE")
        assert not any(m["id"]==queued["id"] for m in api(path+"/inbox")["data"])
        print("Verified OpenCode switched Birch to Cedar during one turn, honored read permission, and deduplicated a retried prompt.")
    finally:
        provider.release.set()
        service.terminate()
        try:
            service.wait(timeout=8)
        except subprocess.TimeoutExpired:
            service.kill()
            service.wait()
        provider.shutdown()
        provider.server_close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="coral-opencode-contract-") as temporary:
        verify(Path(temporary))
