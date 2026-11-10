#!/usr/bin/env python3
"""Native M2 search acceptance in a private Wayland/XDG session.

Only the search build target is needed. Fixtures are disposable, actual files;
100k means 100,000 nonempty regular files, not model rows. Timings measure real
input-to-observed-ack (including wtype startup), NOT paint/frame latency.
Failures and partial evidence are retained in results.json; no host files,
clipboard, desktop, configuration or recovery state are used.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import time
import traceback
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC


class Harness:
    def __init__(self, session, binary, output, evidence):
        self.session, self.output, self.evidence = session, output, evidence
        self.ipc = IPC(session)
        self.fixtures = Path(session.env['XDG_CONFIG_HOME']) / 'search-fixtures'
        self.fixtures.mkdir()
        self.command_path = self.fixtures / 'command.ini'
        session.env['CORAL_TEST_COMMAND'] = str(self.command_path)
        self.app = session.child('coral-search', [binary], G_DEBUG='fatal-criticals')
        window = wait_for(lambda: next((w for w in self.ipc.state() if w['kind'] == 'window'), None))
        self.ipc.call('command', action='window.activate', fields={'id': window['id']})
        self.last = {}
        self.peak_rss = 0
        self.expected = {}
        self.protected = {}
        self.deadline = time.monotonic() + 540

    def alive(self):
        if self.app.proc.poll() is not None:
            start = next((i for i, line in enumerate(self.app.lines) if 'panic:' in line or 'CRITICAL' in line), max(0, len(self.app.lines) - 20))
            raise AssertionError('\n'.join(self.app.lines[start:start + 20]))
        assert time.monotonic() < self.deadline, 'Native suite exceeded 540-second budget'

    def key(self, name, *mods):
        self.alive()
        argv = ['wtype', '-s', '10']
        for mod in mods:
            argv += ['-M', mod]
        argv += ['-k', name]
        for mod in reversed(mods):
            argv += ['-m', mod]
        # Keep the virtual keyboard alive across GTK list rebuilds; destroying
        # it sooner can drop queued events rather than measure their latency.
        self.session.run(argv + ['-s', '100'])

    def text(self, value):
        self.session.run(['wtype', '-s', '10', '--', value])

    @staticmethod
    def escape(value):
        return str(value).replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')

    def command(self, action, value=None, **fields) -> tuple[list[str], float]:
        self.alive()
        content = '[Test]\naction=' + action + '\n'
        if value is not None:
            content += 'value=' + self.escape(value) + '\n'
        content += ''.join(f'{k}={self.escape(v)}\n' for k, v in fields.items())
        self.command_path.write_text(content)
        start = len(self.app.lines)
        began = time.monotonic()
        # Keep this virtual keyboard alive UNTIL acknowledgement, rather than
        # destroying it after a guessed sleep during a potentially heavy frame.
        # The trailing sleep does not enter the input-to-ack measurement.
        for attempt in range(20):
            keyboard = subprocess.Popen(['wtype', '-s', '10', '-k', 'F11', '-s', '5000'],
                                        env=self.session.env, cwd=self.session.base,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE)
            try:
                wait_for(lambda: self.app.proc.poll() is not None or 'CORAL_COMMAND_DONE' in self.app.lines[start:],
                         .25 if action.endswith('-probe') else 5)
                elapsed = time.monotonic() - began
                self.alive()
                time.sleep(.01)  # allow the matching release event to reach the seat
                if attempt:
                    self.evidence.setdefault('probe_retries', []).append({'action': action, 'attempts': attempt + 1, 'ack_ms': elapsed * 1000})
                return self.app.lines[start:], elapsed
            except TimeoutError:
                # Like native.py, retry READ-ONLY probes across transient loss
                # of keyboard focus, never mutations. Timing includes retries.
                if not action.endswith('-probe') or attempt == 19:
                    self.screenshot('command-timeout')
                    raise TimeoutError(f'{action} was not acknowledged; windows={self.ipc.state()}')
            finally:
                keyboard.terminate()
                keyboard.communicate(timeout=2)
        raise AssertionError('Command retry loop exhausted without a result')

    def probe(self, kind='search'):
        prefix = 'CORAL_' + kind.upper() + ' '
        lines, _ = self.command(kind + '-probe')
        value = json.loads(next(line[len(prefix):] for line in lines if line.startswith(prefix)))
        self.last[kind] = value
        if kind == 'search':
            assert value['holds'] == int(value['active']), value
            assert value['started'] - value['reaped'] == int(value['active']), value
            assert value['worker_limit'] == value['pending_limit'] == value['mailbox_limit'] == 1
            assert len(value['results']) <= 1024 and value['rows'] <= 2080, value
            assert value['live_widgets'] <= 256 and value['peak_widgets'] <= 256, value
            assert value['overlay_bytes'] <= value['overlay_byte_limit'] == 4 * 1024 * 1024
        return value

    def browser(self):
        # File monitors first invalidate, then debounce/rebuild policy and watch
        # plans. No scan jobs alone does not mean a new query is safe to start.
        stable_since, previous = time.monotonic(), None

        def ready():
            nonlocal stable_since, previous
            p = self.probe('browser')
            stamp = (p['watch_generation'], p['resets'], p['pending'], p['loading'],
                     p['scanning'], p['watch_worker_busy'], p['watch_queue_depth'])
            if stamp != previous:
                stable_since, previous = time.monotonic(), stamp
            idle = not (p['pending'] or p['loading'] or p['scanning'] or
                        p['watch_worker_busy'] or p['watch_queue_depth'])
            return p if idle and time.monotonic() - stable_since >= .6 else None

        return wait_for(ready, 15)

    def settled(self, timeout=90):
        wait_for(lambda: p if not ((p := self.probe())['pending'] or p['active']) else None, timeout)
        # The worker callback can retire before the 25ms render pump runs.
        time.sleep(.03)
        return self.probe()

    def query(self, value, mode='text'):
        self.command('search-query', value, mode=mode)
        return self.settled()

    def exact(self, state, count, paths=None):
        assert state['complete'] and not state['stale'] and state['status'] == 'complete', state
        assert not state['reasons'] and state['error_name'] is None, state
        assert len(state['results']) == count, state
        if paths is not None:
            assert sorted(r['relative_path'] for r in state['results']) == sorted(paths), state
        return state

    def open_workspace(self, path, folder=False):
        self.command('open-folder' if folder else 'open-workspace', path)
        return self.browser()

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        data = content.encode() if isinstance(content, str) else content
        path.write_bytes(data)
        self.expected[path] = hashlib.sha256(data).hexdigest()
        return path

    def document(self, path):
        return next((d for d in self.probe('workspace')['documents'] if d['path'] == str(path)), None)

    def open_document(self, path):
        self.key('Escape')
        self.command('open', path)
        return wait_for(lambda: d if (d := self.document(path)) and d['text'] else None)

    def active(self):
        state = self.probe('workspace')
        view = next(v for v in state['views'] if v['active'])
        doc = next(d for d in state['documents'] if d['id'] == view['document_id'])
        return doc, view

    def activate(self, index, path=None):
        before = self.probe()['activations']
        self.command('search-activate', index=index)
        wait_for(lambda: self.probe()['activations'] == before + 1)
        doc, view = self.active()
        if path is not None:
            assert doc['path'] == str(path), (doc, path)
        return doc, view

    def protect(self, path):
        doc = self.document(path)
        assert doc and doc['dirty'], doc
        self.protected[doc['id']] = doc

    def preserved(self):
        docs = {d['id']: d for d in self.probe('workspace')['documents']}
        for identity, expected in self.protected.items():
            assert docs.get(identity) == expected, (expected, docs.get(identity))

    def rss(self):
        status = Path(f'/proc/{self.app.proc.pid}/status').read_text()
        value = int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmRSS:'))) * 1024
        self.peak_rss = max(self.peak_rss, value)
        return value

    def screenshot(self, name):
        path = self.output / 'screenshots' / (name + '.png')
        path.parent.mkdir(exist_ok=True)
        self.session.run(['grim', path])
        assert path.stat().st_size > 1000

    def no_criticals(self):
        assert not any('CRITICAL' in line or 'panic:' in line or 'protocol error' in line for line in self.app.lines), self.app.lines[-20:]


def run(h):
    f = h.fixtures
    left, right = f / 'left' / 'same', f / 'right' / 'same'
    unicode_text = 'heading\nπ🙂 e\u0301 CAFÉ needle 終\n'
    for root, label in ((left, 'LEFT'), (right, 'RIGHT')):
        h.write(root / 'same.txt', label + ' shared-root-token\n')
    h.write(left / 'unicode.txt', unicode_text)
    h.write(left / 'dirty.txt', 'disk-only-token\n')
    h.write(left / 'deleted.txt', 'deleted-disk-token\n')
    h.write(left / 'policy-visible.txt', 'policy-token\n')
    h.write(left / 'ignored.tmp', 'policy-token\n')
    h.write(left / 'nested' / 'keep.tmp', 'policy-token\n')
    h.write(left / 'nested' / 'drop.tmp', 'policy-token\n')
    h.write(left / 'nested' / '.gitignore', '!keep.tmp\n')
    h.write(left / '.gitignore', '*.tmp\npruned/\n')
    h.write(left / 'pruned' / 'child.txt', 'policy-token\n')
    h.write(left / '.git' / 'secret.txt', 'policy-token\n')
    h.write(right / 'excluded.txt', 'policy-token\n')
    spec = {'version': 1, 'roots': [{'path': 'left/same', 'name': 'same'}, {'path': 'right/same', 'name': 'same'}], 'exclude': ['excluded.txt']}
    manifest = h.write(f / 'pair.coral-workspace', json.dumps(spec))
    empty = h.write(f / 'empty.coral-workspace', '{"version":1,"roots":[]}')

    def routing():
        lines, _ = h.command('search-routing-checks')
        assert 'CORAL_SEARCH_ROUTING_CHECKS ok=1' in lines, lines
        h.evidence['routing_regressions'] = ['streaming navigation ownership', 'activation serial success/failure routing', 'captured document reload invalidation']

    def keyboard_identity_unicode():
        roots = h.open_workspace(manifest)['roots']
        ids = [r['id'] for r in roots]
        assert len(set(ids)) == 2
        h.key('p', 'ctrl')
        h.key('a', 'ctrl')
        h.text('same.txt')
        state = h.exact(h.settled(), 2, ['same.txt', 'same.txt'])
        assert state['visible'] and state['mode'] == 'quick_open' and state['query'] == 'same.txt'
        assert {r['root_id'] for r in state['results']} == set(ids)
        first = state['selected_index']
        h.key('Down')
        selected = h.probe()['selected_index']
        assert selected != first and selected is not None
        target = state['results'][selected]
        before = state['activations']
        h.key('Return')
        wait_for(lambda: h.probe()['activations'] == before + 1)
        expected_root = (left, right)[ids.index(target['root_id'])]
        assert h.active()[0]['path'] == str(expected_root / 'same.txt')
        assert not h.probe()['visible']
        h.key('f', 'ctrl', 'shift')
        h.key('a', 'ctrl')
        h.text('shared-root-token')
        state = h.exact(h.settled(), 2, ['same.txt', 'same.txt'])
        assert state['mode'] == 'text' and state['rows'] == 6, state
        assert {r['root_id'] for r in state['results']} == set(ids)
        h.screenshot('root-identity-groups')
        state = h.exact(h.query('café needle'), 1, ['unicode.txt'])
        result = state['results'][0]
        assert (result['line'], result['column'], result['end_column']) == (1, 6, 17), result
        assert result['byte_offset'] == len('heading\nπ🙂 e\u0301 '.encode())
        assert result['byte_length'] == len('CAFÉ needle'.encode())
        before = state['activations']
        h.key('Return')
        wait_for(lambda: h.probe()['activations'] == before + 1)
        doc, view = h.active()
        lo, hi = sorted((view['insertion'], view['bound']))
        assert doc['path'] == str(left / 'unicode.txt') and doc['text'][lo:hi] == 'CAFÉ needle', (doc, view)
        assert lo == unicode_text.index('CAFÉ') and not doc['dirty']
        h.screenshot('unicode-selection')
        h.evidence['unicode_result'] = result

    def overlays():
        path = left / 'dirty.txt'
        h.open_document(path)
        h.key('a', 'ctrl')
        h.text('unsaved-overlay-token π🙂')
        wait_for(lambda: (d := h.document(path))['text'] == 'unsaved-overlay-token π🙂' and d['dirty'])
        h.protect(path)
        state = h.exact(h.query('unsaved-overlay-token'), 1, ['dirty.txt'])
        overlay = state['results'][0]['source']['overlay']
        doc = h.document(path)
        assert overlay == {'document_id': doc['id'], 'revision': doc['revision']}
        h.exact(h.query('disk-only-token'), 0)
        h.exact(h.query('unsaved-overlay-token'), 1)
        h.activate(0, path)
        h.preserved()
        deleted = left / 'deleted.txt'
        h.open_document(deleted)
        h.key('a', 'ctrl')
        h.text('deleted-overlay-token')
        wait_for(lambda: h.document(deleted)['text'] == 'deleted-overlay-token')
        h.protect(deleted)
        deleted.unlink()
        h.expected.pop(deleted)
        h.browser()
        state = h.exact(h.query('deleted-overlay-token'), 1, ['deleted.txt'])
        assert 'overlay' in state['results'][0]['source']
        h.activate(0, deleted)
        assert not deleted.exists()
        h.exact(h.query('deleted-disk-token'), 0)
        h.preserved()
        h.evidence['overlay_identity'] = overlay

    def policy_and_staleness():
        h.open_workspace(manifest)
        h.exact(h.query('policy-token'), 2, ['policy-visible.txt', 'nested/keep.tmp'])
        # A denied dirty buffer must not bypass ignore/exclude policy.
        hidden = right / 'excluded.txt'
        h.open_document(hidden)
        h.key('End', 'ctrl')
        h.text(' hidden-overlay-token')
        h.protect(hidden)
        h.exact(h.query('hidden-overlay-token'), 0)
        h.exact(h.query('ignored.tmp', 'quick_open'), 0)
        h.exact(h.query('excluded.txt', 'quick_open'), 0)
        h.exact(h.query('keep.tmp', 'quick_open'), 1, ['nested/keep.tmp'])
        h.exact(h.query('policy-token'), 2)
        prior = h.probe()['generation']
        spec['exclude'].append('policy-visible.txt')
        h.write(manifest, json.dumps(spec))
        state = wait_for(lambda: p if (p := h.probe())['stale'] else None)
        assert state['generation'] > prior and not state['results'] and not state['complete']
        h.command('search-activate', index=0)
        h.browser()
        h.command('search-refresh')
        h.exact(h.settled(), 1, ['nested/keep.tmp'])
        h.write(left / 'nested' / '.gitignore', '')
        h.command('workspace-rescan')
        h.browser()
        h.exact(h.query('policy-token'), 0)
        h.write(left / 'nested' / '.gitignore', '!keep.tmp\n')
        spec['exclude'].remove('policy-visible.txt')
        h.write(manifest, json.dumps(spec))
        h.browser()
        h.exact(h.query('policy-token'), 2)
        # A real editor keystroke, not a synthetic revision flag, invalidates.
        doc, _ = h.active()
        h.command('search-query', 'policy-token', mode='text')
        h.settled()
        state = h.probe('workspace')
        index = next(i for i, v in enumerate(state['views']) if v['document_id'] == doc['id'])
        h.command('focus-view', index=index)
        h.key('End', 'ctrl')
        h.text(' revision-edit')
        state = wait_for(lambda: p if (p := h.probe())['stale'] else None)
        assert not state['results'] and not state['pending'] and not state['complete']
        h.protect(Path(doc['path']))
        h.command('search-refresh')
        h.exact(h.settled(), 2)
        h.preserved()

    def overlapping_activation():
        h.open_workspace(manifest)
        for fail in (False, True):
            state = h.exact(h.query('shared-root-token'), 2)
            before = state['activations']
            discarded = state['discarded_activations']
            _, second = state['results']
            h.command('search-activation-delay', 1000)
            if fail:
                h.command('search-activation-fail')
            h.command('search-activate', index=0)
            pending = h.probe()
            assert pending['navigation_pending']
            first_serial = pending['activation_serial']
            h.command('search-activate', index=1)
            wait_for(lambda before=before: h.probe()['activations'] == before + 1)
            expected = next(r for r in h.browser()['roots'] if r['id'] == second['root_id'])
            assert h.active()[0]['path'] == str(Path(expected['canonical']) / second['relative_path'])
            state = wait_for(lambda discarded=discarded: p if (p := h.probe())['discarded_activations'] > discarded else None)
            assert state['activation_serial'] == first_serial + 1 and state['activations'] == before + 1
            assert not state['stale'] and state['complete'] and not state['navigation_pending'], state
            assert h.active()[0]['path'] == str(Path(expected['canonical']) / second['relative_path'])
        h.preserved()

    def limits():
        caps = f / 'caps'
        h.write(caps / 'many.txt', 'cap-token\n' * 1300)
        for i in range(180):
            h.write(caps / f'candidate-{i:03}.txt', 'fuzzy filler\n')
        h.open_workspace(caps, folder=True)
        state = h.query('cap-token')
        assert state['status'] == 'incomplete' and not state['complete'] and not state['stale'], state
        assert state['reasons'] == ['result_limit'] and len(state['results']) == 1024, state
        assert 'Incomplete' in state['label'] and 'result_limit' in state['label'], state
        assert state['rows'] == 1026 and state['live_widgets'] < state['rows'], state
        h.screenshot('explicit-result-cap')
        h.evidence['text_cap'] = {k: state[k] for k in ('status', 'reasons', 'rows', 'live_widgets', 'peak_widgets', 'result_limit')}
        state = h.query('candidate', 'quick_open')
        assert state['status'] == 'incomplete' and not state['complete'] and len(state['results']) == 128, state
        assert state['reasons'] == ['result_limit'] and state['rows'] == 128, state
        # A >1 MiB dirty overlay must shadow the small on-disk match. Insertion
        # uses the native edit hook to avoid a million virtual keyboard events.
        huge = h.write(caps / 'oversized.txt', 'oversized-disk-token\n')
        h.open_document(huge)
        h.command('insert', 'x' * (1024 * 1024 + 1))
        state = h.query('oversized-disk-token')
        assert not state['complete'] and state['status'] == 'incomplete' and not state['results'], state
        assert state['omitted_overlays'] == 1 and 'overlay_too_large' in state['reasons'], state
        h.evidence['oversized_overlay'] = {k: state[k] for k in ('reasons', 'overlay_bytes', 'omitted_overlays')}
        h.key('Escape')
        h.key('w', 'ctrl')
        wait_for(lambda: h.probe('workspace')['dialog'])
        h.command('respond', response=1)
        wait_for(lambda: h.document(huge) is None)
        # Binary, invalid UTF-8 and oversize disk omissions are explicit too.
        h.write(caps / 'binary.bin', b'\x00binary-token')
        h.write(caps / 'invalid.txt', b'\xffinvalid-token')
        h.write(caps / 'large.txt', b'large-token\n' + b'x' * (1024 * 1024))
        h.command('workspace-rescan')
        h.browser()
        state = h.query('never-present-query')
        assert not state['complete'] and state['status'] == 'incomplete' and not state['results'], state
        assert {'binary_file', 'invalid_utf8', 'file_too_large'} <= set(state['reasons']), state
        h.evidence['disk_omissions'] = state['reasons']

    def hundred_thousand():
        many = f / 'hundred-thousand'
        many.mkdir()
        began = time.monotonic()
        target = 'unique-acceptance-needle.txt'
        payload = b'ordinary nonempty content\n'
        unique = b'unique-100k-text-token\n'
        stream = b'stream-target-token\n'
        # Exactly 100,000 actual nonempty files, spread over 100 directories to
        # bound flat-directory continuation revalidation costs on slow disks.
        for directory in range(100):
            parent = many / f'dir-{directory:03}'
            parent.mkdir()
            for i in range(1000):
                name = target if directory == 99 and i == 999 else f'file-{i:04}.txt'
                (parent / name).write_bytes(unique if name == target else stream if directory == 0 and i == 0 else payload)
        count = sum(1 for p in many.rglob('*') if p.is_file() and p.stat().st_size > 0)
        assert count == 100000
        h.evidence['fixture'] = {'nonempty_files': count, 'creation_seconds': time.monotonic() - began, 'directories': 100}
        h.open_workspace(many, folder=True)
        baseline = h.rss()
        h.command('search-query', target, mode='quick_open')
        acks = []
        samples = []
        began = time.monotonic()
        while True:
            state = h.probe()
            samples.append(h.rss())
            if not state['active'] and not state['pending']:
                break
            _, elapsed = h.command('workspace-probe')
            acks.append(elapsed)
        h.exact(state, 1, ['dir-099/' + target])
        assert state['progress']['records'] >= 100000 and state['progress']['pages'] >= 400, state
        h.evidence['100k_quick_open'] = {'seconds': time.monotonic() - began, 'progress': state['progress'], 'results': len(state['results'])}
        # Keep an unsaved document outside the workspace and prove exact text,
        # dirty state and revision survive the entire 100k traversal.
        h.key('Escape')
        h.key('n', 'ctrl')
        h.text('protected scratch π🙂')
        doc, _ = h.active()
        assert doc['dirty'] and doc['path'] is None
        h.protected[doc['id']] = doc
        h.command('search-query', 'unique-100k-text-token', mode='text')
        began = time.monotonic()
        while True:
            state = h.probe()
            samples.append(h.rss())
            if not state['active'] and not state['pending']:
                break
            # F11 is real virtual-keyboard input and the ack is emitted in the
            # GTK handler. This is a conservative input-to-ack upper bound.
            _, elapsed = h.command('workspace-probe')
            acks.append(elapsed)
        h.exact(state, 1, ['dir-099/' + target])
        assert state['progress']['files'] == 100000, state
        assert state['progress']['scanned_bytes'] >= len(payload) * 99998 + len(unique) + len(stream), state
        assert len(acks) >= 3 and max(acks) < .250, acks
        assert max(samples) - baseline < 256 * 1024 * 1024 and max(samples) < 768 * 1024 * 1024, (baseline, max(samples))
        h.preserved()
        h.evidence['100k_text'] = {'seconds': time.monotonic() - began, 'scanned_files': state['progress']['files'], 'progress': state['progress'], 'results': len(state['results']), 'rows': state['rows'], 'peak_widgets': state['peak_widgets']}
        h.evidence['responsiveness'] = {'samples': len(acks), 'max_ack_ms': max(acks) * 1000, 'ack_ms': [round(x * 1000, 3) for x in acks], 'rss_baseline': baseline, 'rss_peak': max(samples)}
        h.screenshot('100k-complete')
        # Measure actual editor typing as well as command input. Revision
        # invalidation is expected: the in-flight scan must retire, not publish
        # matches against the pre-keystroke dirty-buffer snapshot.
        scratch = doc
        workspace = h.probe('workspace')
        index = next(i for i, v in enumerate(workspace['views']) if v['document_id'] == scratch['id'])
        h.command('search-query', 'absent-100k-token', mode='text')
        wait_for(lambda: h.probe()['active'])
        h.command('focus-view', index=index)
        assert h.probe()['active'], 'Typing must overlap the real traversal'
        typed_at = time.monotonic()
        h.text(' live-input')
        typed, _ = h.active()
        typing_ack = time.monotonic() - typed_at
        assert typed['id'] == scratch['id'] and typed['text'] == scratch['text'] + ' live-input' and typed['dirty'], typed
        assert typed['revision'] > scratch['revision'] and typing_ack < .250, typing_ack
        h.protected[typed['id']] = typed
        h.evidence['responsiveness']['editor_typing_ack_ms'] = typing_ack * 1000
        state = h.settled()
        assert state['stale'] and not state['results'] and not state['pending'], state
        h.preserved()
        # Activate a displayed result while the real traversal is still running;
        # later batches/completion must not cancel its independently owned path.
        h.command('search-query', 'stream-target-token', mode='text')
        streaming = wait_for(lambda: p if (p := h.probe())['active'] and p['results'] else None)
        chosen = streaming['results'][0]
        h.evidence['mid_stream_activation'] = {'active': streaming['active'], 'batches': streaming['batches'], 'path': chosen['relative_path']}
        h.command('search-activate', index=0)
        wait_for(lambda: h.probe()['activations'] == streaming['activations'] + 1)
        doc, view = h.active()
        assert doc['path'] == str(many / chosen['relative_path'])
        lo, hi = sorted((view['insertion'], view['bound']))
        assert doc['text'][lo:hi] == 'stream-target-token'
        h.settled()
        h.preserved()
        # Read every file back, not just stat: native navigation/search never saves.
        for path in many.rglob('*.txt'):
            expected = unique if path.name == target else stream if path.relative_to(many).as_posix() == 'dir-000/file-0000.txt' else payload
            assert path.read_bytes() == expected, path

    def cancellation_and_close():
        h.open_workspace(manifest)
        # Delayed old query cannot replace the newest pending query.
        h.command('search-delay', 700)
        h.command('search-query', 'shared-root-token', mode='text')
        old = wait_for(lambda: p if (p := h.probe())['active'] else None)
        h.command('search-query', 'never-present-query', mode='text')
        h.command('search-query', 'café needle', mode='text')
        state = h.exact(h.settled(), 1, ['unicode.txt'])
        assert state['generation'] > old['generation'] and state['discarded'] > old['discarded']
        assert state['query'] == 'café needle'
        for action in ('search-cancel', 'escape', 'close-workspace', 'swap'):
            if not h.browser()['roots']:
                h.open_workspace(manifest)
            h.command('search-delay', 1200)
            h.command('search-query', 'shared-root-token', mode='text')
            before = wait_for(lambda: p if (p := h.probe())['active'] else None)
            began = time.monotonic()
            if action == 'escape':
                h.key('Escape')
            elif action == 'swap':
                h.command('open-workspace', empty)
            else:
                h.command(action)
            elapsed = time.monotonic() - began
            assert elapsed < .250, (action, elapsed)
            # Workspace close/swap first retains the automatic project snapshot;
            # cancellation follows retirement, not command acknowledgement.
            state = wait_for(lambda: p if (p := h.probe())['stale'] else None)
            assert state['active'] and state['holds'] == 1 and not state['results'], state
            if action == 'escape':
                assert not state['visible']
            state = h.settled()
            assert state['reaped'] == state['started'] and state['discarded'] > before['discarded'], state
            assert state['stale'] and not state['results'] and not state['pending']
            h.evidence.setdefault('cancellation_ack_ms', {})[action] = elapsed * 1000
            h.preserved()
        h.open_workspace(manifest)
        h.command('search-refresh')
        h.exact(h.settled(), 2)

    def shutdown():
        h.preserved()
        # Discard in-memory edits only through native close dialogs; this makes
        # the final shutdown independent of the number of protected documents.
        h.key('Escape')
        for _ in range(30):
            state = h.probe('workspace')
            dirty = next((d for d in state['documents'] if d['dirty']), None)
            if dirty is None:
                break
            index = next(i for i, v in enumerate(state['views']) if v['document_id'] == dirty['id'])
            h.command('focus-view', index=index)
            h.key('w', 'ctrl')
            wait_for(lambda: h.probe('workspace')['dialog'])
            h.command('respond', response=1)
        assert not any(d['dirty'] for d in h.probe('workspace')['documents'])
        h.command('search-delay', 2000)
        h.command('search-query', 'shared-root-token', mode='text')
        state = wait_for(lambda: p if (p := h.probe())['active'] else None)
        assert state['holds'] == 1
        h.key('q', 'ctrl')
        wait_for(lambda: not any(w['kind'] == 'window' for w in h.ipc.state()))
        assert h.app.proc.poll() is None, 'Window close must retain the delayed search worker hold'
        assert h.app.wait(timeout=10) == 0, h.app.lines[-20:]
        h.no_criticals()
        for path, digest in h.expected.items():
            assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, path
        h.evidence['shutdown'] = {'window_closed_before_worker_exit': True, 'exit_status': 0, 'fixture_files_verified': len(h.expected)}

    scenarios = [routing, keyboard_identity_unicode, overlays, policy_and_staleness,
                 limits, hundred_thousand, overlapping_activation, cancellation_and_close, shutdown]
    for position, scenario in enumerate(scenarios):
        began = time.monotonic()
        print('RUN', scenario.__name__, flush=True)
        record: dict[str, object] = {'name': scenario.__name__}
        try:
            scenario()
            h.no_criticals()
            record['status'] = 'passed'
            print('PASS', scenario.__name__, flush=True)
        except Exception as exc:
            record.update(status='failed', error=str(exc), traceback=traceback.format_exc(), last_probe=h.last.copy())
            print('FAIL', scenario.__name__, str(exc)[:2000], flush=True)
        record['seconds'] = time.monotonic() - began
        h.evidence['checks'].append(record)
        save(h.output, h.evidence)
        if h.app.proc.poll() is not None:
            for blocked in scenarios[position + 1:]:
                h.evidence['checks'].append({'name': blocked.__name__, 'status': 'blocked',
                                             'reason': f'Native process exited during {scenario.__name__}'})
            break
        if record['status'] == 'failed':
            # Retire any failed scenario's scan without concealing its failure.
            h.key('Escape')
            h.settled()
    # Verify fixture integrity even when a source defect aborts later checks.
    for path, digest in h.expected.items():
        assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, path
    h.evidence['fixture_hashes_verified'] = len(h.expected)


def save(output, evidence):
    (output / 'results.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-search')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    began = time.monotonic()
    evidence = {'checks': [], 'status': 'running', 'measurement_note': 'Real Wayland key input to GTK handler acknowledgement; not paint/frame latency. Quick-open enumerates paths (progress.records), text reads files (progress.files).',
                'limits': {'native_runtime_seconds': 540, 'input_ack_ms': 250, 'text_results': 1024, 'fuzzy_results': 128, 'live_widgets': 256, 'rss_growth_bytes': 256 * 1024 * 1024, 'rss_absolute_bytes': 768 * 1024 * 1024}}
    try:
        with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
            session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
            h = Harness(session, args.binary.resolve(), output, evidence)
            run(h)
        evidence['status'] = 'passed' if len(evidence['checks']) == 9 and all(c['status'] == 'passed' for c in evidence['checks']) else 'failed'
    except Exception:
        evidence.update(status='failed', fatal=traceback.format_exc())
        raise
    finally:
        evidence['seconds'] = time.monotonic() - began
        save(output, evidence)
    print(f"{evidence['status'].upper()}: {sum(c['status'] == 'passed' for c in evidence['checks'])}/9 native search groups; {output / 'results.json'}", flush=True)
    return 0 if evidence['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
