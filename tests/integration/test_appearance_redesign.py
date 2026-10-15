#!/usr/bin/env python3
"""Native Appearance preview isolation, disclosure navigation and responsive layout."""
import argparse
import copy
import hashlib
import json
import time
from pathlib import Path
from PIL import Image
from test_settings_app import (ROOT, PrivateSession, IPC, wait_for, probe, request,
                               capture, clean, keys, resize, windows)
from test_settings_appearance import ready, click, type_text
from settings_editor import EditorPeer
from pearl_session import fixture_prefix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/appearance-redesign/native')
    args = parser.parse_args()
    args.settings = args.settings.resolve(); args.pearl = args.pearl.resolve()
    args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', checks=[], captures=[], binaries={name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() for name in ('settings', 'pearl')})
    try:
        with PrivateSession(args.output/'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            legacy = Path(s.env['XDG_CONFIG_HOME'])/'pearl/last-good.json'
            legacy.parent.mkdir(parents=True); legacy.write_text('{}')
            generator_mode = s.base/'generator-mode'; generator_mode.write_text('pass')
            generator_log = s.base/'generator-log'; generator_log.write_text('')
            s.env.update(PATH=str(ROOT/'tests/fixtures/theme')+':'+s.env['PATH'],
                         PEARL_TEST_GENERATOR_MODE=str(generator_mode), PEARL_TEST_GENERATOR_LOG=str(generator_log))
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, rules, 1200, 960)
            ipc.call('command', action='session.reload', fields={})
            shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
            peer = EditorPeer(s, ipc)
            initial = json.loads(peer.document('committed'))
            app = s.child('settings', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s, ipc)

            def save_capture(name):
                time.sleep(.6)
                state = probe(s, ipc)
                capture(s, name, output['name'])
                report['captures'].append(dict(name=name, path='session/'+name+'.png', window=windows(ipc)[0]['geometry']))
                body = state['body_bounds']; footer = state['footer_bounds']
                assert footer['y']+footer['height'] <= state['height']+1
                for control in state['controls']:
                    if control['field'].startswith('mode.') or control['field'] == 'appearance.preview':
                        box = control['bounds']
                        assert box and box['width'] > 0
                        assert box['x'] >= body['x']-1 and box['x']+box['width'] <= body['x']+body['width']+1, control
                return state

            save_capture('dark')
            before = peer.document()
            click(s, ipc, 'appearance.section.text')
            click(s, ipc, 'appearance.section.text')
            assert peer.document() == before
            click(s, ipc, 'mode.package')
            assert peer.document() == before
            assert next(c for c in probe(s, ipc)['controls'] if c['field'] == 'appearance.section.themes')['selected']
            click(s, ipc, 'appearance.section.themes')
            report['checks'].append('disclosures-and-community-picker-preserve-draft')

            click(s, ipc, 'mode.dynamic')
            wait_for(lambda: json.loads(peer.document())['theme']['mode'] == 'dynamic')
            click(s, ipc, 'seed'); type_text(s, '#346785')
            wait_for(lambda: json.loads(peer.document())['theme']['seed'] == '#346785')
            wait_for(lambda: not probe(s, ipc)['theme_busy'])
            before = peer.document()
            click(s, ipc, 'appearance.preview-colors')
            wait_for(lambda: probe(s, ipc)['theme_status'].startswith('Preview only'), 30)
            assert peer.document() == before
            assert json.loads(peer.document('committed')) == initial
            assert probe(s, ipc)['style'] == 'dark'
            assert next(c for c in probe(s, ipc)['controls'] if c['field'] == 'appearance.preview')['text'].startswith('Draft colors')
            report['checks'].append('native-mode-seed-and-backend-preview-do-not-commit')
            generator_mode.write_text('slow')
            click(s, ipc, 'appearance.preview-colors')
            wait_for(lambda: '"mode": "slow"' in generator_log.read_text(), 10)
            request(s, ipc, page='bar'); ready(s, ipc)
            wait_for(lambda: not probe(s, ipc)['theme_busy'], 15)
            assert 'Cancel' in probe(s, ipc)['theme_status']
            assert peer.document() == before
            assert json.loads(peer.document('committed')) == initial
            request(s, ipc, page='appearance'); ready(s, ipc)
            generator_mode.write_text('pass')
            report['checks'].append('in-flight-color-preview-cancelled-on-navigation')
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(peer.document()) == initial

            click(s, ipc, 'choose'); wait_for(lambda: probe(s, ipc)['editor']['picker'])
            keys(s, 'Escape'); wait_for(lambda: not probe(s, ipc)['editor']['picker'])
            assert not peer.state()['dirty']
            image = s.base/'wallpaper with spaces.png'
            Image.new('RGB', (1200, 800), (67, 83, 115)).save(image)
            click(s, ipc, 'choose'); wait_for(lambda: probe(s, ipc)['editor']['picker'])
            s.run(['wtype', '-s', '200', '-M', 'ctrl', 'l', '-m', 'ctrl', str(image), '-k', 'Return'])
            wait_for(lambda: probe(s, ipc)['editor']['preview'], 15)
            wait_for(lambda: json.loads(peer.document())['wallpaper']['path'] == str(image))
            assert json.loads(peer.document('committed')) == initial
            request(s, ipc, page='bar'); ready(s, ipc)
            request(s, ipc, page='appearance'); ready(s, ipc)
            assert json.loads(peer.document())['wallpaper']['path'] == str(image)
            click(s, ipc, 'apply')
            wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'], 30)
            committed = json.loads(peer.document('committed'))
            assert committed['wallpaper']['path'] == str(image)
            report['checks'].append('native-chooser-cancel-preview-navigation-and-apply')
            save_capture('wallpaper')
            click(s, ipc, 'font_size'); type_text(s, '18'); keys(s, 'Tab'); ready(s, ipc)
            wait_for(lambda: json.loads(peer.document())['font_size'] == 18)
            click(s, ipc, 'desktop_enabled'); ready(s, ipc)
            save_capture('details')
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(peer.document()) == committed
            report['checks'].append('expanded-text-and-desktop-controls-share-discard')
            app.stop(); clean(app)

            for name, width, height, variant, mode, font in (
                ('light', 1200, 960, 'light', 'static', 14),
                ('native', 1040, 760, 'light', 'gtk', 14),
                ('narrow', 390, 900, 'dark', 'static', 14),
                ('large-text', 560, 900, 'dark', 'static', 24),
            ):
                p = copy.deepcopy(committed)
                p['theme'].update(mode=mode, variant=variant, gtk_name='')
                p['font_size'] = font; p['reduced_motion'] = True
                peer.keep(json.dumps(p)); assert peer.action('apply')['state'] == 'succeeded'
                resize(s, rules, width, height)
                ipc.call('command', action='session.reload', fields={})
                app = s.child('settings-'+name, [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings')
                app.expect('event=settings-window-created'); ready(s, ipc)
                wait_for(lambda: probe(s, ipc)['style'] == ('gtk' if mode == 'gtk' else variant))
                state = save_capture(name)
                assert state['width'] <= width+1, (name, state['width'])
                click(s, ipc, 'motion'); ready(s, ipc)
                assert peer.state()['dirty']
                click(s, ipc, 'discard'); ready(s, ipc)
                app.stop(); clean(app)
            report['checks'].append('light-gtk-390px-and-large-text-layout-and-keyboard-editing')
            peer.close(); shell.stop(); clean(shell)
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=repr(exc))
        raise
    finally:
        (args.output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(dict(status=report['status'], checks=report['checks'])), flush=True)


if __name__ == '__main__':
    main()
