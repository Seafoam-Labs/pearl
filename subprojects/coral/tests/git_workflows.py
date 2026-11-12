#!/usr/bin/env python3
"""M4 native workflow acceptance: commit/uncommit, branches/tags, worktrees,
stash, conflicts, remotes (local bare), history/blame/permalink and hunk
stage/unstage — in a private Wayland/D-Bus/HOME/XDG session.

  python3 -B tests/git_workflows.py --binary /path/to/coral-test --case commit-staged-only

Every fixture repository, remote and worktree lives under the disposable session
tree; no host repository is touched and no network is used (remotes are local
bare paths). Trust and the Source Control disclosure are exercised through the
real policy commands; each workflow is requested through the controller's
documented fixture bridge, which drives the *actual* public entry points and
answers the *actual* visible native dialogs (it never grants trust or bypasses a
permit). Read-only inspection uses the existing win.git-* GActions.

The runner mirrors tests/git.py: per-case disposable HOME/XDG/repos, bounded
case/suite budgets, and failure evidence (logs, probes, screenshots) that survives
fixture disposal. --case accepts exact names or prefix groups, repeatable; subsets
are reported as partial.

Integration gate: the binary must contain every new CORAL_GIT_* probe marker.
A stale binary that predates the parent's controller/command wiring is refused
up front rather than producing misleading per-case failures.

Hunk cases: git.Controller hunk selection is wired by the parent. The backend
(index_transaction.zig stage_hunk/unstage_hunk + hunk.zig HunkRef{ordinal,digest})
is already present; the surface assumptions used here are isolated in the HUNK
ADAPTER section below (probe field names + selection/command action names) so they
can be reconciled with the parent's final schema in one place.
"""
import argparse
import functools
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path
from typing import Any

from search import PEARL, PROJECT
from windows import stage_styles
from git import GitHarness, digest, save, CaseTimeout, process_stamp, descendants
from git_mutations import entries, entry, escaped, sha, Preservation
from git_mutations import mutation as mutation_probe, accept as mutation_accept

# search installs the shared scripts/integration helper paths at runtime.
from pearl_session import PrivateSession, fixture_prefix, wait_for  # pyright: ignore[reportMissingImports]


# --- probe markers / fixture probe actions (from src/git/*_controller.zig) -----

COMMIT = 'CORAL_GIT_COMMIT'
REFS = 'CORAL_GIT_REFS'
WORKTREE = 'CORAL_GIT_WORKTREE'
STASH = 'CORAL_GIT_STASH'
CONFLICT = 'CORAL_GIT_CONFLICT'
REMOTE = 'CORAL_GIT_REMOTE'
HISTORY = 'CORAL_GIT_HISTORY'

PROBE_ACTION = {
    COMMIT: 'commit-probe',
    REFS: 'refs-probe',
    WORKTREE: 'worktree-probe',
    STASH: 'stash-probe',
    CONFLICT: 'conflict-probe',
    REMOTE: 'git-remote-probe',
    HISTORY: 'git-history-probe',
}

REQUIRED_MARKERS = (
    b'CORAL_GIT ', b'CORAL_COMMAND_DONE',
    b'CORAL_GIT_COMMIT ', b'CORAL_GIT_REFS ', b'CORAL_GIT_WORKTREE ',
    b'CORAL_GIT_STASH ', b'CORAL_GIT_CONFLICT ', b'CORAL_GIT_REMOTE ', b'CORAL_GIT_HISTORY ',
)


class WorkflowHarness(GitHarness):
    """GitHarness plus probes/helpers for the M4 workflow controllers."""

    def wf(self, marker):
        """Probe a workflow controller once via its documented fixture action."""
        action = PROBE_ACTION[marker]
        lines, _ = self.command(action)
        prefix = marker + ' '
        value = next((json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)), None)
        assert value is not None, (
            'Workflow probe marker absent — controller not wired into the binary', marker, lines[-6:])
        assert value['window'] == self.target, (marker, value.get('window'), self.target)
        self.last[marker] = value
        return value

    def wait_wf(self, marker, predicate, timeout=18):
        def ready():
            value = self.wf(marker)
            return value if predicate(value) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('Workflow deadline', marker, self.last.get(marker))) from exc

    def idle_wf(self, marker, timeout=18):
        return self.wait_wf(marker, lambda p: not p['busy'] and p.get('pending', 'none') == 'none', timeout)

    def close_workflows(self):
        # Idempotent invalidation of every workflow controller; harmless if a
        # controller was never used. Keeps teardown free of lingering dialogs/holds.
        for action in ('commit-close', 'refs-close', 'worktree-close', 'stash-close',
                       'conflict-close', 'git-remote-close', 'git-history-close'):
            self.command(action)

    def stop(self):
        if self.app is not None and self.app.proc.poll() is None:
            self.close_workflows()
        super().stop()

    # -- fixture Git conveniences (all writes confined to disposable fixtures) --

    def out(self, root, *args):
        return self.fixture_git(root, *args).decode().strip()

    def head(self, root):
        return self.out(root, 'rev-parse', 'HEAD')

    def branch(self, root):
        return self.out(root, 'rev-parse', '--abbrev-ref', 'HEAD')

    def blob(self, root, path):
        return self.fixture_git(root, 'show', 'HEAD:' + path)

    def expect(self, path, data):
        """Record the new authoritative bytes of a file the app legitimately wrote."""
        data = data.encode() if isinstance(data, str) else data
        self.expected[path] = digest(data)

    def bare(self, name='remote.git'):
        root = self.fixtures / name
        root.mkdir(parents=True)
        self.fixture_git(root, 'init', '--bare', '--initial-branch=main', '--template=')
        return root

    def identity(self, root):
        # The app's write environment uses the user's (private, disposable) Git
        # identity; repo-local config keeps commits deterministic without hooks.
        self.fixture_git(root, 'config', 'user.name', 'Coral disposable fixture')
        self.fixture_git(root, 'config', 'user.email', 'fixture@example.invalid')
        self.fixture_git(root, 'config', 'commit.gpgSign', 'false')
        self.fixture_git(root, 'config', 'tag.gpgSign', 'false')

    def file_git(self, root, *args, expected=0, input=None):
        """fixture_git with ONLY the local file transport permitted (no network).

        Mirrors src/git/remote_test.zig: GIT_ALLOW_PROTOCOL=file lets a local bare
        remote be cloned/fetched/pushed while every network protocol stays refused.
        All other fixture_git guards (disposable paths, clean env, no hooks) apply.
        """
        previous = self.git_env['GIT_ALLOW_PROTOCOL']
        self.git_env['GIT_ALLOW_PROTOCOL'] = 'file'
        try:
            return self.fixture_git(root, *args, expected=expected, input=input)
        finally:
            self.git_env['GIT_ALLOW_PROTOCOL'] = previous

    def reindex(self, root, expected, reason):
        """Rebaseline ONLY an already-verified index change from a reviewed write.

        Workflow writes (commit, checkout, stash, conflict resolution) legitimately
        republish the index. Verify the complete entry map and every other watched
        index first, then replace just this index's bytes/mtime baseline. Unlike the
        selected-file mutation guard, the index may be republished with identical
        entries (e.g. a merge commit), so a byte/mtime change is recorded, not required.
        """
        raw = self.fixture_git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index')
        assert raw.endswith(b'\n'), raw
        path = Path(os.fsdecode(raw[:-1]))
        assert path.resolve().is_relative_to(self.fixtures.resolve()), path
        assert path in self.indexes, path
        actual = entries(self, root)
        assert actual == expected, ('Unexpected index entries', reason, expected, actual)
        for other, before in self.indexes.items():
            if other != path:
                now = (other.read_bytes(), other.stat().st_mtime_ns) if other.exists() else None
                assert now == before, ('Unrelated repository index changed', other)
        after = (path.read_bytes(), path.stat().st_mtime_ns) if path.exists() else None
        changed = after != self.indexes[path]
        self.indexes[path] = after
        self.evidence.setdefault('index_baseline_resets', []).append(dict(
            case=self.name, reason=reason, path=str(path), changed=changed,
            entries=[dict(path=p, stage=s, mode=m, oid=o) for (p, s), (m, o) in sorted(actual.items())]))


