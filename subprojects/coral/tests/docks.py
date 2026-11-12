#!/usr/bin/env python3
"""Native dock acceptance, not a layout-model/unit test or another suite runner.

From subprojects/coral (choose a fresh install prefix for concurrent builds):
  zig build -Doptimize=ReleaseSafe -Dtest-hooks=true --prefix .cache/docks-local/install -j2
  python3 tests/docks.py --binary .cache/docks-local/install/bin/coral

Real GTK commands, Wayland keyboard/pointer input and allocated paned geometry
run in a private compositor/D-Bus. Each case has disposable HOME/XDG/fixtures;
only that case's explicit restarts retain state. No host desktop or documents
are touched. results.json retains partial failures, geometry, binary identity,
fixture hashes and screenshots; native process logs live under session/.
Quick Open and text search deliberately share ONE controller/query/results.
Session cases require the v2 layout descriptor; v1 must restore default docks.
"""
import argparse
import json
import math
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path

from search import Harness, PEARL
from sessions import SessionHarness, digest, layout as editor_layout
from policy import BudgetExpired, save
from pearl_session import PrivateSession, fixture_prefix, wait_for
from wayland_test_input import pointer_drag, pointer_move

SIDES = ('left', 'right', 'bottom')
DEFAULT = dict(explorer='left', search='bottom', explorer_visible=True,
               search_visible=False, active='explorer', left_size=222,
               right_size=320, bottom_size=240,
               source_control='left', source_control_visible=False,
               terminal='bottom', terminal_visible=False)


def contents(state):
    """Stable editor identities/selections; allocation may legitimately scroll."""
    return {'documents': state['documents'], 'groups': state['groups'],
            'views': [{k: v for k, v in view.items() if k not in ('scroll_x', 'scroll_y')}
                      for view in state['views']]}


def editor_size(p):
    return p['editor_width'], p['editor_height']


def dock_state(p):
    """Presentation intent/focus, independent of notices that reflow the shell."""
    return {key: p[key] for key in ('desired', 'compact', 'focus', 'shared_search',
                                   'explorer_visible', 'search_visible', 'picker_visible',
                                   'left_visible', 'right_visible', 'bottom_visible')}


def group_geometry(p, expected_groups=None):
    """Raw window-relative rectangles must not hide clipped/overlapping groups."""
    editor, groups = p['editor_bounds'], p['editor_group_bounds']
    assert groups, p
    if expected_groups is not None:
        assert len(groups) == expected_groups, (expected_groups, p)
    for rect in (editor, *groups):
        assert all(math.isfinite(rect[key]) for key in ('x', 'y', 'width', 'height')), rect
        assert rect['width'] > 0 and rect['height'] > 0, (rect, p)

    def contained(inner, outer):
        # One logical pixel for GTK's fractional bounds/rounding, not clipping.
        assert inner['x'] >= outer['x'] - 1 and inner['y'] >= outer['y'] - 1, (inner, outer, p)
        assert inner['x'] + inner['width'] <= outer['x'] + outer['width'] + 1, (inner, outer, p)
        assert inner['y'] + inner['height'] <= outer['y'] + outer['height'] + 1, (inner, outer, p)

    contained(editor, dict(x=0, y=0, width=p['width'], height=p['height']))
    contained(editor, p['paned_bounds'][2])
    assert abs(editor['width'] - p['editor_width']) <= 1, p
    assert abs(editor['height'] - p['editor_height']) <= 1, p
    for i, group in enumerate(groups):
        contained(group, editor)
        for other in groups[:i]:
            overlap_x = min(group['x'] + group['width'], other['x'] + other['width']) - max(group['x'], other['x'])
            overlap_y = min(group['y'] + group['height'], other['y'] + other['height']) - max(group['y'], other['y'])
            assert overlap_x <= 1 or overlap_y <= 1, ('Overlapping editor groups', group, other, p)


def geometry(p):
    """Check real nested GtkPaned allocations, not just desired visibility.

    Bounds are window-relative. The editor is the bottom paned's start child;
    its width/height plus the nested origins expose every occupied dock extent.
    Allow up to 12 logical pixels for themed splitter handles, never a panel.
    """
    group_geometry(p)
    left, right, bottom = p['paned_bounds']
    assert all(r['width'] > 0 and r['height'] > 0 for r in (left, right, bottom)), p
    assert p['editor_width'] > 0 and p['editor_height'] > 0, p
    assert abs(p['editor_width'] - bottom['width']) <= 1, p
    assert abs(right['y'] - bottom['y']) <= 1 and abs(left['y'] - right['y']) <= 1, p
    assert abs(left['height'] - right['height']) <= 1, p
    assert abs(right['height'] - bottom['height']) <= 1, p
    extents = (right['x'] - left['x'], right['width'] - bottom['width'],
               bottom['height'] - p['editor_height'])
    for i, side in enumerate(SIDES):
        if not p[side + '_visible']:
            assert abs(extents[i]) <= 1, (side, extents, p)
            continue
        assert extents[i] > 40, (side, extents, p)
        if i == 0:
            handle = extents[i] - p['positions'][i]
        elif i == 1:
            handle = p['positions'][i] - bottom['width']
        else:
            handle = p['positions'][i] - p['editor_height']
        assert -1 <= handle <= 12, (side, handle, p)
    assert abs(right['x'] + right['width'] - left['x'] - left['width']) <= 1, p
    assert abs(bottom['x'] - right['x']) <= 1, p
    return dict(zip(SIDES, extents))


