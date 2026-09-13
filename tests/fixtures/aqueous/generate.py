#!/usr/bin/env python3
"""Derive deterministic Pearl test cases from the read-only Aqueous IPC corpus."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Aqueous checkout")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    dest = Path(__file__).resolve().parent
    source = args.source / "compositor/scripts/fixtures/ipc"
    files = {}
    provenance = {}
    for name in ("hello-response", "snapshot-event", "snapshot-response", "delta-event",
                 "subscribe-response", "ack-response", "command-response", "accepted-exit",
                 "stale-session-error", "window-icon-response"):
        path = source / (name + ".json")
        raw = path.read_bytes()
        provenance[str(path.relative_to(args.source))] = hashlib.sha256(raw).hexdigest()
        files[name + ".json"] = json.loads(raw)

    # Synthetic extension of the real two-output snapshot, using schema-1 fields.
    desktop = json.loads(json.dumps(files["snapshot-event.json"]))
    batch = desktop["batch"]
    window = dict(kind="window", id="18446744073709551615", backend="xdg",
                  app_id="org.example.Editor", title="Draft 🐟", workspace="12", output="2",
                  geometry=dict(x=1300, y=30, width=640, height=480),
                  outer_geometry=dict(x=1298, y=28, width=644, height=484), layout="floating")
    window["class"] = None
    for flag in ("focused", "visible", "floating", "minimized", "maximized", "fullscreen",
                 "skip_taskbar", "skip_switcher", "always_above", "always_below", "snapped",
                 "fixed_position", "can_minimize", "can_maximize", "can_activate"):
        window[flag] = flag in ("floating", "can_minimize", "can_maximize", "can_activate")
    window["icon"] = dict(revision="18446744073709551615", name="text-editor", has_pixels=True)
    batch["upsert"].extend([
        window,
        dict(kind="keyboard", id="9007199254740993", seat="default", layouts=["English (US)", "German"], index=1),
        dict(kind="keyboard_device", id="9007199254740994", name="Test keyboard", seat="default", group="9007199254740993", virtual=False),
    ])
    for entity in batch["upsert"]:
        if entity["kind"] == "seat":
            entity["keyboard"] = "9007199254740993"
    files["desktop-event.json"] = desktop

    migration = dict(schema=1, session=batch["session"], sequence="8", base_sequence="1",
                     type="delta", upsert=[], removed=["output:2"])
    for entity in batch["upsert"]:
        if entity["kind"] in ("workspace", "window") and entity["output"] == "2":
            replacement = dict(entity, output="1")
            if entity["kind"] == "workspace":
                replacement["active"] = False
            migration["upsert"].append(replacement)
    files["output-removal-event.json"] = dict(ipc=1, event="state", delivery="2", batch=migration)

    for name, obj in list(files.items()):
        files[name] = (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    for name in ("aqueous-ipc-v1.schema.json", "aqueous-shell-v1.schema.json"):
        path = args.source / "compositor/protocol" / name
        provenance[str(path.relative_to(args.source))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for relative in ("compositor/aqueous/ShellManager.zig", "compositor/aqueous/IpcProtocol.zig",
                     "compositor/protocol/aqueous-ipc-v1.md", "compositor/protocol/aqueous-shell-v1.md"):
        provenance[relative] = hashlib.sha256((args.source / relative).read_bytes()).hexdigest()
    files["GPL-3.0-only.txt"] = (args.source / "compositor/LICENSES/GPL-3.0-only.txt").read_bytes()
    manifest = dict(source_revision=subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip(),
                    source_files_sha256=provenance,
                    fixtures_sha256={name: hashlib.sha256(raw).hexdigest() for name, raw in files.items()})
    files["provenance.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    for name, raw in files.items():
        path = dest / name
        if args.check:
            if not path.exists() or path.read_bytes() != raw:
                raise SystemExit(f"Fixture mismatch: {path}")
        else:
            path.write_bytes(raw)
    print(f"{'Verified' if args.check else 'Wrote'} {len(files)} fixture/license/provenance files")


if __name__ == "__main__":
    main()
