#!/usr/bin/env python3
"""Exercise ordinary-compositor supervision without opening a real PAM session."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def wait_file(path, host):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return path.read_text().strip()
        assert host.poll() is None, host.communicate()[1]
        time.sleep(.02)
    raise AssertionError(f'Timed out waiting for {path}')


def finish(host, pids, ok=True):
    _, err = host.communicate(timeout=8)
    assert (host.returncode == 0) == ok, err
    assert 'event=greeter-host-reaped' in err, err
    assert 'GLib-CRITICAL' not in err, err
    for pid in pids:
        assert not Path(f'/proc/{pid}').exists(), f'Leaked descendant {pid}: {err}'


def fixtures(host_binary, root):
    runtime = root/'fixture-runtime'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime))
    # Model Aqueous: the init/UI and another descendant each call setsid().
    ui = root/'ui.py'
    ui.write_text('import os,sys,time\nfrom pathlib import Path\nos.write(3, (str(os.getpid())+"\\n").encode())\nos.close(3)\nopen(sys.argv[1],"w").write(str(os.getpid()))\nwhile not Path(sys.argv[1]+".exit").exists(): time.sleep(.02)\n')
    compositor = root/'compositor.py'
    compositor.write_text('''import os,signal,subprocess,sys,time
if sys.argv[4] == "forced-shutdown": signal.signal(signal.SIGTERM, signal.SIG_IGN)
ui=subprocess.Popen(['/usr/bin/python3',sys.argv[1],sys.argv[2]],pass_fds=(3,),start_new_session=True)
escaped=subprocess.Popen(['/usr/bin/sleep','120'],start_new_session=True)
open(sys.argv[3],'w').write(str(os.getpid())+' '+str(escaped.pid))
time.sleep(120)
''')
    for event in ('shutdown', 'forced-shutdown', 'ui-exit', 'ui-crash', 'compositor-crash'):
        ui_pid = root/(event+'-ui')
        pids = root/(event+'-pids')
        host = subprocess.Popen([str(host_binary), '--fixture-host', '/usr/bin/dbus-run-session', '--', '/usr/bin/python3', str(compositor), str(ui), str(ui_pid), str(pids), event], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ui_id = int(wait_file(ui_pid, host))
            compositor_id, escaped = map(int, wait_file(pids, host).split())
            # Give the host time to consume the lifecycle message before the crash.
            time.sleep(.1)
            if event in ('shutdown', 'forced-shutdown'):
                host.send_signal(signal.SIGTERM)
            elif event == 'ui-exit':
                Path(str(ui_pid)+'.exit').touch()
            else:
                os.kill(ui_id if event == 'ui-crash' else compositor_id, signal.SIGKILL)
            finish(host, (ui_id, compositor_id, escaped))
        finally:
            if host.poll() is None:
                host.terminate()
                host.communicate(timeout=8)
    for command in (['/usr/bin/false'], ['/bin/sh', '-c', 'printf invalid\\\\n >&3; sleep 120']):
        host = subprocess.Popen([str(host_binary), '--fixture-host', *command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        finish(host, (), ok=False)
    # Missing init notification must end startup, even if the compositor stays alive.
    host = subprocess.Popen([str(host_binary), '--fixture-host', '/usr/bin/sleep', '120'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    _, err = host.communicate(timeout=38)
    assert host.returncode != 0 and 'did not start within 30 seconds' in err, err


def aqueous_case(host_binary, aqueous, root):
    env = {k: os.environ[k] for k in ('PATH', 'LANG', 'LD_LIBRARY_PATH') if k in os.environ}
    for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CONFIG_DIRS'):
        directory = root/key
        directory.mkdir(mode=0o700)
        env[key] = str(directory)
    env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
    # Exercise the packaged init handshake unchanged; substitute only the UI executable.
    marker = root/'real-ui'
    init = root/'init'
    content = (ROOT/'packaging/greeter/pearl-greeter-init').read_text()
    content = content.replace('exec /usr/bin/pearl-greeter 3>&-', f'printf "%s\\n" "$$" > "{marker}"\nexec /usr/bin/sleep 120 3>&-')
    init.write_text(content)
    init.chmod(0o700)
    host = subprocess.Popen([str(host_binary), '--fixture-host', '/usr/bin/dbus-run-session', '--', str(aqueous), '-no-xwayland', '-c', str(init)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ui_id = int(wait_file(marker, host))
        time.sleep(.1)
        os.kill(ui_id, signal.SIGKILL)
        finish(host, (ui_id,))
    finally:
        if host.poll() is None:
            host.terminate()
            host.communicate(timeout=8)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host', type=Path, required=True)
    p.add_argument('--aqueous', type=Path)
    args = p.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-host-') as tmp:
        unrelated = subprocess.Popen(['/usr/bin/sleep', '120'])
        try:
            fixtures(args.host.resolve(), Path(tmp))
            if args.aqueous:
                aqueous_case(args.host.resolve(), args.aqueous.resolve(), Path(tmp))
            assert unrelated.poll() is None
        finally:
            unrelated.terminate()
            unrelated.wait()
    print('Ordinary host startup/failure, UI/compositor crashes and detached descendant cleanup passed; unrelated process survived.')


if __name__ == '__main__':
    main()
