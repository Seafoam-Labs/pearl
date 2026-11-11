#!/usr/bin/env python3
"""M4 inspection and reviewed index mutation acceptance, in private Wayland/D-Bus/HOME/XDG.

  python3 -B tests/git.py --binary /path/to/coral-test --case diff-sides

No host repository is staged or committed. Fixture Git uses an explicit clean
process environment, disabled hooks/signing, and only disposable session paths.
--case accepts exact names or prefix groups, repeatable; subsets are reported as
partial. Logs and failure evidence survive disposal of the fixture repositories.
Cancellation cases deliberately run a bounded, disposable clean filter: local
filters remain executable after disclosure, unlike external diff/textconv and
fsmonitor. This suite tests that boundary, not an OS sandbox.
"""
import argparse
import functools
import hashlib
import json
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path
from typing import Any

from search import PEARL, PROJECT
from windows import WindowHarness, stage_styles

# search installs the shared scripts/integration helper paths at runtime.
from pearl_session import PrivateSession, fixture_prefix, wait_for  # pyright: ignore[reportMissingImports]


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
        return Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


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


class GitHarness(WindowHarness):
    isolated_app_cwd = True

    def __init__(self, *args):
        self.indexes, self.processes, self.absent = {}, {}, set()
        self.repositories = []
        super().__init__(*args)
        self.git_env = dict(PATH='/usr/bin:/bin', HOME=self.session.env['HOME'],
                            XDG_CONFIG_HOME=self.session.env['XDG_CONFIG_HOME'],
                            LC_ALL='C', LANG='C', TZ='UTC', GIT_EDITOR='true',
                            GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_SYSTEM='/dev/null',
                            GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0',
                            GIT_ASKPASS='/bin/false', SSH_ASKPASS='/bin/false',
                            GIT_ALLOW_PROTOCOL='', GIT_NO_LAZY_FETCH='1',
                            GIT_AUTHOR_NAME='Coral disposable fixture',
                            GIT_AUTHOR_EMAIL='fixture@example.invalid',
                            GIT_COMMITTER_NAME='Coral disposable fixture',
                            GIT_COMMITTER_EMAIL='fixture@example.invalid')

    def fixture_git(self, root, *args, expected=0, input=None):
        # Guard every invocation, including init/commit/worktree destinations.
        root = root.resolve()
        assert root.is_relative_to(self.fixtures.resolve()), root
        assert self.fixtures.resolve().is_relative_to(self.session.base.resolve())
        argv = ['/usr/bin/git', '--no-pager', '--no-optional-locks', '--literal-pathspecs',
                '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false',
                '-c', 'tag.gpgSign=false', '-c', 'core.fsmonitor=false',
                '-c', 'core.untrackedCache=false', '-c', 'core.attributesFile=/dev/null',
                '-c', 'credential.helper=', '-c', 'protocol.allow=never', *map(str, args)]
        result = subprocess.run(argv, cwd=root, env=self.git_env,
                                **({'stdin': subprocess.DEVNULL} if input is None else {'input': input}),
                                capture_output=True, timeout=10, check=False)
        assert result.returncode == expected, (argv, result.returncode, result.stdout, result.stderr)
        self.evidence.setdefault('fixture_git', []).append(
            dict(case=self.name, cwd=str(root), args=list(map(str, args)), exit=result.returncode))
        return result.stdout

    def repo(self, name='repo', files=None, commit=True):
        root = self.fixtures / name
        root.mkdir(parents=True)
        self.fixture_git(root, 'init', '--initial-branch=main', '--template=')
        self.repositories.append(root)
        for path, text in (files if files is not None else {'same.txt': 'BASE\n'}).items():
            self.write(root / path, text)
        if commit:
            self.commit(root)
        return root

    def commit(self, root):
        self.fixture_git(root, 'add', '--all', '--', '.')
        self.fixture_git(root, 'commit', '--no-gpg-sign', '-m', 'Disposable acceptance fixture')

    def watch_indexes(self):
        for root in self.repositories:
            raw = self.fixture_git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index')
            assert raw.endswith(b'\n'), raw
            path = Path(os.fsdecode(raw[:-1]))  # preserve newline-bearing paths
            assert path.resolve().is_relative_to(self.fixtures.resolve()), path
            self.indexes[path] = (path.read_bytes(), path.stat().st_mtime_ns) if path.exists() else None

    def verify_files(self):
        super().verify_files()
        for path in self.absent:
            assert not path.exists(), ('Deleted fixture recreated', path)
        for path, before in self.indexes.items():
            after = (path.read_bytes(), path.stat().st_mtime_ns) if path.exists() else None
            assert after == before, ('Git modified index bytes/mtime', path)
            assert not path.with_name(path.name + '.lock').exists(), path
        if hasattr(self, 'mutation_preservation'):
            self.mutation_preservation.verify(retired=not self.git()['mutation']['busy']
                                              if self.app.proc.poll() is None else True)

    def remove(self, path):
        path.unlink()
        self.expected.pop(path, None)
        self.absent.add(path)

    def workspace_roots(self, roots):
        manifest = self.write(self.fixtures / 'fixture.coral-workspace', json.dumps(
            {'version': 1, 'roots': [{'path': str(root)} for root in roots]}))
        self.open_workspace(manifest)
        self.restricted(self.policy_idle())

    def trust(self):
        self.command('policy-trust-confirm')
        p = self.probe('policy')
        assert p['dialog'] and p['confirmation'], p
        self.command('respond', response=1)
        self.trusted(self.policy_idle())

    def git(self):
        p = self.probe('git')
        assert p['window'] == self.target, p
        assert p['visible_rows'] == len(p['entries']) <= 128, p
        assert p['entry_count'] <= 10000 and len(p['repositories']) <= 8, p
        return p

    def wait_git(self, predicate, timeout=18):
        def ready():
            p = self.git()
            return p if predicate(p) else None
        try:
            return wait_for(ready, timeout)
        except TimeoutError as exc:
            raise AssertionError(('Git deadline', self.last.get('git'))) from exc

    def idle(self):
        return self.wait_git(lambda p: not p['busy'] and p['pending'] == 'none')

    def invoke(self, name):
        self.action('win.git-' + name)

    def disclosure(self):
        before = self.git()['launches']
        self.invoke('status')
        p = self.wait_git(lambda p: p['disclosure'])
        assert not p['approved'] and not p['visible'] and p['launches'] == before, p
        return p

    def start(self, roots, active=None):
        self.watch_indexes()
        self.workspace_roots(roots)
        if active is not None:
            self.open_document(active)
        self.trust()
        self.disclosure()
        self.command('git-accept')
        p = self.idle()
        assert p['approved'] and p['visible'] and p['repositories'], p
        assert p['head'] is not None, p
        return p

    def refresh(self):
        before = self.git()['launches']
        self.invoke('refresh')
        p = self.idle()
        assert p['launches'] > before and p['head'] is not None, p
        return p

    def entries(self, p=None):
        p = p or self.idle()
        assert p['entry_count'] == len(p['entries']), ('Use paging for this snapshot', p)
        return {e['path']: e for e in p['entries']}

    def select_file(self, path, alias=False):
        p = self.idle()
        index = next(i for i, e in enumerate(p['entries']) if e['path'] == path) + 128 * p['page']
        self.command('git-select' if alias else 'git-select-file', 'file:%d' % index if alias else index)
        assert self.git()['selected_file'] == index

    def select_repo(self, root, alias=False):
        p = self.idle()
        index = next(i for i, r in enumerate(p['repositories']) if r['path'] == str(root))
        self.command('git-select' if alias else 'git-select-repo', 'repo:%d' % index if alias else index)
        p = self.idle()
        assert p['selected_repository'] == index and p['head'] is not None, p
        return p

    def diff(self, path, staged=False, kind='text', alias=False):
        self.select_file(path, alias)
        self.invoke('staged-diff' if staged else 'diff')
        p = self.idle()
        assert p['diff_kind'] == kind and p['staged'] == staged, p
        self.evidence.setdefault('diffs', []).append(dict(case=self.name, path=path, probe=p))
        return p

    def unchanged(self, before, seconds=.8):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            p = self.git()
            for key in ('launches', 'entry_count', 'entries', 'head', 'branch'):
                assert p[key] == before[key], ('Unexpected automatic Git work', key, before, p)
            assert not p['busy'] and p['pending'] == 'none', p
            time.sleep(.08)

    def remember_processes(self):
        for pid in descendants(self.app.proc.pid):
            stamp = process_stamp(pid)
            if stamp is not None:
                self.processes[pid] = stamp
        assert self.processes, 'No real Git/filter process observed'
        self.evidence.setdefault('processes', []).append(dict(case=self.name, stamps=self.processes.copy()))

    def reaped(self):
        wait_for(lambda: all(process_stamp(pid) != stamp for pid, stamp in self.processes.items()), 6)

    def close_git(self):
        self.command('git-close')
        p = self.idle()
        assert not p['visible'] and not p['disclosure'] and not p['approved'], p
        assert not p['repositories'] and not p['entries'] and p['diff_kind'] == 'none', p
        self.reaped()
        self.drained(1)
        return p

    def stop(self):
        if self.app is not None and self.app.proc.poll() is None:
            self.close_git()
        super().stop()
        self.reaped()


