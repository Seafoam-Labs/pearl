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
                        force_session='wayland:chosen.desktop', power=False, fingerprint_hint=True, password_first=True,
                        preferred_output='DP-1', preferred_output_edid='sha256:'+'ab'*32)
        config.write_text(json.dumps(original))
        def run(request, ok=True):
            result = subprocess.run([str(args.helper.resolve()), '--fixture', str(directory)],
                                    input=json.dumps(request), text=True, capture_output=True, timeout=10)
            assert (result.returncode == 0) == ok, result.stderr
            return json.loads(config.read_text())
        solid = dict(theme='gtk', gtk_theme='Adwaita', wallpaper_color='#123456', wallpaper_fit='cover', image=None)
        synced = run(solid)
        for key in ('allow_uwsm', 'force_session', 'power', 'fingerprint_hint', 'password_first', 'preferred_output', 'preferred_output_edid'):
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
        roles = {'surface': ('#141218', '#fdf7ff'), 'surface_container_low': ('#1d1b20', '#f7f2fa'),
                 'surface_container': ('#211f26', '#f3edf7'), 'surface_container_high': ('#2b2930', '#ece6f0'),
                 'on_surface': ('#e6e0e9', '#1d1b20'), 'on_surface_variant': ('#cac4d0', '#49454f'),
                 'primary': ('#d0bcff', '#6750a4'), 'on_primary': ('#381e72', '#ffffff'),
                 'primary_container': ('#4f378b', '#eaddff'), 'on_primary_container': ('#eaddff', '#21005d'),
                 'outline': ('#79747e', '#79747e'), 'error': ('#ffb4ab', '#8c1d18'),
                 'error_container': ('#601410', '#f9dedc')}
        palette_json = json.dumps({'colors': {role: {'dark': {'color': dark}, 'light': {'color': light}}
                                              for role, (dark, light) in roles.items()}}).encode()
        synced = run(dict(solid, palette=base64.b64encode(palette_json).decode()))
        palette_file = directory/'greeter-assets'/'palette.json'
        assert palette_file.read_bytes() == palette_json
        assert palette_file.stat().st_mode & 0o777 == 0o644
        synced = run(dict(solid, surface_opacity=10))
        assert synced['surface_opacity'] == 10
        flat = {'colors': {role: {'dark': {'color': '#777777'}, 'light': {'color': '#777777'}} for role in roles}}
        for invalid in (dict(solid, command='must-not-run'), dict(solid, wallpaper='/etc/shadow'),
                        dict(solid, gtk_theme='../bad'), dict(solid, wallpaper_color='red; color:white'),
                        dict(solid, image='invalid'), dict(solid, image=base64.b64encode(b'not an image').decode()),
                        dict(solid, palette=base64.b64encode(b'{"colors":{}}').decode()),
                        dict(solid, palette=base64.b64encode(json.dumps(flat).encode()).decode()),
                        dict(solid, surface_opacity=101)):
            before = config.read_bytes()
            palette_before = palette_file.read_bytes() if palette_file.exists() else None
            run(invalid, ok=False)
            assert config.read_bytes() == before
            assert (palette_file.read_bytes() if palette_file.exists() else None) == palette_before
        cleared = run(dict(theme='material_light', gtk_theme=None, wallpaper_color=None, image=None))
        assert cleared['wallpaper'] is None and cleared['gtk_theme'] is None and cleared['wallpaper_color'] is None
        assert cleared['surface_opacity'] is None
        assert not palette_file.exists()
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