# --- shared assertion helpers -------------------------------------------------

def mut(h):
    return h.git()['mutation']


def wait_mut(h, predicate, timeout=18):
    return h.wait_git(lambda p: predicate(p['mutation']))


def no_lock(h, root):
    gitdir = Path(h.out(root, 'rev-parse', '--path-format=absolute', '--git-dir'))
    assert not (gitdir / 'index.lock').exists(), ('Stray index lock', gitdir)


def stage_file(h, root, path, data):
    h.write(root / path, data)
    h.fixture_git(root, 'add', '--', path)


def commit_fixture(h, root, message='Disposable fixture commit'):
    h.fixture_git(root, 'add', '--all', '--', '.')
    h.fixture_git(root, 'commit', '--no-gpg-sign', '-m', message)


def begin(h, roots, active=None):
    """Trust + Source Control disclosure through the real policy commands."""
    for root in roots:
        h.identity(root)
    return h.start(roots, active=active)


# =============================================================================
# COMMIT / UNCOMMIT
# =============================================================================

def commit_staged_only(h):
    root = h.repo(files={'same.txt': 'BASE\n', 'other.txt': 'OTHER_BASE\n'})
    stage_file(h, root, 'same.txt', 'STAGED\n')
    h.write(root / 'same.txt', 'UNSTAGED\n')          # unstaged tracked change
    h.write(root / 'other.txt', 'OTHER_DISK\n')        # another unstaged change
    h.write(root / 'untracked.txt', 'UNTRACKED\n')     # never committed
    begin(h, [root])
    old = h.head(root)
    h.command('commit-show')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'confirming' and p['review'])
    assert p['kind'] == 'commit' and p['confirm'] == 'commit', p
    assert p['staged_count'] == 1 and p['staged_files'] == [{'status': ord('M'), 'path': 'same.txt'}], p
    assert p['unstaged_count'] >= 2 and p['unmerged_count'] == 0, p
    expected = entries(h, root)
    h.command('commit-accept', 'Subject line\n\nBody paragraph.')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'succeeded')
    assert p['committed'] and p['error'] is None, p
    h.reindex(root, expected, 'reviewed staged-only commit')
    new = h.head(root)
    assert new != old and h.out(root, 'rev-parse', 'HEAD^') == old, (old, new)
    assert h.blob(root, 'same.txt') == b'STAGED\n', 'Committed the unstaged bytes'
    assert h.out(root, 'log', '-1', '--format=%B') == 'Subject line\n\nBody paragraph.', 'Message not committed verbatim'
    # Unstaged + untracked preserved on disk and out of the commit.
    assert (root / 'same.txt').read_bytes() == b'UNSTAGED\n'
    assert (root / 'other.txt').read_bytes() == b'OTHER_DISK\n'
    assert (root / 'untracked.txt').read_bytes() == b'UNTRACKED\n'
    assert 'untracked.txt' not in h.out(root, 'ls-tree', '-r', '--name-only', 'HEAD')
    assert 'other.txt' in h.out(root, 'ls-tree', '-r', '--name-only', 'HEAD')
    assert h.blob(root, 'other.txt') == b'OTHER_BASE\n', 'Unstaged other.txt was committed'
    no_lock(h, root)
    h.evidence.setdefault('workflow_outcomes', []).append(dict(case=h.name, probe=p))


def commit_uncommit_soft(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    base = h.head(root)
    stage_file(h, root, 'same.txt', 'STAGED\n')
    h.write(root / 'same.txt', 'UNSTAGED\n')
    begin(h, [root])
    h.command('commit-show')
    h.wait_wf(COMMIT, lambda p: p['state'] == 'confirming' and p['review'])
    expected = entries(h, root)
    h.command('commit-accept', 'To be uncommitted')
    h.wait_wf(COMMIT, lambda p: p['state'] == 'succeeded')
    h.reindex(root, expected, 'reviewed commit before uncommit')
    h.idle()  # commit refreshes Source Control asynchronously before uncommit
    head1 = h.head(root)
    assert head1 != base
    staged_before = entries(h, root)
    h.command('commit-uncommit-show')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'confirming' and p['review'])
    assert p['kind'] == 'uncommit' and p['confirm'] == 'uncommit', p
    assert p['head_oid'] == head1 and p['parent_oid'] == base, p
    h.command('commit-accept')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'succeeded')
    assert p['committed'], p
    assert h.head(root) == base, 'Soft reset did not move HEAD back to the parent'
    assert entries(h, root) == staged_before, 'Uncommit changed the index (must keep it staged)'
    assert (root / 'same.txt').read_bytes() == b'UNSTAGED\n', 'Uncommit changed worktree bytes'
    assert h.blob(root, 'same.txt') == b'BASE\n'
    no_lock(h, root)


def commit_stage_tracked(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'TRACKED_CHANGE\n')
    h.write(root / 'untracked.txt', 'NEVER_ADDED\n')
    begin(h, [root])
    h.command('commit-stage-show')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'confirming' and p['review'])
    assert p['kind'] == 'stage_tracked' and p['confirm'] == 'stage', p
    h.command('commit-accept')  # approve git add -u
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'confirming' and p['confirm'] == 'commit' and p['staged'])
    assert p['staged_files'] == [{'status': ord('M'), 'path': 'same.txt'}], p
    expected = entries(h, root)
    h.reindex(root, expected, 'reviewed git add -u')
    h.command('commit-accept', 'Stage tracked then commit')
    h.wait_wf(COMMIT, lambda p: p['state'] == 'succeeded')
    h.reindex(root, expected, 'reviewed stage-tracked commit')
    assert h.blob(root, 'same.txt') == b'TRACKED_CHANGE\n'
    assert 'untracked.txt' not in h.out(root, 'ls-tree', '-r', '--name-only', 'HEAD'), 'add -u added an untracked file'
    assert (root / 'untracked.txt').read_bytes() == b'NEVER_ADDED\n'
    no_lock(h, root)


def commit_reject(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    stage_file(h, root, 'same.txt', 'REJECTED\n')
    begin(h, [root])
    old = h.head(root)
    h.command('commit-show')
    h.wait_wf(COMMIT, lambda p: p['state'] == 'confirming' and p['review'])
    h.command('commit-reject')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'cancelled')
    assert not p['committed'], p
    assert h.head(root) == old and entries(h, root)[('same.txt', 0)] == entry(b'REJECTED\n')
    no_lock(h, root)


def commit_empty_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'UNSTAGED_ONLY\n')  # nothing staged
    begin(h, [root])
    old = h.head(root)
    h.command('commit-show')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'failed')
    assert p['error'] == 'EmptyStaged' and not p['committed'], p
    assert h.head(root) == old
    no_lock(h, root)


def commit_uncommit_initial_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})  # exactly one commit, no parent
    begin(h, [root])
    old = h.head(root)
    h.command('commit-uncommit-show')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'failed')
    assert p['error'] == 'InitialOrMergeCommit' and not p['committed'], p
    assert h.head(root) == old
    no_lock(h, root)