class DockHarness(SessionHarness):
    # SessionHarness supplies isolated per-case lifecycle, integrity checks and
    # explicit save/restore. Its policy-specific default probe is not search.
    probe = Harness.probe
    settled = Harness.settled

    def launch(self, *paths):
        super().launch(*paths)
        # The floating compositor can enlarge a client without moving its old
        # centered origin. Move the real titlebar first so later 1200x700
        # allocations, bottom splitters and screenshots stay on the output.
        window = next(w for w in self.ipc.state() if w['kind'] == 'window')
        bounds = self.ipc.outputs()[window['output']]['bounds']
        target_x, target_y = bounds['x'] + 20, bounds['y'] + 10
        # GTK consumes the first motion crossing its drag threshold. Re-read
        # compositor placement instead of assuming every pointer pixel moved it.
        for _ in range(4):
            rect = next(w for w in self.ipc.state() if w['kind'] == 'window' and w['id'] == window['id'])['geometry']
            if (bounds['x'] <= rect['x'] <= bounds['x'] + bounds['width'] - 1200 and
                    bounds['y'] <= rect['y'] <= bounds['y'] + bounds['height'] - 700):
                self.evidence.setdefault('window_placement', []).append(
                    {'case': self.name, 'serial': self.serial, 'geometry': rect, 'output_bounds': bounds})
                return
            pointer_move(self.session, rect['x'] + 250, rect['y'] + 20)
            pointer_drag(self.session, target_x - rect['x'], target_y - rect['y'])
            time.sleep(.05)
        raise AssertionError(('Could not place the test window fully on its private output', self.ipc.state()))

    def dock(self, label=None):
        previous, stable_since = None, time.monotonic()

        def ready():
            nonlocal previous, stable_since
            p = self.probe('dock')
            if p != previous:
                previous, stable_since = p, time.monotonic()
            return p if time.monotonic() - stable_since >= .10 else None

        p = wait_for(ready, 6)
        extents = geometry(p)
        if label:
            self.evidence.setdefault('geometry', []).append(
                {'case': self.name, 'label': label, 'dock': p, 'occupied_extents': extents})
        return p

    def resize(self, width=1200, height=700):
        self.command('window-resize', width=width, height=height)
        wait_for(lambda: p if (p := self.probe('dock'))['width'] == width and p['height'] == height else None, 6)
        return self.dock(f'window-{width}x{height}')

    def setup(self):
        self.resize()
        root = self.fixtures / 'root'
        self.target = self.write(root / 'target.txt', 'heading\nneedle π🙂 tail\nlast line\n')
        self.other = self.write(root / 'other.txt', 'other document\nsecond line\n')
        self.root = root
        self.open_workspace(root, folder=True)
        self.open_document(self.target)
        return self.dock('fixture-ready')

    def palette_window(self):
        return next((w for w in self.ipc.state() if w['kind'] == 'window' and
                     w.get('title') == 'Command Palette…'), None)

    def palette(self, label):
        self.key('p', 'ctrl', 'shift')
        wait_for(self.palette_window)
        self.text(label)
        self.key('Return')
        wait_for(lambda: not self.palette_window())

    def single_probe(self, kind, label):
        """One real F11, no retry or refocus that could conceal a detached row."""
        assert kind in ('browser', 'dock', 'workspace'), kind
        self.alive()
        self.command_path.write_text('[Test]\naction=' + kind + '-probe\n')
        start, began = len(self.app.lines), time.monotonic()
        keyboard = subprocess.Popen(['wtype', '-s', '10', '-k', 'F11', '-s', '5000'],
                                    env=self.session.env, cwd=self.session.base,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE)
        try:
            wait_for(lambda: self.app.proc.poll() is not None or
                     'CORAL_COMMAND_DONE' in self.app.lines[start:], 3)
            self.alive()
            prefix = 'CORAL_' + kind.upper() + ' '
            p = json.loads(next(line[len(prefix):] for line in self.app.lines[start:] if line.startswith(prefix)))
            self.last[kind] = p
            self.evidence.setdefault('single_f11_acks', []).append(
                {'case': self.name, 'label': label, 'kind': kind, 'sends': 1,
                 'ack_ms': (time.monotonic() - began) * 1000, 'focus': p.get('focus')})
            time.sleep(.01)
            return p
        finally:
            keyboard.terminate()
            keyboard.communicate(timeout=2)

    def input_browser_settled(self, label):
        previous, since = None, time.monotonic()

        def ready():
            nonlocal previous, since
            p = self.single_probe('browser', label)
            stamp = (p['roots'], p['directories'], p['scans_started'], p['watch_generation'],
                     p['pending'], p['loading'], p['scanning'], p['watch_worker_busy'], p['watch_queue_depth'])
            if stamp != previous:
                previous, since = stamp, time.monotonic()
            idle = not (p['pending'] or p['loading'] or p['scanning'] or p['watch_worker_busy'] or p['watch_queue_depth'])
            return p if idle and time.monotonic() - since >= .3 else None

        return wait_for(ready, 15)

    def preserved_editors(self, before):
        after = contents(self.state())
        assert after == before, (before, after)

    def shot(self, label):
        p = self.dock(label)
        self.screenshot(label)
        path = self.output / 'screenshots' / f'{self.name}-{label}.png'
        self.evidence.setdefault('screenshots', []).append(
            {'case': self.name, 'path': str(path), 'sha256': digest(path.read_bytes()), 'dock': p})


