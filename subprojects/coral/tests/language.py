#!/usr/bin/env python3
"""Native LSP acceptance in disposable HOME/XDG + private headless Wayland/D-Bus.

  zig build language -- --case trusted-start --output .cache/language-local
  # Or use an independently built hook artifact (no build-file changes needed):
  zig build -Dtest-hooks=true -Doptimize=safe --prefix .cache/language-hook/install
  python3 -B tests/language.py --binary .cache/language-hook/install/bin/coral

--case accepts exact names or groups (sync, faults, policy, real-zls), repeatable.
A selected subset is explicitly reported as partial, never full acceptance.
--app-arg passes one argument to Coral; trailing arguments after -- also pass
through. No host desktop/bus/configuration, clipboard or external browser is used.
Native actions use GTK's exported window actions; palette, editing, save and
several approval paths use real Wayland keyboard/pointer input. F11 hooks set up
fixtures, observe public JSON probes, select exact positions and answer reviews.
Real ZLS is mandatory by default, pinned by fixtures/lsp-reference.json, and is
launched at /usr/bin/zls, NOT /usr/bin/zls0.17.0. Optional language smoke cases
are reported separately and never substituted with the fake server.
"""

import argparse
import functools
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from urllib.parse import unquote, urlsplit

from windows import WindowHarness, stage_styles, confirm_scope
from search import PROJECT, PEARL
from pearl_session import PrivateSession, fixture_prefix, wait_for
from wayland_test_input import pointer_move, pointer_click
from fixtures.fake_lsp import offset, text_end
from operations import tree
from language_pause import CASES as PAUSE_CASES

FIXTURE = PROJECT / 'tests/fixtures/fake_lsp.py'
REFERENCE = PROJECT / 'tests/fixtures/lsp-reference.json'
TEXT = 'const greeting = "aé😀z";\nconst answer = 42;\n'
REAL_TEXT = ('pub const answer: u32 = 42;\n'
             'pub fn add(a: u32, b: u32) u32 { return a + b; }\n'
             'pub fn main() void {\n'
             '    const greeting = "café 😀";\n'
             '    _ = greeting;\n'
             '    _ = add(answer, 1);\n'
             '}\n')
LABELS = {
    'start': 'Language: Start…', 'stop': 'Language: Stop all sessions',
    'restart': 'Language: Restart current server', 'status': 'Language: Status',
    'hover': 'Language: Hover', 'signature': 'Language: Signature help',
    'completion': 'Language: Completion…', 'definition': 'Language: Definition…',
    'references': 'Language: References…', 'document-symbols': 'Language: Document symbols…',
    'workspace-symbols': 'Language: Workspace symbols…', 'problems': 'Language: Problems',
    'formatting': 'Language: Format document…', 'range-formatting': 'Language: Format selection…',
    'rename': 'Language: Rename…', 'code-actions': 'Language: Code actions…',
    'semantic-tokens': 'Language: Refresh semantic tokens', 'inlay-hints': 'Language: Inlay hints…',
    'code-lenses': 'Language: Code lenses…', 'document-links': 'Language: Document links…',
}


class Blocked(Exception):
    """A missing prerequisite is not an assertion success."""