def restricted(h):
    root = h.repo()
    h.write(root / 'same.txt', 'DISK\n')
    h.watch_indexes()
    h.workspace_roots([root])
    before = h.git()
    for action in ('status', 'refresh', 'diff', 'staged-diff'):
        h.invoke(action)
        p = h.idle()
        assert not p['disclosure'] and not p['approved'] and not p['visible'], p
        assert p['launches'] == 0 and not p['repositories'], p
    h.command('git-accept')  # answering no disclosure cannot manufacture trust
    h.unchanged(before)
    h.restricted(h.policy_idle())


def decline(h):
    root = h.repo()
    h.watch_indexes()
    h.workspace_roots([root])
    h.trust()
    h.unchanged(h.git())  # trust itself must never launch Git
    h.disclosure()
    h.command('git-reject')
    p = h.idle()
    assert not p['approved'] and not p['visible'] and not p['disclosure'] and p['launches'] == 0, p
    h.write(root / 'same.txt', 'CHANGED AFTER DECLINE\n')
    h.unchanged(p)
    h.disclosure()
    h.command('git-accept')
    assert h.idle()['launches'] > 0


def diff_sides(h):
    root = h.repo(files={'same.txt': 'BASE\n', '.gitattributes': '*.txt diff=sentinel\n'})
    for name, config in (('external-diff', 'diff.external'), ('textconv', 'diff.sentinel.textconv'),
                         ('fsmonitor', 'core.fsmonitor')):
        marker = h.fixtures / (name + '-EXECUTED')
        script = h.write(h.fixtures / (name + '.sh'), '#!/bin/sh\nprintf executed > ' + shlex.quote(str(marker)) + '\n')
        script.chmod(0o700)
        h.sentinels.append(marker)
        h.fixture_git(root, 'config', config, str(script))
    h.write(root / 'same.txt', 'INDEX_ONLY\n')
    h.fixture_git(root, 'add', '--', 'same.txt')
    h.write(root / 'same.txt', 'DISK_ONLY\n')
    p = h.start([root])
    entry = h.entries(p)['same.txt']
    assert (entry['index'], entry['worktree']) == (ord('M'), ord('M')), entry
    p = h.diff('same.txt')
    assert '-INDEX_ONLY\n' in p['diff'] and '+DISK_ONLY\n' in p['diff'] and 'BASE' not in p['diff'], p
    p = h.diff('same.txt', staged=True, alias=True)
    assert '-BASE\n' in p['diff'] and '+INDEX_ONLY\n' in p['diff'] and 'DISK_ONLY' not in p['diff'], p
    h.refresh()
    h.verify_files()


