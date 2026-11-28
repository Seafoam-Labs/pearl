#!/usr/bin/env python3
"""Capture the shipped bar/dock layout presets as real desktop screenshots.

Runs Pearl in a private headless Aqueous (same harness as lock-screenshot.py),
seeds each preset's bar/dock settings and widget groups into the private
preferences, waits for the shell to paint, then screencopies the primary output
with grim. Captures are encoded for the settings preview bundle: AVIF by
default (smallest), WebP or PNG as fallbacks.
"""
import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'tests/integration'))
from pearl_session import PrivateSession
from test_surfaces import IPC


# An empty dock hides itself, so the capture seeds a few installed pins to show
# the applications strip the preset places.
PINS = [
    'firefox.desktop',
    'org.aqueous.Pearl.Settings.desktop',
    'ai.storyteller.filmcraft.desktop',
    'ai.storyteller.photocraft.desktop',
    'btop.desktop',
]


def seeded_preferences(preset):
    groups = {side: ','.join(preset.get('widgets', {}).get(side, [])) for side in ('left', 'center', 'right')}
    bar = dict(preset.get('bar') or {})
    bar['groups'] = groups
    return {'version': 1, 'bar': bar, 'dock': preset.get('dock') or {}, 'bar_dock_preset': preset['id'], 'pinned_apps': PINS}


def detail_sheet(png, preset_id):
    """Close-up of the elements that identify the layout: at tile size a whole
    desktop reduces the bar and dock to unreadable strips, so the preview stacks
    1:1 crops of them (2x pixels for HiDPI) with captions instead."""
    from PIL import Image, ImageDraw, ImageFont
    src = Image.open(png).convert('RGB')
    if preset_id == 'macos':
        strips = [('Bar · left', (0, 0, 320, 32)), ('Bar · right', (960, 0, 320, 32)), ('Dock · bottom', (480, 632, 320, 76))]
    else:
        strips = [('Taskbar · left', (0, 672, 320, 48)), ('Taskbar · center', (480, 672, 320, 48)), ('Taskbar · right', (960, 672, 320, 48))]
    canvas = Image.new('RGB', (640, 400), (16, 18, 24))
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=20)
    y = 0
    for caption, box in strips:
        draw.text((8, y + 2), caption, fill=(154, 160, 180), font=font)
        x, y0, w, h = box
        crop = src.crop((x, y0, x + w, y0 + h)).resize((w * 2, h * 2), Image.LANCZOS)
        canvas.paste(crop, (0, y + 24))
        y += 24 + crop.height + 8
    return canvas


def encode(png, dest, fmt):
    if fmt == 'png':
        shutil.copy(png, dest)
    elif fmt == 'webp':
        subprocess.run(['magick', str(png), '-quality', '82', str(dest)], check=True)
    else:
        subprocess.run(['avifenc', '-q', '65', '-s', '6', str(png), str(dest)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, default=ROOT / 'zig-out/bin/pearl')
    parser.add_argument('--aqueous', type=Path, default=Path('/usr/bin/aqueous'))
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/preset-screenshot')
    parser.add_argument('--previews', type=Path, default=ROOT / 'resources/previews')
    parser.add_argument('--format', choices=('avif', 'webp', 'png'), default='avif')
    parser.add_argument('--only', help='capture just the preset with this id')
    parser.add_argument('--idle', type=float, default=3.0, help='seconds to wait for wallpaper, palette and bar paint')
    parser.add_argument('--reuse', action='store_true', help='recompose previews from existing captures without starting a session')
    parser.add_argument('--detail', action='store_true', help='encode close-up bar/dock sheets instead of the full 16:9 desktop')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.previews.mkdir(parents=True, exist_ok=True)
    catalog = json.loads((ROOT / 'src/config/bar_dock_presets.json').read_text())
    for preset in catalog:
        if args.only and preset['id'] != args.only:
            continue
        png = args.output / f"{preset['id']}.png"
        if not (args.reuse and png.is_file()):
            with PrivateSession(args.output / preset['id'], aqueous=args.aqueous) as session:
                seeded = Path(session.env['XDG_CONFIG_HOME']) / 'pearl'
                seeded.mkdir(parents=True)
                (seeded / 'preferences.json').write_text(json.dumps(seeded_preferences(preset), indent=2))
                ipc = IPC(session)
                primary = next(iter(ipc.outputs().values()))['name']
                app = session.child('pearl', [args.pearl.resolve()])
                try:
                    app.expect('event=control-ready')
                    time.sleep(args.idle)
                    for _ in range(3):
                        session.run(['grim', '-o', primary, str(png)])
                finally:
                    app.stop()
                    ipc.close()
        source = png
        if args.detail:
            source = args.output / f"{preset['id']}-detail.png"
            detail_sheet(png, preset['id']).save(source)
        dest = args.previews / f"{preset['id']}.{args.format}"
        encode(source, dest, args.format)
        print(f"{preset['id']}: {source} -> {dest} ({dest.stat().st_size} bytes)")
        print(f"  preview: /org/aqueous/Pearl/previews/{dest.name}")


if __name__ == '__main__':
    main()
