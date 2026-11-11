"""Selected-file native acceptance helpers; all writes belong to disposable fixtures.

Requests use the real window GActions, never a backend/test-only mutation route.
Only dialog responses and bounded pre-worker delays use mutation test hooks.
"""
import functools
import hashlib
import os
import shlex
import stat
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stamp(path):
    st = path.lstat()
    data = os.fsencode(os.readlink(path)) if stat.S_ISLNK(st.st_mode) else path.read_bytes()
    return (st.st_dev, st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns, sha(data))


def tree(root):
    # Do not follow symlinks or inspect anything outside this disposable fixture.
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [name for name in dirs if name != '.git']
        for name in files + [name for name in dirs if (Path(directory) / name).is_symlink()]:
            path = Path(directory) / name
            if name != '.git':
                result[str(path.relative_to(root))] = stamp(path)
    return result


def entries(h, root):
    raw = h.fixture_git(root, 'ls-files', '--stage', '-z')
    result = {}
    for record in raw.split(b'\0'):
        if not record:
            continue
        header, path = record.split(b'\t', 1)
        mode, oid, stage = header.split()
        result[(os.fsdecode(path), int(stage))] = (int(mode, 8), oid.decode())
    return result


def entry(data, mode=0o100644):
    # These fixtures use Git's default SHA-1 format, asserted when captured.
    return (mode, hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest())


def index_path(h, root):
    raw = h.fixture_git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index')
    path = Path(os.fsdecode(raw[:-1]))
    assert raw.endswith(b'\n') and path.resolve().is_relative_to(h.fixtures.resolve()), path
    return path


class Preservation:
    def __init__(self, h):
        self.h = h
        self.trees = {root: tree(root) for root in h.repositories}
        self.metadata = {}
        for root in h.repositories:
            common = h.fixture_git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
            directory = Path(os.fsdecode(common.rstrip(b'\n')))
            assert directory.resolve().is_relative_to(h.fixtures.resolve()), directory
            self.metadata[directory] = self.metadata_tree(directory)
        self.scratch = set()
        h.mutation_preservation = self

    @staticmethod
    def metadata_tree(directory):
        # Index publication and new immutable objects are allowed separately;
        # HEAD, refs, reflogs, config, hooks and all other metadata are not.
        return {name: value for name, value in tree(directory).items()
                if Path(name).name != 'index' and 'objects' not in Path(name).parts}

    def observe_scratch(self):
        # Inspect only descriptors owned by this test's app, not a broad /tmp scan.
        for fd in Path('/proc/%d/fd' % self.h.app.proc.pid).iterdir():
            try:
                path = Path(os.readlink(fd))
            except FileNotFoundError:
                continue
            if path.name.startswith('coral-index-') and path.parent == Path('/tmp'):
                self.scratch.add(path)

    def verify(self, retired=False):
        for root, before in self.trees.items():
            assert tree(root) == before, ('Worktree rewritten or changed', root, before, tree(root))
        for directory, before in self.metadata.items():
            assert self.metadata_tree(directory) == before, ('Repository metadata changed', directory)
        if retired:
            for path in self.scratch:
                assert not path.exists(), ('Native transaction scratch survived retirement', path)

    def external_file(self, path, data):
        self.verify()
        self.h.write(path, data)
        for root in self.trees:
            if path.is_relative_to(root):
                self.trees[root] = tree(root)

    def reset_index(self, root, expected, reason):
        """Permit ONLY an already-verified selected-entry or external-fixture change.

        Never relax verify_files: replace just this index's explicit baseline after
        checking the complete entry map and every other watched index first.
        """
        assert reason in ('reviewed selected path', 'external stale-index fixture')
        self.verify()
        actual = entries(self.h, root)
        assert actual == expected, ('Unexpected index entries', reason, expected, actual)
        path = index_path(self.h, root)
        assert path in self.h.indexes
        for other, before in self.h.indexes.items():
            if other != path:
                now = (other.read_bytes(), other.stat().st_mtime_ns) if other.exists() else None
                assert now == before, ('Unrelated repository index changed', other)
        before = self.h.indexes[path]
        after = (path.read_bytes(), path.stat().st_mtime_ns) if path.exists() else None
        assert before != after, ('Expected index mutation did not happen', root)
        self.h.evidence.setdefault('index_baseline_resets', []).append(dict(
            case=self.h.name, reason=reason, path=str(path),
            before_sha256=None if before is None else sha(before[0]),
            after_sha256=None if after is None else sha(after[0]),
            entries=[dict(path=p, stage=s, mode=m, oid=o) for (p, s), (m, o) in sorted(actual.items())]))
        self.h.indexes[path] = after
        self.h.verify_files()