def commit_uncommit_published_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'PUBLISHED\n')
    commit_fixture(h, root, 'Published commit')
    head1 = h.head(root)
    # Configure a local upstream whose tip already contains HEAD (published).
    # git status only reports branch.upstream when a real remote is configured.
    bare = h.bare()
    h.fixture_git(root, 'config', 'remote.origin.url', str(bare))
    h.fixture_git(root, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
    h.fixture_git(root, 'config', 'branch.main.remote', 'origin')
    h.fixture_git(root, 'config', 'branch.main.merge', 'refs/heads/main')
    h.fixture_git(root, 'update-ref', 'refs/remotes/origin/main', head1)
    begin(h, [root])
    h.command('commit-uncommit-show')
    p = h.wait_wf(COMMIT, lambda p: p['state'] == 'failed')
    # The refusal reason is authoritative; abort() clears the published probe flag.
    assert p['error'] == 'PublishedHead' and not p['committed'], p
    assert h.head(root) == head1
    no_lock(h, root)


# =============================================================================
# BRANCHES / TAGS
# =============================================================================

def refs_wait_dialog(h, flow):
    return h.wait_wf(REFS, lambda p: p['flow'] == flow and p['dialog'] and not p['busy'])


def refs_branch_index(h, name, delete=False):
    p = h.wf(REFS)
    rows = [b for b in p['branches'] if not (delete and b['remote'])]
    return next(i for i, b in enumerate(rows) if b['name'] == name)


def refs_create_branch(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    begin(h, [root])
    head = h.head(root)
    h.command('refs-show', 'create-branch')
    refs_wait_dialog(h, 'create_branch_name')
    h.command('refs-answer', 'text:feature/topic')
    refs_wait_dialog(h, 'create_branch_confirm')
    writes = h.wf(REFS)['writes']
    h.command('refs-accept')
    p = h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    assert p['error'] is None, p
    assert h.out(root, 'rev-parse', 'refs/heads/feature/topic') == head, 'Branch not created at HEAD'
    assert h.branch(root) == 'main', 'Create branch must not check out'
    assert (root / 'same.txt').read_bytes() == b'BASE\n'
    no_lock(h, root)


def refs_switch_branch(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'checkout', '-b', 'topic')
    h.write(root / 'same.txt', 'TOPIC\n')
    commit_fixture(h, root, 'Topic commit')
    h.fixture_git(root, 'checkout', 'main')
    begin(h, [root])
    assert (root / 'same.txt').read_bytes() == b'BASE\n'
    h.command('refs-show', 'switch-branch')
    refs_wait_dialog(h, 'switch_pick')
    index = refs_branch_index(h, 'topic')
    h.command('refs-answer', str(index))
    refs_wait_dialog(h, 'switch_confirm')
    writes = h.wf(REFS)['writes']
    h.command('refs-accept')
    h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    h.idle()  # switch triggers a Source Control refresh
    assert h.branch(root) == 'topic', 'Did not switch branch'
    assert (root / 'same.txt').read_bytes() == b'TOPIC\n', 'Worktree not updated to topic'
    h.expect(root / 'same.txt', b'TOPIC\n')
    h.reindex(root, {('same.txt', 0): entry(b'TOPIC\n')}, 'reviewed branch switch')
    no_lock(h, root)


def refs_switch_dirty_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'branch', 'topic')
    h.write(root / 'same.txt', 'DIRTY\n')  # unstaged change blocks switching
    begin(h, [root])
    h.command('refs-show', 'switch-branch')
    refs_wait_dialog(h, 'switch_pick')
    h.command('refs-answer', str(refs_branch_index(h, 'topic')))
    p = refs_wait_dialog(h, 'dirty_choice')
    assert p['dirty'] >= 1, p
    writes = p['writes']
    h.command('refs-accept')  # "Use stash command" — never discards or switches
    p = h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'])
    assert p['writes'] == writes, 'Dirty switch performed a write'
    assert h.branch(root) == 'main' and (root / 'same.txt').read_bytes() == b'DIRTY\n'
    no_lock(h, root)


def refs_delete_merged(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'branch', 'merged')  # points at HEAD, fully merged
    begin(h, [root])
    h.command('refs-show', 'delete-branch')
    refs_wait_dialog(h, 'delete_pick')
    h.command('refs-answer', str(refs_branch_index(h, 'merged', delete=True)))
    p = refs_wait_dialog(h, 'delete_confirm')
    assert p['merged'] is True, p
    writes = p['writes']
    h.command('refs-accept')
    h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    assert h.fixture_git(root, 'rev-parse', '--verify', 'refs/heads/merged', expected=128) == b''
    assert h.branch(root) == 'main'
    no_lock(h, root)


def refs_delete_unmerged_force(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'checkout', '-b', 'unmerged')
    h.write(root / 'same.txt', 'UNIQUE\n')
    commit_fixture(h, root, 'Unique commit')
    h.fixture_git(root, 'checkout', 'main')
    h.expect(root / 'same.txt', b'BASE\n')  # checkout restored BASE; UNIQUE lives only on the unmerged branch
    begin(h, [root])
    h.command('refs-show', 'delete-branch')
    refs_wait_dialog(h, 'delete_pick')
    h.command('refs-answer', str(refs_branch_index(h, 'unmerged', delete=True)))
    p = refs_wait_dialog(h, 'delete_force')
    assert p['merged'] is False, p
    writes = p['writes']
    h.command('refs-answer', 'text:wrong-name')  # mismatched force confirmation
    p = refs_wait_dialog(h, 'delete_force')
    assert p['writes'] == writes, 'Mismatched force text deleted the branch'
    assert h.out(root, 'rev-parse', 'refs/heads/unmerged')
    h.command('refs-answer', 'text:unmerged')  # exact name confirms force delete
    h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    assert h.fixture_git(root, 'rev-parse', '--verify', 'refs/heads/unmerged', expected=128) == b''
    no_lock(h, root)


def refs_delete_dirty_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'branch', 'topic')
    h.write(root / 'same.txt', 'DIRTY\n')
    begin(h, [root])
    h.command('refs-show', 'delete-branch')
    refs_wait_dialog(h, 'delete_pick')
    h.command('refs-answer', str(refs_branch_index(h, 'topic', delete=True)))
    p = refs_wait_dialog(h, 'dirty_choice')
    writes = p['writes']
    h.command('refs-accept')
    p = h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'])
    assert p['writes'] == writes and h.out(root, 'rev-parse', 'refs/heads/topic')
    no_lock(h, root)


def refs_create_tag(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    begin(h, [root])
    head = h.head(root)
    h.command('refs-show', 'create-tag')
    refs_wait_dialog(h, 'create_tag_name')
    h.command('refs-answer', 'text:v1.0')
    refs_wait_dialog(h, 'create_tag_confirm')
    writes = h.wf(REFS)['writes']
    h.command('refs-accept')
    h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    assert h.out(root, 'rev-parse', 'refs/tags/v1.0') == head, 'Lightweight tag not at HEAD'
    # Read-only tag listing shows it as lightweight.
    h.command('refs-show', 'tags')
    p = h.wait_wf(REFS, lambda p: p['flow'] == 'tags_pick' and p['dialog'] and p['tag_count'] >= 1)
    tag = next(t for t in p['tags'] if t['name'] == 'v1.0')
    assert tag['lightweight'] is True and tag['oid'] == head, tag
    h.command('refs-reject')
    h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['dialog'])
    no_lock(h, root)


