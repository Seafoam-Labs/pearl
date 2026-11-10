#!/usr/bin/env python3
"""Native workspace-operation acceptance, exclusively in private Wayland/HOME/XDG.

  zig build operations -Doptimize=safe -j1 --summary all
  python3 tests/operations.py --binary /path/to/coral-test --case palette_workflow

Reuse windows.WindowHarness (and its Case-like per-scenario isolation), never its
main/scenarios. Real palette, exported menu GActions, explorer pointer clicks,
entry typing and dialog button clicks exercise the UI; F11 submissions cover
bounded adversarial/race fixtures through the same prepare/review/apply workers.
No shell filesystem commands, live workspaces, recursive deletion or source edits.
Snapshots use lstat and never read a FIFO or follow a fixture symlink. Evidence is
retained on failure. Delays establish observable pending work, not speed claims;
these tests do not claim atomic protection against hostile syscall-boundary races.
"""
import argparse
import json
import os
import signal
import stat
import sys
import time
import traceback
from pathlib import Path

from windows import (WindowHarness, PEARL, PrivateSession, fixture_prefix,
                     wait_for, stage_styles, digest, save, BudgetExpired,
                     pointer_move, pointer_click, resource_sample, start_accessibility)


KINDS = ('create_file', 'create_directory', 'rename', 'move', 'delete')
LABELS = dict(zip(KINDS, ('Explorer: New file…', 'Explorer: New directory…',
                        'Explorer: Rename…', 'Explorer: Move…',
                        'Explorer: Delete permanently…')))
TITLES = dict(zip(KINDS, ('Create file', 'Create directory', 'Rename entry',
                        'Move entry', 'Delete entry permanently')))
ACTIONS = dict(zip(KINDS, ('workspace-create-file', 'workspace-create-directory',
                         'workspace-rename', 'workspace-move', 'workspace-delete')))


def tree(path):
    result = {}

    def walk(directory):
        for child in sorted(directory.iterdir()):
            mode = child.lstat().st_mode
            key = child.relative_to(path).as_posix()
            if stat.S_ISLNK(mode):
                result[key] = dict(kind='symlink', target=os.readlink(child))
            elif stat.S_ISDIR(mode):
                result[key] = dict(kind='directory')
                walk(child)
            elif stat.S_ISREG(mode):
                result[key] = dict(kind='file', sha256=digest(child.read_bytes()))
            else:
                result[key] = dict(kind='special', mode=stat.S_IFMT(mode))
    walk(path)
    return result


