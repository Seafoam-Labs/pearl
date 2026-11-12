#!/usr/bin/env python3
"""M4 UI-parity native acceptance: the Source Control dock panel (app.git_panel)
and the Project Diff window (app.git_project_diff), in a private
Wayland/D-Bus/HOME/XDG session.

  python3 -B tests/git_ui.py --binary /path/to/coral-test --case panel-groups

Every fixture repository lives under the disposable session tree; no host
repository is staged/committed and no network is used. Trust and the Source
Control disclosure are exercised through the real policy commands; the dock and
Project Diff are driven through their documented fixture bridges, which call the
*actual* public entry points and answer the *actual* visible native dialogs (they
never grant trust or bypass a permit). Dock placement/focus/compact use the real
win.* registry commands and the CORAL_DOCK probe; rendered diff text and the
editable current-side excerpt are observed/driven through the private
accessibility bus and real Wayland pointer/keyboard input.

The runner mirrors tests/git.py and tests/git_workflows.py: per-case disposable
HOME/XDG/repos, bounded case/suite budgets, and failure evidence (logs, probes,
screenshots) that survives fixture disposal. --case accepts exact names or prefix
groups, repeatable; subsets are reported as partial.

Integration gate: the binary must contain the dock/panel/project-diff/commit probe
markers. A stale binary that predates the parent's wiring is refused up front.

Scope note: this suite owns only tests/git_ui.py and the build.zig `git-ui`
target. It asserts the observable probe/fixture contract; it does not modify
production code. Gutter tags are verified through the rendered line
classification (unified +/-/@@ gutters, split old/new panes, word mode) read from
the real read-only GtkSourceView buffers.
"""
import argparse
import functools
import json
import os
import signal
import sys
import tempfile
import time
import traceback
from pathlib import Path
from typing import Any

from search import PEARL, PROJECT
from windows import stage_styles, start_accessibility
from git import GitHarness, digest, save, CaseTimeout, process_stamp, descendants
from git_mutations import entries, entry, sha, Preservation
from git_workflows import WorkflowHarness

# search installs the shared scripts/integration helper paths at runtime.
from pearl_session import PrivateSession, fixture_prefix, wait_for  # pyright: ignore[reportMissingImports]
from wayland_test_input import pointer_move, pointer_click


PANEL = 'CORAL_GIT_PANEL'
PD = 'CORAL_GIT_PROJECT_DIFF'
COMMIT = 'CORAL_GIT_COMMIT'
DOCK = 'CORAL_DOCK'
PD_TITLE = 'Project Diff — editable excerpts, hunk and selection staging'

REQUIRED_MARKERS = (
    b'CORAL_GIT ', b'CORAL_COMMAND_DONE', b'CORAL_DOCK ',
    b'CORAL_GIT_PANEL ', b'CORAL_GIT_PROJECT_DIFF ', b'CORAL_GIT_COMMIT ',
)

SIDES = ('left', 'right', 'bottom')


# --- private accessibility bridge ---------------------------------------------
# Dump every SHOWING text widget of one native frame. GtkTextView/GtkSourceView
# report MULTI_LINE; a GtkEntry reports SINGLE_LINE. The editable current-side
# excerpt is the only EDITABLE MULTI_LINE text widget in the Project Diff window
# (the rendered diff panes are read-only; the selection entry is single-line).
ATSPI_VIEWS = '''
import json, sys, gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
pid, title = int(sys.argv[1]), sys.argv[2]
desktop = Atspi.get_desktop(0)
queue, frames = [], []
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    if app.get_process_id() != pid:
        continue
    for j in range(app.get_child_count()):
        frame = app.get_child_at_index(j)
        if frame.get_name() == title and frame.get_state_set().contains(Atspi.StateType.SHOWING):
            frames.append(frame)
assert len(frames) <= 1, ('Ambiguous Project Diff frame', title, len(frames))
views = []
if frames:
    queue.append((frames[0], 0))
seen = 0
while queue and seen < 8000:
    node, depth = queue.pop(0)
    seen += 1
    states = node.get_state_set()
    if (node.get_role() == Atspi.Role.TEXT and states.contains(Atspi.StateType.SHOWING)):
        text = ''
        try:
            iface = node.get_text_iface()
            if iface is not None:
                text = iface.get_text(0, iface.get_character_count())
        except Exception:
            text = ''
        rect = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        views.append(dict(
            name=node.get_name(), role=node.get_role_name(),
            editable=states.contains(Atspi.StateType.EDITABLE),
            single_line=states.contains(Atspi.StateType.SINGLE_LINE),
            sensitive=states.contains(Atspi.StateType.SENSITIVE),
            text=text, x=rect.x, y=rect.y, width=rect.width, height=rect.height))
    if depth < 40:
        queue.extend((node.get_child_at_index(i), depth + 1)
                     for i in range(min(node.get_child_count(), 1024)))
print(json.dumps(views))
'''


