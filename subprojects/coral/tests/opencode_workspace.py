#!/usr/bin/env python3
"""Drive the native OpenCode composer and isolated worktree review through GTK accessibility."""
import argparse
import json
import os
import queue
import secrets
import socket
import base64
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

CORAL = Path(__file__).resolve().parents[1]
PEARL = CORAL.parents[1]
sys.path[:0] = [str(PEARL / "scripts"), str(PEARL / "tests/integration")]


def drive(offline=False, adaptive=False):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    def descendants(node):
        yield node
        for index in range(node.get_child_count()):
            child = node.get_child_at_index(index)
            if child:
                yield from descendants(child)

    def lookup(name, actionable=True):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            for obj in descendants(Atspi.get_desktop(0)):
                if obj.get_name() != name or not obj.get_state_set().contains(Atspi.StateType.SHOWING):
                    continue
                if not actionable or (obj.get_n_actions() > 0 and obj.get_state_set().contains(Atspi.StateType.SENSITIVE)):
                    return obj
            time.sleep(.05)
        names = [obj.get_name() for obj in descendants(Atspi.get_desktop(0)) if obj.get_name() and obj.get_state_set().contains(Atspi.StateType.SHOWING)]
        raise AssertionError(f"Missing visible GTK control {name!r}; visible controls {names!r}")

    def click(name):
        assert lookup(name).do_action(0), name

    def fixture(action, **fields):
        request = Request(os.environ["WORKSPACE_FIXTURE_URL"] + "/test", data=json.dumps({"action": action, **fields}).encode(),
                          headers={"Authorization": os.environ["WORKSPACE_FIXTURE_AUTH"]})
        with urlopen(request, timeout=5) as reply:
            return json.load(reply)

    def buffer_with(text, contains=False):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            seen = []
            for node in descendants(Atspi.get_desktop(0)):
                if node.get_state_set().contains(Atspi.StateType.SHOWING) and "Text" in node.get_interfaces():
                    contents = Atspi.Text.get_text(node, 0, -1)
                    if contents == text or (contains and text in contents):
                        return node
                    if "EditableText" in node.get_interfaces():
                        seen.append((node.get_name(), contents[:90]))
            time.sleep(.05)
        raise AssertionError(f"No visible GTK buffer contains {text!r}. Editable controls contained {seen!r}")

    def capture(name):
        if directory := os.environ.get("WORKSPACE_TEST_CAPTURES"):
            subprocess.run(["grim", "-g", os.environ["WORKSPACE_TEST_GEOMETRY"],
                            str(Path(directory) / (name + ".png"))], check=True)

    if adaptive:
        def visible(name):
            return any(obj.get_name() == name and obj.get_state_set().contains(Atspi.StateType.SHOWING)
                       for obj in descendants(Atspi.get_desktop(0)))

        def bounds(name):
            obj = lookup(name, actionable=False)
            return Atspi.Component.get_extents(obj, Atspi.CoordType.WINDOW)

        def escape():
            subprocess.run(["wtype", "-s", "60", "-k", "Escape"], check=True)

        if os.environ.get("WORKSPACE_TEST_LARGE_TEXT"):
            # The same 1440px window now needs a drawer for its agent as well.
            lookup("Toggle Explorer drawer")
            lookup("Toggle OpenCode drawer")
            click("Toggle OpenCode drawer")
            click("Birch")
            lookup("Cedar")
            lookup("Task output", actionable=False)
            capture("large-text-model")
            print("Verified large-text drawer layout retains both the model picker and dock at desktop width.")
            return
        lookup("Birch")
        composer = lookup("Message OpenCode", actionable=False)
        assert composer.set_text_contents("Drawer draft")
        fixture("resize", width=920)
        lookup("Toggle Explorer drawer")
        assert not visible("Toggle OpenCode drawer")
        lookup("Birch")
        assert not visible("Restore cursor") or not visible("Review watcher")
        click("Toggle Explorer drawer")
        lookup("Review watcher")
        escape()
        lookup("Toggle Explorer drawer")
        fixture("resize", width=680)
        lookup("Toggle OpenCode drawer")
        assert not visible("Message OpenCode")
        lookup("Task output", actionable=False)
        click("Toggle OpenCode drawer")
        lookup("Birch")
        assert bounds("Message OpenCode").y < bounds("Task output").y
        assert Atspi.Text.get_text(lookup("Message OpenCode", False), 0, -1) == "Drawer draft"
        click("Birch")
        lookup("Cedar")
        if directory := os.environ.get("WORKSPACE_TEST_CAPTURES"):
            frame = fixture("geometry")
            geometry = "{x},{y} {width}x{height}".format(**frame)
            subprocess.run(["grim", "-g", geometry, str(Path(directory) / "narrow-model.png")], check=True)
        click("Cedar")
        until = time.monotonic() + 3
        while fixture("current-model") != "cedar":
            assert time.monotonic() < until, "The service did not receive the model change"
            time.sleep(.05)
        lookup("Cedar")
        escape()
        fixture("resize", width=1440)
        lookup("Review watcher")
        lookup("Cedar")
        assert not visible("Toggle Explorer drawer") and not visible("Toggle OpenCode drawer")
        assert Atspi.Text.get_text(lookup("Message OpenCode", False), 0, -1) == "Drawer draft"
        # A temporarily opened drawer must not overwrite an explicitly hidden pin.
        subprocess.run(["wtype", "-M", "ctrl", "-k", "b", "-m", "ctrl"], check=True)
        deadline = time.monotonic() + 3
        while visible("Review watcher"):
            assert time.monotonic() < deadline, "Explorer pin did not close"
            time.sleep(.05)
        lookup("Cedar")
        fixture("resize", width=680)
        click("Toggle Explorer drawer")
        lookup("Review watcher")
        fixture("resize", width=1440)
        lookup("Cedar")
        assert not visible("Review watcher")
        print("Verified adaptive drawers, session model and draft, bottom dock access and manually hidden pin restoration.")
        return

    if offline:
        click("Restore")
        lookup("Recovery copied safely", actionable=False)
        click("Keep for later")
        lookup("Start OpenCode with opencode service start, then reconnect.", actionable=False)
        composer = lookup("Message OpenCode", actionable=False)
        assert Atspi.Text.get_text(composer, 0, -1) == "Draft saved before restart"
        assert composer.set_text_contents("Offline edit")
        click("Review changes")
        lookup("Previously applied to the editor", actionable=False)
        click("Next change")
        lookup("renamed-image.bin   ·   1/1   ·   +0 −0", actionable=False)
        click("Mark file reviewed")
        lookup("File reviewed", actionable=False)
        click("Next change")
        lookup("test-binary.bin   ·   1/1   ·   +0 −0", actionable=False)
        click("Mark file reviewed")
        lookup("File reviewed", actionable=False)
        return

    source = buffer_with("staged and edited locally\n")
    assert Atspi.Text.add_selection(source, 0, 6)
    click("Earlier messages")
    buffer_with("An older message from this thread.", contains=True)
    click("Attach selected code")
    lookup("hello.txt · L1–1")
    composer = lookup("Message OpenCode", actionable=False)
    assert composer.set_text_contents("Keep this draft across model switches")
    click("Birch")
    lookup("Retired")
    capture("model-selection")
    click("Retired")
    lookup("This model has been retired", actionable=False)
    assert Atspi.Text.get_text(composer, 0, -1) == "Keep this draft across model switches"
    click("Birch")
    click("Cedar")
    click("Review watcher")
    lookup("Birch")
    click("Restore cursor")
    lookup("Cedar")
    fixture("external-change")
    lookup("Birch")
    fixture("missed-event")
    lookup("Cedar")
    assert Atspi.Text.get_text(composer, 0, -1) == "Keep this draft across model switches"
    click("hello.txt · L1–1")
    buffer_with("staged")
    click("Remove selection")
    click("Send to this session")
    click("Delivery unknown · Retry this prompt")
    lookup("Keep this draft across model switches", actionable=False)
    click("Cancel queued prompt")
    click("New OpenCode session")
    lookup("Worktree test", actionable=False)
    click("Review changes")
    click("Side by side")
    lookup("Shared base", actionable=False)
    lookup("Agent worktree", actionable=False)
    capture("split-review")
    click("Apply hunk")
    lookup("Applied to unsaved buffer", actionable=False)
    click("Return to editor")

    editor = buffer_with("agent edit\n")
    assert editor.set_text_contents("my unsaved edit\n")
    click("Review changes")
    lookup("Previously applied to the editor", actionable=False)
    click("Apply hunk")
    lookup("Resolve overlapping edits", actionable=False)
    capture("conflict")
    click("Keep my edit")
    click("Return to editor")
    buffer_with("my unsaved edit\n")
    click("Review changes")
    lookup("Previously skipped", actionable=False)
    click("Apply hunk")
    click("Use agent change")
    lookup("Applied to unsaved buffer", actionable=False)
    click("Return to editor")
    editor = buffer_with("agent edit\n")
    subprocess.run(["wtype", "-s", "100", "-M", "ctrl", "-k", "z", "-m", "ctrl"], check=True)
    buffer_with("my unsaved edit\n")
    assert composer.set_text_contents("Draft saved before restart")


