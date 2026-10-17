#!/usr/bin/env python3
"""Live committed Pearl appearance against a real Phyto in a private desktop."""
import argparse
import json
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parents[1]
sys.path[:0] = [str(ROOT / 'scripts'), str(ROOT / 'tests/integration')]
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC
from test_custom_themes import Peer

BASELINE_DARK_ACCENT = [0xd0 / 255, 0xbc / 255, 0xff / 255]
BASELINE_LIGHT_ACCENT = [0x67 / 255, 0x50 / 255, 0xa4 / 255]


def rgb(value):
    return [int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)]


THEME_FIELDS = ('theme_mode', 'theme_subscribed', 'theme_revision', 'theme_native', 'theme_class', 'theme_accent', 'theme_foreground')


def theme_state(probe):
    return {key: probe[key] for key in THEME_FIELDS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--pearl', type=Path, default=ROOT / 'zig-out/bin/pearl')
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/themes')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'checks': []}

    def passed(name):
        report['checks'].append(name)
        print('PASS', name, flush=True)

    try:
        with PrivateSession(output / 'session', tool_prefix=fixture_prefix()) as session:
            session.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(session)
            display = next(iter(ipc.outputs().values()))
            session.run(['wlr-randr', '--output', display['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(session.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 760\n')
            ipc.call('command', action='session.reload', fields={})
            # Prevent first-install profile provisioning; all files are private.
            config = Path(session.env['XDG_CONFIG_HOME']) / 'pearl'
            config.mkdir()
            (config / 'last-good.json').write_text('{}')

            app = None
            launch_count = 0

            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Phyto']

            def key(name, *modifiers):
                command = ['wtype', '-s', '60']
                for mod in modifiers:
                    command += ['-M', mod]
                command += ['-k', name]
                for mod in reversed(modifiers):
                    command += ['-m', mod]
                session.run(command)

            def probe():
                assert app.proc.poll() is None, app.lines[-30:]
                start = len(app.lines)
                key('F12')
                return wait_for(lambda: next((json.loads(line[len('PHYTO_PROBE '):]) for line in app.lines[start:] if line.startswith('PHYTO_PROBE ')), None))

            def launch(*flags):
                nonlocal app, launch_count
                launch_count += 1
                app = session.child(f'phyto-{launch_count}', [args.binary.resolve(), *flags], G_DEBUG='fatal-warnings')
                window = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.activate', fields={'id': window['id']})
                return wait_for(lambda: probe())

            def close():
                key('w', 'ctrl')
                assert app.wait(timeout=10) == 0, app.lines[-30:]
                assert not any(token in line for line in app.lines for token in ('WARNING', 'CRITICAL', 'panic:')), app.lines[-30:]
                wait_for(lambda: not windows())

            def capture(name):
                session.run(['grim', '-o', display['name'], output / f'{name}.png'])

            standalone = launch()
            assert standalone['theme_mode'] == 'follow_pearl', standalone
            assert standalone['theme_revision'] is None, standalone
            assert standalone['theme_class'] == 'dark' and not standalone['theme_native'], standalone
            assert standalone['theme_accent'] == BASELINE_DARK_ACCENT, standalone
            capture('standalone')
            passed('First run keeps Phyto palette while Pearl is absent')

            shell = session.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            peer = Peer(session, ipc)
            wait_for(lambda: not peer.state()['busy'], 25)
            dark = wait_for(lambda: (t if (t := probe())['theme_revision'] is not None else False), 15)
            committed = peer.call('ping')['result']['appearance']
            assert dark['theme_class'] == 'dark' and not dark['theme_native'], dark
            assert dark['theme_accent'] == rgb(committed['palette']['primary']), (dark, committed)
            assert dark['theme_foreground'] == rgb(committed['palette']['text']), (dark, committed)
            capture('connected-dark')
            passed('An already running Phyto connects when Pearl starts')

            def commit(edit):
                prefs = json.loads(peer.document('committed'))
                edit(prefs)
                peer.keep(json.dumps(prefs))
                result = peer.action('apply')
                assert result['state'] == 'succeeded', result
                wait_for(lambda: not peer.state()['busy'], 25)
                expected = peer.call('ping')['result']['appearance']
                return wait_for(lambda: (t if (t := probe())['theme_revision'] == int(expected['revision']) else False), 4), expected

            light, expected = commit(lambda p: p['theme'].update(variant='light'))
            assert light['theme_class'] == 'light' and not light['theme_native'], light
            assert light['theme_accent'] == rgb(expected['palette']['primary']), (light, expected)
            assert light['theme_foreground'] != dark['theme_foreground'], light
            capture('committed-light')
            passed('Committed light variant recolors Phyto while running')

            native, _ = commit(lambda p: p['theme'].update(mode='gtk', gtk_name='HighContrast', package_id='', catalog_revision='', snapshot_digest=''))
            assert native['theme_native'] and native['theme_class'] == 'native', native
            capture('pearl-gtk-high-contrast')
            static, expected = commit(lambda p: p['theme'].update(mode='static', gtk_name='', package_id='', palette_id='', style_id='', catalog_revision='', snapshot_digest='', variant='dark'))
            assert not static['theme_native'] and static['theme_class'] == 'dark', static
            assert static['theme_accent'] == rgb(expected['palette']['primary']), (static, expected)
            passed('Follow Pearl honors its GTK theme mode and returns to palettes')

            key('w', 'ctrl')
            assert app.wait(timeout=10) == 0, app.lines[-30:]
            wait_for(lambda: not windows())
            manual = launch('--light')
            assert manual['theme_mode'] == 'light' and not manual['theme_subscribed'], manual
            assert manual['theme_accent'] == BASELINE_LIGHT_ACCENT, manual
            prefs = json.loads(peer.document('committed'))
            prefs['theme']['variant'] = 'light'
            peer.keep(json.dumps(prefs))
            assert peer.action('apply')['state'] == 'succeeded'
            wait_for(lambda: not peer.state()['busy'], 25)
            time.sleep(1)
            assert theme_state(probe()) == theme_state(manual)
            capture('manual-light')
            passed('Manual CLI modes ignore Pearl theme changes')
            close()

            restored = launch()
            assert restored['theme_mode'] == 'follow_pearl', restored
            wait_for(lambda: (t if (t := probe())['theme_revision'] is not None else False), 15)
            close()
            passed('Saved Follow Pearl preference survives restart')
            peer.close()
            shell.stop()
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=str(exc))
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