class Case(WindowHarness):
    def setup(self):
        self.root = self.fixtures / 'root'
        self.write(self.root / 'source.txt', 'original π🙂 bytes\n')
        self.write(self.root / 'nested/child.txt', 'descendant bytes\n')
        self.write(self.fixtures / 'outside.txt', 'outside must stay intact\n')
        (self.root / 'destination').mkdir()
        (self.root / 'empty').mkdir()
        self.workspace(self.root)
        self.ipc.call('command', action='window.maximized', fields={'id': self.native_ids[self.target], 'value': True})
        wait_for(lambda: (p := self.probe('dock'))['width'] >= 1000 and p['height'] >= 650, 6)
        self.seal()

    def seal(self):
        # Called only after fixture construction or explicit external race edits.
        self.expected_tree = tree(self.fixtures)

    def assert_tree(self, expected=None, label='unchanged'):
        expected = self.expected_tree if expected is None else expected
        actual = tree(self.fixtures)
        delta = {key: dict(expected=expected.get(key), actual=actual.get(key))
                 for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key)}
        self.evidence.setdefault('filesystem_checks', []).append(
            dict(case=self.name, label=label, expected=expected, actual=actual, delta=delta))
        assert not delta, (label, delta)
        self.expected_tree = expected.copy()

    def verify_files(self):
        if hasattr(self, 'expected_tree'):
            self.assert_tree(label='final fixture integrity')
        else:
            super().verify_files()

    def ops(self):
        p = self.probe('operations')
        assert 0 <= p['jobs_started'] - p['jobs_reaped'] <= 1, p
        if not p['busy']:
            assert not p['dialog'] and not p['barrier'], p
            assert p['jobs_started'] == p['jobs_reaped'], p
        return p

    def state_is(self, state):
        return wait_for(lambda: p if (p := self.ops())['state'] == state else None, 12)

    def finished(self, state, errors=None):
        p = wait_for(lambda: p if not (p := self.ops())['busy'] else None, 12)
        assert p['state'] == state, p
        if errors is not None:
            assert p['err'] in errors, p
        self.evidence.setdefault('operations', []).append(dict(case=self.name, result=p))
        self.browser()
        registry = self.drained()
        assert registry['file_operation_owner'] is None, registry
        return p

    def request(self, kind, source='', destination='', root=0):
        self.browser()
        before = self.ops()['completed']
        self.command('operations-request', kind, source=source, destination=destination, root=root)
        return before

    def review(self, kind, source='', destination='', root=0):
        before = self.request(kind, source, destination, root)
        p = self.state_is('confirming')
        assert p['kind'] == kind and p['dialog'] and not p['barrier'], p
        assert p['completed'] == before, p
        self.assert_tree(label='review has no mutation')
        return before

    def apply(self, before, click=False):
        if click:
            self.click_dialog('Confirm workspace file operation')
        else:
            self.command('operations-respond', 'accept')
        p = self.finished('succeeded', {None})
        assert p['completed'] == before + 1, p
        return p

    def rejected(self, kind, source='', destination='', errors=None, root=0):
        before = self.request(kind, source, destination, root)
        p = self.finished('failed', errors)
        assert p['completed'] == before, p
        self.assert_tree(label='rejection has no mutation')

    def expect_change(self, kind, source='', destination=''):
        expected = self.expected_tree.copy()
        src, dst = 'root/' + source, 'root/' + destination
        if kind == 'create_file':
            expected[dst] = dict(kind='file', sha256=digest(b''))
        elif kind == 'create_directory':
            expected[dst] = dict(kind='directory')
        elif kind == 'delete':
            del expected[src]
        else:
            if kind == 'rename':
                dst = str(Path(src).parent / destination)
            moving = {key: value for key, value in expected.items()
                      if key == src or key.startswith(src + '/')}
            assert moving, src
            for key, value in moving.items():
                del expected[key]
                expected[dst + key[len(src):]] = value
        self.assert_tree(expected, label='exact ' + kind + ' mutation')

    def click_dialog(self, title, accept=True):
        surface = wait_for(lambda: next((w for w in self.native_windows()
                                        if w.get('title') == title), None))
        self.ipc.call('command', action='window.activate', fields={'id': surface['id']})
        # GtkDialog's trailing action buttons, anchored to the actual transient
        # allocation rather than an assumed compositor origin.
        # Initial map geometry can precede the compositor's placement transaction.
        time.sleep(.2)
        self.screenshot(title.replace(' ', '-') + '-before-click')
        surface = next(w for w in self.native_windows() if w['id'] == surface['id'])
        box = surface['geometry']
        x, y = box['x'] + box['width'] - (40 if accept else 115), box['y'] + box['height'] - 22
        pointer_move(self.session, x, y)
        pointer_click(self.session)
        self.evidence.setdefault('pointer_routes', []).append(
            dict(case=self.name, title=title, accept=accept, pointer=[x, y], surface=surface))
        wait_for(lambda: all(w['id'] != surface['id'] for w in self.native_windows()), 5)

    def select_row(self, relative=''):
        self.select(self.target, focus=True)
        self.command('workspace-roots')
        self.command('browser-activate', index=0)
        p = self.browser()
        # This fixture has one expanded root. Arrow navigation changes the real
        # GtkSingleSelection without activating/opening the affected document.
        index = 0 if not relative else 1 + next(i for i, e in enumerate(p['entries']) if e['name'] == relative)
        self.action('win.focus-explorer')
        self.key('Home')
        for _ in range(index):
            self.key('Down')
        p = self.probe('browser')
        assert p['selected_path'] == relative, (relative, index, p)

    def ui_start(self, kind, selected='', palette=True):
        self.select_row(selected)
        if palette:
            self.palette(LABELS[kind])
        else:
            self.action('win.' + ACTIONS[kind])
        p = self.state_is('input')
        assert p['kind'] == kind and not p['barrier'], p
        self.assert_tree(label='input has no mutation')
        return p['completed']

    def ui_review(self, kind, destination='', keyboard=True):
        if keyboard:
            if kind != 'delete':
                self.key('a', 'ctrl')
                self.text(destination)
            self.click_dialog(TITLES[kind])
        else:
            self.command('operations-input', destination)
        p = self.state_is('confirming')
        self.assert_tree(label='UI review has no mutation')
        return p

    def close_document(self, path, dirty=False):
        # Opening the first file can reuse the initial blank document. Explicitly
        # retain an unnamed buffer before closing the affected document.
        self.action('win.new')
        self.open_document(path)
        self.action('win.close')
        if dirty:
            wait_for(lambda: self.state()['dialog'])
            self.command('respond', response=1)
        wait_for(lambda: self.document(path) is None)
        assert any(d['path'] is None for d in self.state()['documents']), self.state()
        self.drained()


