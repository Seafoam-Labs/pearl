#!/usr/bin/env python3
"""The unified 'Window decorations' dropdown derives from and writes both
decoration.renderer and layout.force_ssd, and applies them atomically."""
import argparse
import json
from pathlib import Path
import time
from test_settings_app import PrivateSession, IPC, wait_for, probe, keys, resize, click_widget
from test_settings_appearance import ready, click, control
from test_settings_services import Peer, aq_ready, navigate
from pearl_session import fixture_prefix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pearl", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("/tmp/pearl-decoration-mode-check"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    with PrivateSession(args.output / "session", tool_prefix=fixture_prefix()) as session:
        session.env["GSETTINGS_BACKEND"] = "memory"
        session.env["DBUS_SYSTEM_BUS_ADDRESS"] = "unix:path=" + str(session.runtime / "no-system-bus")
        legacy = Path(session.env["XDG_CONFIG_HOME"]) / "pearl/last-good.json"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("{}")
        ipc = IPC(session)
        rules = Path(session.env["XDG_CONFIG_HOME"]) / "aqueous/rules.toml"
        resize(session, rules, 1200, 960)
        ipc.call("command", action="session.reload", fields={})
        shell = session.child("pearl", [args.pearl.resolve()], G_DEBUG="fatal-warnings")
        shell.expect("event=control-ready")
        app = session.child("settings", [args.settings.resolve(), "--page", "aqueous"], G_DEBUG="fatal-criticals")
        app.expect("event=settings-window-created")
        peer = Peer(session, ipc)
        ready(session, ipc)
        aq_ready(session, ipc, peer)
        navigate(session, ipc, "aqueous", "appearance")
        aq_ready(session, ipc, peer)

        def fields(document):
            return {f["id"]: f["value"] for f in document["fields"]}

        def changes():
            return {c["id"]: c["value"] for c in peer.aq_document("draft").get("changes", [])}

        def accept_review():
            for _ in range(6):
                if probe(session, ipc)["aqueous"]["shared_focus"] == "accept":
                    break
                keys(session, "Tab")
            assert probe(session, ipc)["aqueous"]["shared_focus"] == "accept"
            keys(session, "Return")
            wait_for(lambda: not probe(session, ipc)["aqueous"]["shared_review"])

        def apply():
            click_widget(session, ipc, control(session, ipc, "aqueous.apply"))
            wait_for(lambda: probe(session, ipc)["aqueous"]["shared_review"])
            accept_review()
            aq_ready(session, ipc, peer)

        wait_for(lambda: any(c["field"] == "aqueous.decoration-mode" for c in probe(session, ipc)["controls"]))
        checks["dropdown-present"] = True

        # Default configuration derives to "Off" (compositor + force_ssd false).
        committed = fields(peer.aq_document("committed"))
        assert committed["decoration.renderer"] == "compositor" and committed["layout.force_ssd"] is False, committed

        # Select "Pearl titlebars — all capable apps" (index 3 from Off).
        click(session, ipc, "aqueous.decoration-mode")
        time.sleep(.2)
        keys(session, "Down", "Down", "Down", "Return")
        aq_ready(session, ipc, peer)
        wait_for(lambda: changes().get("decoration.renderer") == "shell" and changes().get("layout.force_ssd") is True)
        checks["selection-stages-both-fields"] = True

        apply()
        committed = fields(peer.aq_document("committed"))
        assert committed["decoration.renderer"] == "shell" and committed["layout.force_ssd"] is True, committed
        checks["apply-commits-shell-force"] = True

        # Back to "Off" (index 0, three Up from index 3).
        click(session, ipc, "aqueous.decoration-mode")
        time.sleep(.2)
        keys(session, "Up", "Up", "Up", "Return")
        aq_ready(session, ipc, peer)
        wait_for(lambda: changes().get("decoration.renderer") == "compositor" and changes().get("layout.force_ssd") is False)
        apply()
        committed = fields(peer.aq_document("committed"))
        assert committed["decoration.renderer"] == "compositor" and committed["layout.force_ssd"] is False, committed
        checks["round-trip-off"] = True

        peer.close()
    print(json.dumps(checks, indent=2))
    print("PASS decoration mode dropdown")


if __name__ == "__main__":
    main()