def default_geometry(h):
    p = h.setup()
    assert p['desired'] == DEFAULT and p['left_visible'] and not p['bottom_visible'], p
    h.key('f', 'ctrl', 'shift')
    h.text('needle')
    h.exact(h.settled(), 1, ['target.txt'])
    p = h.dock('default-text-search')
    assert p['desired']['explorer'] == 'left' and p['desired']['search'] == 'bottom', p
    assert p['explorer_visible'] and p['search_visible'] and not p['right_visible'], p
    assert p['left_visible'] and p['bottom_visible'] and p['focus'] == 'search', p
    assert p['editor_width'] >= 240 and p['editor_height'] >= 160, p
    h.shot('default')


def move_panel(h, panel):
    h.setup()
    h.command('focus-' + ('search' if panel == 'explorer' else 'explorer'))
    h.command('hide-panel')
    h.command('focus-' + panel)
    before = contents(h.state())
    for side, key in zip(SIDES, ('Left', 'Right', 'Down')):
        h.key(key, 'ctrl', 'alt')
        p = h.dock(panel + '-' + side)
        assert p['desired'][panel] == side and p['focus'] == panel, p
        assert p[panel + '_visible'], p
        assert [p[s + '_visible'] for s in SIDES] == [s == side for s in SIDES], p
        h.preserved_editors(before)
    h.shot('moved')


def same_dock_tabs(h):
    h.setup()
    h.query('needle')
    checked = h.probe()
    before = contents(h.state())
    for side in SIDES:
        for panel in ('explorer', 'search'):
            h.command('focus-' + panel)
            h.command('dock-' + side)
        p = h.dock('tabs-' + side)
        assert p['desired']['explorer_visible'] and p['desired']['search_visible'], p
        size = editor_size(p)
        for panel in ('explorer', 'search', 'explorer', 'search'):
            # These are the very same registry actions as the dock's tab buttons.
            h.command('focus-' + panel)
            p = h.dock(side + '-tab-' + panel)
            assert p['focus'] == panel and p[panel + '_visible'], p
            assert sum(p[x + '_visible'] for x in ('explorer', 'search')) == 1, p
            assert [p[s + '_visible'] for s in SIDES] == [s == side for s in SIDES], p
            assert editor_size(p) == size, p
            h.preserved_editors(before)
        # Explicit Focus Search refreshes the one shared controller. Query and
        # checked results survive, but a new generation is expected.
        now = h.settled()
        assert (now['query'], now['results']) == (checked['query'], checked['results']), (checked, now)
    h.shot('same-dock-tabs')


def keyboard_visibility_reset(h):
    h.setup()
    h.key('b', 'ctrl')
    assert not h.dock()['explorer_visible']
    h.key('e', 'ctrl', 'shift')
    assert h.dock()['focus'] == 'explorer'
    h.key('Right', 'ctrl', 'alt')
    h.key('b', 'ctrl', 'shift')
    p = h.dock('hidden-explorer')
    assert p['focus'] == 'editor' and not any(p[s + '_visible'] for s in SIDES), p
    h.key('f', 'ctrl', 'shift')
    assert h.dock()['focus'] == 'search'
    h.key('1', 'ctrl')
    assert h.dock()['focus'] == 'editor'
    h.palette('Toggle Search dock')
    assert not h.dock()['search_visible']
    h.palette('Focus Search')
    assert h.dock()['focus'] == 'search'
    h.palette('Reset dock layout')
    p = h.dock('reset-via-keyboard-palette')
    assert p['desired'] == DEFAULT and p['explorer_visible'] and not p['search_visible'], p


def splitters(h):
    h.setup()
    for i, side in enumerate(SIDES):
        h.command('focus-explorer')
        h.command('dock-' + side)
        # Start below the effective allocation cap: growing an already-clamped
        # bottom dock may change desire without changing any visible geometry.
        h.command('dock-resize', side, size=160 if i == 2 else 260)
        before = h.dock('before-drag-' + side)
        rect, pos = before['paned_bounds'][i], before['positions'][i]
        win = next(w for w in h.ipc.state() if w['kind'] == 'window')['geometry']
        x = round(win['x'] + rect['x'] + (rect['width'] / 2 if i == 2 else pos + 3))
        y = round(win['y'] + rect['y'] + (pos + 3 if i == 2 else rect['height'] / 2))
        pointer_move(h.session, x, y)
        pointer_drag(h.session, 0 if i == 2 else (60 if i == 0 else -60), -40 if i == 2 else 0)
        after = h.dock('after-real-pointer-drag-' + side)
        field = side + '_size'
        delta = after['desired'][field] - before['desired'][field]
        assert 20 <= delta <= 100, (side, delta, before, after)
        assert geometry(after)[side] > geometry(before)[side] + 15, (before, after)
        axis = 1 if i == 2 else 0
        assert editor_size(after)[axis] < editor_size(before)[axis] - 15, (before, after)
        h.evidence.setdefault('pointer_drags', []).append(
            {'case': h.name, 'side': side, 'start': [x, y], 'desired_delta': delta})
        h.command('focus-explorer')
        h.key('Page_Up', 'ctrl', 'alt')
        assert h.dock()['desired'][field] == after['desired'][field] + 40
        h.key('Page_Down', 'ctrl', 'alt')
        assert h.dock()['desired'][field] == after['desired'][field]
    h.shot('splitters')