class GitUiHarness(WorkflowHarness):
    """GitHarness + workflow helpers, plus dock/panel/project-diff probes."""

    # -- probe bridges ---------------------------------------------------------

    def _marker(self, action, marker):
        lines, _ = self.command(action)
        prefix = marker + ' '
        value = next((json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)), None)
        assert value is not None, ('Probe marker absent — controller not wired', marker, lines[-6:])
        assert value['window'] == self.target, (marker, value.get('window'), self.target)
        self.last[marker] = value
        return value

    def panel(self):
        p = self._marker('panel-probe', PANEL)
        assert p['visible_rows'] == len(p['rows']) <= 128, p
        assert p['entry_count'] <= 10000, p
        return p

    def wait_panel(self, predicate, timeout=18):
        def ready():
            p = self.panel()
            return p if predicate(p) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('Panel deadline', self.last.get(PANEL))) from exc

    def panel_idle(self, timeout=18):
        return self.wait_panel(lambda p: p['state'] == 'idle' and not p['busy'], timeout)

    def pd(self):
        return self._marker('project-diff-probe', PD)

    def wait_pd(self, predicate, timeout=18):
        def ready():
            p = self.pd()
            return p if predicate(p) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('Project Diff deadline', self.last.get(PD))) from exc

    def pd_idle(self, timeout=18):
        return self.wait_pd(lambda p: not p['busy'] and p['pending'] == 'none' and not p['mutation_busy'], timeout)

    def commit_probe(self):
        return self._marker('commit-probe', COMMIT)

    def dock(self):
        return self.probe('dock')

    # -- panel lifecycle -------------------------------------------------------

    def open_panel(self):
        """Focus the dock (real win.focus-source-control) and answer its own
        disclosure. The panel reuses app.git discovery from start()."""
        self.command('focus-source-control')
        p = self.wait_panel(lambda p: p['disclosure'])
        assert not p['approved'] and p['attached'], p
        self.command('panel-accept')
        p = self.panel_idle()
        assert p['approved'] and p['attached'] and not p['disclosure'], p
        assert p['repository'] and p['head'] is not None, p
        return p

    def panel_refresh(self):
        before = self.panel()['launches']
        self.command('panel-refresh')
        p = self.panel_idle()
        assert p['launches'] > before, p
        return p

    def pd_show(self):
        self.command('project-diff-show')
        p = self.wait_pd(lambda p: p['visible'] and not p['busy'] and p['pending'] == 'none')
        assert p['git_valid'], p
        return p

    def pd_select(self, index, kind='text'):
        self.command('project-diff-select-file', index)
        return self.wait_pd(lambda p: p['selected_file'] == index and not p['busy']
                            and p['pending'] == 'none' and p['diff_kind'] == kind)

    # -- accessibility ---------------------------------------------------------

    def pd_surface(self):
        surface = wait_for(lambda: next((w for w in self.native_windows()
                                         if w.get('title') == PD_TITLE), None), 8)
        return surface

    def pd_views(self):
        surface = self.pd_surface()
        self.ipc.call('command', action='window.activate', fields={'id': surface['id']})
        views = wait_for(lambda: v if (v := json.loads(self.session.run(
            [sys.executable, '-c', ATSPI_VIEWS, str(self.app.proc.pid), PD_TITLE]).stdout)) else None, 8)
        self.evidence.setdefault('pd_views', []).append(dict(case=self.name, count=len(views)))
        return surface, views

    def pd_diff_panes(self):
        """Read-only rendered diff panes, identified by structure (the private
        accessibility bridge exposes widget roles/extents but not GtkSourceView
        buffer text). With the file open as a Document the current-side excerpt
        is editable, so the tall read-only multi-line panes are the diff view(s):
        one in unified/word mode, two (old/new) in split mode."""
        _, views = self.pd_views()
        return [v for v in views if not v['editable'] and not v['single_line'] and v['height'] > 100]

    def pd_edit_excerpt(self, marker):
        """Click the editable current-side excerpt and type a real insertion.
        The excerpt is the tall editable multi-line pane; the selection entry is
        a short single-line control."""
        surface, views = self.pd_views()
        excerpts = [v for v in views if v['editable'] and not v['single_line']
                    and v['sensitive'] and v['height'] > 100 and v['width'] > 0]
        assert len(excerpts) == 1, ('Expected one editable excerpt', excerpts)
        view = excerpts[0]
        x = round(surface['geometry']['x'] + view['x'] + view['width'] / 2)
        y = round(surface['geometry']['y'] + view['y'] + min(view['height'] / 2, 24))
        pointer_move(self.session, x, y)
        pointer_click(self.session)
        self.session.run(['wtype', '-s', '20', '--', marker])
        self.evidence.setdefault('pd_excerpt_edits', []).append(
            dict(case=self.name, marker=marker, pointer=[x, y], view_height=view['height']))
        return view

    # -- teardown --------------------------------------------------------------

    def stop(self):
        if self.app is not None and self.app.proc.poll() is None:
            # Invalidate the dock/window controllers (closes their dialogs and
            # cancels jobs) before the shared Source Control + Quit All teardown.
            self.command('panel-close')
            self.command('project-diff-close')
        super().stop()


# --- shared assertion helpers -------------------------------------------------

def panel_review(h, kind, path_count):
    p = h.wait_panel(lambda p: p['state'] == 'confirming' and p['review'])
    assert p['write_kind'] == kind and p['write_path_count'] == path_count, p
    assert p['busy'] is False and not p['barrier'], p
    h.verify_files()  # a review is not authorization to mutate the index
    h.evidence.setdefault('panel_reviews', []).append(dict(case=h.name, probe=p))
    return p


def panel_accept(h, root, expected, reason):
    jobs = h.panel()['jobs_reaped']
    h.command('panel-review-accept')
    # The write commits in a worker; the index change then triggers a Source
    # Control refresh that invalidates the dock snapshot, so 'succeeded' is
    # transient. Wait for the worker to reap and assert the committed outcome.
    p = h.wait_panel(lambda p: p['jobs_reaped'] > jobs and not p['busy'])
    assert p['committed'] and p['error'] is None, p
    h.reindex(root, expected, reason)
    h.mutation_preservation.verify(retired=True)
    h.evidence.setdefault('panel_outcomes', []).append(dict(case=h.name, probe=p))
    return p


def pd_review(h, selection):
    p = h.wait_pd(lambda p: p['mutation_dialog'] or p['mutation_state'] in ('failed', 'cancelled'))
    assert p['mutation_state'] == 'confirming' and p['mutation_dialog'] and p['mutation_busy'], p
    assert not p['mutation_committed'] and p['mutation_err'] is None, p
    heading = 'SELECTION, NOT THE WHOLE HUNK' if selection else 'ONE HUNK, NOT THE WHOLE FILE'
    assert heading in p['mutation_review'], p
    assert 'NEVER saved' in p['mutation_review'] and 'BEFORE — INDEX' in p['mutation_review'], p
    h.verify_files()  # prepare/review is not authorization to mutate the index
    h.evidence.setdefault('pd_reviews', []).append(dict(case=h.name, probe=p))
    return p