class CaseTimeout(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(path)


def process_stamp(pid):
    try:
        fields = Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()
        return fields[19]  # starttime (field 22), immune to PID reuse
    except (FileNotFoundError, ProcessLookupError):
        return None


def descendants(pid):
    found, pending = set(), [pid]
    while pending:
        parent = pending.pop()
        for path in Path('/proc/%d/task' % parent).glob('*/children'):
            try:
                children = [int(item) for item in path.read_text().split()]
            except (FileNotFoundError, ProcessLookupError):
                continue
            for child in children:
                if child not in found:
                    found.add(child)
                    pending.append(child)
    return found


def transcript(path):
    if not path.exists():
        return []
    data = path.read_bytes()
    # Only the final, in-flight line may be incomplete. Never hide corrupt JSON.
    complete = data[:data.rfind(b'\n') + 1]
    return [json.loads(line) for line in complete.splitlines()]


def replay(messages, encoding):
    """Independently reconstruct canonical documents from native outbound traffic."""
    documents, versions = {}, {}
    for message in messages:
        method, params = message.get('method'), message.get('params', {})
        item = params.get('textDocument', {})
        uri = item.get('uri')
        if method == 'textDocument/didOpen':
            assert uri not in documents, ('duplicate didOpen', message)
            documents[uri], versions[uri] = item['text'], item['version']
        elif method == 'textDocument/didChange':
            assert uri in documents and item['version'] > versions[uri], message
            text = documents[uri]
            for change in params['contentChanges']:
                if 'range' in change:
                    begin = offset(text, change['range']['start'], encoding)
                    end = offset(text, change['range']['end'], encoding)
                    text = text[:begin] + change['text'] + text[end:]
                else:
                    text = change['text']
            documents[uri], versions[uri] = text, item['version']
        elif method == 'textDocument/didClose':
            assert uri in documents, message
            del documents[uri]
            del versions[uri]
    return documents, versions


class LanguageHarness(WindowHarness):
    isolated_app_cwd = True

    def __init__(self, session, binary, output, evidence, name, deadline, binary_args=()):
        self.binary_args = binary_args
        self.server_processes = {}
        self.config_serial = 0
        self.case_output = output / name
        self.case_output.mkdir()
        self.logs = self.case_output / 'protocol'
        self.logs.mkdir()
        self.current_prefix = None
        self.marker = None
        super().__init__(session, binary, output, evidence, name, deadline)
        self.config = Path(session.env['HOME']) / '.config/coral/languages.json'
        self.config.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.last_language = self.language()

    def launch(self, recovery=False, paths=()):
        super().launch(recovery=recovery, paths=(*self.binary_args, *paths))

    def drained(self, count=None):
        # Each live browser owns one watcher hold; each live LSP session owns
        # another. WindowHarness predates language sessions and expects only one.
        def ready():
            registry = self.windows()
            if (registry['closing'] or registry['saves'] or registry['session_owner'] is not None or
                    registry['preferences_pending'] or (count is not None and registry['live'] != count)):
                return None
            total = 0
            for window in registry['windows']:
                with self.at(window['id']):
                    sessions = self.language()['session_count']
                if window['holds'] != 1 + sessions or window['recovery_holds'] or window['recovery_opening']:
                    return None
                total += 1 + sessions
            return registry if registry['holds'] == total else None
        result = wait_for(ready, 15)
        self.evidence.setdefault('language_drains', []).append(dict(case=self.name, registry=result))
        return result

    def language(self):
        p = self.probe('language')
        assert p['window'] == self.target, ('language probe routed to wrong owner', self.target, p)
        assert p['session_count'] == len(p['sessions']) <= 8, p
        assert p['diagnostics'] == sum(d['diagnostics'] for s in p['sessions'] for d in s['documents']), p
        self.last_language = p
        return p

    def wait_language(self, predicate, timeout=12):
        def ready():
            p = self.language()
            return p if predicate(p) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('language deadline', self.last_language)) from exc

    def result(self, mode=None, timeout=15):
        def ready(p):
            if p['pending'] is not None or p['review_loading']:
                return False
            if p['dialog'] and (mode is None or p['mode'] == mode):
                return True
            if not p['dialog'] and p['status'].startswith('Language: '):
                raise AssertionError(('native language request failed', p))
            return False
        return self.wait_language(ready, timeout)

    def invoke(self, action, palette=False):
        if palette:
            # The palette uses ordered-subsequence matching, not exact-label
            # ranking: "Language: Status" also matches "Restart current server".
            # Stable action spelling avoids that ambiguity while using real UI.
            self.palette('language-' + action)
        else:
            self.action('win.language-' + action)

    def accept(self, value=None):
        self.command('language-accept', value)

    def reject(self):
        self.command('language-reject')
        assert not self.language()['dialog'], self.last_language

    def click_dialog(self, title, approve=True):
        surface = wait_for(lambda: next((w for w in self.native_windows() if w.get('title') == title), None))
        self.ipc.call('command', action='window.activate', fields={'id': surface['id']})
        time.sleep(.15)
        surface = next(w for w in self.native_windows() if w['id'] == surface['id'])
        rect = surface['geometry']
        # Real GtkDialog action-area coordinates, same route as roots.py. Verify
        # semantic outcome after the click, not just disappearance of a surface.
        x = rect['x'] + rect['width'] - (80 if approve else 270)
        y = rect['y'] + rect['height'] - 22
        pointer_move(self.session, x, y)
        pointer_click(self.session)
        self.evidence.setdefault('pointer_routes', []).append(
            dict(case=self.name, title=title, approve=approve, point=[x, y]))
        wait_for(lambda: all(w['id'] != surface['id'] for w in self.native_windows()), 7)

    def configure(self, mode='default', *, options=(), real=False, language='zig', argv=None, marker=False):
        self.config_serial += 1
        env = {key: self.session.env[key] for key in (
            'HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_RUNTIME_DIR')}
        env.update(PATH='/usr/bin:/bin', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
        self.current_prefix = self.logs / ('server-%02d.jsonl' % self.config_serial)
        if argv is None:
            argv = ['/usr/bin/zls'] if real else [sys.executable, '-B', str(FIXTURE), '--mode', mode,
                                                '--log', str(self.current_prefix), '--log-sequence', *options]
        if marker:
            self.marker = self.case_output / ('launch-%02d.json' % self.config_serial)
            env.update(CORAL_FAKE_LSP_TEST='1', CORAL_FAKE_LSP_LAUNCH_MARKER=str(self.marker))
        else:
            self.marker = None
        value = {'version': 1, 'servers': [{'language': language, 'argv': argv, 'env': env, 'cwd': 'root'}]}
        self.config.write_text(json.dumps(value) + '\n')
        self.config.chmod(0o600)
        self.evidence.setdefault('server_configurations', []).append(
            dict(case=self.name, config=value, sha256=digest(self.config.read_bytes())))
        if self.language()['session_count']:
            self.wait_language(lambda p: p['session_count'] == 0)
        time.sleep(.15)  # allow the file monitor's coalesced config events to drain
        return value

    def fixture(self, text=TEXT, roots=1, filename='main.zig'):
        self.roots = [self.fixtures / ('root-%d' % i) for i in range(roots)]
        for root in self.roots:
            self.write(root / filename, text)
            self.write(root / 'other.zig', 'const other = 9;\n')
        self.main = self.roots[0] / filename
        self.other = self.roots[0] / 'other.zig'
        if roots == 1:
            self.workspace(self.roots[0])
        else:
            self.manifest = self.write(self.fixtures / 'roots.coral-workspace', json.dumps({
                'version': 1, 'roots': [{'path': str(root), 'name': root.name} for root in self.roots]}))
            self.command('open-workspace', self.manifest)
            self.browser()
            self.policy_idle()
        self.open_document(self.main)
        return self.main

    def trust(self):
        p = self.policy_idle()
        if p['trust'] != 'trusted':
            confirm_scope(self)

    def ready_language(self, count=1):
        p = self.wait_language(lambda p: p['session_count'] == count and
                               all(s['state'] == 'ready' and s['documents'] for s in p['sessions']), 25)
        assert not p['dialog'], p
        self.remember_processes()
        return p

    def automatic_review(self):
        # Never issue Start here: that would conceal a broken automatic trigger.
        p = self.wait_language(lambda p: p['dialog'] and p['mode'] == 'start', 25)
        assert 'Approval is saved for this exact configuration and executable identity' in p['popup'], p
        assert 'Workspace trust is NOT an OS sandbox' in p['popup'], p
        assert p['automatic']['approval_key'], p
        return p

    def start(self, native=False, count=1):
        p = self.language()
        if not (p['dialog'] and p['mode'] == 'start'):
            self.invoke('start', palette=native)
        p = self.wait_language(lambda p: (p['dialog'] and p['mode'] == 'start') or
                               (p['session_count'] == count and all(s['state'] == 'ready' for s in p['sessions'])), 25)
        if p['dialog']:
            self.automatic_review()
            if native:
                self.click_dialog('Language: Start')
            else:
                self.accept()
        return self.ready_language(count)

    def stays_stopped(self, seconds=2.5, *, paused=False):
        # Observe several production reconciliation intervals, not one lucky tick.
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            p = self.language()
            assert p['session_count'] == 0 and not p['dialog'], p
            if paused:
                assert p['automatic']['paused'], p
            time.sleep(.15)
        return p

    def setup(self, mode='default', *, text=TEXT, roots=1, options=(), real=False, native=False):
        self.configure(mode, options=options, real=real)
        self.fixture(text=text, roots=roots)
        self.trust()
        self.automatic_review()
        if native:
            self.click_dialog('Language: Start')
        else:
            self.accept()
        return self.ready_language()

    def remember_processes(self):
        for pid in descendants(self.app.proc.pid):
            try:
                command = Path('/proc/%d/cmdline' % pid).read_bytes().split(b'\0')
                executable = Path('/proc/%d/exe' % pid).resolve()
                if str(FIXTURE).encode() in command or executable == Path('/usr/bin/zls'):
                    stamp = process_stamp(pid)
                    if stamp is None:
                        continue
                    self.server_processes[pid] = stamp
                    self.evidence.setdefault('server_processes', []).append(
                        dict(case=self.name, pid=pid, starttime=stamp,
                             argv=[part.decode(errors='replace') for part in command if part]))
            except (FileNotFoundError, ProcessLookupError):
                pass
        return self.server_processes.copy()

    def assert_reaped(self, processes=None):
        processes = self.server_processes if processes is None else processes
        wait_for(lambda: all(process_stamp(pid) != stamp for pid, stamp in processes.items()), 10)
        self.evidence.setdefault('reaped', []).append(dict(case=self.name, pids=list(processes)))

    def log_paths(self):
        return sorted(self.logs.glob('*.jsonl'))

    def records(self, prefix=None):
        paths = self.log_paths()
        if prefix:
            paths = [p for p in paths if p.name.startswith(prefix.stem + '.')]
        return [(path, record) for path in paths for record in transcript(path)]

    def messages(self, method=None, kind='receive', prefix=None):
        return [r['message'] for _, r in self.records(prefix) if r['kind'] == kind and
                (method is None or r['message'].get('method') == method)]

    def traffic(self, method, count=1, timeout=12, kind='receive'):
        return wait_for(lambda: found if len(found := self.messages(method, kind)) >= count else None, timeout)

    def select_position(self, index, end=None):
        self.command('select', start=index, end=index if end is None else end)

    def focus_document(self, path):
        self.open_document(path)
        self.select(self.target, focus=True)
        self.action('win.focus-editor')

    def canonical_text(self, path=None):
        return self.document(path or self.main)['text']

    def check_disk_unchanged(self):
        self.verify_files()

    def review(self):
        p = self.result('review', 20)
        assert p['review'] and 'Files are NOT saved' in p['popup'], p
        self.check_disk_unchanged()
        return p

    def apply_review(self, native=False):
        self.review()
        if native:
            self.click_dialog('Language: Review edits')
        else:
            self.accept()
        p = self.wait_language(lambda p: not p['review'] and not p['dialog'])
        assert 'applied' in p['status'].lower(), p
        self.check_disk_unchanged()
        return p

    def restore_grouped(self, texts):
        self.action('win.grouped-undo')
        wait_for(lambda: all(self.canonical_text(path) == text for path, text in texts.items()))
        self.check_disk_unchanged()

    def stop_language(self):
        self.invoke('stop')
        p = self.wait_language(lambda p: p['session_count'] == 0 and p['pending'] is None)
        assert not p['review'] and not p['server_review'] and not p['navigation'], p
        self.assert_reaped()
        return self.wait_language(lambda p: p['automatic']['paused'] and p['automatic']['pause_writes'] == 0
                                  and p['config_check'] is None and not p['config_queued'])

    def evidence_snapshot(self, label):
        self.evidence.setdefault('observations', []).append(dict(
            case=self.name, label=label, language=self.language(), workspace=self.state(), policy=self.probe('policy')))

    def stop(self):
        if self.app is not None and self.app.proc.poll() is None:
            p = self.language()
            if p['dialog'] or p['pending'] is not None or p['review_loading']:
                self.command('language-reject')
                self.wait_language(lambda p: not p['dialog'] and not p.get('resource_review', False))
        super().stop()
        self.assert_reaped()


# Security and lifecycle cases are separate so a failure cannot hide another.
def trusted_start(h):
    h.configure(marker=True)
    h.fixture()
    h.invoke('start', palette=True)
    p = h.language()
    assert p['session_count'] == 0 and not p['dialog'], p
    assert 'Restricted' in p['status'] or 'Trust' in p['status'], p
    assert not h.marker.exists() and not h.log_paths(), 'Restricted start spawned a process'
    h.trust()
    assert not h.marker.exists(), 'Trust confirmation auto-launched a server'
    h.automatic_review()
    h.reject()
    assert not h.marker.exists(), 'Rejected start spawned a process'
    h.start(native=True)
    assert json.loads(h.marker.read_text())['fixture'] == 'coral-fake-lsp'
    initialization = h.traffic('initialize')[0]
    capabilities = initialization['params']['capabilities']
    assert capabilities['textDocument']['completion']['completionItem']['snippetSupport'] is False
    h.invoke('hover', palette=True)
    assert 'Fixture hover' in h.result('info')['popup']
    h.screenshot('hover-native')
    h.reject()
    h.stop_language()


def automatic_detection(h):
    value = h.configure()
    python = dict(value['servers'][0], language='python3')
    value['servers'].append(python)
    h.config.write_text(json.dumps(value))
    h.fixture()
    # An active unsupported document must not hide eligible background documents.
    unsupported = h.write(h.roots[0] / 'notes.txt', 'plain text\n')
    h.open_document(unsupported)
    h.trust()
    review = h.automatic_review()
    assert review['session_count'] == 0 and not h.log_paths() and not h.remember_processes(), review
    h.click_dialog('Language: Start')
    first = h.ready_language()['sessions'][0]
    assert first['language'] == 'zig', first
    h.focus_document(h.other)
    h.wait_language(lambda p: len(p['sessions'][0]['documents']) == 2)
    h.action('win.split-group')
    h.focus_document(h.main)
    h.wait_language(lambda p: p['sessions'][0]['id'] == first['id'] and
                    len(p['sessions'][0]['documents']) == 2)
    assert len(h.messages('initialize')) == 1
    assert {m['params']['textDocument']['uri'] for m in h.traffic('textDocument/didOpen', 2)} == {
        h.main.as_uri(), h.other.as_uri()}
    # Detection changes must discover a new language and reuse the old session
    # when the document returns to Zig, rather than spawn per view or focus.
    h.command('policy-language', 'python3')
    changed = h.automatic_review()
    assert changed['automatic']['approval_key'] != review['automatic']['approval_key']
    assert len(h.messages('initialize')) == 1
    h.click_dialog('Language: Start')
    p = h.ready_language(2)
    assert {s['language'] for s in p['sessions']} == {'zig', 'python3'}, p
    h.command('policy-language', 'zig')
    p = h.wait_language(lambda p: any(s['id'] == first['id'] and len(s['documents']) == 2 for s in p['sessions']))
    assert p['session_count'] == 2 and len(h.messages('initialize')) == 2, p
    h.evidence_snapshot('automatic-detection-and-session-reuse')


def automatic_decline(h):
    h.configure()
    h.fixture()
    h.trust()
    review = h.automatic_review()
    h.click_dialog('Language: Start', approve=False)
    h.open_document(h.other)
    h.action('win.split-group')
    p = h.stays_stopped()
    assert any(c['reason'] == 'declined-or-review-owned' for c in p['automatic']['candidates']), p
    assert not h.log_paths() and not h.remember_processes()
    first = h.target
    h.new_window()
    h.workspace(h.roots[0])
    h.open_document(h.main)
    assert h.policy_idle()['trust'] == 'trusted'
    h.stays_stopped()  # same declined configuration cannot nag in another window
    h.invoke('start', palette=True)
    assert h.automatic_review()['automatic']['approval_key'] == review['automatic']['approval_key']
    h.click_dialog('Language: Start')
    h.ready_language()

    with h.at(first):
        h.ready_language()
    h.evidence_snapshot('decline-suppressed-until-explicit-start')


def automatic_failure(h, initialize=False):
    if initialize:
        h.configure('timeout', options=('--target-method', 'initialize'))
        h.fixture()
        h.trust()
        h.automatic_review()
        h.click_dialog('Language: Start')
        h.wait_language(lambda p: p['session_count'] == 1)
        h.remember_processes()
    else:
        h.setup('crash')
        h.invoke('hover')
    h.wait_language(lambda p: p['session_count'] == 0, 35)
    h.assert_reaped()
    h.focus_document(h.other)
    p = h.stays_stopped()
    assert any(c['reason'] == 'restart-required' for c in p['automatic']['candidates']), p
    assert len(h.log_paths()) == len(h.messages('initialize')) == 1
    if not initialize:
        h.invoke('restart', palette=True)
        h.ready_language()
        assert len(h.messages('initialize')) == 2
    h.evidence_snapshot('initialization-timeout-suppressed' if initialize else 'crash-suppressed-and-explicit-retry')


def automatic_restore_pause(h):
    h.setup()
    h.open_document(h.other)
    h.wait_language(lambda p: len(p['sessions'][0]['documents']) == 2)
    h.action('win.save-workspace-session')
    wait_for(lambda: h.probe('session')['status'] == 'saved')
    h.stop()
    h.launch()
    p = h.ready_language()  # neither Start nor approval: durable approval reused
    assert {d['uri'] for d in p['sessions'][0]['documents']} == {h.main.as_uri(), h.other.as_uri()}, p
    assert len(h.messages('initialize')) == 2
    h.stop_language()
    h.command('workspace-rescan')
    h.policy_idle()
    h.focus_document(h.other)
    h.stays_stopped(paused=True)
    h.stop()
    h.launch()
    h.policy_idle()
    h.wait_language(lambda p: p['automatic']['paused'])
    h.stays_stopped(paused=True)
    assert h.document(h.main) and h.document(h.other), 'full documents must restore while paused'
    assert len(h.messages('initialize')) == 2
    for action in ('start', 'restart'):
        h.invoke(action, palette=True)
        p = h.ready_language()
        assert not p['automatic']['paused'], p
        h.stop_language()
    assert len(h.messages('initialize')) == 4
    h.evidence_snapshot('durable-approval-and-pause-across-processes')


def automatic_windows(h):
    h.setup()
    first = h.target
    second = h.new_window()
    h.workspace(h.roots[0])
    h.open_document(h.main)
    assert h.policy_idle()['trust'] == 'trusted'
    h.ready_language()
    h.new_window()
    alternate = h.write(h.fixtures / 'unrelated/main.zig', TEXT)
    h.workspace(alternate.parent)
    h.open_document(alternate)
    assert h.policy_idle()['trust'] == 'restricted'
    h.stays_stopped()  # exact executable approval is not workspace trust
    assert len(h.messages('initialize')) == 2
    h.trust()
    independent = h.ready_language()['sessions'][0]['id']
    with h.at(first):
        h.invoke('stop')
        h.wait_language(lambda p: p['session_count'] == 0 and p['automatic']['paused'] and
                        p['automatic']['pause_writes'] == 0)
    with h.at(second):
        h.wait_language(lambda p: p['session_count'] == 0 and p['automatic']['paused'])
        h.stays_stopped(paused=True)
    assert h.language()['sessions'][0]['id'] == independent, 'Stop leaked into another workspace'
    with h.at(second):
        h.invoke('restart')
        h.ready_language()
    with h.at(first):
        h.ready_language()
    assert len(h.messages('initialize')) == 5
    h.evidence_snapshot('shared-workspace-pause-and-independent-trust')


def automatic_changed_approval(h, executable=False):
    value = h.configure()
    if executable:
        binary = h.fixtures / 'fixture-python'
        shutil.copyfile(sys.executable, binary)
        binary.chmod(0o700)
        value['servers'][0]['argv'][0] = str(binary)
        h.config.write_text(json.dumps(value))
    h.fixture()
    h.trust()
    old_key = h.automatic_review()['automatic']['approval_key']
    h.click_dialog('Language: Start')
    old_session = h.ready_language()['sessions'][0]['id']
    processes = h.remember_processes()
    if executable:
        # Replace with byte-identical content: identity, not only argv/config
        # bytes, must revoke approval. Never modify the system interpreter.
        replacement = binary.with_suffix('.replacement')
        shutil.copyfile(sys.executable, replacement)
        replacement.chmod(0o700)
        os.replace(replacement, binary)
    else:
        value['servers'][0]['env']['CORAL_TEST_CHANGED_CONFIG'] = '1'
        h.config.write_text(json.dumps(value))
    p = h.automatic_review()
    h.wait_language(lambda p: p['session_count'] == 0)
    h.assert_reaped(processes)
    assert p['automatic']['approval_key'] != old_key, p
    assert len(h.messages('initialize')) == 1, 'changed configuration executed before approval'
    h.click_dialog('Language: Start')
    assert h.ready_language()['sessions'][0]['id'] != old_session
    assert len(h.messages('initialize')) == 2
    h.evidence_snapshot('executable-identity-reapproval' if executable else 'configuration-reapproval')


def automatic_storage_failure(h):
    h.configure()
    h.fixture()
    h.trust()
    h.automatic_review()
    state = Path(h.session.env['XDG_STATE_HOME']) / 'coral/language'
    state.symlink_to(h.fixtures)
    h.click_dialog('Language: Start')
    h.wait_language(lambda p: p['config_check'] is None and not p['dialog'])
    h.stays_stopped()
    assert not h.log_paths() and not h.remember_processes()
    state.unlink()
    h.stays_stopped(seconds=6)
    h.start(native=True)
    h.evidence_snapshot('unsafe-approval-storage-fails-closed-until-explicit-retry')


def approval_location_not_cwd(h):
    h.stop()
    home = Path(h.session.env['HOME'])
    state = home / '.local/state'
    state.mkdir(parents=True, mode=0o700)
    h.session.env['XDG_STATE_HOME'] = str(state)
    h.store = state / 'coral/trust/store'
    h.app_cwd = home
    h.launch()
    assert Path('/proc/%d/cwd' % h.app.proc.pid).resolve() == home.resolve()
    target = state / 'coral/language'
    assert target.is_relative_to(home), 'old cwd guard must reject this fixture layout'
    h.setup(native=True)  # automatic review and a real approval click, no Start
    assert (target / 'store').is_file() and h.store.is_file()
    assert len(h.messages('initialize')) == 1
    h.evidence_snapshot('approval-with-state-under-disposable-home-cwd')
    h.stop()
    h.launch()
    assert Path('/proc/%d/cwd' % h.app.proc.pid).resolve() == home.resolve()
    h.ready_language()  # persisted approval plus restored document, no Start/accept
    assert len(h.messages('initialize')) == 2
    approved = (target / 'store').read_bytes()

    # The sibling trust store is outside the forbidden root/base, so trust must
    # succeed. Only the language controller's actual-target guard can reject it.
    assert h.store.parent.parent == target.parent
    assert not h.store.resolve().is_relative_to(target.resolve())
    source = h.write(target / 'main.zig', TEXT)
    manifest = h.write(target / 'unsafe.coral-workspace', json.dumps({
        'version': 1, 'roots': [{'path': str(h.roots[0])}]}))
    alias = h.fixtures / 'approval-store-alias'
    alias.symlink_to(target, target_is_directory=True)
    for kind in ('root', 'manifest'):
        if kind == 'root':
            browser = h.workspace(alias)
            assert browser['roots'][0]['canonical'] == str(target.resolve()), browser
            h.open_document(source)
        else:
            h.command('open-workspace', alias / manifest.name)
            h.browser()
            h.open_document(h.main)
        h.trust()
        assert h.policy_idle()['trust'] == 'trusted'
        p = h.wait_language(lambda p: p['session_count'] == 0 and
                            'StateInsideWorkspace' in p['status'])
        assert not p['dialog'] and p['config_check'] is None and not p['config_queued'], p
        h.assert_reaped()
        h.invoke('start')  # explicit Start cannot bypass the same admission guard
        h.wait_language(lambda p: 'StateInsideWorkspace' in p['status'])
        h.stays_stopped()
        assert (target / 'store').read_bytes() == approved, 'rejected location changed approval storage'
        assert len(h.messages('initialize')) == 2, 'server executed with approval storage inside workspace'
        assert h.policy_idle()['trust'] == 'trusted', 'test accidentally exercised the trust-store guard'
        h.evidence_snapshot('approval-target-rejected-as-canonical-' + kind)


def policy_stop(h, change):
    h.setup(roots=2 if change == 'root-list' else 1)
    before = h.remember_processes()
    if change == 'revoke':
        h.action('win.workspace-revoke')
    elif change == 'switch':
        alternate = h.write(h.fixtures / 'different/main.zig', TEXT).parent
        h.command('open-folder', alternate)
    elif change == 'close':
        h.action('win.close-workspace')
    elif change == 'root-list':
        h.command('explorer-reset')
        h.browser()
        h.action('win.focus-explorer')
        h.key('Home')
        h.action('win.workspace-remove-root')
        wait_for(lambda: h.probe('roots')['state'] == 'confirming')
        h.command('roots-respond', 'accept')
        result = wait_for(lambda: p if not (p := h.probe('roots'))['busy'] else None)
        assert result['state'] == 'succeeded', result
        updated = json.loads(h.manifest.read_text())
        assert [root['path'] for root in updated['roots']] == [str(h.roots[1])], updated
        h.expected[h.manifest] = digest(h.manifest.read_bytes())
    elif change == 'root-identity':
        root = h.roots[0]
        root.rename(root.with_name('retired-root'))
        root.mkdir()
        # The same pathname now identifies a different root incarnation.
        for old in list(h.expected):
            if old.is_relative_to(root):
                h.expected[root.with_name('retired-root') / old.relative_to(root)] = h.expected.pop(old)
        h.write(root / 'main.zig', TEXT)
        h.command('workspace-rescan')
    elif change == 'config':
        h.configure('utf8')
    elif change == 'root-policy':
        h.write(h.roots[0] / '.coral/settings.json', json.dumps({'version': 1, 'settings': {'indent': 2}}))
        h.command('workspace-rescan')
    else:
        raise AssertionError(change)
    h.wait_language(lambda p: p['session_count'] == 0)
    h.assert_reaped(before)
    assert not h.language()['review']
    h.evidence_snapshot('policy-invalidation:' + change)


def sync_case(h, sync, encoding):
    # File names exercise percent encoding; file bytes exercise newline normalization.
    h.configure(options=('--sync', sync, '--encoding', encoding))
    h.fixture(text='const café = "😀";\r\n// aέ😀z', filename='unicode café #.zig')
    h.trust()
    started = h.start()
    canonical = h.canonical_text()
    opened = h.traffic('textDocument/didOpen')[-1]['params']['textDocument']
    assert opened['uri'] == h.main.resolve().as_uri(), opened
    assert opened['text'] == canonical and '\r' not in canonical, opened
    assert opened['languageId'] == 'zig'
    h.focus_document(h.main)
    h.key('End', 'ctrl')
    h.text('終')
    expected = canonical + '終'
    wait_for(lambda: h.canonical_text() == expected)
    changed = h.traffic('textDocument/didChange')[-1]['params']
    assert changed['textDocument']['version'] > opened['version'], changed
    assert len(changed['contentChanges']) == 1
    edit = changed['contentChanges'][0]
    assert edit['text'] == expected, edit
    if sync == 'incremental':
        assert edit['range'] == {'start': {'line': 0, 'character': 0}, 'end': text_end(canonical, encoding)}, edit
    else:
        assert 'range' not in edit, edit
    # A second canonical view must not send a duplicate didOpen.
    h.action('win.split-group')
    h.action('win.language-hover')
    h.result('info')
    h.reject()
    docs, versions = replay(h.messages(), encoding)
    assert docs[h.main.as_uri()] == expected
    assert len(h.messages('textDocument/didOpen')) == 1
    assert h.language()['sessions'][0]['id'] == started['sessions'][0]['id']
    h.evidence_snapshot(sync + ':' + encoding)
    h.stop_language()


def large_document_sync(h, sync, size):
    # Exact UTF-8 byte sizes, astral characters, and many moderately sized lines.
    # Each action is submitted once: waits observe traffic, never resend it or
    # restart a failed session to conceal transport pressure.
    row = '// café 😀 ' + 'x' * 240 + '\n'
    count, remainder = divmod(size - len(TEXT.encode()), len(row.encode()))
    text = TEXT + row * count + ('//' + 'x' * (remainder - 3) + '\n'
                                if remainder >= 3 else ' ' * remainder)
    assert len(text.encode()) == size
    started_at = time.monotonic()
    started = h.setup('late', text=text, options=(
        '--sync', sync, '--encoding', 'utf-16', '--delay-ms', '8000'))
    session_id = started['sessions'][0]['id']
    opened = h.traffic('textDocument/didOpen')[0]['params']['textDocument']
    assert opened['text'] == text and opened['uri'] == h.main.as_uri()
    assert opened['version'] == 1
    open_elapsed = time.monotonic() - started_at

    h.select_position(2)
    h.invoke('hover')
    hover = h.traffic('textDocument/hover')[0]
    h.select_position(len(text))
    suffix = '\n// saved 終😀\n'
    changed_at = time.monotonic()
    h.command('insert', suffix)
    # Save immediately, without waiting for didChange or transport drainage.
    h.action('win.save')
    expected = text + suffix
    saved = h.traffic('textDocument/didSave', timeout=25)[0]['params']
    save_elapsed = time.monotonic() - changed_at
    assert saved['textDocument']['uri'] == h.main.as_uri()
    assert saved['text'] == expected
    wait_for(lambda: not h.document(h.main)['dirty'], 15)
    assert h.canonical_text() == expected and h.main.read_text() == expected
    h.expected[h.main] = digest(expected.encode())

    changes = h.messages('textDocument/didChange')
    assert len(changes) == 1, ('duplicate change / retry', len(changes))
    changed = changes[0]['params']
    assert changed['textDocument']['version'] == opened['version'] + 1
    assert len(changed['contentChanges']) == 1
    edit = changed['contentChanges'][0]
    assert edit['text'] == expected
    if sync == 'incremental':
        assert edit['range'] == {'start': {'line': 0, 'character': 0},
                                 'end': text_end(text, 'utf-16')}
    else:
        assert 'range' not in edit
    messages = h.messages()
    methods = [m.get('method') for m in messages]
    assert methods.index('textDocument/didOpen') < methods.index('textDocument/hover')
    assert methods.index('textDocument/hover') < methods.index('$/cancelRequest')
    assert methods.index('$/cancelRequest') < methods.index('textDocument/didChange')
    assert methods.index('textDocument/didChange') < methods.index('textDocument/didSave')
    assert h.messages('$/cancelRequest')[0]['params']['id'] == hover['id']
    documents, versions = replay(messages, 'utf-16')
    assert documents == {h.main.as_uri(): expected}
    assert versions == {h.main.as_uri(): opened['version'] + 1}

    # This peer deliberately sends the obsolete reply despite cancellation.
    wait_for(lambda: any(m.get('id') == hover['id'] and 'result' in m
                         for m in h.messages(kind='send')), 15)
    time.sleep(.3)  # observe after the native poll; this is not a latency assertion
    p = h.wait_language(lambda p: p['pending'] is None)
    assert not p['dialog'] and not p['rows'] and not p['review'], p
    assert len(p['sessions']) == 1 and p['sessions'][0]['id'] == session_id
    assert p['sessions'][0]['state'] == 'ready'
    assert p['sessions'][0]['documents'][0]['version'] == opened['version'] + 1
    assert any(r['kind'] == 'cancel-ignored' and r['id'] == hover['id'] for _, r in h.records())
    # A fresh request proves the same server remains usable after open/change/save.
    h.invoke('document-symbols')
    assert h.result('picker')['rows']
    h.reject()
    assert len(h.messages('initialize')) == len(h.messages('textDocument/didOpen')) == 1
    assert len(h.messages('textDocument/didChange')) == len(h.messages('textDocument/didSave')) == 1
    assert len(h.log_paths()) == 1
    h.evidence.setdefault('large_document_sync', []).append(dict(
        case=h.name, bytes=size, sync=sync, encoding='utf-16', session=session_id,
        version=versions[h.main.as_uri()], open_workflow_seconds=open_elapsed,
        change_save_observed_seconds=save_elapsed, stale_response_id=hover['id']))
    h.check_disk_unchanged()
    h.stop_language()


def large_document_message_limit(h):
    # Below the 8 MiB snapshot budget and the controller's character guard, but
    # over the unchanged 4 MiB JSON body limit. No truncated frame may be sent.
    text = TEXT + '// ' + '😀' * (1024 * 1024) + '\n'
    h.configure()
    h.fixture(text=text)
    h.trust()
    h.invoke('start')
    h.result('start')
    h.accept()
    p = h.wait_language(lambda p: p['session_count'] == 0 and
                        'MessageTooLarge' in p['status'], 25)
    status = p['status']
    assert 'synchronization failure: MessageTooLarge' in status, status
    assert len(h.traffic('initialize')) == 1
    assert not h.messages('textDocument/didOpen')
    time.sleep(.4)  # many former 20ms retry opportunities
    p = h.language()
    assert p['session_count'] == 0 and p['status'] == status, p
    assert len(h.log_paths()) == 1 and len(h.messages('initialize')) == 1
    assert not h.messages('textDocument/didChange')
    h.check_disk_unchanged()


def did_save(h):
    h.setup()
    session_id = h.language()['sessions'][0]['id']
    h.focus_document(h.main)
    h.key('End', 'ctrl')
    h.text('// saved café 😀')
    expected = h.canonical_text()
    h.key('s', 'ctrl')
    wait_for(lambda: not h.document(h.main)['dirty'])
    h.expected[h.main] = digest(expected.encode())
    assert h.main.read_text() == expected
    message = h.traffic('textDocument/didSave')[-1]['params']
    assert message['textDocument']['uri'] == h.main.as_uri() and message['text'] == expected, message
    # Wait through the watcher debounce/recheck; not merely the immediate save callback.
    h.browser()
    h.policy_idle()
    p = h.language()
    assert [s['id'] for s in p['sessions']] == [session_id], ('didSave stopped/restarted session', p)
    h.invoke('hover')
    assert 'Fixture hover' in h.result()['popup']
    h.reject()


def diagnostics_current(h):
    h.setup()
    initial = h.wait_language(lambda p: p['diagnostics'] == 1)
    document = initial['sessions'][0]['documents'][0]
    assert document['verified'] and document['diagnostics'] == 1, document
    old_version = document['version']
    h.focus_document(h.main)
    h.key('Home', 'ctrl')
    h.text('x')
    h.traffic('textDocument/didChange')
    p = h.wait_language(lambda p: p['diagnostics'] == 1 and
                       p['sessions'][0]['documents'][0]['version'] > old_version)
    current = p['sessions'][0]['documents'][0]
    diagnostic = h.messages('textDocument/publishDiagnostics', kind='send')[-1]['params']
    assert diagnostic['version'] == current['version'] and current['verified'], (diagnostic, current)
    assert diagnostic['uri'] == h.main.as_uri()
    h.invoke('problems')
    assert any('Fixture diagnostic' in row for row in h.result('picker')['rows'])
    h.reject()


def superseded_hover(h):
    h.setup('late', options=('--delay-ms', '1300'))
    h.invoke('hover')
    request_id = h.traffic('textDocument/hover')[-1]['id']
    h.invoke('signature')
    expected = h.result('info')['popup']
    assert 'greet(' in expected
    cancellations = h.traffic('$/cancelRequest')
    assert any(m['params']['id'] == request_id for m in cancellations), cancellations
    wait_for(lambda: any(r['kind'] == 'send' and r['message'].get('id') == request_id
                         for _, r in h.records()), 5)
    time.sleep(.1)
    p = h.language()
    assert p['pending'] is None and p['popup'] == expected, p
    h.reject()


def fault_case(h, mode):
    h.setup(mode)
    old = h.language()['sessions'][0]['id']
    processes = h.remember_processes()
    h.invoke('hover')
    if mode == 'timeout':
        p = h.wait_language(lambda p: p['pending'] is None and 'timed out' in p['status'], 36)
        assert p['session_count'] == 1, p
        h.invoke('definition')
        h.result('picker')
        h.reject()
    elif mode == 'fragmented':
        assert 'Fixture hover' in h.result('info')['popup']
        h.reject()
    else:
        p = h.wait_language(lambda p: p['session_count'] == 0, 15)
        assert p['pending'] is None and not p['review'], p
        h.assert_reaped(processes)
        assert any(word in p['status'].lower() for word in ('reaped', 'crash', 'failed', 'language:')), p
    # Explicit Restart must recover using the existing exact approval.
    h.invoke('restart')
    p = h.language()
    if p['dialog'] and p['mode'] == 'start':
        h.accept()
    p = h.wait_language(lambda p: p['session_count'] == 1 and p['sessions'][0]['state'] == 'ready' and
                       p['sessions'][0]['id'] != old, 25)
    h.remember_processes()
    h.invoke('signature')  # unrelated to target fault
    assert 'greet(' in h.result('info')['popup']
    h.reject()
    assert len(h.log_paths()) >= 2, h.log_paths()
    h.evidence_snapshot(mode + ':restarted')


def features_read(h):
    h.setup(native=True)
    h.invoke('status', palette=True)
    assert h.result('info')['popup']
    h.reject()
    for action, expected in [('hover', 'Fixture hover'), ('signature', 'greet(')]:
        h.invoke(action, palette=True)
        assert expected in h.result('info')['popup']
        h.reject()
    for action in ['definition', 'references', 'document-symbols', 'workspace-symbols']:
        h.focus_document(h.main)
        h.select_position(8)
        h.invoke(action)
        if action == 'workspace-symbols':
            h.result('workspace_query')
            h.accept('fixture')
        p = h.result('picker')
        assert p['rows'], (action, p)
        h.accept(1 if action == 'references' else 0)
        target = h.other if action == 'references' else h.main
        wait_for(lambda: h.active()[0]['path'] == str(target))
        h.wait_language(lambda p: not p['navigation'])
        if target == h.main:
            view = h.active()[1]
            assert {view['insertion'], view['bound']} == {0, 5}, view
    h.invoke('problems')
    p = h.result('picker')
    assert any('Fixture diagnostic' in row for row in p['rows']), p
    h.reject()
    # Missing capabilities are explicit unavailable notices, not fabricated results.
    for action in ['declaration', 'type-definition', 'implementation']:
        h.invoke(action)
        assert 'unavailable' in h.language()['status'], h.last_language
    h.screenshot('navigation-and-status')


def completion(h):
    h.setup()
    original = h.canonical_text()
    h.invoke('completion', palette=True)
    p = h.result('picker')
    assert p['rows'] == ['fixtureCall'], p
    h.accept(0)
    h.review()
    assert 'fixtureCall(name)' in h.last_language['popup'], h.last_language
    h.apply_review(native=True)
    expected = 'fixtureCall(name)' + original + '\n// fixture import\n'
    assert h.canonical_text() == expected, h.canonical_text()
    assert '${' not in h.canonical_text() and h.document(h.main)['dirty']
    h.restore_grouped({h.main: original})


def edit_case(h, action):
    h.setup(text='const greeting = "aé😀z";  \nconst answer = 42;  \n')
    main, other = h.canonical_text(), h.other.read_text()
    h.invoke(action, palette=True)
    if action == 'rename':
        h.result('rename')
        h.accept('renamed_name')
    elif action == 'code-actions':
        assert h.result('picker')['rows']
        h.accept(0)
    h.review()
    h.screenshot(action + '-review')
    h.apply_review()
    if action == 'formatting':
        assert h.canonical_text() == '\n'.join(line.rstrip() for line in main.split('\n'))
    else:
        replacement = 'renamed_name' if action == 'rename' else 'renamed'
        assert h.canonical_text() == replacement + main[5:]
        assert h.canonical_text(h.other) == '// fixture second file\n' + other
    h.restore_grouped({h.main: main, **({h.other: other} if action != 'formatting' else {})})
    if action == 'formatting':
        h.focus_document(h.main)
        h.key('Home', 'ctrl')
        h.key('End', 'shift')
        h.invoke('range-formatting')
        h.review()
        h.apply_review()
        assert h.canonical_text().split('\n')[0] == main.split('\n')[0].rstrip()


def advanced(h):
    h.setup()
    for index, method in enumerate(['textDocument/semanticTokens/full', 'textDocument/semanticTokens/full/delta']):
        h.invoke('semantic-tokens')
        h.traffic(method)
        p = h.wait_language(lambda p: p['pending'] is None and 'Applied' in p['status'])
        assert p['sessions'][0]['documents'][0]['semantic_tokens'] == 1, p
    h.invoke('inlay-hints')
    assert any(': u8' in row for row in h.result('picker')['rows'])
    h.accept(0)
    h.wait_language(lambda p: not p['navigation'])
    h.invoke('code-lenses')
    assert h.result('picker')['rows'] == ['Resolve code lens…']
    h.accept(0)
    assert 'fake.applyEdit' in h.result('command')['popup']
    h.traffic('codeLens/resolve')
    h.reject()  # commands need their own independent approval
    assert not h.messages('workspace/executeCommand')
    h.invoke('document-links')
    h.result('picker')
    h.accept(0)
    assert h.result('external')['popup'] == 'https://example.invalid/fixture'
    h.traffic('documentLink/resolve')
    h.reject()  # never launch a browser, even on the private desktop
    h.check_disk_unchanged()


def server_apply_edit(h, approve):
    h.setup('commands')
    original, other = h.canonical_text(), h.other.read_text()
    h.invoke('code-actions')
    h.result('picker')
    h.accept(0)
    h.result('command')
    h.accept()
    p = h.review()
    assert p['server_review'], p
    if approve:
        h.apply_review()
    else:
        h.reject()
    replies = wait_for(lambda: rows if (rows := [r['message'] for _, r in h.records()
                                               if r['kind'] == 'server-response']) else None)
    assert replies[-1]['result']['applied'] is approve, replies
    if approve:
        assert h.canonical_text() == 'renamed' + original[5:]
        assert h.canonical_text(h.other) == '// fixture second file\n' + other
        h.restore_grouped({h.main: original, h.other: other})
    else:
        assert h.canonical_text() == original and h.canonical_text(h.other) == other
    h.check_disk_unchanged()


def stale_case(h, kind):
    if kind == 'diagnostics-edits':
        h.setup('stale')
        h.traffic('textDocument/publishDiagnostics', kind='send')
        h.invoke('hover')
        h.result('info')
        h.reject()
        assert h.language()['diagnostics'] == 0, h.last_language
        original = h.canonical_text()
        h.invoke('rename')
        h.result('rename')
        h.accept('must_not_apply')
        p = h.wait_language(lambda p: p['pending'] is None and not p['review_loading'] and
                            'Version' in p['status'])
        assert not p['dialog'] and h.canonical_text() == original, p
    elif kind in ('hover', 'completion'):
        method = 'textDocument/' + kind
        h.setup('late', options=('--target-method', method, '--delay-ms', '1500'))
        original = h.canonical_text()
        h.invoke(kind)
        h.traffic(method)
        h.select_position(len(original))
        h.command('insert', '// changed')
        h.traffic('$/cancelRequest')
        h.wait_language(lambda p: p['pending'] is None)
        time.sleep(1.6)
        p = h.language()
        assert not p['dialog'] and not p['rows'] and not p['review'], p
        assert h.canonical_text() == original + '// changed'
    elif kind == 'review':
        h.setup()
        h.invoke('formatting')
        h.review()
        # Setup mutation bypasses modal input intentionally; Apply must still
        # revalidate the canonical revision, not rely solely on modal UI.
        h.select_position(0)
        h.command('insert', '// intervening\n')
        before = h.canonical_text()
        h.accept()
        p = h.language()
        assert not p['review'] and ('Stale' in p['status'] or 'Changed' in p['status']), p
        assert h.canonical_text() == before
    h.check_disk_unchanged()


def hostile(h, kind):
    options = ('--outsideRoot',) if kind == 'outside-root' else ('--malicious',)
    h.setup('commands' if kind == 'malicious' else 'default', options=options)
    before = h.canonical_text()
    if kind == 'outside-root':
        h.invoke('rename')
        h.result('rename')
        h.accept('forbidden')
        p = h.wait_language(lambda p: p['pending'] is None and 'Outside' in p['status'])
        assert not p['review'] and not p['dialog'], p
    else:
        h.invoke('hover')
        assert '<script>' in h.result('info')['popup'], 'Untrusted payload must be inert plain text'
        h.reject()
        h.invoke('code-actions')
        h.result('picker')
        h.accept(0)
        p = h.language()
        assert 'NotAdvertised' in p['status'] and not p['dialog'], p
        assert not h.messages('workspace/executeCommand')
        h.invoke('document-links')
        h.result('picker')
        h.accept(0)
        p = h.wait_language(lambda p: p['pending'] is None and 'SchemeUnsupported' in p['status'])
        assert not p['dialog'], p
    assert h.canonical_text() == before
    h.check_disk_unchanged()


def roots_and_windows(h, shared=False):
    h.setup(roots=1 if shared else 2)
    first = h.target
    initial = h.language()['sessions'][0]['id']
    if not shared:
        h.focus_document(h.roots[1] / 'main.zig')
        h.start(count=2)
        p = h.language()
        assert len({s['root'] for s in p['sessions']}) == 2, p
        for s in p['sessions']:
            assert all(Path(unquote(urlsplit(d['uri']).path)).is_relative_to(Path(s['path']))
                       for d in s['documents']), s
    second = h.new_window(keyboard=True)
    h.workspace(h.roots[0])
    h.open_document(h.main)
    if not shared:
        confirm_scope(h)  # folder scope differs from the first window's manifest
    else:
        assert h.policy_idle()['trust'] == 'trusted'
    h.start()
    second_session = h.language()['sessions'][0]['id']
    assert second_session != initial
    h.focus_document(h.main)
    h.key('End', 'ctrl')
    h.text('// second window')
    h.traffic('textDocument/didChange')
    second_text = h.canonical_text()
    with h.at(first):
        assert h.canonical_text() == TEXT, 'canonical documents leaked across windows'
        assert h.language()['sessions'][0]['id'] == initial
    if shared:
        h.action('win.workspace-revoke', first)
        h.wait_language(lambda p: p['session_count'] == 0)
        with h.at(first):
            h.wait_language(lambda p: p['session_count'] == 0)
        assert h.probe('policy')['trust'] == 'restricted'
        h.assert_reaped()
    else:
        h.invoke('stop')
        h.wait_language(lambda p: p['session_count'] == 0)
        with h.at(first):
            assert h.language()['session_count'] == 2, 'stopping one window stopped another'
    assert h.canonical_text() == second_text
    h.evidence_snapshot('window-isolation')


def close_pending(h):
    h.setup('late', options=('--delay-ms', '1800'))
    h.invoke('hover')
    h.traffic('textDocument/hover')
    h.action('win.close')
    wait_for(lambda: h.document(h.main) is None)
    h.traffic('textDocument/didClose')
    h.traffic('$/cancelRequest')
    time.sleep(1.9)
    p = h.language()
    assert not p['dialog'] and p['pending'] is None, p
    h.stop_language()


def close_window_pending(h):
    h.setup('timeout')
    first = h.target
    pids = h.remember_processes()
    second = h.new_window()
    h.select(first, focus=True)
    h.invoke('hover')
    h.traffic('textDocument/hover')
    h.close_window(first, second, keyboard=True)
    h.assert_reaped(pids)
    assert h.language()['session_count'] == 0
    h.drained(1)


def resource_operations(h, kind):
    if 'resource_review' not in h.language():
        raise Blocked('Native binary predates the resource-review public API; rebuild current test hooks')
    operation = kind if kind in ('create', 'rename', 'delete') else 'mixed' if kind == 'mixed' else 'create'
    options = ['--resource-operation', operation]
    if kind == 'overwrite':
        options += ['--resource-option', 'overwrite']
    if kind == 'outside-root':
        options += ['--outside-root-uri', (h.fixtures / 'outside/anchor.zig').as_uri()]
    h.configure('resource', options=options)
    h.fixture()
    source = h.write(h.roots[0] / 'resource-source.zig', 'resource source café 😀\n')
    h.write(h.fixtures / 'outside/sentinel.zig', 'outside root must remain intact\n')
    h.browser()
    h.policy_idle()
    h.trust()
    h.start()
    peer = None
    if kind == 'revoke':
        owner = h.target
        peer = h.new_window()
        h.workspace(h.roots[0])
        assert h.policy_idle()['trust'] == 'trusted'
        h.select(owner, focus=True)
    before = tree(h.fixtures)
    source_bytes = source.read_bytes()
    server_request = kind.startswith('server-')
    h.invoke('code-lenses' if server_request else 'code-actions')
    h.result('picker')
    h.accept(0)
    if server_request:
        h.result('command')
        h.accept()
    if kind in ('mixed', 'overwrite', 'outside-root'):
        error = {'mixed': 'MixedOrMultipleResourceEditsUnsupported',
                 'overwrite': 'ResourceOverwriteOrIgnoreOptionsUnsupported',
                 'outside-root': 'ResourceOutsideSessionRoot'}[kind]
        p = h.wait_language(lambda p: p['pending'] is None and error in p['status'])
        assert not p['resource_review'] and not p['dialog'] and not p['review'], p
        assert tree(h.fixtures) == before
        h.check_disk_unchanged()
        return
    p = h.wait_language(lambda p: p.get('resource_state') == 'confirming' and p['dialog'])
    assert p['resource_review'] and p['mode'] == 'resource' and not p['review'], p
    assert p['resource_kind'] == ('create_file' if operation == 'create' else operation), p
    assert 'no undo' in p['popup'].lower() and 'filesystem' in p['popup'].lower(), p
    assert tree(h.fixtures) == before, 'resource operation mutated disk before approval'
    assert p['server_review'] is server_request, p
    h.screenshot('resource-' + kind + '-review')
    if kind in ('reject', 'server-reject'):
        h.command('language-reject')
    elif kind == 'revoke':
        # The resource owner's modal intentionally blocks ordinary actions.
        # Revoke from a live peer of the same scope to test synchronous policy
        # invalidation while the other window owns an outstanding review.
        h.action('win.workspace-revoke', peer)
    elif kind == 'stale':
        h.select_position(0)
        h.command('insert', '// invalidate resource origin\n')
    else:
        h.accept()
    p = h.wait_language(lambda p: not p['resource_review'], 20)
    ops = wait_for(lambda: p if not (p := h.probe('operations'))['busy'] else None)
    assert ops['jobs_started'] == ops['jobs_reaped'] and not ops['dialog'] and not ops['barrier'], ops
    applied = kind in ('create', 'rename', 'delete', 'server-accept')
    if server_request:
        replies = wait_for(lambda: rows if (rows := [r['message'] for _, r in h.records()
                                                   if r['kind'] == 'server-response']) else None)
        assert replies[-1]['result']['applied'] is applied, replies
    expected = before.copy()
    if applied:
        assert ops['state'] == 'succeeded', ops
        if operation == 'create':
            created = h.roots[0] / 'created.zig'
            assert created.read_bytes() == b''
            h.expected[created] = digest(b'')
            expected['root-0/created.zig'] = {'kind': 'file', 'sha256': digest(b'')}
            method, files = 'workspace/didCreateFiles', [{'uri': created.as_uri()}]
        elif operation == 'rename':
            renamed = h.roots[0] / 'resource-renamed.zig'
            assert not source.exists() and renamed.read_bytes() == source_bytes
            h.expected[renamed] = h.expected.pop(source)
            expected['root-0/resource-renamed.zig'] = expected.pop('root-0/resource-source.zig')
            method, files = 'workspace/didRenameFiles', [{'oldUri': source.as_uri(), 'newUri': renamed.as_uri()}]
        else:
            assert not source.exists()
            h.expected.pop(source)
            del expected['root-0/resource-source.zig']
            method, files = 'workspace/didDeleteFiles', [{'uri': source.as_uri()}]
        assert tree(h.fixtures) == expected, 'resource edit affected unreviewed files'
        message = h.traffic(method)[-1]
        assert message['params']['files'] == files, message
        assert h.language()['file_notifications_queued'] >= 1
    else:
        assert tree(h.fixtures) == before, 'cancelled/stale/revoked resource edit changed files'
        assert not any(h.messages(method) for method in
                       ('workspace/didCreateFiles', 'workspace/didRenameFiles', 'workspace/didDeleteFiles'))
    h.check_disk_unchanged()
    h.evidence_snapshot('resource:' + kind)


def config_directory_replaced(h, review, ancestor=False):
    h.setup('commands' if review == 'command' else 'default', text=TEXT.replace('42;', '42;  '))
    original = h.canonical_text()
    original_document = h.document(h.main)
    processes = h.remember_processes()
    assert processes, 'Regression requires an observed live server before replacing configuration'
    if review == 'text':
        h.invoke('formatting')
        h.review()
    elif review == 'command':
        h.invoke('code-actions')
        h.result('picker')
        h.accept(0)
        h.result('command')
    else:
        assert review == 'idle'
    old_config = h.config.read_bytes()
    directory = h.config.parent.parent if ancestor else h.config.parent
    retired = directory.with_name(directory.name + '-retired')
    relative = h.config.relative_to(directory)
    old_identity = (directory.stat().st_dev, directory.stat().st_ino)
    log_paths = h.log_paths()
    directory.rename(retired)
    h.config.parent.mkdir(parents=True, mode=0o700)
    h.config.write_text('{"version":1,"servers":[]}\n')
    h.config.chmod(0o600)
    assert (directory.stat().st_dev, directory.stat().st_ino) != old_identity
    assert (retired / relative).read_bytes() == old_config
    # No configure(), rescan, restart or explicit stop: those would mask a
    # monitor still watching the old inode. Apply must revalidate even before
    # monitor delivery, and accepting a dismissed screen must be a no-op.
    if review != 'idle':
        h.accept()
    stopped = h.wait_language(lambda p: p['session_count'] == 0 and p['pending'] is None, 12)
    assert not stopped['review'] and not stopped['dialog'] and not stopped['server_review'], stopped
    h.assert_reaped(processes)
    assert h.canonical_text() == original, 'stale config review modified canonical text'
    assert h.document(h.main) == original_document, 'stale config review changed revision/dirty state'
    assert not h.messages('workspace/executeCommand'), 'stale config review dispatched a command'
    h.invoke('start')
    p = h.wait_language(lambda p: p['config_check'] is None and 'LanguageNotConfigured' in p['status'])
    assert not p['dialog'] and p['session_count'] == 0, p
    assert h.log_paths() == log_paths, 'replacement empty configuration launched a new server'
    assert (retired / relative).read_bytes() == old_config
    h.check_disk_unchanged()
    h.evidence_snapshot('renamed-config-directory:' + review)


def chained_root_retarget(h):
    h.configure()
    root0, root1 = h.fixtures / 'root0', h.fixtures / 'root1'
    h.main = h.write(root0 / 'main.zig', TEXT)
    h.other = h.write(root0 / 'other.zig', 'const other = 9;\n')
    h.write(root1 / 'main.zig', 'const alternate = 99;\n')
    middle, alias = h.fixtures / 'middle', h.fixtures / 'alias'
    middle.symlink_to(root0, target_is_directory=True)
    alias.symlink_to(middle, target_is_directory=True)
    h.workspace(alias)
    initial_browser = h.browser()
    assert initial_browser['roots'][0]['path'] == str(alias), initial_browser
    assert initial_browser['roots'][0]['canonical'] == str(root0), initial_browser
    h.open_document(h.main)
    h.trust()
    started = h.start()
    assert started['sessions'][0]['path'] == str(root0), started
    processes = h.remember_processes()
    alias_identity = (alias.lstat().st_dev, alias.lstat().st_ino, os.readlink(alias))
    document_before = h.document(h.main)
    staged = h.fixtures / 'middle-next'
    staged.symlink_to(root1, target_is_directory=True)
    staged.replace(middle)
    assert alias.resolve() == root1
    assert (alias.lstat().st_dev, alias.lstat().st_ino, os.readlink(alias)) == alias_identity
    # Only the interior symlink changes. Neither canonical root nor the top
    # alias is modified, and a test-triggered rescan would hide this regression.
    p = h.wait_language(lambda p: p['session_count'] == 0, 15)
    assert p['pending'] is None and not p['review'] and not p['dialog'], p
    h.assert_reaped(processes)
    policy = h.policy_idle()
    assert policy['trust'] == 'restricted' and not any(policy['permits']), policy
    assert h.document(h.main) == document_before, 'retarget changed the old canonical document'
    h.invoke('start')
    p = h.language()
    assert not p['dialog'] and p['session_count'] == 0, p
    assert len(h.log_paths()) == 1, 'retarget automatically launched a replacement server'
    h.check_disk_unchanged()
    h.evidence_snapshot('interior-symlink-retarget-without-rescan')


def ui_before_initialize(h, operation, value=None):
    before = h.language()
    documents = h.state()['documents']
    assert not before['dialog'] and before['session_count'] == 0
    assert not h.config.exists()
    # Deliberately do not use cleanup's active-dialog guard: the native public
    # test control itself must safely ignore these calls before UI.bind/init.
    for _ in range(2):
        h.command('language-' + operation, value)
        after = h.language()
        assert after == before, ('uninitialized language UI response was not a no-op', before, after)
        assert h.state()['documents'] == documents
        h.alive()
    assert not h.log_paths() and not h.remember_processes()
    h.evidence_snapshot('uninitialized-ui:' + operation)


def decoration_buffers(h, probe, document, views):
    if 'tags' not in probe:
        raise Blocked('Required CORAL_LANGUAGE.tags probe missing: expose GTK-derived '
                      'diagnostic_kinds/semantic_kinds for canonical and view buffers, independent '
                      'of session caches; zero session counts are not decoration-cleanup evidence')
    # Counts represent tag kinds with applied ranges, not the number of ranges
    # or cached protocol items. Nonzero/zero proves presentation cleanup.
    entries = [entry for entry in probe['tags'] if entry['document'] == document]
    expected = {None, *views}
    assert len(entries) == len(expected) and {entry['view'] for entry in entries} == expected, \
        ('probe must retain canonical and view buffers after session loss', expected, entries)
    for entry in entries:
        assert all(type(entry[key]) is int and entry[key] >= 0
                   for key in ('diagnostic_kinds', 'semantic_kinds')), entry
    return entries


def crash_clears_decorations(h):
    if 'tags' not in h.language():
        raise Blocked('Required GTK-derived CORAL_LANGUAGE.tags observation is not available')
    h.setup('crash')
    h.action('win.split-group')
    state = h.state()
    document = h.document(h.main)
    views = {view['id'] for view in state['views'] if view['document_id'] == document['id']}
    assert len(views) == 2, state
    h.wait_language(lambda p: p['diagnostics'] == 1)
    h.invoke('semantic-tokens')
    h.wait_language(lambda p: p['pending'] is None and 'Applied' in p['status'])
    before = decoration_buffers(h, h.language(), document['id'], views)
    assert all(entry['diagnostic_kinds'] > 0 and entry['semantic_kinds'] > 0 for entry in before), \
        ('regression requires actual applied GTK decorations in every buffer', before)
    h.evidence.setdefault('decoration_observations', []).append(dict(case=h.name, stage='before-crash', buffers=before))
    h.screenshot('decorations-before-crash')
    processes = h.remember_processes()
    assert processes
    h.invoke('hover')  # crash mode exits 86 without responding; not graceful stop
    h.wait_language(lambda p: p['session_count'] == 0 and p['pending'] is None)
    h.assert_reaped(processes)
    after = decoration_buffers(h, h.language(), document['id'], views)
    assert all(entry['diagnostic_kinds'] == entry['semantic_kinds'] == 0 for entry in after), \
        ('crashed session left real GTK tag ranges behind', after)
    assert h.document(h.main) == document, 'cleanup must not close/reload/edit the decorated document'
    assert {view['id'] for view in h.state()['views'] if view['document_id'] == document['id']} == views
    h.evidence.setdefault('decoration_observations', []).append(dict(case=h.name, stage='after-crash', buffers=after))
    h.screenshot('decorations-after-crash')
    h.check_disk_unchanged()


def default_zls_without_config(h):
    h.evidence['verified_reference'] = verify_pins(h.session)
    alternate_config = Path(h.session.env['XDG_CONFIG_HOME']) / 'coral/languages.json'
    assert not h.config.exists() and not alternate_config.exists()
    h.fixture(text=REAL_TEXT)
    h.trust()
    p = h.automatic_review()
    assert 'Executable/argv: ["/usr/bin/zls"]' in p['popup'], p
    assert '/usr/bin/zls0.17.0' not in p['popup']
    h.evidence.setdefault('default_server_reviews', []).append(p)
    h.click_dialog('Language: Start')
    p = h.wait_language(lambda p: p['session_count'] == 1 and p['sessions'][0]['state'] == 'ready' and
                       bool(p['sessions'][0]['documents']), 25)
    processes = h.remember_processes()
    assert len(processes) == 1, processes
    for pid, stamp in processes.items():
        assert process_stamp(pid) == stamp and Path('/proc/%d/exe' % pid).resolve() == Path('/usr/bin/zls')
        assert Path('/proc/%d/cmdline' % pid).read_bytes().split(b'\0')[0] == b'/usr/bin/zls'
    h.select_position(REAL_TEXT.index('answer, 1') + 2)
    h.invoke('hover')
    assert 'answer' in h.result('info', 30)['popup']
    h.reject()
    assert not h.config.exists() and not alternate_config.exists(), 'test/server unexpectedly wrote an override'
    assert not h.log_paths(), 'default real launch must not use the fake server'
    h.evidence_snapshot('pinned-default-zls-no-user-config')
    h.stop_language()


def verify_pins(session):
    reference = json.loads(REFERENCE.read_text())
    verified = {}
    for name, pin in reference['environment_reference']['tools'].items():
        path = Path(pin['path'])
        if not path.is_file():
            raise Blocked('Mandatory pinned tool missing: ' + str(path))
        sha = digest(path.read_bytes())
        if sha != pin['sha256'] or str(path.resolve()) != pin['resolved_path']:
            raise Blocked('Mandatory tool hash/path differs from pinned environment: ' + name)
        result = session.run([path, *pin['version_args']])
        if result.stdout.strip() != pin['version']:
            raise Blocked('Mandatory tool version differs: ' + name)
        verified[name] = dict(path=str(path), version=result.stdout.strip(), sha256=sha)
    assert verified['zls']['path'] == '/usr/bin/zls' and verified['zls']['version'] == '0.17.0'
    assert verified['zig']['version'] == '0.17.1'
    return verified


def real_zls(h, kind):
    pins = verify_pins(h.session)  # mandatory, including when --case selects only real ZLS
    h.evidence['verified_reference'] = pins
    h.setup(real=True, text=REAL_TEXT, native=True)
    pids = h.remember_processes()
    assert pids, 'No real ZLS descendant observed'
    if kind == 'navigation':
        call = REAL_TEXT.index('add(answer')
        h.select_position(call + 1)
        h.invoke('definition', palette=True)
        assert h.result('picker', 30)['rows']
        h.accept(0)
        h.wait_language(lambda p: not p['navigation'])
        doc, view = h.active()
        assert doc['path'] == str(h.main)
        assert REAL_TEXT.index('fn add') <= view['insertion'] <= REAL_TEXT.index('fn add') + 7, view
        h.select_position(call + 5)
        h.invoke('hover')
        assert 'answer' in h.result('info', 30)['popup']
        h.reject()
    elif kind == 'completion':
        text = REAL_TEXT.replace('_ = add(answer, 1);', '_ = ans;')
        h.focus_document(h.main)
        start = REAL_TEXT.index('add(answer, 1)')
        h.select_position(start, start + len('add(answer, 1)'))
        h.text('ans')
        wait_for(lambda: h.canonical_text() == text)
        h.select_position(text.index('ans;') + 3)
        h.invoke('completion', palette=True)
        p = h.result('picker', 30)
        index = next((i for i, row in enumerate(p['rows']) if row == 'answer' or row.startswith('answer ')), None)
        assert index is not None, p
        h.accept(index)
        h.review()
        h.apply_review()
        assert '_ = answer;' in h.canonical_text(), h.canonical_text()
        h.restore_grouped({h.main: text})
    elif kind == 'rename':
        h.select_position(REAL_TEXT.index('answer, 1') + 2)
        h.invoke('rename', palette=True)
        h.result('rename')
        # Entry input is actual keyboard input; acceptance still uses public hook.
        h.text('renamed_answer')
        h.accept('renamed_answer')
        h.review()
        h.apply_review(native=True)
        assert h.canonical_text() == REAL_TEXT.replace('answer', 'renamed_answer'), h.canonical_text()
        h.restore_grouped({h.main: REAL_TEXT})
    elif kind == 'formatting':
        h.invoke('formatting', palette=True)
        h.review()
        h.apply_review(native=True)
        actual = h.canonical_text()
        assert actual != REAL_TEXT and 'café 😀' in actual and 'return a + b;' in actual, actual

        # Exact independent formatting oracle, using the pinned compiler and
        # only disposable stdin/stdout; no source files are passed to zig fmt.
        run = subprocess.run(['/usr/bin/zig', 'fmt', '--stdin'], input=REAL_TEXT, text=True,
                             capture_output=True, env=h.session.env, cwd=h.session.base, timeout=15, check=True)
        assert actual == run.stdout, (actual, run.stdout)
        h.restore_grouped({h.main: REAL_TEXT})
    elif kind == 'unicode':
        # An astral character before the identifier on the same line distinguishes
        # UTF-16 code units from UTF-8 bytes and Python/GTK character offsets.
        text = 'pub const answer: u32 = 42;\npub fn main() void { _ = "aé😀"; _ = answer; }\n'
        h.replace_keyboard(text)
        h.select_position(text.rindex('answer') + 2)
        h.invoke('definition')
        assert h.result('picker', 30)['rows']
        h.accept(0)
        h.wait_language(lambda p: not p['navigation'])
        assert h.active()[1]['insertion'] < text.index('\n'), h.active()
        h.select_position(text.rindex('answer') + 2)
        h.invoke('rename')
        h.result('rename')
        h.accept('unicode_answer')
        h.review()
        h.apply_review()
        assert h.canonical_text() == text.replace('answer', 'unicode_answer')
    elif kind == 'restart':
        old = h.language()['sessions'][0]['id']
        # Kill only a verified descendant of this private Coral process, with
        # executable identity and starttime checked immediately before signaling.
        zls = [pid for pid, stamp in pids.items() if process_stamp(pid) == stamp and
               Path('/proc/%d/exe' % pid).resolve() == Path('/usr/bin/zls')]
        assert len(zls) == 1, zls
        os.kill(zls[0], signal.SIGKILL)
        h.wait_language(lambda p: p['session_count'] == 0)
        h.assert_reaped(pids)
        h.invoke('restart', palette=True)
        p = h.ready_language()
        assert p['sessions'][0]['id'] != old
        h.remember_processes()
        h.select_position(REAL_TEXT.index('answer, 1') + 1)
        h.invoke('hover')
        assert 'answer' in h.result('info', 30)['popup']
        h.reject()
    h.evidence_snapshot('real-zls:' + kind)
    h.screenshot('real-zls-' + kind)
    h.check_disk_unchanged()


OPTIONAL = {
    'clangd': ('c', 'main.c', 'int answer = 42;\nint main(void) { return answer; }\n', ['--background-index=0']),
    'typescript-language-server': ('typescript', 'main.ts',
                                   'const answer: number = 42;\nconsole.log(answer);\n', ['--stdio']),
    'pyright-langserver': ('python3', 'main.py', 'answer = 42\nprint(answer)\n', ['--stdio']),
}


def optional_smoke(h, name):
    binary = shutil.which(name, path='/usr/bin:/bin')
    if binary is None:
        raise Blocked('Optional real language server not installed: ' + name)
    language, filename, text, options = OPTIONAL[name]
    h.configure(language=language, argv=[binary, *options])
    h.fixture(text=text, filename=filename)
    h.trust()
    initialized = h.start()
    assert initialized['sessions'][0]['state'] == 'ready' and initialized['sessions'][0]['documents']
    h.evidence.setdefault('optional_initializations', []).append(dict(
        case=h.name, binary=binary, argv=[binary, *options], language=language, native_probe=initialized))
    h.select_position(text.index('answer') + 2)
    h.invoke('hover')
    p = h.result('info', 35)
    assert p['popup'].strip(), ('Optional real server produced no hover evidence', p)
    h.reject()
    h.evidence_snapshot('optional-real:' + name)


CASES = [('trusted-start', trusted_start, True)]
CASES += PAUSE_CASES
CASES += [('auto-detection-reuse', automatic_detection, True),
          ('auto-decline', automatic_decline, True),
          ('auto-crash', automatic_failure, True),
          ('auto-initialize-timeout', functools.partial(automatic_failure, initialize=True), True),
          ('auto-restored-documents-persistent-stop', automatic_restore_pause, True),
          ('auto-windows-restricted-workspace', automatic_windows, True),
          ('auto-configuration-change', automatic_changed_approval, True),
          ('auto-executable-change', functools.partial(automatic_changed_approval, executable=True), True),
          ('auto-storage-failure', automatic_storage_failure, True),
          ('auto-approval-location-not-cwd', approval_location_not_cwd, True)]
CASES += [('lifecycle-config-' + parent + '-' + review,
           functools.partial(config_directory_replaced, review=review, ancestor=parent == 'ancestor'), True)
          for parent in ('parent', 'ancestor') for review in ('idle', 'text', 'command')]
CASES += [('lifecycle-root-chain-retarget', chained_root_retarget, True),
          ('lifecycle-crash-decorations', crash_clears_decorations, True)]
CASES += [('lifecycle-ui-uninitialized-' + name,
           functools.partial(ui_before_initialize, operation=operation, value=value), True)
          for name, operation, value in [('reject', 'reject', None), ('accept', 'accept', None),
                                          ('accept-index', 'accept', 0), ('accept-input', 'accept', 'unused')]]
CASES += [('real-zls-default-no-config', default_zls_without_config, True)]
CASES += [('policy-' + name, functools.partial(policy_stop, change=name), True)
          for name in ['revoke', 'switch', 'close', 'root-list', 'root-identity', 'root-policy', 'config']]
CASES += [('sync-' + sync + '-' + encoding, functools.partial(sync_case, sync=sync, encoding=encoding), True)
          for sync in ['full', 'incremental'] for encoding in ['utf-8', 'utf-16', 'utf-32']]
CASES += [('large-document-' + sync + '-' + name,
           functools.partial(large_document_sync, sync=sync, size=size), True)
          for sync in ['full', 'incremental']
          for name, size in [('128k', 128 * 1024), ('1m', 1024 * 1024)]]
CASES += [('large-document-message-limit', large_document_message_limit, True)]
CASES += [('did-save', did_save, True), ('diagnostics-current', diagnostics_current, True),
          ('stale-superseded-hover', superseded_hover, True)]
CASES += [('faults-' + name, functools.partial(fault_case, mode=name), True)
          for name in ['crash', 'timeout', 'malformed', 'oversize', 'fragmented']]
CASES += [('features-read', features_read, True), ('completion-snippet-edits', completion, True)]
CASES += [('edits-' + name, functools.partial(edit_case, action=name), True)
          for name in ['formatting', 'rename', 'code-actions']]
CASES += [('advanced', advanced, True),
          ('server-apply-edit-accept', functools.partial(server_apply_edit, approve=True), True),
          ('server-apply-edit-reject', functools.partial(server_apply_edit, approve=False), True)]
CASES += [('stale-' + name, functools.partial(stale_case, kind=name), True)
          for name in ['diagnostics-edits', 'hover', 'completion', 'review']]
CASES += [('hostile-' + name, functools.partial(hostile, kind=name), True)
          for name in ['outside-root', 'malicious']]
CASES += [('roots-windows-isolation', roots_and_windows, True),
          ('policy-peer-revoke', functools.partial(roots_and_windows, shared=True), True),
          ('close-document-pending', close_pending, True), ('close-window-pending', close_window_pending, True),
          ]
CASES += [('resource-' + name, functools.partial(resource_operations, kind=name), True)
          for name in ['create', 'rename', 'delete', 'reject', 'mixed', 'outside-root', 'overwrite',
                       'stale', 'revoke', 'server-accept', 'server-reject']]
CASES += [('real-zls-' + name, functools.partial(real_zls, kind=name), True)
          for name in ['navigation', 'completion', 'rename', 'formatting', 'unicode', 'restart']]
CASES += [('optional-' + name, functools.partial(optional_smoke, name=name), False) for name in OPTIONAL]


def choose_cases(names):
    if not names:
        return CASES
    selected = []
    for name in names:
        matches = [case for case in CASES if case[0] == name or case[0].startswith(name + '-')]
        if not matches:
            raise ValueError('Unknown case/group: ' + name)
        for case in matches:
            if case not in selected:
                selected.append(case)
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-language')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', help='exact case or prefix group; repeatable')
    parser.add_argument('--list-cases', action='store_true')
    parser.add_argument('--case-timeout', type=int, default=120)
    parser.add_argument('--app-arg', action='append', default=[])
    parser.add_argument('binary_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.list_cases:
        print('\n'.join(name + (' [mandatory]' if mandatory else ' [optional]') for name, _, mandatory in CASES))
        return 0
    if args.binary is None:
        parser.error('--binary is required')
    if args.case_timeout < 45:
        parser.error('--case-timeout must be at least 45 seconds (native request timeout is 30 seconds)')
    try:
        cases = choose_cases(args.case)
    except ValueError as exc:
        parser.error(str(exc))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    run_output = Path(tempfile.mkdtemp(prefix='run-', dir=output))
    report = output / 'results.json'
    evidence = dict(schema_version=1, status='running', complete_suite=not bool(args.case),
                    invocation=[sys.executable, *sys.argv], binary=str(args.binary.resolve()),
                    artifacts=str(run_output), selected_cases=[case[0] for case in cases],
                    unselected_cases=[case[0] for case in CASES if case not in cases], checks=[],
                    isolation='Private headless Wayland/session bus and per-case disposable HOME/XDG; no live desktop',
                    limitations=['Synthetic fixtures are not language correctness evidence.',
                                 'Resources cover standalone operations; mixed/multiple edits must be rejected atomically.'])
    began = time.monotonic()
    save(report, evidence)

    def expired(_signum, _frame):
        raise CaseTimeout('native language case exceeded %d seconds' % args.case_timeout)

    previous = signal.signal(signal.SIGALRM, expired)
    try:
        binary = args.binary.resolve()
        data = binary.read_bytes()
        evidence['binary_sha256'] = digest(data)
        evidence['source_sha256'] = {str(path.relative_to(PROJECT)): digest(path.read_bytes())
                                     for path in (Path(__file__).resolve(), FIXTURE, REFERENCE,
                                                  PROJECT / 'tests/language_pause.py',
                                                  PROJECT / 'tests/fixtures/language_pause_races.py',
                                                  PROJECT / 'tests/fixtures/language_resume.zig')}
        assert all(marker in data for marker in (b'CORAL_LANGUAGE ', b'CORAL_WINDOWS ', b'CORAL_COMMAND_DONE')), \
            'Build a current native binary with -Dtest-hooks=true (language and windows probes required)'
        del data
        with PrivateSession(run_output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            stage_styles(session, evidence)
            assert Path(session.env['HOME']).is_relative_to(session.base)
            assert session.env['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path=' + str(session.runtime))
            assert session.display_path.is_relative_to(session.base)
            extra = args.binary_args[1:] if args.binary_args[:1] == ['--'] else args.binary_args
            for name, scenario, mandatory in cases:
                record = dict(name=name, mandatory=mandatory, status='running')
                evidence['checks'].append(record)
                save(report, evidence)
                h, start = None, time.monotonic()
                child_start = len(session.children)
                print('RUN', name, flush=True)
                signal.alarm(args.case_timeout)
                try:
                    # Keep the object available for failure evidence even if initialization fails.
                    h = LanguageHarness.__new__(LanguageHarness)
                    h.__init__(session, binary, run_output, evidence, name,
                               time.monotonic() + args.case_timeout, args.app_arg + extra)
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed')
                    print('PASS', name, flush=True)
                except Blocked as exc:
                    record.update(status='blocked', reason=str(exc))
                    print('BLOCKED', name, str(exc), flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc())
                    print('FAIL', name, str(exc)[:1800], flush=True)
                finally:
                    signal.alarm(0)
                    if h is not None:
                        record['last_probe'] = getattr(h, 'last', {}).copy()
                        record['transcripts'] = [str(path) for path in h.log_paths()] if hasattr(h, 'logs') else []
                        record['fixture_hashes'] = {str(p): value for p, value in getattr(h, 'expected', {}).items()}
                        if record['status'] != 'passed' and getattr(h, 'app', None) is not None:
                            try:
                                h.screenshot('failure')
                            except Exception:
                                record['screenshot_error'] = traceback.format_exc()
                        # Evidence remains on disk even if the native process has crashed.
                        if getattr(h, 'app', None) is not None:
                            record['native_log'] = str(h.app.logfile)
                        if hasattr(h, 'load_gate'):
                            h.load_gate.unlink(missing_ok=True)
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    del session.children[child_start:]
                    # Transports own their process groups. Clean up only exact recorded
                    # descendants if the parent died before it could reap them; this is
                    # failure cleanup, never counted as successful native close/reaping.
                    if h is not None:
                        for pid, stamp in getattr(h, 'server_processes', {}).items():
                            if process_stamp(pid) == stamp:
                                record.setdefault('forced_server_cleanup', []).append(pid)
                                try:
                                    os.kill(pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                                if record['status'] == 'passed':
                                    record.update(status='failed', error='server survived successful native teardown')
                    record['seconds'] = time.monotonic() - start
                    save(report, evidence)
    except Exception:
        evidence.update(status='failed', fatal=traceback.format_exc())
        print(evidence['fatal'], file=sys.stderr, flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        completed = {record['name'] for record in evidence['checks']}
        for name, _, mandatory in cases:
            if name not in completed:
                evidence['checks'].append(dict(name=name, mandatory=mandatory, status='blocked', reason='Suite setup failed'))
        counts = {state: sum(c['status'] == state for c in evidence['checks']) for state in ['passed', 'failed', 'blocked']}
        required_bad = any(c['mandatory'] and c['status'] != 'passed' for c in evidence['checks'])
        if 'fatal' in evidence or required_bad or counts['failed']:
            evidence['status'] = 'failed'
        elif counts['blocked']:
            evidence['status'] = 'passed-with-optional-blockers'
        else:
            evidence['status'] = 'passed' if not args.case else 'selected-cases-passed'
        evidence.update(counts=counts, seconds=time.monotonic() - began)
        save(report, evidence)
        save(run_output / 'results.json', evidence)
    print('%s: %s; %s' % (evidence['status'].upper(), evidence['counts'], report), flush=True)
    return 1 if evidence['status'] == 'failed' else 0


if __name__ == '__main__':
    sys.exit(main())
