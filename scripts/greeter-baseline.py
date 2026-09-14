#!/usr/bin/env python3
"""Read-only greeter baseline capture. Never changes PAM, seats or services."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def command(*args):
    p = subprocess.run(args, text=True, capture_output=True)
    return {"status": p.returncode, "stdout": p.stdout.strip(), "stderr": p.stderr.strip()}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--greetd-source", type=Path, required=True)
    parser.add_argument("--aqueous-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"schema": 1, "evidence": "inspection-only", "real_login": False,
              "zig": command("zig", "version"), "pearl": command("git", "rev-parse", "HEAD"),
              "packages": command("pacman", "-Q", "greetd", "gtk4", "gtk4-layer-shell", "glib2", "systemd", "pam", "zig"),
              "kvm_available": Path("/dev/kvm").exists(), "binaries": {}, "sources": {}, "sessions": {}}
    for name in ("greetd", "aqueous", "zig"):
        path = shutil.which(name)
        if path:
            report["binaries"][name] = {"path": path, "sha256": digest(path)}
    for name, path in (("greetd", args.greetd_source), ("aqueous", args.aqueous_source)):
        report["sources"][name] = {"revision": command("git", "-C", str(path), "rev-parse", "HEAD"),
                                   "worktree": command("git", "-C", str(path), "status", "--short")}
    files = ("greetd/src/server.rs", "greetd/src/context.rs", "greetd/src/session/worker.rs", "greetd_ipc/src/lib.rs")
    report["sources"]["greetd"]["files"] = {f: digest(args.greetd_source / f) for f in files}
    for kind in ("wayland-sessions", "xsessions"):
        for path in sorted((Path("/usr/share") / kind).glob("*.desktop")):
            report["sessions"][f"{kind}/{path.name}"] = {"sha256": digest(path), "metadata": path.read_text()}
    report["gates"] = ["Aqueous restricted host enforcement unavailable at inspected revision",
                       "greetd cancellation while get_question holds context write lock requires VM proof/upstream fix",
                       "installed greetd distribution patches not verified against source",
                       "required GNOME/Plasma/standalone/X11 VM login matrix not run"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
