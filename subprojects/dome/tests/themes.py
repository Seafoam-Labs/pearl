#!/usr/bin/env python3
"""Live committed Pearl appearance against a real Dome in a private desktop."""
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
from test_theme_packages import fixture, archive, PALETTE


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
            rules.write_text('[[window]]\napp_id = "org.aqueous.Dome"\nfloating = true\nwidth = 1120\nheight = 800\n')
            ipc.call('command', action='session.reload', fields={})
            # Prevent first-install profile provisioning; all files are private.
            config = Path(session.env['XDG_CONFIG_HOME']) / 'pearl'
            config.mkdir()
            (config / 'last-good.json').write_text('{}')

            app = None
            launch_count = 0

            def windows():
                return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.aqueous.Dome']

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
                state = wait_for(lambda: next((json.loads(line[11:]) for line in app.lines[start:] if line.startswith('DOME_PROBE ')), None))
                theme = next(json.loads(line[11:]) for line in app.lines[start:] if line.startswith('DOME_THEME '))
                return state, theme

            def launch(*flags):
                nonlocal app, launch_count
                launch_count += 1
                app = session.child(f'dome-{launch_count}', [args.binary.resolve(), '--page=0', *flags], G_DEBUG='fatal-warnings')
                window = wait_for(lambda: next(iter(windows()), None))
                ipc.call('command', action='window.activate', fields={'id': window['id']})
                return wait_for(lambda: (v if (v := probe())[0]['sample'] >= 2 else False))

            def close():
                key('w', 'ctrl')
                assert app.wait(timeout=10) == 0, app.lines[-30:]
                assert not any(token in line for line in app.lines for token in ('WARNING', 'CRITICAL', 'panic:')), app.lines[-30:]
                wait_for(lambda: not windows())

            def capture(name):
                session.run(['grim', '-o', display['name'], output / f'{name}.png'])

            state, native = launch()
            assert native['mode'] == 'follow_pearl' and native['native'] and native['revision'] is None, native
            capture('standalone')
            passed('First run uses native GTK while Pearl is absent')
            shell = session.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            peer = Peer(session, ipc)
            wait_for(lambda: not peer.state()['busy'], 25)
            dark = wait_for(lambda: (t if (t := probe()[1])['revision'] is not None else False), 15)
            assert dark['pearl_class'] and not dark['native'], dark
            capture('connected-dark')
            passed('An already running Dome connects when Pearl starts')

            def commit(edit):
                prefs = json.loads(peer.document('committed'))
                edit(prefs)
                peer.keep(json.dumps(prefs))
                result = peer.action('apply')
                assert result['state'] == 'succeeded', result
                wait_for(lambda: not peer.state()['busy'], 25)
                expected = peer.call('ping')['result']['appearance']
                return wait_for(lambda: (t if (t := probe()[1])['revision'] == int(expected['revision']) else False), 4)

            key('p', 'ctrl')
            time.sleep(.5)
            paused = probe()[0]
            # A draft alone must not change the running application.
            draft = json.loads(peer.document('committed'))
            draft['theme']['variant'] = 'light'
            peer.keep(json.dumps(draft))
            assert probe()[1]['revision'] == dark['revision']
            peer.action('discard')
            light = commit(lambda p: p['theme'].update(variant='light'))
            assert light['foreground'] != dark['foreground'] and light['accent'] != dark['accent']
            assert probe()[0]['sample'] == paused['sample'] and probe()[0]['paused']
            capture('paused-light')
            passed('Committed light/dark colors and graphs update while paused; drafts do not')

            key('F6')
            opened = probe()
            assert opened[0]['dialog'] and opened[1]['dialog_pearl_class']
            dark_again = commit(lambda p: p['theme'].update(variant='dark'))
            # GTK's foreground transitions finish on subsequent frames.
            dark_again = wait_for(lambda: (t if (t := probe()[1])['dialog_foreground'] == t['foreground'] else False))
            assert dark_again['dialog_foreground'] == dark_again['foreground']
            assert dark_again['dialog_foreground'] != light['foreground']
            capture('open-dialog-dark')
            key('Escape')
            passed('Open dialogs receive the same committed appearance')

            source = session.base / 'theme-source'
            manifest = fixture(source)
            bundle = session.base / 'theme.tar.gz'
            archive(source, bundle)
            peer.theme('import_archive', path=str(bundle))
            catalog = peer.theme('catalog')
            themed = commit(lambda p: p['theme'].update(mode='package', package_id=manifest['id'], catalog_revision=catalog['revision']))
            expected_accent = [int(PALETTE['primary'][i:i+2], 16) / 255 for i in (1, 3, 5)]
            assert themed['accent'] == expected_accent, themed
            capture('community-theme')
            passed('Community palette, style tokens and component CSS reach Dome')

            native_theme = commit(lambda p: p['theme'].update(mode='gtk', gtk_name='HighContrast', package_id='', catalog_revision='', snapshot_digest=''))
            assert native_theme['native'] and native_theme['pearl_class'], native_theme
            capture('pearl-gtk-high-contrast')
            commit(lambda p: p['theme'].update(mode='package', gtk_name='', package_id=manifest['id'], catalog_revision=catalog['revision']))
            passed('Follow Pearl honors its GTK theme mode and can return to a community palette')

            # Exercise the real dropdown and Apply response across every mode.
            for expected in ('native_gtk', 'light', 'dark', 'follow_pearl'):
                key('F6'); key('F2')
                current = probe()[1]
                assert current['mode'] == expected, current
                if expected != 'follow_pearl':
                    assert not current['subscribed'] and current['revision'] is None and not current['pearl_class'], current
                else:
                    wait_for(lambda: probe()[1]['accent'] == expected_accent, 15)
            passed('Preference mode changes clean up providers and reconnect when following again')

            retained = probe()[1]
            peer.close()
            shell.stop()
            time.sleep(.5)
            assert probe()[1]['accent'] == retained['accent']
            capture('disconnected-retained')
            shell = session.child('pearl-restarted', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            peer = Peer(session, ipc)
            wait_for(lambda: not peer.state()['busy'], 25)
            commit(lambda p: p['theme'].update(mode='static', package_id='', palette_id='', style_id='', catalog_revision='', snapshot_digest='', variant='light'))
            assert probe()[1]['accent'] != retained['accent']
            passed('Last valid appearance survives disconnect and refreshes after Pearl restart')
            close()

            for flag, mode in (('--dark', 'dark'), ('--light', 'light'), ('--native-theme', 'native_gtk')):
                _, manual = launch(flag)
                assert manual['mode'] == mode and not manual['subscribed']
                prefs = json.loads(peer.document('committed'))
                prefs['theme']['variant'] = 'dark' if prefs['theme']['variant'] == 'light' else 'light'
                peer.keep(json.dumps(prefs))
                assert peer.action('apply')['state'] == 'succeeded'
                assert probe()[1] == manual
                close()
            passed('All manual CLI modes ignore Pearl theme changes')

            _, follow = launch('--dark', '--follow-pearl')
            assert follow['mode'] == 'follow_pearl'
            wait_for(lambda: probe()[1]['revision'] is not None, 15)
            close()
            _, restored = launch()
            assert restored['mode'] == 'follow_pearl'
            close()
            passed('CLI precedence and saved Follow Pearl preference survive restart')
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