def pd_accept(h, root, expected, reason):
    h.command('project-diff-accept')
    p = h.wait_pd(lambda p: p['mutation_state'] == 'succeeded' and not p['mutation_busy']
                  and not p['busy'] and p['pending'] == 'none')
    assert p['mutation_committed'] and p['mutation_err'] is None and not p['mutation_dialog'], p
    h.reindex(root, expected, reason)
    h.mutation_preservation.verify(retired=True)
    h.evidence.setdefault('pd_outcomes', []).append(dict(case=h.name, probe=p))
    return p


def begin(h, roots, active=None):
    for root in roots:
        h.identity(root)
    p = h.start(roots, active=active)
    Preservation(h)
    return p


def begin_ro(h, roots, active=None):
    """Trust + disclosure without a worktree/metadata preservation guard, for
    cases that legitimately write HEAD/refs (commit) or the worktree (Save)."""
    for root in roots:
        h.identity(root)
    return h.start(roots, active=active)


def section_rows(p, section):
    return [r for r in p['rows'] if r['section'] == section]


# =============================================================================
# SOURCE CONTROL DOCK PANEL
# =============================================================================

def panel_dock(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'DISK\n')
    begin(h, [root])
    h.open_panel()
    before = h.state()
    # The floating compositor may allocate the default window compact; request a
    # known wide allocation (as the dock acceptance does) before asserting.
    h.command('window-resize', width=1200, height=700)
    p = wait_for(lambda: d if (d := h.dock())['width'] == 1200 and d['height'] == 700 and not d['compact'] else None, 6)
    assert p['source_control_visible'] and p['focus'] == 'source_control', p
    assert p['desired']['source_control'] == 'left' and p['desired']['active'] == 'source_control', p
    assert p['desired']['source_control_visible'], p
    # Move the active Source Control panel across every dock side. Explorer
    # stays visible on the left, so the source-control side is additional.
    for side in SIDES:
        h.command('dock-' + side)
        p = h.dock()
        assert p['desired']['source_control'] == side and p['focus'] == 'source_control', p
        assert p['source_control_visible'] and p[side + '_visible'], p
        assert p['desired']['explorer'] == 'left', p
        assert h.state()['documents'] == before['documents'], 'Dock move disturbed editors'
    # Coexist with Explorer and Search; desired placements survive focus changes.
    h.command('dock-left')
    h.command('focus-explorer')
    p = h.dock()
    assert p['focus'] == 'explorer' and p['explorer_visible'] and p['desired']['explorer'] == 'left', p
    h.command('focus-search')
    p = h.dock()
    assert p['focus'] == 'search' and p['search_visible'], p
    assert p['desired']['source_control'] == 'left', p
    h.command('focus-source-control')
    p = h.dock()
    assert p['focus'] == 'source_control' and p['source_control_visible'], p
    assert p['desired']['explorer'] == 'left' and p['desired']['search'] == 'bottom', p
    # Toggle hides then re-shows the panel without losing its desired placement.
    h.command('toggle-source-control')
    p = h.dock()
    assert not p['source_control_visible'] and not p['desired']['source_control_visible'], p
    h.command('toggle-source-control')
    p = h.dock()
    assert p['source_control_visible'] and p['focus'] == 'source_control', p
    # Compact allocation preserves desired layout; widening restores it.
    desired = p['desired'].copy()
    h.command('window-resize', width=650, height=520)
    compact = wait_for(lambda: d if (d := h.dock())['compact'] else None, 6)
    assert compact['desired'] == desired, (desired, compact)
    h.command('window-resize', width=1200, height=700)
    wide = wait_for(lambda: d if not (d := h.dock())['compact'] else None, 6)
    assert wide['desired'] == desired and wide['source_control_visible'], wide
    assert h.state()['documents'] == before['documents']
    h.evidence.setdefault('dock_geometry', []).append(dict(case=h.name, dock=wide))


def panel_groups(h):
    files = {'staged.txt': 'STAGED_BASE\n', 'unstaged.txt': 'UNSTAGED_BASE\n',
             'both.txt': 'BOTH_BASE\n', 'dir/a.txt': 'A_BASE\n', 'dir/b.txt': 'B_BASE\n'}
    root = h.repo(files=files)
    h.write(root / 'staged.txt', 'STAGED_INDEX\n')
    h.fixture_git(root, 'add', '--', 'staged.txt')
    h.write(root / 'unstaged.txt', 'UNSTAGED_DISK\n')
    h.write(root / 'both.txt', 'BOTH_INDEX\n')
    h.fixture_git(root, 'add', '--', 'both.txt')
    h.write(root / 'both.txt', 'BOTH_DISK\n')
    h.write(root / 'dir/a.txt', 'A_DISK\n')
    h.write(root / 'new.txt', 'UNTRACKED\n')
    h.write(root / 'dir/c.txt', 'UNTRACKED_DIR\n')
    begin(h, [root])
    p = h.open_panel()
    # both.txt is staged AND unstaged; it appears in both sections.
    assert p['staged_count'] == 2 and p['unstaged_count'] == 3 and p['untracked_count'] == 2, p
    assert p['entry_count'] == 6 and p['unmerged_count'] == 0, p
    assert p['display_rows'] == p['staged_count'] + p['unstaged_count'] + p['untracked_count'], p
    assert [r['path'] for r in section_rows(p, 'staged')] == ['both.txt', 'staged.txt'], p
    assert [r['path'] for r in section_rows(p, 'unstaged')] == ['both.txt', 'dir/a.txt', 'unstaged.txt'], p
    assert [r['path'] for r in section_rows(p, 'untracked')] == ['dir/c.txt', 'new.txt'], p
    # Section order is staged, unstaged, untracked regardless of tree/flat.
    order = [r['section'] for r in p['rows']]
    assert order == sorted(order, key=('staged', 'unstaged', 'untracked').index), p
    flat_rows = [(r['section'], r['path']) for r in p['rows']]
    h.command('panel-tree-flat', 'tree')
    p = h.panel()
    assert p['tree'] is True, p
    assert [(r['section'], r['path']) for r in p['rows']] == flat_rows, 'Tree changed display order'
    h.command('panel-tree-flat', 'flat')
    p = h.panel()
    assert p['tree'] is False and [(r['section'], r['path']) for r in p['rows']] == flat_rows, p
    # Selection tracks a zero-based display row; "none" clears it.
    h.command('panel-select', 0)
    p = h.panel()
    assert p['selected'] == 0 and p['selected_entry'] == p['rows'][0]['entry'], p
    h.command('panel-select', 'none')
    assert h.panel()['selected'] is None
    h.verify_files()


