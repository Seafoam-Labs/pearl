"""Private Aqueous development sessions. No host service-manager environment import."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.025)
    raise TimeoutError('private session condition timed out')


class Child:
    def __init__(self, argv, env, cwd, logfile, echo=False, input_pipe=False, log_limit=20000):
        self.lines = []
        self.proc = subprocess.Popen([str(x) for x in argv], env=env, cwd=cwd,
                                     stdin=subprocess.PIPE if input_pipe else subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.logfile = Path(logfile)
        self.logfile.parent.mkdir(parents=True, exist_ok=True)
        def collect():
            with self.logfile.open('w') as log:
                for line in self.proc.stdout:
                    if len(self.lines) < log_limit:
                        self.lines.append(line.rstrip())
                        log.write(line)
                        log.flush()
                        if echo:
                            print(line, end='', flush=True)
        self.thread = threading.Thread(target=collect, daemon=True)
        self.thread.start()

    def expect(self, fragment, timeout=10):
        def found():
            if any(fragment in line for line in self.lines):
                return True
            if self.proc.poll() is not None:
                self.thread.join(timeout=1)
                raise AssertionError(f'{self.logfile}: exited {self.proc.returncode}\n' + '\n'.join(self.lines[-25:]))
        wait_for(found, timeout)

    def wait(self, timeout=10):
        status = self.proc.wait(timeout=timeout)
        self.thread.join(timeout=2)
        return status

    def signal(self, sig=signal.SIGTERM):
        os.killpg(self.proc.pid, sig)

    def stop(self):
        # Include descendants even if their original parent has already exited.
        try:
            self.signal()
        except ProcessLookupError:
            pass
        try:
            self.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.signal(signal.SIGKILL)
            self.wait(timeout=4)
        try:
            self.signal(signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.proc.stdout.close()
        if self.proc.stdin is not None:
            self.proc.stdin.close()


class PrivateSession:
    def __init__(self, output, aqueous=None, backend='headless', parent_display=None, inherited=None, renderer='pixman', wm_extra=''):
        self.output = Path(output).resolve()
        self.aqueous = Path(aqueous or ROOT / '.cache/aqueous/bin/aqueous').resolve()
        if backend not in ('headless', 'nested'):
            raise ValueError('backend must be headless or nested')
        if renderer not in ('pixman', 'vulkan'):
            raise ValueError('unsupported private renderer')
        self.renderer = renderer
        self.wm_extra = wm_extra
        self.backend = backend
        self.parent_display = parent_display
        self.inherited = dict(os.environ if inherited is None else inherited)
        self.children = []
        self.temp = None

    def __enter__(self):
        try:
            self.start()
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *_):
        self.close()

    def child(self, name, argv, *, echo=False, input_pipe=False, log_limit=20000, **overrides):
        child = Child(argv, dict(self.env, **overrides), self.base, self.output / f'{name}.log', echo=echo, input_pipe=input_pipe, log_limit=log_limit)
        self.children.append(child)
        return child

    def run(self, argv, check=True, **overrides):
        return subprocess.run([str(x) for x in argv], env=dict(self.env, **overrides), cwd=self.base,
                              capture_output=True, text=True, timeout=10, check=check)

    def start(self):
        if not self.aqueous.is_file():
            raise FileNotFoundError(f'Build the T00 Aqueous test binary first, or pass --aqueous: {self.aqueous}')
        if self.backend == 'nested' and (not self.parent_display or not Path(self.parent_display).is_socket()):
            raise ValueError('nested mode requires an explicit, existing parent Wayland socket')
        self.output.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='pearl-dev-')
        self.base = Path(self.temp.name)
        # Only locale and executable lookup survive. In particular, never retain
        # host bus, Wayland FDs, activation tokens, shell sockets or LD_PRELOAD.
        self.env = {k: self.inherited[k] for k in ('PATH', 'LANG', 'LC_ALL', 'TZ') if k in self.inherited}
        for key, name in [('HOME', 'home'), ('XDG_RUNTIME_DIR', 'run'), ('XDG_CONFIG_HOME', 'config'),
                          ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state'), ('XDG_DATA_HOME', 'data'),
                          ('XDG_CONFIG_DIRS', 'system-config')]:
            directory = self.base / name
            directory.mkdir(mode=0o700)
            self.env[key] = str(directory)
        self.runtime = Path(self.env['XDG_RUNTIME_DIR'])
        self.env.update(USER='pearl-demo', LOGNAME='pearl-demo', XDG_SESSION_TYPE='wayland',
                        XDG_CURRENT_DESKTOP='Aqueous', GDK_BACKEND='wayland', GTK_A11Y='none', GSK_RENDERER='cairo',
                        DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(self.runtime / 'bus'),
                        DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(self.runtime / 'no-system-bus'),
                        PULSE_SERVER='unix:' + str(self.runtime / 'pulse/native'))
        config = self.base / 'bus.conf'
        config.write_text('<busconfig><type>session</type><listen>' + escape(self.env['DBUS_SESSION_BUS_ADDRESS']) +
                          '</listen><auth>EXTERNAL</auth><policy context="default"><allow own="*"/>'
                          '<allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>')
        bus = self.child('bus', ['dbus-daemon', '--nofork', '--config-file=' + str(config)])
        def bus_ready():
            if bus.proc.poll() is not None:
                raise RuntimeError('private D-Bus failed: ' + str(bus.logfile))
            return (self.runtime / 'bus').is_socket()
        wait_for(bus_ready)
        wm = self.base / 'config/aqueous/wm.toml'
        wm.parent.mkdir()
        wm.write_text('[layout]\ndefault = "floating"\ngaps_outer = 0\ngaps_inner = 0\n'
                      '[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\nfocus_new_windows = true\n' + self.wm_extra)
        self.env['AQUEOUS_CONFIG'] = str(wm)
        compositor_env = dict(WLR_BACKENDS='headless' if self.backend == 'headless' else 'wayland',
                              WLR_RENDERER=self.renderer, WLR_HEADLESS_OUTPUTS='2', WLR_WL_OUTPUTS='1')
        if self.parent_display:
            compositor_env['WAYLAND_DISPLAY'] = str(self.parent_display)
        marker = 'printenv WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/display"; printenv AQUEOUS_SOCKET > "$XDG_RUNTIME_DIR/endpoint"'
        self.compositor = self.child('compositor', [self.aqueous, '-no-xwayland', '-c', marker], **compositor_env)
        def ready():
            if self.compositor.proc.poll() is not None:
                raise RuntimeError('private Aqueous failed: ' + str(self.compositor.logfile))
            endpoint = self.runtime / 'endpoint'
            return endpoint.exists() and endpoint.read_text().strip()
        endpoint = Path(wait_for(ready, 15))
        display = (self.runtime / 'display').read_text().strip()
        assert endpoint.is_relative_to(self.runtime) and endpoint.is_socket()
        display_path = self.runtime / display
        assert display_path.is_relative_to(self.runtime) and display_path.is_socket()
        assert display_path != self.parent_display
        self.env.update(WAYLAND_DISPLAY=display, AQUEOUS_SOCKET=str(endpoint))
        self.display_path = display_path

    def close(self):
        try:
            for child in reversed(self.children):
                child.stop()
        finally:
            self.children.clear()
            if self.temp is not None:
                self.temp.cleanup()
                self.temp = None
