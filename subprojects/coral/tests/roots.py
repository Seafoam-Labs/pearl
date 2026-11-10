#!/usr/bin/env python3
"""Native M2 root/manifest acceptance in disposable Wayland/D-Bus/HOME/XDG.

Run with a test-hooks binary; --case may be repeated for focused runs. Reuses
windows.WindowHarness, never another suite's main. Palette/menu GActions, native
folder/save choosers, real explorer selection and pointer-clicked review buttons
cover UI dispatch. F11 hooks cover bounded prepare/review/apply races using the
same controller. Every review/cancellation/rejection checks the whole fixture
filesystem (lstat, no symlink traversal or FIFO reads). Only explicitly reviewed
manifest bytes may change; evidence and failures are retained, never suppressed.
This tests observed conflicts, not hostile syscall-boundary atomicity.
"""
import argparse
import json
import os
import signal
import sys
import time
import traceback
from pathlib import Path

from windows import (WindowHarness, PEARL, PrivateSession, fixture_prefix,
                     wait_for, stage_styles, digest, save, BudgetExpired,
                     pointer_move, pointer_click, resource_sample)
from operations import tree

LABELS = {'save_as': 'Save Workspace As…', 'add': 'Workspace: Add Folder…',
          'remove': 'Workspace: Remove Selected Root…'}
ACTIONS = {'save_as': 'win.save-workspace-as', 'add': 'win.workspace-add-root',
           'remove': 'win.workspace-remove-root'}
TITLES = {'save_as': 'Save Workspace As', 'add': 'Add Folder to Workspace'}
REVIEW = 'Review workspace manifest edit'