def panel_paging(h):
    root = h.repo()
    for i in range(131):
        h.write(root / ('untracked-%03d.txt' % i), 'untracked\n')
    begin(h, [root])
    p = h.open_panel()
    assert p['entry_count'] == 131 and p['visible_rows'] == 128 and p['page'] == 0, p
    first = {r['path'] for r in p['rows']}
    launches = p['launches']
    h.command('panel-page', 'prev')
    assert h.panel()['page'] == 0
    h.command('panel-page', 'next')
    p = h.panel()
    assert p['page'] == 1 and p['visible_rows'] == 3 and p['selected'] is None, p
    second = {r['path'] for r in p['rows']}
    assert not first & second and len(first | second) == 131
    h.command('panel-select', 130)
    p = h.panel()
    assert p['selected'] == 130 and p['page'] == 1, p
    h.command('panel-page', 'next')
    assert h.panel()['page'] == 1
    h.command('panel-page', 'prev')
    p = h.panel()
    assert p['page'] == 0 and p['selected'] is None and p['launches'] == launches, p
    assert {r['path'] for r in p['rows']} == first
    h.verify_files()


def panel_stage_all(h):
    root = h.repo(files={'same.txt': 'BASE\n', 'other.txt': 'OTHER_BASE\n', 'staged.txt': 'STAGED_BASE\n'})
    other = h.repo('other', files={'unrelated.txt': 'UNRELATED_BASE\n'})
    h.write(root / 'same.txt', 'SAME_DISK\n')
    h.write(root / 'other.txt', 'OTHER_DISK\n')
    h.write(root / 'staged.txt', 'STAGED_INDEX\n')
    h.fixture_git(root, 'add', '--', 'staged.txt')
    h.write(root / 'new.txt', 'UNTRACKED\n')
    h.write(other / 'unrelated.txt', 'UNRELATED_DISK\n')
    begin(h, [root, other])
    h.open_panel()
    expected = entries(h, root)
    # Stage all unstaged TRACKED changes (git add -u); untracked + staged preserved.
    h.command('panel-stage-all')
    panel_review(h, 'stage_unstaged', 2)
    expected[('same.txt', 0)] = entry(b'SAME_DISK\n')
    expected[('other.txt', 0)] = entry(b'OTHER_DISK\n')
    panel_accept(h, root, expected, 'reviewed dock stage-all unstaged')
    assert (root / 'same.txt').read_bytes() == b'SAME_DISK\n'
    assert (root / 'new.txt').read_bytes() == b'UNTRACKED\n'
    assert (other / 'unrelated.txt').read_bytes() == b'UNRELATED_DISK\n'
    p = h.open_panel()
    assert p['staged_count'] == 3 and p['unstaged_count'] == 0 and p['untracked_count'] == 1, p
    h.verify_files()


def panel_stage_untracked(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'SAME_DISK\n')
    h.write(root / 'new.txt', 'UNTRACKED\n')
    h.write(root / 'dir/another.txt', 'UNTRACKED_DIR\n')
    begin(h, [root])
    h.open_panel()
    expected = entries(h, root)
    h.command('panel-stage-all', 'untracked')
    panel_review(h, 'stage_untracked', 2)
    expected[('new.txt', 0)] = entry(b'UNTRACKED\n')
    expected[('dir/another.txt', 0)] = entry(b'UNTRACKED_DIR\n')
    panel_accept(h, root, expected, 'reviewed dock stage-all untracked')
    # Tracked unstaged change is NOT staged by an untracked bulk write.
    assert entries(h, root)[('same.txt', 0)] == entry(b'BASE\n')
    p = h.open_panel()
    assert p['untracked_count'] == 0 and p['staged_count'] == 2 and p['unstaged_count'] == 1, p
    h.verify_files()


def panel_unstage_all(h):
    root = h.repo(files={'same.txt': 'BASE\n', 'other.txt': 'OTHER_BASE\n'})
    h.write(root / 'same.txt', 'SAME_INDEX\n')
    h.write(root / 'other.txt', 'OTHER_INDEX\n')
    h.fixture_git(root, 'add', '--', 'same.txt', 'other.txt')
    h.write(root / 'same.txt', 'SAME_DISK_UNSTAGED\n')
    h.write(root / 'new.txt', 'UNTRACKED\n')
    begin(h, [root])
    h.open_panel()
    expected = entries(h, root)
    h.command('panel-unstage-all')
    panel_review(h, 'unstage_staged', 2)
    expected[('same.txt', 0)] = entry(b'BASE\n')
    expected[('other.txt', 0)] = entry(b'OTHER_BASE\n')
    panel_accept(h, root, expected, 'reviewed dock unstage-all')
    # Whole-index reset never touches the worktree or untracked paths.
    assert (root / 'same.txt').read_bytes() == b'SAME_DISK_UNSTAGED\n'
    assert (root / 'new.txt').read_bytes() == b'UNTRACKED\n'
    p = h.open_panel()
    assert p['staged_count'] == 0 and p['unstaged_count'] == 2 and p['untracked_count'] == 1, p
    h.verify_files()