class Service(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, project):
        super().__init__(("127.0.0.1", 0), API)
        self.project = project
        self.password = secrets.token_urlsafe(20)
        self.authorization = "Basic " + base64.b64encode(("opencode:" + self.password).encode()).decode()
        self.sessions = {}
        self.calls = []
        self.closed = threading.Event()
        self.events = queue.Queue()
        self.inbox = {}
        self.attempts = []
        self.cancelled = []
        self.add("ses_first", "Restore cursor", project, "birch")
        self.add("ses_second", "Review watcher", project, "cedar")
        self.sessions["ses_second"].pop("model")

    def add(self, sid, title, location, model, metadata=None):
        self.sessions[sid] = dict(id=sid, title=title, projectID="fixture",
                                  location={"directory": str(location)}, model={"id": model, "providerID": "local"},
                                  metadata=metadata or {})


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj, status=200):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.route(False)

    def do_POST(self):
        self.route(True)

    def do_DELETE(self):
        self.route(False)

    def route(self, post):
        service = self.server
        if self.headers.get("Authorization") != service.authorization:
            self.send_error(401)
            return
        path = urlsplit(self.path).path
        service.calls.append(path)
        if path == "/api/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'data: {"type":"server.connected"}\n\n')
            self.wfile.flush()
            while not service.closed.is_set():
                try:
                    event = service.events.get(timeout=.25)
                except queue.Empty:
                    continue
                if event is None:
                    break
                self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
                self.wfile.flush()
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"]))) if post else None
        if path == "/test" and post:
            if body["action"] == "current-model":
                return self.reply(service.sessions["ses_first"]["model"]["id"])
            if body["action"] in ("resize", "geometry"):
                return self.reply(service.window_geometry(body.get("width")))
            model = "birch" if body["action"] == "external-change" else "cedar"
            service.sessions["ses_first"]["model"] = {"id": model, "providerID": "local"}
            service.events.put({"type": "session.model.selected", "data": {"sessionID": "ses_first"}}
                               if model == "birch" else None)
            return self.reply({})
        if path == "/api/model/default":
            return self.reply({"data": {"id": "birch", "providerID": "local"}})
        if path == "/api/location":
            return self.reply({"project": {"id": "fixture"}, "directory": str(service.project)})
        if path == "/api/model":
            return self.reply({"data": [dict(id=x.lower(), name=x, providerID="local", enabled=True)
                                        for x in ("Birch", "Cedar", "Retired")]})
        if path == "/api/session":
            if post:
                tree = Path(body["location"]["directory"])
                assert tree.resolve() != service.project.resolve()
                assert (tree / "hello.txt").read_text() == "staged and edited locally\n"
                assert (tree / "untracked.txt").read_text() == "untracked baseline\n"
                (tree / "hello.txt").write_text("agent edit\n")
                (tree / "old-image.bin").rename(tree / "renamed-image.bin")
                (tree / "test-binary.bin").write_bytes(b"\x00\xf0agent")
                service.add("ses_created", "Worktree test", tree, "birch", body["metadata"])
                return self.reply({"data": service.sessions["ses_created"]})
            return self.reply({"data": list(service.sessions.values()), "cursor": {}})
        fields = path.strip("/").split("/")
        if len(fields) >= 3 and fields[1] == "session" and fields[2] in service.sessions:
            session = service.sessions[fields[2]]
            if len(fields) == 3:
                return self.reply({"data": session})
            if fields[3] == "model" and post:
                if body["model"]["id"] == "retired":
                    return self.reply({"_tag": "InvalidRequestError", "message": "This model has been retired"}, 400)
                session["model"] = body["model"]
                self.send_response(204)
                self.end_headers()
                return
            if fields[3] == "prompt" and post:
                item = dict(id=body["id"], sessionID=fields[2], type="user", payload={"text": body["text"]})
                service.attempts.append(item)
                if len(service.attempts) == 1:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                service.inbox[item["id"]] = item
                return self.reply({"data": item})
            if fields[3] == "inbox":
                if self.command == "DELETE":
                    service.cancelled.append(service.inbox.pop(fields[4]))
                    return self.reply({})
                return self.reply({"data": list(service.inbox.values())})
            if fields[3] == "message":
                if parse_qs(urlsplit(self.path).query).get("cursor") == ["older"]:
                    return self.reply({"data": [{"type":"user", "id":"msg_older", "text":"An older message from this thread."}], "cursor":{}})
                return self.reply({"cursor":{"next":"older"}, "data": [
                    {"type": "assistant", "id": "msg_answer", "content": [{"type": "text", "text": "The saved cursor is restored before the thread opens. I can add a bounds check in the isolated worktree."}]},
                    {"type": "user", "id": "msg_request", "text": "Keep my reading position when I reopen this session."}]})
            if fields[3] == "permission":
                return self.reply({"data": []})
        self.send_error(404)