def palette_workflow(h):
    for kind, source, destination in (
            ('create_file', '', '-π🙂.txt'),
            ('rename', '-π🙂.txt', '-renamed 終.txt'),
            ('move', '-renamed 終.txt', 'destination/-moved π.txt'),
            ('delete', 'source.txt', '')):
        before = h.ui_start(kind, source)
        h.ui_review(kind, destination)
        h.screenshot(kind + '-review')
        h.apply(before, click=True)
        h.expect_change(kind, source, destination)


def explorer_buttons(h):
    h.select_row()
    h.command('settings', theme=1, font=14)
    h.screenshot('explorer-before-click')
    route = h.click_accessible('New file…')
    h.evidence.setdefault('pointer_routes', []).append(
        dict(case=h.name, action='workspace-create-file', pointer=route['pointer'], control=route['control']))
    before = h.state_is('input')['completed']
    h.ui_review('create_file', 'clicked.txt')
    h.click_dialog('Confirm workspace file operation', accept=False)
    p = h.finished('cancelled')
    assert p['completed'] == before
    h.assert_tree()
    # Native exported menu action, plus real entry/review/confirm buttons.
    before = h.ui_start('create_directory', palette=False)
    h.ui_review('create_directory', 'clicked-directory')
    h.apply(before, click=True)
    h.expect_change('create_directory', destination='clicked-directory')


def filesystem_success(h):
    for kind, source, destination in (
            ('create_file', '', 'empty-file'), ('create_directory', '', '-new π'),
            ('rename', 'source.txt', '-renamed π🙂'),
            ('move', '-renamed π🙂', 'destination/-moved 終'),
            ('delete', 'destination/-moved 終', ''), ('delete', 'empty', '')):
        h.apply(h.review(kind, source, destination))
        h.expect_change(kind, source, destination)


def cancel_kind(h, kind):
    source = '' if kind.startswith('create_') else 'source.txt'
    destination = '' if kind == 'delete' else 'cancelled'
    # Cover every real command's input cancellation as well as prepared review.
    before = h.ui_start(kind, source, palette=False)
    h.command('operations-cancel')
    assert h.finished('cancelled')['completed'] == before
    h.assert_tree()
    before = h.review(kind, source, destination)
    h.command('operations-respond', 'anything-is-cancel')
    assert h.finished('cancelled')['completed'] == before
    h.assert_tree()


def stale_review(h, variant):
    source = 'nested/child.txt' if variant == 'parent_rename' else 'source.txt'
    before = h.review('move', source, 'destination/moved.txt')
    if variant == 'replacement':
        replacement = h.root / 'replacement'
        replacement.write_text('replacement inode must survive\n')
        replacement.replace(h.root / source)
    elif variant == 'edit':
        (h.root / source).write_text('external longer source edit must survive\n')
    elif variant == 'parent_rename':
        (h.root / 'nested').rename(h.root / 'renamed-parent')
    elif variant == 'root_rename':
        h.root.rename(h.fixtures / 'renamed-root')
    elif variant == 'collision':
        (h.root / 'destination/moved.txt').write_text('late destination must survive\n')
    h.seal()
    h.command('operations-respond', 'accept')
    p = h.finished('failed', {'StaleSnapshot', 'WorkspaceChanged', 'AlreadyExists', 'UnavailableRoot'})
    assert p['completed'] == before
    h.assert_tree(label='external edit retained; stale review did not mutate')


