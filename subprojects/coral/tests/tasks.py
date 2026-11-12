#!/usr/bin/env python3
"""M5 native tasks/problem-matcher acceptance, in a private Wayland/D-Bus/HOME/XDG.

  python3 -B tests/tasks.py --binary /path/to/coral-test --case run-and-match

Every fixture workspace, task script and source file lives under the disposable
session tree; no host file is read or written and no host repository is touched.
Task definitions are real `.coral/tasks.json` files; the controller reads them
through its documented fixture bridge, which drives the *actual* public entry
points and answers the *actual* visible native dialogs. It never grants trust or
bypasses a permit: trust is exercised through the real policy commands, and each
run is reviewed through the real per-run disclosure.

Executables are /bin/sh running fixed, disposable fixture scripts (literal argv,
no shell interpolation by the runner). Diagnostic tasks only print; the slow task
only sleeps; nothing writes. Cancellation cases assert the supervised process
group is reaped (no lingering descendants). Matcher parsing, trust refusal,
cancellation/reap and the 1000-problem bound are all asserted against the live
CORAL_TASKS probe.

Integration gate: the binary must contain the CORAL_TASKS probe marker. A stale
binary that predates the parent's controller/command wiring is refused up front
rather than producing misleading per-case failures.

Fixture/probe API (src/tasks/tasks_controller.zig):
  actions: tasks-show tasks-run tasks-stop tasks-restart tasks-reload
           tasks-accept tasks-reject tasks-select tasks-navigate tasks-close
           tasks-probe
  probe:   CORAL_TASKS {window,visible,approved,generation,busy,loading,phase,
           launches,discarded,tasks,task_count,selected,run_index,problems,
           problem_count,problems_truncated,selected_problem,output_kind,
           output_bytes,dialog,restart_pending,navigate_path,navigate_line,
           navigate_column,status}
"""
import argparse
import hashlib
import json
import signal
import sys
import time
import traceback
from pathlib import Path

from search import PEARL, PROJECT
from policy import BudgetExpired, PolicyHarness, save
from windows import WindowHarness, stage_styles
from pearl_session import PrivateSession, fixture_prefix, wait_for

MARKER = 'CORAL_TASKS'
REQUIRED_MARKERS = (b'CORAL_TASKS ', b'CORAL_COMMAND_DONE')


def descendants(pid):
    found, pending = set(), [pid]
    while pending:
        parent = pending.pop()
        for path in Path('/proc/%d/task' % parent).glob('*/children'):
            try:
                children = [int(value) for value in path.read_text().split()]
            except (FileNotFoundError, ProcessLookupError):
                continue
            for child in children:
                if child not in found:
                    found.add(child)
                    pending.append(child)
    return found


def descendant_cmdlines(pid):
    lines = []
    for child in descendants(pid):
        try:
            raw = Path('/proc/%d/cmdline' % child).read_bytes()
        except (FileNotFoundError, ProcessLookupError):
            continue
        lines.append(raw.replace(b'\x00', b' ').decode('utf-8', 'replace'))
    return lines