def mutation(h):
    p = h.git()
    assert 'mutation' in p, ('Integrated mutation probe missing', p)
    return p['mutation']


def settled(h, state, error=None):
    p = h.wait_git(lambda p: not p['mutation']['busy'] and not p['busy'] and p['pending'] == 'none')
    m = p['mutation']
    assert m['state'] == state and m['error'] == error, p
    assert not m['dialog'] and not m['barrier'], m
    assert m['jobs_started'] == m['jobs_reaped'], m
    assert m['committed'] == (state == 'succeeded') and not m['durability_uncertain'], m
    h.mutation_preservation.verify(retired=True)
    h.reaped()
    h.drained(1)
    h.evidence.setdefault('mutation_outcomes', []).append(dict(case=h.name, probe=p))
    return p


def request(h, path, action='stage'):
    h.select_file(path)
    before = mutation(h)['jobs_started']
    assert h.git()['mutation_actions_enabled'], h.git()
    h.invoke(action)  # real org.gtk.Actions route used by the native window
    p = h.wait_git(lambda p: p['mutation']['jobs_started'] > before or p['mutation']['state'] == 'failed')
    assert p['mutation']['jobs_started'] > before, p
    return p


def escaped(data):
    result = ''
    for ch in data.decode('utf-8'):
        cp = ord(ch)
        if ch == '\n':
            result += '\\n\n'
        elif ch == '\\':
            result += '\\\\'
        elif cp < 0x20 or 0x7f <= cp <= 0x9f or cp in (0x61c, 0x200e, 0x200f) or 0x2028 <= cp <= 0x202e or 0x2066 <= cp <= 0x206f:
            result += '\\u{%x}' % cp
        else:
            result += ch
    return result


def review(h, path, before, after, action='stage', before_mode=0o100644, after_mode=0o100644):
    request(h, path, action)
    p = h.wait_git(lambda p: p['mutation']['dialog'] or not p['mutation']['busy'])
    m = p['mutation']
    assert m['state'] == 'confirming' and m['dialog'] and m['busy'] and not m['barrier'], p
    assert m['action'] == action and m['path'] == path and not m['committed'], m
    assert m['jobs_started'] == m['jobs_reaped'], m
    assert not p['mutation_actions_enabled'], p
    for side, data, mode in (('before', before, before_mode), ('after', after, after_mode)):
        mode = mode if data is not None else 0
        assert m[side + '_exists'] == (data is not None), m
        assert m[side + '_mode'] == mode and m[side + '_bytes'] == len(data or b''), m
    def pane(label, data, mode):
        return '%s · exists: %s · mode: %o · %d bytes\nSHA-256: %s\n%s' % (
            label, 'yes' if data is not None else 'no', mode if data is not None else 0,
            len(data or b''), sha(data or b''), escaped(data or b''))
    suffix = '\n\n' + pane('BEFORE — INDEX', before, before_mode) + '\n\n' + pane(
        'AFTER — INDEX FROM ' + ('DISK' if action == 'stage' else 'HEAD'), after, after_mode)
    assert m['review'].endswith(suffix), (suffix, m)
    assert 'FULL FILE, NOT HUNKS' in m['review'] and 'NEVER saved' in m['review'], m
    h.mutation_preservation.observe_scratch()
    assert h.mutation_preservation.scratch, 'Prepared review must own observed native scratch'
    h.verify_files()  # prepare/review is not authorization to mutate the index
    h.evidence.setdefault('mutation_reviews', []).append(dict(case=h.name, probe=p))
    return p


def accept(h, root, expected):
    h.command('git-mutation-accept')
    settled(h, 'succeeded')
    h.mutation_preservation.reset_index(root, expected, 'reviewed selected path')
    for mode, oid in expected.values():
        data = h.fixture_git(root, 'cat-file', 'blob', oid)
        assert entry(data, mode) == (mode, oid), ('Published index references missing/incorrect object', oid)
    before = mutation(h)
    h.command('git-mutation-accept')  # consumed approval cannot replay a mutation
    assert mutation(h) == before
    h.verify_files()


def fixture(h, unborn=False):
    root = h.repo(files={'same.txt': b'BASE\n', 'unrelated.txt': b'OTHER_BASE\n'}, commit=not unborn)
    h.write(root / 'unrelated.txt', b'OTHER_INDEX\n')
    h.fixture_git(root, 'add', '--', 'unrelated.txt')
    h.write(root / 'unrelated.txt', b'OTHER_DISK_UNSTAGED\n')
    return root