def rejected_paths(h):
    for kind, source, destination, errors in (
            ('create_file', '', '../escaped', {'InvalidPath'}),
            ('create_directory', '', '.git/objects', {'GitPath'}),
            ('create_file', '', 'destination//bad', {'InvalidPath'}),
            ('create_file', '', './bad', {'InvalidPath'}),
            ('create_file', '', str(h.fixtures / 'outside-new'), {'InvalidDestination'}),
            ('move', 'source.txt', '../outside.txt', {'InvalidPath'}),
            ('rename', 'source.txt', 'destination/new', {'InvalidRename'}),
            ('delete', '../outside.txt', '', {'InvalidPath'}),
            ('rename', '', 'renamed-root', {'RootMutation'}),
            ('move', 'nested', 'nested/inside', {'InvalidDestination'}),
            ('create_file', '', 'source.txt', {'AlreadyExists'})):
        h.rejected(kind, source, destination, errors)
    h.rejected('delete', 'source.txt', errors={'InvalidRoot'}, root=42)


def rejected_types(h):
    (h.root / 'link').symlink_to(h.fixtures / 'outside.txt')
    (h.root / 'linked-dir').symlink_to(h.root / 'destination', target_is_directory=True)
    os.mkfifo(h.root / 'fifo')
    h.seal()
    for kind, source, destination, errors in (
            ('delete', 'link', '', {'Symlink'}),
            ('create_file', '', 'linked-dir/new', {'Symlink'}),
            ('move', 'fifo', 'destination/fifo', {'SpecialFile'}),
            ('create_file', '', 'missing/new', {'NotFound'})):
        h.rejected(kind, source, destination, errors)
    before = h.review('delete', 'nested')
    h.command('operations-respond', 'accept')
    assert h.finished('failed', {'DirectoryNotEmpty'})['completed'] == before
    h.assert_tree()


def own_documents(h):
    path = h.root / 'source.txt'
    h.open_document(path)
    h.rejected('rename', 'source.txt', 'renamed', {'OpenDocument'})
    h.close_document(path)
    h.apply(h.review('rename', 'source.txt', 'renamed'))
    h.expect_change('rename', 'source.txt', 'renamed')


def peer_documents(h):
    owner = h.target
    peer = h.new_window()
    path = h.root / 'nested/child.txt'
    h.open_document(path)
    h.select(owner, focus=True)
    h.rejected('move', 'nested', 'destination/nested', {'OpenDocument'})
    h.select(peer, focus=True)
    h.replace_keyboard('dirty descendant retained π🙂')
    h.protect(path)
    h.journals(['dirty descendant retained π🙂'])
    h.select(owner, focus=True)
    h.rejected('delete', 'nested/child.txt', errors={'OpenDocument'})
    h.select(peer, focus=True)
    h.preserved()
    h.close_document(path, dirty=True)
    h.select(owner, focus=True)
    h.apply(h.review('move', 'nested', 'destination/nested'))
    h.expect_change('move', 'nested', 'destination/nested')


def protected_workspace(h):
    owner = h.target
    peer = h.new_window()
    manifest = h.write(h.root / 'config/active.coral-workspace', json.dumps(
        {'version': 1, 'roots': [{'path': str(h.root / 'nested')}]}))
    h.open_workspace(manifest)
    h.seal()
    h.select(owner, focus=True)
    h.rejected('rename', 'nested', 'elsewhere', {'RootMutation'})
    h.rejected('delete', 'config/active.coral-workspace', errors={'ProtectedManifest'})
    h.rejected('move', 'config', 'destination/config', {'ProtectedManifest'})
    h.select(peer, focus=True)
    h.action('win.close-workspace')
    h.browser()
    h.select(owner, focus=True)
    h.apply(h.review('rename', 'nested', 'released'))
    h.expect_change('rename', 'nested', 'released')


def unrelated_admission_refused(h):
    # Admission is deliberately global, not just an overlap check against the
    # uncertain peer spelling. These paths are unrelated to its endpoint.
    started = h.ops()['jobs_started']
    for kind in KINDS:
        source = '' if kind.startswith('create_') else 'source.txt'
        destination = '' if kind == 'delete' else 'unrelated-new'
        h.rejected(kind, source, destination, {'WorkspaceBusy'})
        assert h.ops()['jobs_started'] == started, 'Uncertain peer must reject before preparing'


