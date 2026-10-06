#!/usr/bin/env python3
"""Development-only acceptance for Zig assets, discovery and application profiles."""
import argparse
import base64
import hashlib
import json
import random
import shutil
from pathlib import Path
from PIL import Image
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, probe, capture, resize, clean
from test_settings_appearance import ready, settled, click, type_text
from test_custom_themes import Peer
from test_theme_packages import fixture


def main():
    parser = argparse.ArgumentParser()
    for name in ('pearl', 'settings', 'themes'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/theme-completion')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'binaries': {name: hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ('pearl','settings','themes')}}
    (args.output/'acceptance.json').write_text(json.dumps(report))
    with PrivateSession(args.output/'session', tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        ipc = IPC(s)
        output = next(iter(ipc.outputs().values()))
        s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
        resize(s, Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml', 1040, 850)
        shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = Peer(s, ipc)
        settled(peer)
        generation = peer.state()['theme_catalog_generation']
        source = Path(s.env['XDG_DATA_HOME'])/'pearl/themes/original-completion'
        manifest = fixture(source, 'original.completion')
        full = json.loads((ROOT/'tests/fixtures/community/render-data/matugen-4.2.json').read_text())
        role_names = ['surface', 'surface_container_low', 'surface_container', 'surface_container_high', 'on_surface', 'on_surface_variant', 'primary', 'on_primary', 'primary_container', 'on_primary_container', 'outline', 'error', 'error_container']
        shell_names = ['surface', 'low', 'container', 'high', 'text', 'secondary', 'primary', 'on_primary', 'primary_container', 'on_container', 'outline', 'error_color', 'error_container']
        palette = {short: full['colors'][role]['dark']['color'] for short, role in zip(shell_names, role_names)}
        (source/'dark.json').write_text(json.dumps(palette))
        (source/'render.json').write_text(json.dumps(dict(schema_version=1, renderer='matugen-4', colors=full['colors'], base16=full['base16'], palettes=full['palettes'])))
        manifest.update(schema_version=2, images=[dict(id='grain', path='grain.png')], profiles=['zed.json'], defaults=[dict(application='zed', profile='original.zed')], render_data=dict(dark='render.json'))
        manifest['requires'].update(style_api=2, profile_api=1, render_data_api=1)
        (source/'theme.json').write_text(json.dumps(manifest))
        pixels = random.Random(9876).randbytes(256*256*4)
        image = Image.frombytes('RGBA', (256, 256), pixels)
        image.putalpha(12)
        image.save(source/'grain.png')
        (source/'extra.css').write_text('.pearl-card { background-image: url("theme-asset:grain"); background-repeat: repeat; }')
        descriptor = dict(schema_version=1, id='original.zed', application='zed', adapter='zed', name='Original Zed', author='Pearl', license='CC0-1.0', source='https://example.org/original', asset_version='1.0.0', variants=['dark', 'light'], templates=[dict(path='zed.in', output='theme.json')])
        (source/'zed.json').write_text(json.dumps(descriptor))
        (source/'zed.in').write_text('{"name":"Pearl original","author":"Pearl","themes":[{"name":"Pearl original dark","appearance":"dark","style":{"background":"{{colors.surface.default.hex}}"}}]}')
        wait_for(lambda: peer.state()['theme_catalog_generation'] != generation, 15)
        catalog = peer.theme('catalog')
        assert catalog['entries'][0]['id'] == manifest['id'], catalog
        report['package'] = catalog['entries'][0]
        report['renderer'] = s.run(['matugen', '--version']).stdout.strip()
        report['render_data_sha256'] = hashlib.sha256((source/'render.json').read_bytes()).hexdigest()
        theme = dict(mode='package', package_id=manifest['id'], catalog_revision=catalog['revision'])
        prefs = json.loads(peer.document('committed'))
        prefs['theme'].update(theme)
        prefs['matugen'] = dict(enabled=True, applications={'steam': dict(mode='off', profile_id='')})
        peer.keep(json.dumps(prefs))
        assert peer.action('apply')['state'] == 'succeeded'
        state = settled(peer)
        assert state['applications']['targets'][0]['state'] == 'activation_required', state
        installed = Path(s.env['XDG_CONFIG_HOME'])/'zed/themes/pearl-original.zed-theme.json'
        assert palette['surface'] in installed.read_text()
        assert state['applications']['targets'][4]['state'] == 'unmanaged'
        check = Peer(s, ipc)
        assert check.capabilities['theme_assets']
        images = check.appearance['images']
        assert len(images) == 1 and images[0]['size'] > 48*1024
        data = bytearray()
        while len(data) < images[0]['size']:
            chunk = check.call('theme.asset', preview=False, revision=check.appearance['revision'], digest=images[0]['digest'], offset=len(data))
            assert chunk['ok'], chunk
            data.extend(base64.b64decode(chunk['result']['data']))
        assert hashlib.sha256(data).hexdigest() == images[0]['digest']
        check.close()
        app = s.child('settings', [args.settings.resolve(), '--page', 'appearance'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created')
        ready(s, ipc)
        wait_for(lambda: probe(s, ipc)['appearance_updates'] > 0, 15)
        wait_for(lambda: any(c['field'] == 'themes.preview.0' for c in probe(s, ipc)['controls']), 15)
        wait_for(lambda: not probe(s,ipc)['theme_busy'],15)
        click(s, ipc, 'themes.preview.0')
        wait_for(lambda: probe(s, ipc)['theme_status'].startswith('Preview only'), 20)
        capture(s, 'images-and-profiles', output['name'])
        click(s, ipc, 'applications.enabled')
        wait_for(lambda: peer.state()['dirty'], 15)
        assert not json.loads(peer.document('draft'))['matugen']['enabled']
        capture(s, 'application-controls', output['name'])
        click(s, ipc, 'discard')
        wait_for(lambda: not peer.state()['dirty'], 15)
        assert json.loads(peer.document('draft'))['matugen']['enabled']
        committed = json.loads(peer.document('committed'))
        before = installed.read_bytes()
        generation = peer.state()['theme_catalog_generation']
        (source/'zed.in').write_text((source/'zed.in').read_text().replace('Pearl original', 'Changed input'))
        wait_for(lambda: peer.state()['theme_catalog_generation'] != generation, 15)
        assert installed.read_bytes() == before
        # A retry must use committed template bytes, even after mutable files change.
        peer.theme('application_retry', revision=peer.state()['revision'])
        assert installed.read_bytes() == before
        shutil.rmtree(source)
        app.stop(); clean(app); peer.close(); shell.stop(); clean(shell)
        shell = s.child('pearl-restart', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = Peer(s, ipc); state = settled(peer)
        check = Peer(s, ipc)
        assert check.appearance['images'] == images, check.appearance
        check.close()
        assert installed.read_bytes() == before
        # Off preserves a user edit and reports the conflict independently of shell Apply.
        installed.write_text('user edit')
        prefs = json.loads(peer.document('committed'))
        prefs['theme'].update(mode='static', package_id='', palette_id='', style_id='', catalog_revision='')
        prefs['matugen']['enabled'] = False
        peer.keep(json.dumps(prefs)); assert peer.action('apply')['state'] == 'succeeded'
        state = settled(peer)
        assert state['applications']['targets'][0]['state'] == 'conflict', state
        assert installed.read_text() == 'user edit'
        # Author through the real Settings controls and native backend.
        app = s.child('palette-settings', [args.settings.resolve(), '--page', 'appearance'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created'); ready(s, ipc)
        wait_for(lambda: any(c['field']=='palettes.create' for c in probe(s,ipc)['controls']),15)
        click(s,ipc,'palettes.expander')
        click(s,ipc,'palettes.name');type_text(s,'Live Meadow')
        assert next(c['text'] for c in probe(s,ipc)['controls'] if c['field']=='palettes.name')=='Live Meadow'
        click(s,ipc,'palettes.create')
        local=Path(s.env['XDG_CONFIG_HOME'])/'pearl/palettes/meadow.json'
        wait_for(local.exists,15)
        wait_for(lambda: not probe(s,ipc)['theme_busy'],15)
        wait_for(lambda: any(c['field']=='themes.select.0' for c in probe(s,ipc)['controls']),15)
        assert json.loads(local.read_text())['name']=='Live Meadow', (local.read_text(),probe(s,ipc))
        assert not peer.state()['dirty']
        click(s,ipc,'themes.select.0');ready(s,ipc)
        click(s,ipc,'themes.default_style.0');ready(s,ipc)
        click(s,ipc,'apply');settled(peer);ready(s,ipc)
        def appearance():
            check=Peer(s,ipc)
            value=check.appearance
            check.close()
            return value
        assert appearance()['palette']['primary']=='#a4dfb0'
        assert appearance()['palette']['surface']=='#101c19'
        # Manual application choices and Off override inherited defaults.
        applications=['zed','equibop','fluxer','starship','steam','gtk','qt5ct','qt6ct','kcolorscheme','ghostty','kitty','foot','alacritty','wezterm','nvim','vscode','emacs','firefox','zenbrowser','pywalfox','vesktop','vencord','fcitx5']
        prefs=json.loads(peer.document('committed'))
        choices={name:dict(mode='off',profile_id='') for name in applications}
        choices['ghostty']=dict(mode='theme',profile_id='')
        choices['kitty']=dict(mode='profile',profile_id='pearl.material.kitty')
        prefs['matugen']=dict(enabled=True,defaults_revision=1,applications=choices)
        peer.keep(json.dumps(prefs));assert peer.action('apply')['state']=='succeeded'
        wait_for(lambda: not peer.state()['busy'] and not peer.state()['applications']['busy'],30)
        ghostty=Path(s.env['XDG_CONFIG_HOME'])/'ghostty/themes/pearl-material'
        kitty=Path(s.env['XDG_CONFIG_HOME'])/'kitty/pearl-material.conf'
        wait_for(ghostty.exists,15)
        assert '#a4dfb0' in ghostty.read_text()
        # In-memory editor changes are isolated until Save palette.
        prior=local.read_bytes()
        click(s,ipc,'palettes.primary');type_text(s,'#abcdef')
        assert local.read_bytes()==prior and appearance()['palette']['primary']=='#a4dfb0'
        click(s,ipc,'palettes.save')
        wait_for(lambda: appearance()['palette']['primary']=='#abcdef',20)
        wait_for(lambda: '#abcdef' in ghostty.read_text(),20)
        assert peer.state()['applications']['targets'][0]['state']=='unmanaged'
        ready(s,ipc);capture(s,'local-palette-editor',output['name'])
        # Live file updates leave the on-disk selection and unsaved draft intact.
        disk=Path(s.env['XDG_CONFIG_HOME'])/'pearl/preferences.json'
        disk_before=disk.read_bytes()
        draft=json.loads(peer.document('committed'));draft['font_size']=19
        peer.keep(json.dumps(draft));draft_before=peer.document('draft')
        valid=json.loads(local.read_text())
        valid['dark']['primary']='#a4dfb0'
        valid['dark']['terminal']=dict(cursor='#012abc',bright=dict(red='#feabba'))
        valid['dark'].update(hover='#244136',on_hover='#e8f4e9')
        replacement=local.with_suffix('.tmp');replacement.write_text(json.dumps(valid));replacement.replace(local)
        wait_for(lambda: appearance()['palette']['primary']=='#a4dfb0',20)
        wait_for(lambda: 'palette = 9=#feabba' in ghostty.read_text(),20)
        assert 'cursor-color = #012abc' in ghostty.read_text()
        assert '#feabba' in kitty.read_text()
        assert '#244136' in appearance()['style_css']
        assert peer.document('draft')==draft_before and peer.state()['dirty']
        assert disk.read_bytes()==disk_before
        revision=appearance()['revision']
        generation=peer.state()['theme_catalog_generation']
        other=local.parent/'unselected.json';other.write_text(json.dumps(valid))
        wait_for(lambda: peer.state()['theme_catalog_generation']!=generation,15)
        assert appearance()['revision']==revision
        preview=s.child('author-preview',[args.themes.resolve(),'preview',other,'--watch'],G_DEBUG='fatal-warnings')
        wait_for(lambda: any(w.get('app_id')=='org.aqueous.Pearl.PalettePreview' for w in ipc.state()),15)
        preview_source=json.loads(other.read_text());preview_source['dark']['surface']='#090e12'
        replacement=other.with_suffix('.tmp');replacement.write_text(json.dumps(preview_source));replacement.replace(other)
        def preview_updated():
            capture(s,'watched-author-preview',output['name'])
            pixels=Image.open(s.output/'watched-author-preview.png').convert('RGB')
            return sum(n for n,c in pixels.getcolors(pixels.width*pixels.height) if c==(9,14,18))>1000
        wait_for(preview_updated,15)
        assert appearance()['revision']==revision and peer.document('draft')==draft_before
        assert disk.read_bytes()==disk_before
        preview_window=next(w for w in ipc.state() if w.get('app_id')=='org.aqueous.Pearl.PalettePreview')
        ipc.call('command',action='window.close',fields=dict(id=preview_window['id']))
        clean(preview)
        # Invalid edits and a missing source preserve the most recently valid colors.
        local.write_text('{"dark":')
        wait_for(lambda: peer.state()['error_code'] is not None,20)
        assert appearance()['palette']['primary']=='#a4dfb0'
        assert disk.read_bytes()==disk_before and peer.document('draft')==draft_before
        local.write_text(json.dumps(valid))
        try:
            wait_for(lambda: peer.state()['error_code'] is None and not peer.state()['busy'],20)
        except TimeoutError:
            state=peer.state()
            raise AssertionError({key:state[key] for key in ('error_code','busy','revision','theme_catalog_generation')} | dict(source=local.read_text()))
        # Burst replacements publish only the final valid source.
        for color in ['#abcdef','#b9e0f4','#a4dfb0']:
            valid['dark']['primary']=color
            replacement.write_text(json.dumps(valid));replacement.replace(local)
        wait_for(lambda: appearance()['palette']['primary']=='#a4dfb0' and not peer.state()['busy'],20)
        assert peer.document('draft')==draft_before and disk.read_bytes()==disk_before
        local.unlink()
        app.stop();clean(app);peer.close();shell.stop();clean(shell)
        shell=s.child('palette-restart',[args.pearl.resolve()],G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready');peer=Peer(s,ipc);settled(peer)
        assert appearance()['palette']['primary']=='#a4dfb0'
        wait_for(lambda: 'palette = 9=#feabba' in ghostty.read_text(),20)
        assert disk.read_bytes()==disk_before
        peer.close(); shell.stop(); clean(shell)
        report.update(status='passed', images=images, checks=['automatic_local_discovery', 'multi_chunk_assets', 'gtk_images_preview', 'application_controls_shared_draft_discard', 'fixed_render_data', 'inherited_zed_steam_off', 'committed_template_retry', 'image_profile_restart', 'off_preserves_user_edit', 'palette_editor_create_save_preview', 'local_palette_application_defaults', 'live_atomic_edits_preserve_draft', 'watched_cli_preview_isolation', 'invalid_palette_last_good', 'palette_invalid_to_valid_and_burst_replacements', 'missing_palette_restart'])
        (args.output/'acceptance.json').write_text(json.dumps(report, indent=2)+'\n')
        print('PASS completion assets, discovery, application profiles and recovery')


if __name__ == '__main__':
    main()
