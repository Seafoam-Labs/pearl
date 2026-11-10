#!/usr/bin/env python3
"""Native M2 explorer acceptance: 100k flat files, nested tree and live policy.
Real GTK/Wayland, real GTask/page/monitor paths, real keyboard input. Loop gaps
and command acknowledgement are not frame/paint latency measurements.
"""
import argparse
import json
import statistics
import sys
import threading
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, wait_for, fixture_prefix
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=PEARL / '.cache/coral-explorer')
    parser.add_argument('--aqueous-prefix', type=Path, default=fixture_prefix())
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks, evidence = [], {}
    with PrivateSession(output / 'session', tool_prefix=args.aqueous_prefix) as session:
        session.env.update(GSETTINGS_BACKEND='memory', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LANGUAGE='en_US')
        ipc = IPC(session)
        fixtures = Path(session.env['XDG_CONFIG_HOME']) / 'explorer-fixtures'
        flat, live, offline = fixtures / 'flat', fixtures / 'live', fixtures / 'offline'
        flat.mkdir(parents=True)
        live.mkdir()
        # One directory really contains 100,000 regular files. No stand-in model.
        for i in range(100000):
            (flat / f'file-{i:06}.txt').touch()
        nested = live / 'nested'
        nested.mkdir()
        (nested / 'keep.txt').write_text('nested kept\n')
        (nested / 'hide.tmp').write_text('inherited rule\n')
        (nested / '.gitignore').write_text('!keep.txt\n')
        (live / '.gitignore').write_text('*.tmp\n')
        (live / 'excluded.txt').write_text('manifest final hide\n')
        for i in range(20):
            directory = live / f'branch-{i:02}'
            directory.mkdir()
            for j in range(300):
                (directory / f'child-{j:04}.txt').touch()
        hidden = live / 'hidden'
        hidden.mkdir()
        (hidden / '.gitignore').write_text('*\n')
        for i in range(5000):
            (hidden / f'ignored-{i:04}.tmp').touch()
        manifest = fixtures / 'explorer.coral-workspace'
        spec = {'version': 1, 'roots': [{'path': 'flat'}, {'path': 'live'}, {'path': 'offline'}], 'exclude': ['excluded.txt']}
        manifest.write_text(json.dumps(spec))
        empty = fixtures / 'empty.coral-workspace'
        empty.write_text('{"version":1,"roots":[]}')
        command_path = fixtures / 'command.ini'
        session.env['CORAL_TEST_COMMAND'] = str(command_path)
        app = session.child('coral-explorer', [args.binary.resolve()], G_DEBUG='fatal-criticals')
        window = wait_for(lambda: next((w for w in ipc.state() if w['kind'] == 'window'), None))
        ipc.call('command', action='window.activate', fields={'id': window['id']})

        def key(name, *mods):
            cmd = ['wtype', '-s', '20']
            for mod in mods:
                cmd += ['-M', mod]
            cmd += ['-k', name]
            for mod in reversed(mods):
                cmd += ['-m', mod]
            session.run(cmd + ['-s', '40'])

        def command(action, value=None, **fields):
            start = len(app.lines)
            content = '[Test]\naction=' + action + '\n'
            if value is not None:
                content += 'value=' + str(value) + '\n'
            content += ''.join(f'{k}={v}\n' for k, v in fields.items())
            command_path.write_text(content)
            began = time.monotonic()
            key('F11')
            wait_for(lambda: app.proc.poll() is not None or any('CORAL_COMMAND_DONE' in line for line in app.lines[start:]))
            assert app.proc.poll() is None, app.lines[-45:]
            return app.lines[start:], time.monotonic() - began

        def probe(browser=True):
            assert app.proc.poll() is None, app.lines[-30:]
            prefix = 'CORAL_BROWSER ' if browser else 'CORAL_WORKSPACE '
            lines, _ = command('browser-probe' if browser else 'workspace-probe')
            return json.loads(next(line[len(prefix):] for line in lines if line.startswith(prefix)))

        def settled():
            return wait_for(lambda: p if not (p := probe())['pending'] and not p['loading'] and not p['scanning'] else None)

        def names():
            return {e['name'] for e in settled()['entries']}

        def browse(root, relative=''):
            command('workspace-roots')
            command('browser-activate', index=root)
            settled()
            if relative:
                state = settled()
                index = next(i for i, entry in enumerate(state['entries']) if entry['name'] == relative)
                command('browser-activate', index=index)
            return settled()

        def passed(label):
            assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-30:]
            checks.append(label)
            print('PASS', label, flush=True)

        def rss():
            status = Path(f'/proc/{app.proc.pid}/status').read_text()
            return int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmRSS:'))) * 1024

        # Exact initial-load regression: no pre-existing workspace/watch can
        # notice this edit. The first read completes before its delayed callback.
        review_root = fixtures / 'review-root'
        review_root.mkdir()
        (review_root / 'secret.txt').write_text('must be hidden\n')
        (review_root / 'visible.txt').write_text('visible\n')
        race_manifest = fixtures / 'initial-race.coral-workspace'
        race_spec = {'version': 1, 'roots': [{'path': 'review-root'}]}
        race_manifest.write_text(json.dumps(race_spec))
        assert not settled()['roots']
        command('explorer-delay')
        command('open-workspace', race_manifest)
        assert probe()['loading']
        race_spec['exclude'] = ['secret.txt']
        race_manifest.write_text(json.dumps(race_spec))
        settled()
        state = browse(0)
        assert 'secret.txt' not in names() and 'visible.txt' in names(), state
        assert not state['watch_fallback'], state
        passed('Initial manifest snapshot edited before first watch registration is revalidated before publication')

        links, policies = fixtures / 'links', fixtures / 'policies'
        links.mkdir()
        policies.mkdir()
        lexical_root = links / 'data'
        lexical_root.mkdir()
        (lexical_root / 'secret.txt').write_text('lexical root\n')
        (lexical_root / 'visible.txt').write_text('lexical root\n')
        target = policies / 'policy.json'
        linked = links / 'test.coral-workspace'
        linked.symlink_to('../policies/policy.json')
        link_spec = {'version': 1, 'roots': [{'path': 'data'}], 'exclude': ['secret.txt']}
        target.write_text(json.dumps(link_spec))
        command('open-workspace', linked)
        state = settled()
        assert state['roots'][0]['canonical'] == str(lexical_root)
        state = browse(0)
        assert names() == {'visible.txt'} and not state['watch_fallback']
        link_spec['exclude'] = []
        target.write_text(json.dumps(link_spec))
        wait_for(lambda: names() == {'secret.txt', 'visible.txt'})
        replacement = policies / 'replacement.json'
        link_spec['exclude'] = ['secret.txt']
        replacement.write_text(json.dumps(link_spec))
        replacement.replace(target)
        wait_for(lambda: names() == {'visible.txt'})
        alternate = policies / 'alternate.json'
        link_spec['exclude'] = ['visible.txt']
        alternate.write_text(json.dumps(link_spec))
        new_link = links / 'new-link'
        new_link.symlink_to('../policies/alternate.json')
        new_link.replace(linked)
        wait_for(lambda: names() == {'secret.txt'})
        assert settled()['roots'][0]['canonical'] == str(lexical_root)
        command('explorer-watch-fail')
        settled()
        link_spec['exclude'] = ['secret.txt']
        alternate.write_text(json.dumps(link_spec))
        command('workspace-rescan')
        assert names() == {'visible.txt'}
        command('explorer-watch-restore')
        assert not settled()['watch_fallback']
        passed('Symlink manifests track target writes, atomic replacement and link retarget; Rescan rereads policy and keeps the lexical relative-root base')
        hop = policies / 'hop.json'
        hop.symlink_to('alternate.json')
        new_link.symlink_to('../policies/hop.json')
        new_link.replace(linked)
        command('open-workspace', linked)
        settled()
        browse(0)
        assert names() == {'visible.txt'}
        link_spec['exclude'] = ['visible.txt']
        target.write_text(json.dumps(link_spec))
        next_hop = policies / 'next-hop'
        next_hop.symlink_to('policy.json')
        next_hop.replace(hop)
        wait_for(lambda: names() == {'secret.txt'})
        assert settled()['roots'][0]['canonical'] == str(lexical_root)
        passed('Intermediate manifest symlink retarget is observed, not just the lexical link and final target')

        # Hold the registration worker, not GTK. Change policy inside the exact
        # registration/read gap; no candidate roots/pages may be published yet.
        command('close-workspace')
        settled()
        race_spec['exclude'] = []
        race_manifest.write_text(json.dumps(race_spec))
        command('explorer-watch-delay')
        command('open-workspace', race_manifest)
        wait_for(lambda: probe()['watch_worker_busy'])
        waiting = probe()
        assert waiting['loading'] and not waiting['roots'] and not waiting['entries'], waiting
        race_spec['exclude'] = ['secret.txt']
        race_manifest.write_text(json.dumps(race_spec))
        _, registration_ack = command('workspace-probe')
        assert registration_ack < .250
        settled()
        state = browse(0)
        assert names() == {'visible.txt'} and not state['watch_fallback'], state
        passed('A delayed watch installation never publishes its pre-registration policy snapshot; native input stays responsive')

        before_builds = settled()['watch_builds']
        command('explorer-watch-storm')
        state = probe()
        assert state['watch_worker_limit'] == 1 and state['watch_queue_depth'] <= 1
        assert state['watch_queued_bytes'] <= state['watch_plan_byte_limit'] == 128 * 1024
        assert state['in_flight'] <= 8 and state['request_bytes'] <= 128 * 1024
        watch_ack = []
        for _ in range(3):
            _, elapsed = command('workspace-probe')
            watch_ack.append(elapsed)
        assert max(watch_ack) < .250
        assert probe()['watch_worker_busy'], 'Delayed worker must still own its plan/handles at cancellation'
        _, watch_cancel_ack = command('close-workspace')
        assert watch_cancel_ack < .250, watch_cancel_ack
        state = wait_for(lambda: p if not (p := probe())['roots'] else None)
        assert not state['entries'] and state['watch_worker_busy'], state
        # Replace its desired generation while the old blocking call is still in
        # flight. Old handles remain worker-owned; no GTK fd close/reuse occurs.
        command('open-workspace', race_manifest)
        state = settled()
        assert state['manifest'] == str(race_manifest)
        browse(0)
        assert names() == {'visible.txt'}
        evidence.update(watch_registration_ack_ms=1000 * registration_ack,
                        watch_storm_input_max_ms=1000 * max(watch_ack),
                        watch_cancel_ui_ack_ms=1000 * watch_cancel_ack,
                        watch_storm_builds=state['watch_builds'] - before_builds)
        passed('64 delayed registration requests coalesce to one worker/one queued plan; close/reopen cancels UI promptly and ignores stale watch generations')
        command('close-workspace')
        previous_scans = settled()['scans_started']
        command('open-workspace', manifest)
        initial = settled()
        assert len(initial['roots']) == 3 and initial['scans_started'] == previous_scans
        assert initial['resident_pages'] == 0 and initial['node_count'] == 3
        assert initial['roots'][2]['availability'] == 'missing'
        passed('Opening a workspace watches roots but enumerates no unopened directory')
        key('n', 'ctrl')
        session.run(['wtype', '-s', '40', '--', 'dirty before paging\n'])
        baseline_docs = probe(False)['documents']
        dirty_id = next(d['id'] for d in baseline_docs if d['dirty'])
        baseline_rss = rss()
        # Actual GtkListView activate signal, not a standalone filesystem harness.
        command('explorer-activate', index=0)
        first = settled()
        assert len(first['entries']) == 256 and not first['complete']
        all_names = [e['name'] for e in first['entries']]
        start_lines = len(app.lines)
        started = time.monotonic()
        command('explorer-drain')
        acknowledgement = []
        peak_rss = baseline_rss
        for i in range(12):
            session.run(['wtype', '-s', '40', '--', f'input-{i} '])
            _, elapsed = command('workspace-probe')
            acknowledgement.append(elapsed)
            peak_rss = max(peak_rss, rss())
        deadline = time.monotonic() + 120
        while True:
            state = probe()
            peak_rss = max(peak_rss, rss())
            assert state['resident_pages'] <= 8 and state['resident_bytes'] <= 1024 * 1024
            assert state['in_flight'] <= 8 and state['request_bytes'] <= 128 * 1024
            if not state['draining'] and not state['pending']:
                break
            assert time.monotonic() < deadline, state
            time.sleep(.1)
        page_count = 1
        for line in app.lines[start_lines:]:
            if line.startswith('CORAL_EXPLORER_PAGE '):
                page = json.loads(line.removeprefix('CORAL_EXPLORER_PAGE '))
                assert len(page['entries']) <= 256
                all_names.extend(e['name'] for e in page['entries'])
                page_count += 1
        assert len(all_names) == len(set(all_names)) == 100000
        assert set(all_names) == {f'file-{i:06}.txt' for i in range(100000)}
        assert state['complete'] and state['peak_widgets'] < 256, state
        assert peak_rss - baseline_rss < 128 * 1024 * 1024, (baseline_rss, peak_rss)
        assert max(acknowledgement) < .250, acknowledgement
        dirty = next(d for d in probe(False)['documents'] if d['id'] == dirty_id)
        assert dirty['dirty'] and dirty['text'] == 'dirty before paging\n' + ''.join(f'input-{i} ' for i in range(12)), dirty
        evidence.update(flat_files=100000, nested_files=11002, pages=page_count,
                        page_seconds=time.monotonic() - started, baseline_rss=baseline_rss,
                        peak_rss=peak_rss, peak_row_widgets=state['peak_widgets'],
                        resident_page_bytes=state['resident_bytes'],
                        input_ack_max_ms=1000 * max(acknowledgement),
                        input_ack_median_ms=1000 * statistics.median(acknowledgement),
                        main_loop_gap_max_ms=state['loop_gap_us'] / 1000)
        session.run(['grim', output / '100k-paged.png'])
        passed('100,000 flat filenames reached exactly once; bounded virtualized rows/RSS and real typing preserved during paging')
        passed('Native input acknowledgement under 250 ms during paging; loop probe is not paint latency')

        # Opening a file from the final window uses the unchanged root-bound path.
        last_name = state['entries'][-1]['name']
        command('browser-activate', index=len(state['entries']) - 1)
        wait_for(lambda: any(d['path'] == str(flat / last_name) for d in probe(False)['documents']))
        session.run(['wtype', '-s', '40', '--', 'dirty last page'])
        protected = probe(False)['documents']
        command('explorer-watch-fail')
        state = settled()
        assert not state['complete'] and state['offset'] == 0
        previous_resets = state['resets']
        (flat / 'added-after-cookie.txt').touch()
        command('browser-more')
        state = settled()
        assert state['resets'] > previous_resets and state['offset'] == 0, state
        command('explorer-watch-restore')
        settled()
        passed('Backend reset_required discards the old window and restarts from a null continuation even without monitor delivery')
        state = browse(1, 'hidden')
        assert not state['entries'] and not state['complete'], state
        command('browser-more')
        state = settled()
        assert not state['entries'] and state['complete'], state
        passed('Empty incomplete pages retain a reachable Load more action until all 5,000 ignored records are consumed')
        state = browse(1)
        assert 'excluded.txt' not in names()
        state = browse(1, 'nested')
        assert 'keep.txt' in names() and 'hide.tmp' not in names()
        selected = state['selected_path']
        old_ids = [r['id'] for r in state['roots']]
        command('open-workspace', manifest)
        state = settled()
        assert [r['id'] for r in state['roots']] == old_ids
        assert state['relative'] == 'nested' and state['selected_path'] == selected
        assert any(n['path'] == 'nested' and n['expanded'] for n in state['directories'])
        passed('Inherited .gitignore and final Model.exclude applied; reopening same workspace preserves root IDs and expanded/selected paths')
        # Collapse/reexpand the actual GtkListView root row. The first root is
        # still expanded, so find the second root from the bounded directory data.
        command('explorer-reset')
        state = settled()
        assert state['scans_started'] >= 1 and state['resident_pages'] == 0
        command('explorer-activate', index=1)
        state = settled()
        nested_index = next(i for i, entry in enumerate(state['entries']) if entry['name'] == 'nested')
        command('explorer-activate', index=2 + nested_index)
        state = settled()
        assert state['relative'] == 'nested'
        remembered = state['selected_path']
        before_scans = state['scans_started']
        command('explorer-activate', index=1)
        assert not next(n for n in settled()['directories'] if n['root'] == old_ids[1] and n['path'] == '')['expanded']
        command('explorer-activate', index=1)
        state = settled()
        assert state['scans_started'] == before_scans and state['selected_path'] == remembered
        assert next(n for n in state['directories'] if n['path'] == 'nested')['expanded']
        browse(1, 'nested')
        passed('Native tree controls collapse/reexpand lazily without rescanning or losing descendant expansion/selection')

        (nested / 'created.txt').write_text('created\n')
        wait_for(lambda: 'created.txt' in names())
        (nested / 'created.txt').rename(nested / 'renamed.txt')
        wait_for(lambda: 'renamed.txt' in names() and 'created.txt' not in names())
        (nested / 'renamed.txt').unlink()
        wait_for(lambda: 'renamed.txt' not in names())
        (live / '.gitignore').write_text('*.tmp\nkeep.txt\n')
        # Child negation overrides inherited rule.
        wait_for(lambda: 'keep.txt' in names())
        (nested / '.gitignore').write_text('')
        wait_for(lambda: 'keep.txt' not in names())
        (live / '.gitignore').write_text('')
        wait_for(lambda: {'keep.txt', 'hide.tmp'} <= names())
        # A failed ignore read clears old pages; it must never mean "ignore disabled".
        (nested / '.gitignore').unlink()
        (nested / '.gitignore').symlink_to(live / '.gitignore')
        wait_for(lambda: not names() and any(n['path'] == 'nested' and n['err'] for n in probe()['directories']))
        (nested / '.gitignore').unlink()
        (nested / '.gitignore').write_text('')
        wait_for(lambda: 'keep.txt' in names())
        spec['exclude'] = ['excluded.txt', 'nested/keep.txt']
        manifest.write_text(json.dumps(spec))
        wait_for(lambda: 'keep.txt' not in names() and 'hide.tmp' in names())
        assert [r['id'] for r in settled()['roots']] == old_ids
        manifest.write_text('{')
        wait_for(lambda: probe()['error_name'] == 'InvalidSchema')
        assert settled()['resident_pages'] == 0
        command('explorer-reset')
        assert settled()['resident_pages'] == 0 and probe()['error_name'] == 'InvalidSchema'
        manifest.write_text(json.dumps(spec))
        wait_for(lambda: 'keep.txt' not in names() and 'hide.tmp' in names())
        assert [r['id'] for r in settled()['roots']] == old_ids
        passed('Live create/delete/rename, inherited ignore edits and manifest policy changes invalidate loaded descendants; policy errors fail closed')

        before = settled()['scans_started']
        def storm():
            for i in range(80):
                (nested / 'storm.txt').write_text(str(i))
                time.sleep(.01)
        thread = threading.Thread(target=storm)
        thread.start()
        during = []
        while thread.is_alive():
            _, elapsed = command('workspace-probe')
            during.append(elapsed)
        thread.join()
        wait_for(lambda: 'storm.txt' in names())
        after = settled()['scans_started']
        assert after - before < 25, (before, after)
        assert max(during) < .250, during
        evidence.update(storm_scans=after - before, storm_input_max_ms=1000 * max(during))
        passed('Continuous monitor bursts coalesce to bounded per-node reloads while native input remains responsive')

        moved = fixtures / 'live-moved'
        live.rename(moved)
        wait_for(lambda: not names() and any(n['err'] for n in probe()['directories'] if n['path'] == 'nested'))
        moved.rename(live)
        wait_for(lambda: 'hide.tmp' in names())
        offline.mkdir()
        (offline / 'online.txt').write_text('back online\n')
        state = browse(2)
        assert 'online.txt' in names()
        assert state['roots'][2]['id'] == old_ids[2]
        passed('Lost roots and previously unavailable roots return through bounded parent watches without replacing root IDs')

        command('explorer-watch-fail')
        state = settled()
        assert state['watch_fallback'] and 'use Rescan' in state['status'] and state['watches'] == 0
        (offline / 'manual.txt').write_text('manual\n')
        time.sleep(.2)
        assert 'manual.txt' not in names()
        command('workspace-rescan')
        assert 'manual.txt' in names()
        command('explorer-watch-restore')
        assert not settled()['watch_fallback']
        passed('Injected monitor-registration failure is visible and explicit manual Rescan remains functional')
        before = settled()
        command('explorer-overflow')
        state = settled()
        assert state['overflows'] == before['overflows'] + 1
        assert state['scans_started'] > before['scans_started']
        assert 'manual.txt' in names()
        assert [r['id'] for r in state['roots']] == old_ids
        passed('Injected raw IN_Q_OVERFLOW rebuilds bounded watches and invalidates accessed pages plus manifest policy without eager traversal')

        # Delayed worker has already acquired a page but may not install after close.
        command('explorer-delay')
        command('workspace-rescan')
        wait_for(lambda: probe()['pending'] > 0)
        _, cancel_elapsed = command('close-workspace')
        assert cancel_elapsed < .250, cancel_elapsed
        # Project retirement durably retains the previous snapshot before the
        # close clears roots; command acknowledgement is not completion.
        state = wait_for(lambda: p if not (p := probe())['roots'] else None)
        assert not state['entries'], state
        settled()
        command('open-workspace', manifest)
        settled()
        command('browser-swap-race', empty)
        state = settled()
        assert not state['roots'] and not state['entries'] and state['manifest'] == str(empty)
        assert probe(False)['documents'] == protected
        evidence['cancel_ui_ack_ms'] = cancel_elapsed * 1000
        passed('Close acknowledges within 250 ms, retains cancelled worker storage until callback, ignores old-model pages and preserves exact dirty documents')
        command('open-workspace', race_manifest)
        settled()
        command('explorer-watch-delay', 2000)
        command('workspace-rescan')
        wait_for(lambda: probe()['watch_worker_busy'])
        key('q', 'ctrl')
        refused = probe(False)
        assert refused['notice'] == 'Quit All could not freeze project sessions: Loading. All windows kept open.', refused
        assert refused['documents'] == protected and not refused['dialog'], refused
        assert probe()['watch_worker_busy'] and app.proc.poll() is None
        settled()
        wait_for(lambda: not probe()['watch_worker_busy'])
        key('q', 'ctrl')
        for _ in range(sum(d['dirty'] for d in protected)):
            wait_for(lambda: probe(False)['dialog'])
            assert probe(False)['documents'] == protected
            command('respond', response=1)
        wait_for(lambda: not any(w['kind'] == 'window' for w in ipc.state()))
        assert app.wait(timeout=15) == 0, app.lines[-30:]
        assert not any('CRITICAL' in line or 'panic:' in line for line in app.lines), app.lines[-30:]
        passed('Window shutdown refuses unresolved watch/model installation, preserves dirty documents through every prompt, and drains handles before App destruction')
    evidence.update(checks=checks, limits={'directory_states': 64, 'page_entries': 256,
                    'resident_pages': 8, 'resident_page_arena_bytes': 1024 * 1024,
                    'watches': 128, 'workers': 8, 'watch_workers': 1, 'queued_watch_plans': 1,
                                        'watch_plan_string_bytes': 128 * 1024, 'request_path_bytes': 128 * 1024,
                    'debounce_ms': 100, 'max_debounce_ms': 500},
                    measurement_note='Input ack and main-loop probe are not paint/frame latency; pages are windows, not a global sort.')
    (output / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'Passed {len(checks)} native explorer check groups.', flush=True)


if __name__ == '__main__':
    main()