def canonical_peer(h, owner, peer):
    h.select(peer, focus=True)
    p = h.workspace(h.root)
    assert p['manifest'] is None and len(p['roots']) == 1, p
    root = p['roots'][0]
    assert root['path'] == root['canonical'] == str(h.root) and root['availability'] == 'available', p
    h.drained(2)
    h.select(owner, focus=True)


def unavailable_peer_alias(h):
    owner = h.target
    h.write(h.root / 'file', 'unavailable root alias must not hide this file\n')
    alias = h.fixtures / 'alias'
    alias.symlink_to(h.root, target_is_directory=True)
    manifests = {leaf: h.write(h.fixtures / (leaf + '.coral-workspace'), json.dumps(
        {'version': 1, 'roots': [{'path': str(alias / leaf)}]})) for leaf in ('file', 'missing')}
    h.seal()
    peer = h.new_window()
    for leaf, availability in (('file', 'not_directory'), ('missing', 'missing')):
        h.select(peer, focus=True)
        h.open_workspace(manifests[leaf])
        p = h.browser()
        assert len(p['roots']) == 1 and p['manifest'] == str(manifests[leaf]), p
        root = p['roots'][0]
        assert root['path'] == str(alias / leaf) and root['canonical'] is None, p
        assert root['availability'] == availability, p
        h.drained(2)
        h.evidence.setdefault('peer_admission', []).append(dict(case=h.name, variant=leaf, browser=p))
        h.select(owner, focus=True)
        if leaf == 'file':
            h.rejected('delete', 'file', errors={'WorkspaceBusy'})
            h.rejected('rename', 'file', 'renamed-file', {'WorkspaceBusy'})
        else:
            h.rejected('create_file', destination='missing', errors={'WorkspaceBusy'})
            h.rejected('create_directory', destination='missing', errors={'WorkspaceBusy'})
        unrelated_admission_refused(h)
    canonical_peer(h, owner, peer)
    h.apply(h.review('rename', 'file', 'renamed-file'))
    h.expect_change('rename', 'file', 'renamed-file')
    h.apply(h.review('create_directory', destination='missing'))
    h.expect_change('create_directory', destination='missing')


def lexical_parent_peer(h, manifest):
    owner = h.target
    (h.root / 'sub').mkdir()
    alias = h.fixtures / 'alias'
    alias.symlink_to(h.root, target_is_directory=True)
    # Preserve '..' verbatim: resolving this fixture path would erase the very
    # dependency on sub whose protection this regression exercises.
    spelling = alias / 'sub' / '..' / 'active.json'
    if manifest:
        h.write(h.root / 'active.json', json.dumps(
            {'version': 1, 'roots': [{'path': str(h.root / 'destination')}]}))
        workspace = spelling
    else:
        (h.root / 'active.json').mkdir()
        workspace = h.write(h.fixtures / 'peer.coral-workspace', json.dumps(
            {'version': 1, 'roots': [{'path': str(spelling)}]}))
    h.seal()
    peer = h.new_window()
    h.open_workspace(workspace)
    p = h.browser()
    assert len(p['roots']) == 1 and p['manifest'] == str(workspace), p
    root = p['roots'][0]
    assert root['availability'] == 'available', p
    if manifest:
        assert root['path'] == root['canonical'] == str(h.root / 'destination'), p
    else:
        assert root['path'] == str(spelling) and root['canonical'] == str(h.root / 'active.json'), p
    h.drained(2)
    h.evidence.setdefault('peer_admission', []).append(dict(case=h.name, browser=p))
    h.select(owner, focus=True)
    h.rejected('delete', 'sub', errors={'WorkspaceBusy'})
    h.rejected('rename', 'sub', 'renamed-sub', {'WorkspaceBusy'})
    unrelated_admission_refused(h)
    canonical_peer(h, owner, peer)
    h.apply(h.review('rename', 'sub', 'renamed-sub'))
    h.expect_change('rename', 'sub', 'renamed-sub')
    h.apply(h.review('delete', 'renamed-sub'))
    h.expect_change('delete', 'renamed-sub')