def panel_selected(h):
    root = h.repo(files={'same.txt': 'BASE\n', 'other.txt': 'OTHER_BASE\n'})
    h.write(root / 'same.txt', 'SAME_DISK\n')
    h.write(root / 'other.txt', 'OTHER_DISK\n')
    begin(h, [root])
    h.open_panel()
    p = h.panel()
    index = next(i for i, r in enumerate(p['rows']) if r['path'] == 'same.txt')
    h.command('panel-select', index)
    expected = entries(h, root)
    h.command('panel-stage-selected')
    panel_review(h, 'stage_selected', 1)
    expected[('same.txt', 0)] = entry(b'SAME_DISK\n')
    panel_accept(h, root, expected, 'reviewed dock stage-selected')
    # The other unstaged path is preserved untouched.
    assert entries(h, root)[('other.txt', 0)] == entry(b'OTHER_BASE\n')
    assert (root / 'other.txt').read_bytes() == b'OTHER_DISK\n'
    # Now unstage the same selected path; other staged paths would survive.
    p = h.open_panel()
    index = next(i for i, r in enumerate(p['rows']) if r['path'] == 'same.txt' and r['section'] == 'staged')
    h.command('panel-select', index)
    expected = entries(h, root)
    h.command('panel-unstage-selected')
    panel_review(h, 'unstage_selected', 1)
    expected[('same.txt', 0)] = entry(b'BASE\n')
    panel_accept(h, root, expected, 'reviewed dock unstage-selected')
    assert (root / 'same.txt').read_bytes() == b'SAME_DISK\n'
    h.verify_files()


def panel_review_reject(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'REJECTED_DISK\n')
    begin(h, [root])
    h.open_panel()
    metadata = h.mutation_preservation.metadata_tree(root / '.git')
    expected = entries(h, root)
    h.command('panel-stage-all')
    panel_review(h, 'stage_unstaged', 1)
    h.command('panel-review-reject')
    p = h.wait_panel(lambda p: p['state'] == 'cancelled' and not p['busy'])
    assert not p['committed'] and not p['review'] and p['error'] is None, p
    assert entries(h, root) == expected, 'Rejected review changed the index'
    assert h.mutation_preservation.metadata_tree(root / '.git') == metadata
    before = h.panel()
    h.command('panel-review-accept')  # consumed approval cannot replay a write
    assert h.panel()['jobs_started'] == before['jobs_started']
    h.verify_files()


def panel_commit_delegates(h):
    root = h.repo(files={'same.txt': 'BASE\n', 'other.txt': 'OTHER_BASE\n'})
    h.write(root / 'same.txt', 'STAGED\n')
    h.fixture_git(root, 'add', '--', 'same.txt')
    h.write(root / 'same.txt', 'UNSTAGED\n')
    h.write(root / 'other.txt', 'OTHER_DISK\n')
    begin_ro(h, [root])
    p = h.open_panel()
    assert p['commit_wired'] is False, 'Parent must delegate to the reviewed commit workflow'
    old = h.head(root)
    h.command('panel-commit')
    c = wait_for(lambda: c if (c := h.commit_probe())['state'] == 'confirming' and c['review'] else None, 18)
    assert c['kind'] == 'commit' and c['confirm'] == 'commit', c
    assert c['staged_count'] == 1 and c['staged_files'] == [{'status': ord('M'), 'path': 'same.txt'}], c
    # The dock commit button opened the commit review; it did not commit by itself.
    assert h.head(root) == old and not c['committed'], c
    expected = entries(h, root)
    h.command('commit-accept', 'Dock delegated commit\n\nBody.')
    c = wait_for(lambda: c if (c := h.commit_probe())['state'] == 'succeeded' else None, 18)
    assert c['committed'] and c['error'] is None, c
    h.reindex(root, expected, 'reviewed dock-delegated commit')
    new = h.head(root)
    assert new != old and h.out(root, 'rev-parse', 'HEAD^') == old, (old, new)
    assert h.blob(root, 'same.txt') == b'STAGED\n', 'Committed unstaged bytes'
    assert h.out(root, 'log', '-1', '--format=%B') == 'Dock delegated commit\n\nBody.'
    assert (root / 'same.txt').read_bytes() == b'UNSTAGED\n'
    assert (root / 'other.txt').read_bytes() == b'OTHER_DISK\n'
    h.command('commit-close')
    h.verify_files()


def panel_gates(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'DISK\n')
    h.watch_indexes()
    h.workspace_roots([root])
    Preservation(h)
    # Without trust the dock cannot launch Git or manufacture approval.
    h.command('focus-source-control')
    p = h.panel()
    assert not p['approved'] and not p['disclosure'] and p['launches'] == 0, p
    h.command('panel-accept')
    h.command('panel-stage-all')
    p = h.panel()
    assert not p['approved'] and p['launches'] == 0 and p['jobs_started'] == 0, p
    h.restricted(h.policy_idle())
    # Trust + disclosure, then a dirty buffer is excluded and never saved.
    h.trust()
    h.disclosure()
    h.command('git-accept')
    h.idle()
    h.open_panel()
    h.open_document(root / 'same.txt')
    h.replace_keyboard('UNSAVED_BUFFER_ONLY\n')
    doc = h.document(root / 'same.txt')
    assert doc['dirty'], doc
    p = h.panel_refresh()
    assert p['dirty_documents'] == 1, p
    expected = entries(h, root)
    h.command('panel-stage-all')
    panel_review(h, 'stage_unstaged', 1)
    expected[('same.txt', 0)] = entry(b'DISK\n')
    panel_accept(h, root, expected, 'reviewed dock stage with dirty buffer')
    assert h.document(root / 'same.txt') == doc, 'Dock saved or altered the dirty buffer'
    assert (root / 'same.txt').read_bytes() == b'DISK\n'
    h.verify_files()


# =============================================================================
# PROJECT DIFF WINDOW
# =============================================================================