def status_kinds(h):
    root = h.repo(files={'deleted.txt': 'DELETE_ME\n', 'old.txt': 'RENAMED_CONTENT\n', 'binary.bin': b'a\0b'})
    h.remove(root / 'deleted.txt')
    h.fixture_git(root, 'mv', '--', 'old.txt', 'new.txt')
    h.expected.pop(root / 'old.txt')
    h.absent.add(root / 'old.txt')
    h.expected[root / 'new.txt'] = digest((root / 'new.txt').read_bytes())
    h.write(root / 'binary.bin', b'a\0CHANGED')
    h.write(root / 'untracked.txt', 'NEVER FABRICATE THIS DIFF\n')
    entries = h.entries(h.start([root]))
    assert set(entries) == {'deleted.txt', 'old.txt', 'new.txt', 'binary.bin', 'untracked.txt'}, entries
    assert entries['deleted.txt']['worktree'] == ord('D'), entries
    # --no-renames intentionally represents a staged rename as delete + add.
    assert entries['old.txt']['index'] == ord('D') and entries['new.txt']['index'] == ord('A'), entries
    assert entries['untracked.txt']['kind'] == 'untracked', entries
    assert '-DELETE_ME\n' in h.diff('deleted.txt')['diff']
    assert '-RENAMED_CONTENT\n' in h.diff('old.txt', staged=True)['diff']
    assert '+RENAMED_CONTENT\n' in h.diff('new.txt', staged=True)['diff']
    h.diff('new.txt', kind='unchanged')
    h.diff('binary.bin', kind='binary')
    before = h.git()['launches']
    h.diff('untracked.txt', kind='untracked')
    assert h.git()['launches'] == before