def desired_clamping(h):
    h.setup()
    for side, minimum, maximum in (('left', 120, 1200), ('right', 120, 1200), ('bottom', 100, 1000)):
        h.command('focus-explorer')
        h.command('dock-' + side)
        for requested, expected in ((0, minimum), (65535, maximum)):
            h.command('dock-resize', side, size=requested)
            p = h.dock(f'{side}-request-{requested}')
            assert p['desired'][side + '_size'] == expected, p
            assert p['editor_width'] >= 240 and p['editor_height'] >= 160, p
            if requested == 65535:
                assert geometry(p)[side] < expected, p
                h.resize(1000, 680)
                assert h.dock()['desired'][side + '_size'] == maximum
                h.resize()


def compact_preserves_desired(h):
    h.setup()
    h.query('needle')
    h.command('dock-right')
    for side, size in zip(SIDES, (350, 390, 270)):
        h.command('dock-resize', side, size=size)
    wide = h.dock('wide-custom')
    desired = wide['desired'].copy()
    assert wide['explorer_visible'] and wide['search_visible'], wide
    compact = h.resize(650, 520)
    assert compact['compact'] and compact['desired'] == desired, compact
    assert compact['search_visible'] and not compact['explorer_visible'], compact
    h.command('focus-explorer')
    p = h.dock('compact-explorer')
    assert p['explorer_visible'] and not p['search_visible'], p
    assert p['desired'] == dict(desired, active='explorer'), p
    h.command('focus-search')
    h.shot('compact-one-auxiliary')
    restored = h.resize()
    assert not restored['compact'] and restored['desired'] == desired, restored
    assert restored['explorer_visible'] and restored['search_visible'], restored
    assert editor_size(restored) == editor_size(wide), (wide, restored)


def picker_escape(h):
    h.setup()
    h.query('needle')
    h.command('focus-editor')
    h.command('select', start=16, end=8)
    for excerpt in (False, True):
        if excerpt:
            h.command('excerpt')
            h.command('select', start=5, end=1)
            assert h.active()[1]['excerpt_start'] is not None
        before, editors = h.dock(), contents(h.state())
        h.key('p', 'ctrl')
        p = h.dock('picker-over-' + ('excerpt' if excerpt else 'editor'))
        assert p['picker_visible'] and p['focus'] == 'picker' and p['shared_search'], p
        assert editor_size(p) == editor_size(before), (before, p)
        h.shot('picker-excerpt' if excerpt else 'picker-editor')
        h.key('Escape')
        p = h.dock('escape-restored-focus')
        assert not p['picker_visible'] and p['focus'] == 'editor', p
        assert editor_size(p) == editor_size(before), (before, p)
        h.preserved_editors(editors)


def activation_dismissal(h):
    h.setup()
    text = h.exact(h.query('needle'), 1, ['target.txt'])
    doc, view = h.activate(0, h.target)
    assert doc['text'][min(view['insertion'], view['bound']):max(view['insertion'], view['bound'])] == 'needle', view
    assert h.dock()['search_visible'], 'Text-search navigation must leave the results dock open'
    assert h.probe()['results'] == text['results']
    # Switching modes intentionally replaces the shared query; retaining the
    # checked quick-open results after commit is not a second text-search model.
    before = h.exact(h.query('other.txt', mode='quick_open'), 1, ['other.txt'])
    h.command('search-activation-delay', 1600)
    h.key('Return')
    pending = h.probe()
    assert pending['navigation_pending'] and pending['activations'] == before['activations'], pending
    assert h.dock('navigation-pending')['picker_visible'], 'Dismissed before navigation committed'
    wait_for(lambda: h.probe()['activations'] == before['activations'] + 1, 8)
    after = h.probe()
    p = h.dock('navigation-committed')
    assert not p['picker_visible'] and p['focus'] == 'editor', p
    assert h.active()[0]['path'] == str(h.other)
    assert not after['navigation_pending'] and not after['stale'] and after['complete'], after
    for key in ('query', 'mode', 'generation', 'results', 'selected_index'):
        assert after[key] == before[key], (key, before, after)



def palette_focus(h):
    h.setup()
    h.query('needle')
    for panel in ('explorer', 'search', 'editor'):
        h.command('focus-' + panel)
        h.settled()
        editors = contents(h.state())
        h.key('p', 'ctrl', 'shift')
        wait_for(h.palette_window)
        h.text('no-such-dock-command')
        time.sleep(.15)
        palette = h.palette_window()
        assert palette and palette['focused'], 'Dock allocation stole keyboard focus from the palette'
        h.key('Escape')
        wait_for(lambda: not h.palette_window())
        p = h.dock('palette-return-' + panel)
        assert p['focus'] == panel, p
        h.preserved_editors(editors)
        h.browser()
    h.command('focus-search')
    h.palette('Move active panel right')
    p = h.dock('palette-move-no-editor-focus-theft')
    assert p['desired']['search'] == 'right' and p['focus'] == 'search', p


def watcher_hidden(h):
    h.setup()
    h.command('explorer-activate', index=0)
    h.browser()
    h.query('needle')
    for panel in ('explorer', 'search'):
        h.command('focus-' + panel)
        h.command('hide-panel')
    before = h.dock('both-hidden')
    scans = h.browser()['scans_started']
    h.write(h.root / 'watch-created.txt', 'needle watcher\n')
    wait_for(lambda: h.probe('browser')['scans_started'] > scans, 10)
    browser = h.browser()
    assert any(e['name'] == 'watch-created.txt' for e in browser['entries']), browser
    h.settled()
    p = h.dock('watcher-delivered-still-hidden')
    assert p['desired'] == before['desired'] and p['focus'] == 'editor', p
    assert not any(p[s + '_visible'] for s in SIDES), p
    assert editor_size(p) == editor_size(before), (before, p)