def pd_multifile(h):
    base = ''.join('line %02d\n' % i for i in range(1, 21))
    root = h.repo(files={'same.txt': base, 'other.txt': 'OTHER_BASE\n', 'untracked.txt': 'X\n'})
    disk = base.replace('line 02\n', 'line 02 CHANGED\n').replace('line 18\n', 'line 18 CHANGED\n')
    h.write(root / 'same.txt', disk)
    h.write(root / 'other.txt', 'OTHER_DISK\n')
    begin(h, [root])
    # Open both changed files so the current-side excerpt binds to a real
    # editable Document (the read-only fallback pane is then not rendered).
    h.open_document(root / 'other.txt')
    h.open_document(root / 'same.txt')
    p = h.pd_show()
    # Only ordinary textual changed files are listed; untracked is excluded.
    assert p['files'] == ['other.txt', 'same.txt'] and p['file_count'] == 2, p
    assert p['selected_file'] == 0 and p['mode'] == 'unified' and p['side'] == 'both', p
    assert p['staged'] is False and p['diff_kind'] == 'text', p
    # Unified mode renders one read-only diff pane (gutter classification is a
    # background tag; the pane structure is observed via accessibility).
    assert len(h.pd_diff_panes()) == 1, h.pd_diff_panes()
    # Select the second file; its two hunks load.
    p = h.pd_select(1)
    assert p['hunk_count'] == 2 and p['selected_hunk'] == 0, p
    assert len(h.pd_diff_panes()) == 1
    # Hunk navigation.
    h.command('project-diff-next-hunk')
    assert h.pd()['selected_hunk'] == 1
    h.command('project-diff-next-hunk')
    assert h.pd()['selected_hunk'] == 1, 'Navigation must clamp at the last hunk'
    h.command('project-diff-prev-hunk')
    assert h.pd()['selected_hunk'] == 0
    h.command('project-diff-prev-hunk')
    assert h.pd()['selected_hunk'] == 0
    # Render modes: unified (one pane), split (old/new pair), word (one pane).
    h.command('project-diff-mode', 'split')
    p = h.pd()
    assert p['mode'] == 'split', p
    assert len(h.pd_diff_panes()) == 2, ('Split must render two read-only panes', h.pd_diff_panes())
    h.command('project-diff-mode', 'word')
    p = h.pd()
    assert p['mode'] == 'word' and p['diff_kind'] == 'text', p
    assert len(h.pd_diff_panes()) == 1
    h.command('project-diff-mode', 'unified')
    assert h.pd()['mode'] == 'unified'
    # Original side is read-only; current/both bind an editable excerpt when open.
    h.command('project-diff-side', 'original')
    p = h.pd()
    assert p['side'] == 'original' and p['excerpt_document'] is None and p['excerpt_editable'] is False, p
    h.command('project-diff-side', 'current')
    p = h.pd()
    assert p['side'] == 'current' and p['excerpt_document'] is not None and p['excerpt_editable'] is True, p
    h.command('project-diff-side', 'both')
    assert h.pd()['side'] == 'both'
    h.verify_files()


def pd_staged_side(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'INDEX\n')
    h.fixture_git(root, 'add', '--', 'same.txt')
    h.write(root / 'same.txt', 'DISK\n')
    begin(h, [root])
    h.pd_show()
    p = h.pd_select(0)
    assert p['staged'] is False and p['diff_kind'] == 'text', p
    # Cross-check the displayed side against the authoritative Source Control diff.
    assert '+DISK' in h.diff('same.txt')['diff']
    h.command('project-diff-staged', '1')
    p = h.wait_pd(lambda p: p['staged'] and not p['busy'] and p['pending'] == 'none' and p['diff_kind'] == 'text')
    staged = h.diff('same.txt', staged=True)['diff']
    assert '+INDEX' in staged and '-BASE' in staged and 'DISK' not in staged, staged
    h.command('project-diff-staged', '0')
    p = h.wait_pd(lambda p: not p['staged'] and not p['busy'] and p['pending'] == 'none')
    assert '+DISK' in h.diff('same.txt')['diff']
    h.verify_files()


def pd_stage_hunk(h):
    base = ''.join('line %02d\n' % i for i in range(1, 21))
    root = h.repo(files={'same.txt': base, 'unrelated.txt': 'UNRELATED_BASE\n'})
    other = h.repo('other', files={'u.txt': 'U_BASE\n'})
    disk = base.replace('line 02\n', 'line 02 CHANGED\n').replace('line 18\n', 'line 18 CHANGED\n')
    h.write(root / 'same.txt', disk)
    h.write(other / 'u.txt', 'U_DISK\n')
    begin(h, [root, other])
    h.pd_show()
    p = h.pd_select(0)
    assert p['hunk_count'] == 2, p
    after0 = base.replace('line 02\n', 'line 02 CHANGED\n').encode()
    expected = entries(h, root)
    h.command('project-diff-stage-hunk')
    pd_review(h, selection=False)
    expected[('same.txt', 0)] = entry(after0)
    pd_accept(h, root, expected, 'reviewed project-diff stage-hunk')
    # Worktree keeps BOTH changes; only hunk 0 reached the index.
    assert (root / 'same.txt').read_bytes() == disk.encode()
    assert (root / 'unrelated.txt').read_bytes() == b'UNRELATED_BASE\n'
    assert (other / 'u.txt').read_bytes() == b'U_DISK\n'
    # Unstage hunk 0 from the staged side; the index returns to base.
    h.command('project-diff-staged', '1')
    p = h.wait_pd(lambda p: p['staged'] and not p['busy'] and p['pending'] == 'none' and p['diff_kind'] == 'text')
    assert p['hunk_count'] == 1, p
    expected = entries(h, root)
    h.command('project-diff-unstage-hunk')
    pd_review(h, selection=False)
    expected[('same.txt', 0)] = entry(base.encode())
    pd_accept(h, root, expected, 'reviewed project-diff unstage-hunk')
    assert (root / 'same.txt').read_bytes() == disk.encode()
    h.verify_files()


