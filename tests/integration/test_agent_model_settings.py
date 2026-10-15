#!/usr/bin/env python3
"""Native model and resource edits; no model loading, downloads or live services."""
import argparse
import json
from pathlib import Path
import time
from test_settings_app import PrivateSession, IPC, wait_for, probe, windows, click_widget, keys, capture
from settings_editor import EditorPeer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pearl", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--ctl", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("/tmp/pearl-model-settings-check"))
    args = parser.parse_args()
    checks = {}
    args.output.mkdir(parents=True, exist_ok=True)
    with PrivateSession(args.output / "session") as session:
        session.env["PEARL_TEST_CTL"] = str(args.ctl.resolve())
        ipc = IPC(session)
        rules = Path(session.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
        rules.write_text('[[window]]\napp_id = "org.aqueous.Pearl.Settings"\nfloating = true\nwidth = 1040\nheight = 760\n')
        legacy = Path(session.env["XDG_CONFIG_HOME"]) / "pearl/last-good.json"
        legacy.parent.mkdir(parents=True)
        legacy.write_text('{}')
        shell = session.child("pearl", [args.pearl.resolve()], G_DEBUG="fatal-warnings")
        shell.expect("event=control-ready")
        # The nested compositor can discard a frame after presenting it, which
        # GDK reports as a warning. Keep actual GTK criticals fatal.
        app = session.child("settings", [args.settings.resolve(), "--page", "assistant"], G_DEBUG="fatal-criticals")
        app.expect("event=settings-window-created")
        wait_for(lambda: probe(session, ipc)["connected"])
        peer = EditorPeer(session, ipc)
        def reach(field):
            if field in {"threads", "context", "tokens", "read_pages"}:
                section = next(c for c in probe(session, ipc)["controls"] if c["field"] == "assistant.resources_section")
                if not section["selected"]:
                    click_widget(session, ipc, reach("resources_section")["bounds"])
                    wait_for(lambda: next(c for c in probe(session, ipc)["controls"] if c["field"] == "assistant.resources_section")["selected"])
            for _ in range(80):
                view = probe(session, ipc)
                control = next(c for c in view["controls"] if c["field"] == "assistant." + field)
                rect, viewport = control["bounds"], view["body_bounds"]
                if rect["y"] >= viewport["y"] and rect["y"] + rect["height"] <= viewport["y"] + viewport["height"]:
                    return control
                window = windows(ipc)[0]["geometry"]
                session.run(["wlrctl", "pointer", "move", "-100000", "-100000"])
                session.run(["wlrctl", "pointer", "move", str(round(window["x"] + viewport["x"] + viewport["width"] / 2)), str(round(window["y"] + viewport["y"] + viewport["height"] / 2))])
                session.run(["wlrctl", "pointer", "scroll", "140" if rect["y"] > viewport["y"] else "-140", "0"])
                time.sleep(.1)
            raise AssertionError((field, rect, viewport))
        def settled():
            def ready():
                editor = probe(session, ipc)["editor"]
                return editor["can_edit"] and not editor["local"] and editor["upload"] == "none" and editor["download"] == "none" and not editor["state"]["busy"]
            wait_for(ready)
        try:
            original = json.loads(peer.document("committed"))["assistant"]
            for index, model_id in [(2, "qwen3-4b-instruct-2507-q4km"), (3, "liquid-lfm25-26b-q4km"), (4, "liquid-lfm25-12b-instruct-q4km"), (5, "custom")]:
                settled()
                click_widget(session, ipc, reach("model")["bounds"])
                keys(session, "Home", *(["Down"] * index), "Return")
                try:
                    draft = wait_for(lambda: (d if (d := json.loads(peer.document())["assistant"])["model_id"] == model_id else False))
                except TimeoutError:
                    (args.output / "model-failure.json").write_text(json.dumps({"expected": model_id, "draft": json.loads(peer.document()), "view": probe(session, ipc)}, indent=2))
                    raise
                assert draft["context_tokens"] == 0 and draft["answer_tokens"] == 0, draft
                assert json.loads(peer.document("committed"))["assistant"] == original
            peer.action("discard")
            wait_for(lambda: not probe(session, ipc)["editor"]["state"]["dirty"])
            checks["all_suggested_models_and_custom_are_selectable_in_draft"] = True
            for field, key, value in [("threads", "cpu_threads", 8), ("context", "context_tokens", 16384), ("tokens", "answer_tokens", 2048)]:
                settled()
                # Click the editable text, not the spin button's stepper half.
                rect = dict(reach(field)["bounds"])
                rect["width"] /= 3
                click_widget(session, ipc, rect)
                session.run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-s", "100", str(value), "-s", "500", "-k", "Tab"])
                try:
                    wait_for(lambda: json.loads(peer.document())["assistant"][key] == value)
                except TimeoutError:
                    (args.output / "edit-failure.json").write_text(json.dumps({"field": field, "expected": value, "draft": json.loads(peer.document()), "view": probe(session, ipc)}, indent=2))
                    capture(session, "edit-failure")
                    raise
            assert json.loads(peer.document("committed"))["assistant"] == original
            view = wait_for(lambda: (v if (v := probe(session, ipc))["editor"]["can_apply"] else False))
            click_widget(session, ipc, next(c for c in view["controls"] if c["field"] == "apply")["bounds"])
            saved = wait_for(lambda: (d if (d := json.loads(peer.document("committed"))["assistant"])["cpu_threads"] == 8 else False))
            assert saved["context_tokens"] == 16384 and saved["answer_tokens"] == 2048, saved
            checks["explicit_resources_persist_only_after_apply"] = True
            checks["no_models_downloaded"] = not (Path(session.env["XDG_DATA_HOME"]) / "pearl/assistant/models").exists()
            assert checks["no_models_downloaded"]
        finally:
            peer.close()
    (args.output / "report.json").write_text(json.dumps({"status": "passed", "checks": checks}, indent=2) + "\n")


if __name__ == "__main__":
    main()
