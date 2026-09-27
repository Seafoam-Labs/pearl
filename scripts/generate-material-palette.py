#!/usr/bin/env python3
"""Regenerate static Material render data with Matugen 4.2.0 and exact shell roles."""
import json, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def main():
    version=subprocess.check_output(['matugen','--version'],text=True).strip()
    if version != 'matugen 4.2.0': raise SystemExit('Use pinned matugen 4.2.0, found '+version)
    with tempfile.TemporaryDirectory(prefix='pearl-material-palette-') as temp:
        config=Path(temp)/'empty.toml';config.write_text('[config]\n[templates]\n')
        full=json.loads(subprocess.check_output(['matugen','--config',str(config),'--dry-run','--json','hex','--mode','dark','color','hex','#6750a4']))
    fields=['surface','low','container','high','text','secondary','primary','on_primary','primary_container','on_container','outline','error_color','error_container']
    roles=['surface','surface_container_low','surface_container','surface_container_high','on_surface','on_surface_variant','primary','on_primary','primary_container','on_primary_container','outline','error','error_container']
    shell=(ROOT/'src/theme/theme.zig').read_text()
    for variant in ['dark','light']:
        block=shell.split('pub const '+variant+': Palette = .{')[1].split('};')[0]
        for field,role in zip(fields,roles):full['colors'][role][variant]['color']=re.search(r'\.'+field+r' = "(#[0-9a-f]+)"',block)[1]
        for alias,role in [('background','surface'),('on_background','on_surface'),('surface_tint','primary')]:full['colors'][alias][variant]=full['colors'][role][variant].copy()
    for section in ['colors','base16']:
        for value in full[section].values():value['default']=value['dark'].copy()
    fixed={k:full[k] for k in ['colors','base16','palettes']};fixed.update(schema_version=1,renderer='matugen-4')
    (ROOT/'src/theme/material/palette.json').write_text(json.dumps(fixed,indent=2)+'\n')
if __name__=='__main__':main()
