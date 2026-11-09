#!/usr/bin/env python3
"""Native explicit workspace-session acceptance (not the codec/unit suite).

Run from subprojects/coral with:
  zig build -Dtest-hooks=true
  python3 tests/sessions.py --binary zig-out/bin/coral
The parent-owned `zig build sessions` target can supply its test-hook artifact
once wired. This file does not build binaries or run other acceptance suites.

Every case uses real GTK/F11 commands in a private headless compositor/D-Bus,
with independent disposable HOME/XDG and fixtures. Restarts within a case keep
that case's state. Only explicit saves may replace coral/sessions/current.
results.json records actual passed/failed/blocked cases, observations, hashes,
invocation and binary identity; native logs and failure screenshots remain in
--output (default .cache/coral-sessions). A 500-second alarm bounds the suite.
Review regressions preserve lexical ./../ roots and use the acknowledged
CORAL_TEST_SESSION_LOAD_PAUSE gate for post-preflight rollback/cancellation,
not timing sleeps. Gate files are private and removed even on assertion failure.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import signal
import sys
import time
import traceback
from pathlib import Path

# Reuse protocol, isolation, fixture and trust helpers, never policy.main/run.
from policy import BudgetExpired, PolicyHarness, save
from search import PEARL
from pearl_session import PrivateSession, fixture_prefix, wait_for


def digest(data):
    return hashlib.sha256(data).hexdigest()


class SessionHarness(PolicyHarness):
    def launch(self, *paths):
        self.load_gate = self.command_path.with_name('session-load.gate')
        assert self.load_gate.is_absolute() and not self.load_gate.exists(), self.load_gate
        self.session.env['CORAL_TEST_SESSION_LOAD_PAUSE'] = str(self.load_gate)
        self.serial += 1
        self.app = self.session.child(f'{self.name}-{self.serial}', [self.binary, *paths],
                                      G_DEBUG='fatal-criticals')
        window = wait_for(lambda: next((w for w in self.ipc.state() if w['kind'] == 'window'), None))
        self.ipc.call('command', action='window.activate', fields={'id': window['id']})
        self.settled()
        docs = wait_for(lambda: self.state()['documents'])
        self.startup_blank = docs[0]['id'] if len(docs) == 1 and not docs[0]['text'] and docs[0]['path'] is None else None
        p = self.probe('session')
        assert not p['busy'] and p['status'] == 'idle', p
        self.slot = Path(self.session.env['XDG_STATE_HOME']) / 'coral/sessions/current'

    def state(self):
        return self.probe('workspace')

    def open_document(self, path):
        doc = super().open_document(path)
        if self.startup_blank is not None:
            # File fixtures should contain only the named files, not the launch
            # placeholder. Close it explicitly through GTK, never during restore.
            p = self.state()
            blank = next(d for d in p['documents'] if d['id'] == self.startup_blank)
            assert not blank['text'] and not blank['dirty'] and blank['path'] is None, blank
            index = next(i for i, v in enumerate(p['views']) if v['document_id'] == blank['id'])
            self.command('focus-view', index=index)
            self.command('close')
            self.startup_blank = None
            p = self.state()
            index = next(i for i, v in enumerate(p['views']) if v['document_id'] == doc['id'])
            self.command('focus-view', index=index)
        return doc

    def stop(self):
        if self.app is not None and self.app.proc.poll() is None:
            before = self.state()
            assert not before['dialog'], before
            self.key('q', 'ctrl')
            for _ in range(sum(d['dirty'] for d in before['documents'])):
                wait_for(lambda: self.state()['dialog'])
                # Unlike the shared helper, permit a successful process exit
                # immediately after the final native Discard response.
                start = len(self.app.lines)
                self.command_path.write_text('[Test]\naction=respond\nresponse=1\n')
                self.key('F11')
                wait_for(lambda: self.app.proc.poll() is not None or
                         'CORAL_COMMAND_DONE' in self.app.lines[start:])
            assert self.app.wait(timeout=15) == 0, self.app.lines[-30:]
            wait_for(lambda: not any(w['kind'] == 'window' for w in self.ipc.state()))
        if self.app is not None:
            self.no_criticals()

    def session_done(self, status, error=None):
        p = wait_for(lambda: p if not (p := self.probe('session'))['busy'] else None, 20)
        assert p['status'] == status and p['error_name'] == error, p
        assert self.state()['session'] == p, 'Workspace and session probes disagree'
        self.evidence.setdefault('observations', []).append(
            {'case': self.name, 'session': p, 'notice': self.state()['notice']})
        return p

    def save_session(self, status='saved', error=None):
        self.command('save-workspace-session')
        p = self.session_done(status, error)
        if status == 'saved':
            assert self.slot.is_file() and not self.slot.is_symlink(), self.slot
            assert self.slot.stat().st_mode & 0o777 == 0o600
            assert self.slot.parent.stat().st_mode & 0o777 == 0o700
        return p

    def restore_session(self, status='restored', error=None):
        self.command('restore-workspace-session')
        return self.session_done(status, error)

    @contextmanager
    def paused_restore(self):
        marker = 'CORAL_SESSION_WORKSPACE_LOAD_PAUSED'
        start = len(self.app.lines)
        began = time.monotonic()
        record = {'case': self.name, 'marker': marker, 'acknowledged': False}
        self.evidence.setdefault('load_gates', []).append(record)
        self.load_gate.touch(mode=0o600, exist_ok=False)
        try:
            self.command('restore-workspace-session')
            wait_for(lambda: marker in self.app.lines[start:], 5)
            record['acknowledged'] = True
            record['ack_seconds'] = time.monotonic() - began
            p = self.probe('session')
            browser = self.probe('browser')
            assert p['busy'] and p['status'] == 'running', p
            assert browser['loading'] and not browser['roots'] and browser['manifest'] is None, browser
            yield record
            # A timeout release must not accidentally pass a race regression.
            assert time.monotonic() - began < 8, 'Gate test approached its 10-second automatic release'
        finally:
            record['release_seconds'] = time.monotonic() - began
            self.load_gate.unlink(missing_ok=True)

    def checkpoint_bytes(self, label):
        raw = self.slot.read_bytes()
        self.evidence.setdefault('checkpoints', []).append(
            {'case': self.name, 'label': label, 'bytes': len(raw), 'sha256': digest(raw)})
        return raw

    def unchanged(self, raw):
        assert self.slot.read_bytes() == raw, 'Explicit checkpoint was replaced or removed'

    def close_workspace(self):
        before = self.state()['documents']
        self.command('close-workspace')
        browser = self.browser()
        assert not browser['roots'] and browser['manifest'] is None, browser
        assert self.state()['documents'] == before, 'Close Workspace discarded documents'

    def remove_fixture(self, path):
        path.unlink()
        self.expected.pop(path)
        self.evidence.setdefault('removed_fixtures', []).append(str(path))

    def no_resume(self):
        p = self.state()
        assert not p['dialog'] and all(not d['text'] and d['path'] is None for d in p['documents']), p
        assert not self.probe('browser')['roots']
        assert not any('CORAL_RECOVERY_PROMPT' in line for line in self.app.lines), self.app.lines[-20:]
        assert p['session']['status'] == 'idle', p['session']


def layout(state, group_ids=None):
    """Compare presentation identities, not freshly allocated document/view IDs."""
    docs = {d['id']: d['text'] for d in state['documents']}
    groups = [g for g in state['groups'] if group_ids is None or g['id'] in group_ids]
    return [{'active': g['active'], 'tabs': [
        {'text': docs[v['document_id']], **{k: v[k] for k in
         ('page', 'selected', 'active', 'insertion', 'bound', 'excerpt_start', 'excerpt_end')}}
        for v in sorted(state['views'], key=lambda v: v['page']) if v['group_id'] == g['id']
    ]} for g in groups]


def layout_roundtrip(h):
    h.fixture()
    h.open_workspace(h.manifest)
    first = h.write(h.roots[0] / 'unicode.txt', 'α😀 heading\n' + ''.join(f'line {i:03d}\n' for i in range(220)))
    second = h.write(h.roots[1] / 'second.txt', 'second root document\n')
    h.open_document(first)
    h.command('select', start=4, end=1)
    h.command('split-group')
    h.open_document(second)
    h.command('focus-view', index=1)
    h.command('select', start=2, end=40)
    h.command('excerpt')
    h.command('select', start=7, end=2)
    h.command('focus-group', index=0)
    h.command('select', start=4, end=1)
    h.command('scroll', y=320)
    before = h.state()
    assert len(before['groups']) == 2 and len(before['views']) == 4, before
    assert any(v['excerpt_start'] is not None for v in before['views'])
    assert next(v for v in before['views'] if v['active'])['scroll_y'] >= 300
    roots = [(r['path'], r['name']) for r in h.probe('browser')['roots']]
    saved = h.save_session()
    assert (saved['documents'], saved['groups'], saved['views']) == (2, 2, 4), saved
    raw = h.checkpoint_bytes('layout')
    h.restart()
    h.no_resume()
    existing_groups = {g['id'] for g in h.state()['groups']}
    restored = h.restore_session()
    assert (restored['bound'], restored['copies'], restored['conflicts']) == (2, 0, 0), restored
    after = h.state()
    restored_groups = {g['id'] for g in after['groups']} - existing_groups
    assert layout(after, restored_groups) == layout(before), (layout(before), layout(after, restored_groups))
    assert all(not d['dirty'] for d in after['documents'])
    # Vertical position is serialized as a line, so allow one line of rounding.
    active = next(v for v in after['views'] if v['active'])
    old_active = next(v for v in before['views'] if v['active'])
    assert abs(active['scroll_y'] - old_active['scroll_y']) < 30, (old_active, active)
    assert [(r['path'], r['name']) for r in h.browser()['roots']] == roots
    h.unchanged(raw)
    h.screenshot('restored-layout')


def copies_without_writes(h):
    paths = [h.write(h.fixtures / (name + '.txt'), name + ' saved contents\n')
             for name in ('clean', 'dirty', 'conflict', 'unavailable')]
    for path in paths:
        h.open_document(path)
        if path.stem == 'dirty':
            h.command('insert', 'unsaved α😀 ')
    before = h.state()
    h.save_session()
    raw = h.checkpoint_bytes('mixed-documents')
    h.stop()
    h.write(paths[2], 'external replacement MUST survive\n')
    h.remove_fixture(paths[3])
    h.launch()
    p = h.restore_session()
    assert (p['bound'], p['copies'], p['conflicts'], p['unavailable']) == (1, 3, 1, 1), p
    after = h.state()
    for old in before['documents']:
        doc = next(d for d in after['documents'] if d['text'] == old['text'])
        clean = old['path'] == str(paths[0])
        assert doc['path'] == (str(paths[0]) if clean else None) and doc['dirty'] != clean, doc
    assert 'Save As' in after['notice'] and 'no files written' in after['notice'], after['notice']
    assert not paths[3].exists()
    h.verify_files()
    h.unchanged(raw)


def existing_cli_documents(h):
    path = h.write(h.fixtures / 'shared.txt', 'saved clean text\n')
    h.open_document(path)
    h.save_session()
    raw = h.checkpoint_bytes('before-cli')
    h.stop()
    cli = h.write(h.fixtures / 'cli.txt', 'CLI document retained\n')
    h.launch(path, cli)
    wait_for(lambda: len([d for d in h.state()['documents'] if d['path']]) == 2)
    h.key('n', 'ctrl')
    h.command('insert', 'existing unsaved scratch α😀')
    before = h.state()['documents']
    p = h.restore_session()
    assert (p['bound'], p['copies'], p['conflicts']) == (0, 1, 1), p
    after = h.state()['documents']
    assert after[:len(before)] == before, (before, after)
    assert len(after) == len(before) + 1 and after[-1]['path'] is None and after[-1]['dirty'], after
    assert after[-1]['text'] == path.read_text()
    h.unchanged(raw)


def explicit_lifecycle(h):
    h.command('insert', 'explicit checkpoint α😀')
    h.save_session()
    raw = h.checkpoint_bytes('explicit')
    h.command('insert', ' later edit not checkpointed')
    h.stop()  # Discard must neither delete nor update the explicit slot.
    h.unchanged(raw)
    h.launch()
    h.no_resume()
    h.unchanged(raw)
    h.stop()  # Nor does a clean/empty quit replace it.
    h.unchanged(raw)
    h.launch()
    h.no_resume()
    p = h.restore_session()
    assert p['copies'] == 1 and p['bound'] == 0, p
    assert any(d['text'] == 'explicit checkpoint α😀' and d['dirty'] for d in h.state()['documents'])
    h.unchanged(raw)


def active_workspace_prerequisite(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.open_document(h.roots[0] / 'plain.txt')
    h.save_session()
    raw = h.checkpoint_bytes('active-workspace')
    before = h.state()
    h.restore_session('failed', 'ActiveWorkspace')
    after = h.state()
    assert after['documents'] == before['documents'] and after['views'] == before['views']
    assert 'Close the active workspace first' in after['notice'], after['notice']
    h.close_workspace()
    p = h.restore_session()
    assert p['conflicts'] == 1 and p['copies'] == 1, p
    assert h.state()['documents'][:len(before['documents'])] == before['documents']
    assert h.browser()['manifest'] == str(h.manifest)
    h.unchanged(raw)


def fresh_manifest_and_settings(h):
    h.fixture({'indent': 2})
    h.open_workspace(h.manifest)
    path = h.roots[0] / 'plain.txt'
    h.open_document(path)
    h.save_session()
    raw = h.checkpoint_bytes('old-settings')
    h.stop()
    h.spec['roots'].reverse()
    h.spec['roots'][0]['name'] = 'Fresh right name'
    h.spec['settings'] = {'indent': 7, 'wrap': False}
    h.write(h.manifest, json.dumps(h.spec))
    h.folder_settings(0, {'lines': False})
    h.launch()
    h.restore_session()
    browser = h.browser()
    assert [r['path'] for r in browser['roots']] == [str(r) for r in reversed(h.roots)], browser
    assert browser['roots'][0]['name'] == 'Fresh right name'
    h.settled()
    h.effective(path, dict(lines=False, wrap=False, spaces=True, indent=7),
                ('folder', 'workspace', 'default', 'workspace'), root=h.roots[0])
    h.restricted()
    h.unchanged(raw)


def trust_revalidated(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.approve()
    h.save_session()
    raw = h.checkpoint_bytes('saved-while-trusted')
    h.restart()
    h.restore_session()
    h.trusted(h.settled())  # Existing approval is checked through the normal loader.
    h.stop()
    assert h.store.exists()
    h.store.unlink()  # Revoke the private approval, leave the checkpoint untouched.
    h.launch()
    h.restore_session()
    h.restricted(h.settled())
    h.unchanged(raw)


def missing_manifest(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.open_document(h.roots[0] / 'plain.txt')
    h.save_session()
    raw = h.checkpoint_bytes('missing-manifest')
    h.stop()
    h.remove_fixture(h.manifest)
    h.launch()
    before = h.state()['documents']
    h.restore_session('failed', 'NotFound')
    p = h.state()
    assert p['documents'] == before and not h.probe('browser')['roots'], p
    assert 'Saved roots' in p['notice'] and 'no fallback' in p['notice'], p['notice']
    assert all(str(root) in p['notice'] for root in h.roots), p['notice']
    assert not h.manifest.exists()
    h.unchanged(raw)


def unavailable_root(h):
    h.fixture()
    h.open_workspace(h.manifest)
    path = h.roots[1] / 'plain.txt'
    h.open_document(path)
    h.save_session()
    raw = h.checkpoint_bytes('unavailable-root')
    h.stop()
    # Park rather than destroy the fixture; restoration must not recreate it.
    parked = h.fixtures / 'parked-right'
    h.roots[1].rename(parked)
    for old in list(h.expected):
        if old.is_relative_to(h.roots[1]):
            h.expected[parked / old.relative_to(h.roots[1])] = h.expected.pop(old)
    h.launch()
    p = h.restore_session()
    assert (p['unavailable_roots'], p['unavailable'], p['copies']) == (1, 1, 1), p
    roots = h.browser()['roots']
    assert len(roots) == 2 and roots[1]['availability'] != 'available', roots
    assert roots[1]['path'] == str(h.roots[1]), roots
    assert not h.roots[1].exists()
    # The normal policy worker may replace the shared session notice before
    # a probe arrives. Check its durable diagnostic, not that transient label.
    policy = h.restricted(h.settled())
    assert 'UnavailableRoot' in (policy['store_error'] or ''), policy
    h.unchanged(raw)


def damaged_slot(h, future):
    h.command('insert', 'valid saved checkpoint')
    h.save_session()
    valid = h.checkpoint_bytes('valid')
    h.stop()
    header, payload = valid.split(b'\n', 1)
    assert header in (b'CORAL-SESSION 1', b'CORAL-SESSION 2'), header
    damaged = b'CORAL-SESSION 999\n' + payload if future else b'not a session\n'
    assert damaged != valid
    h.slot.write_bytes(damaged)
    h.launch()
    h.no_resume()
    h.command('insert', 'existing document must survive rejected restore')
    before = h.state()
    h.restore_session('failed', 'UnsupportedVersion' if future else 'CorruptSession')
    after = h.state()
    assert after['documents'] == before['documents'] and after['views'] == before['views']
    h.unchanged(damaged)
    h.stop()
    h.unchanged(damaged)
    h.checkpoint_bytes('rejected-preserved')


def oversized_save(h):
    small = h.write(h.fixtures / 'small.txt', 'old checkpoint remains usable\n')
    h.open_document(small)
    h.save_session()
    raw = h.checkpoint_bytes('before-oversize')
    # Just over the 4 MiB per-document session cap, below the large-open prompt.
    # Real file input, not an in-process codec test or a giant command argument.
    large = h.write(h.fixtures / 'over-cap.txt', (b'x' * 127 + b'\n') * (4 * 1024 * 1024 // 128 + 1))
    h.open_document(large)
    h.save_session('failed', 'TooLarge')
    assert h.document(large)['path'] == str(large)
    h.unchanged(raw)
    h.restart()
    h.no_resume()
    p = h.restore_session()
    assert p['bound'] == 1 and p['copies'] == 0, p
    assert any(d['path'] == str(small) for d in h.state()['documents'])
    assert not any(d['path'] == str(large) for d in h.state()['documents'])
    h.unchanged(raw)


def lexical_roots_roundtrip(h):
    project = h.fixtures / 'project'
    shared = h.fixtures / 'shared'
    paths = [h.write(project / 'local.txt', 'local lexical root\n'),
             h.write(shared / 'shared.txt', 'shared lexical root\n')]
    manifest = h.write(project / 'lexical.coral-workspace', json.dumps({
        'version': 1, 'roots': [{'path': '.', 'name': 'Local dot'},
                                {'path': '../shared', 'name': 'Shared parent'}]}))
    # Path joining in Python drops '.', so retain the requested spelling as text.
    lexical = [str(project) + '/.', str(project) + '/../shared']
    canonical = [str(project), str(shared)]
    h.open_workspace(manifest)
    for path in paths:
        h.open_document(path)
    before = h.browser()['roots']
    assert [r['path'] for r in before] == lexical, before
    assert [r['canonical'] for r in before] == canonical, before
    h.save_session()
    raw = h.checkpoint_bytes('lexical-roots')
    # Inspect only the native-produced descriptor: a reload of the manifest
    # alone could hide accidental normalization in the explicit checkpoint.
    descriptor = json.loads(raw.split(b'\n', 3)[2])['workspace']
    assert [base64.b64decode(r['path']).decode() for r in descriptor['roots']] == lexical, descriptor
    assert [r['name'] for r in descriptor['roots']] == ['Local dot', 'Shared parent'], descriptor
    h.restart()
    h.no_resume()
    restored = h.restore_session()
    assert (restored['bound'], restored['copies'], restored['unavailable_roots']) == (2, 0, 0), restored
    browser = h.browser()
    assert browser['manifest'] == str(manifest), browser
    assert [{k: r[k] for k in ('path', 'canonical', 'name', 'availability')} for r in browser['roots']] == [
        {k: r[k] for k in ('path', 'canonical', 'name', 'availability')} for r in before]
    h.evidence.setdefault('lexical_roots', []).append({'case': h.name, 'saved': lexical, 'restored': browser['roots']})
    h.unchanged(raw)


def existing_state_preserved(h, before):
    after = h.state()
    assert after['documents'] == before['documents'], 'Restore failure changed existing documents'
    assert after['groups'] == before['groups'], 'Restore failure leaked or changed groups'
    assert layout(after) == layout(before), 'Restore failure changed existing tabs, selections or focus'
    return after


def postload_rollback(h, oversized):
    h.fixture({'indent': 7})
    h.open_workspace(h.manifest)
    if oversized:
        # Each document fits the 4 MiB cap. Initial combined state is exactly
        # 8 MiB; a one-byte edit while paused exceeds ONLY the combined cap.
        saved_bytes = 6 * 1024 * 1024
        for root in h.roots:
            path = h.write(root / 'checkpoint.txt', (b'x' * 127 + b'\n') * (3 * 1024 * 1024 // 128))
            h.open_document(path)
        existing_text = (b'e' * 127 + b'\n') * (2 * 1024 * 1024 // 128)
    else:
        h.open_document(h.roots[0] / 'plain.txt')
        saved_bytes = len((h.roots[0] / 'plain.txt').read_bytes())
        existing_text = b'existing document survives the readiness failure\n'
    saved = h.save_session()
    raw = h.checkpoint_bytes('before-postload-failure')
    h.stop()
    existing_path = h.write(h.roots[0] / 'existing.txt', existing_text)
    h.launch(existing_path)
    wait_for(lambda: (d := h.document(existing_path)) is not None and d['text'] == existing_text.decode())
    before = h.state()
    assert not h.probe('browser')['roots']
    if oversized:
        assert saved_bytes + sum(len(d['text'].encode()) for d in before['documents']) == 8 * 1024 * 1024
    with h.paused_restore() as gate:
        if oversized:
            h.command('insert', 'X')
        else:
            h.command('policy-show')
            assert h.state()['dialog'], 'Readiness dialog did not open while load was paused'
        changed = h.state()
        if oversized:
            combined = saved_bytes + sum(len(d['text'].encode()) for d in changed['documents'])
            assert combined == 8 * 1024 * 1024 + 1, combined
            assert all(len(d['text'].encode()) <= 4 * 1024 * 1024 for d in changed['documents'])
            gate['combined_bytes_after_edit'] = combined
        assert h.probe('session')['busy'], 'Restore completed before the gate was released'
    failure = h.session_done('failed', 'TooLarge' if oversized else 'Loading')
    browser = h.browser()
    assert not browser['loading'] and not browser['roots'] and browser['manifest'] is None, browser
    existing_state_preserved(h, changed)
    h.settled()
    h.effective(existing_path, dict(lines=True, wrap=True, spaces=True, indent=4), ['default'] * 4)
    h.unchanged(raw)
    gate['failure'] = failure
    gate['rollback_roots'] = browser['roots']
    gate['existing_documents_preserved'] = True
    if oversized:
        h.command('undo')
        assert h.document(existing_path)['text'] == existing_text.decode()
    else:
        assert h.state()['dialog'], 'The readiness failure unexpectedly dismissed the existing dialog'
        h.command('respond', response=0)
    wait_for(lambda: not h.state()['dialog'])
    before_retry = h.state()['documents']
    restored = h.restore_session()
    assert restored['bound'] == saved['documents'] and restored['copies'] == 0, restored
    assert h.browser()['manifest'] == str(h.manifest)
    assert h.state()['documents'][:len(before_retry)] == before_retry, 'Retry changed existing documents'
    h.settled()
    h.effective(existing_path, dict(lines=True, wrap=True, spaces=True, indent=7),
                ('default', 'default', 'default', 'workspace'), root=h.roots[0])
    gate['retry'] = restored
    h.unchanged(raw)


def paused_newer_workspace(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.open_document(h.roots[0] / 'plain.txt')
    h.save_session()
    raw = h.checkpoint_bytes('before-paused-switch')
    h.restart()
    h.command('insert', 'existing unsaved document kept across workspace switch')
    before = h.state()
    with h.paused_restore() as gate:
        h.command('open-folder', h.roots[1])
        # Cancellation must release the paused worker even with its gate still
        # present. The stale completion must not close the newer installation.
        stale = h.session_done('stale', 'StaleWorkspace')
        browser = h.browser()
        assert h.load_gate.exists(), 'Gate disappeared before cancellation was observed'
        assert browser['manifest'] is None and [r['path'] for r in browser['roots']] == [str(h.roots[1])], browser
        existing_state_preserved(h, before)
        gate['cancelled_with_gate_present'] = True
        gate['completion'] = stale
        gate['newer_roots'] = browser['roots']
    browser = h.browser()
    assert [r['path'] for r in browser['roots']] == [str(h.roots[1])], browser
    existing_state_preserved(h, before)
    h.unchanged(raw)


def stale_workspace_switch(h):
    h.fixture()
    h.open_workspace(h.manifest)
    h.open_document(h.roots[0] / 'plain.txt')
    h.save_session()
    raw = h.checkpoint_bytes('before-switch')
    h.restart()
    before = h.state()['documents']
    h.command('session-delay', 4000)
    _, elapsed = h.command('restore-workspace-session')
    assert elapsed < 1 and h.probe('session')['busy'], elapsed
    h.command('open-folder', h.roots[1])
    assert h.probe('session')['busy'], 'Delay expired before workspace switch'
    h.session_done('stale', 'StaleWorkspace')
    browser = h.browser()
    assert browser['manifest'] is None and [r['path'] for r in browser['roots']] == [str(h.roots[1])], browser
    assert h.state()['documents'] == before
    h.unchanged(raw)


def delayed_shutdown(h, operation):
    path = h.write(h.fixtures / 'shutdown.txt', 'clean shutdown fixture\n')
    h.open_document(path)
    h.save_session()
    raw = h.checkpoint_bytes('before-shutdown')
    if operation == 'restore':
        h.restart()
    h.command('session-delay', 5000)
    _, elapsed = h.command(operation + '-workspace-session')
    assert elapsed < 1 and h.probe('session')['busy'], elapsed
    began = time.monotonic()
    h.key('q', 'ctrl')
    wait_for(lambda: not any(w['kind'] == 'window' for w in h.ipc.state()), 2)
    window_seconds = time.monotonic() - began
    assert h.app.proc.poll() is None, 'Worker was not retained after window close'
    assert h.app.wait(timeout=10) == 0, h.app.lines[-30:]
    h.no_criticals()
    final = [json.loads(line.removeprefix('CORAL_SESSION ')) for line in h.app.lines
             if line.startswith('CORAL_SESSION ')]
    assert final and not final[-1]['busy'] and final[-1]['status'] == 'stale', final
    # An explicitly requested save can finish its I/O after close; it captured
    # the same document/layout here. Shutdown itself must not save or restore.
    h.unchanged(raw)
    h.evidence.setdefault('shutdown', []).append(
        {'operation': operation, 'input_ack_seconds': elapsed, 'window_close_seconds': window_seconds,
         'window_closed_before_worker_exit': True, 'exit_status': 0, 'final_session': final[-1]})
    h.launch()
    h.no_resume()
    h.unchanged(raw)


SCENARIOS = [
    ('layout_roundtrip_clean_rebound', layout_roundtrip),
    ('dirty_conflict_unavailable_copies_no_writes', copies_without_writes),
    ('existing_cli_and_unsaved_documents_retained', existing_cli_documents),
    ('explicit_only_restart_discard_no_quit_save', explicit_lifecycle),
    ('close_active_workspace_prerequisite', active_workspace_prerequisite),
    ('fresh_manifest_roots_and_settings', fresh_manifest_and_settings),
    ('trust_revalidated_not_deserialized', trust_revalidated),
    ('missing_manifest_diagnostics_no_fallback', missing_manifest),
    ('unavailable_root_not_recreated', unavailable_root),
    ('malformed_checkpoint_preserved', lambda h: damaged_slot(h, False)),
    ('future_checkpoint_preserved', lambda h: damaged_slot(h, True)),
    ('oversized_save_keeps_old_checkpoint', oversized_save),
    ('lexical_dot_parent_roots_roundtrip', lexical_roots_roundtrip),
    ('postload_combined_cap_failure_rolls_back_workspace', lambda h: postload_rollback(h, True)),
    ('postload_readiness_failure_rolls_back_workspace', lambda h: postload_rollback(h, False)),
    ('paused_restore_preserves_newer_workspace', paused_newer_workspace),
    ('delayed_restore_workspace_switch_stale', stale_workspace_switch),
    ('delayed_restore_shutdown', lambda h: delayed_shutdown(h, 'restore')),
    ('delayed_save_shutdown', lambda h: delayed_shutdown(h, 'save')),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-sessions')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    began = time.monotonic()
    evidence = {'status': 'running', 'checks': [], 'invocation': [sys.executable, *sys.argv],
                'binary': str(args.binary.resolve()), 'runtime_budget_seconds': 500,
                'scope': 'Native acceptance only; no codec, filesystem fault-injection or implementation unit tests.',
                'isolation': 'Private headless compositor, D-Bus, HOME/XDG; separate per-case state, preserved only across its restarts.'}

    def expired(_signal, _frame):
        raise BudgetExpired('Session acceptance exceeded its 500-second budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(500)
    save(output, evidence)
    try:
        binary_bytes = args.binary.read_bytes()
        evidence['binary_sha256'] = digest(binary_bytes)
        if not all(marker in binary_bytes for marker in (b'CORAL_COMMAND_DONE', b'CORAL_SESSION ', b'CORAL_SESSION_WORKSPACE_LOAD_PAUSED')):
            raise RuntimeError('Binary lacks session test hooks; build with zig build -Dtest-hooks=true or use the sessions target artifact')
        del binary_bytes
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            for name, scenario in SCENARIOS:
                record = {'name': name, 'status': 'running'}
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = SessionHarness(session, args.binary.resolve(), output, evidence, name, began + 495)
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_hashes_verified=len(h.expected))
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
        for name, _ in SCENARIOS:
            if name not in completed:
                evidence['checks'].append({'name': name, 'status': 'blocked', 'reason': 'Setup or runtime budget failed'})
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        save(output, evidence)
    passed = sum(c['status'] == 'passed' for c in evidence['checks'])
    print(f"{evidence['status'].upper()}: {passed}/{len(SCENARIOS)} native session cases; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
