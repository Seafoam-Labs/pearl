#!/usr/bin/env python3
"""T00 proof on a private headless Aqueous display and private D-Bus session."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def wait(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError('condition timed out')


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class IPC:
    def __init__(self, endpoint):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(str(endpoint))
        self.buffer = b''
        self.counter = 0
        self.session = None
        self.hello = self.call('hello')['result']
        self.session = self.hello['session']

    def receive(self):
        while b'\n' not in self.buffer:
            block = self.sock.recv(65536)
            if not block:
                raise EOFError('Aqueous IPC disconnected')
            self.buffer += block
            if len(self.buffer) > 4259840 + 65536:
                raise ValueError('oversized frame')
        line, self.buffer = self.buffer.split(b'\n', 1)
        assert len(line) <= 4259840
        return json.loads(line)

    def call(self, operation, params=None):
        self.counter += 1
        request = dict(ipc=1, id=str(self.counter), op=operation, params=params or {})
        if self.session:
            request['session'] = self.session
        self.sock.sendall(json.dumps(request).encode() + b'\n')
        reply = self.receive()
        assert reply.get('id') == request['id'] and reply.get('ok'), reply
        return reply

    def snapshot(self):
        return self.call('snapshot')['result']['batch']


class Child:
    def __init__(self, argv, environment, logfile):
        self.lines = []
        self.proc = subprocess.Popen(argv, env=environment, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, start_new_session=True, bufsize=1)
        self.log = logfile.open('w')
        def collect():
            for line in self.proc.stdout:
                if len(self.lines) < 20000:
                    self.lines.append(line.rstrip())
                    self.log.write(line)
                    self.log.flush()
            self.log.close()
        self.thread = threading.Thread(target=collect, daemon=True)
        self.thread.start()

    def seen(self, text):
        return any(text in line for line in self.lines)

    def expect(self, text, timeout=8):
        def check():
            if self.seen(text):
                return True
            if self.proc.poll() is not None:
                raise AssertionError('\n'.join(self.lines[-25:]))
        wait(check, timeout)

    def command(self, text):
        self.proc.stdin.write(text + '\n')
        self.proc.stdin.flush()

    def stop(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=4)
        self.thread.join(timeout=2)


class Session:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.children = []
        self.env = dict(os.environ)
        self.runtime = Path(self.env['XDG_RUNTIME_DIR'])
        assert self.env.get('PEARL_T00_ISOLATED') == '1'
        assert 'pearl-t00-' in str(self.runtime) and self.runtime.stat().st_mode & 0o777 == 0o700
        self.results = {}

    def child(self, name, argv, **environment):
        child = Child(argv, dict(self.env, **environment), self.output / f'{name}.log')
        self.children.append(child)
        return child

    def run(self, argv, timeout=10, check=True):
        return subprocess.run([str(x) for x in argv], env=self.env, capture_output=True, text=True, timeout=timeout, check=check)

    def capture(self, name):
        self.run(['grim', '-o', self.outputs[0]['name'], str(self.output / f'{name}.png')])

    def outputs_now(self):
        return [e for e in self.ipc.snapshot()['upsert'] if e['kind'] == 'output']

    def click(self, x, y):
        # Saturate at the top-left before using a relative test pointer move.
        self.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
        self.run(['wlrctl', 'pointer', 'move', str(x), str(y)])
        self.run(['wlrctl', 'pointer', 'click'])
        time.sleep(.1)

    def start(self):
        wm = Path(self.env['XDG_CONFIG_HOME']) / 'aqueous/wm.toml'
        wm.parent.mkdir(parents=True, exist_ok=True)
        wm.write_text('[layout]\ndefault = "monocle"\ngaps_outer = 0\ngaps_inner = 0\n[struts]\ntop = 0\nbottom = 0\nleft = 0\nright = 0\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\nfocus_new_windows = true\n')
        self.env['AQUEOUS_CONFIG'] = str(wm)
        marker = 'printenv WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/display"; printenv AQUEOUS_SOCKET > "$XDG_RUNTIME_DIR/endpoint"'
        compositor = self.child('compositor', [self.args.aqueous, '-no-xwayland', '-c', marker])
        def ready():
            if compositor.proc.poll() is not None:
                raise AssertionError('\n'.join(compositor.lines[-25:]))
            p = self.runtime / 'endpoint'
            return p.exists() and p.read_text().strip()
        endpoint = wait(ready, 15)
        assert Path(endpoint).is_relative_to(self.runtime)
        self.env['AQUEOUS_SOCKET'] = endpoint
        self.env['WAYLAND_DISPLAY'] = (self.runtime / 'display').read_text().strip()
        assert (self.runtime / self.env['WAYLAND_DISPLAY']).is_socket()
        self.ipc = IPC(endpoint)
        self.events = IPC(endpoint)
        assert self.ipc.session == self.events.session
        self.events.call('subscribe')
        initial = self.events.receive()
        self.events.call('ack', dict(delivery=initial['delivery']))
        self.outputs = self.outputs_now()
        assert len(self.outputs) == 2
        save(self.output / 'hello.json', self.ipc.hello)
        save(self.output / 'snapshot.json', initial)
        (self.output / 'wayland-info.txt').write_text(self.run(['wayland-info']).stdout)
        save(self.output / 'outputs.json', json.loads(self.run([self.args.ctl, 'outputs', '--json']).stdout))
        self.results['two_connection_handshake_subscription_ack'] = 'pass'
        self.results['reload'] = self.ipc.call('command', dict(action='session.reload', fields={}))
        name = self.outputs[0]['name']
        before = json.loads(self.run([self.args.ctl, 'layout', '--output', name, '--json']).stdout)
        changed = json.loads(self.run([self.args.ctl, 'layout', '--output', name, '--set', 'grid', '--json']).stdout)
        self.run([self.args.ctl, 'layout', '--output', name, '--set', 'monocle', '--json'])
        save(self.output / 'layout.json', dict(before=before, changed=changed))
        for op in ('version', 'snapshot'):
            response = self.run(['aqueous-config', op, '--shell', 'none'], check=False)
            (self.output / f'config-{op}.json').write_text(response.stdout)
            (self.output / f'config-{op}.stderr').write_text(response.stderr)
            self.results[f'config_{op}_exit'] = response.returncode
        self.results['private_session_services'] = self.run(['busctl', '--address=' + self.env['DBUS_SESSION_BUS_ADDRESS'], '--no-pager', 'list'], check=False).stdout

    def test_spike(self):
        keyboard = self.input_fixture()
        initial = {o['id']: o['usable_bounds'] for o in self.outputs_now()}
        plain = self.child('normal-window', [str(ROOT / 'zig-out/bin/pearl-t00')], PEARL_T00_MODE='plain')
        plain.expect('event=ready mode=plain')
        wait(lambda: any(e['kind'] == 'window' for e in self.ipc.snapshot()['upsert']))
        self.capture('gtk-normal-window')
        start = time.monotonic()
        bars = self.child('bars', [str(ROOT / 'zig-out/bin/pearl-t00')])
        bars.expect('event=ready mode=bars')
        wait(lambda: all(o['usable_bounds']['height'] == initial[o['id']]['height'] - 48 for o in self.outputs_now()))
        self.results['bar_ready_ms'] = round((time.monotonic() - start) * 1000, 2)
        self.results['exclusive_zones'] = dict(before=initial, during={o['id']: o['usable_bounds'] for o in self.outputs_now()})
        observed = [line for line in bars.lines if line.startswith('T00 monitor=')]
        assert {re.search(r'monitor=(\S+)', line)[1] for line in observed} == {o['name'] for o in self.outputs}
        self.results['monitor_mapping'] = observed
        self.capture('gtk-bars')
        self.click(80, 24)
        bars.expect('event=popup-opened')
        wait(lambda: any(e['kind'] == 'seat' and e.get('focus_kind') == 'layer_surface' for e in self.ipc.snapshot()['upsert']))
        for code in (30, 16, 22, 18, 24, 22, 31):
            keyboard.command(f'chord {code} 0')
            time.sleep(.05)
        bars.expect('event=entry text=aqueous')
        self.capture('gtk-popup')
        keyboard.command('chord 1 0')
        bars.expect('reason=escape')
        bars.command('popup')
        time.sleep(.3)
        clicks = sum('event=underlying-click' in x for x in plain.lines)
        self.click(40, 110)
        bars.expect('reason=outside-click')
        assert sum('event=underlying-click' in x for x in plain.lines) == clicks, 'dismissal click leaked to underlying window'
        self.click(40, 110)
        plain.expect('event=underlying-click')
        self.results['popup_keyboard_escape_outside_click_no_leak'] = 'pass'
        bars.command('lock')
        bars.expect('event=locked')
        wait(lambda: sum('event=lock-monitor' in x for x in bars.lines) == 2)
        assert any(e['kind'] == 'session' and e['locked'] for e in self.ipc.snapshot()['upsert'])
        # Lock acquisition is verified through its signal and compositor state.
        bars.command('unlock')
        bars.expect('event=unlocked')
        wait(lambda: any(e['kind'] == 'session' and not e['locked'] for e in self.ipc.snapshot()['upsert']))
        self.results['generated_session_lock_signals_two_outputs'] = 'pass (test-only lock, no authentication)'
        self.measure_idle(bars)
        bars.command('quit')
        assert bars.proc.wait(timeout=5) == 0
        wait(lambda: all(o['usable_bounds'] == initial[o['id']] for o in self.outputs_now()))
        self.results['exclusive_zones']['after'] = {o['id']: o['usable_bounds'] for o in self.outputs_now()}
        self.capture('gtk-after-unmap')
        plain.command('quit')
        assert plain.proc.wait(timeout=5) == 0
        self.results['normal_window_and_graceful_teardown'] = 'pass'

    def input_fixture(self):
        # Reuse Aqueous's existing test client as a persistent virtual keyboard.
        # It is an external test executable, never linked into Pearl.
        source = Path(self.args.aqueous_source) / 'compositor'
        build = self.runtime / 'input-fixture'
        build.mkdir()
        protocols = {
            'xdg-shell': '/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml',
            'xdg-activation': '/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml',
            'shortcuts': '/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
            'virtual-keyboard': source / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'layer-shell': source / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'session-lock': '/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',
            'aqueous-shell': source / 'protocol/aqueous-shell-v1.xml',
            'ext-workspace': source / 'protocol/upstream/ext-workspace-v1.xml',
            'pointer-constraints': '/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
        }
        generated = []
        for name, xml in protocols.items():
            self.run(['wayland-scanner', 'client-header', xml, build / (name + '-client-protocol.h')])
            code = build / (name + '.c')
            self.run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        executable = build / 'input'
        self.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(build), source / 'scripts/fixtures/shell-client.c',
                  *generated, '-lwayland-client', '-lxkbcommon', '-o', executable])
        child = self.child('input', [str(executable), 'input'])
        child.expect('ready')
        return child

    def measure_idle(self, child):
        pid = child.proc.pid
        def ticks():
            parts = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            return int(parts[11]) + int(parts[12])
        start_ticks = ticks()
        start = time.monotonic()
        time.sleep(self.args.idle_seconds)
        duration = time.monotonic() - start
        cpu = (ticks() - start_ticks) / os.sysconf('SC_CLK_TCK') / duration * 100
        memory = Path(f'/proc/{pid}/smaps_rollup').read_text()
        self.results['spike_idle_baseline'] = dict(seconds=round(duration, 2), cpu_percent_one_core=round(cpu, 3),
            pss_kib=int(re.search(r'^Pss:\s+(\d+)', memory, re.M)[1]), renderer=self.env['GSK_RENDERER'], compositor_renderer=self.env['WLR_RENDERER'])

    def references(self):
        settings = Path(self.env['XDG_CONFIG_HOME']) / 'DankMaterialShell/settings.json'
        settings.parent.mkdir(parents=True)
        save(settings, dict(currentThemeName='purple', showDock=True, dockAutoHide=False,
                            weatherEnabled=False, useAutoLocation=False, enableWelcomeScreen=False))
        state = Path(self.env['XDG_STATE_HOME']) / 'DankMaterialShell/session.json'
        state.parent.mkdir(parents=True)
        save(state, dict(pinnedApps=['pearl-fixture-terminal', 'pearl-fixture-files', 'pearl-fixture-settings'], isLightMode=False))
        apps = Path(self.env['XDG_DATA_HOME']) / 'applications'
        apps.mkdir(parents=True)
        for name, icon in [('terminal', 'utilities-terminal'), ('files', 'system-file-manager'), ('settings', 'preferences-system')]:
            (apps / f'pearl-fixture-{name}.desktop').write_text('[Desktop Entry]\nType=Application\nName=Pearl reference ' + name + '\nExec=true\nIcon=' + icon + '\n')
        source = Path(self.args.dms_source) / 'quickshell'
        dms = self.child('dms', ['quickshell', '-p', str(source)])
        def available():
            if dms.proc.poll() is not None:
                raise AssertionError('\n'.join(dms.lines[-30:]))
            result = self.run(['quickshell', 'ipc', '--pid', str(dms.proc.pid), 'show'], check=False)
            return result.stdout if result.returncode == 0 else None
        (self.output / 'dms-ipc.txt').write_text(wait(available, 20))
        calls = []
        def call(*arguments):
            result = self.run(['quickshell', 'ipc', '--pid', str(dms.proc.pid), 'call', *arguments], check=False)
            calls.append(dict(args=arguments, exit=result.returncode, stdout=result.stdout, stderr=result.stderr))
            save(self.output / 'dms-calls.json', calls)
            if result.returncode != 0:
                raise AssertionError(result.stderr)
            time.sleep(.6)
        time.sleep(3)
        notification = self.run(['notify-send', '-a', 'Pearl T00 fixture', '-t', '0', 'Reference notification', 'A private-session fixture for spacing, typography and actions.'], check=False)
        self.results['notification_fixture_exit'] = notification.returncode
        for theme in ('dark', 'light'):
            call('theme', theme)
            self.capture(f'dms-{theme}-bar-dock')
            for name, opening, closing in [
                ('launcher', ('launcher', 'open'), ('launcher', 'close')),
                ('control-center', ('control-center', 'open'), ('control-center', 'hide')),
                ('notifications', ('notifications', 'open'), ('notifications', 'close')),
                ('calendar-media', ('dash', 'open', 'calendar'), ('dash', 'close')),
                ('media', ('dash', 'open', 'media'), ('dash', 'close')),
                ('settings', ('settings', 'open'), ('settings', 'close')),
            ]:
                call(*opening)
                self.capture(f'dms-{theme}-{name}')
                call(*closing)
        call('lock', 'demo')
        for theme in ('dark', 'light'):
            call('theme', theme)
            self.capture(f'dms-{theme}-lock-demo')
        (self.output / 'dms-settings.json').write_text(settings.read_text())
        if state.exists():
            (self.output / 'dms-session.json').write_text(state.read_text())
        self.results['dms_references'] = 'captured; software renderer, private services unavailable, lock is demo'

    def finish(self):
        save(self.output / 'results.json', self.results)
        for child in reversed(self.children):
            child.stop()
        for name in ('ipc', 'events'):
            if hasattr(self, name):
                getattr(self, name).sock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--aqueous', default=str(ROOT / '.cache/aqueous/bin/aqueous'))
    parser.add_argument('--ctl', default=str(ROOT / '.cache/aqueous/bin/aqueousctl'))
    parser.add_argument('--aqueous-source', default='/home/zoey/RiderProjects/Aqueous')
    parser.add_argument('--dms-source', default='/home/zoey/DankMaterialShell')
    parser.add_argument('--references-only', action='store_true')
    parser.add_argument('--output', default=str(ROOT / 'artifacts/t00/latest'))
    parser.add_argument('--idle-seconds', type=float, default=60)
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.idle_seconds <= 0:
        parser.error('--idle-seconds must be positive')
    if not args.inside:
        with tempfile.TemporaryDirectory(prefix='pearl-t00-') as tmp:
            base = Path(tmp)
            env = {k: os.environ[k] for k in ('PATH', 'LANG', 'LC_ALL', 'TZ') if k in os.environ}
            for key, directory in [('HOME','home'), ('XDG_RUNTIME_DIR','run'), ('XDG_CONFIG_HOME','config'), ('XDG_CACHE_HOME','cache'), ('XDG_STATE_HOME','state'), ('XDG_DATA_HOME','data')]:
                path = base / directory
                path.mkdir(mode=0o700)
                env[key] = str(path)
            env.update(PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman',
                       USER='pearl-reference', LOGNAME='pearl-reference',
                       GDK_BACKEND='wayland', GSK_RENDERER='cairo', GTK_A11Y='none', XDG_SESSION_TYPE='wayland',
                       XDG_CURRENT_DESKTOP='Aqueous', DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(base / 'no-system-bus'),
                       QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software', QSG_RHI_BACKEND='software',
                       DMS_DISABLE_MATUGEN='1', DMS_DISABLE_HOT_RELOAD='1')
            bus_config = base / 'bus.conf'
            bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=' + env['XDG_RUNTIME_DIR'] + '</listen>'
                                  '<auth>EXTERNAL</auth><policy context="default"><allow own="*"/>'
                                  '<allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>')
            # No service directories: nested tests must not auto-activate installed daemons.
            result = subprocess.run(['dbus-run-session', '--config-file=' + str(bus_config), '--', sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], '--inside'], env=env)
            raise SystemExit(result.returncode)
    session = Session(args)
    try:
        session.start()
        if args.references_only:
            session.references()
        else:
            session.test_spike()
        session.results['status'] = 'pass'
        print('PASS: T00 DMS reference capture' if args.references_only else 'PASS: T00 private Aqueous GTK/bindings/IPC/surface tests', flush=True)
    except Exception as error:
        session.results['status'] = 'failed'
        session.results['error'] = repr(error)
        raise
    finally:
        session.finish()


if __name__ == '__main__':
    main()
