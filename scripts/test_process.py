"""Linux process supervision and atomic evidence for the test runner."""
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    tmp.replace(path)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def fingerprint(root):
    h = hashlib.sha256()
    excluded = {'.git', '.cache', '.zig-cache', 'zig-out', 'zig-pkg', '__pycache__', 'target', 'artifacts'}
    for base in ['scripts', 'tests', 'src', 'bindings', 'resources', 'themes', 'plugins', 'packaging', 'subprojects']:
        for folder, dirs, files in os.walk(root / base):
            dirs[:] = sorted(d for d in dirs if d not in excluded)
            for name in sorted(files):
                p = Path(folder) / name
                if p.suffix == '.pyc':
                    continue
                h.update(str(p.relative_to(root)).encode() + b'\0')
                h.update((os.readlink(p) if p.is_symlink() else sha(p)).encode())
    for name in ['build.zig', 'build.zig.zon', '.zigversion']:
        h.update(name.encode() + (root / name).read_bytes())
    return h.hexdigest()


@contextlib.contextmanager
def checkout_lock(root):
    path = root / '.cache/test-runner/lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another test run or preparation owns this checkout; wait for it to finish.') from None
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def _processes():
    found = {}
    for p in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields = p.read_text().rsplit(')', 1)[1].split()
            found[int(p.parent.name)] = (int(fields[1]), fields[19])  # parent PID, birth tick
        except (OSError, ValueError, IndexError):
            pass
    return found


def descendants(pid):
    table = _processes()
    owned = {pid}
    while True:
        children = {p for p, (parent, _) in table.items() if parent in owned}
        updated = owned | children
        if updated == owned:
            break
        owned = updated
    return {p: table[p][1] for p in owned - {pid} if p in table}


def _signal_owned(owned, sig):
    table = _processes()
    for pid, birth in owned.items():
        if pid in table and table[pid][1] == birth:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass


def execute(command, cwd, env, logfile, timeout=900, echo=True):
    """A dedicated subreaper contains even double-forked/setsid descendants.

    The CLI invokes one worker process per command so unrelated children of the
    caller are never adopted or signalled. See worker() below.
    """
    import sys
    spec = Path(logfile).with_suffix('.command.json')
    # Environment can contain credentials; send it to the worker through inheritance,
    # never persist it in the command receipt.
    atomic_json(spec, dict(command=[str(v) for v in command], cwd=str(cwd), timeout=timeout,
                           logfile=str(logfile), echo=echo))
    proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), str(spec)], env=env)
    try:
        code = proc.wait()
    except KeyboardInterrupt:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            owned = descendants(proc.pid)
            _signal_owned(owned, signal.SIGKILL)
            proc.kill()
            proc.wait()
        raise
    return code


def worker(spec):
    # PR_SET_CHILD_SUBREAPER: orphaned descendants reparent to this worker, even
    # if a harness launched them with start_new_session=True.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'Unable to enable child subreaper')
    interrupted = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: interrupted.set())
    logfile = Path(spec['logfile'])
    logfile.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with logfile.open('wb') as log:
        child = subprocess.Popen(spec['command'], cwd=spec['cwd'], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        def drain():
            last_echo = 0.0
            while chunk := child.stdout.read1(65536):
                log.write(chunk)
                log.flush()
                now = time.monotonic()
                if spec['echo'] and now - last_echo > .1:
                    print(chunk[-4096:].decode(errors='replace'), end='', flush=True)
                    last_echo = now
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        code = None
        while child.poll() is None:
            if interrupted.is_set():
                code = 130
                break
            if time.monotonic() - started > spec['timeout']:
                code = 124
                break
            time.sleep(.05)
        if code is not None:
            # Interrupt first so Python harnesses execute finally clauses.
            try:
                os.killpg(child.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
            end = time.monotonic() + 3
            while child.poll() is None and time.monotonic() < end:
                time.sleep(.05)
        # Also clean up leaked grandchildren after a nominally successful command.
        for sig, delay in ((signal.SIGTERM, .3), (signal.SIGKILL, .1)):
            _signal_owned(descendants(os.getpid()), sig)
            time.sleep(delay)
        child.wait()
        reader.join(timeout=2)
        child.stdout.close()
        while True:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    break
            except ChildProcessError:
                break
    return code if code is not None else child.returncode


if __name__ == '__main__':
    import sys
    try:
        sys.exit(worker(json.loads(Path(sys.argv[1]).read_text())))
    except Exception as error:
        print(f'Runner worker error: {error}', file=sys.stderr)
        sys.exit(125)