class TasksHarness(WindowHarness):
    isolated_app_cwd = True

    def probe(self, kind='policy'):
        # WindowHarness defaults probes to 'workspace', but the inherited
        # PolicyHarness trust helpers (approve/restricted/trusted/confirmation/
        # settled/snapshot) require the policy probe. Restore that default while
        # keeping WindowHarness's target routing for explicit 'workspace' probes.
        return super().probe(kind)

    def fixture(self, settings=None):
        super().fixture(settings)
        root = self.roots[0]
        self.task_root = root
        # Real source files so relative problem paths resolve to existing files.
        self.write(root / 'src' / 'main.zig', 'const std = @import("std");\n' * 30)
        self.write(root / 'lib' / 'a.c', 'int fixture;\n' * 50)
        diag = self.write(root / 'diag.sh',
                          "printf 'src/main.zig:12:5: error: expected token\\n'\n"
                          "printf 'src/main.zig:20:1: note: referenced here\\n'\n"
                          "printf 'lib/a.c:40:9: warning: unused variable\\n' >&2\n"
                          "exit 1\n")
        slow = self.write(root / 'slow.sh', 'sleep 30\n')
        ok = self.write(root / 'ok.sh', "printf 'done\\n'\n")
        many = self.write(root / 'many.sh',
                          'i=1\n'
                          'while [ "$i" -le 1500 ]; do\n'
                          "  printf 'src/main.zig:%d:1: error: problem %d\\n' \"$i\" \"$i\"\n"
                          '  i=$((i + 1))\n'
                          'done\n')
        for script in (diag, slow, ok, many):
            script.chmod(0o700)
        env = {'PATH': '/usr/bin:/bin'}
        spec = {'version': 1, 'tasks': [
            {'name': 'diagnostics', 'argv': ['/bin/sh', str(diag)], 'env': env, 'matcher': 'zig'},
            {'name': 'slow', 'argv': ['/bin/sh', str(slow)], 'env': env, 'matcher': 'generic'},
            {'name': 'ok', 'argv': ['/bin/sh', str(ok)], 'env': env},
            {'name': 'many', 'argv': ['/bin/sh', str(many)], 'env': env, 'matcher': 'zig'},
        ]}
        self.write(root / '.coral' / 'tasks.json', json.dumps(spec))
        return self.manifest

    # --- tasks probe / fixture helpers ---------------------------------------

    def tp(self):
        lines, _ = self.command('tasks-probe')
        prefix = MARKER + ' '
        value = next((json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)), None)
        assert value is not None, ('CORAL_TASKS probe absent — controller not wired', lines[-6:])
        assert value['window'] == self.target, (value.get('window'), self.target)
        self.last[MARKER] = value
        return value

    def wait_tasks(self, predicate, timeout=18):
        def ready():
            value = self.tp()
            return value if predicate(value) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('Tasks deadline', self.last.get(MARKER))) from exc

    def idle_tasks(self, timeout=18):
        return self.wait_tasks(lambda p: not p['busy'] and not p['loading'], timeout)

    def setup(self, trust=True):
        self.fixture()
        self.open_workspace(self.manifest)
        if trust:
            self.approve()
        return self.probe()

    def open_tasks(self):
        self.command('tasks-show')
        assert self.tp()['dialog'] == 'trust', self.tp()
        self.command('tasks-accept')
        return self.wait_tasks(lambda p: p['visible'] and not p['loading'] and not p['busy'])

    def run_selected(self, index):
        self.command('tasks-select', value=index)
        assert self.tp()['selected'] == index
        self.command('tasks-run')
        assert self.tp()['dialog'] == 'run', self.tp()
        before = self.tp()['launches']
        self.command('tasks-accept')
        return self.wait_tasks(lambda p: p['launches'] > before and not p['busy'] and not p['loading'])

    def close_tasks(self):
        self.command('tasks-close')


# --- scenarios ---------------------------------------------------------------

def trust_refusal(h):
    h.setup(trust=False)
    h.restricted()
    h.command('tasks-show')
    p = h.tp()
    assert not p['approved'] and not p['visible'] and p['dialog'] is None, p
    assert p['launches'] == 0 and p['task_count'] == 0, p
    # A run request without trust must not launch anything.
    h.command('tasks-run')
    p = h.tp()
    assert p['launches'] == 0 and not p['busy'], p
    h.snapshot('restricted-tasks-refused')


def disclosure_reject(h):
    h.setup()
    h.command('tasks-show')
    assert h.tp()['dialog'] == 'trust'
    h.command('tasks-reject')
    p = h.tp()
    assert not p['approved'] and not p['visible'], p
    assert p['launches'] == 0, p
    h.snapshot('trust-disclosure-rejected')


