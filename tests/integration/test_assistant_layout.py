#!/usr/bin/env python3
"""Assistant cards, native disclosures, conditional fields and responsive layout."""
import argparse
import copy
import json
import time
from pathlib import Path
from test_settings_app import (ROOT, PrivateSession, IPC, wait_for, probe, request,
                               capture, clean, keys, resize, windows, click_widget)
from test_settings_appearance import ready, click, type_text
from settings_editor import EditorPeer
from pearl_session import fixture_prefix

# Already reproduced on the unchanged Appearance implementation. Keep these in
# the report/logs; all other toolkit warnings and criticals still fail the suite.
FRAME_WARNINGS = ('gdk_frame_timings_discarded() called on already presented frame',
                  'Duplicate call to gdk_frame_timings_presented()')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/assistant-layout/native')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', checks=[], captures=[], frame_warnings=[])
    try:
        with PrivateSession(args.output/'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            legacy = Path(s.env['XDG_CONFIG_HOME'])/'pearl/last-good.json'
            legacy.parent.mkdir(parents=True)
            legacy.write_text('{}')
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, rules, 1200, 960)
            ipc.call('command', action='session.reload', fields={})
            shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            shell.expect('event=preferences-applied')
            peer = EditorPeer(s, ipc)
            initial = json.loads(peer.document('committed'))
            app = s.child('settings', [args.settings.resolve(), '--page', 'assistant'], G_DEBUG='fatal-criticals')
            app.expect('event=settings-window-created')
            ready(s, ipc)

            def control(name):
                return next(c for c in probe(s, ipc)['controls'] if c['field'] == 'assistant.' + name)

            def press(name):
                click(s, ipc, 'assistant.' + name)
                if name in ('threads', 'context', 'tokens'):
                    rect = dict(control(name)['bounds'])
                    rect['width'] /= 3
                    click_widget(s, ipc, rect)
                time.sleep(.2)

            def finish_app():
                app.stop()
                report['frame_warnings'].extend(line for line in app.lines if any(w in line for w in FRAME_WARNINGS))
                clean(app, allowed_warnings=FRAME_WARNINGS)

            def save_capture(name):
                time.sleep(.5)
                state = probe(s, ipc)
                capture(s, name, output['name'])
                report['captures'].append(dict(name=name, path='session/'+name+'.png', window=windows(ipc)[0]['geometry']))
                body = state['body_bounds']
                footer = state['footer_bounds']
                assert footer['y'] + footer['height'] <= state['height'] + 1
                assert body['y'] + body['height'] <= footer['y'] + 1
                for c in state['controls']:
                    if not c['field'].startswith('assistant.') or not c['visible']:
                        continue
                    box = c['bounds']
                    if not box or box['height'] == 0:
                        continue
                    assert box['x'] >= body['x'] - 1 and box['x'] + box['width'] <= body['x'] + body['width'] + 1, c
                return state

            save_capture('dark')
            before = peer.document()
            for section in ('model_options', 'runtime_options', 'engines_section', 'resources_section'):
                assert not control(section)['selected']
                press(section)
                assert control(section)['selected']
                press(section)
            assert peer.document() == before
            report['checks'].append('native-disclosures-do-not-edit-draft')

            press('compute.1')
            ready(s, ipc)
            assert json.loads(peer.document())['assistant']['compute']['mode'] == 'auto'
            assert json.loads(peer.document('committed')) == initial
            assert control('compute.1')['selected']
            request(s, ipc, page='appearance'); ready(s, ipc)
            request(s, ipc, page='assistant'); ready(s, ipc)
            assert control('compute.1')['selected']
            click(s, ipc, 'discard'); ready(s, ipc)
            assert control('compute.0')['selected']
            report['checks'].append('radio-selection-shared-draft-navigation-and-discard')

            press('runtime_options')
            assert not control('runtime_path')['visible']
            press('runtime_source'); keys(s, 'End', 'Return')
            wait_for(lambda: control('runtime_path')['visible'])
            press('runtime_path'); type_text(s, '/tmp/pearl-missing-runtime'); keys(s, 'Tab')
            ready(s, ipc)
            press('discover')
            wait_for(lambda: probe(s, ipc)['assistant_state']['status'] and not probe(s, ipc)['assistant_state']['busy'])
            assert control('runtime_options')['selected']
            assert 'not checked' in control('runtime_summary')['text'].lower()
            save_capture('runtime-recovery')
            click(s, ipc, 'discard'); ready(s, ipc)
            report['checks'].append('custom-runtime-path-and-local-failure-recovery')

            press('engines_section')
            assert not control('endpoint')['visible']
            assert not control('engine_id')['visible']
            press('provider_kind'); keys(s, 'Home', 'Down', 'Return')
            wait_for(lambda: control('endpoint')['visible'])
            press('endpoint'); type_text(s, 'https://search.example.org'); keys(s, 'Tab')
            ready(s, ipc)
            press('provider_kind'); keys(s, 'End', 'Return'); ready(s, ipc)
            assert not control('endpoint')['visible']
            assert json.loads(peer.document())['assistant']['providers'][0]['endpoint'] == 'https://search.example.org'
            click(s, ipc, 'discard'); ready(s, ipc)
            report['checks'].append('conditional-engine-fields-preserve-hidden-values')

            press('resources_section')
            press('threads'); type_text(s, '8'); keys(s, 'Tab'); ready(s, ipc)
            assert json.loads(peer.document())['assistant']['cpu_threads'] == 8
            request(s, ipc, page='bar'); ready(s, ipc)
            request(s, ipc, page='assistant'); ready(s, ipc)
            assert control('resources_section')['selected']
            save_capture('expanded')
            click(s, ipc, 'discard'); ready(s, ipc)
            click(s, ipc, 'benchmark.open')
            assert not (Path(s.env['XDG_DATA_HOME'])/'pearl/assistant/models').exists()
            assert not list((Path(s.env['XDG_STATE_HOME'])/'pearl/assistant/benchmarks').glob('*.json'))
            assert json.loads(peer.document('committed')) == initial
            report['checks'].append('resources-preserve-focus-and-expansion-without-implicit-operations')
            finish_app()

            for name, width, variant, mode, font, scale in (
                ('light', 1200, 'light', 'static', 14, 1),
                ('native', 1040, 'light', 'gtk', 14, 1),
                ('narrow', 390, 'dark', 'static', 14, 1),
                ('narrow-light', 440, 'light', 'static', 14, 1),
                ('large-text', 560, 'dark', 'static', 24, 1),
                ('scale-125', 1040, 'dark', 'static', 14, 1.25),
                ('scale-150', 1040, 'dark', 'static', 14, 1.5),
                ('scale-200', 700, 'dark', 'static', 14, 2),
            ):
                p = copy.deepcopy(initial)
                p['theme'].update(mode=mode, variant=variant, gtk_name='')
                p['font_size'] = font
                p['reduced_motion'] = True
                peer.keep(json.dumps(p))
                assert peer.action('apply')['state'] == 'succeeded'
                s.run(['wlr-randr', '--output', output['name'], '--scale', str(scale)])
                resize(s, rules, width, min(900, int(1100/scale)-80))
                ipc.call('command', action='session.reload', fields={})
                app = s.child('settings-'+name, [args.settings.resolve(), '--page', 'assistant'], G_DEBUG='fatal-criticals')
                app.expect('event=settings-window-created'); ready(s, ipc)
                wait_for(lambda: probe(s, ipc)['style'] == ('gtk' if mode == 'gtk' else variant))
                state = save_capture(name)
                assert state['width'] <= width + 1, (name, state['width'])
                press('compute.1'); ready(s, ipc)
                assert control('compute.1')['selected']
                keys(s, 'Left'); ready(s, ipc)
                if not control('compute.0')['selected']:
                    (args.output/'keyboard-failure.json').write_text(json.dumps(probe(s, ipc), indent=2))
                    raise AssertionError('CPU radio could not be selected with Left')
                if peer.state()['dirty']:
                    click(s, ipc, 'discard'); ready(s, ipc)
                finish_app()
            report['checks'].append('dark-light-gtk-narrow-large-text-scales-and-radio-keyboard')
            peer.close(); shell.stop(); clean(shell)
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=repr(exc))
        raise
    finally:
        (args.output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
