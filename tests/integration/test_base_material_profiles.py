#!/usr/bin/env python3
"""Real Matugen, parsers, application consumers and owned writes in private roots."""
import argparse, configparser, io, json, os, shutil, subprocess, tempfile, tomllib, zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--driver', type=Path, required=True); parser.add_argument('--tool', type=Path, required=True); args = parser.parse_args()
    evidence = ROOT/'artifacts/base-material-matugen'; evidence.mkdir(parents=True, exist_ok=True)
    checks = []; skipped = []
    with tempfile.TemporaryDirectory(prefix='pearl-material-') as temporary:
        root = Path(temporary)
        env = {**os.environ, 'HOME':str(root), 'XDG_CONFIG_HOME':str(root/'config'), 'XDG_DATA_HOME':str(root/'data'), 'XDG_CACHE_HOME':str(root/'cache'), 'XDG_STATE_HOME':str(root/'state'), 'NVIM_LOG_FILE':str(root/'nvim.log'), 'XDG_DATA_DIRS':str(root/'system')}
        for name in ['config', 'data', 'cache']: (root/name).mkdir()
        def run(p, **overrides):
            result = subprocess.run([str(args.driver.resolve()), json.dumps(p)], env=env|overrides, capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, (result.stdout, result.stderr)
            return json.loads(result.stdout)
        legacy = run({'matugen':{'enabled':True}})
        assert legacy['captured']['profiles'] == []
        assert not (root/'config/gtk-3.0').exists()
        checks.append('legacy-enabled-does-not-adopt')
        p = {'matugen': {'enabled':True, 'defaults_revision':1, 'applications': {name:{'mode':'profile','profile_id':'pearl.material.'+name} for name in ['qt5ct','qt6ct']}}}
        gtk = root/'config/gtk-3.0/gtk.css'; gtk.parent.mkdir(); gtk.write_text('/* preserve existing CSS */\nbutton { padding: 3px; }\n')
        original = gtk.read_bytes()
        flatpak=root/'.var/app/dev.vencord.Vesktop/config';flatpak.mkdir(parents=True)
        result = run(p)
        assert list((flatpak/'vesktop/themes').glob('pearl-*.css'))
        coverage = json.loads((ROOT/'src/theme/material/coverage.json').read_text())
        assert {v['application'] for v in result['captured']['profiles']} == set(coverage['targets'])
        assert not set(coverage['excluded']) & {v['application'] for v in result['status']['targets']}
        def successful(result):
            bad = [v for v in result['status']['targets'] if v['state'] in ['failed','conflict','unavailable','unsupported']]
            assert not bad, bad
        successful(result)
        assert gtk.read_bytes().endswith(original) and b'@import' in gtk.read_bytes()
        checks.append('all-23-targets-and-gtk-preservation')
        rendered = root/'config/pearl/matugen/outputs'
        def validate(variant):
            for app in coverage['targets']:
                if variant == 'light' and app in ['fluxer','steam']: continue
                for file in sorted((rendered/app).glob('*')):
                    text = file.read_text(); assert '{{' not in text and '<*' not in text, file
                    if file.suffix == '.json': json.loads(text)
                    elif file.suffix == '.toml': tomllib.loads(text)
                    elif file.suffix == '.svg': ET.fromstring(text)
                    elif file.suffix in ['.ini','.colors'] or app in ['qt5ct','qt6ct','fcitx5']:
                        ini = configparser.ConfigParser(interpolation=None, strict=True); ini.read_string(text)
                    elif file.suffix == '.lua':
                        if shutil.which('luac'): subprocess.run(['luac','-p',str(file)],env=env,check=True,capture_output=True)
                        else: skipped.append('luac syntax checks')
                    shutil.copy2(file, evidence/(app+'-'+variant+'-'+file.name))
            vsix = root/'data/pearl/vscode/pearl-material.vsix'
            with zipfile.ZipFile(vsix) as z:
                ET.fromstring(z.read('extension.vsixmanifest')); ET.fromstring(z.read('[Content_Types].xml'))
                package=json.loads(z.read('extension/package.json'))
                for theme in package['contributes']['themes']:json.loads(z.read('extension/'+theme['path'].removeprefix('./')))
            if shutil.which('nvim'):
                r = subprocess.run(['nvim','--headless','-i','NONE','-u','NONE','--cmd','set rtp^='+str(root/'config/nvim'),'+colorscheme pearl-material',"+lua assert(vim.g.colors_name == 'pearl-material'); assert(vim.g.terminal_color_0); assert(require('lualine.themes.pearl-material').normal.a.bg)",'+qa!'],env=env,capture_output=True,text=True,timeout=15)
                assert r.returncode==0 and 'Error' not in r.stderr,r.stderr
            else: skipped.append('Neovim runtime')
        validate('dark'); checks.append('dark-independent-parsers-vsix-and-neovim')
        pinned = result['snapshot']; p['matugen']['snapshot_digest'] = pinned
        before = {str(f):f.read_bytes() for f in root.rglob('*') if f.is_file() and 'snapshots' not in str(f) and 'render-cache' not in str(f)}
        successful(run(p))
        assert all(Path(path).read_bytes()==data for path,data in before.items())
        checks.append('committed-snapshot-retry-idempotent')
        # The explicit refresh has a fixed argv and accepts only a selected Pywalfox target.
        helpers=root/'helpers';helpers.mkdir()
        helper=helpers/'pywalfox';helper.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$XDG_CACHE_HOME/refresh-args"\n');helper.chmod(0o700)
        command=dict(action='application_refresh',id='pywalfox',sha256=pinned)
        refresh=subprocess.run([str(args.tool.resolve()),json.dumps(command)],env=env|{'PATH':str(helpers)},capture_output=True,text=True,timeout=15)
        assert refresh.returncode==0,(refresh.stdout,refresh.stderr)
        assert (root/'cache/refresh-args').read_text()=='update\n'
        command['id']='arbitrary-command'
        rejected=subprocess.run([str(args.tool.resolve()),json.dumps(command)],env=env|{'PATH':str(helpers)},capture_output=True,text=True,timeout=15)
        assert rejected.returncode!=0 and 'UnsupportedApplicationRefresh' in rejected.stderr
        checks.append('typed-explicit-pywalfox-refresh')
        # Missing renderer retains every installed output, including the static palette's consumers.
        unavailable=run(p, PATH=str(root/'no-programs'))
        assert next(v for v in unavailable['status']['targets'] if v['application']=='ghostty')['error_code']=='MatugenUnavailable'
        assert all(Path(path).read_bytes()==data for path,data in before.items())
        checks.append('missing-matugen-retains-last-good')
        p['matugen'].pop('snapshot_digest'); p['theme']={'variant':'light'}
        result=run(p)
        failures=[v for v in result['status']['targets'] if v['state']=='unavailable']
        assert {v['application'] for v in failures} == {'fluxer','steam'},failures
        assert all(v['state'] not in ['failed','conflict'] for v in result['status']['targets']),result['status']
        validate('light'); checks.append('light-independent-parsers-and-variant-restrictions')
        ghostty=root/'config/ghostty/themes/pearl-material'; original_ghostty=ghostty.read_bytes();ghostty.write_text('# user edited\n')
        result=run({})
        conflict=next(v for v in result['status']['targets'] if v['application']=='ghostty');assert conflict['state']=='conflict',conflict
        assert ghostty.read_text()=='# user edited\n' and gtk.read_bytes()==original
        checks.append('off-preserves-user-edits-restores-gtk')
        ghostty.write_bytes(original_ghostty); successful(run({})); assert not ghostty.exists()
        assert not (root/'data/fcitx5/themes/pearl-material/theme.conf').exists()
        assert not list((flatpak/'vesktop/themes').glob('pearl-*.css'))
        checks.append('off-restores-all-unchanged-owned-files-and-flatpak')
        # Individual selections and Off survive adopting base defaults.
        p={'matugen':{'enabled':True,'defaults_revision':1,'applications':{'ghostty':{'mode':'off'},'zed':{'mode':'profile','profile_id':'pearl.material.zed'}}}}
        result=run(p); assert not ghostty.exists()
        assert next(v for v in result['captured']['profiles'] if v['application']=='zed')['id']=='pearl.material.zed'
        checks.append('manual-and-off-precedence')
        successful(run({}))
        # A redirected GTK destination is isolated from another target's valid publication.
        gtk4=root/'config/gtk-4.0';gtk4.rmdir();outside=root/'outside';outside.mkdir();gtk4.symlink_to(outside,target_is_directory=True)
        p={'matugen':{'enabled':True,'applications':{'gtk':{'mode':'profile','profile_id':'pearl.material.gtk'},'ghostty':{'mode':'profile','profile_id':'pearl.material.ghostty'}}}}
        result=run(p)
        assert next(v for v in result['status']['targets'] if v['application']=='gtk')['state']=='failed'
        assert next(v for v in result['status']['targets'] if v['application']=='ghostty')['state']=='activation_required'
        assert not list(outside.iterdir()) and ghostty.exists()
        gtk4.unlink();successful(run({}))
        checks.append('redirected-gtk-root-does-not-block-other-targets')
    (evidence/'results.json').write_text(json.dumps({'checks':checks,'unverified_optional_consumers':sorted(set(skipped))},indent=2)+'\n')
    print('PASS base Material: '+', '.join(checks))
if __name__=='__main__': main()