def begin(h, roots, active=None):
    h.start(roots, active=active)
    for root in roots:
        assert h.fixture_git(root, 'rev-parse', '--show-object-format') == b'sha1\n'
    return Preservation(h)


def stage(h, kind):
    root = fixture(h)
    name, before, after = 'same.txt', b'BASE\n', 'DISK\\literal\t\r\n日本語\u202eend'.encode()
    before_mode, after_mode = 0o100644, 0o100644
    if kind == 'modified':
        before = b'PREVIOUS_INDEX_ONLY\n'
        h.write(root / name, before)
        h.fixture_git(root, 'add', '--', name)
    elif kind == 'untracked':
        name, before, after = ':(glob)*.txt', None, 'NEW 日本語\u202e\\\t\nno-final-LF'.encode()
    elif kind == 'delete':
        after = None
    elif kind == 'empty':
        name, before, after = 'empty.txt', None, b''
    elif kind == 'mode':
        after_mode = 0o100755
    elif kind == 'unborn':
        # A missing index is distinct from an existing empty index.
        root = h.repo('unborn', files={}, commit=False)
        name, before, after = 'first.txt', None, b'FIRST\n'
    if after is None:
        h.remove(root / name)
    else:
        h.write(root / name, after)
        if kind == 'mode':
            (root / name).chmod(0o755)
    begin(h, [root])
    expected = entries(h, root)
    review(h, name, before, after, before_mode=before_mode, after_mode=after_mode)
    if after is None:
        del expected[(name, 0)]
    else:
        expected[(name, 0)] = entry(after, after_mode)
    accept(h, root, expected)


def unstage(h, kind):
    root = fixture(h, unborn=kind == 'unborn')
    name, before, after = 'same.txt', b'INDEX\n', b'BASE\n'
    if kind in ('added', 'unborn'):
        after = None
        if kind == 'added':
            name = 'new.txt'
    if kind == 'delete':
        h.fixture_git(root, 'update-index', '--force-remove', '--', name)
        before = None
    else:
        h.write(root / name, before)
        if kind == 'mode':
            (root / name).chmod(0o755)
        h.fixture_git(root, 'add', '--', name)
    h.write(root / name, b'UNSTAGED_DISK_MUST_SURVIVE\n')
    begin(h, [root])
    expected = entries(h, root)
    review(h, name, before, after, 'unstage', before_mode=0o100755 if kind == 'mode' else 0o100644)
    if after is None:
        del expected[(name, 0)]
    else:
        expected[(name, 0)] = entry(after)
    accept(h, root, expected)


def dirty(h):
    root = fixture(h)
    h.write(root / 'same.txt', b'DISK_ONLY\n')
    begin(h, [root], active=root / 'same.txt')
    h.replace_keyboard('UNSAVED_BUFFER_ONLY\n')
    doc = h.document(root / 'same.txt')
    assert doc['dirty'], doc
    expected = entries(h, root)
    p = review(h, 'same.txt', b'BASE\n', b'DISK_ONLY\n')
    assert p['dirty_documents'] == 1 and 'UNSAVED_BUFFER_ONLY' not in p['mutation']['review'], p
    expected[('same.txt', 0)] = entry(b'DISK_ONLY\n')
    accept(h, root, expected)
    assert h.document(root / 'same.txt') == doc
    review(h, 'same.txt', b'DISK_ONLY\n', b'BASE\n', 'unstage')
    expected[('same.txt', 0)] = entry(b'BASE\n')
    accept(h, root, expected)
    assert h.document(root / 'same.txt') == doc
    h.close_git()
    h.select(h.target, focus=True)
    h.action('win.close')
    from pearl_session import wait_for
    wait_for(lambda: h.state()['dialog'])
    h.command('respond', response=1)
    wait_for(lambda: h.document(root / 'same.txt') is None)


def reject(h):
    root = fixture(h)
    h.write(root / 'same.txt', b'REJECTED_DISK\n')
    begin(h, [root])
    metadata = tree(root / '.git')
    review(h, 'same.txt', b'BASE\n', b'REJECTED_DISK\n')
    assert tree(root / '.git') == metadata, 'Prepare wrote repository metadata or objects'
    h.command('git-mutation-reject')
    settled(h, 'cancelled')
    assert tree(root / '.git') == metadata, 'Rejected review wrote repository metadata or objects'
    before = mutation(h)
    h.command('git-mutation-accept')
    assert mutation(h) == before
    h.verify_files()


