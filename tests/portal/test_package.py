#!/usr/bin/env python3
"""Check candidate routing and install contents without modifying desktop routing."""
import configparser
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
parser=configparser.ConfigParser();parser.optionxform=str
parser.read(ROOT/'packaging/portal/pearl.portal')
interfaces=set(parser['portal']['Interfaces'].strip(';').split(';'))
implemented=set(subprocess.check_output([ROOT/'zig-out/bin/xdg-desktop-portal-pearl','--interfaces'],text=True).splitlines())
assert len(interfaces)==11 and interfaces==implemented
routes=configparser.ConfigParser();routes.optionxform=str
routes.read(ROOT/'packaging/portal/pearl-portals.conf');routing=routes['preferred']
assert routing['default']=='pearl'
for interface in interfaces:assert routing[interface]=='pearl'
for interface in ['ScreenCast','Screenshot']:assert routing['org.freedesktop.impl.portal.'+interface]=='aqueous'
assert 'gtk' not in set(routing.values())
with tempfile.TemporaryDirectory(prefix='pearl-portal-package-') as tmp:
    stage=Path(tmp)
    subprocess.run(['bash',ROOT/'packaging/portal/install.sh'],env={**os.environ,'DESTDIR':tmp},check=True)
    for path in ['usr/lib/pearl/xdg-desktop-portal-pearl','usr/lib/pearl/pearl-preview-helper','usr/lib/pearl/pearl-capture-picker','usr/share/xdg-desktop-portal/portals/pearl.portal','usr/share/xdg-desktop-portal/pearl-portals.conf','usr/lib/systemd/user/xdg-desktop-portal-pearl.service','usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.pearl.service']:
        assert (stage/path).is_file(),path
    assert not (stage/'usr/lib/systemd/user/graphical-session.target.wants').exists()
subprocess.run(['python3',ROOT/'tests/portal/generate_contracts.py','--check'],check=True)
print('PASS eleven implemented routes, Aqueous capture routing, staged activation and pinned contract generation')
# Co-installable identities share no package-owned paths. Build the Git candidate
# with --prefix zig-out/portal-git before this acceptance check.
git_binaries=ROOT/'zig-out/portal-git/bin'
if (git_binaries/'xdg-desktop-portal-pearl').exists():
    with tempfile.TemporaryDirectory(prefix='pearl-portal-coinstall-') as tmp:
        base=Path(tmp)
        for variant,binaries in [('stable',ROOT/'zig-out/bin'),('git',git_binaries)]:
            subprocess.run(['bash',ROOT/'packaging/portal/install.sh'],env={**os.environ,'DESTDIR':str(base/variant),'PEARL_VARIANT':variant,'PEARL_BINARY_DIR':str(binaries)},check=True)
        stable={p.relative_to(base/'stable') for p in (base/'stable').rglob('*') if p.is_file()}
        git={p.relative_to(base/'git') for p in (base/'git').rglob('*') if p.is_file()}
        assert not stable.intersection(git),stable.intersection(git)
        for variant,component in [('stable','pearl'),('git','pearl-git')]:
            assert (base/variant/f'usr/lib/{component}/pearl-preview-helper').is_file()
        cfg=configparser.ConfigParser();cfg.optionxform=str
        cfg.read(base/'git/usr/share/xdg-desktop-portal/pearl-git-portals.conf')
        assert cfg['preferred']['default']=='pearl-git'
        assert cfg['preferred']['org.freedesktop.impl.portal.ScreenCast']=='aqueous-git'
        assert cfg['preferred']['org.freedesktop.impl.portal.Screenshot']=='aqueous-git'
        descriptor=(base/'git/usr/share/xdg-desktop-portal/portals/pearl-git.portal').read_text()
        assert 'DBusName=org.freedesktop.impl.portal.desktop.pearl_git' in descriptor
        assert 'UseIn=Pearl-Git;' in descriptor
        failure=subprocess.run(['bash',ROOT/'packaging/portal/install.sh'],env={**os.environ,'DESTDIR':str(base/'wrong'),'PEARL_VARIANT':'git','PEARL_BINARY_DIR':str(ROOT/'zig-out/bin')},capture_output=True)
        assert failure.returncode==2
    print('PASS stable/Git package coinstallation, bundled helper ownership and mismatched-binary rejection')
else:
    print('SKIP Git coinstallation: build-portal -Dportal-variant=git --prefix zig-out/portal-git first')