def two_documents(h):
    h.setup()
    h.open_document(h.other)
    state = h.state()
    assert len(state['documents']) == len(state['views']) == 2 and len(state['groups']) == 1, state
    assert h.active()[0]['path'] == str(h.other)
    return state


def active_editor(h, path, label):
    state = h.single_probe('workspace', label)
    view = next(v for v in state['views'] if v['active'])
    doc = next(d for d in state['documents'] if d['id'] == view['document_id'])
    assert doc['path'] == str(path) and state['editor_focused'], (path, state)
    assert h.single_probe('dock', label)['focus'] == 'editor'
    return doc


def tab_navigation(h):
    before = two_documents(h)
    for key, mods in (('Tab', ('ctrl', 'shift')), ('ISO_Left_Tab', ('ctrl',)),
                      ('ISO_Left_Tab', ('ctrl', 'shift'))):
        for repeat in range(2):
            h.key('Tab', 'ctrl')
            active_editor(h, h.target, f'next-tab-{key}-{repeat}')
            h.key(key, *mods)
            active_editor(h, h.other, f'previous-tab-{key}-{repeat}')
            h.preserved_editors(contents(before))
    h.shot('tab-navigation-editor-focus')


def plain_tab_unicode_history(h):
    before = two_documents(h)
    h.key('End', 'ctrl')
    original = h.active()[0]['text']
    h.key('Tab')
    indented = active_editor(h, h.other, 'plain-tab')['text']
    indentation = indented[len(original):]
    assert indented.startswith(original) and indentation and set(indentation) <= {' ', '\t'}, indented
    typed = 'π🙂 e\u0301 終'
    h.text(typed)
    expected = indented + typed
    assert active_editor(h, h.other, 'unicode-typing')['text'] == expected
    # GTK may coalesce native typing differently by script/word boundary. Check
    # every undo/redo state rather than assuming one synthetic undo transaction.
    undone = []
    for step in range(24):
        current = h.active()[0]['text']
        if current == original:
            break
        undone.append(current)
        h.key('z', 'ctrl')
        assert active_editor(h, h.other, f'undo-{step}')['text'] != current
    else:
        raise AssertionError('Native undo did not reach the original document')
    assert undone and h.active()[0]['text'] == original
    for step, text in enumerate(reversed(undone)):
        h.key('z', 'ctrl', 'shift')
        assert active_editor(h, h.other, f'redo-{step}')['text'] == text
    assert h.active()[0]['text'] == expected
    assert h.document(h.target) == next(d for d in before['documents'] if d['path'] == str(h.target))
    assert {v['id'] for v in h.state()['views']} == {v['id'] for v in before['views']}
    h.evidence['native_typing'] = {'text': typed, 'indentation': indentation, 'undo_redo_steps': len(undone),
                                 'scope': 'Real Unicode key input; not an external IME composition test.'}


def query_key_routing(h):
    two_documents(h)
    for mode, focus in (('text', 'search'), ('quick_open', 'picker')):
        h.query('needle', mode=mode)
        before = contents(h.state())
        h.key('a', 'ctrl')
        query = 'π🙂 e\u0301 query'
        h.text(query)
        assert h.settled()['query'] == query
        h.preserved_editors(before)
        for mods in ((), ('shift',)):
            h.key('Tab', *mods)
            h.preserved_editors(before)
        # Refocus the query explicitly after normal GTK focus traversal. The
        # registered Ctrl+Tab chord is intentionally global, even from a query.
        h.query(query, mode=mode)
        assert h.dock()['focus'] == focus
        h.key('Tab', 'ctrl')
        active_editor(h, h.target, mode + '-global-next-tab')
        h.query(query, mode=mode)
        h.key('Tab', 'ctrl', 'shift')
        active_editor(h, h.other, mode + '-global-previous-tab')
        assert h.state()['documents'] == before['documents']
        if mode == 'quick_open':
            h.key('Escape')


def find_escape(h):
    two_documents(h)
    for query in ('', 'unmatched π🙂 query'):
        before = h.dock()
        docs = h.state()['documents']
        h.key('f', 'ctrl')
        h.key('a', 'ctrl')
        h.key('BackSpace')
        if query:
            h.text(query)
        shown = h.dock('find-query-focused')
        assert shown['focus'] == 'other' and not h.state()['editor_focused'], shown
        assert shown['editor_bounds']['y'] > before['editor_bounds']['y'], (before, shown)
        assert h.state()['documents'] == docs
        h.key('Escape')
        p = h.dock('find-escape-restores-editor')
        assert dock_state(p) == dock_state(before) and p['editor_bounds'] == before['editor_bounds'], (before, p)
        assert active_editor(h, h.other, 'find-escape')['text'] == next(d['text'] for d in docs if d['path'] == str(h.other))
        # A successful probe alone is not proof that subsequent typing targets
        # the editor rather than a now-hidden GtkSearchEntry.
        original = h.active()[0]['text']
        h.text('λ')
        assert h.active()[0]['text'] != original
        h.key('z', 'ctrl')
        assert active_editor(h, h.other, 'find-escape-undo')['text'] == original