def pd_selection(h):
    root = h.repo(files={'same.txt': 'a\nb\nc\n', 'unrelated.txt': 'UNRELATED_BASE\n'})
    disk = 'a\nb\nX1\nX2\nX3\nc\n'
    h.write(root / 'same.txt', disk)
    begin(h, [root])
    h.pd_show()
    p = h.pd_select(0)
    assert p['hunk_count'] == 1 and p['selected_hunk'] == 0, p
    # Stage only the first two of three added change-lines.
    h.command('project-diff-select-lines', '0:2')
    p = h.pd()
    assert p['selected_lines'] == [{'start': 0, 'end': 2}], p
    after = b'a\nb\nX1\nX2\nc\n'
    expected = entries(h, root)
    h.command('project-diff-stage-selection')
    review = pd_review(h, selection=True)
    assert 'X3' not in review['mutation_review'].split('AFTER — INDEX')[1], 'Unselected line staged'
    expected[('same.txt', 0)] = entry(after)
    pd_accept(h, root, expected, 'reviewed project-diff selection staging')
    # The unselected change-line remains on disk and unstaged; unrelated preserved.
    assert (root / 'same.txt').read_bytes() == disk.encode()
    assert (root / 'unrelated.txt').read_bytes() == b'UNRELATED_BASE\n'
    assert entries(h, root)[('unrelated.txt', 0)] == entry(b'UNRELATED_BASE\n')
    unstaged = h.fixture_git(root, 'diff', '--', 'same.txt')
    assert b'+X3' in unstaged and b'+X1' not in unstaged and b'+X2' not in unstaged, unstaged
    p = h.pd_select(0)
    assert p['hunk_count'] == 1, p
    h.command('project-diff-select-lines', '2:1')
    p = h.pd()
    assert p['selected_lines'] == [], p
    h.verify_files()


def pd_excerpt(h):
    root = h.repo(files={'same.txt': 'line1\nline2\nline3\n'})
    disk = 'line1\nline2 CHANGED\nline3\n'
    h.write(root / 'same.txt', disk)
    begin_ro(h, [root], active=root / 'same.txt')
    doc = h.document(root / 'same.txt')
    assert doc and not doc['dirty'], doc
    original = doc['text']
    h.pd_show()
    p = h.pd_select(0)
    assert p['excerpt_document'] == doc['id'] and p['excerpt_editable'] is True, p
    # A real insertion in the editable excerpt propagates to the canonical document.
    marker = 'ZZEDITZZ'
    h.pd_edit_excerpt(marker)
    edited = wait_for(lambda: d if (d := h.document(root / 'same.txt'))['dirty'] and marker in d['text'] else None, 8)
    assert edited['text'].replace(marker, '', 1) == original, ('Excerpt edit was not a clean insertion', edited)
    assert (root / 'same.txt').read_bytes() == disk.encode(), 'Excerpt edit wrote to disk'
    # Staging uses the captured disk snapshot and excludes the unsaved edit.
    expected = entries(h, root)
    h.command('project-diff-stage-hunk')
    review = pd_review(h, selection=False)
    assert marker not in review['mutation_review'], 'Unsaved excerpt edit leaked into staging'
    expected[('same.txt', 0)] = entry(disk.encode())
    pd_accept(h, root, expected, 'reviewed project-diff stage excluding unsaved excerpt')
    assert h.document(root / 'same.txt')['dirty'], 'Staging saved the dirty buffer'
    assert (root / 'same.txt').read_bytes() == disk.encode()
    # Save through the parent-wired handler writes the edited buffer to disk.
    h.command('project-diff-save')
    saved = wait_for(lambda: d if not (d := h.document(root / 'same.txt'))['dirty'] else None, 8)
    assert marker in saved['text'], saved
    assert (root / 'same.txt').read_bytes() == saved['text'].encode()
    h.expect(root / 'same.txt', saved['text'])
    h.verify_files()


def pd_reject(h):
    root = h.repo(files={'same.txt': 'a\nb\nc\n'})
    h.write(root / 'same.txt', 'a\nb\nX1\nX2\nc\n')
    begin(h, [root])
    h.pd_show()
    h.pd_select(0)
    metadata = h.mutation_preservation.metadata_tree(root / '.git')
    expected = entries(h, root)
    h.command('project-diff-stage-hunk')
    pd_review(h, selection=False)
    h.command('project-diff-reject')
    p = h.wait_pd(lambda p: p['mutation_state'] == 'cancelled' and not p['mutation_busy'])
    assert not p['mutation_committed'] and not p['mutation_dialog'], p
    assert entries(h, root) == expected, 'Rejected review changed the index'
    assert h.mutation_preservation.metadata_tree(root / '.git') == metadata
    before = h.pd()
    h.command('project-diff-accept')  # consumed approval cannot replay a write
    assert h.pd()['mutation_state'] == before['mutation_state']
    h.verify_files()


def pd_gates(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'DISK\n')
    h.watch_indexes()
    h.workspace_roots([root])
    Preservation(h)
    # Project Diff never grants trust or runs Git independently: without a valid
    # Source Control it defers to the Source Control window.
    h.command('project-diff-show')
    p = h.pd()
    assert not p['visible'] and not p['git_valid'], p
    g = h.wait_git(lambda p: p['disclosure'])
    assert not g['approved'], g
    h.command('project-diff-stage-hunk')
    assert not h.pd()['visible'] and h.git()['launches'] == 0, 'Project Diff bypassed disclosure'
    h.restricted(h.policy_idle())
    h.verify_files()


