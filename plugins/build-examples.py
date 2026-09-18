#!/usr/bin/env python3
"""Build real components from pinned WIT bindings. Downloads nothing."""
import argparse, os, shutil, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--wit-bindgen', required=True, type=Path)
p.add_argument('--wasm-tools', required=True, type=Path)
p.add_argument('--output', type=Path, default=ROOT/'.cache/plugin-examples')
p.add_argument('--cargo', default='cargo')
p.add_argument('--rustc')
p.add_argument('--fixtures', action='store_true')
p.add_argument('--skip-rust', action='store_true')
args = p.parse_args()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
def run(*cmd, **kw): subprocess.run([str(x) for x in cmd], check=True, cwd=ROOT, **kw)
def version(tool, expected):
    actual = subprocess.check_output([str(tool), 'version' if str(tool) == 'zig' else '--version'], text=True).strip()
    if expected not in actual: raise SystemExit(f'Expected {expected}; found {actual}')
version('zig', '0.16.0'); version(args.wit_bindgen, '0.62.0'); version(args.wasm_tools, '1.259.0')
generated = out/'bindings'; generated.mkdir(exist_ok=True)
run(args.wit_bindgen, 'c', ROOT/'plugins/wit', '--world', 'plugin', '--out-dir', generated)
for name in ('plugin.c', 'plugin.h'):
    if (generated/name).read_bytes() != (ROOT/'plugins/sdk/c'/name).read_bytes(): raise SystemExit(f'Stale generated SDK: {name}')
env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.cache/zig'))
for name in ('timer-c', 'companion-c', 'counter-zig'):
    source = ROOT/'plugins/examples'/name; destination = out/name; destination.mkdir(exist_ok=True)
    common = ['-target', 'wasm32-wasi', '-I', str(generated), str(generated/'plugin.c'), str(generated/'plugin_component_type.o')]
    core = out/(name+'.core.wasm')
    if name.endswith('-zig'):
        obj = out/'counter-zig.o'
        run('zig', 'build-obj', source/'plugin.zig', '-O', 'ReleaseSmall', '-target', 'wasm32-wasi', '-lc', '-I', generated, '-femit-bin='+str(obj), env=env)
        run('zig', 'cc', '-O2', '-mexec-model=reactor', obj, *common, '-o', core, env=env)
    else:
        run('zig', 'cc', '-O2', '-mexec-model=reactor', source/'plugin.c', *common, '-o', core, env=env)
    run(args.wasm_tools, 'component', 'new', core, '-o', destination/'plugin.wasm')
    run(args.wasm_tools, 'validate', destination/'plugin.wasm')
    shutil.copy2(source/'plugin.json', destination/'plugin.json')
    if name == 'companion-c':
        run('rsvg-convert', source/'cat.svg', '-o', destination/'cat.png')
        shutil.copy2(source/'LICENSE.assets', destination/'LICENSE.assets')
if not args.skip_rust:
    env.update(CARGO_HOME=str(ROOT/'.cache/plugin-cargo'), CARGO_TARGET_DIR=str(ROOT/'.cache/plugin-rust-target'))
    if args.rustc: env['RUSTC'] = args.rustc
    run(args.cargo, 'build', '--locked', '--offline', '--manifest-path', ROOT/'plugins/examples/counter-rust/Cargo.toml', '--release', '--target', 'wasm32-wasip2', env=env)
    destination = out/'counter-rust'; destination.mkdir(exist_ok=True)
    shutil.copy2(ROOT/'.cache/plugin-rust-target/wasm32-wasip2/release/pearl_counter.wasm', destination/'plugin.wasm')
    shutil.copy2(ROOT/'plugins/examples/counter-rust/plugin.json', destination/'plugin.json')
    run(args.wasm_tools, 'validate', destination/'plugin.wasm')
if args.fixtures:
    import json
    destination = out/'activity-fixture'; destination.mkdir(exist_ok=True)
    core = out/'activity-fixture.core.wasm'
    run('zig', 'cc', '-O2', '-mexec-model=reactor', ROOT/'tests/fixtures/plugin_activity.c', *common, '-o', core, env=env)
    run(args.wasm_tools, 'component', 'new', core, '-o', destination/'plugin.wasm')
    (destination/'plugin.json').write_text(json.dumps(dict(id='pearl.activity-fixture',name='Activity fixture',version='0.1.0',capabilities=dict(input_activity=True))))
    for case in range(1, 7):
        destination = out/f'fault-{case}'; destination.mkdir(exist_ok=True)
        core = out/f'fault-{case}.core.wasm'
        run('zig', 'cc', '-O2', '-mexec-model=reactor', f'-DTEST_CASE={case}', ROOT/'tests/fixtures/plugin_bad.c', *common, '-o', core, env=env)
        run(args.wasm_tools, 'component', 'new', core, '-o', destination/'plugin.wasm')
        (destination/'plugin.json').write_text(json.dumps(dict(id=f'pearl.fault-{case}',name='Failure fixture',version='0.1.0')))
    destination = out/'unknown-import'; destination.mkdir(exist_ok=True)
    wat = out/'unknown-import.wat'; wat.write_text('(component (import "unapproved:system/access" (func)))')
    run(args.wasm_tools, 'parse', wat, '-o', destination/'plugin.wasm')
    (destination/'plugin.json').write_text(json.dumps(dict(id='pearl.unknown',name='Unknown import fixture',version='0.1.0')))
print('Components:', out)