def refs_invalid_name(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    begin(h, [root])
    h.command('refs-show', 'create-branch')
    refs_wait_dialog(h, 'create_branch_name')
    h.command('refs-answer', 'text:bad name')  # spaces are invalid ref names
    p = refs_wait_dialog(h, 'create_branch_name')  # re-prompt, no write
    assert p['writes'] == 0, p
    assert h.fixture_git(root, 'rev-parse', '--verify', 'refs/heads/bad name', expected=128) == b''
    h.command('refs-reject')
    h.wait_wf(REFS, lambda p: p['flow'] == 'none' and not p['dialog'])
    no_lock(h, root)


# =============================================================================
# WORKTREES
# =============================================================================

def worktree_flow(h, show, flow, attempts=8):
    """Reach a worktree picker flow, tolerating workspace churn from a fresh worktree.

    Creating a worktree inside the monitored root briefly rescans the workspace,
    which fails closed (invalidates) any in-flight controller job. Re-request once
    the churn settles; the controller recaptures the still-selected repository.
    """
    for _ in range(attempts):
        h.command('worktree-show', show)
        try:
            return h.wait_wf(WORKTREE, lambda p: p['flow'] == flow and p['dialog'] and not p['busy'], timeout=3)
        except AssertionError:
            h.idle()
    raise AssertionError(('Worktree flow never reached', show, flow, h.last.get(WORKTREE)))


def worktree_add_remove(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    begin(h, [root])
    linked = root / 'linked'
    h.command('worktree-show', 'add')
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'add_path' and p['dialog'] and not p['busy'])
    h.command('worktree-answer', 'text:' + str(linked))
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'add_branch' and p['dialog'] and not p['busy'])
    h.command('worktree-answer', 'text:wt-topic')  # new branch at HEAD
    p = h.wait_wf(WORKTREE, lambda p: p['flow'] == 'add_confirm' and p['dialog'] and not p['busy'])
    assert p['add_path'] == str(linked) and p['add_name'] == 'wt-topic' and p['add_new'] is True, p
    writes = p['writes']
    h.command('worktree-accept')
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    h.idle()
    assert linked.is_dir() and (linked / 'same.txt').read_bytes() == b'BASE\n'
    assert h.out(root, 'rev-parse', 'refs/heads/wt-topic') == h.head(root)
    listing = h.out(root, 'worktree', 'list', '--porcelain')
    assert str(linked) in listing, listing

    # Open hands the path to the parent; exercise both message and callback modes.
    p = worktree_flow(h, 'worktrees', 'list_pick')
    index = next(i for i, w in enumerate(p['worktrees']) if w['path'] == str(linked))
    h.command('worktree-answer', str(index))
    p = h.wait_wf(WORKTREE, lambda p: p['opened_path'] == str(linked) and p['open_mode'] == 'message')
    h.command('worktree-open-mode', 'callback')
    worktree_flow(h, 'worktrees', 'list_pick')
    h.command('worktree-answer', str(index))
    p = h.wait_wf(WORKTREE, lambda p: p['open_mode'] == 'callback' and p['open_callback'])
    assert p['opened_path'] == str(linked), p

    # Clean removal.
    worktree_flow(h, 'remove', 'remove_pick')
    p = h.wf(WORKTREE)
    index = next(i for i, w in enumerate(p['worktrees']) if w['path'] == str(linked))
    h.command('worktree-answer', str(index))
    p = h.wait_wf(WORKTREE, lambda p: p['flow'] == 'remove_confirm' and p['dialog'] and not p['busy'])
    assert p['remove_path'] == str(linked) and p['dirty'] == 0, p
    writes = p['writes']
    h.command('worktree-accept')
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'none' and not p['busy'] and p['writes'] == writes + 1)
    assert not linked.exists(), 'Clean worktree was not removed'
    assert str(linked) not in h.out(root, 'worktree', 'list', '--porcelain')
    no_lock(h, root)


def worktree_remove_dirty_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    linked = h.fixtures / 'dirty-linked'
    h.fixture_git(root, 'worktree', 'add', '--detach', str(linked), 'HEAD')
    h.repositories.append(linked)
    h.write(linked / 'same.txt', 'LINKED_DIRTY\n')
    begin(h, [root])
    h.command('worktree-show', 'remove')
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'remove_pick' and p['dialog'] and not p['busy'])
    p = h.wf(WORKTREE)
    index = next(i for i, w in enumerate(p['worktrees']) if w['path'] == str(linked))
    writes = p['writes']
    h.command('worktree-answer', str(index))
    p = h.wait_wf(WORKTREE, lambda p: p['flow'] == 'none' and not p['busy'] and p['dirty'] >= 1)
    assert p['writes'] == writes, 'Dirty worktree removal performed a write'
    assert linked.is_dir() and (linked / 'same.txt').read_bytes() == b'LINKED_DIRTY\n'
    assert str(linked) in h.out(root, 'worktree', 'list', '--porcelain')
    no_lock(h, root)


def worktree_add_path_validation(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    begin(h, [root])
    h.command('worktree-show', 'add')
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'add_path' and p['dialog'] and not p['busy'])
    h.command('worktree-answer', 'text:relative/path')  # NotAbsolute
    p = h.wait_wf(WORKTREE, lambda p: p['flow'] == 'add_path' and p['dialog'] and not p['busy'])
    assert p['writes'] == 0, p
    h.command('worktree-answer', 'text:/etc/coral-outside')  # OutsideRoot
    p = h.wait_wf(WORKTREE, lambda p: p['flow'] == 'add_path' and p['dialog'] and not p['busy'])
    assert p['writes'] == 0, p
    h.command('worktree-reject')
    h.wait_wf(WORKTREE, lambda p: p['flow'] == 'none' and not p['dialog'])
    assert h.out(root, 'worktree', 'list', '--porcelain').count('worktree ') == 1
    no_lock(h, root)


# =============================================================================
# STASH
# =============================================================================

def stash_push(h, name):
    h.command('stash-push')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'push' and not p['busy'])
    h.command('stash-accept', name)
    p = h.wait_wf(STASH, lambda p: not p['busy'] and not p['engaged'] and p['dialog'] is None)
    h.idle()  # push refreshes Source Control asynchronously; wait for repo re-selection
    return p


def stash_push_apply(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'STASHED_CHANGE\n')
    begin(h, [root])
    stash_push(h, 'my work')
    p = h.wait_wf(STASH, lambda p: p['entry_count'] == 1)
    assert (root / 'same.txt').read_bytes() == b'BASE\n', 'Push did not reset the stashed path'
    h.expect(root / 'same.txt', b'BASE\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash push')
    assert 'On main: my work' in h.out(root, 'stash', 'list')
    h.command('stash-select', '0')
    h.command('stash-show')
    p = h.wait_wf(STASH, lambda p: p['diff_kind'] == 'text' and not p['busy'])
    assert '+STASHED_CHANGE' in p['diff'], p
    h.command('stash-apply')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'apply')
    h.command('stash-accept')
    p = h.wait_wf(STASH, lambda p: not p['busy'] and not p['engaged'] and p['entry_count'] == 1)
    assert (root / 'same.txt').read_bytes() == b'STASHED_CHANGE\n', 'Apply did not restore the change'
    h.expect(root / 'same.txt', b'STASHED_CHANGE\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash apply')
    assert 'On main: my work' in h.out(root, 'stash', 'list'), 'Apply must preserve the entry'
    no_lock(h, root)


def stash_pop(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'POPPED\n')
    begin(h, [root])
    stash_push(h, 'pop me')
    h.wait_wf(STASH, lambda p: p['entry_count'] == 1)
    h.expect(root / 'same.txt', b'BASE\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash push')
    h.command('stash-select', '0')
    h.command('stash-pop')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'pop_apply')
    h.command('stash-accept')
    p = h.wait_wf(STASH, lambda p: p['dialog'] == 'pop_drop' and not p['busy'])
    assert (root / 'same.txt').read_bytes() == b'POPPED\n', 'Pop apply did not restore the change'
    h.expect(root / 'same.txt', b'POPPED\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash pop apply')
    h.command('stash-accept')  # separate explicit drop confirmation
    p = h.wait_wf(STASH, lambda p: not p['busy'] and not p['engaged'] and p['entry_count'] == 0)
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash pop drop')
    assert h.out(root, 'stash', 'list') == '', 'Pop did not drop the entry after confirmation'
    no_lock(h, root)


def stash_pop_cancel_drop(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'KEPT\n')
    begin(h, [root])
    stash_push(h, 'keep entry')
    h.wait_wf(STASH, lambda p: p['entry_count'] == 1)
    h.expect(root / 'same.txt', b'BASE\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash push')
    h.command('stash-select', '0')
    h.command('stash-pop')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'pop_apply')
    h.command('stash-accept')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'pop_drop' and not p['busy'])
    h.expect(root / 'same.txt', b'KEPT\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash pop apply')
    h.command('stash-reject')  # cancel the drop -> entry preserved
    p = h.wait_wf(STASH, lambda p: not p['busy'] and not p['engaged'] and p['entry_count'] == 1)
    assert (root / 'same.txt').read_bytes() == b'KEPT\n'
    assert 'On main: keep entry' in h.out(root, 'stash', 'list'), 'Cancelled pop drop lost the entry'
    no_lock(h, root)


