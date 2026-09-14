#!/usr/bin/env python3
"""Export reviewed appearance fields/assets, never commands or host configuration."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--preferences',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    if args.output.exists():p.error('output must be a new directory')
    with args.preferences.open('rb') as f:raw=f.read(65537)
    if len(raw)>65536:p.error('preferences exceed 64 KiB')
    prefs=json.loads(raw);theme=prefs.get('theme',{});mode=theme.get('mode','static')
    config={'version':1,'theme':'gtk' if mode=='gtk' else 'material_'+theme.get('variant','dark'),'font_size':max(12,min(32,prefs.get('font_size',16))),'reduced_motion':bool(prefs.get('reduced_motion',True))}
    if config['theme'] not in ('gtk','material_dark','material_light'):p.error('unsupported appearance')
    if mode=='gtk' and theme.get('gtk_name'):
        name=theme['gtk_name']
        if not isinstance(name,str) or not re.fullmatch(r'[A-Za-z0-9 _:.+-]{1,256}',name):p.error('invalid installed GTK theme name')
        config['gtk_theme']=name
    # Copy only an explicitly requested local wallpaper from the supplied preferences.
    wallpaper=prefs.get('wallpaper',{});image=None;image_bytes=None
    if wallpaper.get('mode') in ('cover','contain') and wallpaper.get('path'):
        image=Path(wallpaper['path']).resolve()
        if not image.is_file() or image.stat().st_size>16*1024*1024:p.error('wallpaper is missing or exceeds 16 MiB')
        if image.suffix.lower() not in ('.png','.jpg','.jpeg'):p.error('only PNG/JPEG wallpaper bundles are supported')
        with image.open('rb') as f:image_bytes=f.read(16*1024*1024+1)
        if len(image_bytes)>16*1024*1024:p.error('wallpaper exceeds 16 MiB')
        config['wallpaper']='/usr/share/pearl-greeter/wallpaper'+image.suffix.lower()
    args.output.mkdir(parents=True)
    if image:(args.output/('wallpaper'+image.suffix.lower())).write_bytes(image_bytes)
    (args.output/'greeter-appearance.json').write_text(json.dumps(config,indent=2)+'\n')
    manifest={'purpose':'Review and merge appearance into administrator greeter config; this tool never installs it','dynamic_theme': 'Export uses static Material palette; no per-user generator runs before login' if mode=='dynamic' else None,'files':{path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in args.output.iterdir()}}
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(args.output)


if __name__=='__main__':main()
