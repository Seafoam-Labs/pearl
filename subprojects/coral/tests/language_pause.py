"""Pause regressions registered by language.py (zig build language -- --case pause).

Native cases use production UI actions, an actual external flock, and the real
approval-store API in another process. No state bytes or approvals are forged.
The companion extracted-source Zig tests order completions with a fake clock;
there is no reliable native barrier for the very short paused-poll/Start race.
"""

from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from pearl_session import wait_for

PROJECT = Path(__file__).resolve().parents[1]
FIXTURES = PROJECT / 'tests/fixtures'


def run_logged(h, argv, name, *, env=None, timeout=60, allowed=(0,)):
    log = h.case_output / (name + '.log')
    with log.open('a') as stream:
        result = subprocess.run(argv, cwd=h.case_output, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    h.evidence.setdefault('pause_commands', []).append(dict(
        case=h.name, argv=[str(arg) for arg in argv], returncode=result.returncode, log=str(log)))
    assert result.returncode in allowed, (argv, result.returncode, log.read_text()[-4000:])
    return result.returncode


def completion_races(h):
    run_logged(h, [sys.executable, '-B', FIXTURES / 'language_pause_races.py',
                   '--output', h.case_output], 'completion-races', timeout=90)


@contextmanager
def locked_store(h):
    store = Path(h.session.env['XDG_STATE_HOME']) / 'coral/language'
    fd = os.open(store, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        # Do not let a broken lock holder hang the harness before its case alarm.
        def acquire():
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                return False
        wait_for(acquire, 5)
        yield store
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def paused_on_disk(store, key):
    # Observation only. Publication must always go through approvals.setPaused.
    return ('P ' + key).encode() in (store / 'store').read_bytes().splitlines()


def observe_busy_stop(h, store, key, *, queued):
    h.wait_language(lambda p: p['session_count'] == 0 and p['config_check'] == 'pause'
                    and p['config_queued'] == queued and p['automatic']['paused'])
    # The lock establishes the race, rather than hoping a Stop lands in a short
    # I/O window. Sample across several retry deadlines; exact backoff and retry
    # counts are checked without wall-clock timing in completion_races.
    until = time.monotonic() + 1.2
    while time.monotonic() < until:
        p = h.language()
        assert p['config_check'] == 'pause' and p['config_queued'] == queued, p
        assert p['automatic']['paused'] and p['automatic']['runtime_inhibited'], p
        assert p['session_count'] == 0 and not p['dialog'], p
        assert not paused_on_disk(store, key), 'Stop published despite the external lock'
        assert len(h.messages('initialize')) == 1, 'Start overtook the pending Stop'
        time.sleep(.05)
    h.assert_reaped()
    h.evidence_snapshot('busy-stop-with-queued-start' if queued else 'busy-stop-before-close')


def busy_close(h):
    h.setup()
    key = h.language()['automatic']['workspace_key']
    with locked_store(h) as store:
        assert not paused_on_disk(store, key)
        h.invoke('stop')
        observe_busy_stop(h, store, key, queued=False)
        h.action('win.quit')
        wait_for(lambda: not h.native_windows(), 8)
        assert h.app.proc.poll() is None, 'closing dropped the pending durable Stop hold'
    assert h.app.wait(timeout=15) == 0
    assert paused_on_disk(store, key), 'process exited without publishing the retried Stop'
    h.no_criticals()
    h.assert_reaped()
    h.launch()
    h.wait_language(lambda p: p['automatic']['paused'] and p['session_count'] == 0)
    h.stays_stopped(paused=True)
    assert h.document(h.main), 'restored document missing after Busy Stop/close'
    assert len(h.messages('initialize')) == 1
    h.evidence_snapshot('busy-stop-published-before-process-drain-and-restore')


def busy_resume_order(h):
    h.setup()
    old = h.language()['sessions'][0]['id']
    key = h.language()['automatic']['workspace_key']
    with locked_store(h) as store:
        assert not paused_on_disk(store, key)
        h.invoke('stop')
        h.wait_language(lambda p: p['session_count'] == 0 and p['config_check'] == 'pause')
        h.invoke('start')
        observe_busy_stop(h, store, key, queued=True)
    p = h.ready_language()
    assert p['sessions'][0]['id'] != old and not p['automatic']['paused'], p
    assert not p['automatic']['runtime_inhibited'] and not p['config_queued'], p
    assert not paused_on_disk(store, key)
    assert len(h.messages('initialize')) == 2
    h.evidence_snapshot('resume-ordered-after-retried-stop')


def external_resume(h):
    # Keep the helper independent of private build artifacts. Zig's module path
    # boundary requires the small local import closure beside the fixture root.
    sources = ('src/language/approvals.zig', 'src/workspace/trust_fs.zig',
               'src/workspace/trust.zig', 'src/workspace/identity.zig')
    hashes = {}
    for relative in sources:
        source, target = PROJECT / relative, h.case_output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        hashes[relative] = hashlib.sha256(target.read_bytes()).hexdigest()
        assert target.read_bytes() == source.read_bytes()
    helper_source = h.case_output / 'language_resume.zig'
    shutil.copyfile(FIXTURES / helper_source.name, helper_source)
    helper = h.case_output / 'language-resume'
    run_logged(h, ['zig', 'build-exe', helper_source, '-lc', '-O', 'safe',
                   '-femit-bin=' + str(helper)], 'build-resume-helper')
    h.evidence.setdefault('pause_helper_sources', []).append(dict(case=h.name, sha256=hashes))
    h.setup()
    old = h.language()['sessions'][0]['id']
    p = h.stop_language()
    key = p['automatic']['workspace_key']
    store = Path(h.session.env['XDG_STATE_HOME']) / 'coral/language'
    assert p['automatic']['runtime_inhibited'] and paused_on_disk(store, key), p
    before = {line for line in (store / 'store').read_bytes().splitlines() if line.startswith(b'A ')}
    assert before, 'fixture must have a real UI-granted executable approval'
    env = dict(h.session.env, CORAL_TEST_PAUSE_KEY=key)
    wait_for(lambda: run_logged(h, [helper], 'external-resume', env=env,
                               timeout=5, allowed=(0, 75)) == 0, 10)
    p = h.ready_language()  # no local Start/Restart: reconcile another process's durable resume
    assert p['sessions'][0]['id'] != old, p
    assert not p['automatic']['paused'] and not p['automatic']['runtime_inhibited'], p
    assert not paused_on_disk(store, key)
    after = {line for line in (store / 'store').read_bytes().splitlines() if line.startswith(b'A ')}
    assert before == after, 'resume must preserve, not forge or revoke, executable approval'
    assert len(h.messages('initialize')) == 2
    h.evidence_snapshot('external-durable-resume-reconciled')


CASES = [('pause-completion-races', completion_races, True),
         ('pause-busy-close', busy_close, True),
         ('pause-busy-resume-order', busy_resume_order, True),
         ('pause-external-resume', external_resume, True)]