def stash_drop(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.write(root / 'same.txt', 'FIRST\n')
    begin(h, [root])
    stash_push(h, 'first')
    h.wait_wf(STASH, lambda p: p['entry_count'] == 1)
    h.expect(root / 'same.txt', b'BASE\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash push first')
    h.write(root / 'same.txt', 'SECOND\n')
    stash_push(h, 'second')
    h.wait_wf(STASH, lambda p: p['entry_count'] == 2)
    h.expect(root / 'same.txt', b'BASE\n')
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash push second')
    h.command('stash-select', '1')  # stash@{1} == first
    h.command('stash-drop')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'drop')
    h.command('stash-accept')
    p = h.wait_wf(STASH, lambda p: not p['busy'] and not p['engaged'] and p['entry_count'] == 1)
    h.reindex(root, {('same.txt', 0): entry(b'BASE\n')}, 'reviewed stash drop')
    listing = h.out(root, 'stash', 'list')
    assert 'second' in listing and 'first' not in listing, listing
    assert (root / 'same.txt').read_bytes() == b'BASE\n', 'Drop changed worktree bytes'
    no_lock(h, root)


def stash_push_dirty_buffer_refused(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    begin(h, [root], active=root / 'same.txt')
    h.replace_keyboard('UNSAVED_BUFFER\n')
    assert h.document(root / 'same.txt')['dirty']
    h.command('stash-push')
    h.wait_wf(STASH, lambda p: p['dialog'] == 'push' and not p['busy'])
    h.command('stash-accept', 'must refuse')
    p = h.wait_wf(STASH, lambda p: not p['busy'] and not p['engaged'] and p['entry_count'] == 0)
    assert 'unsaved' in p['status'].lower(), p
    assert h.out(root, 'stash', 'list') == '', 'Push ran despite unsaved buffers'
    assert (root / 'same.txt').read_bytes() == b'BASE\n', 'Unsaved buffer was written to disk'
    # Discard the unsaved buffer through the real close dialog so teardown is clean.
    h.command('stash-close')
    h.close_git()
    h.select(h.target, focus=True)
    h.action('win.close')
    wait_for(lambda: h.state()['dialog'])
    h.command('respond', response=1)
    wait_for(lambda: h.document(root / 'same.txt') is None)


# =============================================================================
# CONFLICTS
# =============================================================================

def conflict_fixture(h):
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'checkout', '-b', 'other')
    h.write(root / 'same.txt', 'OTHER\n')
    commit_fixture(h, root, 'Other side')
    h.fixture_git(root, 'checkout', 'main')
    h.write(root / 'same.txt', 'MAIN\n')
    commit_fixture(h, root, 'Main side')
    h.fixture_git(root, 'merge', '--no-edit', '--no-gpg-sign', 'other', expected=1)
    h.expect(root / 'same.txt', (root / 'same.txt').read_bytes())
    return root


def conflict_ready(h):
    return h.wait_wf(CONFLICT, lambda p: not p['busy'] and p['conflict_count'] == 1
                     and p['operation'] == 'merge' and p['ours_bytes'] is not None and p['theirs_bytes'] is not None)


def conflict_resolve(h, choice):
    root = conflict_fixture(h)
    pre_merge = h.out(root, 'rev-parse', 'HEAD')
    other = h.out(root, 'rev-parse', 'other')
    begin(h, [root])
    h.command('conflict-show')
    p = conflict_ready(h)
    assert p['conflicts'][0]['path'] == 'same.txt' and p['conflicts'][0]['kind'] == 'both_modified', p
    chosen = {'current': b'MAIN\n', 'incoming': b'OTHER\n', 'both': b'MAIN\nOTHER\n'}[choice]
    h.command('conflict-resolve-' + choice)
    h.wait_wf(CONFLICT, lambda p: p['resolve_dialog'] and not p['busy'])
    h.command('conflict-accept')  # write reviewed bytes + git add
    p = h.wait_wf(CONFLICT, lambda p: not p['busy'] and p['writes_committed'] == 1 and p['conflict_count'] == 0)
    assert (root / 'same.txt').read_bytes() == chosen, ('Resolution bytes', choice, chosen)
    h.expect(root / 'same.txt', chosen)
    h.reindex(root, {('same.txt', 0): entry(chosen)}, 'reviewed conflict resolution')
    h.idle()  # resolution refreshes Source Control asynchronously before continue
    staged = entries(h, root)
    assert staged[('same.txt', 0)] == entry(chosen), ('Resolved file not staged', staged)
    assert all(stage == 0 for (_, stage) in staged), 'Unmerged stages remain after resolution'
    # Continue the detected merge operation.
    h.command('conflict-continue')
    h.wait_wf(CONFLICT, lambda p: p['confirm'] == 'continue_op')
    h.command('conflict-accept')
    h.wait_wf(CONFLICT, lambda p: not p['busy'] and p['operation'] == 'none' and p['confirm'] is None)
    h.idle()
    h.reindex(root, {('same.txt', 0): entry(chosen)}, 'reviewed merge continue')
    assert h.out(root, 'rev-parse', 'HEAD^2') == other, 'Merge continue did not create a merge commit'
    assert h.out(root, 'rev-parse', 'HEAD^1') == pre_merge
    assert h.blob(root, 'same.txt') == chosen
    assert h.fixture_git(root, 'rev-parse', '--verify', 'MERGE_HEAD', expected=128) == b''
    no_lock(h, root)


def conflict_abort(h):
    root = conflict_fixture(h)
    pre_merge = h.out(root, 'rev-parse', 'HEAD')
    begin(h, [root])
    h.command('conflict-show')
    conflict_ready(h)
    h.command('conflict-abort')
    h.wait_wf(CONFLICT, lambda p: p['confirm'] == 'abort_op')
    h.command('conflict-accept')
    h.wait_wf(CONFLICT, lambda p: not p['busy'] and p['operation'] == 'none' and p['conflict_count'] == 0)
    h.idle()
    assert h.head(root) == pre_merge, 'Abort moved HEAD'
    assert (root / 'same.txt').read_bytes() == b'MAIN\n', 'Abort did not restore the worktree'
    h.expect(root / 'same.txt', b'MAIN\n')
    h.reindex(root, {('same.txt', 0): entry(b'MAIN\n')}, 'reviewed merge abort')
    assert entries(h, root) == {('same.txt', 0): entry(b'MAIN\n')}, 'Abort left a dirty index'
    assert h.fixture_git(root, 'rev-parse', '--verify', 'MERGE_HEAD', expected=128) == b''
    no_lock(h, root)


def conflict_resolve_reject(h):
    root = conflict_fixture(h)
    conflicted = (root / 'same.txt').read_bytes()
    begin(h, [root])
    h.command('conflict-show')
    conflict_ready(h)
    before = entries(h, root)
    h.command('conflict-resolve-incoming')
    h.wait_wf(CONFLICT, lambda p: p['resolve_dialog'])
    h.command('conflict-reject')
    p = h.wait_wf(CONFLICT, lambda p: not p['resolve_dialog'] and not p['busy'])
    assert p['writes_committed'] == 0, p
    assert (root / 'same.txt').read_bytes() == conflicted, 'Rejected resolution wrote the worktree'
    assert entries(h, root) == before, 'Rejected resolution changed the index'
    no_lock(h, root)


# =============================================================================
# REMOTES (local bare; no network)
# =============================================================================

def remote_setup(h):
    bare = h.bare()
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'remote', 'add', 'origin', str(bare))
    begin(h, [root])
    h.command('git-remote-refresh')
    p = h.wait_wf(REMOTE, lambda p: not p['busy'] and p['pending'] == 'none' and len(p['remotes']) >= 1)
    assert p['remotes'][0]['name'] == 'origin' and p['remotes'][0]['fetch_url'] == str(bare), p
    assert p['branch'] == 'main', p
    return root, bare


def remote_idle(h):
    return h.wait_wf(REMOTE, lambda p: not p['busy'] and p['pending'] == 'none')


def remote_request(h, action):
    """Request a network operation and wait for the real credential disclosure."""
    h.command(action)
    return h.wait_wf(REMOTE, lambda p: p['network_disclosure'] and not p['busy'] and p['pending'] == 'none')