def conflict(h):
    root = h.repo()
    h.fixture_git(root, 'checkout', '-b', 'other')
    h.write(root / 'same.txt', 'OTHER\n')
    h.commit(root)
    h.fixture_git(root, 'checkout', 'main')
    h.write(root / 'same.txt', 'MAIN\n')
    h.commit(root)
    h.fixture_git(root, 'merge', '--no-edit', '--no-gpg-sign', 'other', expected=1)
    h.expected[root / 'same.txt'] = digest((root / 'same.txt').read_bytes())
    entry = h.entries(h.start([root]))['same.txt']
    assert entry['kind'] == 'unmerged' and entry['index'] == entry['worktree'] == ord('U'), entry
    before = h.git()['launches']
    h.diff('same.txt', kind='conflict')
    h.diff('same.txt', staged=True, kind='conflict')
    assert h.git()['launches'] == before


def unborn(h):
    root = h.repo(commit=False)
    h.fixture_git(root, 'add', '--', 'same.txt')
    p = h.start([root])
    assert p['head'] == '(initial)' and p['branch'] == 'main', p
    assert '+BASE\n' in h.diff('same.txt', staged=True)['diff']
    h.diff('same.txt', kind='unchanged')


def detached(h):
    root = h.repo()
    head = h.fixture_git(root, 'rev-parse', 'HEAD').decode().strip()
    h.fixture_git(root, 'checkout', '--detach', 'HEAD')
    h.write(root / 'same.txt', 'DETACHED_DISK\n')
    p = h.start([root])
    assert p['head'] == head and p['branch'] == '(detached)', p
    assert '+DETACHED_DISK\n' in h.diff('same.txt')['diff']


def literal_paths(h):
    names = ['line\nbreak.txt', '-leading.txt', '日本語-é😀.txt', ':(glob)*.txt', '[ab]*?.txt']
    root = h.repo(name='repo\n', files={name: 'BASE_%d\n' % i for i, name in enumerate(names)} |
                  {'decoy.txt': 'DECOY_BASE\n'})
    for i, name in enumerate(names):
        h.write(root / name, 'LITERAL_%d\n' % i)
    h.write(root / 'decoy.txt', 'DECOY_CHANGED\n')
    p = h.start([root])
    assert p['repositories'][0]['path'] == str(root), p
    assert set(h.entries(p)) == set(names) | {'decoy.txt'}
    for i, name in enumerate(names):
        p = h.diff(name, alias=bool(i % 2))
        assert '+LITERAL_%d\n' % i in p['diff'] and 'DECOY_CHANGED' not in p['diff'], p
        assert all('LITERAL_%d' % j not in p['diff'] for j in range(len(names)) if j != i), p


def roots_discovery(h):
    left, right = h.repo('left'), h.repo('right')
    nested = h.repo('left/nested')
    worktree = h.fixtures / 'worktree'
    assert worktree.resolve().is_relative_to(h.fixtures.resolve())
    h.fixture_git(right, 'worktree', 'add', '--detach', str(worktree), 'HEAD')
    h.repositories.append(worktree)
    assert (worktree / '.git').is_file()
    for root, token in ((left, 'LEFT'), (right, 'RIGHT'), (nested, 'NESTED'), (worktree, 'WORKTREE')):
        h.write(root / 'same.txt', token + '\n')
    p = h.start([left, right, worktree], active=nested / 'same.txt')
    repos = {r['path']: r for r in p['repositories']}
    assert set(repos) == set(map(str, (left, right, nested, worktree))), p
    assert repos[str(nested)]['owner'] == str(left), p
    assert repos[str(worktree)]['gitdir'] != repos[str(worktree)]['commondir'], p
    assert repos[str(worktree)]['commondir'] == str(right / '.git'), p
    assert repos[str(left)]['root'] == repos[str(nested)]['root'], p
    assert len({r['root'] for r in repos.values()}) == 3, p
    for i, (root, token) in enumerate(((left, 'LEFT'), (right, 'RIGHT'), (nested, 'NESTED'), (worktree, 'WORKTREE'))):
        h.select_repo(root, alias=bool(i % 2))
        assert '+' + token + '\n' in h.diff('same.txt')['diff']