class Case(WindowHarness):
    def setup(self):
        self.left = self.fixtures / 'left' / 'same'
        self.right = self.fixtures / 'right' / 'same'
        self.extra = self.fixtures / 'extra'
        for root, text in ((self.left, 'LEFT α\n'), (self.right, 'RIGHT β\n'),
                           (self.extra, 'EXTRA γ\n')):
            self.write(root / 'same.txt', text)
        self.write(self.fixtures / 'outside.txt', 'outside bytes must stay intact\n')
        self.manifest = self.fixtures / 'work.coral-workspace'
        self.workspace(self.left)
        self.ipc.call('command', action='window.maximized',
                      fields={'id': self.native_ids[self.target], 'value': True})
        wait_for(lambda: (p := self.probe('dock'))['width'] >= 1000 and p['height'] >= 650, 6)
        self.seal()

    def seal(self):
        # Only fixture construction or an intentional, explicitly labelled external edit.
        self.expected_tree = tree(self.fixtures)

    def assert_tree(self, expected=None, label='unchanged'):
        expected = self.expected_tree if expected is None else expected
        actual = tree(self.fixtures)
        delta = {key: {'expected': expected.get(key), 'actual': actual.get(key)}
                 for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key)}
        self.evidence.setdefault('filesystem_checks', []).append(
            dict(case=self.name, label=label, delta=delta))
        assert not delta, (label, delta)
        self.expected_tree = expected.copy()

    def verify_files(self):
        if hasattr(self, 'expected_tree'):
            self.assert_tree(label='final fixture integrity, including after Quit All')

    def roots(self):
        p = self.probe('roots')
        assert 0 <= p['jobs_started'] - p['jobs_reaped'] <= 1, p
        if not p['busy']:
            assert not p['dialog'] and not p['barrier'], p
            assert p['jobs_started'] == p['jobs_reaped'], p
        return p

    def state_is(self, state):
        def ready():
            p = self.roots()
            assert p['busy'] or p['state'] == state, ('Unexpected terminal roots state', state, p, self.state())
            return p if p['state'] == state else None
        return wait_for(ready, 12)

    def finished(self, state, errors=None):
        p = wait_for(lambda: p if not (p := self.roots())['busy'] else None, 15)
        assert p['state'] == state, p
        if errors is not None:
            assert p['err'] in errors, p
        self.evidence.setdefault('roots_results', []).append(dict(case=self.name, result=p))
        self.browser()
        registry = self.drained()
        assert registry['file_operation_owner'] is None, registry
        return p

    def load_manifest(self, specs=None, **fields):
        self.assert_tree()
        specs = specs if specs is not None else [dict(path=str(self.left), name='Left'),
                                                dict(path=str(self.right), name='Right')]
        value = dict(version=1, roots=specs, **fields)
        self.write(self.manifest, json.dumps(value, ensure_ascii=False))
        self.seal()
        self.command('open-workspace', self.manifest)
        p = self.browser()
        assert p['error_name'] is None and p['manifest'] == str(self.manifest), p
        self.policy_idle()
        self.drained()
        return value

    def select_root(self, index=0, child=None):
        self.select(self.target, focus=True)
        self.command('explorer-reset')
        p = self.browser()
        root = p['roots'][index]
        if child is not None:
            assert index == 0, 'Child fixture uses first root only'
            self.command('browser-activate', index=index)
            p = self.browser()
            row = 1 + next(i for i, entry in enumerate(p['entries']) if entry['name'] == child)
        else:
            row = index
        self.action('win.focus-explorer')
        self.key('Home')
        for _ in range(row):
            self.key('Down')
        if child is not None:
            assert self.probe('browser')['selected_path'] == child
        return root['id']

    def request(self, kind, path=''):
        self.browser()
        self.drained()
        before = self.roots()['completed']
        self.command('roots-request', kind, path=path)
        return before

    def review(self, kind, path=''):
        before = self.request(kind, path)
        p = self.state_is('confirming')
        assert p['kind'] == kind and p['dialog'] and not p['barrier'], p
        assert p['completed'] == before, p
        self.assert_tree(label='prepared review has not written anything')
        return before

    def reject(self, kind, path='', errors=None):
        before = self.request(kind, path)
        p = self.finished('failed', errors)
        assert p['completed'] == before, p
        self.assert_tree(label='rejected request has not written anything')
        return p

    def apply(self, before, click=False):
        if click:
            self.click_button(REVIEW)
        else:
            self.command('roots-respond', 'accept')
        p = self.finished('succeeded', {None})
        assert p['completed'] == before + 1, p
        return p

    def manifest_changed(self, path, expected):
        data = path.read_bytes()
        actual = json.loads(data)
        assert actual == expected, (actual, expected)
        assert all(Path(root['path']).is_absolute() for root in actual['roots']), actual
        baseline = self.expected_tree.copy()
        baseline[path.relative_to(self.fixtures).as_posix()] = dict(kind='file', sha256=digest(data))
        self.assert_tree(baseline, 'only exact reviewed manifest changed')
        p = self.browser()
        assert p['error_name'] is None and p['manifest'] == str(path), p
        assert len(p['roots']) == len(actual['roots']), (p, actual)
        return actual

    def click_button(self, title, accept=True, chooser=False):
        surface = wait_for(lambda: next((w for w in self.native_windows() if w.get('title') == title), None))
        self.ipc.call('command', action='window.activate', fields={'id': surface['id']})
        time.sleep(.2)  # compositor placement transaction, not filesystem readiness
        self.screenshot(title.replace(' ', '-') + ('-accept' if accept else '-cancel'))
        surface = next(w for w in self.native_windows() if w['id'] == surface['id'])
        box = surface['geometry']
        # Native chooser footer and GtkDialog action area have different margins.
        offset = 65 if accept else (270 if chooser else 230)
        x = box['x'] + box['width'] - offset
        y = box['y'] + box['height'] - (34 if chooser else 22)
        pointer_move(self.session, x, y)
        pointer_click(self.session)
        self.evidence.setdefault('pointer_routes', []).append(
            dict(case=self.name, title=title, accept=accept, point=[x, y], surface=surface))
        wait_for(lambda: all(w['id'] != surface['id'] for w in self.native_windows()), 7)

    def ui_start(self, kind, palette=True):
        self.browser()
        self.drained()
        before = self.roots()['completed']
        if palette:
            self.palette(LABELS[kind])
        else:
            self.action(ACTIONS[kind])
        self.state_is('confirming' if kind == 'remove' else 'choosing')
        self.assert_tree(label='native command and chooser have not mutated fixtures')
        return before

    def choose_directory(self, kind, directory):
        title = TITLES[kind]
        surface = wait_for(lambda: next((w for w in self.native_windows() if w.get('title') == title), None))
        self.ipc.call('command', action='window.activate', fields={'id': surface['id']})
        self.key('l', 'ctrl')
        self.key('a', 'ctrl')
        self.text(str(directory))
        self.key('Return')
        # A directory location navigates without accepting. Save uses the real
        # filename entry's initial Workspace.coral-workspace; click its button.
        time.sleep(.6)
        assert self.roots()['state'] == 'choosing'
        self.assert_tree(label='native chooser navigation has no publication')
        self.click_button(title, chooser=True)
        self.state_is('confirming')
        self.assert_tree(label='native chooser acceptance still requires review')

    def close_document(self, path, dirty=False):
        self.action('win.new')
        self.open_document(path)
        self.action('win.close')
        if dirty:
            wait_for(lambda: self.state()['dialog'])
            self.command('respond', response=1)
        wait_for(lambda: self.document(path) is None)
        self.drained()


