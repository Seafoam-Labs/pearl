#!/usr/bin/env python3
"""Native Aqueous cards, search and shared review in an isolated compositor."""
import argparse
import copy
import json
import time
from pathlib import Path
from test_settings_app import (ROOT, PrivateSession, IPC, wait_for, probe, request,
                               capture, clean, keys, resize, windows, click_widget)
from test_settings_appearance import ready, click, control, type_text
from test_settings_services import Peer, aq_ready, navigate
from pearl_session import fixture_prefix

FRAME_WARNINGS = ('gdk_frame_timings_discarded() called on already presented frame',
                  'gdk_frame_timings_throttling_hint: runtime check failed')
SECTIONS = ('appearance', 'layouts', 'input', 'keybinds', 'rules', 'displays', 'advanced')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/aqueous-layout/native')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', checks=[], captures=[], frame_warnings=[])
    try:
        with PrivateSession(args.output/'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(s.runtime/'no-system-bus')
            legacy = Path(s.env['XDG_CONFIG_HOME'])/'pearl/last-good.json'
            legacy.parent.mkdir(parents=True)
            legacy.write_text('{}')
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))['name']
            s.run(['wlr-randr', '--output', output, '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, rules, 1200, 960)
            ipc.call('command', action='session.reload', fields={})
            shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready'); shell.expect('event=preferences-applied')
            app = s.child('settings', [args.settings.resolve(), '--page', 'aqueous'], G_DEBUG='fatal-criticals')
            app.expect('event=settings-window-created')
            peer = Peer(s, ipc); ready(s, ipc); aq_ready(s, ipc, peer)

            def go(section):
                navigate(s, ipc, 'aqueous', section)
                aq_ready(s, ipc, peer)
                wait_for(lambda: probe(s, ipc)['section'] == section)

            def controls():
                return {c['field']: c for c in probe(s, ipc)['controls']}

            def footer(name):
                click_widget(s, ipc, control(s, ipc, 'aqueous.' + name))
                time.sleep(.2)

            def accept_review():
                for _ in range(6):
                    if probe(s, ipc)['aqueous']['shared_focus'] == 'accept':
                        break
                    keys(s, 'Tab')
                assert probe(s, ipc)['aqueous']['shared_focus'] == 'accept'
                keys(s, 'Return')
                wait_for(lambda: not probe(s, ipc)['aqueous']['shared_review'])

            def shot(name):
                time.sleep(.3)
                v = probe(s, ipc)
                capture(s, name, output)
                report['captures'].append(name)
                body, footer_box = v['body_bounds'], v['footer_bounds']
                assert footer_box['y'] + footer_box['height'] <= v['height'] + 1
                assert body['y'] + body['height'] <= footer_box['y'] + 1
                for c in v['controls']:
                    if c["field"] not in scalar_ids and not c["field"].startswith(("aqueous.", "display.", "record:")):
                        continue
                    rect = c['bounds']
                    if rect and rect['width'] > 0:
                        assert rect['x'] >= body['x'] - 1 and rect['x'] + rect['width'] <= body['x'] + body['width'] + 1, c
                return v

            before = peer.aq_document('committed')
            pearl_before = json.loads(peer.document('committed'))
            scalar_ids = {field['id'] for field in before['fields']}
            for section in SECTIONS:
                go(section)
                assert probe(s, ipc)['aqueous']['fields'] == 221
                assert not controls()['aqueous.apply']['enabled']
                if section != 'advanced':
                    assert 'aqueous.validate' not in controls()
                shot(section)
            assert peer.aq_document('committed') == before
            report['checks'].append('seven-routes-221-fields-fixed-footer-without-mutation')

            go('input')
            click(s, ipc, 'aqueous.section.focus')
            assert 'input.focus_follows_mouse' in controls()
            go('appearance'); go('input')
            assert controls()['aqueous.section.focus']['selected']
            click(s, ipc, 'aqueous.section.focus')
            assert 'input.focus_follows_mouse' not in controls()
            report['checks'].append('disclosure-state-restores-with-navigation')

            go('keybinds')
            assert 'focus_workspace_1' not in controls()
            click(s, ipc, 'aqueous.search'); type_text(s, 'focus_workspace_1')
            wait_for(lambda: 'focus_workspace_1' in controls())
            assert 'spawn_terminal' not in controls()
            go('input'); go('keybinds')
            assert 'focus_workspace_1' in controls() and 'spawn_terminal' not in controls()
            click(s, ipc, 'aqueous.search'); type_text(s, 'no-such-action-xyz')
            assert not any(c.startswith('record:') for c in controls())
            click(s, ipc, 'aqueous.search'); type_text(s, ''); keys(s, 'BackSpace')
            assert 'spawn_terminal' in controls() and 'focus_workspace_1' not in controls()
            report['checks'].append('search-id-empty-result-reset-and-state-restoration')

            pearl_draft = copy.deepcopy(pearl_before)
            pearl_draft['font_size'] = 16
            peer.keep(json.dumps(pearl_draft))
            retained_pearl = peer.document()

            go('layouts')
            choices = [name for name in controls() if name.startswith('aqueous.layout.')]
            assert len(choices) >= 4
            chosen = next(name for name in choices if not controls()[name]['selected'])
            click(s, ipc, chosen); aq_ready(s, ipc, peer)
            assert controls()[chosen]['selected']
            keys(s, 'End'); aq_ready(s, ipc, peer)
            assert controls()[choices[-1]]['selected']
            keys(s, 'Home'); aq_ready(s, ipc, peer)
            assert controls()[choices[0]]['selected']
            go('input')
            click(s, ipc, 'input.repeat_rate'); type_text(s, '38'); keys(s, 'Tab')
            aq_ready(s, ipc, peer)
            draft = peer.aq_document('draft')
            assert {'layout.default', 'input.repeat_rate'} <= {c['id'] for c in draft['changes']}
            footer('apply'); wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
            capture(s, 'shared-review', output)
            # Escape must dismiss review without publishing or dropping edits.
            keys(s, 'Escape')
            wait_for(lambda: not probe(s, ipc)['aqueous']['shared_review'])
            assert peer.aq_document('draft') == draft
            assert peer.aq_document('committed') == before
            report['checks'].append('layout-radio-keyboard-mixed-draft-review-cancel')

            footer('discard'); wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
            # Native Dialog action order: Cancel, then accept.
            accept_review()
            aq_ready(s, ipc, peer)
            assert not controls()['aqueous.apply']['enabled']
            assert peer.aq_document('committed') == before
            assert peer.document() == retained_pearl
            report['checks'].append('discard-confirms-entire-shared-draft')

            click(s, ipc, 'input.repeat_rate'); type_text(s, '38'); keys(s, 'Tab')
            aq_ready(s, ipc, peer)
            footer('apply'); wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
            stale = peer.aq_document('draft')
            stale['changes'][0]['value'] = 37
            assert peer.aq_keep(stale)['result']['state'] == 'succeeded'
            aq_ready(s, ipc, peer)
            accept_review()
            assert peer.aqueous()['draft'] and peer.aq_document('committed') == before
            click(s, ipc, 'input.repeat_rate'); type_text(s, '38'); keys(s, 'Tab')
            aq_ready(s, ipc, peer)
            footer('apply'); wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
            accept_review()
            wait_for(lambda: not peer.aqueous()['draft'] and not peer.aqueous()['busy'], 30)
            aq_ready(s, ipc, peer)
            assert next(f['value'] for f in peer.aq_document('committed')['fields'] if f['id'] == 'input.repeat_rate') == 38
            assert peer.document() == retained_pearl
            peer.action('discard'); ready(s, ipc)
            report['checks'].append('reviewed-nondisplay-apply-saves-through-existing-operation')
            report['checks'].append('changed-revision-requires-new-review')

            go('advanced'); click(s, ipc, 'aqueous.section.raw')
            click(s, ipc, 'aqueous.raw-source'); keys(s, 'Home', 'Down', 'Down', 'Return')
            click(s, ipc, 'aqueous.raw'); type_text(s, '[input]\nrepeat_rate = 39\n')
            aq_ready(s, ipc, peer)
            assert peer.aq_document('draft')['raw_files']['input'] == '[input]\nrepeat_rate = 39\n'
            go('input')
            assert not controls()['input.repeat_rate']['enabled']
            go('advanced')
            assert controls()['aqueous.section.raw']['selected']
            footer('discard'); wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
            accept_review(); aq_ready(s, ipc, peer)
            go('input'); assert controls()['input.repeat_rate']['enabled']
            report['checks'].append('raw-source-selection-ownership-disables-typed-fields-and-discard-restores')

            go('advanced')
            click(s, ipc, 'aqueous.raw'); type_text(s, '[')
            aq_ready(s, ipc, peer)
            click(s, ipc, 'aqueous.validate')
            wait_for(lambda: probe(s, ipc)['aqueous']['err'] is not None)
            footer('issue')
            wait_for(lambda: controls()['aqueous.section.request']['selected'])
            assert 'aqueous.request' in controls()
            footer('discard'); wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
            accept_review(); aq_ready(s, ipc, peer)
            report['checks'].append('validation-error-opens-request-disclosure-for-repair')

            go('appearance')
            click(s, ipc, 'aqueous.pearl-appearance')
            wait_for(lambda: probe(s, ipc)['page'] == 'appearance')
            go('appearance')
            report['checks'].append('contextual-pearl-appearance-route')

            resize(s, rules, 560, 820)
            ipc.call('command', action='session.reload', fields={})
            wait_for(lambda: probe(s, ipc)['width'] <= 600)
            for section in SECTIONS:
                go(section); shot('narrow-' + section)
            report['checks'].append('all-seven-sections-at-560px')
            def finish_app():
                app.stop()
                report['frame_warnings'].extend(line for line in app.lines if any(w in line for w in FRAME_WARNINGS))
                clean(app, allowed_warnings=FRAME_WARNINGS)

            finish_app()
            for name, width, height, variant, mode, font, scale, language in (
                ('light', 1200, 960, 'light', 'static', 14, 1, 'en_US.UTF-8'),
                ('native', 1040, 900, 'light', 'gtk', 14, 1, 'en_US.UTF-8'),
                ('390', 390, 900, 'dark', 'static', 14, 1, 'en_US.UTF-8'),
                ('large-text', 560, 900, 'dark', 'static', 24, 1, 'en_US.UTF-8'),
                ('german', 390, 900, 'dark', 'static', 14, 1, 'de_DE.UTF-8'),
                ('short', 1040, 480, 'dark', 'static', 14, 1, 'en_US.UTF-8'),
                ('scale-125', 1040, 800, 'dark', 'static', 14, 1.25, 'en_US.UTF-8'),
                ('scale-150', 960, 640, 'dark', 'static', 14, 1.5, 'en_US.UTF-8'),
                ('scale-200', 700, 460, 'dark', 'static', 14, 2, 'en_US.UTF-8'),
            ):
                preferences = copy.deepcopy(pearl_before)
                preferences['theme'].update(mode=mode, variant=variant, gtk_name='')
                preferences['font_size'], preferences['reduced_motion'] = font, True
                peer.keep(json.dumps(preferences)); assert peer.action('apply')['state'] == 'succeeded'
                s.run(['wlr-randr', '--output', output, '--scale', str(scale)])
                resize(s, rules, width, height)
                ipc.call('command', action='session.reload', fields={})
                app = s.child('settings-'+name, [args.settings.resolve(), '--page', 'aqueous'], G_DEBUG='fatal-criticals', LANG=language)
                app.expect('event=settings-window-created'); ready(s, ipc); aq_ready(s, ipc, peer)
                for section in SECTIONS:
                    go(section)
                    v = shot(name+'-'+section)
                    assert v['width'] <= width + 1, (name, v['width'])
                finish_app()
            report['checks'].append('all-sections-dark-light-native-390-large-text-german-short-scales-125-150-200')
            shell.stop(); clean(shell)
            report['status'] = 'passed'
    except Exception as exc:
        report['status'] = 'failed'; report['error'] = repr(exc)
        raise
    finally:
        (args.output/'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
