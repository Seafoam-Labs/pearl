#!/usr/bin/env python3
"""Regenerate the two missing namespaces using Ghostty's pinned GIR generator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NAMES = ("gtk4layershell1", "gtk4sessionlock1")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if generated files differ")
    parser.add_argument("--update-input-lock", action="store_true", help="explicitly accept changed system GIR inputs")
    args = parser.parse_args()
    if args.check and args.update_input_lock:
        parser.error("--check and --update-input-lock are mutually exclusive")
    os.chdir(ROOT)
    environment = dict(os.environ)
    environment.setdefault("ZIG_GLOBAL_CACHE_DIR", str(ROOT / ".cache/zig"))
    subprocess.run(["zig", "build", "-Dcodegen=true"], env=environment, check=True)
    lock_path = ROOT / "bindings/gir-inputs.json"
    if not args.update_input_lock:
        for name, expected in json.loads(lock_path.read_text()).items():
            path = ROOT / "bindings/gir" / name
            if not path.exists():
                path = Path("/usr/share/gir-1.0") / name
            if digest(path) != expected:
                raise SystemExit(f"GIR input changed: {name}; review before --update-input-lock")
    with tempfile.TemporaryDirectory(prefix="pearl-gir-", dir=ROOT / ".cache") as tmp:
        base = Path(tmp)
        output = base / "generated"
        codegen = ROOT / "zig-out/share/gir-codegen"
        subprocess.run([
            str(ROOT / "zig-out/bin/translate-gir"),
            f"--gir-dir={ROOT / 'bindings/gir'}", "--gir-dir=/usr/share/gir-1.0",
            f"--gir-fixes-dir={codegen / 'gir-fixes'}",
            f"--bindings-dir={codegen / 'binding-overrides'}",
            f"--extensions-dir={codegen / 'extensions'}",
            f"--output-dir={output}", f"--dependency-file={base / 'inputs.d'}",
            "Gtk4LayerShell-1.0", "Gtk4SessionLock-1.0",
        ], check=True)
        inputs = {}
        for filename in re.findall(r"(?:/[^\s:]+)\.gir", (base / "inputs.d").read_text()):
            path = Path(filename)
            inputs[path.name] = digest(path)
        if args.update_input_lock:
            lock_path.write_text(json.dumps(inputs, indent=2, sort_keys=True) + "\n")
        else:
            assert inputs == json.loads(lock_path.read_text()), "GIR dependency set changed"
        for name in NAMES:
            source = output / "src" / name
            target = ROOT / "bindings/generated" / name
            if args.check:
                assert {p.name for p in target.iterdir()} == {p.name for p in source.iterdir()}, f"Generated file set differs: {name}"
            for file in source.iterdir():
                if args.check:
                    assert (target / file.name).read_bytes() == file.read_bytes(), f"Regeneration differs: {name}/{file.name}"
                else:
                    target.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(file, target / file.name)
        print("PASS: layer-shell and session-lock bindings match pinned generation" if args.check else "Generated layer-shell and session-lock bindings")


if __name__ == "__main__":
    main()