def remote_accept(h):
    h.command('git-remote-accept')
    return remote_idle(h)


def remote_push_fetch(h):
    root, bare = remote_setup(h)
    head = h.head(root)
    h.command('git-remote-upstream', '1')
    assert h.wf(REMOTE)['push_set_upstream'] is True
    p = remote_request(h, 'git-remote-push')
    launches = p['launches']
    p = remote_accept(h)
    p = h.wait_wf(REMOTE, lambda p: not p['busy'] and p['output_kind'] == 'text')
    assert p['launches'] == launches + 1 and 'Push complete' in p['status'], p
    assert h.out(bare, 'rev-parse', 'refs/heads/main') == head, 'Push did not publish main to the bare remote'
    assert h.out(root, 'config', 'branch.main.remote') == 'origin', 'Push -u did not set the upstream remote'
    assert h.out(root, 'config', 'branch.main.merge') == 'refs/heads/main', 'Push -u did not set the upstream merge ref'
    # Refresh so the controller model picks up the newly written upstream config.
    h.command('git-remote-refresh')
    p = h.wait_wf(REMOTE, lambda p: not p['busy'] and p['pending'] == 'none' and p['upstream_remote'] == 'origin')
    assert p['upstream_branch'] == 'main', p

    # A second disposable clone advances the bare remote; fetch must download it.
    publisher = h.fixtures / 'publisher'
    h.file_git(h.fixtures, 'clone', str(bare), 'publisher')
    h.identity(publisher)
    h.write(publisher / 'published.txt', 'PUBLISHED\n')
    h.fixture_git(publisher, 'add', '--', 'published.txt')
    h.fixture_git(publisher, 'commit', '--no-gpg-sign', '-m', 'Publisher commit')
    pub_head = h.head(publisher)
    h.file_git(publisher, 'push', 'origin', 'main')
    assert h.out(bare, 'rev-parse', 'refs/heads/main') == pub_head
    remote_request(h, 'git-remote-fetch')
    p = remote_accept(h)
    p = h.wait_wf(REMOTE, lambda p: not p['busy'] and p['output_kind'] == 'text')
    assert 'Fetch complete' in p['status'], p
    assert h.out(root, 'rev-parse', 'refs/remotes/origin/main') == pub_head, 'Fetch did not advance the tracking ref'
    # Fetch is read-only for the worktree and HEAD.
    assert h.head(root) == head and (root / 'same.txt').read_bytes() == b'BASE\n'
    assert not (root / 'published.txt').exists(), 'Fetch wrote the worktree'
    no_lock(h, root)
    h.evidence.setdefault('workflow_outcomes', []).append(dict(case=h.name, probe=p))


def remote_force_with_lease(h):
    bare = h.bare()
    root = h.repo(files={'same.txt': 'BASE\n'})
    h.fixture_git(root, 'remote', 'add', 'origin', str(bare))
    head0 = h.head(root)
    h.file_git(root, 'push', 'origin', 'main')            # bare main = head0
    # Rewrite local history so a normal push would be non-fast-forward.
    h.fixture_git(root, 'commit', '--amend', '--no-gpg-sign', '-m', 'Rewritten history')
    head1 = h.head(root)
    assert head1 != head0
    begin(h, [root])
    h.command('git-remote-refresh')
    h.wait_wf(REMOTE, lambda p: not p['busy'] and p['pending'] == 'none' and len(p['remotes']) >= 1)
    # Establish the lease: fetch records refs/remotes/origin/main = head0.
    remote_request(h, 'git-remote-fetch')
    remote_accept(h)
    h.wait_wf(REMOTE, lambda p: not p['busy'] and p['output_kind'] == 'text')
    assert h.out(root, 'rev-parse', 'refs/remotes/origin/main') == head0

    # The distinct force confirmation can be declined without any push.
    p = remote_request(h, 'git-remote-force-push')
    launches = p['launches']
    h.command('git-remote-accept')  # network credential disclosure
    p = h.wait_wf(REMOTE, lambda p: p['force_disclosure'] and not p['busy'])
    assert p['launches'] == launches, 'Force confirmation launched Git before consent'
    h.command('git-remote-force-reject')
    p = h.wait_wf(REMOTE, lambda p: not p['force_disclosure'] and not p['network_disclosure'] and not p['busy'])
    assert p['launches'] == launches and p['pending'] == 'none', p
    assert h.out(bare, 'rev-parse', 'refs/heads/main') == head0, 'Declined force push changed the remote'

    # Someone else advances the remote; the stale lease must refuse the force push.
    publisher = h.fixtures / 'publisher'
    h.file_git(h.fixtures, 'clone', str(bare), 'publisher')
    h.identity(publisher)
    h.write(publisher / 'other.txt', 'OTHER\n')
    h.fixture_git(publisher, 'add', '--', 'other.txt')
    h.fixture_git(publisher, 'commit', '--no-gpg-sign', '-m', 'Other publisher')
    h.file_git(publisher, 'push', 'origin', 'main')
    head2 = h.head(publisher)
    assert h.out(bare, 'rev-parse', 'refs/heads/main') == head2
    remote_request(h, 'git-remote-force-push')
    h.command('git-remote-accept')
    h.wait_wf(REMOTE, lambda p: p['force_disclosure'] and not p['busy'])
    h.command('git-remote-force-accept')
    p = h.wait_wf(REMOTE, lambda p: not p['busy'] and p['pending'] == 'none' and p['output_kind'] == 'error')
    assert 'Push failed' in p['status'], p
    assert h.out(bare, 'rev-parse', 'refs/heads/main') == head2, 'Stale-lease force push overwrote the remote'
    assert h.head(root) == head1

    # Fetching refreshes the lease; the force push now succeeds and discards head2.
    remote_request(h, 'git-remote-fetch')
    remote_accept(h)
    h.wait_wf(REMOTE, lambda p: not p['busy'] and p['output_kind'] == 'text')
    assert h.out(root, 'rev-parse', 'refs/remotes/origin/main') == head2
    remote_request(h, 'git-remote-force-push')
    h.command('git-remote-accept')
    h.wait_wf(REMOTE, lambda p: p['force_disclosure'] and not p['busy'])
    h.command('git-remote-force-accept')
    p = h.wait_wf(REMOTE, lambda p: not p['busy'] and p['pending'] == 'none' and p['output_kind'] == 'text')
    assert 'Push complete' in p['status'], p
    assert h.out(bare, 'rev-parse', 'refs/heads/main') == head1, 'Fresh-lease force push did not update the remote'
    assert h.head(root) == head1 and (root / 'same.txt').read_bytes() == b'BASE\n'
    no_lock(h, root)
    h.evidence.setdefault('workflow_outcomes', []).append(dict(case=h.name, probe=p))


# =============================================================================
# HISTORY / BLAME / PERMALINK (read-only; external link only after consent)
# =============================================================================

def history_fixture(h):
    root = h.repo(files={'same.txt': 'LINE1\nLINE2\nLINE3\n'})
    h.write(root / 'same.txt', 'LINE1\nLINE2_CHANGED\nLINE3\n')
    commit_fixture(h, root, 'Change line two')
    return root


def history_log_diff(h):
    root = history_fixture(h)
    head = h.head(root)
    first = h.out(root, 'rev-parse', 'HEAD~1')
    begin(h, [root], active=root / 'same.txt')
    h.command('git-history-show')
    p = h.wait_wf(HISTORY, lambda p: not p['busy'] and p['pending'] == 'none' and len(p['log']) >= 2)
    assert p['file'] == 'same.txt', p
    assert p['selected_commit'] == 0 and p['log'][0]['oid'] == head, p
    assert p['log'][1]['oid'] == first and p['log'][0]['subject'] == 'Change line two', p
    # Commit diff for the selected (newest) commit.
    h.command('git-history-diff')
    p = h.wait_wf(HISTORY, lambda p: not p['busy'] and p['pending'] == 'none' and p['output_kind'] == 'text')
    assert '-LINE2\n' in p['output'] and '+LINE2_CHANGED\n' in p['output'], p
    # Select the older commit; its diff introduced the original lines.
    h.command('git-history-select', '1')
    assert h.wf(HISTORY)['selected_commit'] == 1
    h.command('git-history-diff')
    p = h.wait_wf(HISTORY, lambda p: not p['busy'] and p['pending'] == 'none' and p['output_kind'] == 'text')
    assert '+LINE1\n' in p['output'] and '+LINE2\n' in p['output'], p
    assert h.head(root) == head, 'History inspection moved HEAD'
    no_lock(h, root)
    h.evidence.setdefault('workflow_outcomes', []).append(dict(case=h.name, probe=p))