def load_and_select(h):
    h.setup()
    p = h.open_tasks()
    assert p['approved'] and p['visible'], p
    assert p['task_count'] == 4, p
    assert p['tasks'] == ['diagnostics', 'slow', 'ok', 'many'], p
    h.command('tasks-select', value=0)
    assert h.tp()['selected'] == 0
    h.command('tasks-select', value=2)
    assert h.tp()['selected'] == 2
    h.snapshot('tasks-loaded-and-selected')
    h.close_tasks()
    assert not h.tp()['visible']


def run_review_reject(h):
    h.setup()
    h.open_tasks()
    h.command('tasks-select', value=0)
    h.command('tasks-run')
    assert h.tp()['dialog'] == 'run'
    h.command('tasks-reject')
    p = h.idle_tasks()
    assert p['launches'] == 0 and p['problem_count'] == 0, p
    h.snapshot('run-review-rejected')
    h.close_tasks()


def run_and_match(h):
    h.setup()
    h.open_tasks()
    p = h.run_selected(0)
    assert p['output_kind'] == 'nonzero', p
    assert p['problem_count'] == 3, p
    assert not p['problems_truncated'], p
    problems = p['problems']
    assert problems[0] == {'file': 'src/main.zig', 'line': 12, 'column': 5,
                           'severity': 'error', 'message': 'expected token'}, problems[0]
    assert problems[1]['severity'] == 'note' and problems[1]['line'] == 20, problems[1]
    assert problems[2] == {'file': 'lib/a.c', 'line': 40, 'column': 9,
                           'severity': 'warning', 'message': 'unused variable'}, problems[2]
    assert p['output_bytes'] > 0, p
    h.snapshot('task-ran-and-matched')
    h.close_tasks()


def navigate_problem(h):
    h.setup()
    h.open_tasks()
    h.run_selected(0)
    h.command('tasks-navigate', value=0)
    p = h.tp()
    expected = str(h.task_root / 'src' / 'main.zig')
    assert p['navigate_path'] == expected, (p['navigate_path'], expected)
    assert p['navigate_line'] == 12 and p['navigate_column'] == 5, p
    h.snapshot('problem-navigation-callback')
    h.close_tasks()


def stop_and_reap(h):
    h.setup()
    h.open_tasks()
    h.command('tasks-select', value=1)
    h.command('tasks-run')
    assert h.tp()['dialog'] == 'run'
    h.command('tasks-accept')
    running = h.wait_tasks(lambda p: p['busy'] and p['phase'] == 'running')
    assert running['launches'] >= 1
    # The slow task's process group must be alive while running.
    assert any('slow.sh' in line or 'sleep' in line for line in descendant_cmdlines(h.app.proc.pid)), \
        descendant_cmdlines(h.app.proc.pid)
    h.command('tasks-stop')
    p = h.idle_tasks()
    assert p['output_kind'] == 'cancelled', p
    assert not p['busy'], p
    # Supervised cancellation reaps the whole group: no lingering descendants.
    def reaped():
        lingering = [line for line in descendant_cmdlines(h.app.proc.pid)
                     if 'slow.sh' in line or 'sleep' in line]
        return not lingering
    wait_for(reaped, 10)
    h.snapshot('task-stopped-and-reaped')
    h.close_tasks()


def restart_reruns(h):
    h.setup()
    h.open_tasks()
    first = h.run_selected(2)
    assert first['output_kind'] == 'success', first
    assert first['problem_count'] == 0, first
    launches = first['launches']
    h.command('tasks-restart')
    assert h.tp()['dialog'] == 'run', h.tp()
    h.command('tasks-accept')
    p = h.wait_tasks(lambda q: q['launches'] > launches and not q['busy'] and not q['loading'])
    assert p['output_kind'] == 'success', p
    assert p['launches'] == launches + 1, p
    h.snapshot('task-restarted')
    h.close_tasks()