def stale(h, source):
    root = fixture(h)
    h.write(root / 'same.txt', b'REVIEWED\n')
    guard = begin(h, [root])
    review(h, 'same.txt', b'BASE\n', b'REVIEWED\n')
    if source == 'disk':
        guard.external_file(root / 'same.txt', b'CHANGED_AFTER_REVIEW\n')
    elif source == 'index':
        expected = entries(h, root)
        expected[('unrelated.txt', 0)] = entry(b'OTHER_DISK_UNSTAGED\n')
        h.fixture_git(root, 'add', '--', 'unrelated.txt')
        guard.reset_index(root, expected, 'external stale-index fixture')
    else:
        old = h.fixture_git(root, 'rev-parse', 'HEAD').decode().strip()
        tree_oid = h.fixture_git(root, 'rev-parse', 'HEAD^{tree}').decode().strip()
        new = h.fixture_git(root, 'commit-tree', tree_oid, '-p', old, '-m', 'External fixture HEAD move').decode().strip()
        h.fixture_git(root, 'update-ref', 'HEAD', new, old)
        # Deliberate external HEAD/ref/reflog change, not permission for the app
        # to rewrite any repository metadata during refusal.
        directory = root / '.git'
        guard.metadata[directory] = guard.metadata_tree(directory)
    h.command('git-mutation-accept')
    settled(h, 'failed', 'StaleSnapshot')
    h.verify_files()


def locked(h):
    root = fixture(h)
    h.write(root / 'same.txt', b'CONTENDED\n')
    begin(h, [root])
    review(h, 'same.txt', b'BASE\n', b'CONTENDED\n')
    lock = index_path(h, root).with_name('index.lock')
    assert not lock.exists()
    lock.write_bytes(b'FOREIGN LOCK - NEVER REMOVE\n')
    before = stamp(lock)
    guard = h.mutation_preservation
    guard.metadata[root / '.git'] = guard.metadata_tree(root / '.git')
    try:
        h.command('git-mutation-accept')
        settled(h, 'failed', 'IndexLocked')
        assert stamp(lock) == before, 'Foreign lock changed or removed'
        # verify_files intentionally still rejects *any* lock. Prove native
        # preservation first, then explicitly remove only our fixture's lock.
    finally:
        if lock.exists() and stamp(lock) == before:
            lock.unlink()
            guard.metadata[root / '.git'] = guard.metadata_tree(root / '.git')
    h.verify_files()


def teardown(h, phase, mode):
    root = fixture(h)
    other = h.repo('other') if mode == 'root' else None
    h.write(root / 'same.txt', b'CANCEL_BEFORE_PUBLICATION\n')
    guard = begin(h, [root])
    h.command('git-mutation-delay', phase + ':2000')
    if phase == 'prepare':
        request(h, 'same.txt')
    else:
        review(h, 'same.txt', b'BASE\n', b'CANCEL_BEFORE_PUBLICATION\n')
        h.command('git-mutation-accept')
    p = h.wait_git(lambda p: p['mutation']['state'] == ('preparing' if phase == 'prepare' else 'applying'))
    m = p['mutation']
    assert m['busy'] and m['jobs_started'] > m['jobs_reaped'], m
    assert m['barrier'] == (phase == 'apply'), m
    guard.observe_scratch()
    if mode == 'root':
        h.workspace_roots([other])
    elif mode == 'revoke':
        h.command('policy-revoke')
        h.restricted(h.policy_idle())
    else:
        h.command('git-close')
    p = settled(h, 'cancelled')
    assert not p['approved'] and not p['visible'] and not p['entries'], p
    h.verify_files()
    # Exercise a fresh request after retirement: stale approval is gone and
    # releasing the barrier is operational, not merely a probe boolean.
    if mode != 'root':
        if mode == 'revoke':
            h.trust()
        h.disclosure()
        h.command('git-accept')
        h.idle()
        review(h, 'same.txt', b'BASE\n', b'CANCEL_BEFORE_PUBLICATION\n')
        h.command('git-mutation-reject')
        settled(h, 'cancelled')
        h.verify_files()


