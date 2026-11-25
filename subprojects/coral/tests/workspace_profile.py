#!/usr/bin/env python3
"""Measure the release workspace on a private Wayland desktop with a local streaming service."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

from opencode_workspace import API, Service, CORAL
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC
from wayland_test_input import pointer_move, pointer_click

THREAD_SIZE = 2000
FILES = 50000


def now():
    return time.monotonic_ns() // 1000


class ProfileAPI(API):
    def route(self, post):
        service = self.server
        url = urlsplit(self.path)
        if self.headers.get("Authorization") != service.authorization:
            return self.send_error(401)
        if post and url.path == "/profile":
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if data["action"] == "start":
                service.streaming.set()
            elif data["action"] == "pointer":
                service.point(data["x"], data["y"])
            return self.reply({})
        if not post and url.path.endswith("/message"):
            sid = url.path.split("/")[3]
            limit = int(parse_qs(url.query).get("limit", [100])[0])
            end = int(parse_qs(url.query).get("cursor", [THREAD_SIZE])[0])
            if end == THREAD_SIZE and service.streaming.is_set():
                service.head_chunks[sid].add(service.chunks)
            start = max(0, end - limit)
            service.pages[sid].add((start, end))
            rows = []
            for i in reversed(range(start, end)):
                body = f"{sid} message {i:04d}. Review the change to the saved cursor."
                if i == THREAD_SIZE - 1:
                    body += f" Streaming chunk {service.chunks}."
                rows.append({"type": "assistant", "id": f"{sid}-{i}", "content": [{"type": "text", "text": body}]})
            return self.reply({"data": rows, "cursor": {"next": str(start)} if start else {}})
        event_stream = url.path == "/api/event"
        if event_stream:
            service.event_open.set()
        try:
            super().route(post)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if event_stream:
                service.event_open.clear()


def drive():
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
    phases = {}

    @contextmanager
    def phase(name):
        start = now()
        yield
        phases[name] = [start, now()]

    def post(action, **data):
        request = Request(os.environ["PROFILE_URL"] + "/profile", data=json.dumps(dict(action=action, **data)).encode(),
                          headers={"Authorization": os.environ["PROFILE_AUTH"]})
        with urlopen(request, timeout=10) as reply:
            return json.load(reply)

    def nodes(parent):
        yield parent
        for i in range(parent.get_child_count()):
            child = parent.get_child_at_index(i)
            if child:
                yield from nodes(child)

    def find(predicate):
        def search():
            return next((node for node in nodes(Atspi.get_desktop(0)) if predicate(node)
                         and node.get_state_set().contains(Atspi.StateType.SHOWING)), None)
        try:
            return wait_for(search, 10)
        except TimeoutError:
            shown = [n.get_name() for n in nodes(Atspi.get_desktop(0))
                     if n.get_state_set().contains(Atspi.StateType.SHOWING) and n.get_name()]
            raise AssertionError(f"Control missing during {tuple(phases)}. Visible controls: {shown[:20]} … {shown[-90:]}")

    def button(name):
        return find(lambda n: n.get_name() == name and n.get_role() != Atspi.Role.LABEL and n.get_n_actions() > 0
                    and n.get_state_set().contains(Atspi.StateType.SENSITIVE))

    def transcript(sid, oldest=1900):
        first = f"{sid} message {oldest:04d}."
        return find(lambda n: n.get_role() == Atspi.Role.TEXT and first in Atspi.Text.get_text(n, 0, 90))

    def keys(*args):
        subprocess.run(["wtype", "-s", "75", *args], check=True)

    transcript("ses_first")
    with phase("idle"):
        time.sleep(1)
    post("start")
    with phase("expand"):
        folder = find(lambda n: n.get_name().strip() == "▸ package-00")
        r = Atspi.Component.get_extents(folder, Atspi.CoordType.WINDOW)
        post("pointer", x=r.x + min(35, r.width // 2), y=r.y + r.height // 2)
        find(lambda n: (n.get_name() or "").strip().startswith("source-"))
    with phase("history"):
        for oldest in range(1800, -1, -100):
            assert button("Earlier messages").do_action(0)
            transcript("ses_first", oldest)
    full_thread = Atspi.Text.get_text(transcript("ses_first", 0), 0, -1)
    assert full_thread.count("ses_first message ") == THREAD_SIZE
    assert "ses_first message 1999." in full_thread and "ses_second message " not in full_thread
    with phase("typing"):
        keys("-M", "ctrl", "-k", "1", "-m", "ctrl", "-k", "End")
        word = "thequickbrownfoxjumpsoverthelazydog"
        keys("-d", "32", word)
        find(lambda n: n.get_role() == Atspi.Role.TEXT and word in Atspi.Text.get_text(n, 0, 100))
        time.sleep(.3)
    with phase("switch"):
        assert button("Review watcher").do_action(0)
        transcript("ses_second")
        assert button("Restore cursor").do_action(0)
        # Restoring the saved reading position can fetch earlier pages immediately.
        find(lambda n: n.get_role() == Atspi.Role.TEXT and "ses_first message " in Atspi.Text.get_text(n, 0, 90))
    keys("-M", "ctrl", "-k", "s", "-m", "ctrl")
    time.sleep(.7)
    Path(os.environ["PROFILE_PHASES"]).write_text(json.dumps(phases))


def distribution(values):
    data = sorted(values)
    assert data
    return {"samples": len(data), **{name: round(data[math.ceil(q * len(data)) - 1] / 1000, 2)
            for name, q in (("p50_ms", .5), ("p95_ms", .95), ("max_ms", 1))}}


def run(args):
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    binary = args.binary.resolve()
    with PrivateSession(out / "session", tool_prefix=args.aqueous_prefix or fixture_prefix()) as session:
        repo = session.base / "profile-repo"
        repo.mkdir()
        doc = repo / "main.txt"
        doc.write_text("Coral profile document\n")
        for folder in range(50):
            root = repo / f"package-{folder:02d}"
            root.mkdir()
            for i in range(999 if folder == 49 else 1000):
                (root / f"source-{i:04d}.txt").touch()
        for argv in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Large fixture"]):
            subprocess.run(["git", "-C", repo, *argv], env=session.env, check=True)
        assert subprocess.check_output(["git","-C",repo,"ls-files","-z"], env=session.env).count(b"\0") == FILES
        service = Service(repo, ProfileAPI)
        service.streaming = threading.Event()
        service.event_open = threading.Event()
        service.chunks = 0
        service.pages = {sid: set() for sid in service.sessions}
        service.head_chunks = {sid: set() for sid in service.sessions}
        for row in service.sessions.values():
            row["time"] = {"busy": 100}
        def stream():
            while not service.closed.is_set():
                if not service.streaming.wait(.1):
                    continue
                service.chunks += 1
                for sid in service.sessions:
                    service.events.put({"type": "session.text.delta", "data": {"sessionID": sid, "text": str(service.chunks)}})
                service.closed.wait(.025)
        threading.Thread(target=service.serve_forever, daemon=True).start()
        threading.Thread(target=stream, daemon=True).start()
        try:
            state = Path(session.env["XDG_STATE_HOME"]) / "opencode"
            state.mkdir()
            endpoint = f"http://127.0.0.1:{service.server_port}"
            (state / "service.json").write_text(json.dumps({"url": endpoint, "password": service.password}))
            session.env.update(PROFILE_URL=endpoint, PROFILE_AUTH=service.authorization, PROFILE_PHASES=str(out / "phases.json"))
            session.env.pop("GTK_A11Y", None)
            session.child("access-bus", ["/usr/lib/at-spi-bus-launcher", "--launch-immediately"])
            session.run(["gdbus", "wait", "--session", "--timeout=5", "org.a11y.Bus"])
            session.child("access-registry", ["/usr/lib/at-spi2-registryd"]).expect("well-known name")
            ipc = IPC(session)
            display = next(iter(ipc.outputs().values()))
            session.run(["wlr-randr", "--output", display["name"], "--custom-mode", "1440x900@60Hz"])
            rules = Path(session.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
            rules.write_text('[[window]]\napp_id="org.aqueous.Coral.Workspace"\nfloating=true\nwidth=1400\nheight=860\n')
            ipc.call("command", action="session.reload", fields={})
            def point(x, y):
                rect = next(w["geometry"] for w in ipc.state() if w["kind"] == "window" and w.get("app_id") == "org.aqueous.Coral.Workspace")
                pointer_move(session, x + rect["x"], y + rect["y"])
                pointer_click(session)
            service.point = point
            starts = []
            for i in range(4):
                start = now()
                app = session.child(f"workspace-{i}", [binary, repo, doc])
                app.expect("PROFILE first", 20)
                _, _, observed, presented = next(line.split() for line in app.lines if line.startswith("PROFILE first "))
                starts.append({"complete_us": int(observed) - start, "presented_us": int(presented) - start if int(presented) > 0 else None})
                if i == 3:
                    subprocess.run([sys.executable, str(Path(__file__).resolve()), "--drive"], env=session.env, check=True, timeout=120)
                session.run(["wtype", "-s", "100", "-M", "ctrl", "-k", "q", "-m", "ctrl"])
                assert app.wait(timeout=8) == 0
                if service.event_open.is_set():
                    service.events.put(None)
                    wait_for(lambda: not service.event_open.is_set(), 2)
            phases = json.loads((out / "phases.json").read_text())
            samples = {name: [] for name in phases}
            keys = []
            for line in app.lines:
                if line.startswith("PROFILE gaps "):
                    begin, *gaps = map(int, line.split()[2:])
                    for gap in gaps:
                        end = begin + gap
                        for name, (a, b) in phases.items():
                            if begin < b and end > a:
                                samples[name].append(gap)
                        begin = end
                elif line.startswith("PROFILE key "):
                    key, changed, complete, presented = map(int, line.split()[2:])
                    keys.append((changed - key, complete - key, presented - key if presented else None))
            assert len(service.pages["ses_first"]) == 20, service.pages
            assert len(service.head_chunks["ses_first"]) >= 2 and service.head_chunks["ses_second"], service.head_chunks
            assert service.chunks > 0 and len(keys) == 35, (service.chunks, len(keys))
            cpu = next(line.split(":",1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name"))
            _, _, mode, zig_version = next(line.split() for line in app.lines if line.startswith("PROFILE build "))
            libraries = {name: subprocess.check_output(["pkg-config", "--modversion", name], text=True).strip()
                         for name in ("gtk4", "gtksourceview-5", "libsoup-3.0")}
            result = {"cpu": cpu, "kernel": platform.release(), "backend": "Aqueous headless, 1440×900 at 60 Hz, Cairo",
                      "optimize": mode, "zig": zig_version, "libraries": libraries, "window_px": [1400, 860], "tracked_files": FILES, "messages_per_session": THREAD_SIZE, "sessions": 2,
                      "chunks_per_session": service.chunks, "distinct_head_updates": {sid: len(v) for sid, v in service.head_chunks.items()}, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                      "first_frame_prime_and_three_warm": starts, "main_context_5ms_heartbeat": {n: distribution(v) for n,v in samples.items()},
                      "key_to_buffer": distribution([k[0] for k in keys]), "key_to_frame_complete": distribution([k[1] for k in keys]),
                      "key_to_presentation": distribution([k[2] for k in keys if k[2] is not None]) if any(k[2] is not None for k in keys) else None}
            (out / "measurements.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result, indent=2))
        finally:
            service.closed.set()
            service.streaming.set()
            service.events.put(None)
            service.shutdown()
            service.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--drive", action="store_true")
    parser.add_argument("--binary", type=Path, default=CORAL / "zig-out/bin/coral-workspace-profile")
    parser.add_argument("--output", type=Path, default=CORAL / ".zig-cache/workspace-profile")
    parser.add_argument("--aqueous-prefix", type=Path)
    options = parser.parse_args()
    if options.drive:
        drive()
    else:
        run(options)
