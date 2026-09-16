#!/usr/bin/env python3
"""S2 normal Settings window / separate Zig frontend on private Aqueous sessions."""
import argparse
import hashlib
import json
import socket
import sys
import time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC, ctl, status, capture, clean
APP_ID = 'org.aqueous.Pearl.Settings'


def endpoint(s, ipc): return s.runtime / 'pearl' / ipc.session / 'settings-app.sock'


def request(s, ipc, **params):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5); sock.connect(str(endpoint(s, ipc)))
        message = dict(settings=1, session=ipc.session, display=str(s.display_path)) | params
        sock.sendall(json.dumps(message).encode() + b'\n')
        with sock.makefile('rb') as f: return json.loads(f.readline())


def probe(s, ipc):
    result = request(s, ipc, op='probe')
    assert result['ok'], result
    return result['result']


def windows(ipc): return [w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == APP_ID]


def click_widget(s, ipc, rect):
    assert rect and rect['width'] > 0, rect
    win = windows(ipc)[0]['geometry']
    x = win['x'] + rect['x'] + rect['width']/2
    y = win['y'] + rect['y'] + rect['height']/2
    s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
    s.run(['wlrctl', 'pointer', 'move', str(round(x)), str(round(y))])
    s.run(['wlrctl', 'pointer', 'click'])
    time.sleep(.15)


def keys(s, *names):
    cmd = ['wtype', '-s', '80']
    for name in names: cmd += ['-k', name, '-s', '80']
    s.run(cmd)


def choose_navigation(s, ipc, page, section=None, pointer=True):
    """Activate a real navigation row with pointer or keyboard, including scrolling."""
    v = probe(s, ipc)
    if v['narrow']:
        if not v['sections_open']:
            click_widget(s, ipc, v['sections_bounds'])
            wait_for(lambda: probe(s, ipc)['sections_open'])
    if pointer:
        for _ in range(40):
            v = probe(s, ipc)
            row = next(link for link in v['links'] if link['page'] == page and link['section'] == section)
            assert row['visible'], row
            rect, viewport = row['bounds'], v['navigation_bounds']
            if rect['y'] >= viewport['y'] and rect['y'] + rect['height'] <= viewport['y'] + viewport['height']:
                break
            win = windows(ipc)[0]['geometry']
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(round(win['x'] + viewport['x'] + viewport['width']/2)), str(round(win['y'] + viewport['y'] + viewport['height']/2))])
            below = rect['y'] > viewport['y']
            distance = rect['y'] + rect['height'] - viewport['y'] - viewport['height'] if below else viewport['y'] - rect['y']
            s.run(['wlrctl', 'pointer', 'scroll', str(min(180, max(10, distance + 5)) * (1 if below else -1)), '0'])
            time.sleep(.1)
        else:
            raise AssertionError(('navigation row unreachable', row, viewport))
        click_widget(s, ipc, row['bounds'])
        wait_for(lambda: (v := probe(s, ipc))['page'] == page and (section is None or v['section'] == section))
        return probe(s, ipc)
    if not v['narrow']:
        click_widget(s, ipc, v['header_bounds'])
    for _ in range(24):
        if any(link['focused'] for link in probe(s, ipc)['links']):
            break
        keys(s, 'ISO_Left_Tab')
    else:
        raise AssertionError(('navigation focus unreachable', probe(s, ipc)))
    links = [link for link in probe(s, ipc)['links'] if link['visible']]
    index = next(i for i, link in enumerate(links) if link['page'] == page and link['section'] == section)
    keys(s, 'Home', *(['Down'] * index))
    row = next(link for link in probe(s, ipc)['links'] if link['page'] == page and link['section'] == section)
    assert row['focused'], row
    keys(s, 'Return')
    wait_for(lambda: (v := probe(s, ipc))['page'] == page and (section is None or v['section'] == section))
    return probe(s, ipc)