def delayed_barrier(h):
    owner = h.target
    peer = h.new_window()
    other = h.fixtures / 'outside.txt'
    h.open_document(other)
    h.replace_keyboard('unsaved peer text')
    h.drained()
    h.select(owner, focus=True)
    before = h.review('rename', 'source.txt', 'after-barrier')
    h.command('operations-delay', '2000')
    h.command('operations-respond', 'accept')
    p = h.state_is('applying')
    assert p['barrier'] and h.windows()['file_operation_owner'] == owner, p
    h.select(peer, focus=True)
    h.command('open', h.root / 'source.txt')
    assert h.document(h.root / 'source.txt') is None
    for action in ('win.save', 'win.save-workspace-session', 'win.restore-workspace-session', 'win.new-window'):
        h.action(action)
    p = h.windows()
    assert p['live'] == 2 and p['session_owner'] is None and not p['saves'], p
    assert 'operation' in h.state()['notice'].lower(), h.state()
    assert h.document(other)['dirty'] and not h.slot.exists()
    h.assert_tree(label='delayed apply blocks writes and opens')
    h.select(owner)
    assert h.finished('succeeded')['completed'] == before + 1
    h.expect_change('rename', 'source.txt', 'after-barrier')
    h.select(peer, focus=True)
    h.action('win.save')
    wait_for(lambda: not h.document(other)['dirty'])
    expected = h.expected_tree.copy()
    expected['outside.txt'] = dict(kind='file', sha256=digest(b'unsaved peer text'))
    h.assert_tree(expected, label='save works after barrier release')
    third = h.new_window()
    h.close_window(third, peer)


def delayed_owner_close(h):
    owner = h.target
    peer = h.new_window()
    h.select(owner, focus=True)
    before = h.review('delete', 'source.txt')
    h.command('operations-delay', '2000')
    h.command('operations-respond', 'accept')
    assert h.state_is('applying')['barrier']
    h.action('win.close-window')
    p = h.windows()
    assert p['live'] == 2 and not p['closing'] and not p['quitting'], p
    assert 'worker cleanup' in h.state()['notice'], h.state()
    assert h.ops()['barrier'], 'Close must not release the live worker barrier'
    h.assert_tree(label='close refused while delayed owner is applying')
    assert h.finished('succeeded')['completed'] == before + 1
    h.expect_change('delete', 'source.txt')
    h.close_window(owner, peer)
    assert h.drained(1)['file_operation_owner'] is None
    h.workspace(h.root)
    h.apply(h.review('create_file', destination='after-close'))
    h.expect_change('create_file', destination='after-close')


def quit_cancel(h):
    owner = h.target
    peer = h.new_window()
    h.replace_keyboard('Quit All cancellation keeps this buffer')
    h.select(owner, focus=True)
    before = h.review('delete', 'source.txt')
    h.command('operations-delay', '2000')
    h.command('operations-respond', 'accept')
    assert h.state_is('applying')['barrier']
    # Quit All is rejected before any dirty-close prompt while apply is live.
    # It must neither discard peer buffers nor release the worker's admission.
    h.action('win.quit', peer)
    h.select(peer)
    state = h.state()
    assert not state['dialog'] and 'Quit All was cancelled' in state['notice'], state
    p = h.windows()
    assert p['live'] == 2 and not p['quitting'] and not p['closing'], p
    assert h.active()[0]['text'] == 'Quit All cancellation keeps this buffer'
    h.select(owner)
    assert h.ops()['barrier']
    h.assert_tree(label='Quit All refused before mutation and without closing windows')
    assert h.finished('succeeded')['completed'] == before + 1
    h.expect_change('delete', 'source.txt')
    assert h.drained(2)['file_operation_owner'] is None