def output_value(roots, settings=None, exclude=None):
    return dict(version=1, roots=roots, settings=settings or {}, exclude=exclude or [])


def native_palette(h):
    before = h.ui_start('save_as')
    h.choose_directory('save_as', h.fixtures)
    h.apply(before, click=True)
    path = h.fixtures / 'Workspace.coral-workspace'
    first = dict(name='same', path=str(h.left))
    h.manifest_changed(path, output_value([first]))
    before = h.ui_start('add')
    h.choose_directory('add', h.right)
    h.apply(before, click=True)
    h.manifest_changed(path, output_value([first, dict(path=str(h.right))]))
    root_id = h.select_root(1)
    before = h.ui_start('remove')
    assert h.roots()['selected'] == root_id
    h.apply(before, click=True)
    h.manifest_changed(path, output_value([first]))


def menu_chooser_cancel(h):
    before = h.ui_start('save_as', palette=False)
    h.key('Escape')
    assert h.finished('cancelled')['completed'] == before
    h.assert_tree()
    h.load_manifest()
    before = h.ui_start('add', palette=False)
    h.key('Escape')
    assert h.finished('cancelled')['completed'] == before
    h.assert_tree()
    h.select_root(1)
    before = h.ui_start('remove', palette=False)
    h.click_button(REVIEW, accept=False)
    assert h.finished('cancelled')['completed'] == before
    h.assert_tree()


def folder_prerequisite_lastroot(h):
    for kind in ('add', 'remove'):
        h.reject(kind, h.right if kind == 'add' else '', {'SaveWorkspaceFirst'})
        assert 'Save Workspace As' in h.state()['notice']
    h.load_manifest([dict(path=str(h.left), name='Only')])
    h.select_root()
    h.reject('remove', errors={'LastRoot'})
    assert 'at least one root' in h.state()['notice']


def samebasename_remove_dirty(h):
    h.load_manifest([dict(path=str(root), name='same') for root in (h.left, h.right)])
    roots = h.browser()['roots']
    assert len({r['id'] for r in roots}) == 2
    for index, root in enumerate((h.left, h.right)):
        h.command('workspace-roots')
        h.command('browser-activate', index=index)
        p = h.browser()
        entry = next(i for i, e in enumerate(p['entries']) if e['name'] == 'same.txt')
        h.command('browser-activate', index=entry)
        wait_for(lambda: h.document(root / 'same.txt'))
        h.replace_keyboard(('LEFT' if index == 0 else 'RIGHT') + ' dirty π🙂 buffer')
    docs = h.state()['documents']
    assert len({d['id'] for d in docs if d['path']}) == 2
    assert all(d['dirty'] for d in docs if d['path'])
    for root in roots:
        assert any(label.startswith(f"#{root['id']} same · same.txt") for label in h.state()['tab_labels'])
    selected = h.select_root(0, 'same.txt')
    before = h.review('remove')
    assert h.roots()['selected'] == selected
    h.apply(before)
    h.manifest_changed(h.manifest, output_value([dict(name='same', path=str(h.right))]))
    assert h.state()['documents'] == docs, (docs, h.state())
    assert (h.left / 'same.txt').read_text() == 'LEFT α\n'
    h.screenshot('removed-root-dirty-documents-kept')