def outside_root(h):
    outer = h.repo('outer', files={'sub/file.txt': 'OUTSIDE OWNER\n'})
    h.watch_indexes()
    h.workspace_roots([outer / 'sub'])
    h.open_document(outer / 'sub/file.txt')
    h.trust()
    h.disclosure()
    h.command('git-accept')
    p = h.idle()
    assert p['outside'] >= 1 and not p['repositories'] and p['head'] is None, p
    assert not p['entries'] and p['visible'], p


def refresh_unsaved(h):
    root = h.repo()
    h.write(root / 'same.txt', 'DISK_BEFORE\n')
    p = h.start([root], active=root / 'same.txt')
    h.replace_keyboard('UNSAVED_BUFFER_ONLY\n')
    doc = h.document(root / 'same.txt')
    assert doc['dirty'], doc
    h.unchanged(p)
    p = h.diff('same.txt')
    assert '+DISK_BEFORE\n' in p['diff'] and 'UNSAVED_BUFFER_ONLY' not in p['diff'], p
    assert p['dirty_documents'] == 1, p
    h.write(root / 'new-on-disk.txt', 'EXPLICIT_REFRESH_ONLY\n')
    h.unchanged(p)
    # Presenting an already-open surface is not a refresh either.
    h.invoke('status')
    h.unchanged(p)
    p = h.refresh()
    assert set(h.entries(p)) == {'same.txt', 'new-on-disk.txt'}, p
    assert h.document(root / 'same.txt') == doc
    assert (root / 'same.txt').read_text() == 'DISK_BEFORE\n'
    h.close_git()
    h.select(h.target, focus=True)
    h.action('win.close')
    wait_for(lambda: h.state()['dialog'])
    h.command('respond', response=1)
    wait_for(lambda: h.document(root / 'same.txt') is None)


def paging(h):
    root = h.repo()
    for i in range(131):
        h.write(root / ('untracked-%03d.txt' % i), 'untracked\n')
    p = h.start([root])
    assert p['entry_count'] == 131 and p['visible_rows'] == 128 and p['page'] == 0, p
    first = {e['path'] for e in p['entries']}
    launches = p['launches']
    h.command('git-page', 'previous')
    assert h.git()['page'] == 0
    h.command('git-page', 'next')
    p = h.git()
    assert p['page'] == 1 and p['visible_rows'] == 3 and p['selected_file'] is None, p
    second = {e['path'] for e in p['entries']}
    assert not first & second and len(first | second) == 131
    h.diff(p['entries'][-1]['path'], kind='untracked', alias=True)
    assert h.git()['selected_file'] == 130
    h.command('git-page', 'next')
    assert h.git()['page'] == 1
    h.command('git-page', 'previous')
    p = h.git()
    assert p['page'] == 0 and p['selected_file'] is None and p['launches'] == launches, p
    assert {e['path'] for e in p['entries']} == first


