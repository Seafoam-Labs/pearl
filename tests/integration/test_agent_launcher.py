#!/usr/bin/env python3
"""Real keyboard launcher handoff and Settings Apply, in a private desktop.

Requires an explicitly supplied local model and staged private runtime.
Search is a local fixture; no live Google requests or user settings are used.
"""
import argparse
import http.server
import json
import os
import shutil
from pathlib import Path
import sys
import threading
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from pearl_session import PrivateSession, wait_for, fixture_source
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture
from test_desktop import desktop, keys
from test_settings_app import apply_preferences, probe as settings_probe, click_widget, windows as settings_windows
from test_agent_ui import Search


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("pearl", "ctl", "locker", "pam-module", "agent", "settings", "model"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--aqueous", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/assistant/launcher")
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Search)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    checks = {}
    report = {"status": "running", "checks": checks}
    try:
        with PrivateSession(args.output / "session", aqueous=args.aqueous) as s:
            s.env["GTK_A11Y"] = "test"
            s.env["DBUS_SYSTEM_BUS_ADDRESS"] = "unix:path=" + str(s.runtime / "system-bus")
            s.child("system-bus", ["dbus-daemon", "--session", "--nofork", "--address=" + s.env["DBUS_SYSTEM_BUS_ADDRESS"]])
            wait_for(lambda: s.run(["busctl", "--address=" + s.env["DBUS_SYSTEM_BUS_ADDRESS"], "list"], check=False).returncode == 0)
            s.env["PEARL_SECURITY_LOG"] = str(s.output / "security.jsonl")
            Path(s.env["PEARL_SECURITY_LOG"]).write_text("")
            s.env["PEARL_TEST_LOCKER"] = str(args.locker.resolve())
            s.env["PEARL_TEST_AGENT"] = str(args.agent.resolve())
            s.env["PEARL_TEST_CTL"] = str(args.ctl.resolve())
            pam = s.base / "pam"
            pam.mkdir()
            (pam / "pearl").write_text(f"auth required {args.pam_module.resolve()}\naccount required {args.pam_module.resolve()}\n")
            s.env["PEARL_TEST_PAM_DIR"] = str(pam)
            s.args = SimpleNamespace(aqueous_source=str(fixture_source()))
            T00Session.input_fixture(s)
            authority = s.child("authority", ["python3", ROOT / "tests/fixtures/session_security.py"], input_pipe=True)
            authority.expect("event=ready")
            system_data = s.base / "system-data"
            system_data.mkdir()
            s.env["XDG_DATA_DIRS"] = str(system_data)
            desktop(s, "Question", "What is RAM?", command="/usr/bin/true")
            model_dir = Path(s.env["XDG_DATA_HOME"]) / "pearl/assistant/models"
            model_dir.mkdir(parents=True)
            os.link(args.model.resolve(), model_dir / "LFM2.5-350M-Q4_K_M.gguf")
            pearl = s.child("pearl", [args.pearl], G_DEBUG="fatal-warnings")
            pearl.expect("event=control-ready")
            pearl.expect("event=app-index-ready")
            pearl.expect("event=preferences-applied")
            ipc = IPC(s)

            def agent():
                return ctl(s, args.ctl, "assistant", "status")["result"]

            def probe():
                return ctl(s, args.ctl, "aqueous", "status", "--text", "test-launcher-calculator")["result"]

            def show():
                ctl(s, args.ctl, "launcher", "show")
                wait_for(lambda: (v := probe())["fresh"] and not v["pending"])

            def query(text):
                s.run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-k", "BackSpace", "--", text])
                return wait_for(lambda: (v if (v := probe())["query"] == text and v["fresh"] and not v["pending"] else False))

            wait_for(lambda: not agent()["locked"])
            assert not agent()["enabled"] and not agent()["running"]
            show()
            assert all(row["kind"] != "ask" for row in query("What is storage?")["rows"])
            assert not Search.requests
            checks["disabled_by_default_no_agent_or_search"] = True
            ctl(s, args.ctl, "launcher", "hide")
            runtime_path = args.agent.parent.parent / "libexec/pearl/assistant/llama-server"
            apply_preferences(s, args.ctl, assistant=dict(enabled=True, read_pages=False, default_provider_id="google", runtime=dict(source="custom", executable=str(runtime_path)),
                providers=[dict(id="google", kind="google", name="Google", endpoint=f"http://127.0.0.1:{server.server_port}")]))
            show()
            assert query("12*(3+4)")["rows"][0]["kind"] == "calculator"
            assert query("What is RAM?")["rows"][0]["kind"] == "app"
            v = query("What is the difference between RAM and storage?")
            assert v["rows"][0]["kind"] == "ask", v
            assert not agent()["running"] and not Search.requests
            checks["question_rank_exact_app_calculator_and_no_typing_inference"] = True
            capture(s, "launcher-question")
            keys(s, "Return")
            wait_for(lambda: status(s, args.ctl)["popup"] is None)
            windows = wait_for(lambda: [w for w in ipc.state() if w["kind"] == "window" and w.get("app_id") == "org.aqueous.Pearl.Agent"])
            assert windows[0]["floating"] and windows[0]["geometry"]["width"] == 440, windows
            try:
                wait_for(lambda: Search.requests, 60)
            except TimeoutError:
                capture(s, "handoff-failure")
                raise
            assert agent()["running"] and not agent()["handoff_pending"]
            checks["keyboard_enter_acknowledged_handoff_and_google_search"] = windows[0]["geometry"]
            # Focus changes must not dismiss the separate conversation window.
            show()
            assert any(w.get("app_id") == "org.aqueous.Pearl.Agent" for w in ipc.state())
            ctl(s, args.ctl, "launcher", "hide")
            checks["focus_change_keeps_chat"] = True
            ctl(s, args.ctl, "assistant", "clear")
            ctl(s, args.ctl, "assistant", "stop")
            assert not agent()["running"]
            ctl(s, args.ctl, "assistant", "show")
            wait_for(lambda: agent()["running"] and not agent()["handoff_pending"])
            checks["cli_clear_stop_and_resume"] = True
            output = next(iter(ipc.outputs().values()))
            s.run(["wlr-randr", "--output", output["name"], "--custom-mode", "1600x1100@60Hz"])
            (Path(s.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml").write_text('[[window]]\napp_id = "org.aqueous.Pearl.Settings"\nfloating = true\nwidth = 1040\nheight = 760\n')
            time.sleep(.3)
            settings = s.child("settings", [args.settings, "--page", "assistant"], G_DEBUG="fatal-warnings")
            settings.expect("event=settings-window-created")
            v = wait_for(lambda: (v if (v := settings_probe(s, ipc))["connected"] else False))
            assert v["page"] == "assistant", v
            def reach(field):
                for _ in range(60):
                    view = settings_probe(s, ipc)
                    control = next(c for c in view["controls"] if c["field"] == "assistant." + field)
                    rect, viewport = control["bounds"], view["body_bounds"]
                    if rect["y"] >= viewport["y"] and rect["y"] + rect["height"] <= viewport["y"] + viewport["height"]:
                        return control
                    win = settings_windows(ipc)[0]["geometry"]
                    s.run(["wlrctl", "pointer", "move", "-100000", "-100000"])
                    s.run(["wlrctl", "pointer", "move", str(round(win["x"] + viewport["x"] + viewport["width"] / 2)), str(round(win["y"] + viewport["y"] + viewport["height"] / 2))])
                    below = rect["y"] > viewport["y"]
                    s.run(["wlrctl", "pointer", "scroll", "140" if below else "-140", "0"])
                    time.sleep(.1)
                raise AssertionError(("assistant control unreachable", field, rect, viewport))
            expected = {"runtime_source", "runtime_path", "compute_mode", "device", "backend", "fallback", "discover", "runtime_check", "setup_runtime"}
            assert expected <= {c["field"].removeprefix("assistant.") for c in v["controls"]}
            before_check = len(Search.requests)
            click_widget(s, ipc, reach("setup_runtime")["bounds"])
            wait_for(lambda: "Using compatible installed runtime" in settings_probe(s, ipc)["assistant_state"]["runtime"], 15)
            assert len(Search.requests) == before_check
            assert not settings_probe(s, ipc)["editor"]["state"]["dirty"]
            checks["native_setup_reuses_compatible_runtime_without_installation"] = True
            click_widget(s, ipc, reach("discover")["bounds"])
            try:
                wait_for(lambda: "Runtime found" in settings_probe(s, ipc)["assistant_state"]["runtime"], 15)
            except TimeoutError:
                (args.output / "discovery-failure.json").write_text(json.dumps(settings_probe(s, ipc), indent=2))
                capture(s, "discovery-failure")
                raise
            click_widget(s, ipc, reach("runtime_check")["bounds"])
            wait_for(lambda: "Compatible" in settings_probe(s, ipc)["assistant_state"]["runtime"], 90)
            assert len(Search.requests) == before_check
            checks["native_runtime_discovery_and_local_check_without_search"] = True
            mode_control = reach("compute_mode")
            click_widget(s, ipc, mode_control["bounds"])
            keys(s, "Home", "Down", "Return")
            view = wait_for(lambda: (p if (p := settings_probe(s, ipc))["editor"]["can_apply"] else False))
            assert agent()["compute_mode"] == "cpu", agent()
            capture(s, "runtime-acceleration-settings")
            click_widget(s, ipc, next(c for c in view["controls"] if c["field"] == "apply")["bounds"])
            wait_for(lambda: agent()["compute_mode"] == "auto")
            checks["compute_draft_isolated_until_apply"] = True
            # An intentionally slow protocol fixture makes the active-answer
            # Apply confirmation deterministic; it is not an inference benchmark.
            slow_runtime = s.base / "slow_answer"
            shutil.copyfile(Path(__file__).with_name("fake_llama_server.py"), slow_runtime)
            slow_runtime.chmod(0o755)
            apply_preferences(s, args.ctl, assistant=dict(runtime=dict(source="custom", executable=str(slow_runtime)), compute=dict(mode="cpu")))
            wait_for(lambda: agent()["compute_mode"] == "cpu")
            click_widget(s, ipc, reach("compute_mode")["bounds"])
            keys(s, "Home", "Down", "Return")
            wait_for(lambda: settings_probe(s, ipc)["editor"]["can_apply"])
            show()
            assert query("What is fixture GPU failure?")["rows"][0]["kind"] == "ask"
            keys(s, "Return")
            wait_for(lambda: agent()["compute"]["busy"])
            view = settings_probe(s, ipc)
            click_widget(s, ipc, next(c for c in view["controls"] if c["field"] == "apply")["bounds"])
            wait_for(lambda: settings_probe(s, ipc)["assistant_state"]["apply_prompt"])
            assert agent()["compute_mode"] == "cpu" and agent()["compute"]["busy"]
            capture(s, "stop-and-apply")
            # Dialog defaults to Keep editing. Move to Stop & apply explicitly.
            keys(s, "Tab", "Return")
            wait_for(lambda: not settings_probe(s, ipc)["assistant_state"]["apply_prompt"])
            wait_for(lambda: agent()["compute_mode"] == "auto" and not agent()["compute"]["busy"])
            checks["active_answer_requires_stop_and_apply"] = True
            reach("enabled")
            control = wait_for(lambda: next((c for c in settings_probe(s, ipc)["controls"] if c["field"] == "assistant.enabled" and c["enabled"]), False))
            capture(s, "assistant-settings")
            time.sleep(.3)
            control = next(c for c in settings_probe(s, ipc)["controls"] if c["field"] == "assistant.enabled")
            click_widget(s, ipc, control["bounds"])
            try:
                v = wait_for(lambda: (v if (v := settings_probe(s, ipc))["editor"]["can_apply"] else False))
            except TimeoutError:
                (args.output / "settings-failure.json").write_text(json.dumps(settings_probe(s, ipc), indent=2))
                capture(s, "settings-failure")
                raise
            click_widget(s, ipc, next(c for c in v["controls"] if c["field"] == "apply")["bounds"])
            wait_for(lambda: not agent()["enabled"] and not agent()["running"])
            checks["native_settings_apply_disables_and_terminates_agent"] = True
        report["status"] = "passed"
    finally:
        server.shutdown()
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