def preserve_policy_lexical(h):
    physical = h.fixtures / 'physical'
    (physical / 'child').mkdir(parents=True)
    h.write(physical / 'root/code.zig', 'const value = 1;\n')
    h.write(physical / 'root/hidden.tmp', 'excluded\n')
    (h.fixtures / 'link').symlink_to(physical / 'child', target_is_directory=True)
    (h.fixtures / 'elsewhere').mkdir()
    h.seal()
    settings = dict(wrap=False, indent=7, languages={'zig': dict(indent=2, spaces=False), 'c': dict(lines=False)})
    excludes = ['*.tmp', 'build/**']
    specs = [dict(name='Named "root" π', path='link/../root'),
             dict(name='Offline', path='link/../missing/../later')]
    h.load_manifest(specs, settings=settings, exclude=excludes)
    target = h.fixtures / 'elsewhere/copy.coral-workspace'
    h.apply(h.review('save_as', target))
    expected = [dict(name=r['name'], path=str(h.fixtures) + '/' + r['path']) for r in specs]
    value = h.manifest_changed(target, output_value(expected, settings, excludes))
    p = h.browser()
    assert p['roots'][0]['canonical'] == str(physical / 'root') and p['roots'][1]['availability'] == 'missing', p
    h.command('browser-activate', index=0)
    assert 'hidden.tmp' not in {e['name'] for e in h.browser()['entries']}
    h.apply(h.review('add', h.right))
    value['roots'].append(dict(path=str(h.right)))
    h.manifest_changed(target, value)
    h.select_root(2)
    h.apply(h.review('remove'))
    h.manifest_changed(target, output_value(expected, settings, excludes))


def duplicate_alias(h):
    h.load_manifest()
    alias = h.fixtures / 'left-alias'
    alias.symlink_to(h.left, target_is_directory=True)
    h.seal()
    h.reject('add', alias, {'DuplicateRoot'})
    h.reject('add', h.left, {'DuplicateRoot'})


def root_cap(h):
    specs = []
    for i in range(32):
        root = h.fixtures / f'root-{i:02}'
        root.mkdir()
        specs.append(dict(name=f'Root {i}', path=str(root)))
    h.seal()
    h.load_manifest(specs)
    assert len(h.browser()['roots']) == 32
    h.reject('add', h.extra, {'TooManyRoots'})
    h.select_root(31)
    h.apply(h.review('remove'))
    h.manifest_changed(h.manifest, output_value(specs[:-1]))
    h.apply(h.review('add', h.extra))
    h.manifest_changed(h.manifest, output_value(specs[:-1] + [dict(path=str(h.extra))]))


def cancel_reviews(h):
    h.load_manifest()
    for kind, path in (('save_as', h.fixtures / 'cancel.coral-workspace'), ('add', h.extra), ('remove', '')):
        if kind == 'remove':
            h.select_root(1)
        before = h.review(kind, path)
        h.command('roots-respond', 'cancel')
        p = h.finished('cancelled')
        assert p['completed'] == before
        h.command('roots-respond', 'accept')
        assert h.roots()['state'] == 'cancelled'
        h.assert_tree(label='cancelled and late accept cannot write')


def destination_rejections(h):
    h.load_manifest()
    file = h.write(h.fixtures / 'exists.coral-workspace', 'competitor bytes')
    link = h.fixtures / 'dangling.coral-workspace'
    link.symlink_to('absent-target')
    fifo = h.fixtures / 'pipe.coral-workspace'
    os.mkfifo(fifo)
    h.seal()
    for path in (file, link, fifo, h.extra):
        h.reject('save_as', path, {'AlreadyExists'})
    h.reject('save_as', h.fixtures / 'absent-parent/new.coral-workspace', {'NotFound'})
    h.reject('add', file, {'NotDirectory'})
    h.reject('add', h.fixtures / 'absent-folder', {'NotFound'})
    target = h.fixtures / 'late.coral-workspace'
    before = h.review('save_as', target)
    h.write(target, 'late competitor')
    h.seal()
    h.command('roots-respond', 'accept')
    assert h.finished('failed', {'AlreadyExists'})['completed'] == before
    h.assert_tree(label='late destination never overwritten')


def source_changed_prepare(h):
    h.load_manifest()
    h.command('roots-delay', '1800')
    before = h.request('add', h.extra)
    assert h.state_is('preparing')['busy']
    changed = json.loads(h.manifest.read_bytes())
    changed['roots'][0]['name'] = 'External new root name'
    h.manifest.write_text(json.dumps(changed))
    h.seal()
    assert h.finished('failed', {'WorkspaceChanged'})['completed'] == before
    h.assert_tree(label='fresh source differing from loaded model was not adopted or overwritten')


