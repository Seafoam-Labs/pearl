#!/usr/bin/env python3
"""Record local inputs and hardware for T00 without contacting desktop services."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*argv):
    try:
        p = subprocess.run(argv, text=True, capture_output=True, timeout=20)
        return dict(exit=p.returncode, stdout=p.stdout.strip(), stderr=p.stderr.strip())
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(error=str(error))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def reference(path, scopes):
    listing = run('git', '-C', str(path), 'ls-files', '-z', '--', *scopes)
    assert listing.get('exit') == 0, listing
    files = listing['stdout'].split('\0')
    dirty = run('git', '-C', str(path), 'ls-files', '--others', '--exclude-standard', '-z')['stdout'].split('\0')
    return dict(path=str(path), revision=run('git', '-C', str(path), 'rev-parse', 'HEAD')['stdout'],
                status=run('git', '-C', str(path), 'status', '--short')['stdout'],
                submodules=run('git', '-C', str(path), 'submodule', 'status'),
                sha256={name: sha(path / name) for name in sorted(set(files + dirty)) if name and (path / name).is_file()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--aqueous-source', type=Path, default=Path('/home/zoey/RiderProjects/Aqueous'))
    parser.add_argument('--dms-source', type=Path, default=Path('/home/zoey/DankMaterialShell'))
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/t00/metadata.json')
    args = parser.parse_args()
    executable = ROOT / 'zig-out/bin/pearl-t00'
    dynamic = run('readelf', '-d', str(executable))
    linked = run('ldd', str(executable))
    compositor_linked = run('ldd', str(ROOT / '.cache/aqueous/bin/aqueous'))
    libraries = sorted(set(re.findall(r'=> (/\S+)', linked.get('stdout', '') + '\n' + compositor_linked.get('stdout', ''))))
    gobject = next((ROOT / 'zig-pkg').glob('gobject-0.3.2-*/build.zig'))
    pkg_names = ['gtk4', 'gtk4-layer-shell-0', 'glib-2.0', 'gio-2.0', 'gobject-2.0', 'pango', 'wayland-client', 'xkbcommon', 'pixman-1', 'Qt6Core']
    data = dict(
        recorded_utc=datetime.now(timezone.utc).isoformat(),
        sources={
            'aqueous': reference(args.aqueous_source, ['compositor', 'settingsApplication', 'LICENSE', 'LICENSES']),
            'dms': reference(args.dms_source, ['quickshell', 'dank-qml-common', 'LICENSE']),
            'dank-qml-common': reference(args.dms_source / 'dank-qml-common', ['.']),
        },
        machine=dict(kernel=platform.platform(), architecture=platform.machine(), logical_cpus=os.cpu_count(),
                     cpu=next(line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),
                     pci=run('lspci', '-nnk'), backlight_devices=[p.name for p in Path('/sys/class/backlight').iterdir()],
                     gpu_used='none: headless wlroots pixman + GTK cairo / Qt software',
                     output_setup='two 1280x720 headless outputs, scale 1; see outputs.json for refresh and geometry'),
        versions={name: run('pkg-config', '--modversion', name) for name in pkg_names},
        tools={name: dict(path=shutil.which(name), version=run(name, *switches),
                         sha256=sha(shutil.which(name)) if shutil.which(name) else None)
               for name, switches in [('zig', ['version']), ('quickshell', ['--version']), ('dms', ['version']), ('aqueous-config', ['version', '--shell', 'none'])]},
        builds=dict(pearl='zig build -Doptimize=ReleaseSafe (native target)',
                    aqueous='-Dvulkan-effects=false -Dman-pages=false -Doptimize=ReleaseSafe -Dllvm; pinned patched wlroots from source .deps/wlroots-render-hook'),
        binding_inventory=re.findall(r'pub const (\w+): Library', gobject.read_text()),
        elf_dynamic=dynamic, ldd=linked, aqueous_ldd=compositor_linked,
        shared_library_sha256={path: sha(path) for path in libraries},
        local_sha256={str(p.relative_to(ROOT)): sha(p) for p in [ROOT / 'build.zig.zon', ROOT / 'build.zig', executable,
            ROOT / '.cache/aqueous/bin/aqueous', ROOT / '.cache/aqueous/bin/aqueousctl', *sorted((ROOT / 'bindings').rglob('*')),
            *sorted((ROOT / 'spikes').rglob('*')), *sorted((ROOT / 'scripts').glob('*.py'))]
            if p.is_file()},
        font_match=run('fc-match', 'Inter Variable'),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()
