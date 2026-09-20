#!/usr/bin/env python3
"""T05 surfaces/control/native blur on private Aqueous displays and buses."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from PIL import Image, ImageChops, ImageStat


class IPC:
    def __init__(self, session):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(4)
        self.sock.connect(session.env['AQUEOUS_SOCKET'])
        self.file = self.sock.makefile('r')
        self.serial = 0
        self.session = None
        self.session = self.call('hello')['session']

    def call(self, op, **params):
        self.serial += 1
        req = dict(ipc=1, id=str(self.serial), op=op, params=params)
        if self.session:
            req['session'] = self.session
        self.sock.sendall(json.dumps(req).encode() + b'\n')
        result = json.loads(self.file.readline())
        assert result['ok'], result
        return result['result']

    def state(self):
        return self.call('snapshot')['batch']['upsert']

    def outputs(self):
        return {e['id']: e for e in self.state() if e['kind'] == 'output' and e['enabled'] and e['powered']}

    def close(self):
        self.file.close()
        self.sock.close()


def ctl(session, binary, *args, code=0, **env):
    result = session.run([binary, *args], check=False, **env)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout) if result.stdout else None


def status(session, binary):
    return ctl(session, binary, 'status')['result']


def eventually_status(session, binary, predicate):
    def check():
        result = session.run([binary, 'status'], check=False)
        if result.returncode != 0:
            return False
        value = json.loads(result.stdout)['result']
        return value if predicate(value) else False
    return wait_for(check)


def click(session, x, y, outputs):
    left = min(o['bounds']['x'] for o in outputs.values())
    top = min(o['bounds']['y'] for o in outputs.values())
    session.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
    session.run(['wlrctl', 'pointer', 'move', str(x-left), str(y-top)])
    time.sleep(.1)
    session.run(['wlrctl', 'pointer', 'click'])
    time.sleep(.15)


def clean(child):
    assert child.wait() == 0, child.lines[-20:]
    assert not any(word in line for line in child.lines for word in ('CRITICAL', 'WARNING', 'panic:', 'event=css-error', 'protocol error')), child.lines[-30:]


def capture(session, name, output=None):
    path = session.output / f'{name}.png'
    for _ in range(3):
        session.run(['grim', *(['-o', output] if output else []), path])
    return Image.open(path).convert('RGB')


def basic(args, checks):
    with PrivateSession(args.output / 'surfaces') as s:
        ipc = IPC(s)
        try:
            before = ipc.outputs()
            right = list(before.values())[1]
            s.run(['wlr-randr', '--output', right['name'], '--scale', '1.5', '--pos', '-854,0'])
            wait_for(lambda: any(o['scale'] == 1.5 for o in ipc.outputs().values()))
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings', WAYLAND_DEBUG='client')
            app.expect('event=control-ready')
            live = eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 2 and all(o['bar_size'] >= 48 and o['usable']['height'] == o['bounds']['height'] - o['bar_size'] for o in v['outputs']))
            assert {o['connector'] for o in live['outputs']} == {o['name'] for o in ipc.outputs().values()}
            assert not live['blur']
            assert sorted(o['scale'] for o in live['outputs']) == [1, 1.5]
            checks['mixed-scale-negative-origin-mapping-and-single-reservation'] = True
            capture(s, 'two-outputs')

            duplicate = s.child('duplicate', [args.pearl], G_DEBUG='fatal-warnings')
            duplicate.expect('error=AlreadyRunning')
            assert duplicate.wait() == 1
            assert status(s, args.ctl)['availability'] == 'ready'
            checks['instance-lock-preserves-running-server'] = True

            target = next(o for o in live['outputs'] if o['scale'] == 1)
            tid = target['id']
            ctl(s, args.ctl, 'bar', 'set', '--output', tid, '--edge', 'bottom', '--size', '64')
            ctl(s, args.ctl, 'frame', 'set', '--output', tid, '--edge', 'top', '--size', '8')
            reply = ctl(s, args.ctl, 'frame', 'set', '--output', tid, '--edge', 'bottom', '--size', '8', code=4)
            assert reply['err']['code'] == 'EdgeOccupied'
            live = eventually_status(s, args.ctl, lambda v: next(o for o in v['outputs'] if o['id'] == tid)['usable']['height'] == target['bounds']['height'] - 72)
            checks['bar-move-frame-exclusion-and-conflict'] = True

            ctl(s, args.ctl, 'popup', 'show', '--output', tid)
            wait_for(lambda: any(e['kind'] == 'seat' and e['focus_kind'] == 'layer_surface' for e in ipc.state()))
            pop = status(s, args.ctl)['popup']
            o = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == tid)
            r = pop['rect']
            assert r['x'] + o['bounds']['x'] >= o['usable']['x'] and r['y'] + o['bounds']['y'] >= o['usable']['y']
            assert r['y'] + o['bounds']['y'] + r['height'] <= o['usable']['y'] + o['usable']['height']
            s.run(['wtype', '-s', '100', '-k', 'Escape', '-s', '100'])
            eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            ctl(s, args.ctl, 'popup', 'show', '--output', tid)
            other = next(o for o in live['outputs'] if o['id'] != tid)
            ctl(s, args.ctl, 'popup', 'show', '--output', other['id'])
            assert status(s, args.ctl)['popup']['output'] == other['id']
            ctl(s, args.ctl, 'popup', 'toggle', '--output', other['id'])
            assert status(s, args.ctl)['popup'] is None
            checks['popup-clamping-keyboard-escape-and-arbitration'] = True

            # Existing independent GTK fixture: one large normal-window button.
            plain = s.child('underlying', [args.spike], input_pipe=True, PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', PEARL_T00_MODE='plain')
            plain.expect('event=ready mode=plain')
            window = wait_for(lambda: next((e for e in ipc.state() if e['kind'] == 'window'), None))
            ipc.call('command', action='window.maximized', fields=dict(id=window['id'], value=True))
            ipc.call('command', action='window.activate', fields=dict(id=window['id']))
            output = ipc.outputs()[window['output']]
            tid = output['id']
            time.sleep(.3)
            u = output['usable_bounds']
            x, y = u['x'] + u['width']//2, u['y'] + u['height'] - 60
            seat = next(e for e in ipc.state() if e['kind'] == 'seat')
            ctl(s, args.ctl, 'osd', 'show', '--output', tid, '--text', 'Sound muted', '--duration', '1500')
            time.sleep(.2)
            after = next(e for e in ipc.state() if e['kind'] == 'seat')
            assert (after['focus_kind'], after['window']) == (seat['focus_kind'], seat['window'])
            click(s, x, y, ipc.outputs())
            plain.expect('event=underlying-click')
            checks['osd-does-not-steal-focus-and-is-click-through'] = True
            eventually_status(s, args.ctl, lambda v: not v['osd'])

            ctl(s, args.ctl, 'popup', 'show', '--output', tid)
            time.sleep(.15)
            count = sum('event=underlying-click' in x for x in plain.lines)
            x, y = u['x'] + 25, u['y'] + 85
            click(s, x, y, ipc.outputs())
            eventually_status(s, args.ctl, lambda v: v['popup'] is None)
            assert sum('event=underlying-click' in x for x in plain.lines) == count
            click(s, x, y, ipc.outputs())
            wait_for(lambda: sum('event=underlying-click' in x for x in plain.lines) > count)
            checks['outside-click-dismissal-does-not-leak-and-frame-interior-passes-input'] = True
            plain.proc.stdin.write('quit\n'); plain.proc.stdin.flush(); clean(plain)

            from test_preferences import apply, settled
            ctl(s, args.ctl, 'frame', 'set', '--output', target['id'], '--edge', 'top', '--size', '0')
            saved_preferences = settled(s, args.ctl)['preferences']
            hotplug_preferences = json.loads(json.dumps(saved_preferences))
            hotplug_preferences['wallpaper'].update(mode='solid', color='#e08020')
            hotplug_preferences['outputs'] = [dict(connector=other['connector'], bar=dict(edge='top', size=48, islands=False, background_opacity=dict(mode='custom', percent=50)))]
            apply(s, args.ctl, hotplug_preferences)
            time.sleep(.2)
            sample = (int(7*other['scale']), int(24*other['scale']))
            opacity_before = capture(s, 'bar-opacity-before-hotplug', other['connector']).getpixel(sample)
            ctl(s, args.ctl, 'popup', 'show', '--output', other['id'])
            s.run(['wlr-randr', '--output', other['connector'], '--off'])
            eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 1 and v['popup'] is None)
            s.run(['wlr-randr', '--output', other['connector'], '--on'])
            eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 2)
            time.sleep(.2)
            opacity_after = capture(s, 'bar-opacity-after-hotplug', other['connector']).getpixel(sample)
            assert max(abs(a-b) for a,b in zip(opacity_before, opacity_after)) <= 3, (opacity_before, opacity_after)
            assert opacity_after != (224,128,32), opacity_after
            checks['custom-bar-opacity-restored-after-output-hotplug'] = True
            apply(s, args.ctl, saved_preferences)
            checks['hotplug-invalidates-mapping-and-dismisses-target-popup'] = True
            s.run(['wlr-randr', '--output', other['connector'], '--transform', '90'])
            rotated = eventually_status(s, args.ctl, lambda v: next(o for o in v['outputs'] if o['connector'] == other['connector'])['bounds']['height'] > 700)
            target_rotated = next(o for o in rotated['outputs'] if o['connector'] == other['connector'])
            ctl(s, args.ctl, 'popup', 'show', '--output', target_rotated['id'])
            pop = status(s, args.ctl)['popup']['rect']
            assert pop['x'] >= 0 and pop['x'] + pop['width'] <= target_rotated['bounds']['width']
            capture(s, 'rotated-popup')
            ctl(s, args.ctl, 'popup', 'hide')
            checks['rotated-output-popup-clamping'] = True

            time.sleep(.4)
            def ticks():
                fields = Path(f'/proc/{app.proc.pid}/stat').read_text().split()
                return int(fields[13]) + int(fields[14])
            start = ticks(); time.sleep(1.5); delta = ticks() - start
            assert delta <= 3, f'non-idle frame loop: {delta} CPU ticks'
            checks['idle-cpu-ticks-over-1.5s'] = delta
            capture(s, 'final-surfaces')
            app.signal(signal.SIGKILL)
            assert app.wait() == -signal.SIGKILL
            wait_for(lambda: all(o['usable_bounds'] == o['bounds'] for o in ipc.outputs().values()))
            checks['kill-restores-usable-bounds'] = True
            restarted = s.child('restarted', [args.pearl], G_DEBUG='fatal-warnings')
            restarted.expect('event=control-ready')
            eventually_status(s, args.ctl, lambda v: len(v['outputs']) == 2)
            ctl(s, args.ctl, 'quit'); clean(restarted)
            wait_for(lambda: all(o['usable_bounds'] == o['bounds'] for o in ipc.outputs().values()))
            checks['stale-socket-recovery-and-graceful-reservation-removal'] = True
        finally:
            ipc.close()


def isolation(args, checks):
    with PrivateSession(args.output / 'isolation-parent') as parent:
        app = parent.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
        app.expect('event=control-ready')
        parent_state = eventually_status(parent, args.ctl, lambda v: len(v['outputs']) == 2)
        with PrivateSession(args.output / 'isolation-nested', backend='nested', parent_display=parent.display_path, inherited=parent.env) as nested:
            child = nested.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            child.expect('event=control-ready')
            nested_state = eventually_status(nested, args.ctl, lambda v: len(v['outputs']) == 1)
            assert nested_state['session'] != parent_state['session']
            ctl(nested, args.ctl, 'popup', 'show', AQUEOUS_SOCKET=parent.env['AQUEOUS_SOCKET'], code=3)
            rejected = ctl(nested, args.ctl, 'popup', 'show', AQUEOUS_SOCKET=parent.env['AQUEOUS_SOCKET'], XDG_RUNTIME_DIR=parent.env['XDG_RUNTIME_DIR'], WAYLAND_DISPLAY=str(nested.display_path), code=4)
            assert rejected['err']['code'] == 'DisplayMismatch'
            assert status(parent, args.ctl)['popup'] is None
            wrong = nested.child('wrong-native-display', [args.pearl], G_DEBUG='fatal-warnings', AQUEOUS_SOCKET=parent.env['AQUEOUS_SOCKET'], XDG_RUNTIME_DIR=parent.env['XDG_RUNTIME_DIR'], WAYLAND_DISPLAY=str(nested.display_path))
            wrong.expect('error=SessionDisplayMismatch')
            assert wrong.wait() == 1
            checks['native-wayland-session-matches-ipc-before-surfaces-or-control'] = True
            sock = socket.socket(socket.AF_UNIX)
            endpoint = Path(nested.env['XDG_RUNTIME_DIR']) / 'pearl' / nested_state['session'] / 'control.sock'
            assert endpoint.parent.stat().st_mode & 0o077 == 0
            sock.connect(str(endpoint))
            req = dict(pearl=1, id='7', session='a'*32, display=str(nested.display_path), op='popup_show')
            sock.sendall(json.dumps(req).encode()+b'\n')
            response = json.loads(sock.makefile().readline())
            assert response['id'] == '7' and response['err']['code'] == 'StaleSession'
            sock.close()
            def raw(payload):
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.settimeout(7)
                    peer.connect(str(endpoint))
                    peer.sendall(payload)
                    return json.loads(peer.makefile().readline())
            valid = dict(pearl=1, id='8', session=nested_state['session'], display=str(nested.display_path), op='status')
            for update, expected in ((dict(pearl=2), 'Version'), (dict(extra=dict(nested=True)), 'InvalidRequest'), (dict(pearl='1'), 'InvalidRequest')):
                reply = raw(json.dumps(dict(valid, **update)).encode()+b'\n')
                assert reply['id'] == '0' and reply['err']['code'] == expected, reply
            # Partial requests consume a bounded slot and expire without a newline.
            peers = []
            try:
                for _ in range(8):
                    peer = socket.socket(socket.AF_UNIX)
                    peers.append(peer)
                    peer.settimeout(7)
                    peer.connect(str(endpoint))
                    peer.sendall(b'{')
                time.sleep(.1)
                with socket.socket(socket.AF_UNIX) as excess:
                    excess.settimeout(2)
                    excess.connect(str(endpoint))
                    assert excess.recv(1) == b''
                for peer in peers:
                    assert peer.recv(1) == b''
            finally:
                for peer in peers:
                    peer.close()
            with socket.socket(socket.AF_UNIX) as peer:
                peer.settimeout(2)
                peer.connect(str(endpoint))
                peer.sendall(b' ' * 8193 + b'\n')
                try:
                    assert peer.recv(1) == b''
                except ConnectionResetError:
                    pass
            assert raw(json.dumps(valid).encode()+b'\n')['ok']
            checks['control-schema-frame-limit-eight-client-bound-and-partial-request-deadline'] = True
            ctl(nested, args.ctl, 'quit'); clean(child)
        ctl(parent, args.ctl, 'quit'); clean(app)
    checks['private-nested-stale-session-and-cross-display-cli-isolation'] = True


def blur(args, checks):
    with PrivateSession(args.output / 'blur', aqueous=args.effects_aqueous, renderer='vulkan', wm_extra='[blur]\nenabled = true\nradius = 8\npasses = 2\n') as s:
        gallery = s.child('gallery', [args.pearl, '--demo'], G_DEBUG='fatal-warnings')
        gallery.expect('event=work-finished applied=true')
        app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings', WAYLAND_DEBUG='client')
        app.expect('event=control-ready')
        live = eventually_status(s, args.ctl, lambda v: v['blur'] and len(v['outputs']) == 2)
        ipc = IPC(s)
        window = next(e for e in ipc.state() if e['kind'] == 'window')
        target = next(o for o in live['outputs'] if o['id'] == window['output'])
        ctl(s, args.ctl, 'popup', 'show', '--output', target['id'])
        time.sleep(.3)
        enabled = capture(s, 'native-blur', target['connector'])
        # Aqueous now reaches Pearl's notification daemon on each config reload.
        # Suppress those toasts so this experiment measures only the blur rule.
        ctl(s, args.ctl, 'session', 'action', '--command', 'dnd_on')
        rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
        original = rules.read_text() if rules.exists() else ''
        reloads = sum('configuration hot-reloaded' in line for line in s.compositor.lines)
        rules.write_text('[[layer]]\nnamespace = "pearl:popup"\nblur = false\n')
        wait_for(lambda: sum('configuration hot-reloaded' in line for line in s.compositor.lines) > reloads)
        denied = capture(s, 'rule-veto', target['connector'])
        r = status(s, args.ctl)['popup']['rect']
        box = (r['x']+24, r['y']+24, r['x']+r['width']-24, r['y']+r['height']-24)
        diff = sum(ImageStat.Stat(ImageChops.difference(enabled.crop(box), denied.crop(box))).mean)/3
        assert diff > .08, ('native blur or veto had no pixel effect', diff)
        reloads = sum('configuration hot-reloaded' in line for line in s.compositor.lines)
        rules.write_text(original)
        wait_for(lambda: sum('configuration hot-reloaded' in line for line in s.compositor.lines) > reloads)
        allowed = capture(s, 'rule-restored', target['connector'])
        restored = sum(ImageStat.Stat(ImageChops.difference(enabled.crop(box), allowed.crop(box))).mean)/3
        assert restored < diff / 2, (diff, restored)
        checks['native-blur-pixel-difference-under-rule-veto'] = diff
        checks['rule-restored-pixel-difference'] = restored
        from test_preferences import apply, settled
        import copy
        saved_preferences = settled(s, args.ctl)['preferences']
        opacity_preferences = copy.deepcopy(saved_preferences)
        opacity_preferences['bar'].update(islands=False, background_opacity=dict(mode='custom', percent=50))
        opacity_preferences['outputs'] = []
        opacity_preferences['wallpaper'].update(mode='solid', color='#e08020')
        apply(s, args.ctl, opacity_preferences)
        time.sleep(.2)
        custom_blur = capture(s, 'bar-opacity-with-blur', target['connector']).getpixel((7,24))
        config = Path(s.env['AQUEOUS_CONFIG'])
        text = config.read_text()
        config.write_text(text.replace('[blur]\nenabled = true', '[blur]\nenabled = false'))
        eventually_status(s, args.ctl, lambda v: not v['blur'])
        time.sleep(.2)
        custom_plain = capture(s, 'bar-opacity-without-blur', target['connector']).getpixel((7,24))
        assert max(abs(a-b) for a,b in zip(custom_blur, custom_plain)) <= 3, (custom_blur, custom_plain)
        assert custom_plain != (224,128,32), custom_plain
        checks['custom-bar-opacity-survives-blur-capability-change'] = True
        apply(s, args.ctl, saved_preferences)
        capture(s, 'opaque-fallback', target['connector'])
        config.write_text(text)
        eventually_status(s, args.ctl, lambda v: v['blur'])
        for _ in range(3):
            ctl(s, args.ctl, 'popup', 'hide')
            ctl(s, args.ctl, 'popup', 'show', '--output', target['id'])
            time.sleep(.1)
        ctl(s, args.ctl, 'bar', 'set', '--output', target['id'], '--edge', 'top', '--size', '80')
        time.sleep(.3)
        capture(s, 'resized-remapped', target['connector'])
        ctl(s, args.ctl, 'popup', 'hide')
        ctl(s, args.ctl, 'quit'); clean(app)
        gallery.signal(); clean(gallery)
        ipc.close()
        trace = '\n'.join(app.lines)
        effects = re.findall(r'get_background_effect\(new id ext_background_effect_surface_v1#(\d+), wl_surface#(\d+)\)', trace)
        assert len(effects) >= 6, effects
        for effect, surface in effects:
            assert f'wl_surface#{surface}.attach(' in trace, 'effect was not attached to a GTK-rendered surface'
            assert f'ext_background_effect_surface_v1#{effect}.destroy()' in trace
        assert 'capabilities(0)' in trace and 'capabilities(1)' in trace
        assert '.set_blur_region(nil)' in trace
        checks['gtk-owned-surface-native-protocol-capability-resize-remap-lifecycle'] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--spike', type=Path, required=True)
    parser.add_argument('--effects-aqueous', type=Path, default=Path(os.environ.get('PEARL_TEST_AQUEOUS_PREFIX', ROOT / '.cache/aqueous-effects')) / 'bin/aqueous')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/t05/latest')
    args = parser.parse_args()
    for name in ('pearl','ctl','spike','effects_aqueous','output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', checks=checks, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest(), effects_aqueous_sha256=hashlib.sha256(args.effects_aqueous.read_bytes()).hexdigest())
    try:
        basic(args, checks)
        print('PASS surfaces, reservations, input and hotplug', flush=True)
        isolation(args, checks)
        print('PASS CLI isolation', flush=True)
        blur(args, checks)
        print('PASS native GTK blur', flush=True)
        result['status'] = 'passed'
    finally:
        (args.output / 'results.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