def expand_root(h):
    browser = h.browser()
    if not browser['directories'][0]['expanded']:
        h.command('explorer-activate', index=0)
        browser = h.browser()
    assert browser['entries'] and browser['directories'][0]['expanded'], browser
    return browser


def explorer_row_refresh_focus(h):
    h.setup()
    editors = contents(h.state())
    for repeat in range(2):
        for action in ('workspace-rescan', 'explorer-reset', 'watcher'):
            expand_root(h)
            h.command('focus-explorer')
            h.key('Home')
            h.key('Down')
            selected = h.single_probe('browser', 'focused-file-row')
            assert selected['selected_path'], selected
            assert h.single_probe('dock', 'before-row-replacement')['focus'] == 'explorer'
            label = f'{action}-{repeat}'
            if action == 'watcher':
                filename = f'refresh-{repeat}.txt'
                h.write(h.root / filename, 'new row\n')
                wait_for(lambda: h.single_probe('browser', label)['scans_started'] > selected['scans_started'], 10)
            else:
                h.command(action)
            # Do not refocus Explorer between row destruction and these probes.
            h.single_probe('dock', label + '-next-f11')
            browser = h.input_browser_settled(label)
            if action == 'watcher':
                assert any(e['name'] == filename for e in browser['entries']), browser
            p = h.single_probe('dock', label + '-published')
            assert p['focus'] == 'explorer' and p['explorer_visible'], p
            h.preserved_editors(editors)
    h.shot('explorer-row-focus-retained')


def watcher_preserves_input_focus(h):
    two_documents(h)
    expand_root(h)
    for mode, focus in ((None, 'editor'), ('text', 'search'), ('quick_open', 'picker')):
        for repeat in range(2):
            if mode:
                h.query('needle', mode=mode)
                h.key('End')
            else:
                h.command('focus-editor')
                h.key('End', 'ctrl')
            editors = contents(h.state())
            desired = h.dock()['desired']
            browser = h.single_probe('browser', 'before-watcher-' + focus)
            filename = f'watch-{focus}-{repeat}.txt'
            h.write(h.root / filename, 'watcher refresh\n')
            wait_for(lambda: h.single_probe('browser', filename)['scans_started'] > browser['scans_started'], 10)
            after = h.input_browser_settled(filename)
            assert any(e['name'] == filename for e in after['entries']), after
            p = h.single_probe('dock', filename + '-input-focus')
            assert p['focus'] == focus and p['desired'] == desired, p
            h.preserved_editors(editors)
            h.text('λ')
            if mode:
                assert h.settled()['query'] == 'needleλ'
                h.preserved_editors(editors)
            else:
                original = next(d['text'] for d in editors['documents'] if d['path'] == str(h.other))
                assert active_editor(h, h.other, filename + '-typed')['text'] == original + 'λ'
    h.key('Escape')


def edited_groups(h):
    h.setup()
    h.command('insert', 'unsaved α🙂 ')
    h.command('split-group')
    h.open_document(h.other)
    h.command('select', start=12, end=2)
    h.command('excerpt')
    h.command('insert', 'excerpt edit ')
    h.command('select', start=7, end=1)
    before = contents(h.state())
    assert len(before['groups']) == 2 and len(before['views']) >= 4, before
    assert sum(d['dirty'] for d in before['documents']) == 2, before
    return before


def editor_integrity(h):
    before = edited_groups(h)
    for panel in ('explorer', 'search'):
        h.command('focus-' + panel)
        for side in SIDES:
            h.command('dock-' + side)
            assert h.probe('dock')['desired'][panel] == side
            h.preserved_editors(before)
        h.command('hide-panel')
        h.preserved_editors(before)
    h.command('focus-editor')
    h.command('undo')
    assert h.active()[0]['text'] != next(d['text'] for d in before['documents'] if d['id'] == h.active()[0]['id'])
    h.command('redo')
    after = h.state()['documents']
    # Undo/redo correctly increments revision even when the original text returns.
    assert [{k: v for k, v in d.items() if k != 'revision'} for d in after] == [
        {k: v for k, v in d.items() if k != 'revision'} for d in before['documents']], (before, after)


def split_group_geometry(h):
    before = edited_groups(h)
    for label, width, height in (('wide', 1200, 700), ('narrow', 650, 520), ('wide-restored', 1200, 700)):
        desired = h.dock()['desired']
        resized = h.resize(width, height)
        assert resized['desired'] == desired, (desired, resized)
        for panel in ('explorer', 'search'):
            h.command('focus-' + panel)
            for side in SIDES:
                h.command('dock-' + side)
                p = h.dock('two-editor-groups-' + label + '-' + panel + '-' + side)
                assert p['compact'] == (label == 'narrow'), p
                assert p['desired'][panel] == side and p[panel + '_visible'] and p['focus'] == panel, p
                group_geometry(p, expected_groups=len(before['groups']))
                h.preserved_editors(before)
        h.shot('two-editor-groups-' + label)


def custom_layout(h):
    h.command('focus-explorer')
    h.command('dock-bottom')
    h.command('hide-panel')
    h.command('focus-search')
    h.command('dock-right')
    for side, size in zip(SIDES, (370, 410, 290)):
        h.command('dock-resize', side, size=size)
    return h.dock('custom-layout')['desired']


def decode_slot(raw):
    header, checksum, payload = raw.split(b'\n', 2)
    assert checksum.decode() == digest(payload), 'Saved session outer checksum is invalid'
    descriptor, recovery = payload.split(b'\n', 1)
    return header, json.loads(descriptor), recovery