def source_changed_review(h):
    h.load_manifest()
    before = h.review('add', h.extra)
    # Same parsed contents, new inode: exact reviewed source identity matters.
    data = h.manifest.read_bytes()
    replacement = h.fixtures / 'replacement.tmp'
    replacement.write_bytes(data)
    replacement.replace(h.manifest)
    h.seal()
    h.command('roots-respond', 'accept')
    assert h.finished('failed', {'StaleSnapshot', 'WorkspaceBusy'})['completed'] == before
    h.assert_tree(label='replaced source retains external bytes')


def added_type_race(h):
    h.load_manifest()
    path = h.fixtures / 'candidate'
    path.mkdir()
    h.seal()
    before = h.review('add', path)
    path.rmdir()
    path.write_text('now a regular file')
    h.seal()
    h.command('roots-respond', 'accept')
    assert h.finished('failed', {'NotDirectory', 'StaleSnapshot'})['completed'] == before
    h.assert_tree(label='directory changed into a file after review')


def stale_generation_reply(h):
    h.load_manifest()
    original_ids = {r['id'] for r in h.browser()['roots']}
    before = h.review('add', h.extra)
    original = h.roots()
    h.command('open-folder', h.right)
    assert h.probe('browser')['manifest'] == str(h.manifest), 'Review must block normal workspace switches'
    h.command('roots-respond', 'cancel')
    h.finished('cancelled')
    h.workspace(h.right)
    assert h.browser()['roots'][0]['id'] not in original_ids
    h.evidence.setdefault('stale_generations', []).append(dict(case=h.name, retired=original))
    h.command('roots-respond', 'accept')
    assert h.roots()['completed'] == before and not h.roots()['busy']
    assert h.browser()['manifest'] is None
    h.assert_tree(label='late confirmation from retired generation cannot publish')


def bound_owner(h):
    h.load_manifest()
    h.open_document(h.manifest)
    h.reject('add', h.extra, {'OpenDocument'})
    h.replace_keyboard('unsaved manifest edit must survive')
    before = h.document(h.manifest)
    h.reject('add', h.extra, {'OpenDocument'})
    assert h.document(h.manifest) == before
    h.close_document(h.manifest, dirty=True)
    h.apply(h.review('add', h.extra))
    h.manifest_changed(h.manifest, output_value([dict(name='Left', path=str(h.left)),
                                              dict(name='Right', path=str(h.right)), dict(path=str(h.extra))]))


def bound_peer_aliases(h):
    h.load_manifest()
    owner = h.target
    peer = h.new_window()
    alias = h.fixtures / 'manifest-alias'
    alias.symlink_to(h.manifest)
    hard = h.fixtures / 'manifest-hardlink'
    os.link(h.manifest, hard)
    h.seal()
    for path in (alias, hard):
        h.select(peer, focus=True)
        h.command('open', path)
        canonical = h.manifest if path == alias else hard
        wait_for(lambda: d if (d := h.document(canonical)) and d['text'] else None)
        h.select(owner, focus=True)
        h.reject('add', h.extra, {'OpenDocument'})
        h.select(peer, focus=True)
        h.close_document(canonical)
    h.select(owner, focus=True)
    before = h.review('add', h.extra)
    h.select(peer, focus=True)
    h.open_document(hard)  # New binding after prepare must be rechecked at apply.
    h.select(owner)
    h.command('roots-respond', 'accept')
    assert h.finished('failed', {'OpenDocument'})['completed'] == before
    h.assert_tree(label='late peer manifest binding blocks commit')