def history_blame(h):
    root = history_fixture(h)
    head = h.head(root)
    first = h.out(root, 'rev-parse', 'HEAD~1')
    begin(h, [root], active=root / 'same.txt')
    h.command('git-history-show')
    h.wait_wf(HISTORY, lambda p: not p['busy'] and len(p['log']) >= 2)
    h.command('git-history-blame')
    p = h.wait_wf(HISTORY, lambda p: not p['busy'] and p['pending'] == 'none' and p['blame_lines'] == 3)
    assert p['output_kind'] == 'blame' and p['selected_line'] == 0, p
    assert 'LINE2_CHANGED' in p['output'] and head[:12] in p['output'], p
    # Blame the older commit: line two still has its original content.
    h.command('git-history-select', '1')
    h.command('git-history-blame')
    p = h.wait_wf(HISTORY, lambda p: not p['busy'] and p['pending'] == 'none' and p['blame_lines'] == 3)
    assert 'LINE2_CHANGED' not in p['output'] and first[:12] in p['output'], p
    # Selecting a line feeds the permalink line number.
    h.command('git-history-line', '2')
    assert h.wf(HISTORY)['selected_line'] == 2
    no_lock(h, root)
    h.evidence.setdefault('workflow_outcomes', []).append(dict(case=h.name, probe=p))


def history_permalink(h):
    root = history_fixture(h)
    head = h.head(root)
    # A https web remote is configured as data only; nothing is fetched or opened.
    url = 'https://github.com/coral-fixture/disposable.git'
    h.fixture_git(root, 'remote', 'add', 'origin', url)
    begin(h, [root], active=root / 'same.txt')
    h.command('git-history-show')
    h.wait_wf(HISTORY, lambda p: not p['busy'] and len(p['log']) >= 1)
    h.command('git-history-permalink')
    p = h.wait_wf(HISTORY, lambda p: p['external_disclosure'] and not p['busy'] and p['permalink'])
    assert p['remote_url'] == url, p
    expected = 'https://github.com/coral-fixture/disposable/blob/%s/same.txt#L1' % head
    assert p['permalink'] == expected, p
    # Declining the external-link confirmation must not launch anything.
    before = descendants(h.app.proc.pid)
    h.command('git-history-external-reject')
    p = h.wait_wf(HISTORY, lambda p: not p['external_disclosure'] and not p['busy'])
    assert p['permalink'] == expected, p
    time.sleep(.3)
    assert descendants(h.app.proc.pid) <= before, 'Declined permalink launched a process'
    # A blame line selection changes the permalink fragment (0-based index 1 -> L2).
    h.command('git-history-blame')
    h.wait_wf(HISTORY, lambda p: not p['busy'] and p['blame_lines'] == 3)
    h.command('git-history-line', '1')
    h.command('git-history-permalink')
    p = h.wait_wf(HISTORY, lambda p: p['external_disclosure'] and p['permalink'])
    assert p['permalink'].endswith('/same.txt#L2'), p
    h.command('git-history-external-reject')
    h.wait_wf(HISTORY, lambda p: not p['external_disclosure'])
    no_lock(h, root)
    h.evidence.setdefault('workflow_outcomes', []).append(dict(case=h.name, probe=p))


def history_permalink_local_refused(h):
    root = history_fixture(h)
    bare = h.bare()
    h.fixture_git(root, 'remote', 'add', 'origin', str(bare))
    begin(h, [root], active=root / 'same.txt')
    h.command('git-history-show')
    h.wait_wf(HISTORY, lambda p: not p['busy'] and len(p['log']) >= 1)
    h.command('git-history-permalink')
    p = h.wait_wf(HISTORY, lambda p: not p['busy'] and p['pending'] == 'none' and 'Permalink unavailable' in p['status'])
    assert p['permalink'] is None and not p['external_disclosure'], p
    assert p['remote_url'] == str(bare), p
    no_lock(h, root)


# =============================================================================
# HUNK ADAPTER
# =============================================================================
# git.Controller hunk selection is wired by the parent. The backend
# (index_transaction.zig stage_hunk/unstage_hunk + hunk.zig HunkRef{ordinal,digest})
# is present; these are the reconciled surface names (probe fields + GActions),
# isolated here so a schema change is a one-place edit.
HUNK_COUNT = 'hunk_count'          # git probe: parsed hunks in the current diff
HUNK_SELECTED = 'selected_hunk'    # git probe: 0-based selected hunk ordinal (or null)
HUNK_NEXT = 'next-hunk'            # win.git-next-hunk
HUNK_PREVIOUS = 'previous-hunk'    # win.git-previous-hunk
HUNK_STAGE = 'stage-hunk'          # win.git-stage-hunk
HUNK_UNSTAGE = 'unstage-hunk'      # win.git-unstage-hunk


def hunk_diff(h, path, staged=False):
    """Select a file and load one diff side; return the git probe with hunks."""
    h.select_file(path)
    h.invoke('staged-diff' if staged else 'diff')
    return h.wait_git(lambda p: p['diff_kind'] == 'text' and p[HUNK_COUNT] > 0)


def hunk_select(h, index):
    p = h.git()
    assert 0 <= index < p[HUNK_COUNT], p
    current = p[HUNK_SELECTED] or 0
    while current < index:
        h.invoke(HUNK_NEXT)
        current += 1
    while current > index:
        h.invoke(HUNK_PREVIOUS)
        current -= 1
    p = h.git()
    assert p[HUNK_SELECTED] == index, p
    return p


def hunk_review(h, path, before, after, action):
    """Request a hunk mutation and verify the full captured before/after review."""
    p = h.git()
    assert p[HUNK_SELECTED] is not None and p[HUNK_COUNT] > 0 and p['diff_kind'] == 'text', p
    jobs = mutation_probe(h)['jobs_started']
    h.invoke(action)  # real org.gtk.Actions route used by the native window
    p = h.wait_git(lambda p: p['mutation']['jobs_started'] > jobs or p['mutation']['state'] == 'failed')
    assert p['mutation']['jobs_started'] > jobs, p
    p = h.wait_git(lambda p: p['mutation']['dialog'] or not p['mutation']['busy'])
    m = p['mutation']
    assert m['state'] == 'confirming' and m['dialog'] and m['busy'] and not m['barrier'], p
    # The probe reports the backend Action tag (stage_hunk); the GAction uses a hyphen.
    assert m['action'] == action.replace('-', '_') and m['path'] == path and not m['committed'], m
    assert m['jobs_started'] == m['jobs_reaped'], m
    assert 'ONE HUNK, NOT THE WHOLE FILE' in m['review'], m
    for side, data in (('before', before), ('after', after)):
        assert m[side + '_exists'] is True and m[side + '_mode'] == 0o100644 and m[side + '_bytes'] == len(data), m

    def pane(label, data):
        return '%s · exists: yes · mode: 100644 · %d bytes\nSHA-256: %s\n%s' % (
            label, len(data), sha(data), escaped(data))
    # Stage applies the hunk toward the disk snapshot; unstage toward HEAD.
    after_source = 'DISK' if action == HUNK_STAGE else 'HEAD'
    suffix = '\n\n' + pane('BEFORE — INDEX', before) + '\n\n' + pane('AFTER — INDEX FROM ' + after_source, after)
    assert m['review'].endswith(suffix), (suffix, m['review'])
    h.mutation_preservation.observe_scratch()
    assert h.mutation_preservation.scratch, 'Prepared hunk review must own observed native scratch'
    h.verify_files()  # prepare/review is not authorization to mutate the index
    h.evidence.setdefault('mutation_reviews', []).append(dict(case=h.name, probe=p))
    return p