def encode_slot(header, descriptor, recovery):
    payload = json.dumps(descriptor, separators=(',', ':'), ensure_ascii=False).encode() + b'\n' + recovery
    return header + b'\n' + digest(payload).encode() + b'\n' + payload


def session_v2(h):
    h.setup()
    h.command('select', start=16, end=8)
    wanted = custom_layout(h)
    before = h.state()
    # Capture desired wide sizes even while effective layout is compact.
    h.resize(650, 520)
    h.save_session()
    raw = h.checkpoint_bytes('v2-custom')
    header, descriptor, _ = decode_slot(raw)
    assert header == b'CORAL-SESSION 2', header
    assert descriptor['layout'] == wanted, descriptor
    h.restart()
    assert h.dock('v2-automatic-restored')['desired'] == wanted
    assert editor_layout(h.state()) == editor_layout(before)
    h.unchanged(raw)
    h.restart_explicit()
    h.no_resume()
    h.resize()
    initial_groups = {g['id'] for g in h.state()['groups']}
    h.restore_session()
    h.browser()
    p = h.dock('v2-restored')
    assert p['desired'] == wanted, (wanted, p)
    assert p['right_visible'] and not p['left_visible'] and not p['bottom_visible'], p
    after = h.state()
    restored_groups = {g['id'] for g in after['groups']} - initial_groups
    assert editor_layout(after, restored_groups) == editor_layout(before)
    h.unchanged(raw)
    h.shot('v2-restored')


def session_v1(h):
    h.setup()
    h.save_session()
    _, descriptor, recovery = decode_slot(h.checkpoint_bytes('source-for-legacy'))
    descriptor.pop('layout', None)
    legacy = encode_slot(b'CORAL-SESSION 1', descriptor, recovery)
    h.stop()
    h.slot.write_bytes(legacy)
    h.launch_explicit()
    h.no_resume()
    h.resize()
    custom_layout(h)
    h.restore_session()
    h.browser()
    p = h.dock('legacy-default-layout')
    assert p['desired'] == DEFAULT, p
    assert p['left_visible'] and not p['right_visible'] and not p['bottom_visible'], p
    assert h.document(h.target)['text'] == h.target.read_text()
    h.unchanged(legacy)


def invalid_layout(h):
    h.setup()
    h.save_session()
    header, descriptor, recovery = decode_slot(h.checkpoint_bytes('before-layout-corruption'))
    assert header == b'CORAL-SESSION 2', header
    h.restart_explicit()
    h.no_resume()
    h.resize()
    custom_layout(h)
    h.command('focus-editor')
    h.command('insert', 'live unsaved document survives invalid layout')
    before, dock_before = contents(h.state()), h.dock()
    # Recompute a VALID checksum so these reach layout validation rather than
    # accidentally passing because the envelope checksum was corrupted.
    variants = [(field, dict(descriptor, layout=dict(descriptor['layout'], **{field: value})), error)
                for field, value, error in [('left_size', 0, 'InvalidLayout'), ('right_size', 1201, 'InvalidLayout'),
                                            ('bottom_size', 99, 'InvalidLayout'), ('explorer', 'floating', 'CorruptSession')]]
    variants += [('missing-layout', {k: v for k, v in descriptor.items() if k != 'layout'}, 'CorruptSession'),
                 ('null-layout', dict(descriptor, layout=None), 'CorruptSession')]
    group_geometry(dock_before, expected_groups=len(before['groups']))
    for field, altered, error in variants:
        raw = encode_slot(header, altered, recovery)
        h.slot.write_bytes(raw)
        browser = h.probe('browser')
        h.restore_session('failed', error)
        h.preserved_editors(before)
        p = h.dock('rejected-' + field)
        # Rejection displays an error notice, legitimately changing shell y /
        # height. It must not change dock intent, visibility, focus or editors.
        assert dock_state(p) == dock_state(dock_before), (dock_before, p)
        group_geometry(p, expected_groups=len(before['groups']))
        after = h.probe('browser')
        for key in ('roots', 'manifest', 'watch_generation', 'watch_builds', 'scans_started', 'resets', 'directories'):
            assert after[key] == browser[key], (key, browser, after)
        assert not after['loading'] and not after['pending'], after
        h.unchanged(raw)
        h.checkpoint_bytes('rejected-' + field)


def inflight_hide(h):
    h.setup()
    h.command('search-delay', 1800)
    h.command('search-query', 'needle', mode='text')
    before = wait_for(lambda: p if (p := h.probe())['active'] else None)
    h.key('b', 'ctrl', 'shift')
    p = h.dock('hidden-with-worker-in-flight')
    assert not p['search_visible'] and p['focus'] == 'editor', p
    after = h.settled()
    assert after['started'] == after['reaped'] and after['holds'] == 0, after
    assert after['discarded'] > before['discarded'] and after['stale'], after
    assert not after['results'] and not after['pending'], after
    assert not h.dock('worker-retired-still-hidden')['search_visible']


def inflight_shutdown(h):
    h.setup()
    h.command('search-delay', 2500)
    h.command('search-query', 'needle', mode='text')
    before = wait_for(lambda: p if (p := h.probe())['active'] else None)
    assert before['holds'] == 1, before
    h.key('q', 'ctrl')
    wait_for(lambda: not any(w['kind'] == 'window' for w in h.ipc.state()), 5)
    assert h.app.proc.poll() is None, 'Native window must close before the delayed worker releases its hold'
    assert h.app.wait(timeout=10) == 0, h.app.lines[-30:]
    h.evidence['shutdown'] = {'window_closed_before_worker_exit': True, 'exit_status': 0}


