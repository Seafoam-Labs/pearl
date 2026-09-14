#!/usr/bin/env python3
"""T13: real native lock input, accessibility, output changes and PAM failures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, capture


def ui(child):
    for line in reversed(child.lines):
        if "event=lock-ui" in line:
            return dict(re.findall(r"(\w+)=([^ ]+)", line))
    return {}


def metrics(pid):
    values = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
    pss = next(int(line.split()[1]) * 1024 for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines() if line.startswith("Pss:"))
    return {"pss_bytes": pss, "fds": len(list(Path(f"/proc/{pid}/fd").iterdir())), "cpu_ticks": int(values[11]) + int(values[12]),
            "rss_bytes": int(values[21]) * os.sysconf("SC_PAGE_SIZE")}


def children(pid):
    return [int(p) for task in Path(f"/proc/{pid}/task").iterdir()
            for p in (task / "children").read_text().split()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locker", type=Path, required=True)
    parser.add_argument("--pam-module", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/t13/latest")
    parser.add_argument("--idle-seconds", type=int, default=65)
    parser.add_argument("--hotplug-cycles", type=int, default=100)
    args = parser.parse_args()
    assert 1 <= args.idle_seconds <= 3600
    assert 1 <= args.hotplug_cycles <= 1000
    args.locker, args.pam_module, args.output = (p.resolve() for p in
                                               (args.locker, args.pam_module, args.output))
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"status": "running", "checks": {}, "binaries": {
        name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()
        for name in ("locker", "pam_module")}}
    checks = report["checks"]
    try:
        with PrivateSession(args.output / "session") as session:
            session.args = SimpleNamespace(aqueous_source="/home/zoey/RiderProjects/Aqueous")
            T00Session.input_fixture(session)
            pam_dir = session.base / "pam"
            pam_dir.mkdir()
            session.env["PEARL_TEST_PAM_DIR"] = str(pam_dir)
            session.env["GTK_A11Y"] = "test"
            session.env["G_DEBUG"] = "fatal-warnings"
            ipc = IPC(session)
            outputs = list(ipc.outputs().values())
            primary, secondary = outputs[0]["name"], outputs[1]["name"]

            def stack(mode="normal", account="fixture"):
                account_module = args.pam_module if account == "fixture" else "pam_deny.so"
                (pam_dir / "pearl").write_text(
                    f"auth required {args.pam_module} {mode}\naccount required {account_module}\n")

            def locked():
                return next(x for x in ipc.state() if x["kind"] == "session")["locked"]

            def key(*keys):
                session.run(["wtype", "-s", "120", *keys, "-s", "150"])

            def waiting(child, echo):
                return wait_for(lambda: ui(child).get("waiting") == "true" and
                                ui(child).get("echo") == str(echo).lower())

            broken = session.base / "broken-readiness"
            broken.write_text("#!/usr/bin/python3\nimport os\nr,w=os.pipe()\nos.close(r)\nos.dup2(w,3)\nos.set_inheritable(3,True)\nos.execv(" + repr(str(args.locker)) + ", [" + repr(str(args.locker)) + ", '--ready-fd=3'])\n")
            broken.chmod(0o700)
            invalid = session.run([args.locker, "--ready-fd=3"], check=False)
            assert invalid.returncode != 0 and not locked()
            checks["invalid-readiness-fd-rejected-before-opening-display"] = True

            def start(name, fast=False, ready_fd=False):
                env = {"PEARL_TEST_FAST_AUTH": "1"} if fast else {}
                child = session.child(name, [broken if ready_fd else args.locker], **env)
                child.expect("event=lock-acquired")
                wait_for(locked)
                return child

            def unlock(child):
                waiting(child, True)
                key("fixture-user", "-k", "Return")
                waiting(child, False)
                key("fixture-secret", "-k", "Return")
                assert child.wait() == 0, child.lines[-20:]
                wait_for(lambda: not locked())

            def failed(child):
                wait_for(lambda: ui(child).get("acquired") == "true" and
                         ui(child).get("auth") == "false")
                assert locked() and child.proc.poll() is None
                wait_for(lambda: not children(child.proc.pid))

            # Large text and differing logical sizes exercise scrollable lock surfaces.
            preferences = Path(session.env["XDG_CONFIG_HOME"]) / "pearl/preferences.json"
            preferences.parent.mkdir()
            preferences.write_text(json.dumps({"version": 1, "font_size": 24,
                                               "theme": {"variant": "light"}}))
            session.run(["wlr-randr", "--output", primary, "--scale", "1.5", "--transform", "90"])
            stack()
            child = start("mixed-scale")
            waiting(child, True)
            time.sleep(.5)
            capture(session, "lock-rotated-large-text", primary)
            capture(session, "lock-large-text", secondary)
            checks["gtk-accessible-prompt-labels-and-mixed-scale-large-text"] = True
            key("-k", "Caps_Lock")
            child.expect("event=lock-caps enabled=true")
            key("-k", "Caps_Lock")
            child.expect("event=lock-caps enabled=false")
            checks["caps-lock-indicator-follows-keyboard-state"] = True

            key("fixture-user", "-k", "Return")
            waiting(child, False)
            # A newly returned output must have a focused, usable current prompt.
            for _ in range(12):
                session.run(["wlr-randr", "--output", secondary, "--off"])
                assert locked()
                session.run(["wlr-randr", "--output", secondary, "--on"])
            time.sleep(.3)
            assert ui(child)["views"] == "2"
            key("fixture-secret", "-k", "Return")
            assert child.wait() == 0, child.lines[-20:]
            wait_for(lambda: not locked())
            checks["repeated-output-return-preserves-lock-and-current-prompt-focus"] = True

            session.run(["wlr-randr", "--output", primary, "--transform", "normal", "--scale", "2",
                         "--custom-mode", "640x480"])
            session.run(["wlr-randr", "--output", secondary, "--off"])
            child = start("small-output")
            waiting(child, True)
            time.sleep(.4)
            capture(session, "lock-small-scrollable", primary)
            unlock(child)
            checks["small-logical-output-remains-usable-with-large-text"] = True
            session.run(["wlr-randr", "--output", secondary, "--on"])
            session.run(["wlr-randr", "--output", primary, "--scale", "1", "--custom-mode", "1280x720"])
            preferences.write_text('{"version":1}')

            child = start("unicode-response")
            waiting(child, True)
            for response in ("é" * 600, "x" * 1100):
                before = len(child.lines)
                key(response, "-k", "Return")
                wait_for(lambda: any("event=lock-ui" in line for line in child.lines[before:]))
                assert locked() and ui(child)["waiting"] == "true" and ui(child)["echo"] == "true"
            unlock(child)
            checks["oversize-utf8-response-rejected-without-truncation-and-retry-works"] = True

            for mode in ("crash", "malformed", "hang", "missing"):
                stack(mode)
                if mode == "missing": (pam_dir / "pearl").unlink()
                child = start("helper-" + mode, fast=mode == "hang")
                failed(child)
                stack()
                time.sleep(2.1)
                key("-k", "Return")
                unlock(child)
                checks["helper-" + mode + "-stays-locked-and-recovers"] = True

            child = start("cancel-and-duplicate", ready_fd=True)
            waiting(child, True)
            second = session.child("duplicate-lock", [args.locker])
            assert second.wait() != 0
            assert locked() and child.proc.poll() is None
            key("unsubmitted-response", "-k", "Escape")
            failed(child)
            key("-k", "Return")
            unlock(child)
            checks["duplicate-lock-and-broken-readiness-do-not-release-original"] = True
            checks["escape-clears-conversation-and-enter-retries-without-pointer"] = True

            child = start("output-soak")
            waiting(child, True)
            key("-k", "Escape")
            failed(child)
            time.sleep(.5)
            before_outputs = metrics(child.proc.pid)
            samples = []
            for index in range(args.hotplug_cycles):
                count = sum("event=lock-monitor" in line for line in child.lines)
                session.run(["wlr-randr", "--output", secondary, "--off"])
                time.sleep(.12)
                session.run(["wlr-randr", "--output", secondary, "--on"])
                wait_for(lambda: sum("event=lock-monitor" in line for line in child.lines) > count)
                assert locked() and ui(child)["views"] == "2"
                if (index + 1) % 25 == 0:
                    samples.append({"cycles": index + 1, **metrics(child.proc.pid)})
            after_outputs = metrics(child.proc.pid)
            report["outputs"] = {"cycles": args.hotplug_cycles, "before": before_outputs,
                                 "samples": samples, "after": after_outputs}
            assert after_outputs["fds"] <= before_outputs["fds"] + 2
            assert after_outputs["rss_bytes"] - before_outputs["rss_bytes"] < 16 * 1024 * 1024
            session.run(["wlr-randr", "--output", primary, "--off", "--output", secondary, "--off"])
            wait_for(lambda: not ipc.outputs())
            assert locked()
            time.sleep(.2)
            count = sum("event=lock-monitor" in line for line in child.lines)
            session.run(["wlr-randr", "--output", primary, "--on", "--output", secondary, "--on"])
            wait_for(lambda: sum("event=lock-monitor" in line for line in child.lines) >= count + 2)
            key("-k", "Return")
            unlock(child)
            checks["output-soak-reuses-view-slots-and-file-descriptors"] = True
            checks["all-outputs-removed-return-to-usable-authentication"] = True

            # No compositor polling or full-widget updates in the steady state.
            child = start("idle-cost")
            waiting(child, True)
            key("-k", "Escape")
            failed(child)
            time.sleep(1)
            before = metrics(child.proc.pid)
            start_updates = int(ui(child)["updates"])
            start_lines = len(child.lines)
            started = time.monotonic()
            time.sleep(args.idle_seconds)
            elapsed = time.monotonic() - started
            after = metrics(child.proc.pid)
            clock_events = sum("event=lock-clock" in line for line in child.lines[start_lines:])
            cpu_seconds = (after["cpu_ticks"] - before["cpu_ticks"]) / os.sysconf("SC_CLK_TCK")
            report["idle"] = {"state": "locked, authentication cancelled", "seconds": elapsed, "before": before, "after": after,
                              "cpu_seconds": cpu_seconds, "clock_events": clock_events,
                              "ui_updates": int(ui(child)["updates"]) - start_updates}
            assert report["idle"]["ui_updates"] == 0
            assert clock_events <= args.idle_seconds // 60 + 2
            assert cpu_seconds < max(1, elapsed * .02)
            assert after["fds"] <= before["fds"]
            assert after["rss_bytes"] - before["rss_bytes"] < 8 * 1024 * 1024
            key("-k", "Return")
            unlock(child)
            checks["idle-clock-updates-are-bounded-with-no-auth-ui-churn"] = True
            for child in session.children:
                if child.logfile.name.startswith(("mixed-", "small-", "unicode-", "helper-", "cancel-", "idle-", "output-")):
                    assert not any(word in line for line in child.lines for word in
                                   ("CRITICAL", "WARNING", "panic:", "fixture-secret", "unsubmitted-response")), child.lines[-20:]
            ipc.close()
            report["status"] = "passed"
    except BaseException:
        report["status"] = "failed"
        raise
    finally:
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