def hunk_fixture(h):
    base = ''.join('line %02d\n' % i for i in range(1, 21))
    root = h.repo(files={'same.txt': base, 'unrelated.txt': 'UNRELATED_BASE\n'})
    disk = base.replace('line 02\n', 'line 02 CHANGED\n').replace('line 18\n', 'line 18 CHANGED\n')
    h.write(root / 'same.txt', disk)
    return root, base.encode(), disk.encode()


def hunk_stage_preserves_other(h):
    root, base, disk = hunk_fixture(h)
    after0 = base.replace(b'line 02\n', b'line 02 CHANGED\n')
    begin(h, [root])
    Preservation(h)
    p = hunk_diff(h, 'same.txt')
    assert p[HUNK_COUNT] == 2, p
    # Navigate to the second hunk and back to prove the selection controls.
    hunk_select(h, 1)
    hunk_select(h, 0)
    expected = entries(h, root)
    hunk_review(h, 'same.txt', base, after0, HUNK_STAGE)
    expected[('same.txt', 0)] = entry(after0)
    mutation_accept(h, root, expected)
    # Worktree keeps BOTH changes; only hunk 0 reached the index.
    assert (root / 'same.txt').read_bytes() == disk
    assert (root / 'unrelated.txt').read_bytes() == b'UNRELATED_BASE\n'
    # Staged diff shows only hunk 0; unstaged diff shows only the preserved hunk 1.
    p = hunk_diff(h, 'same.txt', staged=True)
    assert p[HUNK_COUNT] == 1 and '+line 02 CHANGED' in p['diff'] and 'line 18' not in p['diff'], p
    p = hunk_diff(h, 'same.txt')
    assert p[HUNK_COUNT] == 1 and '+line 18 CHANGED' in p['diff'] and 'line 02 CHANGED' not in p['diff'], p
    # Unstage hunk 0 again; the index returns to base, worktree still has both.
    hunk_diff(h, 'same.txt', staged=True)
    hunk_select(h, 0)
    expected = entries(h, root)
    hunk_review(h, 'same.txt', after0, base, HUNK_UNSTAGE)
    expected[('same.txt', 0)] = entry(base)
    mutation_accept(h, root, expected)
    assert (root / 'same.txt').read_bytes() == disk
    p = hunk_diff(h, 'same.txt')
    assert p[HUNK_COUNT] == 2, p
    h.verify_files()


def hunk_stage_second_navigation(h):
    root, base, disk = hunk_fixture(h)
    after1 = base.replace(b'line 18\n', b'line 18 CHANGED\n')
    begin(h, [root])
    Preservation(h)
    hunk_diff(h, 'same.txt')
    hunk_select(h, 1)  # the second hunk (line 18)
    expected = entries(h, root)
    hunk_review(h, 'same.txt', base, after1, HUNK_STAGE)
    expected[('same.txt', 0)] = entry(after1)
    mutation_accept(h, root, expected)
    assert (root / 'same.txt').read_bytes() == disk
    # Only hunk 1 staged; hunk 0 remains unstaged.
    p = hunk_diff(h, 'same.txt', staged=True)
    assert p[HUNK_COUNT] == 1 and '+line 18 CHANGED' in p['diff'] and 'line 02' not in p['diff'], p
    p = hunk_diff(h, 'same.txt')
    assert p[HUNK_COUNT] == 1 and '+line 02 CHANGED' in p['diff'] and 'line 18 CHANGED' not in p['diff'], p
    h.verify_files()


# =============================================================================
# CASE TABLE / RUNNER (mirrors tests/git.py)
# =============================================================================

CASES = [
    ('commit-staged-only', commit_staged_only),
    ('commit-uncommit-soft', commit_uncommit_soft),
    ('commit-stage-tracked', commit_stage_tracked),
    ('commit-reject', commit_reject),
    ('commit-empty-refused', commit_empty_refused),
    ('commit-uncommit-initial-refused', commit_uncommit_initial_refused),
    ('commit-uncommit-published-refused', commit_uncommit_published_refused),
    ('refs-create-branch', refs_create_branch),
    ('refs-switch-branch', refs_switch_branch),
    ('refs-switch-dirty-refused', refs_switch_dirty_refused),
    ('refs-delete-merged', refs_delete_merged),
    ('refs-delete-unmerged-force', refs_delete_unmerged_force),
    ('refs-delete-dirty-refused', refs_delete_dirty_refused),
    ('refs-create-tag', refs_create_tag),
    ('refs-invalid-name', refs_invalid_name),
    ('worktree-add-remove', worktree_add_remove),
    ('worktree-remove-dirty-refused', worktree_remove_dirty_refused),
    ('worktree-add-path-validation', worktree_add_path_validation),
    ('stash-push-apply', stash_push_apply),
    ('stash-pop', stash_pop),
    ('stash-pop-cancel-drop', stash_pop_cancel_drop),
    ('stash-drop', stash_drop),
    ('stash-push-dirty-buffer-refused', stash_push_dirty_buffer_refused),
    *[('conflict-resolve-' + choice, functools.partial(conflict_resolve, choice=choice))
      for choice in ('current', 'incoming', 'both')],
    ('conflict-abort', conflict_abort),
    ('conflict-resolve-reject', conflict_resolve_reject),
    ('remote-push-fetch', remote_push_fetch),
    ('remote-force-with-lease', remote_force_with_lease),
    ('history-log-diff', history_log_diff),
    ('history-blame', history_blame),
    ('history-permalink', history_permalink),
    ('history-permalink-local-refused', history_permalink_local_refused),
    ('hunk-stage-preserves-other', hunk_stage_preserves_other),
    ('hunk-stage-second-navigation', hunk_stage_second_navigation),
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
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-git-workflows')
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
                                 'Remotes are local bare paths over the file protocol only; no network is used.',
                                 'External permalinks are constructed and declined; no browser is launched.'])
    began = time.monotonic()
    save(report, evidence)

    def expired(_signum, _frame):
        raise CaseTimeout('Native workflow case/suite runtime budget exceeded')

    previous = signal.signal(signal.SIGALRM, expired)
    try:
        binary = args.binary.resolve()
        data = binary.read_bytes()
        evidence['binary_sha256'] = digest(data)
        evidence['source_sha256'] = {str(path.relative_to(PROJECT)): digest(path.read_bytes())
                                     for path in (Path(__file__).resolve(), PROJECT / 'tests/git.py',
                                                  PROJECT / 'tests/git_mutations.py',
                                                  *[PROJECT / 'src/git' / name for name in (
                                                      'commit_controller.zig', 'refs_controller.zig',
                                                      'worktree_controller.zig', 'stash_controller.zig',
                                                      'conflict_controller.zig', 'remote_controller.zig',
                                                      'history_controller.zig', 'controller.zig',
                                                      'mutation_controller.zig', 'index_transaction.zig', 'hunk.zig')])}
        missing = [marker.decode() for marker in REQUIRED_MARKERS if marker not in data]
        assert not missing, ('Stale binary refused — missing integrated M4 probe markers', missing)
        del data
        signal.alarm(45)
        with PrivateSession(run_output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            stage_styles(session, evidence)
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
                    h = WorkflowHarness.__new__(WorkflowHarness)
                    h.__init__(session, binary, run_output, evidence, name, min(start + 75, began + 600))
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    resets = sum(item['case'] == name for item in evidence.get('index_baseline_resets', []))
                    record.update(status='passed', indexes_verified=len(h.indexes), index_baseline_resets=resets,
                                  index_expectation='explicit verified workflow baseline' if resets else 'original bytes/mtime',
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
                    # Only kill exact observed descendants; forced cleanup is
                    # failure evidence, never a passing native reaping assertion.
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