def appearance(h, theme):
    h.stop()
    h.launch_explicit('--' + theme)
    h.setup()
    start = len(h.app.lines)
    h.key('F12')
    line = wait_for(lambda: next((line for line in h.app.lines[start:] if line.startswith('CORAL_PROBE ')), None))
    native = json.loads(line.removeprefix('CORAL_PROBE '))
    assert native['theme'] == (1 if theme == 'light' else 0), native
    h.evidence.setdefault('themes', []).append({'case': h.name, 'requested': theme, 'native_theme': native['theme']})
    h.query('needle')
    h.command('focus-editor')
    h.shot(theme + '-docks')
    h.key('p', 'ctrl')
    h.shot(theme + '-quick-open-shared-controller')
    h.key('Escape')


SCENARIOS = [
    ('default_left_bottom_center_geometry', default_geometry),
    ('explorer_all_docks_keyboard', lambda h: move_panel(h, 'explorer')),
    ('search_all_docks_keyboard', lambda h: move_panel(h, 'search')),
    ('same_dock_tabs_all_sides', same_dock_tabs),
    ('keyboard_hide_focus_toggle_reset', keyboard_visibility_reset),
    ('actual_pointer_splitters_all_sides', splitters),
    ('desired_size_clamping', desired_clamping),
    ('compact_one_aux_preserves_wide_desired', compact_preserves_desired),
    ('quick_open_geometry_escape_editor_excerpt', picker_escape),
    ('activation_commit_then_dismiss_checked_results', activation_dismissal),
    ('palette_focus_no_stealing', palette_focus),
    ('watcher_cannot_reopen_hidden_docks', watcher_hidden),
    ('ctrl_tab_reverse_tab_editor_focus', tab_navigation),
    ('plain_tab_unicode_native_undo_redo', plain_tab_unicode_history),
    ('query_text_tab_and_global_ctrl_tab_routing', query_key_routing),
    ('find_escape_hides_and_restores_editor', find_escape),
    ('explorer_row_refresh_attached_focus_f11', explorer_row_refresh_focus),
    ('watcher_preserves_editor_and_query_input_focus', watcher_preserves_input_focus),
    ('moves_preserve_edits_groups_selections_history', editor_integrity),
    ('split_editor_groups_dock_geometry', split_group_geometry),
    ('saved_session_v2_custom_layout_roundtrip', session_v2),
    ('legacy_session_v1_default_layout', session_v1),
    ('invalid_layout_refused_before_live_mutation', invalid_layout),
    ('inflight_search_hide', inflight_hide),
    ('inflight_search_shutdown', inflight_shutdown),
    ('light_screenshots', lambda h: appearance(h, 'light')),
    ('dark_screenshots', lambda h: appearance(h, 'dark')),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-docks')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', choices=[name for name, _ in SCENARIOS],
                        help='Run only named cases (repeatable); results record the selected scope')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    scenarios = [(n, f) for n, f in SCENARIOS if not args.case or n in args.case]
    began = time.monotonic()
    evidence = {'status': 'running', 'checks': [], 'invocation': [sys.executable, *sys.argv],
                'binary': str(args.binary.resolve()), 'runtime_budget_seconds': 500,
                'selected_cases': [n for n, _ in scenarios], 'total_available_cases': len(SCENARIOS),
                'scope': 'Native GTK allocation/input acceptance; shared Quick Open/text search controller is intentional.',
                'isolation': 'Private headless compositor/D-Bus; independent per-case HOME/XDG and fixtures.'}

    def expired(_signal, _frame):
        raise BudgetExpired('Dock acceptance exceeded its 500-second budget')

    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(500)
    save(output, evidence)
    try:
        binary = args.binary.resolve().read_bytes()
        evidence['binary_sha256'] = digest(binary)
        if not all(marker in binary for marker in (b'CORAL_COMMAND_DONE', b'CORAL_DOCK ', b'CORAL_SESSION ')):
            raise RuntimeError('Binary lacks dock/session test hooks; build with -Dtest-hooks=true')
        del binary
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            for name, scenario in scenarios:
                record = {'name': name, 'status': 'running'}
                evidence['checks'].append(record)
                save(output, evidence)
                start, h = time.monotonic(), None
                child_start = len(session.children)
                print('RUN', name, flush=True)
                try:
                    h = DockHarness(session, args.binary.resolve(), output, evidence, name, began + 495)
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
                        for label, operation in (('screenshot', lambda: h.screenshot('failure')),
                                                 ('fixture_integrity', h.verify_files)):
                            try:
                                operation()
                            except Exception:
                                record[label + '_error'] = traceback.format_exc()
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
        for name, _ in scenarios:
            if name not in completed:
                evidence['checks'].append({'name': name, 'status': 'blocked', 'reason': 'Setup or runtime budget failed'})
        for record in evidence['checks']:
            if record['status'] == 'running':
                record.update(status='failed', error='Interrupted; see suite fatal error')
        evidence['seconds'] = time.monotonic() - began
        evidence['counts'] = {status: sum(c['status'] == status for c in evidence['checks'])
                              for status in ('passed', 'failed', 'blocked')}
        save(output, evidence)
    print(f"{evidence['status'].upper()}: {evidence['counts']['passed']}/{len(scenarios)} native dock cases; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