def apply_preferences(s, ctl_binary, **changes):
    current = wait_for(lambda: (v if not (v := ctl(s, ctl_binary, 'preferences', 'status')['result'])['busy'] else False))
    prefs = current['preferences']
    for key, value in changes.items():
        if isinstance(value, dict): prefs[key].update(value)
        else: prefs[key] = value
    ctl(s, ctl_binary, 'preferences', 'apply', '--revision', str(current['revision']), '--text', json.dumps(prefs))
    return wait_for(lambda: (v if not (v := ctl(s, ctl_binary, 'preferences', 'status')['result'])['busy'] and v['revision'] > current['revision'] else False))


def resize(s, rules, width, height):
    rules.write_text('[[window]]\napp_id = "' + APP_ID + '"\nfloating = true\nwidth = ' + str(width) + '\nheight = ' + str(height) + '\n')
    time.sleep(.3)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'production', 'pearl', 'ctl'): p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT / 'artifacts/settings-app/s2')
    args = p.parse_args()
    for name in ('settings', 'production', 'pearl', 'ctl', 'output'): setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = dict(status='running', checks=checks, binaries={name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() for name in ('settings', 'production', 'pearl', 'ctl')})
    try:
        with PrivateSession(args.output / 'session', tool_prefix=ROOT / '.cache/aqueous-082') as s:
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "' + APP_ID + '"\nfloating = true\nwidth = 1040\nheight = 760\n')
            time.sleep(.25)
            app = s.child('settings', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings', PEARL_SETTINGS_FIXTURE='1')
            app.expect('event=settings-window-created')
            wait_for(lambda: len(windows(ipc)) == 1)
            v = probe(s, ipc)
            assert v['page'] == 'appearance' and v['fixture'] and not v['connected'], v
            assert not (s.runtime / 'pearl' / ipc.session / 'control.sock').exists()
            capture(s, 'appearance-no-shell')
            checks['direct-launch-without-shell-normal-window'] = True
            assert windows(ipc)[0]['backend'] == 'xdg'
            assert windows(ipc)[0]['can_minimize'] and windows(ipc)[0]['can_maximize']
            assert not (Path(s.env['XDG_CONFIG_HOME']) / 'pearl').exists()
            assert b'Studio headphones' not in args.production.read_bytes()
            linked = s.run(['readelf', '-d', args.production]).stdout
            for forbidden in ('layer-shell', 'libpulse', 'polkit-agent', 'libpam'):
                assert forbidden not in linked, linked
            checks['production-excludes-samples-and-shell-agent-dependencies'] = True
            pearl = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); pearl.expect('event=control-ready')
            # Reopen window after shell startup; Retry is separately exercised below.
            app.stop(); clean(app)
            app = s.child('settings-connected', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings', PEARL_SETTINGS_FIXTURE='1')
            app.expect('event=settings-window-created')
            wait_for(lambda: probe(s, ipc)['connected'])
            for page in ('appearance', 'sound', 'network', 'bluetooth', 'power', 'overview'):
                launch = s.run([args.production, '--page', page], check=False)
                assert launch.returncode == 0, launch.stderr
                wait_for(lambda: probe(s, ipc)['page'] == page)
                assert len(windows(ipc)) == 1
                time.sleep(.2); capture(s, page + '-dark', output['name'])
                (args.output / (page + '-probe.json')).write_text(json.dumps(probe(s, ipc), indent=2))
            checks['second-launch-selects-page-and-retains-one-window'] = True
            # Generic launches always select Overview, never toggle closed.
            assert s.run([args.production], check=False).returncode == 0
            assert probe(s, ipc)['page'] == 'overview'
            for arguments in (['--page', 'wifi'], ['--page', 'sound', '--section', 'displays'], ['--page', 'aqueous', '--section', 'bogus']):
                assert s.run([args.production, *arguments], check=False).returncode == 2
                assert probe(s, ipc)['page'] == 'overview'
            assert s.run([args.production, '--page', 'aqueous', '--section', 'displays'], check=False).returncode == 0
            assert probe(s, ipc)['section'] == 'displays'
            assert not request(s, ipc, page='sound', section='displays')['ok']
            assert probe(s, ipc)['page'] == 'aqueous'
            checks['generic-launch-strict-validation-and-aqueous-sections'] = True
            for section, title in [('appearance', 'Appearance'), ('layouts', 'Layouts'), ('input', 'Input'), ('keybinds', 'Shortcuts'), ('rules', 'Rules'), ('displays', 'Displays'), ('advanced', 'Advanced')]:
                v = choose_navigation(s, ipc, 'aqueous', section, pointer=section != 'keybinds')
                assert v['heading'] == title, v
                assert [link['section'] for link in v['links'] if link['active']] == [section]
                assert all(link['visible'] for link in v['links'] if link['section'])
            capture(s, 'aqueous-sublist-wide', output['name'])
            v = choose_navigation(s, ipc, 'advanced')
            assert not any(link['visible'] for link in v['links'] if link['section'])
            v = choose_navigation(s, ipc, 'aqueous')
            assert v['section'] == 'advanced'
            v = choose_navigation(s, ipc, 'aqueous')
            assert v['section'] == 'advanced'
            assert s.run([args.production, '--page', 'aqueous'], check=False).returncode == 0
            wait_for(lambda: probe(s, ipc)['section'] == 'appearance')
            checks['aqueous-sublist-pointer-keyboard-parent-return-and-external-default'] = True
            # Parallel launches all complete through one owner.
            launches = [s.child('concurrent-' + str(i), [args.production, '--page', 'sound']) for i in range(6)]
            for child in launches: clean(child)
            assert len(windows(ipc)) == 1 and probe(s, ipc)['page'] == 'sound'
            checks['concurrent-launches-single-owner'] = True
            win_id = windows(ipc)[0]['id']
            ipc.call('command', action='window.minimized', fields=dict(id=win_id, value=True))
            wait_for(lambda: windows(ipc)[0]['minimized'])
            assert s.run([args.production, '--page', 'network'], check=False).returncode == 0
            assert probe(s, ipc)['page'] == 'network'
            desktop = s.base / 'settings.desktop'
            desktop.write_text('[Desktop Entry]\nType=Application\nName=Pearl Settings\nExec=' + str(args.production) + ' --page network\nStartupNotify=true\n')
            launcher = s.child('launcher', ['python3', ROOT/'tests/fixtures/settings_launcher.py', desktop])
            launcher.expect('event=launcher-ready')
            launch_window = wait_for(lambda: next((w for w in ipc.state() if w['kind'] == 'window' and w.get('app_id') == 'org.pearl.SettingsLauncherFixture'), None))
            geo = launch_window['geometry']
            s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
            s.run(['wlrctl', 'pointer', 'move', str(geo['x'] + geo['width']//2), str(geo['y'] + geo['height']//2)])
            s.run(['wlrctl', 'pointer', 'click'])
            launcher.expect('event=settings-launched')
            wait_for(lambda: probe(s, ipc)['activation_contexts'] > 0)
            wait_for(lambda: not windows(ipc)[0]['minimized'])
            launcher.stop(); clean(launcher)
            checks['gio-launcher-token-forwards-and-restores-minimized-window'] = True
            ipc.call('command', action='window.maximized', fields=dict(id=win_id, value=True))
            wait_for(lambda: windows(ipc)[0]['maximized'])
            ipc.call('command', action='window.maximized', fields=dict(id=win_id, value=False))
            wait_for(lambda: not windows(ipc)[0]['maximized'])
            keys(s, 'Escape'); assert app.proc.poll() is None
            checks['ordinary-minimize-maximize-reactivation-and-escape'] = True
            # Real sidebar pointer and keyboard input, with distinct selection.
            request(s, ipc, page='appearance')
            v = probe(s, ipc)
            sound = next(link for link in v['links'] if link['page'] == 'sound')
            click_widget(s, ipc, sound['bounds'])
            wait_for(lambda: probe(s, ipc)['page'] == 'sound')
            assert sum(link['active'] for link in probe(s, ipc)['links']) == 1
            # The heading receives focus on external activation.
            request(s, ipc, page='appearance')
            wait_for(lambda: probe(s, ipc)['focus'] == 'heading')
            checks['pointer-sidebar-selection-and-external-heading-focus'] = True
            # Keyboard traversal gives focus without changing the selected page.
            # Tokenless socket activation does not grant compositor keyboard focus.
            click_widget(s, ipc, probe(s, ipc)['header_bounds'])
            for _ in range(24):
                keys(s, 'ISO_Left_Tab')
                v = probe(s, ipc)
                if v['focus'] in {link['page'] for link in v['links']}: break
            else: raise AssertionError(('sidebar unreachable by keyboard', v))
            keys(s, 'Home')
            assert probe(s, ipc)['focus'] == 'overview' and probe(s, ipc)['page'] == 'appearance'
            keys(s, 'Down')
            assert probe(s, ipc)['focus'] == 'network' and probe(s, ipc)['page'] == 'appearance'
            keys(s, 'Return')
            wait_for(lambda: probe(s, ipc)['page'] == 'network')
            checks['keyboard-focus-distinct-from-selection'] = True
            # Focus a body control, then navigate by pointer away and back.
            request(s, ipc, page='appearance')
            time.sleep(.15)
            click_widget(s, ipc, probe(s, ipc)['header_bounds'])
            keys(s, 'Tab')
            wait_for(lambda: probe(s, ipc)['focus'] == 'body')
            v = probe(s, ipc)
            click_widget(s, ipc, next(link['bounds'] for link in v['links'] if link['page'] == 'sound'))
            click_widget(s, ipc, next(link['bounds'] for link in probe(s, ipc)['links'] if link['page'] == 'appearance'))
            assert probe(s, ipc)['focus'] == 'body'
            # Scroll each viewport with real input; fixed chrome never moves.
            click_widget(s, ipc, probe(s, ipc)['body_bounds'])
            s.run(['wlrctl', 'pointer', 'scroll', '300', '0']); time.sleep(.3)
            before = probe(s, ipc)
            assert before['scroll'] > 0, before
            click_widget(s, ipc, next(link['bounds'] for link in before['links'] if link['page'] == 'sound'))
            assert probe(s, ipc)['scroll'] == 0
            click_widget(s, ipc, next(link['bounds'] for link in probe(s, ipc)['links'] if link['page'] == 'appearance'))
            after = probe(s, ipc)
            assert abs(before['scroll'] - after['scroll']) < 1, (before, after)
            assert before['header_bounds'] == after['header_bounds'] and before['footer_bounds'] == after['footer_bounds']
            request(s, ipc, page='appearance'); time.sleep(.15)
            assert probe(s, ipc)['scroll'] == 0 and probe(s, ipc)['focus'] == 'heading'
            checks['internal-body-focus-and-page-scroll-restoration'] = True
            for mode, variant, label in [('static', 'light', 'light'), ('gtk', 'light', 'gtk'), ('static', 'dark', 'dark')]:
                committed = apply_preferences(s, args.ctl, theme=dict(mode=mode, variant=variant))
                wait_for(lambda: probe(s, ipc)['style'] == ('gtk' if mode == 'gtk' else variant))
                for page in ('appearance', 'network', 'bluetooth', 'sound', 'power'):
                    request(s, ipc, page=page); time.sleep(.2)
                    capture(s, page + '-' + label, output['name'])
            checks['committed-material-light-dark-native-gtk'] = True
            resize(s, rules, 480, 700)
            ipc.call('command', action='session.reload', fields={})
            # Placement rules set initial geometry; this compositor preserves a
            # window's geometry after explicit maximize/restore.
            app.stop(); clean(app)
            app = s.child('settings-narrow', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings', PEARL_SETTINGS_FIXTURE='1')
            app.expect('event=settings-window-created')
            wait_for(lambda: (v := probe(s, ipc))['narrow'] and 0 < v['width'] <= 500)
            request(s, ipc, page='appearance'); time.sleep(.2)
            v = probe(s, ipc)
            assert v['width'] <= 500, v
            assert v['footer_bounds']['y'] + v['footer_bounds']['height'] <= v['height'] + 1
            capture(s, 'appearance-narrow', output['name'])
            click_widget(s, ipc, v['sections_bounds'])
            wait_for(lambda: probe(s, ipc)['sections_open'])
            capture(s, 'sections-narrow', output['name'])
            keys(s, 'Escape'); wait_for(lambda: not probe(s, ipc)['sections_open'])
            assert app.proc.poll() is None
            checks['narrow-navigation-fixed-footer-and-escape'] = True
            v = choose_navigation(s, ipc, 'aqueous', pointer=False)
            assert v['sections_open'] and v['section'] == 'appearance', v
            capture(s, 'aqueous-sublist-narrow', output['name'])
            v = choose_navigation(s, ipc, 'aqueous', 'displays', pointer=False)
            assert not v['sections_open'] and v['heading'] == 'Displays', v
            click_widget(s, ipc, v['sections_bounds'])
            keys(s, 'Escape')
            wait_for(lambda: not probe(s, ipc)['sections_open'])
            assert probe(s, ipc)['section'] == 'displays'
            v = choose_navigation(s, ipc, 'aqueous', 'displays', pointer=True)
            assert not v['sections_open']
            win_id = windows(ipc)[0]['id']
            ipc.call('command', action='window.maximized', fields=dict(id=win_id, value=True))
            wait_for(lambda: not probe(s, ipc)['narrow'])
            assert probe(s, ipc)['section'] == 'displays'
            ipc.call('command', action='window.maximized', fields=dict(id=win_id, value=False))
            wait_for(lambda: probe(s, ipc)['narrow'])
            assert probe(s, ipc)['section'] == 'displays'
            checks['narrow-aqueous-parent-expands-child-selects-and-escape-retains-section'] = True
            request(s, ipc, page='appearance')
            apply_preferences(s, args.ctl, font_size=24, reduced_motion=True)
            time.sleep(1.4); capture(s, 'appearance-large-text', output['name'])
            assert probe(s, ipc)['width'] <= 500
            checks['large-text-reduced-motion-no-window-width-growth'] = True
            apply_preferences(s, args.ctl, font_size=14, reduced_motion=False)
            # A backend failure leaves the frontend alive and retryable.
            pearl.stop(); clean(pearl)
            wait_for(lambda: not probe(s, ipc)['connected'])
            assert app.proc.poll() is None
            pearl = s.child('pearl-restarted', [args.pearl], G_DEBUG='fatal-warnings'); pearl.expect('event=control-ready')
            # Fixture hides status chrome; reopen without fixture for Retry checks.
            assert status(s, args.ctl)['popup'] is None
            app.stop(); clean(app)
            assert pearl.proc.poll() is None
            normal = s.child('settings-real-state', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings')
            normal.expect('event=settings-window-created'); wait_for(lambda: probe(s, ipc)['connected'])
            assert not probe(s, ipc)['fixture']
            capture(s, 'production-state', output['name'])
            pearl.stop(); clean(pearl)
            wait_for(lambda: not probe(s, ipc)['connected'])
            capture(s, 'session-unavailable', output['name'])
            pearl = s.child('pearl-retry', [args.pearl], G_DEBUG='fatal-warnings'); pearl.expect('event=control-ready')
            click_widget(s, ipc, probe(s, ipc)['retry_bounds'])
            wait_for(lambda: probe(s, ipc)['connected'])
            checks['backend-loss-and-explicit-retry-without-shell-start'] = True
            wait_for(lambda: probe(s, ipc)['editor']['ready'])
            ipc.call('command', action='window.activate', fields=dict(id=windows(ipc)[0]['id']))
            # Give the newly created virtual keyboard time to deliver its enter.
            s.run(['wtype', '-s', '200', '-M', 'ctrl', '-k', 'w', '-m', 'ctrl'])
            clean(normal); assert pearl.proc.poll() is None
            wait_for(lambda: not endpoint(s, ipc).exists())
            checks['ctrl-w-closes-only-frontend-and-removes-instance-endpoint'] = True
            production = s.child('production', [args.production], G_DEBUG='fatal-warnings', PEARL_SETTINGS_FIXTURE='1')
            production.expect('event=settings-window-created')
            assert request(s, ipc, op='probe')['err']['code'] == 'Unsupported'
            production.stop(); clean(production)
            checks['production-rejects-test-probe'] = True
            pearl.stop(); clean(pearl); ipc.close()
        with PrivateSession(args.output / 'isolation-parent', tool_prefix=ROOT / '.cache/aqueous-082') as parent:
            parent_ipc = IPC(parent)
            races = [parent.child('cold-launch-' + str(i), [args.settings, '--page', 'sound'], G_DEBUG='fatal-warnings') for i in range(4)]
            wait_for(lambda: endpoint(parent, parent_ipc).exists())
            wait_for(lambda: len([c for c in races if c.proc.poll() is None]) == 1)
            owner = next(c for c in races if c.proc.poll() is None)
            for c in races:
                if c is not owner: clean(c)
            assert len(windows(parent_ipc)) == 1
            checks['cold-concurrent-launch-race'] = True
            with PrivateSession(args.output / 'isolation-nested', backend='nested', parent_display=parent.display_path, tool_prefix=ROOT / '.cache/aqueous-082') as nested:
                nested_ipc = IPC(nested)
                child = nested.child('settings', [args.settings, '--page', 'power'], G_DEBUG='fatal-warnings', DBUS_SESSION_BUS_ADDRESS=parent.env['DBUS_SESSION_BUS_ADDRESS'])
                child.expect('event=settings-window-created')
                wait_for(lambda: len(windows(nested_ipc)) == 1)
                assert parent_ipc.session != nested_ipc.session
                assert probe(parent, parent_ipc)['page'] == 'sound'
                assert probe(nested, nested_ipc)['page'] == 'power'
                assert probe(parent, parent_ipc)['pid'] != probe(nested, nested_ipc)['pid']
                cross = request(parent, parent_ipc, page='network', session=nested_ipc.session)
                assert cross['err']['code'] == 'StaleSession'
                assert probe(parent, parent_ipc)['page'] == 'sound'
                wrong = parent.child('wrong-session', [args.settings, '--page', 'bluetooth'], AQUEOUS_SOCKET=nested.env['AQUEOUS_SOCKET'])
                wrong.expect('event=settings-connection-unavailable error=DisplayMismatch')
                assert probe(nested, nested_ipc)['page'] == 'power'
                wrong.stop(); clean(wrong)
                checks['native-identity-cross-session-denial-on-shared-dbus'] = True
                child.stop(); clean(child); nested_ipc.close()
            owner.proc.kill(); owner.proc.wait(timeout=5)
            wait_for(lambda: len(windows(parent_ipc)) == 0)
            assert endpoint(parent, parent_ipc).exists()
            recovered = parent.child('settings-recovered', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-warnings')
            recovered.expect('event=settings-window-created')
            assert probe(parent, parent_ipc)['page'] == 'appearance'
            recovered.stop(); clean(recovered)
            wait_for(lambda: not endpoint(parent, parent_ipc).exists())
            checks['frontend-crash-stale-instance-recovery'] = True
            parent_ipc.close()
        report['status'] = 'passed'
    finally:
        (args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
