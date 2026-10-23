#!/usr/bin/env python3
"""Check the coordinated Aqueous checkout without installing or starting services."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def metadata(path):
    packages = {}
    current = None
    for line in path.read_text().splitlines():
        if ' = ' not in line:
            continue
        key, value = line.strip().split(' = ', 1)
        if key == 'pkgname':
            current = packages.setdefault(value, {})
        elif current is not None:
            current.setdefault(key, []).append(value)
    return packages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    for recipe, suffix in [('arch/aqueous-desktop', ''), ('arch/aqueous-desktop-git', '-git'), ('devario/aqueous-devario', '')]:
        packages = metadata(source / 'packaging' / recipe / '.SRCINFO')
        session = packages['aqueous-session' + suffix]['depends']
        assert 'xdg-desktop-portal-gtk' not in session, session
        pearl = packages['aqueous-shell-pearl' + suffix]['depends']
        assert 'pearl' + suffix in pearl, pearl
        assert 'pearl-capture-picker>=1' in pearl, pearl
        assert 'xdg-desktop-portal-pearl' + suffix not in pearl, pearl
        assert any(p.startswith('xdg-desktop-portal-aqueous' + suffix + '=') for p in pearl)
        assert 'xdg-desktop-portal-gtk' not in pearl
        if recipe.startswith('arch/'):
            for shell in ['dms', 'noctalia', 'none']:
                assert 'xdg-desktop-portal-gtk' in packages['aqueous-shell-' + shell + suffix]['depends']
    with tempfile.TemporaryDirectory(prefix='pearl-aqueous-integration-') as tmp:
        base = Path(tmp)
        for variant in ['stable', 'git']:
            stage = base / ('stage-' + variant)
            command = [source / 'packaging/stage-component.sh', 'session'] if variant == 'stable' else [source / 'packaging/git/desktop-stage.sh', 'git', 'session']
            subprocess.run(['bash', *command], env={**os.environ, 'DESTDIR': str(stage)}, check=True)
            instance = 'aqueous' if variant == 'stable' else 'aqueous-git'
            desktop = 'Aqueous' if variant == 'stable' else 'Aqueous-Git'
            pearl = 'Pearl' if variant == 'stable' else 'Pearl-Git'
            runtime = stage / 'usr/lib' / instance / 'session-runtime.sh'
            component = 'pearl' if variant == 'stable' else 'pearl-git'
            assert f'pearl_capture_picker=/usr/lib/{component}/pearl-capture-picker' in runtime.read_text()
            picker = base / ('picker-' + variant)
            picker.write_text('#!/bin/sh\ncat\n'); picker.chmod(0o755)
            runtime.write_text(runtime.read_text().replace(f'pearl_capture_picker=/usr/lib/{component}/pearl-capture-picker', f'pearl_capture_picker={picker}'))
            config = base / ('config-' + variant)
            (config / instance).mkdir(parents=True)
            run = base / ('run-' + variant)
            (run / instance).mkdir(parents=True)
            env = {**os.environ, 'XDG_CONFIG_HOME': str(config), 'XDG_RUNTIME_DIR': str(run),
                   'AQUEOUS_SYSCONFDIR': str(base / 'no-system'), 'WAYLAND_DISPLAY': 'private-test'}
            for shell in ['pearl', 'dms', 'noctalia', 'none']:
                (config / instance / 'session.toml').write_text('version = 1\nshell = "' + shell + '"\n')
                identity = subprocess.check_output([runtime, 'portal-identity'], env=env, text=True).strip()
                backend = subprocess.check_output([runtime, 'portal-backend'], env=env, text=True).strip()
                assert identity == (pearl + ':' + desktop if shell == 'pearl' else desktop), identity
                assert backend == ('xdg-desktop-portal-' + (pearl.lower() if shell == 'pearl' else 'gtk') + '.service'), backend
                if shell == 'pearl':
                    result=subprocess.run([runtime,'action','chooser'],input=b'Monitor: original  \n',env=env,capture_output=True,check=True)
                    assert result.stdout==b'Monitor: original  \n'

            (run / instance / 'welcome-session.json').write_text(json.dumps({'shell': 'pearl', 'display': 'private-test'}))
            assert subprocess.check_output([runtime, 'portal-identity'], env=env, text=True).strip() == pearl + ':' + desktop
            assert subprocess.check_output([runtime, 'portal-identity', 'selection'], env=env, text=True).strip() == desktop
            print('PASS staged ' + variant + ' shell identities, matching backend, and next-login selection semantics')
    print('PASS GTK-free Pearl preset dependencies and retained DMS/Noctalia/shell-free providers')


if __name__ == '__main__':
    main()
