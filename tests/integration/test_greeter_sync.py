#!/usr/bin/env python3
"""Exercise the native appearance writer against a private configuration directory."""
import argparse
import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-sync-') as tmp:
        directory = Path(tmp)
        config = directory/'greeter.json'
        original = dict(version=1, theme='material_dark', gtk_theme='old', allow_uwsm=False,
                        force_session='wayland:chosen.desktop', power=False, fingerprint_hint=True)
        config.write_text(json.dumps(original))
        def run(request, ok=True):
            result = subprocess.run([str(args.helper.resolve()), '--fixture', str(directory)],
                                    input=json.dumps(request), text=True, capture_output=True, timeout=10)
            assert (result.returncode == 0) == ok, result.stderr
            return json.loads(config.read_text())
        solid = dict(theme='gtk', gtk_theme='Adwaita', wallpaper_color='#123456', wallpaper_fit='cover', image=None)
        synced = run(solid)
        for key in ('allow_uwsm', 'force_session', 'power', 'fingerprint_hint'):
            assert synced[key] == original[key]
        assert synced['wallpaper_color'] == '#123456' and synced['gtk_theme'] == 'Adwaita'
        assert synced['wallpaper'] is None
        def chunk(kind, data):
            return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
        png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))+chunk(b'IDAT', zlib.compress(b'\x00\x12\x34\x56'))+chunk(b'IEND', b'')
        image = dict(solid, image=base64.b64encode(png).decode(), wallpaper_fit='contain')
        synced = run(image)
        asset = Path(synced['wallpaper'])
        assert asset.parent == directory/'greeter-assets' and asset.read_bytes() == png
        assert asset.stat().st_mode & 0o777 == 0o644
        assert config.stat().st_mode & 0o777 == 0o644
        assert synced['wallpaper_fit'] == 'contain'
        for invalid in (dict(solid, command='must-not-run'), dict(solid, wallpaper='/etc/shadow'),
                        dict(solid, gtk_theme='../bad'), dict(solid, wallpaper_color='red; color:white'),
                        dict(solid, image='invalid'), dict(solid, image=base64.b64encode(b'not an image').decode())):
            before = config.read_bytes()
            run(invalid, ok=False)
            assert config.read_bytes() == before
        cleared = run(dict(theme='material_light', gtk_theme=None, wallpaper_color=None, image=None))
        assert cleared['wallpaper'] is None and cleared['gtk_theme'] is None and cleared['wallpaper_color'] is None
        # Refuse a substituted config file, preserving the target.
        target = directory/'target'
        config.rename(target)
        config.symlink_to(target)
        before = target.read_bytes()
        run(solid, ok=False)
        assert target.read_bytes() == before
        config.unlink()
        target.rename(config)
        # Refuse a substituted assets directory.
        assets = directory/'greeter-assets'
        assets.rename(directory/'original-assets')
        assets.symlink_to(directory/'original-assets')
        before = config.read_bytes()
        run(image, ok=False)
        assert config.read_bytes() == before
    print('Native greeter sync: appearance copy, image assets, clearing, policy preservation and invalid-input checks passed.')


if __name__ == '__main__':
    main()
