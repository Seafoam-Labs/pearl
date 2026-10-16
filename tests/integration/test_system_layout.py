#!/usr/bin/env python3
"""Native System layout and runtime selection, using only private scheduler fixtures."""
import argparse
import copy
import json
import shutil
import time
from pathlib import Path
from test_settings_app import (ROOT, PrivateSession, IPC, wait_for, probe, request,
                               capture, clean, keys, resize, windows)
from test_settings_appearance import ready, click, type_text
from test_settings_services import Peer
from settings_editor import EditorPeer
from pearl_session import fixture_prefix
from test_settings_sched_ext import FIX

# Existing scheduler suite permits these exact compositor timing diagnostics.
FRAME_WARNINGS = ('gdk_frame_timings_discarded() called on already presented frame',
                  'gdk_frame_timings_throttling_hint: runtime check failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/system-layout/native')
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
            root = s.output/'scx-fixture'
            (root/'bin').mkdir(parents=True, exist_ok=True)
            (root/'fixture-marker').touch()
            shutil.copyfile(FIX/'config.json', root/'config.json')
            shutil.copyfile(FIX/'scxctl.py', root/'bin/scxctl')
            (root/'bin/scxctl').chmod(0o755)
            for name in ('scx_bpfland', 'scx_lavd'):
                (root/'bin'/name).write_text('#!/bin/sh\nexit 97\n')
                (root/'bin'/name).chmod(0o755)
            (root/'state.json').write_text('null')
            (root/'kernel-state').write_text('disabled\n')
            (root/'control.json').write_text('{}')
            (root/'calls.jsonl').write_text('')
            s.env['PEARL_TEST_SCX_ROOT'] = str(root)
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime/'no-system-bus')
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, rules, 1200, 960)
            ipc.call('command', action='session.reload', fields={})
            shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready'); shell.expect('event=preferences-applied')
            editor = EditorPeer(s, ipc)
            initial = json.loads(editor.document('committed'))
            peer = Peer(s, ipc); peer.enter('system')
            app = s.child('settings', [args.settings.resolve(), '--page', 'system'], G_DEBUG='fatal-criticals')
            app.expect('event=settings-window-created'); ready(s, ipc)

            def state():
                return peer.page()['live']['sched_ext']

            def settled():
                return wait_for(lambda: (v if not (v := state())['pending'] else False), 20)

            def control(name):
                return next(c for c in probe(s, ipc)['controls'] if c['field'] == 'sched-ext/' + name)

            def press(name):
                wait_for(lambda: not state()['pending'])
                click(s, ipc, 'sched-ext/' + name)
                time.sleep(.15)

            def go(page):
                request(s, ipc, page=page)
                wait_for(lambda: probe(s, ipc)['page'] == page)
                ready(s, ipc)

            def refresh():
                before = settled()['generation']
                press('refresh')
                wait_for(lambda: state()['generation'] != before and not state()['pending'])
                wait_for(lambda: control('refresh')['enabled'])

            def mutations():
                return [v for line in (root/'calls.jsonl').read_text().splitlines()
                        if (v := json.loads(line))[0] in ('start', 'switch', 'stop')]

            def save_capture(name):
                time.sleep(.3)
                v = probe(s, ipc)
                capture(s, name, output['name'])
                report['captures'].append(dict(name=name, path='session/'+name+'.png', window=windows(ipc)[0]['geometry']))
                body, footer = v['body_bounds'], v['footer_bounds']
                assert footer['y'] + footer['height'] <= v['height'] + 1
                assert body['y'] + body['height'] <= footer['y'] + 1
                for c in v['controls']:
                    if not c['field'].startswith('sched-ext/') or not c.get('visible'):
                        continue
                    box = c['bounds']
                    if box and box['height'] > 0:
                        assert box['x'] >= body['x'] - 1 and box['x'] + box['width'] <= body['x'] + body['width'] + 1, c
                return v

            def finish_app():
                app.stop()
                report['frame_warnings'].extend(line for line in app.lines if any(w in line for w in FRAME_WARNINGS))
                clean(app, allowed_warnings=FRAME_WARNINGS)

            settled(); wait_for(lambda: control('apply')['enabled'])
            before = editor.document()
            for section in ('details_section', 'boot_section'):
                assert not control(section)['selected']
                press(section); assert control(section)['selected']
            assert 'scx_missing' in control('missing')['text']
            assert json.loads(control('arguments')['text']) == ['-m', 'auto']
            save_capture('expanded')
            go('appearance')
            go('system')
            assert control('details_section')['selected'] and control('boot_section')['selected']
            for section in ('details_section', 'boot_section'):
                press(section)
            for mode in ('auto', 'gaming', 'lowlatency', 'powersave', 'server'):
                press('mode/' + mode)
                assert control('mode/' + mode)['selected']
                assert probe(s, ipc)['sched_ext']['mode'] == mode
                if mode == 'powersave':
                    assert 'No distinct arguments' in control('mode_note')['text']
            time.sleep(3.5)  # A background poll must not steal radio focus.
            assert control('mode/server')['focused']
            keys(s, 'Home'); wait_for(lambda: control('mode/auto')['selected'])
            keys(s, 'Right'); wait_for(lambda: control('mode/gaming')['selected'])
            keys(s, 'End'); wait_for(lambda: control('mode/server')['selected'])
            assert editor.document() == before and mutations() == []
            report['checks'].append('disclosures-mode-radio-keyboard-and-navigation-without-mutation')

            # Remove the selected mode, then the whole scheduler, without choosing a fallback.
            original_catalog = (root/'config.json').read_text()
            config = json.loads(original_catalog)
            del config['scheds']['scx_bpfland']['server_mode']
            (root/'config.json').write_text(json.dumps(config)); refresh()
            assert probe(s, ipc)['sched_ext']['mode'] == 'server'
            assert not control('mode/server')['visible'] and not control('apply')['enabled']
            assert not any(control('mode/'+m)['selected'] for m in ('auto', 'gaming', 'lowlatency', 'powersave'))
            del config['scheds']['scx_bpfland']
            (root/'config.json').write_text(json.dumps(config)); refresh()
            assert probe(s, ipc)['sched_ext']['scheduler'] == 'scx_bpfland'
            assert not control('apply')['enabled']
            (root/'config.json').write_text(original_catalog); refresh()
            assert control('mode/server')['selected']
            # Auto missing on a newly selected scheduler requires an explicit mode.
            config = json.loads(original_catalog)
            del config['scheds']['scx_lavd']['auto_mode']
            (root/'config.json').write_text(json.dumps(config)); refresh()
            press('scheduler'); keys(s, 'End', 'Return')
            wait_for(lambda: probe(s, ipc)['sched_ext']['scheduler'] == 'scx_lavd')
            assert not control('mode/auto')['visible'] and not control('apply')['enabled']
            press('mode/gaming'); assert control('apply')['enabled']
            (root/'config.json').write_text(original_catalog); refresh()
            press('scheduler'); keys(s, 'Home', 'Return')
            wait_for(lambda: probe(s, ipc)['sched_ext']['scheduler'] == 'scx_bpfland')
            press('mode/gaming')
            assert mutations() == []
            report['checks'].append('removed-scheduler-mode-and-absent-auto-never-select-a-fallback')

            # A native preference edit remains distinct from immediate scheduler application.
            go('appearance')
            click(s, ipc, 'font'); type_text(s, 'Sans'); keys(s, 'Tab'); ready(s, ipc)
            assert json.loads(editor.document())['font'] == 'Sans'
            go('system')
            wait_for(lambda: control('apply')['enabled'])
            (root/'control.json').write_text(json.dumps(dict(delay=1)))
            press('apply')
            wait_for(lambda: state()['pending'])
            assert not control('apply')['enabled'] and not control('stop')['enabled']
            assert control('feedback')['visible']
            wait_for(lambda: state()['status'].get('scheduler') == 'scx_bpfland' and not state()['pending'])
            assert mutations() == [['start', '--sched', 'scx_bpfland', '--mode', 'gaming']]
            assert not control('apply')['enabled']
            assert json.loads(editor.document())['font'] == 'Sans'
            go('appearance')
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(editor.document())['font'] == initial['font']
            go('system')
            assert settled()['status']['mode'] == 'gaming'
            report['checks'].append('immediate-apply-does-not-save-preferences-and-discard-does-not-revert-runtime')

            # Pending selection differs visibly from observed runtime.
            press('mode/auto'); press('refresh'); settled()
            assert control('mode/auto')['selected']
            save_capture('dark')
            (root/'control.json').write_text(json.dumps(dict(fail=True)))
            press('apply')
            wait_for(lambda: 'failed' in state()['feedback'].lower() and not state()['pending'])
            assert control('mode/auto')['selected'] and control('feedback')['visible']
            save_capture('failure')
            (root/'control.json').write_text('{}'); refresh()
            press('apply')
            wait_for(lambda: state()['status'].get('scheduler') == 'scx_bpfland' and not state()['pending'])
            (root/'control.json').write_text(json.dumps(dict(delay=1)))
            press('stop')
            wait_for(lambda: state()['pending'])
            assert control('stop_feedback')['visible']
            wait_for(lambda: state()['status']['kind'] == 'stopped' and not state()['pending'])
            assert mutations()[-1] == ['stop'] and not control('stop')['enabled']
            (root/'control.json').write_text('{}')
            (root/'kernel-state').write_text('enabled\n'); refresh()
            assert 'External or unknown' in probe(s, ipc)['sched_ext']['current']
            assert not control('apply')['enabled'] and not control('stop')['enabled']
            save_capture('unknown')
            (root/'kernel-state').write_text('disabled\n')
            (root/'bin/scxctl').rename(root/'bin/scxctl.off'); refresh()
            assert control('summary')['visible'] and not control('apply')['enabled']
            save_capture('unavailable')
            (root/'bin/scxctl.off').rename(root/'bin/scxctl'); refresh()
            report['checks'].append('apply-stop-progress-failure-external-state-and-dependency-recovery')
            finish_app()

            for name, width, height, variant, mode, font, scale, language in (
                ('light', 1200, 960, 'light', 'static', 14, 1, 'en_US.UTF-8'),
                ('native', 1040, 900, 'light', 'gtk', 14, 1, 'en_US.UTF-8'),
                ('narrow', 390, 900, 'dark', 'static', 14, 1, 'en_US.UTF-8'),
                ('narrow-light', 560, 800, 'light', 'static', 14, 1, 'en_US.UTF-8'),
                ('large-text', 560, 900, 'dark', 'static', 24, 1, 'en_US.UTF-8'),
                ('german', 390, 900, 'dark', 'static', 14, 1, 'de_DE.UTF-8'),
                ('short', 1040, 480, 'dark', 'static', 14, 1, 'en_US.UTF-8'),
                ('scale-125', 1040, 800, 'dark', 'static', 14, 1.25, 'en_US.UTF-8'),
                ('scale-150', 960, 640, 'dark', 'static', 14, 1.5, 'en_US.UTF-8'),
                ('scale-200', 700, 460, 'dark', 'static', 14, 2, 'en_US.UTF-8'),
            ):
                p = copy.deepcopy(initial)
                p['theme'].update(mode=mode, variant=variant, gtk_name='')
                p['font_size'], p['reduced_motion'] = font, True
                editor.keep(json.dumps(p)); assert editor.action('apply')['state'] == 'succeeded'
                s.run(['wlr-randr', '--output', output['name'], '--scale', str(scale)])
                resize(s, rules, width, height)
                ipc.call('command', action='session.reload', fields={})
                app = s.child('settings-'+name, [args.settings.resolve(), '--page', 'system'], G_DEBUG='fatal-criticals', LANG=language)
                app.expect('event=settings-window-created'); ready(s, ipc)
                wait_for(lambda: control('apply')['enabled'])
                v = save_capture(name)
                assert v['width'] <= width + 1, (name, v['width'])
                press('mode/gaming'); keys(s, 'Left')
                wait_for(lambda: control('mode/auto')['selected'])
                press('details_section'); press('boot_section')
                save_capture(name+'-details')
                finish_app()
            report['checks'].append('dark-light-gtk-390-560-short-large-text-german-scales-and-keyboard')
            editor.close(); peer.close(); shell.stop(); clean(shell)
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=repr(exc))
        raise
    finally:
        (args.output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