def delayed_barriers(h):
    h.load_manifest()
    owner = h.target
    peer = h.new_window()
    outside = h.fixtures / 'outside.txt'
    h.open_document(outside)
    h.replace_keyboard('dirty peer save must be blocked')
    h.drained()
    h.select(owner, focus=True)
    before = h.review('add', h.extra)
    h.command('roots-delay', '2000')
    h.command('roots-respond', 'accept')
    assert h.state_is('applying')['barrier']
    assert h.windows()['file_operation_owner'] == owner
    h.select(peer, focus=True)
    h.command('open', h.left / 'same.txt')
    assert h.document(h.left / 'same.txt') is None
    for action in ('win.save', 'win.new-window', 'win.save-workspace-session', 'win.restore-workspace-session'):
        h.action(action)
    p = h.windows()
    assert p['live'] == 2 and not p['saves'] and p['session_owner'] is None, p
    assert h.document(outside)['dirty']
    h.select(owner)
    h.action('win.close-window')
    assert h.windows()['live'] == 2
    assert h.roots()['barrier'], 'Close cannot release apply admission'
    h.assert_tree(label='delayed apply blocks saves, opens, windows, session writes and close')
    assert h.finished('succeeded')['completed'] == before + 1
    h.manifest_changed(h.manifest, output_value([dict(name='Left', path=str(h.left)),
                                              dict(name='Right', path=str(h.right)), dict(path=str(h.extra))]))
    h.select(peer, focus=True)
    h.action('win.save')
    wait_for(lambda: not h.document(outside)['dirty'])
    expected = h.expected_tree.copy()
    expected['outside.txt'] = dict(kind='file', sha256=digest(b'dirty peer save must be blocked'))
    h.assert_tree(expected, 'normal save works again after barrier release')


def close_pending(h):
    h.load_manifest()
    owner = h.target
    peer = h.new_window()
    h.select(owner, focus=True)
    h.command('roots-delay', '1500')
    before = h.request('add', h.extra)
    h.state_is('preparing')
    h.action('win.close-window')
    assert h.windows()['live'] == 2 and 'worker cleanup' in h.state()['notice']
    h.state_is('confirming')
    h.command('roots-respond', 'cancel')
    assert h.finished('cancelled')['completed'] == before
    h.close_window(owner, peer)
    assert h.drained(1)['file_operation_owner'] is None
    h.assert_tree(label='close refused during prepare; cancel drains before owner closes')


def cycles_and_drain(h):
    h.load_manifest()
    h.replace_keyboard('unnamed dirty document stays alive π🙂')
    doc = h.active()[0]
    samples = []
    for index in range(6):
        before = h.review('save_as', h.fixtures / f'cancel-{index}.coral-workspace')
        h.command('roots-respond', 'cancel')
        assert h.finished('cancelled')['completed'] == before
        assert h.active()[0] == doc
        h.assert_tree()
        if index in (0, 3, 5):
            samples.append(resource_sample(h))
    assert samples[-1]['fds'] <= samples[0]['fds'] + 4, samples
    assert samples[-1]['threads'] <= samples[0]['threads'] + 4, samples
    assert samples[-1]['rss'] <= samples[0]['rss'] + 64 * 1024 * 1024, samples
    h.evidence['cycle_resources'] = samples


SCENARIOS = [
    ('native_palette', native_palette),
    ('menu_chooser_cancel', menu_chooser_cancel),
    ('folder_prerequisite_lastroot', folder_prerequisite_lastroot),
    ('samebasename_remove_dirty', samebasename_remove_dirty),
    ('preserve_policy_lexical', preserve_policy_lexical),
    ('duplicate_alias', duplicate_alias),
    ('root_cap', root_cap),
    ('cancel_reviews', cancel_reviews),
    ('destination_rejections', destination_rejections),
    ('source_changed_prepare', source_changed_prepare),
    ('source_changed_review', source_changed_review),
    ('added_type_race', added_type_race),
    ('stale_generation_reply', stale_generation_reply),
    ('bound_owner', bound_owner),
    ('bound_peer_aliases', bound_peer_aliases),
    ('delayed_barriers', delayed_barriers),
    ('close_pending', close_pending),
    ('cycles_and_drain', cycles_and_drain),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-roots')
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
                    scope='Native root commands/choosers and real GTask workers; observed races, not hostile-race atomicity')

    def expired(_signal, _frame):
        raise BudgetExpired('Roots acceptance exceeded its 550-second budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(550)
    save(output, evidence)
    try:
        binary = args.binary.resolve().read_bytes()
        evidence['binary_sha256'] = digest(binary)
        assert all(marker in binary for marker in (b'CORAL_ROOTS ', b'CORAL_WINDOWS ', b'CORAL_COMMAND_DONE')), 'Build with -Dtest-hooks=true'
        del binary
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            styles = stage_styles(session, evidence)
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