def recovery_and_cycles(h):
    text = 'unnamed recovery-safe π🙂 buffer'
    h.replace_keyboard(text)
    doc = h.active()[0]
    h.journals([text])
    samples = []
    for index in range(10):
        destination = f'cycle-{index}'
        before = h.review('create_file', destination=destination)
        if index % 2:
            h.command('operations-respond', 'cancel')
            assert h.finished('cancelled')['completed'] == before
            h.assert_tree()
        else:
            h.apply(before)
            h.expect_change('create_file', destination=destination)
            h.apply(h.review('delete', destination))
            h.expect_change('delete', destination)
        assert h.active()[0] == doc, (doc, h.active()[0])
        if index in (1, 5, 9):
            samples.append(resource_sample(h))
    h.journals([text])
    h.evidence['cycle_resources'] = samples
    assert samples[-1]['fds'] <= samples[0]['fds'] + 4, samples
    assert samples[-1]['threads'] <= samples[0]['threads'] + 4, samples
    assert samples[-1]['rss'] <= samples[0]['rss'] + 64 * 1024 * 1024, samples
    h.crash()
    h.launch(recovery=True)
    h.recovery_choice('F8', 'transferred')
    h.recovery_choice('F10')
    h.ready()
    assert any(d['text'] == text and d['dirty'] and d['path'] is None for d in h.state()['documents'])
    assert not h.browser()['roots'], 'Recovery must not implicitly reopen workspace authority'
    h.assert_tree()


SCENARIOS = [
    ('palette_workflow', palette_workflow),
    ('explorer_buttons', explorer_buttons),
    ('filesystem_success', filesystem_success),
    *[(f'cancel_{kind}', lambda h, kind=kind: cancel_kind(h, kind)) for kind in KINDS],
    *[(f'stale_{variant}', lambda h, variant=variant: stale_review(h, variant))
      for variant in ('replacement', 'edit', 'parent_rename', 'root_rename', 'collision')],
    ('rejected_paths', rejected_paths),
    ('rejected_types', rejected_types),
    ('own_open_document', own_documents),
    ('peer_clean_dirty_descendants', peer_documents),
    ('protected_nested_roots_manifests', protected_workspace),
    ('unavailable_peer_symlink_alias', unavailable_peer_alias),
    ('peer_root_lexical_parent', lambda h: lexical_parent_peer(h, manifest=False)),
    ('peer_manifest_lexical_parent', lambda h: lexical_parent_peer(h, manifest=True)),
    ('delayed_apply_barrier', delayed_barrier),
    ('delayed_owner_close', delayed_owner_close),
    ('quit_all_cancel', quit_cancel),
    ('recovery_buffers_and_repeated_drain', recovery_and_cycles),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-operations')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', choices=[name for name, _ in SCENARIOS])
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scenarios = [(name, run) for name, run in SCENARIOS if not args.case or name in args.case]
    began = time.monotonic()
    evidence = dict(status='running', checks=[], invocation=[sys.executable, *sys.argv],
                    binary=str(args.binary.resolve()), runtime_budget_seconds=550,
                    selected_cases=[name for name, _ in scenarios], total_available_cases=len(SCENARIOS),
                    isolation='Private Wayland and D-Bus; per-case disposable HOME/XDG and filesystem fixtures',
                    scope='Native UI and prepared filesystem workers; bounded observed races, not hostile-race atomicity')

    def expired(_signal, _frame):
        raise BudgetExpired('Operations acceptance exceeded its 550-second budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(550)
    save(output, evidence)
    try:
        binary = args.binary.resolve().read_bytes()
        evidence['binary_sha256'] = digest(binary)
        assert all(marker in binary for marker in (b'CORAL_OPERATIONS ', b'CORAL_WINDOWS ', b'CORAL_COMMAND_DONE')), 'Build with -Dtest-hooks=true'
        del binary
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            styles = stage_styles(session, evidence)
            if any(name == 'explorer_buttons' for name, _ in scenarios):
                start_accessibility(session)
            for name, scenario in scenarios:
                record = dict(name=name, status='running')
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = Case(session, args.binary.resolve(), output, evidence, name, began + 545)
                    h.setup()
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    record.update(status='passed', fixture_snapshot=h.expected_tree)
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
                        record['log_tail'] = h.app.lines[-60:] if h.app else []
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    del session.children[child_start:]
                    record['seconds'] = time.monotonic() - start
                    save(output, evidence)
            for entry in styles:
                for key in ('source', 'path'):
                    assert digest(Path(entry[key]).read_bytes()) == entry['sha256'], ('Style resource changed', entry)
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
        evidence['counts'] = {status: sum(c['status'] == status for c in evidence['checks']) for status in ('passed', 'failed', 'blocked')}
        save(output, evidence)
    print(f"{evidence['status'].upper()}: {evidence['counts']}; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