CASES = [
    ('panel-dock', panel_dock),
    ('panel-groups', panel_groups),
    ('panel-paging', panel_paging),
    ('panel-stage-all', panel_stage_all),
    ('panel-stage-untracked', panel_stage_untracked),
    ('panel-unstage-all', panel_unstage_all),
    ('panel-selected', panel_selected),
    ('panel-review-reject', panel_review_reject),
    ('panel-commit-delegates', panel_commit_delegates),
    ('panel-gates', panel_gates),
    ('pd-multifile', pd_multifile),
    ('pd-staged-side', pd_staged_side),
    ('pd-stage-hunk', pd_stage_hunk),
    ('pd-selection', pd_selection),
    ('pd-excerpt', pd_excerpt),
    ('pd-reject', pd_reject),
    ('pd-gates', pd_gates),
]


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
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-git-ui')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    parser.add_argument('--case', action='append', help='exact case or prefix group; repeatable')
    parser.add_argument('--list-cases', action='store_true')
    args = parser.parse_args()
    if args.list_cases:
        print('\n'.join(name for name, _ in CASES))
        return 0
    if args.binary is None:
        parser.error('--binary is required')
    try:
        cases = choose_cases(args.case)
    except ValueError as exc:
        parser.error(str(exc))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    run_output = Path(tempfile.mkdtemp(prefix='run-', dir=output))
    report = output / 'results.json'
    evidence: dict[str, Any] = dict(schema_version=1, status='running', complete_suite=not bool(args.case),
                    invocation=[sys.executable, *sys.argv], binary=str(args.binary.resolve()),
                    artifacts=str(run_output), selected_cases=[name for name, _ in cases],
                    unselected_cases=[case[0] for case in CASES if case not in cases], checks=[],
                    case_budget_seconds=75, suite_budget_seconds=600,
                    isolation='Private headless Wayland/session bus and per-case disposable HOME/XDG/repos; no host desktop',
                    limitations=['Read-only commands are not a sandbox: local clean filters can execute.',
                                 'Unified added/removed gutter tags are GtkTextTag backgrounds; they are covered via rendered content, @@ hunk headers and split old/new pane separation, not pixel colors.',
                                 'No hidden refresh is sampled over bounded observation windows, not proven for all time.'])
    began = time.monotonic()
    save(report, evidence)

    def expired(_signum, _frame):
        raise CaseTimeout('Native Git UI case/suite runtime budget exceeded')

    previous = signal.signal(signal.SIGALRM, expired)
    try:
        binary = args.binary.resolve()
        data = binary.read_bytes()
        evidence['binary_sha256'] = digest(data)
        evidence['source_sha256'] = {str(path.relative_to(PROJECT)): digest(path.read_bytes())
                                     for path in (Path(__file__).resolve(), PROJECT / 'tests/git.py',
                                                  PROJECT / 'tests/git_mutations.py', PROJECT / 'tests/git_workflows.py',
                                                  *[PROJECT / 'src/git' / name for name in (
                                                      'panel.zig', 'project_diff.zig', 'diff_render.zig',
                                                      'controller.zig', 'commit_controller.zig',
                                                      'index_transaction.zig', 'hunk.zig')],
                                                  PROJECT / 'src/workbench/dock.zig')}
        missing = [marker.decode() for marker in REQUIRED_MARKERS if marker not in data]
        assert not missing, ('Stale binary refused — missing integrated M4 UI probe markers', missing)
        del data
        signal.alarm(45)
        with PrivateSession(run_output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            stage_styles(session, evidence)
            start_accessibility(session)
            assert session.display_path.is_relative_to(session.base)
            assert session.env['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path=' + str(session.runtime))
            for name, scenario in cases:
                remaining = 600 - (time.monotonic() - began)
                if remaining < 10:
                    raise CaseTimeout('Whole-suite budget exhausted')
                record: dict[str, Any] = dict(name=name, status='running')
                evidence['checks'].append(record)
                save(report, evidence)
                h, start = None, time.monotonic()
                child_start = len(session.children)
                print('RUN', name, flush=True)
                signal.alarm(max(1, int(min(75, remaining))))
                try:
                    h = GitUiHarness.__new__(GitUiHarness)
                    h.__init__(session, binary, run_output, evidence, name, min(start + 75, began + 600))
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    resets = sum(item['case'] == name for item in evidence.get('index_baseline_resets', []))
                    record.update(status='passed', indexes_verified=len(h.indexes), index_baseline_resets=resets,
                                  index_expectation='explicit verified UI baseline' if resets else 'original bytes/mtime',
                                  file_hashes_verified=len(h.expected), sentinels_absent=len(h.sentinels))
                    if not resets:
                        record['indexes_unchanged'] = len(h.indexes)
                    print('PASS', name, flush=True)
                except Exception as exc:
                    record.update(status='failed', error=str(exc), traceback=traceback.format_exc())
                    print('FAIL', name, str(exc)[:1800], flush=True)
                finally:
                    signal.alarm(0)
                    if h is not None:
                        record['last_probe'] = getattr(h, 'last', {}).copy()
                        record['indexes'] = {str(path): None if value is None else
                                             dict(sha256=digest(value[0]), mtime_ns=value[1])
                                             for path, value in getattr(h, 'indexes', {}).items()}
                        if getattr(h, 'app', None) is not None:
                            record['native_log'] = str(h.app.logfile)
                            if h.app.proc.poll() is None and record['status'] != 'passed':
                                for pid in descendants(h.app.proc.pid):
                                    stamp = process_stamp(pid)
                                    if stamp is not None:
                                        h.processes[pid] = stamp
                        if record['status'] != 'passed' and getattr(h, 'app', None) is not None:
                            try:
                                h.screenshot('failure')
                                h.verify_files()
                            except Exception:
                                record['failure_evidence_error'] = traceback.format_exc()
                    for child in reversed(session.children[child_start:]):
                        child.stop()
                    del session.children[child_start:]
                    for pid, stamp in getattr(h, 'processes', {}).items():
                        if process_stamp(pid) == stamp:
                            record.setdefault('forced_process_cleanup', []).append(pid)
                            record.update(status='failed', error='Observed Git/filter process survived native teardown')
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                    record['seconds'] = time.monotonic() - start
                    save(report, evidence)
    except Exception:
        evidence.update(fatal=traceback.format_exc())
        print(evidence['fatal'], file=sys.stderr, flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        completed = {record['name'] for record in evidence['checks']}
        for name, _ in cases:
            if name not in completed:
                evidence['checks'].append(dict(name=name, status='blocked', reason='Suite setup/budget failed'))
        counts = {state: sum(c['status'] == state for c in evidence['checks']) for state in ('passed', 'failed', 'blocked')}
        evidence['status'] = ('failed' if 'fatal' in evidence or counts['failed'] or counts['blocked'] else
                              'selected-cases-passed' if args.case else 'passed')
        evidence.update(counts=counts, seconds=time.monotonic() - began)
        save(report, evidence)
        save(run_output / 'results.json', evidence)
    print('%s: %s; %s' % (evidence['status'].upper(), evidence['counts'], report), flush=True)
    return 1 if evidence['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
