#!/usr/bin/env python3
"""F4 bar destinations, private AT-SPI announcements and compact presentation."""
import argparse, ast, copy, hashlib, json, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import ctl, status, eventually_status, capture, clean, IPC, click
from test_preferences import settled as preferences, apply
from test_services import command, await_services
from test_connectivity import await_state, action, state, BA, AP, SP, BD
from settings_navigation import choose_page, report, PAGES
from test_settings_pages import TITLES, assert_page

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'ctl'): p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/settings-navigation/f4/accessibility')
    p.add_argument('--full-matrix', action='store_true')
    args = p.parse_args()
    for name in ('pearl', 'ctl', 'output'): setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', checks=checks, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'session') as s:
            s.child('accessibility-bus', ['/usr/lib/at-spi-bus-launcher', '--launch-immediately'])
            wait_for(lambda: 'org.a11y.Bus' in s.run(['busctl', '--address='+s.env['DBUS_SESSION_BUS_ADDRESS'], 'list']).stdout)
            address = ast.literal_eval(s.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress']).stdout)[0]
            s.env['AT_SPI_BUS_ADDRESS'] = address
            s.child('accessibility-registry', ['/usr/lib/at-spi2-registryd'])
            wait_for(lambda: 'org.a11y.atspi.Registry' in s.run(['busctl', '--address='+address, 'list']).stdout)
            listener = s.child('announcements', ['python3', ROOT/'tests/fixtures/settings_announcements.py'])
            listener.expect('event=ready')
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
            for env_key, filename in [('PEARL_TEST_CONNECTIVITY_LOG', 'connectivity.jsonl'), ('PEARL_TEST_POWER_LOG', 'power.jsonl')]:
                s.env[env_key] = str(s.output/filename); Path(s.env[env_key]).write_text('')
            s.env['PEARL_TEST_BACKLIGHT'] = str(s.base/'backlight')
            backlight = Path(s.env['PEARL_TEST_BACKLIGHT'])/'test_panel'; backlight.mkdir(parents=True)
            (backlight/'max_brightness').write_text('1000\n'); (backlight/'brightness').write_text('420\n')
            for service in ('network', 'bluetooth', 'power'):
                cmd = ['python3', ROOT/'tests/fixtures/services'/('power.py' if service == 'power' else 'connectivity.py')]
                if service != 'power': cmd.append(service)
                child = s.child(service, cmd, input_pipe=True); child.expect('event=ready')
            if args.full_matrix:
                fixtures = ROOT/'tests/fixtures/services'
                s.env['PIPEWIRE_REMOTE'] = 'pipewire-0'
                s.child('pipewire', ['pipewire', '-c', fixtures/'pipewire.conf'])
                wait_for(lambda: (s.runtime/'pipewire-0').is_socket())
                s.child('pulse', ['pipewire-pulse', '-c', fixtures/'pulse.conf'])
                wait_for(lambda: s.run(['pactl', 'info'], check=False).returncode == 0)
                s.run(['pactl', 'load-module', 'module-null-sink', 'sink_name=test_speakers', 'sink_properties=device.description=Test_Speakers'])
                s.run(['pactl', 'set-default-sink', 'test_speakers'])
                s.run(['pactl', 'set-default-source', 'test_speakers.monitor'])
                s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.sink', '{"name":"test_speakers"}', 'Spa:String:JSON'])
                s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.source', '{"name":"test_speakers.monitor"}', 'Spa:String:JSON'])
                s.child('playback', ['pacat', '--playback', '--raw', '--device=test_speakers', '/dev/zero'])
                s.child('recording', ['pacat', '--record', '--raw', '--device=test_speakers.monitor', '/dev/null'])
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings', GTK_A11Y='atspi')
            app.expect('event=control-ready')
            await_state(s, args.ctl, lambda v: v['network']['registered'] and v['bluetooth']['registered'])
            await_services(s, args.ctl, lambda v: v['power']['battery_present'])
            if args.full_matrix: await_services(s, args.ctl, lambda v: v['audio']['count'] >= 4)
            base = copy.deepcopy(preferences(s, args.ctl)['preferences'])
            output = status(s, args.ctl)['outputs'][0]
            ipc = IPC(s)
            def current(): return next(o for o in status(s, args.ctl)['outputs'] if o['id'] == output['id'])
            def ready(page):
                eventually_status(s, args.ctl, lambda v: v['popup'] and v['popup']['page'] == page)
                return wait_for(lambda: (r if (r := report(s, args.ctl))['page'] == page and not r['restoring'] else False))
            def inspect(): return json.loads(s.run(['python3', ROOT/'tests/fixtures/inspect_accessibility.py']).stdout)['nodes']
            def bar_click(item, target=None):
                o = target or current()
                layout = ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-layout:'+o['id'])['result']
                assert layout['keyboard_mode'] == 'none', layout
                widgets = layout['items']
                rect = next(w['rect'] for w in widgets if w['name'] == item)
                bounds = o['bounds']; edge = o['bar_edge']
                x = bounds['x'] + (bounds['width'] - o['bar_size'] if edge == 'right' else 0) + 4 + rect['x'] + rect['width']/2
                y = bounds['y'] + (bounds['height'] - o['bar_size'] if edge == 'bottom' else 0) + 4 + rect['y'] + rect['height']/2
                click(s, x, y, ipc.outputs())
            routes = dict(audio='sound', network='network', bluetooth='bluetooth', battery='power', control='overview')
            for edge in ('top', 'bottom', 'left', 'right'):
                prefs = copy.deepcopy(base)
                prefs['outputs'] = [dict(connector=output['connector'], bar=dict(edge=edge, size=48, groups=dict(left='launcher', center='clock', right=','.join(routes))))]
                apply(s, args.ctl, prefs); wait_for(lambda: current()['bar_edge'] == edge); time.sleep(.2)
                for item, page in routes.items():
                    ctl(s, args.ctl, 'popup', 'hide'); bar_click(item)
                    assert ready(page)['focus'] == 'heading'
                    assert_page(s, args.ctl, page)
                    capture(s, f'{edge}-{page}', output['connector'])
                    bar_click(item); eventually_status(s, args.ctl, lambda v: v['popup'] is None)
                bar_click('audio'); ready('sound')
                for item in ('network', 'bluetooth', 'battery'):
                    bar_click(item); ready(routes[item])
                ctl(s, args.ctl, 'popup', 'hide')
            checks['actual-service-icon-clicks-toggle-and-switch-on-all-four-edges'] = True
            checks['bar-retains-approved-no-keyboard-focus-policy'] = True
            if args.full_matrix:
                # Real pointer input also selects the originating second output.
                bar_click('network'); ready('network')
                other = next(o for o in status(s, args.ctl)['outputs'] if o['id'] != output['id'])
                bar_click('audio', other); ready('sound')
                assert status(s, args.ctl)['popup']['output'] == other['id']
                bar_click('bluetooth'); ready('bluetooth')
                assert status(s, args.ctl)['popup']['output'] == output['id']
                checks['pointer-routing-between-two-outputs-keeps-one-popup'] = True
                # Radios off remain on the requested page with honest state.
                ctl(s, args.ctl, 'control-center', 'show', '--output', output['id'], '--page', 'network'); ready('network')
                action(s, args.ctl, 'network', 'disable')
                await_state(s, args.ctl, lambda v: not v['network']['enabled'])
                assert 'Turn Wi-Fi on' in report(s, args.ctl)['labels']
                disabled = [n for n in inspect() if n['role'] == 'button' and n['name'] in ('Connect', 'Connect saved', 'Scan Wi-Fi')]
                assert disabled and all(not n['sensitive'] for n in disabled), disabled
                for verb, path in [('connect', AP), ('connect_saved', SP)]:
                    assert action(s, args.ctl, 'network', verb, path, code=4)['err']['code'] == 'Unavailable'
                capture(s, 'network-radio-off', output['connector'])
                action(s, args.ctl, 'network', 'enable')
                await_state(s, args.ctl, lambda v: v['network']['enabled'])
                bar_click('bluetooth'); ready('bluetooth')
                action(s, args.ctl, 'bluetooth', 'disable', BA)
                await_state(s, args.ctl, lambda v: not v['bluetooth']['pending'])
                await_state(s, args.ctl, lambda v: any(i['kind'] == 'adapter' and not i['powered'] for i in v['items']))
                disabled = [n for n in inspect() if n['role'] == 'button' and n['name'] in ('Pair…', 'Discover')]
                assert disabled and all(not n['sensitive'] for n in disabled), disabled
                assert action(s, args.ctl, 'bluetooth', 'pair', BD, code=4)['err']['code'] == 'Unavailable'
                capture(s, 'bluetooth-radio-off', output['connector'])
                action(s, args.ctl, 'bluetooth', 'enable', BA)
                await_state(s, args.ctl, lambda v: not v['bluetooth']['pending'])
                checks['radio-off-preserves-correct-destination'] = True
                for dismiss_outside in (False, True):
                    prefs = copy.deepcopy(base); prefs['popup']['dismiss_outside'] = dismiss_outside
                    apply(s, args.ctl, prefs)
                    ctl(s, args.ctl, 'control-center', 'show', '--output', output['id'], '--page', 'sound'); ready('sound')
                    o = current(); popup = status(s, args.ctl)['popup']
                    click(s, o['bounds']['x']+8, o['usable']['y']+8, ipc.outputs())
                    if dismiss_outside:
                        eventually_status(s, args.ctl, lambda v: v['popup'] is None)
                    else:
                        assert status(s, args.ctl)['popup'] == popup
                        s.run(['wtype', '-s', '100', '-k', 'Escape', '-s', '100'])
                        eventually_status(s, args.ctl, lambda v: v['popup'] is None)
                checks['permitted-backdrop-and-keyboard-close-dismissal'] = True
                # Restore both service bars for the accessibility assertions.
                apply(s, args.ctl, prefs | {'outputs': [dict(connector=output['connector'], bar=dict(edge='top', size=48, groups=dict(left='launcher', center='clock', right=','.join(routes))))]})
                time.sleep(.2)
            nodes = inspect()
            (args.output/'all-accessibility.json').write_text(s.run(['python3', ROOT/'tests/fixtures/inspect_accessibility.py', '--all']).stdout)
            for name in ('Sound', 'Network', 'Bluetooth', 'Power'):
                matches = [n for n in nodes if n['name'] == f'Open {name} controls']
                assert matches and all(n['description'] for n in matches), (name, nodes)
            assert any(n['name'] == 'Open settings Overview' for n in nodes)
            (args.output/'bar-accessibility.json').write_text(json.dumps(nodes, indent=2)+'\n')
            checks['accessible-service-actions-retain-status-descriptions'] = True
            trees = {}
            for page in PAGES:
                ctl(s, args.ctl, 'control-center', 'show', '--page', page); ready(page)
                nodes = inspect(); trees[page] = nodes
                assert any(n['name'] == TITLES[page] and n['role'] == 'heading' for n in nodes), nodes
                forbidden = {'Workspace layout', 'Adapters, nearby and saved networks', 'Adapters and devices', 'Output, input and applications', 'Power and brightness'}
                own = dict(overview='Workspace layout', network='Adapters, nearby and saved networks', bluetooth='Adapters and devices', sound='Output, input and applications', power='Power and brightness')[page]
                assert not {n['name'] for n in nodes}.intersection(forbidden-{own}), (page, nodes)
                choose_page(s, args.ctl, PAGES[(PAGES.index(page)+1)%len(PAGES)])
            (args.output/'page-accessibility.json').write_text(json.dumps(trees, indent=2)+'\n')
            for title in TITLES.values():
                wait_for(lambda: any(json.loads(line).get('message') == title for line in listener.lines if line.startswith('{')))
            checks['selected-page-heading-announced-through-atspi-hidden-pages-absent'] = True
            # F5 adds every edge/scale combination at normal and maximum text size.
            custom = Path(s.env['XDG_DATA_HOME'])/'themes/Pearl-Settings-Test/gtk-4.0'
            custom.mkdir(parents=True)
            (custom/'gtk.css').write_text('.background {background:#203040;color:#ffffff;} button {background:#304050;color:#ffffff;}')
            layouts = []
            cases = [('static','dark',14,1,'top'), ('static','light',24,1.25,'left'), ('gtk','dark',24,1.5,'right'), ('static','dark',24,2,'bottom')]
            if args.full_matrix:
                cases += [('static','dark',font,scale,edge) for font in (14,24) for scale in (1,1.25,1.5,2) for edge in ('top','bottom','left','right') if ('static','dark',font,scale,edge) not in cases]
                # Rotating the physical output produces a genuinely narrow host.
                cases = [('static','light',24,2,'portrait-left'), *cases]
            for theme, variant, font, scale, edge in cases:
                ctl(s, args.ctl, 'popup', 'hide')
                portrait = edge.startswith('portrait-')
                s.run(['wlr-randr', '--output', output['connector'], '--transform', '90' if portrait else 'normal'])
                prefs = copy.deepcopy(base)
                prefs['theme'].update(mode=theme, variant=variant, gtk_name='Pearl-Settings-Test')
                prefs.update(font_size=font, reduced_motion=True)
                prefs['outputs'] = [dict(connector=output['connector'], bar=dict(edge=edge.removeprefix('portrait-'), size=64, groups=dict(left='launcher', center='', right='control')))]
                apply(s, args.ctl, prefs)
                s.run(['wlr-randr', '--output', output['connector'], '--scale', str(scale)])
                wait_for(lambda: current()['scale'] == scale); time.sleep(.2)
                for page in PAGES:
                    ctl(s, args.ctl, 'control-center', 'show', '--output', output['id'], '--page', page); r = ready(page)
                    popup = status(s, args.ctl)['popup']; bounds = current()['bounds']
                    assert r['body_height'] > 0 and r['body_width'] <= popup['rect']['width'], (r, popup)
                    assert r['panel_width'] <= popup['rect']['width'] and r['panel_height'] <= popup['rect']['height'], (r, popup)
                    assert popup['rect']['width'] <= bounds['width'] and popup['rect']['height'] <= bounds['height'], (popup, bounds)
                    choose_page(s, args.ctl, page)
                    layouts.append(dict(theme=theme, variant=variant, font=font, scale=scale, edge=edge, page=page, report=r, popup=popup))
                    suffix = '-'+edge if args.full_matrix else ''
                    capture(s, f'{theme}-{variant}-{font}-{scale}-{page}{suffix}', output['connector'])
                    if font == 24 and page in ('network', 'power'):
                        target = 'Connect saved' if page == 'network' else 'Restart…'
                        for _ in range(50):
                            if report(s, args.ctl)['button'] == target: break
                            s.run(['wtype', '-s', '50', '-k', 'Tab', '-s', '50'])
                        else: raise AssertionError(('Large-text control unreachable', page, target))
                        capture(s, f'{theme}-{variant}-{font}-{scale}-{page}{suffix}-scrolled', output['connector'])
                s.run(['wtype', '-s', '100', '-k', 'Escape', '-s', '100'])
                eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            (args.output/'presentation.json').write_text(json.dumps(layouts, indent=2)+'\n')
            checks['dark-light-native-large-text-reduced-motion-and-scaled-output-navigation'] = True
            ipc.close(); ctl(s, args.ctl, 'quit'); clean(app)
        result['status'] = 'passed'
    except Exception as error:
        result.update(status='failed', error=str(error)); raise
    finally:
        (args.output/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))

if __name__ == '__main__': main()