def bounded_problems(h):
    h.setup()
    h.open_tasks()
    p = h.run_selected(3)
    assert p['problem_count'] == 1000, p
    assert p['problems_truncated'], p
    assert len(p['problems']) <= 256, p  # probe renders a bounded visible window
    assert p['output_kind'] == 'success', p
    h.snapshot('problems-bounded-at-1000')
    h.close_tasks()


SCENARIOS = [
    ('trust-refusal', trust_refusal),
    ('disclosure-reject', disclosure_reject),
    ('load-and-select', load_and_select),
    ('run-review-reject', run_review_reject),
    ('run-and-match', run_and_match),
    ('navigate-problem', navigate_problem),
    ('stop-and-reap', stop_and_reap),
    ('restart-reruns', restart_reruns),
    ('bounded-problems', bounded_problems),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-tasks')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', default=None,
                        help='Exact case name or prefix group; repeatable. Subsets are reported as partial.')
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    blob = binary.read_bytes()
    missing = [marker.decode() for marker in REQUIRED_MARKERS if marker not in blob]
    if missing:
        print('REFUSED: binary lacks M5 tasks probe marker(s) %s — the parent has not wired '
              'src/tasks/tasks_controller.zig into this build.' % missing, file=sys.stderr, flush=True)
        sys.exit(2)

    selected = SCENARIOS
    if args.case:
        selected = [(name, fn) for name, fn in SCENARIOS
                    if any(name == want or name.startswith(want) for want in args.case)]
        if not selected:
            print('No cases match --case %s' % args.case, file=sys.stderr)
            sys.exit(2)

    began = time.monotonic()
    evidence = {'status': 'running', 'checks': [], 'runtime_budget_seconds': 400,
                'partial': len(selected) != len(SCENARIOS),
                'measurement_note': 'Native GTK probe assertions; Wayland key-to-handler acknowledgement, not frame latency.',
                'isolation': 'Private headless compositor, D-Bus, HOME and XDG; disposable per-case fixtures; no host writes.'}

    def expired(_signal, _frame):
        raise BudgetExpired('Tasks acceptance exceeded the 400-second whole-suite budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(400)
    save(output, evidence)
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            stage_styles(session, evidence)
            for name, scenario in selected:
                record = {'name': name, 'status': 'running'}
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = TasksHarness(session, binary, output, evidence, name, began + 395)
                    scenario(h)
                    h.close_tasks()
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_hashes_verified=len(h.expected),
                                  executable_sentinels_absent=len(h.sentinels))
                    print('PASS', name, flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc(),
                                  last_probe=h.last.copy() if h else {})
                    print('FAIL', name, str(exc)[:1800], flush=True)
                    if h:
                        try:
                            h.screenshot('failure')
                            h.verify_files()
                        except Exception:
                            record['failure_evidence_error'] = traceback.format_exc()
                finally:
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    del session.children[child_start:]
                    record['seconds'] = time.monotonic() - start
                    save(output, evidence)
        evidence['status'] = 'passed' if all(c['status'] == 'passed' for c in evidence['checks']) else 'failed'
    except (Exception, BudgetExpired):
        evidence.update(status='failed', fatal=traceback.format_exc())
        print(evidence['fatal'], file=sys.stderr, flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        completed = {c['name'] for c in evidence['checks']}
        for name, _ in selected:
            if name not in completed:
                evidence['checks'].append({'name': name, 'status': 'blocked', 'reason': 'Suite setup or runtime budget failed'})
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        save(output, evidence)
    passed = sum(c['status'] == 'passed' for c in evidence['checks'])
    label = 'PARTIAL' if evidence['partial'] else evidence['status'].upper()
    print(f"{label}: {passed}/{len(selected)} native tasks cases; {output / 'results.json'}", flush=True)
    sys.exit(0 if evidence['status'] == 'passed' else 1)


if __name__ == '__main__':
    main()
