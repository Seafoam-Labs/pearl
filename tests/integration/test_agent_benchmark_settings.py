#!/usr/bin/env python3
"""Native benchmark selection, comparison, draft adoption and cancellation."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import time
from test_settings_app import PrivateSession, IPC, wait_for, probe, windows, click_widget, keys, resize
from test_surfaces import capture
from settings_editor import EditorPeer

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["pearl", "settings", "ctl", "model"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("/tmp/pearl-benchmark-settings"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    with PrivateSession(args.output / "session") as session:
        session.env["PEARL_TEST_CTL"] = str(args.ctl.resolve())
        session.env["DBUS_SYSTEM_BUS_ADDRESS"] = "unix:path=" + str(session.runtime / "system-bus")
        session.child("system-bus", ["dbus-daemon", "--session", "--nofork", "--address=" + session.env["DBUS_SYSTEM_BUS_ADDRESS"]])
        wait_for(lambda: session.run(["busctl", "--address=" + session.env["DBUS_SYSTEM_BUS_ADDRESS"], "list"], check=False).returncode == 0)
        session.env["PEARL_SECURITY_LOG"] = str(args.output / "security.jsonl")
        Path(session.env["PEARL_SECURITY_LOG"]).write_text("")
        authority = session.child("authority", ["python3", ROOT / "tests/fixtures/session_security.py"], input_pipe=True)
        authority.expect("event=ready")
        ipc = IPC(session)
        rules = Path(session.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
        rules.write_text('[[window]]\napp_id = "org.aqueous.Pearl.Settings"\nfloating = true\nwidth = 1040\nheight = 760\n')
        runtime = Path(session.env["XDG_DATA_HOME"]) / "benchmark_ok"
        runtime.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "tests/integration/fake_llama_server.py", runtime)
        runtime.chmod(0o755)
        model = runtime.parent / "pearl/assistant/models/LFM2.5-350M-Q4_K_M.gguf"
        model.parent.mkdir(parents=True)
        try:
            os.link(args.model.resolve(), model)
        except OSError:
            shutil.copyfile(args.model, model)
        legacy = Path(session.env["XDG_CONFIG_HOME"]) / "pearl/last-good.json"
        legacy.parent.mkdir(parents=True)
        legacy.write_text(json.dumps({"assistant": {"cpu_threads": 8, "context_tokens": 8192, "runtime": {"source": "custom", "executable": str(runtime)}}}))
        shell = session.child("pearl", [args.pearl.resolve()], G_DEBUG="fatal-criticals")
        shell.expect("event=control-ready")
        # The frontend must start after the asynchronous initial preferences load.
        shell.expect("event=preferences-applied")
        wait_for(lambda: not json.loads(session.run([args.ctl.resolve(), "assistant", "status"]).stdout)["result"]["locked"])
        app = session.child("settings", [args.settings.resolve(), "--page", "assistant"], G_DEBUG="fatal-criticals")
        app.expect("event=settings-window-created")
        wait_for(lambda: probe(session, ipc)["connected"])
        peer = EditorPeer(session, ipc)
        history = Path(session.env["XDG_STATE_HOME"]) / "pearl/assistant/benchmarks"

        def control(field):
            return next(c for c in probe(session, ipc)["controls"] if c["field"] == field)

        def reach(field):
            for _ in range(160):
                view = probe(session, ipc)
                rect = next(c for c in view["controls"] if c["field"] == field)["bounds"]
                viewport = view["body_bounds"]
                if rect and rect["height"] and rect["y"] >= viewport["y"] and rect["y"] + rect["height"] <= viewport["y"] + viewport["height"]:
                    time.sleep(.2)
                    stable = control(field)["bounds"]
                    if stable["y"] >= viewport["y"] and stable["y"] + stable["height"] <= viewport["y"] + viewport["height"]:
                        return stable
                    continue
                window = windows(ipc)[0]["geometry"]
                session.run(["wlrctl", "pointer", "move", "-100000", "-100000"])
                session.run(["wlrctl", "pointer", "move", str(round(window["x"] + viewport["x"] + viewport["width"] / 2)), str(round(window["y"] + viewport["y"] + viewport["height"] / 2))])
                session.run(["wlrctl", "pointer", "scroll", "80" if rect["y"] > viewport["y"] else "-80", "0"])
                time.sleep(.12)
            raise AssertionError((field, rect, viewport))

        def click(field):
            wait_for(lambda: control(field)["enabled"])
            click_widget(session, ipc, reach(field))

        def settled():
            return wait_for(lambda: (e := probe(session, ipc)["editor"])["can_edit"] and e["download"] == "none" and e["upload"] == "none" and not e["local"] and not e["state"]["busy"])

        def latest():
            files = sorted(history.glob("*.json"))
            return json.loads(files[-1].read_text()) if files else None

        def done():
            try:
                return wait_for(lambda: (report if (report := latest()) and report["state"] != "running" else False), 40)
            except TimeoutError:
                ctl = session.run([args.ctl.resolve(), "assistant", "status"], check=False)
                (args.output / "failure.json").write_text(json.dumps({"view": probe(session, ipc), "report": latest(), "draft": json.loads(peer.document()), "ctl": {"code": ctl.returncode, "stdout": ctl.stdout, "stderr": ctl.stderr}}, indent=2))
                raise

        try:
            original = json.loads(peer.document("committed"))["assistant"]
            settled()
            click("assistant.runtime_options")
            click("assistant.runtime_check")
            wait_for(lambda: "Compatible" in probe(session, ipc)["assistant_state"]["runtime"], 20)
            click("assistant.compute.1")
            settled()
            wait_for(lambda: "Not checked for this draft" in probe(session, ipc)["assistant_state"]["runtime"])
            assert json.loads(peer.document("committed"))["assistant"] == original
            peer.action("discard")
            settled()
            assert json.loads(peer.document())["assistant"] == original
            checks["runtime_check_invalidates_when_compute_draft_changes"] = True
            click("assistant.runtime_options")
            click("benchmark.open")
            assert not list(history.glob("*.json")), "Opening started a benchmark"
            assert list(model.parent.iterdir()) == [model]
            checks["opening_does_not_download_or_run"] = True
            for i in [0, 2, 3, 4]:
                click(f"benchmark.model.{i}")
            click("benchmark.start")
            report = done()
            wait_for(lambda: control("benchmark.start")["enabled"])
            assert len(report["results"]) == 1 and len(report["results"][0]["samples"]) == 16
            assert json.loads(peer.document("committed"))["assistant"] == original
            assert json.loads(peer.document())["assistant"] == original
            checks["comparison_keeps_preferences_unchanged"] = True
            click("benchmark.show.0")
            assert "RAM" in control("benchmark.samples")["text"] and "47" in control("benchmark.samples")["text"]
            click("benchmark.use.0")
            wait_for(lambda: json.loads(peer.document())["assistant"]["cpu_threads"] == 0)
            assert json.loads(peer.document("committed"))["assistant"] == original
            peer.action("discard")
            wait_for(lambda: not probe(session, ipc)["editor"]["state"]["dirty"])
            settled()
            assert json.loads(peer.document())["assistant"] == original
            click("benchmark.use.0")
            wait_for(lambda: probe(session, ipc)["editor"]["can_apply"])
            click_widget(session, ipc, control("apply")["bounds"])
            saved = wait_for(lambda: (d if (d := json.loads(peer.document("committed"))["assistant"])["cpu_threads"] == 0 else False))
            assert saved["context_tokens"] == 4096 and saved["answer_tokens"] == 384 and not saved["enabled"]
            checks["use_configuration_respects_apply_discard"] = True
            click("benchmark.export_button")
            time.sleep(.5)
            capture(session, "export-open")
            wait_for(lambda: not control("benchmark.export_button")["enabled"])
            exported = args.output.resolve() / "export.json"
            exported.unlink(missing_ok=True)
            session.run(["wtype", "-M", "ctrl", "-k", "l", "-m", "ctrl", "-s", "150", "-M", "ctrl", "-k", "a", "-m", "ctrl", str(exported), "-s", "150", "-k", "Return"])
            capture(session, "export-entered")
            time.sleep(.3)
            if not exported.exists():
                chooser = next(w for w in ipc.state() if w["kind"] == "window" and w.get("title") == "Export model comparison")["geometry"]
                session.run(["wlrctl", "pointer", "move", "-100000", "-100000"])
                session.run(["wlrctl", "pointer", "move", str(chooser["x"] + chooser["width"] - 45), str(chooser["y"] + 24)])
                session.run(["wlrctl", "pointer", "click"])
            wait_for(exported.exists)
            assert json.loads(exported.read_text())["id"] == report["id"]
            checks["export_selected_history"] = True
            runtime.touch()
            click("benchmark.refresh")
            assert not control("benchmark.use.0")["enabled"], "Changed runtime result remained applicable"
            checks["runtime_changes_mark_results_stale"] = True
            # Preserve the successful comparison while cancelling another run.
            slow = runtime.with_name("benchmark_delayed_answer")
            shutil.copyfile(runtime, slow)
            slow.chmod(0o755)
            draft = json.loads(peer.document())
            draft["assistant"]["runtime"]["executable"] = str(slow)
            peer.keep(json.dumps(draft))
            settled()
            click("benchmark.start")
            wait_for(lambda: control("benchmark.cancel_button")["enabled"])
            time.sleep(1)
            click("benchmark.cancel_button")
            cancelled = done()
            wait_for(lambda: control("benchmark.start")["enabled"])
            assert cancelled["state"] == "cancelled"
            assert len(list(history.glob("*.json"))) == 2
            with (Path(session.env["XDG_RUNTIME_DIR"]) / "pearl-assistant-runtime.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            checks["cancel_keeps_history_and_releases_runtime"] = True
            click("benchmark.delete_button")
            assert len(list(history.glob("*.json"))) == 1
            checks["delete_selected_history"] = True
            click("benchmark.start")
            wait_for(lambda: control("benchmark.cancel_button")["enabled"])
            wait_for(lambda: (report := latest()) and report["state"] == "running")
            # Close via the real GTK keyboard action; job must cancel and reap.
            session.run(["wtype", "-s", "200", "-M", "ctrl", "-k", "w", "-m", "ctrl"])
            # A dirty Settings draft may present its existing close confirmation.
            view = probe(session, ipc) if app.proc.poll() is None else None
            if view and view["editor"]["close_dialog"]:
                keys(session, "Escape")
                peer.action("discard")
                wait_for(lambda: not probe(session, ipc)["editor"]["state"]["dirty"])
                session.run(["wtype", "-s", "200", "-M", "ctrl", "-k", "w", "-m", "ctrl"])
            wait_for(lambda: app.proc.poll() is not None, 10)
            assert done()["state"] == "cancelled"
            checks["closing_cancels_comparison"] = True
            with (Path(session.env["XDG_RUNTIME_DIR"]) / "pearl-assistant-runtime.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert not list(Path(session.env["XDG_RUNTIME_DIR"]).glob("pearl-agent-key-*"))
            resize(session, rules, 480, 700)
            ipc.call("command", action="session.reload", fields={})
            app = session.child("settings-narrow", [args.settings.resolve(), "--page", "assistant"], G_DEBUG="fatal-criticals")
            app.expect("event=settings-window-created")
            wait_for(lambda: probe(session, ipc)["connected"] and probe(session, ipc)["narrow"])
            click("benchmark.open")
            click("benchmark.history")
            keys(session, "End", "Return")
            click("benchmark.show.0")
            assert probe(session, ipc)["width"] <= 500
            capture(session, "benchmark-narrow")
            checks["narrow_results_and_sample_controls"] = True
        except Exception:
            if app.proc.poll() is None:
                capture(session, "benchmark-failure")
                (args.output / "ui-failure.json").write_text(json.dumps({"view": probe(session, ipc), "draft": json.loads(peer.document()), "report": latest()}, indent=2))
            raise
        finally:
            peer.close()
    (args.output / "report.json").write_text(json.dumps({"status": "passed", "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
