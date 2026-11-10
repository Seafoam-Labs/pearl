#!/usr/bin/env python3
"""Durable M2 project acceptance, including W07, in private native sessions.

From subprojects/coral, build a fresh test-hook binary, then run:
  python3 tests/projects.py --binary zig-out/bin/coral
Use --case NAME repeatedly for focused regressions. No cached scripts/helpers,
installed desktop, host HOME/XDG, or real documents are read by these tests.

Keyboard shortcuts, the command palette and exported native menu GActions route
actual UI commands. F11 provides bounded fixture setup, fault injection and
observations, not a replacement for the picker/keyboard acceptance paths.
Roots editing UI has its own roots.py suite; W07 consumes a two-root manifest.
The version-checked binary index fixture below is ONLY for capacity and stale
confirmation fault injection, under the private store's directory lock. It is
not an alternate project implementation. All normal snapshots come from Coral.
Each case retains logs, screenshots, fixture hashes and structured observations.
A whole-suite alarm and per-case deadline bound execution, including failures.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import signal
import shutil
import struct
import sys
import time
import traceback
import uuid
from pathlib import Path

from windows import WindowHarness, stage_styles
from search import PEARL
from sessions import digest, layout
from policy import BudgetExpired, save
from pearl_session import PrivateSession, fixture_prefix, wait_for


class ProjectHarness(WindowHarness):
    def launch(self, *paths, recovery=False):
        # An ordinary launch is now a restore operation, not a clean baseline.
        # Only the very first launch uses a private explicit CLI file.
        if self.serial == 0 and not paths:
            self.initial = self.write(self.fixtures / 'initial.txt', 'explicit CLI baseline\n')
            paths = (self.initial,)
        surfaces = {w['id'] for w in self.native_windows()}
        self.target = None
        self.native_ids, self.actions = {}, {}
        self.serial += 1
        self.recovery_root = Path(self.session.env['XDG_STATE_HOME']) / 'coral/recovery'
        self.slot = Path(self.session.env['XDG_STATE_HOME']) / 'coral/sessions/current'
        self.project_store = Path(self.session.env['XDG_STATE_HOME']) / 'coral/projects'
        self.load_gate = self.command_path.with_name('session-load.gate')
        self.session.env.update(CORAL_TEST_COMMAND=str(self.command_path),
                                CORAL_TEST_SESSION_LOAD_PAUSE=str(self.load_gate))
        self.app = self.session.child(f'{self.name}-{self.serial}',
                                      [self.binary, '--width=900', '--height=620', *paths],
                                      G_DEBUG='fatal-criticals')
        self.first_native = wait_for(lambda: next((w['id'] for w in self.native_windows()
                                                  if w['id'] not in surfaces and
                                                  w.get('title', '').endswith('Coral')), None), 15)
        self.bus = self.find_bus()
        self.first_action = wait_for(lambda: min(self.action_paths(), key=self.path_number))
        self.evidence.setdefault('launches', []).append(dict(
            case=self.name, pid=self.app.proc.pid, argv=[str(p) for p in paths], serial=self.serial))
        if not recovery:
            self.ready()
            self.idle()

    @staticmethod
    def path_number(path):
        return int(path.rsplit('/', 1)[1])

    def idle(self):
        return wait_for(lambda: p if not (p := self.probe('projects'))['busy'] and
                        not p['suppression_pending'] and not p['restore_cleanup'] else None, 20)

    def checkpoint(self):
        self.command('project-checkpoint')
        p = self.idle()
        assert p['id'] and p['error_name'] is None and p['writes'] > 0, p
        return p

    def records(self):
        self.command('project-refresh')
        p = self.idle()
        assert p['limit'] == 64 and len(p['records']) <= 64, p
        assert len({r['id'] for r in p['records']}) == len(p['records']), p
        return p['records']

    def record(self, identity):
        return next(r for r in self.records() if r['id'] == identity)

    def observe(self, label, **values):
        self.evidence.setdefault('observations', []).append(dict(case=self.name, label=label, **values))

    def source_bytes(self, label):
        # Only our private state; snapshots are never deserialized from live data.
        files = {p.name: dict(bytes=p.stat().st_size, sha256=digest(p.read_bytes()))
                 for p in sorted(self.project_store.iterdir()) if p.is_file()}
        self.observe(label, project_files=files)
        return files

    def quit_clean(self):
        self.select(self.target, focus=True)
        self.key('q', 'ctrl')
        assert self.app.wait(timeout=20) == 0, self.app.lines[-30:]
        self.no_criticals()
        wait_for(lambda: not any(w['id'] in self.native_ids.values() for w in self.native_windows()))

    def bind_added(self, before, surfaces, paths):
        p = wait_for(lambda: p if len((p := self.windows())['windows']) == len(before) + 1 else None, 20)
        identity = next(w['id'] for w in p['windows'] if w['id'] not in before)
        native = wait_for(lambda: next((w['id'] for w in self.native_windows()
                                       if w['id'] not in surfaces and w.get('title', '').endswith('Coral')), None))
        action = wait_for(lambda: next(iter(self.action_paths() - paths), None))
        self.bind(identity, native, action)
        self.select(identity, focus=True)
        wait_for(lambda: self.state()['documents'])
        self.idle()
        self.drained()
        return identity

    def open_recent(self, identity, keyboard=False):
        self.records()  # targetFromText is deliberately catalog-relative.
        before = {w['id'] for w in self.windows()['windows']}
        surfaces, paths = {w['id'] for w in self.native_windows()}, self.action_paths()
        if keyboard:
            self.show_picker('projects', 'shortcut')
            self.choose_project(identity)
            self.key('Return')
        else:
            self.command('project-open', identity)
        return self.bind_added(before, surfaces, paths)

    def choose_project(self, identity):
        """Filter and navigate actual rows, checking the exact catalog mapping."""
        records = self.probe('projects')['records']
        wanted = next(i for i, r in enumerate(records) if r['id'] == identity)
        path = records[wanted]['path']
        if path:
            self.text(path)
            wait_for(lambda: self.probe('picker')['query'] == path)
        for _ in range(50):
            p = self.probe('picker')
            if p['selected'] == wanted:
                self.observe('keyboard-project-selection', identity=identity, picker=p)
                return
            assert p['selected'] is not None, (identity, p)
            self.key('Down')
            assert self.probe('picker')['selected'] != p['selected'], ('Target is not visible', identity, p)
        raise AssertionError(('Project selection exceeded the bounded displayed rows', identity))

    def retain_state(self):
        # Called after all native writers stop, before PrivateSession removes its
        # temporary HOME. Preserve only test-owned state, never host state.
        destination = self.output / 'artifacts' / self.session.output.name / self.name
        destination.mkdir(parents=True, exist_ok=True)
        files = []
        sources = list(self.project_store.glob('*')) + ([self.slot] if self.slot.exists() else [])
        for source in sources:
            assert source.is_relative_to(self.session.base) and not source.is_symlink(), source
            if not source.is_file():
                continue
            target = destination / ('explicit-session' if source == self.slot else source.name)
            shutil.copyfile(source, target)
            target.chmod(0o600)
            files.append(dict(path=str(target), bytes=target.stat().st_size, sha256=digest(target.read_bytes())))
        self.observe('retained-private-state', files=files)

    def show_picker(self, kind, route='shortcut'):
        self.select(self.target, focus=True)
        if route == 'shortcut':
            assert kind in ('projects', 'buffers')
            self.key('p' if kind == 'projects' else 'o', 'ctrl', 'alt' if kind == 'projects' else 'shift')
        elif route == 'palette':
            self.palette({'projects': 'Open Recent Project', 'buffers': 'Open Buffers',
                          'forget': 'Forget Recent Session'}[kind])
        else:
            self.action('win.' + {'projects': 'recent-projects', 'buffers': 'open-buffers',
                                  'forget': 'forget-project-session'}[kind])
        p = wait_for(lambda: p if (p := self.probe('picker'))['open'] else None)
        assert p['kind'] == kind, p
        self.observe('native-picker-route', route=route, picker=p)
        return p

    def dismiss_picker(self):
        self.key('Escape')
        wait_for(lambda: not self.probe('picker')['open'])

    def bind_startup(self, count):
        self.drained(count)
        paths = sorted(self.action_paths(), key=self.path_number)
        ids = sorted(w['id'] for w in self.windows()['windows'])
        assert len(paths) == len(ids) == count, (paths, ids)
        # GTK and the registry allocate monotonically in creation order. Verify
        # the surface-to-registry part by focusing every real native window.
        for native in self.native_windows():
            if not native.get('title', '').endswith('Coral'):
                continue
            self.ipc.call('command', action='window.activate', fields={'id': native['id']})
            self.target = None
            identity = self.state()['window_id']
            self.bind(identity, native['id'], paths[ids.index(identity)])
        assert set(self.native_ids) == set(ids), (self.native_ids, ids)
        self.select(ids[0], focus=True)
        return ids

    def peer(self):
        # Same private HOME/XDG, distinct real process and command channel.
        peer = object.__new__(ProjectHarness)
        peer.__dict__ = self.__dict__.copy()
        peer.name = self.name + '-peer'
        peer.command_path = self.command_path.with_name('peer-command.ini')
        peer.last = {}
        peer.launch()
        self.session.env['CORAL_TEST_COMMAND'] = str(self.command_path)
        return peer


def two_roots(h):
    roots = [h.fixtures / 'A' / side for side in ('left', 'right')]
    files = [h.write(root / 'same.txt', label + ' shared-W07-token\nsecond α🙂 line\nlast line\n')
             for root, label in zip(roots, ('LEFT', 'RIGHT'))]
    spec = h.write(h.fixtures / 'A.coral-workspace', json.dumps(dict(
        version=1, roots=[dict(path=str(root), name='same') for root in roots])))
    h.open_workspace(spec)
    assert len({r['id'] for r in h.browser()['roots']}) == 2
    return roots, files, spec


def rich_project(h):
    roots, files, spec = two_roots(h)
    h.open_document(files[0])
    h.command('insert', 'DIRTY-A π🙂 ')
    h.command('select', start=18, end=3)
    h.action('win.split-group')
    h.open_document(files[1])
    h.command('select', start=2, end=32)
    h.action('win.excerpt')
    h.command('select', start=12, end=2)
    h.action('win.new')
    h.text('untitled W07 payload α🙂\nnot a source file\n')
    h.command('select', start=15, end=2)
    h.action('win.focus-explorer')
    h.key('Right', 'ctrl', 'alt')
    h.command('dock-resize', 'right', size=310)
    h.action('win.focus-editor')
    h.command('select', start=15, end=2)
    before = semantic(h)
    assert len(before['layout']) == 2 and any(d['dirty'] for d in before['documents'])
    assert any(v['excerpt_start'] is not None for g in before['layout'] for v in g['tabs'])
    assert any(v['insertion'] > v['bound'] for g in before['layout'] for v in g['tabs'])
    identity = h.checkpoint()['id']
    h.observe('W07-before', identity=identity, state=before)
    return identity, before, roots, files, spec


def semantic(h):
    state = h.state()
    return dict(documents=sorted([dict(text=d['text'], dirty=d['dirty'],
                                      # Dirty restored documents are safe unbound copies.
                                      path=None if d['dirty'] else d['path']) for d in state['documents']],
                                    key=lambda d: (d['text'], d['path'] or '')),
                layout=layout(state),
                roots=[(r['path'], r['name']) for r in h.probe('browser')['roots']],
                docks=h.probe('dock')['desired'])


def initial_identity(h):
    p = h.checkpoint()
    assert p['source'] is None and p['path'] is None, p
    assert h.active()[0]['path'] == str(h.initial)
    r = h.record(p['id'])
    assert r['live'] and r['reopen'], r
    assert h.project_store.stat().st_mode & 0o777 == 0o700
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in h.project_store.iterdir())
    h.source_bytes('explicit-cli-baseline')


def automatic_checkpoint(h):
    h.replace_keyboard('automatic first revision α🙂')
    first = wait_for(lambda: p if (p := h.probe('projects'))['writes'] > 0 and not p['busy'] else None, 15)
    assert first['id'] and first['error_name'] is None, first
    original = (h.project_store / 'index').read_bytes()
    h.replace_keyboard('automatic second revision π🙂')
    second = wait_for(lambda: p if (p := h.probe('projects'))['writes'] > first['writes'] and
                      not p['busy'] else None, 15)
    assert second['id'] == first['id'] and second['generation'] > first['generation'], (first, second)
    assert (h.project_store / 'index').read_bytes() != original
    assert h.active()[0]['dirty']
    h.verify_files()
    # Cross an entire debounce interval with no edits: read-only probes must not
    # cause another publication or mint another project identity.
    time.sleep(1.3)
    stable = h.probe('projects')
    assert stable['writes'] == second['writes'] and stable['id'] == second['id'], stable
    h.observe('automatic-no-checkpoint-hook', first=first, second=second, stable=stable)
    h.source_bytes('automatic-revisions')


def picker_routes(h):
    h.checkpoint()
    before = h.state()['documents']
    for kind, routes in (('projects', ('shortcut', 'palette', 'menu')),
                         ('buffers', ('shortcut', 'palette', 'menu')),
                         ('forget', ('palette', 'menu'))):
        for route in routes:
            p = h.show_picker(kind, route)
            assert p['matches'] >= 1, p
            h.text('NO-SUCH-PROJECT-OR-BUFFER-π')
            p = wait_for(lambda: p if (p := h.probe('picker'))['matches'] == 0 else None)
            assert p['selected'] is None and p['visible'] == 0, p
            h.key('Return')
            assert h.probe('picker')['open'], 'Empty activation must not close or select a stale row'
            h.dismiss_picker()
    assert h.state()['documents'] == before


def colliding_search(h):
    roots, files, _ = two_roots(h)
    root_ids = [r['id'] for r in h.browser()['roots']]
    for key, mods, query, mode in (('p', ('ctrl',), 'same.txt', 'quick_open'),
                                   ('f', ('ctrl', 'shift'), 'shared-W07-token', 'text')):
        h.key(key, *mods)
        h.key('a', 'ctrl')
        h.text(query)
        p = wait_for(lambda: p if (p := h.probe('search'))['complete'] and
                     not p['active'] and not p['pending'] and p['query'] == query else None)
        assert p['mode'] == mode and len(p['results']) == 2, p
        assert {r['root_id'] for r in p['results']} == set(root_ids), p
        assert all(r['relative_path'] == 'same.txt' for r in p['results'])
        h.key('Down')
        selected = h.probe('search')['selected_index']
        assert selected is not None
        target = files[root_ids.index(p['results'][selected]['root_id'])]
        h.key('Return')
        wait_for(lambda: h.active()[0]['path'] == str(target))
        assert h.probe('search')['activations'] == p['activations'] + 1
        h.observe('colliding-' + mode, results=p, opened=str(target))
    h.screenshot('colliding-root-identities')


def buffer_identity(h):
    _, files, _ = two_roots(h)
    h.open_document(files[0])
    h.command('insert', 'dirty left ')
    h.action('win.split-group')
    h.open_document(files[1])
    h.command('select', start=0, end=15)
    h.action('win.excerpt')
    h.show_picker('buffers')
    h.text(str(files[1]))
    p = wait_for(lambda: p if (p := h.probe('picker'))['matches'] == 2 else None)
    first = p['selected']
    h.key('Down')
    assert h.probe('picker')['selected'] != first
    h.key('Return')
    wait_for(lambda: not h.probe('picker')['open'])
    doc, view = h.active()
    assert doc['path'] == str(files[1]) and view['excerpt_start'] is not None, (doc, view)
    assert h.document(files[0])['dirty']
    h.show_picker('buffers', 'palette')
    h.text(str(files[0]))
    wait_for(lambda: h.probe('picker')['matches'] == 2)
    h.key('Return')
    assert h.active()[0]['path'] == str(files[0])


def w07_switch(h):
    source, before, _, _, _ = rich_project(h)
    original_window = h.target
    b = h.fixtures / 'B'
    h.write(b / 'b.txt', 'B independent root\n')
    h.workspace(b)
    b_id = h.checkpoint()['id']
    assert b_id != source
    assert not h.record(source)['reopen'] and not h.record(source)['live']
    b_state = semantic(h)
    restored = h.open_recent(source, keyboard=True)
    assert restored != original_window and h.probe('projects')['id'] != source
    after = semantic(h)
    assert after == before, (before, after)
    assert all(d['path'] is None for d in h.state()['documents'] if d['dirty'])
    h.observe('W07-A-B-A', source=source, clone=h.probe('projects')['id'], state=after)
    with h.at(original_window):
        assert semantic(h) == b_state
    # Selecting the same source again must activate A, not clone another window.
    h.select(original_window, focus=True)
    h.records()
    h.show_picker('projects')
    h.choose_project(source)
    h.key('Return')
    wait_for(lambda: any(w['id'] == restored and w['active'] for w in h.windows()['windows']))
    assert h.windows()['live'] == 2
    h.select(restored, focus=True)
    assert semantic(h) == before
    h.text('independent restored A edit')
    with h.at(original_window):
        assert semantic(h) == b_state, 'Restored A edits leaked into B'
    h.screenshot('W07-restored-A-separate-window')


def closed_reopen(h):
    first = h.target
    root = h.fixtures / 'closed-project'
    path = h.write(root / 'closed.txt', 'closed clean text\nsecond line\n')
    h.workspace(root)
    h.open_document(path)
    h.command('select', start=16, end=2)
    h.action('win.split-group')
    h.command('select', start=10, end=1)
    h.action('win.excerpt')
    h.command('select', start=5, end=1)
    source = h.checkpoint()['id']
    before = semantic(h)
    second = h.new_window(keyboard=True)
    h.close_window(first, second, keyboard=True)
    assert not h.record(source)['reopen'] and not h.record(source)['live']
    h.open_recent(source, keyboard=True)
    assert semantic(h) == before, (before, semantic(h))
    h.observe('closed-project-restored', state=semantic(h))


def startup_multi(h):
    first = h.target
    left = h.write(h.fixtures / 'startup-left' / 'one.txt', 'startup left\n')
    h.workspace(left.parent)
    h.open_document(left)
    h.command('select', start=8, end=1)
    left_id = h.checkpoint()['id']
    second = h.new_window(keyboard=True)
    right = h.write(h.fixtures / 'startup-right' / 'two.txt', 'startup right\n')
    h.workspace(right.parent)
    h.open_document(right)
    right_id = h.checkpoint()['id']
    h.quit_clean()
    h.launch()
    ids = h.bind_startup(2)
    seen, clones = [], []
    for identity in ids:
        h.select(identity, focus=True)
        h.idle()
        seen.append(h.probe('browser')['roots'][0]['path'])
        clones.append(h.probe('projects')['id'])
    assert set(seen) == {str(left.parent), str(right.parent)} and len(set(clones)) == 2
    assert not set(clones) & {left_id, right_id}
    records = h.records()
    assert {r['id'] for r in records if r['reopen']} == set(clones), records
    assert all(not h.record(old)['reopen'] for old in (left_id, right_id))
    h.observe('automatic-multiwindow', windows=ids, clones=clones, roots=seen, prior=[first, second])


def cli_precedence(h):
    path = h.write(h.fixtures / 'old-root' / 'old.txt', 'old retained project\n')
    h.workspace(path.parent)
    h.open_document(path)
    source = h.checkpoint()['id']
    h.quit_clean()
    explicit = h.write(h.fixtures / 'explicit.txt', 'explicit CLI wins\n')
    h.launch(explicit)
    assert h.windows()['live'] == 1 and h.active()[0]['path'] == str(explicit)
    assert not h.probe('browser')['roots']
    assert not any(d['path'] == str(path) for d in h.state()['documents'])
    assert not h.record(source)['reopen'], h.record(source)
    h.quit_clean()
    h.launch()
    assert h.windows()['live'] == 1
    assert not any(d['path'] == str(path) for d in h.state()['documents'])


def recovery_precedence(h, keep=False):
    text = 'crash recovery takes precedence π🙂'
    h.replace_keyboard(text)
    source = h.checkpoint()['id']
    journal = h.journals([text])[text]
    raw = journal.read_bytes()
    h.crash()
    h.launch(recovery=True)
    h.app.expect('CORAL_RECOVERY_PROMPT restore')
    if keep:
        h.recovery_choice('F9')
    else:
        h.recovery_choice('F8', 'transferred')
        h.recovery_choice('F10')
    h.ready()
    h.idle()
    docs = h.state()['documents']
    assert h.windows()['live'] == 1
    assert sum(d['text'] == text for d in docs) == (0 if keep else 1), docs
    if keep:
        assert journal.read_bytes() == raw
    else:
        assert all(d['path'] is None and d['dirty'] for d in docs if d['text'] == text)
        assert not journal.parent.exists()
    assert not h.record(source)['reopen']
    prompts = sum('CORAL_RECOVERY_PROMPT restore' in s for s in h.app.lines)
    h.new_window()
    assert sum('CORAL_RECOVERY_PROMPT restore' in s for s in h.app.lines) == prompts
    assert not any(d['text'] == text for d in h.state()['documents'])
    h.observe('recovery-precedence', kept=keep, documents=docs, source=source, journal_sha256=digest(raw))


def empty_recovery(h):
    path = h.initial
    source = h.checkpoint()['id']
    h.quit_clean()
    empty = h.recovery_root / ('s-' + '0' * 34)
    empty.mkdir(mode=0o700, parents=True)
    h.launch()
    assert any(d['path'] == str(path) for d in h.state()['documents'])
    assert not h.probe('lifecycle')['recovery_claimed'] and not empty.exists()
    assert h.probe('projects')['id'] != source and not h.record(source)['reopen']


def live_process_leases(h):
    source = h.checkpoint()['id']
    before = h.state()['documents']
    lease = h.project_store / (source + '.lease')
    with lease.open('rb') as fd:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            raise AssertionError('Native live window did not hold its lifetime lease')
    peer = h.peer()
    try:
        assert peer.app.proc.pid != h.app.proc.pid
        assert peer.windows()['live'] == 1
        assert not any(d['path'] == str(h.initial) for d in peer.state()['documents'])
        assert peer.record(source)['live'] and peer.record(source)['reopen']
        peer.command('project-open', source)
        p = peer.idle()
        assert p['error_name'] == 'LiveSession' and peer.windows()['live'] == 1, p
        peer.records()
        peer.command('project-forget', source)
        assert 'Close this live project first' in peer.state()['notice']
        assert peer.record(source)['reopen']
        peer.observe('live-two-process-exclusion', owner_pid=h.app.proc.pid,
                     contender_pid=peer.app.proc.pid, source=source, project=p)
        h.select(h.target, focus=True)
        assert h.state()['documents'] == before
        h.checkpoint()
        peer.select(peer.target, focus=True)
        assert peer.record(source)['live']
        h.select(h.target, focus=True)
        h.quit_clean()
        peer.select(peer.target, focus=True)
        assert not peer.record(source)['live']
        peer.open_recent(source, keyboard=True)
        assert any(d['path'] == str(h.initial) for d in peer.state()['documents'])
        assert peer.probe('projects')['id'] != source and not peer.record(source)['reopen']
        peer.quit_clean()
    finally:
        if peer.app.proc.poll() is None:
            peer.app.stop()
    if h.app.proc.poll() is None:
        h.select(h.target, focus=True)


def concurrent_startup(h):
    path = h.write(h.fixtures / 'contended-project' / 'retained.txt',
                   'one original startup member; never three clones π🙂\n')
    h.workspace(path.parent)
    h.open_document(path)
    source = h.checkpoint()['id']
    h.quit_clean()
    with fixture_index(h, mutate=False) as index:
        assert sum(bool(e[113]) for e in index['entries']) == 1, index
        original = bytes(next(e for e in index['entries'] if e[:32].decode() == source))
        assert original[113] == 1
        snapshot_path = h.project_store / (original[32:64].decode() + '.snap')
        snapshot_hash = digest(snapshot_path.read_bytes())
        assert snapshot_hash == original[64:96].hex()

    peers, aligned = [], []
    fd = os.open(h.project_store, os.O_RDONLY | os.O_DIRECTORY)
    began = time.monotonic()
    try:
        # Shared reads admit all three startup catalogs; exclusive source claims
        # wait. Release on observed startup intent, not a guessed sleep. Keep the
        # gate below the worker's one-second Busy retry budget.
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        for number in range(3):
            peer = object.__new__(ProjectHarness)
            peer.__dict__ = h.__dict__.copy()
            peer.name = h.name + '-contender-' + str(number)
            peer.command_path = h.command_path.with_name('startup-' + str(number) + '.ini')
            peer.target, peer.native_ids, peer.actions, peer.last = None, {}, {}, {}
            peer.serial += 1
            peer.app = h.session.child(peer.name, [h.binary, '--width=900', '--height=620'],
                                       CORAL_TEST_COMMAND=str(peer.command_path), G_DEBUG='fatal-criticals')
            peers.append(peer)
            h.evidence.setdefault('launches', []).append(dict(
                case=peer.name, pid=peer.app.proc.pid, argv=[], serial=peer.serial))

        def all_listed():
            aligned.clear()
            for peer in peers:
                peer.alive()
                candidates = [json.loads(line.removeprefix('CORAL_PROJECTS '))
                              for line in peer.app.lines if line.startswith('CORAL_PROJECTS ')]
                observed = next((p for p in candidates if p['restoring'] and any(
                    r['id'] == source and r['reopen'] and not r['live'] for r in p['records'])), None)
                if observed is None:
                    return False
                aligned.append(dict(pid=peer.app.proc.pid, project=observed))
            return True

        wait_for(all_listed, .8)
        assert time.monotonic() - began < .9, 'Startup gate approached the Busy retry deadline'
    finally:
        os.close(fd)
        h.observe('concurrent-startup-gate', source=source, seconds=time.monotonic() - began,
                  aligned=aligned.copy(), pids=[p.app.proc.pid for p in peers])
    assert len({p.app.proc.pid for p in peers}) == 3

    # Map concurrently created surfaces by their child's actual probe response.
    # A bus action cannot reliably acquire Wayland focus without an input token,
    # and identical titles/registry IDs do not identify the owning process.
    surfaces = wait_for(lambda: w if len(w := h.native_windows()) == 3 else None)
    bound = set()
    for surface in surfaces:
        for peer in peers:
            peer.command_path.write_text('[Test]\naction=workspace-probe\n')
        starts = [len(peer.app.lines) for peer in peers]
        h.ipc.call('command', action='window.activate', fields={'id': surface['id']})
        peers[0].key('F11')

        def acknowledged():
            replies = [(peer, line) for peer, start in zip(peers, starts)
                       for line in peer.app.lines[start:] if line.startswith('CORAL_WORKSPACE ')]
            return replies or None

        replies = wait_for(acknowledged)
        assert len(replies) == 1, replies
        peer, line = replies[0]
        assert peer.app.proc.pid not in bound, 'Two surfaces mapped to the same contender'
        bound.add(peer.app.proc.pid)
        peer.first_native = surface['id']
        peer.target = json.loads(line.removeprefix('CORAL_WORKSPACE '))['window_id']
        peer.bus = peer.find_bus()
        paths = peer.action_paths()
        assert len(paths) == 1, paths
        peer.first_action = paths.pop()
        peer.bind(peer.target, peer.first_native, peer.first_action)

    observations, winners, losers = [], [], []
    for peer in peers:
        peer.select(peer.target, focus=True)
        project = peer.idle()
        peer.drained(1)
        state = peer.state()
        browser = peer.browser()
        loaded = any(d['path'] == str(path) for d in state['documents'])
        (winners if loaded else losers).append(peer)
        peer.no_criticals()
        observations.append(dict(pid=peer.app.proc.pid, project=project, loaded=loaded,
                                 documents=state['documents'], roots=browser['roots']))
    h.observe('concurrent-startup-result', source=source, processes=observations,
              winners=len(winners), source_snapshot_sha256=snapshot_hash)
    assert len(winners) == 1, ('Original startup member cloned by multiple processes', observations)
    assert len(losers) == 2
    winner = winners[0]
    clone = next(p['project']['id'] for p in observations if p['loaded'])
    assert clone and clone != source
    for result in observations:
        if not result['loaded']:
            assert result['project']['error_name'] == 'Conflict', result
            assert not result['roots'] and all(d['path'] is None and not d['text'] and not d['dirty']
                                               for d in result['documents']), result

    def membership(label):
        def inspect():
            try:
                with fixture_index(h, mutate=False) as index:
                    source_entry = bytes(next(e for e in index['entries'] if e[:32].decode() == source))
                    expected = bytearray(original)
                    expected[113] = 0
                    assert source_entry == expected, ('Source resurrected or rewritten', label, source_entry)
                    assert digest(snapshot_path.read_bytes()) == snapshot_hash
                    projects = [dict(id=e[:32].decode(), reopen=bool(e[113]))
                                for e in index['entries'] if e[112] == 1]
                    assert {r['id'] for r in projects} == {source, clone}, (label, projects)
                    assert [r['id'] for r in projects if r['reopen']] == [clone], (label, projects)
                    return projects
            except BlockingIOError:
                return None
        records = wait_for(inspect, 10)
        h.verify_files()
        h.observe('concurrent-startup-membership', phase=label, records=records,
                  source_snapshot_sha256=snapshot_hash)

    membership('all-three-live-after-failed-claim-cleanup')
    for number, peer in enumerate(losers):
        peer.select(peer.target, focus=True)
        assert not peer.probe('lifecycle')['frozen']
        marker = 'losing startup remains usable ' + str(number)
        peer.text(marker)
        assert peer.active()[0]['text'] == marker and peer.active()[0]['dirty']
        membership('loser-' + str(number) + '-edited')
        peer.key('q', 'ctrl')
        wait_for(lambda: peer.probe('lifecycle')['dialog'] == 'close')
        peer.command('respond', response=1, allow_exit=True)
        assert peer.app.wait(timeout=20) == 0, peer.app.lines[-30:]
        peer.no_criticals()
        wait_for(lambda: not any(w['id'] == peer.first_native for w in h.native_windows()))
        membership('loser-' + str(number) + '-closed')
    winner.select(winner.target, focus=True)
    assert winner.document(path)['text'] == path.read_text()
    winner.quit_clean()
    membership('all-three-closed')
    assert not h.native_windows()
    assert all(peer.app.proc.poll() == 0 for peer in peers)
    h.observe('concurrent-startup-clean-exits', exitcodes=[peer.app.proc.poll() for peer in peers])


def delayed_close(h, fault=False):
    h.command('select', start=1, end=15)
    h.action('win.excerpt')
    h.checkpoint()
    before = h.state()['documents']
    late = h.write(h.fixtures / 'late.txt', 'late open must not publish\n')
    h.command('project-delay', 4000)
    h.action('win.close-window')
    wait_for(lambda: h.probe('projects')['closing_write'])
    life = h.probe('lifecycle')
    assert life['frozen'] and life['full_views'] and life['excerpt_views'], life
    assert life['full_editable'] == life['excerpts_editable'] == 0, life
    h.text('BLOCKED-BY-FINAL-SNAPSHOT')
    h.command('open', late)
    assert h.state()['documents'] == before
    h.observe('final-snapshot-freeze', lifecycle=life, fault=fault)
    if fault:
        h.command('project-insert-canonical', 'CANONICAL-FAULT')
        wait_for(lambda: not h.probe('projects')['closing_write'])
        life = h.probe('lifecycle')
        assert not life['frozen'] and life['full_editable'] and life['excerpts_editable'], life
        assert 'kept open' in life['notice'] and h.app.proc.poll() is None, life
        assert any('CANONICAL-FAULT' in d['text'] for d in h.state()['documents'])
        h.stop()
        h.launch()
        assert not any('CANONICAL-FAULT' in d['text'] for d in h.state()['documents'])
    else:
        assert h.app.wait(timeout=15) == 0
        h.no_criticals()


def cancel_quit(h):
    first = h.target
    h.command('select', start=0, end=12)
    h.action('win.excerpt')
    h.command('insert', 'dirty first ')
    second = h.new_window()
    h.text('dirty second π🙂')
    h.action('win.quit')
    wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close')
    for identity in (first, second):
        h.select(identity)
        life = h.probe('lifecycle')
        assert life['frozen'] and life['full_editable'] == life['excerpts_editable'] == 0, life
    h.select(second)
    h.command('respond', response=0)
    for identity in (first, second):
        h.select(identity)
        life = h.probe('lifecycle')
        assert not life['frozen'] and life['full_editable'] == life['full_views'], life
        assert life['excerpts_editable'] == life['excerpt_views'], life
    assert h.windows()['live'] == 2 and not h.windows()['quitting']
    h.select(second, focus=True)
    h.text(' after canceled quit')
    assert 'after canceled quit' in h.active()[0]['text']


def save_failure(h):
    h.command('insert', 'unsaved after failed close ')
    before = h.active()[0]
    parent_mode = h.initial.parent.stat().st_mode & 0o777
    file_mode = h.initial.stat().st_mode & 0o777
    # GIO may fall back from atomic replacement to an in-place write when only
    # the directory is read-only. Deny both paths for an actual save failure.
    h.initial.parent.chmod(0o500)
    h.initial.chmod(0o400)
    try:
        h.key('q', 'ctrl')
        wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close')
        h.command('respond', response=2)
        wait_for(lambda: any('event=document-save-failed' in line for line in h.app.lines))
        life = wait_for(lambda: p if not (p := h.probe('lifecycle'))['frozen'] else None)
        assert life['active_dirty'] and h.active()[0]['text'] == before['text'], life
        assert not h.windows()['quitting']
    finally:
        h.initial.chmod(file_mode)
        h.initial.parent.chmod(parent_mode)
    h.verify_files()  # A failed save must not alter the original disk bytes.
    h.key('s', 'ctrl')
    wait_for(lambda: not h.active()[0]['dirty'])
    h.expected[h.initial] = digest(h.initial.read_bytes())
    assert h.initial.read_text() == before['text']


def oversize(h, dirty=False):
    large = h.write(h.fixtures / 'large.txt', b'0123456789abcdef\n' * 310000)
    assert large.stat().st_size > 5 * 1024 * 1024
    h.command('open', large)
    # Do not send a 5MiB workspace JSON probe repeatedly through the harness.
    wait_for(lambda: (h.probe('lifecycle')['active_revision'] or 0) > 0)
    h.drained()
    if dirty:
        h.command('insert', 'DIRTY-OVERSIZE')
    h.action('win.close-window')
    wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close_without_session')
    h.command('respond', response=0)
    assert not h.probe('lifecycle')['frozen']
    h.action('win.close-window')
    wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close_without_session')
    if dirty:
        h.command('respond', response=1)
        wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close')
        h.command('respond', response=0)
        p = h.probe('lifecycle')
        assert not p['frozen'] and p['active_dirty'], p
        h.action('win.close-window')
        wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close_without_session')
        h.command('respond', response=1)
        wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close')
    h.command('respond', response=1, allow_exit=True)
    assert h.app.wait(timeout=20) == 0
    h.no_criticals()
    h.observe('explicit-oversize-optout', dirty=dirty, bytes=large.stat().st_size)


def closed_record(h):
    first = h.target
    source = h.checkpoint()['id']
    second = h.new_window()
    h.close_window(first, second)
    assert not h.record(source)['live']
    return source


def forget_confirmation(h):
    source = closed_record(h)
    h.action('win.save-workspace-session')
    wait_for(lambda: h.probe('session')['status'] == 'saved')
    explicit = h.slot.read_bytes()
    h.show_picker('forget', 'palette')
    h.choose_project(source)
    h.key('Return')
    wait_for(lambda: not h.probe('picker')['open'])
    # Default/escape really cancels the GTK confirmation, not merely the picker.
    h.key('Escape')
    assert any(r['id'] == source for r in h.records())
    h.command('project-forget', source)
    h.command('project-forget', 'accept')
    assert not any(r['id'] == source for r in h.records())
    assert h.slot.read_bytes() == explicit, 'Forget changed the explicit checkpoint'
    h.verify_files()


def forget_live(h):
    source = h.checkpoint()['id']
    before = h.state()['documents']
    h.records()
    h.command('project-forget', source)
    assert 'Close this live project first' in h.state()['notice']
    h.command('project-forget', 'accept')
    assert h.record(source)['live'] and h.state()['documents'] == before


INDEX_HEADER = b'CORAL-PROJECTS 1\n'


@contextmanager
def fixture_index(h, mutate=True):
    """Version-checked private catalog; read-only inspection never republishes it."""
    assert h.project_store.is_relative_to(h.session.base)
    fd = os.open(h.project_store, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, (fcntl.LOCK_EX if mutate else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        path = h.project_store / 'index'
        raw = path.read_bytes()
        assert raw.startswith(INDEX_HEADER), 'Update the fixture codec for the new index version'
        payload = raw[len(INDEX_HEADER) + 32:]
        assert hashlib.sha256(payload).digest() == raw[len(INDEX_HEADER):len(INDEX_HEADER) + 32]
        clock, count = struct.unpack_from('<qH', payload)
        entries, offset = [], 10
        for _ in range(count):
            start = offset
            offset += 115  # id, revision, hash, size, generation, source/reopen/roots
            for _ in range(2):
                length = struct.unpack_from('<H', payload, offset)[0]
                offset += 2 + length
            entries.append(bytearray(payload[start:offset]))
        assert offset == len(payload)
        state = dict(clock=clock, entries=entries)
        yield state
        if not mutate:
            return
        body = struct.pack('<qH', state['clock'], len(entries)) + b''.join(entries)
        pending = h.project_store / 'fixture-index.tmp'
        pending.write_bytes(INDEX_HEADER + hashlib.sha256(body).digest() + body)
        pending.chmod(0o600)
        os.replace(pending, path)
    finally:
        os.close(fd)


def stale_forget(h):
    source = closed_record(h)
    h.records()
    h.command('project-forget', source)
    # Simulate another writer publishing after the confirmation captured its
    # generation. Keep the snapshot and identity valid; only freshness changes.
    with fixture_index(h) as index:
        index['clock'] += 1
        entry = next(e for e in index['entries'] if e[:32].decode() == source)
        struct.pack_into('<q', entry, 104, index['clock'])
    h.command('project-forget', 'accept')
    p = h.idle()
    assert p['error_name'] == 'Conflict', p
    assert h.record(source)['updated'] == index['clock']
    h.observe('stale-forget-rejected', project=p)


def retirement_failure(h):
    root = h.fixtures / 'old'
    path = h.write(root / 'retained.txt', 'retained through failed switch\n')
    h.workspace(root)
    h.open_document(path)
    h.command('insert', 'dirty old ')
    source = h.checkpoint()['id']
    before = semantic(h)
    new = h.fixtures / 'new'
    new.mkdir()
    h.project_store.chmod(0o500)
    try:
        h.command('open-folder', new)
        wait_for(lambda: not h.probe('browser')['loading'])
        assert h.probe('browser')['roots'][0]['path'] == str(root)
        assert h.probe('projects')['id'] == source and semantic(h) == before
    finally:
        h.project_store.chmod(0o700)
    h.workspace(new)
    assert h.checkpoint()['id'] != source
    h.open_recent(source)
    assert semantic(h) == before


def capacity(h):
    source = h.checkpoint()['id']
    h.quit_clean()
    # Fill from real native snapshots, not a cached external Zig executable.
    with fixture_index(h) as index:
        source_entry = next(e for e in index['entries'] if e[:32].decode() == source)
        revision = source_entry[32:64].decode()
        snapshot = (h.project_store / (revision + '.snap')).read_bytes()
        for _ in range(len(index['entries']), 64):
            entry = bytearray(source_entry)
            entry[:32] = uuid.uuid4().hex.encode()
            revision = uuid.uuid4().hex
            entry[32:64] = revision.encode()
            index['clock'] += 1
            struct.pack_into('<q', entry, 104, index['clock'])
            entry[113] = 0  # Closed; do not create 64 startup windows.
            target = h.project_store / (revision + '.snap')
            target.write_bytes(snapshot)
            target.chmod(0o600)
            index['entries'].append(entry)
    original = h.source_bytes('catalog-at-64')
    h.launch()
    p = h.idle()
    assert p['id'] is None and p['error_name'] == 'TooManySessions', p
    assert all(d['path'] is None and not d['text'] for d in h.state()['documents'])
    records = h.records()
    assert len(records) == 64 and h.record(source)['reopen']
    assert all(not r['live'] for r in records)
    h.quit_clean()
    for name, record in original.items():
        if name.endswith('.snap'):
            assert digest((h.project_store / name).read_bytes()) == record['sha256']
    h.launch()
    h.command('insert', 'dirty while catalog full')
    h.command('project-checkpoint')
    assert h.idle()['error_name'] == 'TooManySessions'
    h.action('win.quit')
    wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close')
    h.command('respond', response=1)
    wait_for(lambda: h.probe('lifecycle')['dialog'] == 'close_without_session')
    h.command('respond', response=1, allow_exit=True)
    assert h.app.wait(timeout=20) == 0
    h.launch()
    spare = next(r['id'] for r in h.records() if r['id'] != source)
    h.command('project-forget', spare)
    h.command('project-forget', 'accept')
    assert len(h.records()) == 63
    # The source is older than the picker's displayed prefix of 50. Open this
    # exact ID through the controller rather than accidentally selecting a copy.
    h.open_recent(source)
    assert any(d['path'] == str(h.initial) for d in h.state()['documents'])
    assert not h.record(source)['reopen'], 'The original source was not consumed'
    assert len(h.records()) == 64 and h.probe('projects')['id'] != source
    h.observe('capacity-source-survived', source=source, restored=h.probe('projects')['id'])


SCENARIOS = [
    ('explicit_cli_initial_identity', initial_identity),
    ('automatic_debounced_checkpoint_stable_identity', automatic_checkpoint),
    ('native_shortcuts_palette_menu_picker_routes', picker_routes),
    ('W07_colliding_roots_search_quick_open_identity', colliding_search),
    ('buffer_picker_group_excerpt_identity', buffer_identity),
    ('W07_A_B_A_dirty_untitled_groups_excerpt_docks_selection', w07_switch),
    ('closed_project_reopen_preserves_layout', closed_reopen),
    ('automatic_no_cli_multiwindow_startup', startup_multi),
    ('explicit_cli_precedence_suppresses_previous_membership', cli_precedence),
    ('recovery_restore_precedence_no_duplicates', recovery_precedence),
    ('recovery_keep_precedence_no_duplicates', lambda h: recovery_precedence(h, keep=True)),
    ('empty_recovery_does_not_suppress_projects', empty_recovery),
    ('two_live_processes_lease_exclusion', live_process_leases),
    ('three_concurrent_ordinary_startups_consume_member_once', concurrent_startup),
    ('delayed_final_snapshot_freezes_full_and_excerpt', delayed_close),
    ('canonical_fault_rejects_final_close', lambda h: delayed_close(h, fault=True)),
    ('cancel_quit_thaws_all_windows', cancel_quit),
    ('save_failure_cancels_quit_preserves_edits', save_failure),
    ('oversize_clean_explicit_optout', oversize),
    ('oversize_dirty_optout_still_resolves_edits', lambda h: oversize(h, dirty=True)),
    ('closed_record_forget_confirmation_and_explicit_slot', forget_confirmation),
    ('live_record_forget_refusal', forget_live),
    ('stale_generation_forget_rejected', stale_forget),
    ('failed_retirement_preserves_old_project', retirement_failure),
    ('catalog_cap64_preserves_source_and_explicit_forget_frees_slot', capacity),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-projects')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', choices=[name for name, _ in SCENARIOS])
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scenarios = [(name, run) for name, run in SCENARIOS if not args.case or name in args.case]
    began, budget = time.monotonic(), 550
    evidence = dict(status='running', checks=[], invocation=[sys.executable, *sys.argv],
                    binary=str(args.binary.resolve()), runtime_budget_seconds=budget,
                    selected_cases=[name for name, _ in scenarios], total_available_cases=len(SCENARIOS),
                    isolation='Private compositor/D-Bus; per-case disposable HOME/XDG and fixtures; no live user data',
                    scope='M2/W07 projects, native keyboard/palette/menu pickers; roots editing covered separately')

    def expired(_signal, _frame):
        raise BudgetExpired('Project acceptance exceeded its bounded runtime')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(budget)
    save(output, evidence)
    try:
        binary = args.binary.resolve().read_bytes()
        evidence['binary_sha256'] = digest(binary)
        assert all(marker in binary for marker in (b'CORAL_PROJECTS ', b'CORAL_PICKER ', b'CORAL_LIFECYCLE ')), 'Build with -Dtest-hooks=true'
        del binary
        # Unique runs never erase earlier evidence or recycle an old private HOME.
        with PrivateSession(output / ('session-' + str(time.time_ns())), tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='C.UTF-8', LC_ALL='C.UTF-8', LANGUAGE='en_US')
            styles = stage_styles(session, evidence)
            for name, scenario in scenarios:
                record = dict(name=name, status='running')
                evidence['checks'].append(record)
                save(output, evidence)
                start, h, child_start = time.monotonic(), None, len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = ProjectHarness(session, args.binary.resolve(), output, evidence, name,
                                       min(began + budget - 5, start + 150))
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_hashes={str(p): v for p, v in h.expected.items()})
                    print('PASS', name, flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc(),
                                  last_probe=h.last.copy() if h else {})
                    print('FAIL', name, str(exc)[:1800], flush=True)
                    if h:
                        for label, operation in (('screenshot', lambda: h.screenshot('failure')),
                                                 ('fixture_integrity', h.verify_files), ('gtk_warnings', h.no_criticals)):
                            try:
                                operation()
                            except Exception:
                                record[label + '_error'] = traceback.format_exc()
                finally:
                    if h:
                        h.load_gate.unlink(missing_ok=True)
                    record['native_logs'] = [str(child.logfile) for child in session.children[child_start:]]
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    if h:
                        try:
                            h.retain_state()
                        except Exception:
                            record.update(status='failed', artifact_error=traceback.format_exc())
                    del session.children[child_start:]
                    record['seconds'] = time.monotonic() - start
                    save(output, evidence)
            for entry in styles:
                for key in ('source', 'path'):
                    assert digest(Path(entry[key]).read_bytes()) == entry['sha256'], entry
        evidence['status'] = 'passed' if all(c['status'] == 'passed' for c in evidence['checks']) else 'failed'
    except (Exception, BudgetExpired):
        evidence.update(status='failed', fatal=traceback.format_exc())
        print(evidence['fatal'], file=sys.stderr, flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        completed = {c['name'] for c in evidence['checks']}
        for name, _ in scenarios:
            if name not in completed:
                evidence['checks'].append(dict(name=name, status='blocked', reason='Setup/runtime budget failed'))
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        evidence['counts'] = {status: sum(c['status'] == status for c in evidence['checks'])
                              for status in ('passed', 'failed', 'blocked')}
        save(output, evidence)
    print(f"{evidence['status'].upper()}: {evidence['counts']}; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