def unsupported(h, kind):
    root = fixture(h)
    error = {'filter': 'ConversionUnsupported', 'symlink': 'UnsafeFile', 'binary': 'Binary',
             'conflict': 'Conflict', 'nonutf8': 'NonUtf8', 'preview': 'PreviewTooLarge'}[kind]
    if kind == 'filter':
        marker = h.fixtures / 'FILTER_EXECUTED'
        h.sentinels.append(marker)
        # Untracked target prevents read-only status from legitimately invoking
        # the clean filter before the mutation policy can reject it.
        name = 'filtered.txt'
        h.write(root / '.gitattributes', 'filtered.txt filter=sentinel\n')
        h.fixture_git(root, 'config', 'filter.sentinel.clean', 'touch ' + shlex.quote(str(marker)))
        h.write(root / name, b'FILTER MUST NOT RUN\n')
    elif kind == 'symlink':
        name = 'link.txt'
        (root / name).symlink_to('same.txt')
    elif kind == 'conflict':
        name = 'same.txt'
        base = h.fixture_git(root, 'rev-parse', 'HEAD').decode().strip()
        # Construct conflict stages directly, without checkout or merge writes.
        oid = h.fixture_git(root, 'rev-parse', base + ':same.txt').decode().strip()

        payload = ('0 ' + '0' * 40 + '\t' + name + '\n' + ''.join(
            '100644 %s %d\t%s\n' % (oid, number, name) for number in (1, 2, 3))).encode()
        h.fixture_git(root, 'update-index', '--index-info', input=payload)
    else:
        name = 'same.txt'
        h.write(root / name, {'binary': b'a\0b', 'nonutf8': b'\xff', 'preview': b'x' * 2049}[kind])
    begin(h, [root])
    request(h, name)
    settled(h, 'failed', error)
    h.verify_files()


def worktree(h):
    main = fixture(h)
    root = h.fixtures / 'linked'
    assert root.resolve().is_relative_to(h.fixtures.resolve())
    h.fixture_git(main, 'worktree', 'add', '--detach', str(root), 'HEAD')
    h.repositories.append(root)
    h.write(root / 'same.txt', b'LINKED_DISK\n')
    begin(h, [main, root])
    h.select_repo(root)
    expected = entries(h, root)
    review(h, 'same.txt', b'BASE\n', b'LINKED_DISK\n')
    expected[('same.txt', 0)] = entry(b'LINKED_DISK\n')
    accept(h, root, expected)
    # Publication refresh rediscovers repositories and selects the first one.
    # Request unstage against the linked worktree explicitly, not that default.
    h.select_repo(root)
    review(h, 'same.txt', b'LINKED_DISK\n', b'BASE\n', 'unstage')
    expected[('same.txt', 0)] = entry(b'BASE\n')
    accept(h, root, expected)


def gates(h):
    root = fixture(h)
    h.write(root / 'same.txt', b'NO_IMPLICIT_APPROVAL\n')
    h.watch_indexes()
    h.workspace_roots([root])
    Preservation(h)
    for action in ('stage', 'unstage'):
        h.invoke(action)
        h.command('git-mutation-accept')
        m = mutation(h)
        assert not m['busy'] and not m['dialog'] and not m['committed'] and m['jobs_started'] == 0, m
    h.trust()
    h.disclosure()
    h.command('git-mutation-accept')  # cannot answer the separate disclosure
    assert h.git()['disclosure'] and mutation(h)['jobs_started'] == 0
    h.command('git-accept')
    h.idle()
    h.select_file('same.txt')
    h.command('git-mutation-accept')  # selected path alone is not a review
    assert mutation(h)['jobs_started'] == 0
    h.verify_files()


CASES = [
    ('mutation-gates', gates),
    *[('mutation-stage-' + kind, functools.partial(stage, kind=kind))
      for kind in ('modified', 'untracked', 'delete', 'empty', 'mode', 'unborn')],
    *[('mutation-unstage-' + kind, functools.partial(unstage, kind=kind))
      for kind in ('modified', 'added', 'delete', 'mode', 'unborn')],
    ('mutation-dirty', dirty),
    ('mutation-reject', reject),
    *[('mutation-stale-' + source, functools.partial(stale, source=source)) for source in ('disk', 'index', 'head')],
    ('mutation-lock', locked),
    *[('mutation-teardown-' + phase + '-' + mode, functools.partial(teardown, phase=phase, mode=mode))
      for phase in ('prepare', 'apply') for mode in ('revoke', 'root', 'close')],
    *[('mutation-unsupported-' + kind, functools.partial(unsupported, kind=kind))
      for kind in ('filter', 'symlink', 'binary', 'conflict', 'nonutf8', 'preview')],
    ('mutation-worktree', worktree),
]
