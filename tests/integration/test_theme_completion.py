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
from test_settings_appearance import ready, settled, click
from test_custom_themes import Peer
from test_theme_packages import fixture


def main():
    parser = argparse.ArgumentParser()
    for name in ('pearl', 'settings'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/theme-completion')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running'}
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
        peer.close(); shell.stop(); clean(shell)
        report.update(status='passed', images=images, checks=['automatic_local_discovery', 'multi_chunk_assets', 'gtk_images_preview', 'application_controls_shared_draft_discard', 'fixed_render_data', 'inherited_zed_steam_off', 'committed_template_retry', 'image_profile_restart', 'off_preserves_user_edit'])
        (args.output/'acceptance.json').write_text(json.dumps(report, indent=2)+'\n')
        print('PASS completion assets, discovery, application profiles and recovery')


if __name__ == '__main__':
    main()
