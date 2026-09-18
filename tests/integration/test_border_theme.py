#!/usr/bin/env python3
"""Verify real matugen border synchronization through the Settings backend."""
import argparse
import json
import time
from pathlib import Path
from PIL import Image

from test_settings_app import ROOT, PrivateSession, IPC, wait_for, resize, probe, capture
from test_settings_appearance import ready, click, settled
from test_settings_services import Peer


class ThemePeer(Peer):
    def call(self, op, **params):
        reply = super().call(op, **params)
        if op == 'hello' and reply['ok']:
            self.appearance = reply['result']['appearance']
        return reply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--settings', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/border-theme')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = []

    def passed(name):
        checks.append(name)
        print('PASS', name, flush=True)

    with PrivateSession(args.output / 'session', tool_prefix=ROOT / '.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        mode = s.base / 'generator-mode'
        mode.write_text('pass')
        calls = s.base / 'generator-calls'
        calls.write_text('')
        s.env.update(PATH=str(ROOT / 'tests/fixtures/theme') + ':' + s.env['PATH'],
                     PEARL_TEST_GENERATOR_MODE=str(mode), PEARL_TEST_GENERATOR_LOG=str(calls))
        ipc = IPC(s)
        output = next(iter(ipc.outputs().values()))
        s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
        resize(s, Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml', 1040, 850)
        shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = Peer(s, ipc)
        settled(peer)
        peer.aq_action('refresh')
        def fields():
            return {f['id']: f['value'] for f in peer.aq_document('committed')['fields']}

        before = fields()
        ids = ['layout.border_focused', 'layout.border_normal', 'layout.border_urgent']

        def wait_colors():
            appearance_peer = ThemePeer(s, ipc)
            palette = appearance_peer.appearance['palette']
            appearance_peer.close()
            desired = dict(zip(ids, ['0xFF' + palette[role][1:].upper()
                                    for role in ('primary', 'outline', 'error_color')]))
            def matches():
                state = peer.aqueous()
                if state['busy'] or state['draft']:
                    return False
                actual = fields()
                return all(actual[k].lower() == v.lower() for k, v in desired.items())
            try:
                wait_for(matches, 30)
            except TimeoutError:
                raise AssertionError((desired, fields(), peer.aqueous()))
            return desired

        def apply_theme(**changes):
            prefs = json.loads(peer.document('committed'))
            prefs['theme'].update(changes)
            peer.keep(json.dumps(prefs))
            result = peer.action('apply')
            assert result['state'] == 'succeeded', result
            settled(peer)

        # Enable through the actual GTK control and save the shared Pearl draft.
        app = s.child('settings', [args.settings.resolve(), '--page', 'appearance'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created')
        ready(s, ipc)
        click(s, ipc, 'sync_borders')
        try:
            wait_for(lambda: peer.state()['dirty'])
        except TimeoutError:
            capture(s, 'toggle-failed', output['name'])
            (args.output / 'toggle-failed.json').write_text(json.dumps(probe(s, ipc), indent=2))
            raise
        assert json.loads(peer.document())['theme']['sync_borders']
        click(s, ipc, 'apply')
        wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'])
        wait_colors()
        assert {k: v for k, v in fields().items() if k not in ids} == {k: v for k, v in before.items() if k not in ids}
        passed('checkbox-saves-only-border-colors')

        apply_theme(mode='dynamic', seed='#006e90')
        first = wait_colors()
        assert calls.read_text()
        apply_theme(seed='#b3261e')
        second = wait_colors()
        assert first != second
        apply_theme(variant='light')
        third = wait_colors()
        assert second != third
        passed('real-matugen-seed-and-variant-follow')

        wallpaper = s.base / 'border-wallpaper.png'
        Image.new('RGB', (64, 64), '#1b7f42').save(wallpaper)
        prefs = json.loads(peer.document('committed'))
        prefs['wallpaper']['path'] = str(wallpaper)
        prefs['theme']['source'] = 'wallpaper'
        peer.keep(json.dumps(prefs))
        assert peer.action('apply')['state'] == 'succeeded'
        wallpaper_colors = wait_colors()
        assert wallpaper_colors != third
        apply_theme(source='seed')
        third = wait_colors()
        passed('wallpaper-generated-palette-follows')

        # Pending manual edits remain untouched until explicitly discarded.
        base = peer.aq_document('committed')
        draft = dict(protocol=1, expected_generation=base['generation'], raw_files={},
                     changes=[dict(id='layout.gaps_outer', value=27)])
        assert peer.aq_keep(draft)['result']['state'] == 'succeeded'
        apply_theme(seed='#6750a4')
        time.sleep(.5)
        assert peer.aq_document('draft')['changes'] == draft['changes']
        assert all(fields()[k].lower() == v.lower() for k, v in third.items())
        peer.aq_action('discard')
        wait_colors()
        assert fields()['layout.gaps_outer'] == before['layout.gaps_outer']
        passed('manual-drafts-defer-sync-without-applying-other-edits')

        saved = {k: fields()[k] for k in ids}
        mode.write_text('fail')
        prefs = json.loads(peer.document('committed'))
        prefs['theme']['seed'] = '#123456'
        peer.keep(json.dumps(prefs))
        assert peer.action('apply')['state'] == 'failed'
        assert {k: fields()[k] for k in ids} == saved
        peer.action('discard')
        mode.write_text('pass')
        passed('generator-failure-keeps-border-colors')

        apply_theme(mode='gtk')
        time.sleep(.5)
        assert {k: fields()[k] for k in ids} == saved
        apply_theme(sync_borders=False, mode='static', variant='dark')
        time.sleep(.5)
        assert {k: fields()[k] for k in ids} == saved
        passed('gtk-and-disabled-setting-preserve-colors')
        peer.close()
    (args.output / 'report.json').write_text(json.dumps(dict(status='passed', checks=checks), indent=2))


if __name__ == '__main__':
    main()