def pending_teardown(h, mode):
    root = h.repo(files={'same.txt': 'BASE\n', '.gitattributes': '*.txt filter=bounded\n'})
    other = h.repo('other') if mode == 'root' else None
    marker = h.fixtures / 'filter-entered'
    # Deliberate executable fixture, not a prohibited-execution sentinel. The
    # filter cannot finish normally before cancellation, and has its own bound.
    script = h.write(h.fixtures / 'bounded-filter.py',
                     '#!/usr/bin/python3\nimport os, time\nfrom pathlib import Path\n'
                     + 'Path(%r).write_text(str(os.getpid()))\n' % str(marker)
                     + 'time.sleep(30)\n')
    script.chmod(0o700)
    h.fixture_git(root, 'config', 'filter.bounded.clean', shlex.quote(str(script)))
    h.fixture_git(root, 'config', 'filter.bounded.required', 'true')
    # A size change lets Git classify the file as modified without hashing it,
    # skipping the clean filter entirely. Equal-size contents force that path.
    h.write(root / 'same.txt', 'DIFF\n')
    h.watch_indexes()
    h.workspace_roots([root])
    h.trust()
    h.disclosure()
    h.command('git-accept')
    before = h.wait_git(lambda p: p['busy'] and p['phase'] == 'status'
                        and marker.exists() and marker.read_text(), 6)
    h.remember_processes()
    assert int(marker.read_text()) in h.processes, h.processes
    if mode == 'root':
        h.workspace_roots([other])
    elif mode == 'revoke':
        h.command('policy-revoke')
        h.restricted(h.policy_idle())
    else:
        h.command('git-close')
    p = h.idle()
    assert p['generation'] > before['generation'] and p['discarded'] > before['discarded'], p
    assert not p['visible'] and not p['approved'] and not p['repositories'] and not p['entries'], p
    assert p['diff_kind'] == 'none' and not p['disclosure'], p
    h.reaped()
    h.drained(1)
    h.unchanged(p)
    if mode == 'close':
        # Closing the surface invalidates consent. Re-open, block another real
        # job, then quit the application itself without pre-closing Git.
        marker.unlink()
        h.disclosure()
        h.command('git-accept')
        h.wait_git(lambda p: p['busy'] and p['phase'] == 'status'
                   and marker.exists() and marker.read_text(), 6)
        h.remember_processes()
        h.action('win.quit')
        assert h.app.wait(timeout=10) == 0, h.app.lines[-30:]
        h.reaped()
        wait_for(lambda: not h.native_windows())
        h.no_criticals()


from git_mutations import CASES as MUTATION_CASES


CASES = [
    ('gates-restricted', restricted),
    ('gates-decline', decline),
    ('diff-sides', diff_sides),
    ('status-kinds', status_kinds),
    ('status-conflict', conflict),
    ('head-unborn', unborn),
    ('head-detached', detached),
    ('paths-literal', literal_paths),
    ('roots-discovery', roots_discovery),
    ('roots-outside', outside_root),
    ('refresh-unsaved', refresh_unsaved),
    ('paging', paging),
    *[('teardown-' + mode, functools.partial(pending_teardown, mode=mode)) for mode in ('root', 'revoke', 'close')],
    *MUTATION_CASES,
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
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-git')
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
                                 'No hidden refresh is sampled over bounded observation windows, not proven for all time.',
                                 'Renames are intentionally delete/add in this --no-renames increment.'])
    began = time.monotonic()
    save(report, evidence)

    def expired(_signum, _frame):
        raise CaseTimeout('Native Git case/suite runtime budget exceeded')

    previous = signal.signal(signal.SIGALRM, expired)
    try:
        binary = args.binary.resolve()
        data = binary.read_bytes()
        evidence['binary_sha256'] = digest(data)
        evidence['source_sha256'] = {str(path.relative_to(PROJECT)): digest(path.read_bytes())
                                     for path in (Path(__file__).resolve(), PROJECT / 'src/git/controller.zig',
                                                  PROJECT / 'src/git/command.zig', PROJECT / 'src/git/status.zig',
                                                  PROJECT / 'tests/git_mutations.py', PROJECT / 'src/git/mutation_controller.zig',
                                                  PROJECT / 'src/git/index_transaction.zig', PROJECT / 'src/git/index_transaction_os.zig')}
        assert all(marker in data for marker in (b'CORAL_GIT ', b'CORAL_WINDOWS ', b'CORAL_COMMAND_DONE')), \
            'Parent must build the integrated src/git native target with test hooks; stale binary refused'
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
                    h = GitHarness.__new__(GitHarness)
                    h.__init__(session, binary, run_output, evidence, name, min(start + 75, began + 600))
                    scenario(h)
                    h.stop()
                    h.verify_files()
                    resets = sum(item['case'] == name for item in evidence.get('index_baseline_resets', []))
                    record.update(status='passed', indexes_verified=len(h.indexes), index_baseline_resets=resets,
                                  index_expectation='explicit verified mutation baseline' if resets else 'original bytes/mtime',
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
