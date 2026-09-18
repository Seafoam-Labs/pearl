#!/usr/bin/env python3
"""Build/run the standalone spike; downloads nothing and changes no host setup."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--wasmtime-prefix", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--wasm-tools", type=Path, required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(out / "zig-global-cache"))


def run(*argv):
    subprocess.run(argv, cwd=out, env=env, check=True, timeout=180)


for name in ("main.zig", "build.zig", "guest.c", "guest.zig"):
    shutil.copy2(source / name, out / name)
run("zig", "cc", "-target", "wasm32-freestanding", "-nostdlib", "-O2",
    "-Wl,--no-entry", "-Wl,--export=run", "-o", "c.wasm", "guest.c")
run("zig", "build-exe", "guest.zig", "-target", "wasm32-freestanding",
    "-fno-entry", "-rdynamic", "-O", "ReleaseSmall", "-femit-bin=zig.wasm")
for language in ("c", "zig"):
    module = subprocess.check_output(
        [str(args.wasm_tools.resolve()), "print", str(out / f"{language}.wasm")],
        text=True, timeout=30,
    )
    # Replace only the outer module declaration, preserving generated contents.
    opening = module.index("\n")
    module = "(core module $guest" + module[opening:]
    (out / f"{language}.component.wat").write_text(f'''(component
      (import "increment" (func $increment (param "value" u32) (result u32)))
      (core func $lower (canon lower (func $increment)))
      {module}
      (core instance $host (export "increment" (func $lower)))
      (core instance $instance (instantiate $guest (with "pearl" (instance $host))))
      (func (export "run") (param "value" u32) (result u32)
        (canon lift (core func $instance "run"))))\n''')
run("zig", "build", "probe", f"-Dwasmtime-prefix={args.wasmtime_prefix.resolve()}")