def main(args):
    from pearl_session import PrivateSession, fixture_prefix
    from test_surfaces import IPC
    with PrivateSession(args.output / "session", tool_prefix=args.aqueous_prefix or fixture_prefix()) as session:
        project = session.base / "project"
        project.mkdir()
        def git(*argv):
            return subprocess.check_output(["git", "-C", str(project), *argv], env=session.env)
        git("init", "-q")
        file = project / "hello.txt"
        file.write_text("original\n")
        (project / "old-image.bin").write_bytes(b"\x00rename")
        (project / "test-binary.bin").write_bytes(b"\x00base")
        git("add", ".")
        git("-c", "user.email=test@localhost", "-c", "user.name=Fixture", "commit", "-qm", "Base")
        file.write_text("staged\n")
        git("add", "hello.txt")
        file.write_text("staged and edited locally\n")
        (project / "untracked.txt").write_text("untracked baseline\n")
        service = Service(project)
        threading.Thread(target=service.serve_forever, daemon=True).start()
        try:
            state = Path(session.env["XDG_STATE_HOME"]) / "opencode"
            state.mkdir()
            (state / "service.json").write_text(json.dumps({"url": f"http://127.0.0.1:{service.server_port}",
                                                            "password": service.password}))
            session.env["WORKSPACE_FIXTURE_URL"] = f"http://127.0.0.1:{service.server_port}"
            session.env["WORKSPACE_FIXTURE_AUTH"] = service.authorization
            if args.large_text:
                gtk_settings = Path(session.env["XDG_CONFIG_HOME"]) / "gtk-4.0/settings.ini"
                gtk_settings.parent.mkdir(exist_ok=True)
                gtk_settings.write_text("[Settings]\ngtk-xft-dpi=196608\n")
                session.env["WORKSPACE_TEST_LARGE_TEXT"] = "1"
            if args.light:
                prefs = Path(session.env["XDG_CONFIG_HOME"]) / "coral-workspace/preferences.ini"
                prefs.parent.mkdir(exist_ok=True)
                prefs.write_text("[Coral]\ntheme=1\n")
            session.env.pop("GTK_A11Y", None)
            session.child("access-bus", ["/usr/lib/at-spi-bus-launcher", "--launch-immediately"])
            session.run(["gdbus", "wait", "--session", "--timeout=5", "org.a11y.Bus"])
            registry = session.child("access-registry", ["/usr/lib/at-spi2-registryd"])
            registry.expect("well-known name")
            ipc = IPC(session)
            display = next(iter(ipc.outputs().values()))
            session.run(["wlr-randr", "--output", display["name"], "--custom-mode", "1800x1100@60Hz"])
            rules = Path(session.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
            rules.write_text(f'[[window]]\napp_id="org.aqueous.Coral.Workspace"\nfloating=true\nwidth={args.width}\nheight={args.height}\n')
            ipc.call("command", action="session.reload", fields={})
            def window_geometry(width=None):
                def rect():
                    return next((w["geometry"] for w in ipc.state() if w["kind"] == "window"
                                 and w.get("app_id") == "org.aqueous.Coral.Workspace"), {})
                if width:
                    rules.write_text(f'[[window]]\napp_id="org.aqueous.Coral.Workspace"\nfloating=true\nwidth={width}\nheight=800\n')
                    ipc.call("command",action="session.reload",fields={})
                    wait_for(lambda: abs(rect().get("width",0)-width) < 8)
                return rect()
            service.window_geometry = window_geometry
            application = session.child("workspace", [args.binary.resolve(), project, file], G_DEBUG="fatal-criticals")
            from pearl_session import wait_for
            wait_for(lambda: "/api/model" in service.calls)
            if args.capture_dir:
                args.capture_dir.mkdir(parents=True, exist_ok=True)
                geometry = next(node["geometry"] for node in ipc.state() if node["kind"] == "window" and node.get("app_id") == "org.aqueous.Coral.Workspace")
                session.env["WORKSPACE_TEST_CAPTURES"] = str(args.capture_dir.resolve())
                session.env["WORKSPACE_TEST_GEOMETRY"] = "{x},{y} {width}x{height}".format(**geometry)
            if args.adaptive:
                subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", "--adaptive"],
                               env=session.env, check=True, timeout=60)
                return
            subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive"], env=session.env,
                           check=True, timeout=65)
            assert service.sessions["ses_first"]["model"]["id"] == "cedar"
            assert "model" not in service.sessions["ses_second"]
            assert len(service.attempts) == 2 and service.attempts[0] == service.attempts[1]
            assert service.cancelled == service.attempts[:1]
            assert not service.inbox
            def draft_saved(text):
                files = (Path(session.env["XDG_STATE_HOME"]) / "coral-workspace/sessions").glob("*.json")
                return any(json.loads(path.read_text()).get("text") == text for path in files)
            wait_for(lambda: draft_saved("Draft saved before restart"))
            application.stop()
            (state / "service.json").rename(state / "offline.json")
            session.child("offline-workspace", [args.binary.resolve(), project, file], G_DEBUG="fatal-criticals")
            subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive", "--offline"],
                           env=session.env, check=True, timeout=20)
            wait_for(lambda: draft_saved("Offline edit"))
            assert file.read_text() == "staged and edited locally\n"
            assert git("show", ":hello.txt") == b"staged\n"
            print("Passed native selection, model sync, history paging, idempotent retry, queue cancellation, split review, conflict, undo, and offline draft recovery.")
        finally:
            service.closed.set()
            service.shutdown()
            service.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--drive", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--adaptive", action="store_true")
    parser.add_argument("--binary", type=Path, default=CORAL / "zig-out/bin/coral-workspace")
    parser.add_argument("--output", type=Path, default=CORAL / ".zig-cache/workspace-integration")
    parser.add_argument("--aqueous-prefix", type=Path)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--light", action="store_true")
    parser.add_argument("--large-text", action="store_true")
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=900)
    opts = parser.parse_args()
    if opts.drive:
        drive(opts.offline, opts.adaptive)
    else:
        main(opts)
