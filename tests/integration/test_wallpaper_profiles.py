#!/usr/bin/env python3
"""Live wallpaper/profile acceptance, entirely in a private desktop and XDG roots."""
import argparse
import hashlib
import json
import platform
import shutil
import statistics
import time
from pathlib import Path
from PIL import Image
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, clean
from test_settings_appearance import settled
from test_custom_themes import Peer
from test_surfaces import ctl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--spike', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/matugen-wallpaper-live')
    args = parser.parse_args()
    args.pearl = args.pearl.resolve()
    args.ctl = args.ctl.resolve()
    args.spike = args.spike.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    checks, timings = [], {}

    def passed(name):
        checks.append(name)
        print('PASS', name, flush=True)

    with PrivateSession(args.output/'session', tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        mode, calls = s.base/'mode', s.base/'calls'
        mode.write_text('pass'); calls.write_text('')
        s.env.update(PATH=str(ROOT/'tests/fixtures/theme')+':'+s.env['PATH'],
                     PEARL_TEST_GENERATOR_MODE=str(mode), PEARL_TEST_GENERATOR_LOG=str(calls))
        profiles = Path(s.env['XDG_DATA_HOME'])/'pearl/matugen/profiles'
        shutil.copytree(ROOT/'themes/profiles', profiles)
        wallpaper = s.base/'wallpaper.png'
        Image.new('RGB', (64, 64), '#ff0000').save(wallpaper)
        ipc = IPC(s)
        shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = Peer(s, ipc); settled(peer)
        config = Path(s.env['XDG_CONFIG_HOME'])
        installed = config/'zed/themes/pearl-seafoam.zed-theme.json'

        def apply(**changes):
            prefs = json.loads(peer.document('committed'))
            for key, value in changes.items():
                prefs[key].update(value)
            peer.keep(json.dumps(prefs))
            result = peer.action('apply')
            assert result['state'] == 'succeeded', result
            state = settled(peer)
            assert not state['validation'], state
            return state

        def generated():
            return [json.loads(line) for line in calls.read_text().splitlines()]

        def refresh(color, *, atomic=False, size=64):
            old = installed.read_bytes()
            start = time.monotonic()
            path = wallpaper.with_name('incoming.png') if atomic else wallpaper
            Image.new('RGB', (size, size), color).save(path)
            if atomic:
                path.replace(wallpaper)
            wait_for(lambda: installed.read_bytes() != old, 20)
            state = settled(peer)
            assert state['applications']['applied_generation'] == state['applications']['desired_generation'], state
            return (time.monotonic()-start)*1000

        catalog = peer.theme('profiles_catalog')
        state = apply(theme=dict(mode='dynamic', source='wallpaper'),
                      wallpaper=dict(mode='cover', path=str(wallpaper)),
                      matugen=dict(enabled=True, catalog_revision=catalog['revision'], colors=dict(source='follow_pearl', seed='#6750a4'),
                                   applications={app: dict(mode='profile', profile_id='seafoam.'+app)
                                                 for app in ('zed', 'equibop', 'fluxer', 'starship', 'steam')}))
        assert installed.exists(), state
        passed('committed-path-renders-all-five-profiles')
        committed = peer.document('committed')
        disk = (config/'pearl/preferences.json').read_bytes()
        revision = peer.state()['revision']
        before_calls = len(generated())
        timings['cold_small_ms'] = [refresh('#00ff00')]
        new_calls = generated()[before_calls:]
        assert sum('image' in c['argv'] for c in new_calls) == 1, new_calls
        assert sum('json' in c['argv'] for c in new_calls) == 5, new_calls
        assert peer.state()['revision'] == revision and peer.document('committed') == committed
        assert (config/'pearl/preferences.json').read_bytes() == disk
        passed('in-place-change-shares-extraction-and-preserves-preference-revision')
        timings['cold_small_ms'].append(refresh('#0000ff', atomic=True))
        passed('atomic-replacement')

        # A wallpaper event must not consume the open shared Settings draft.
        draft = json.loads(committed); draft['font_size'] = 19
        peer.keep(json.dumps(draft))
        draft_revision = peer.state()['draft_revision']
        refresh('#eeaa00')
        assert peer.state()['dirty'] and not peer.state()['conflict']
        assert peer.state()['draft_revision'] == draft_revision
        assert json.loads(peer.document())['font_size'] == 19
        peer.action('discard'); settled(peer)
        passed('dirty-draft-survives-refresh')

        old = installed.stat().st_mtime_ns
        before_calls = len(generated())
        wallpaper.write_bytes(wallpaper.read_bytes())
        time.sleep(.9); settled(peer)
        assert len(generated()) == before_calls and installed.stat().st_mtime_ns == old
        idle_jobs = ctl(s, args.ctl, 'preferences', 'status')['result']['jobs']
        time.sleep(.5)
        assert ctl(s, args.ctl, 'preferences', 'status')['result']['jobs'] == idle_jobs
        assert len(generated()) == before_calls
        passed('same-content-no-render-no-output-write-and-idle')

        # Changes to mutable profile assets must never be adopted by live refresh.
        template = profiles/'seafoam.zed/template.json'
        original_template = template.read_bytes()
        template.write_text('invalid template {{')
        refresh('#ff00ff')
        assert 'Seafoam' in installed.read_text()
        peer.theme('application_retry', revision=peer.state()['revision'])
        template.write_bytes(original_template)
        passed('refresh-and-retry-use-committed-template-bytes')

        # Delay extraction, then supersede it. Cancellation must beat the ten-second fixture.
        mode.write_text('slow')
        before_calls = len(generated())
        Image.new('RGB', (64, 64), '#123456').save(wallpaper)
        wait_for(lambda: len(generated()) > before_calls, 5)
        mode.write_text('pass')
        elapsed = refresh('#00ffff', atomic=True)
        assert elapsed < 5000, elapsed
        before = installed.read_bytes()
        time.sleep(.6)
        assert installed.read_bytes() == before
        passed('obsolete-extraction-cancelled-latest-generation-wins')

        # Delay template rendering specifically, after the palette has been extracted.
        mode.write_text('slow-render')
        before_calls = len(generated())
        Image.new('RGB', (64, 64), '#445511').save(wallpaper)
        wait_for(lambda: any('json' in c['argv'] for c in generated()[before_calls:]), 8)
        mode.write_text('pass')
        assert refresh('#ab2255', atomic=True) < 5000
        passed('obsolete-template-render-cancelled')

        before = installed.read_bytes()
        wallpaper.write_bytes(b'partial image')
        wait_for(lambda: peer.state()['error_code'] is not None, 10)
        settled(peer)
        assert installed.read_bytes() == before
        refresh('#337799')
        assert not peer.state()['error_code']
        passed('invalid-image-retains-last-good-and-recovers')

        apply(theme=dict(mode='static'), wallpaper=dict(mode='solid'),
              matugen=dict(colors=dict(source='wallpaper', seed='#6750a4'), snapshot_digest='', catalog_revision=''))
        refresh('#998833')
        passed('application-only-wallpaper-colors-with-solid-shell')
        apply(matugen=dict(colors=dict(source='seed', seed='#6750a4'), snapshot_digest=''), wallpaper=dict(mode='cover'))
        before_calls = len(generated()); before = installed.read_bytes()
        Image.new('RGB', (64, 64), '#998855').save(wallpaper)
        time.sleep(.9); settled(peer)
        assert installed.read_bytes() == before and len(generated()) == before_calls
        passed('seed-colors-ignore-wallpaper-change')
        for shell_mode in ('static', 'gtk'):
            apply(theme=dict(mode=shell_mode, gtk_name=''), matugen=dict(colors=dict(source='follow_pearl', seed='#6750a4'), snapshot_digest=''))
            before = installed.read_bytes(); before_calls = len(generated())
            Image.new('RGB', (64, 64), '#112244' if shell_mode == 'gtk' else '#554411').save(wallpaper)
            time.sleep(.7); settled(peer)
            assert installed.read_bytes() == before and len(generated()) == before_calls
        apply(theme=dict(mode='dynamic', source='seed', seed='#225599'), matugen=dict(snapshot_digest=''))
        before = installed.read_bytes(); before_calls = len(generated())
        Image.new('RGB', (64, 64), '#114455').save(wallpaper)
        time.sleep(.7); settled(peer)
        assert installed.read_bytes() == before and len(generated()) == before_calls
        passed('follow-pearl-static-gtk-and-seed-do-not-use-wallpaper-colors')
        apply(theme=dict(mode='gtk'), matugen=dict(colors=dict(source='wallpaper', seed='#6750a4'), snapshot_digest=''))
        refresh('#2233aa')
        passed('independent-wallpaper-colors-in-gtk-mode')

        # Force reload also resolves new input while retaining the same preference digest.
        before = installed.read_bytes()
        Image.new('RGB', (64, 64), '#66bb11').save(wallpaper)
        ctl(s, args.ctl, 'preferences', 'reload')
        wait_for(lambda: installed.read_bytes() != before, 15); settled(peer)
        passed('explicit-reload-refreshes-colors-with-committed-snapshot')

        before = installed.read_bytes()
        wallpaper.unlink()
        wait_for(lambda: peer.state()['error_code'] is not None, 10); settled(peer)
        assert installed.read_bytes() == before
        refresh('#22bb66')
        passed('deleted-wallpaper-recreation-recovers')

        apply(theme=dict(mode='dynamic', source='wallpaper'), matugen=dict(colors=dict(source='follow_pearl', seed='#6750a4'), snapshot_digest=''))
        # Warm both palettes and all five render caches, then measure alternating hits.
        refresh('#aa0000'); refresh('#00aa00')
        timings['cached_small_ms'] = [refresh(c) for c in ('#aa0000', '#00aa00', '#aa0000', '#00aa00')]
        timings['cold_large_ms'] = [refresh(c, size=2048) for c in ('#669922', '#8866bb', '#bb5522')]
        passed('cached-and-cold-latency-measured')
        # A file can change before the newly selected path has an active watch.
        candidate = s.base/'candidate.png'
        Image.new('RGB', (64, 64), '#220044').save(candidate)
        prefs = json.loads(peer.document('committed')); prefs['wallpaper']['path'] = str(candidate)
        peer.keep(json.dumps(prefs)); mode.write_text('slow')
        before_calls = len(generated())
        assert peer.action('apply', wait=False)['state'] == 'pending'
        wait_for(lambda: len(generated()) > before_calls, 5)
        mode.write_text('pass')
        Image.new('RGB', (64, 64), '#44cc88').save(candidate)
        settled(peer)
        wallpaper = candidate
        empty_config = s.base/'empty-matugen.toml'; empty_config.write_text('[config]\n[templates]\n')
        expected = json.loads(s.run(['/usr/bin/matugen', '--config', str(empty_config), '--dry-run', '--json', 'hex', '--source-color-index', '0', '--mode', 'dark', 'image', str(wallpaper)]).stdout)
        runtime = json.loads((config/'pearl/matugen/runtime.json').read_text())
        actual = json.loads(runtime['snapshot']['render_json'])
        assert actual['colors'] == expected['colors']
        passed('new-path-change-during-extraction-is-rechecked-before-commit')

        mode.write_text('slow-render'); before_calls = len(generated())
        Image.new('RGB', (64, 64), '#a12244').save(wallpaper)
        wait_for(lambda: any('json' in c['argv'] for c in generated()[before_calls:]), 8)
        external = s.base/'during-render.png'
        Image.new('RGB', (64, 64), '#448822').save(external)
        mode.write_text('pass'); before = installed.read_bytes()
        prefs = json.loads(peer.document('committed')); prefs['wallpaper']['path'] = str(external)
        started = time.monotonic()
        (config/'pearl/preferences.json').write_text(json.dumps(prefs))
        wait_for(lambda: installed.read_bytes() != before, 5); settled(peer)
        assert time.monotonic() - started < 5
        wallpaper = external
        passed('external-preference-change-cancels-obsolete-render')
        # Locking cancels publication; a newer locked input is applied on unlock.
        before = installed.read_bytes(); before_calls = len(generated())
        mode.write_text('slow-render')
        Image.new('RGB', (64, 64), '#331155').save(wallpaper)
        wait_for(lambda: any('json' in c['argv'] for c in generated()[before_calls:]), 8)
        locker = s.child('locker', [args.spike], input_pipe=True, PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', PEARL_T00_MODE='plain')
        locker.expect('T00 event=ready')
        locker.proc.stdin.write('lock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=locked')
        wait_for(lambda: peer.state()['locked']); settled(peer)
        mode.write_text('pass')
        Image.new('RGB', (64, 64), '#115533').save(wallpaper)
        time.sleep(.7); settled(peer)
        assert installed.read_bytes() == before
        locker.proc.stdin.write('unlock\n'); locker.proc.stdin.flush(); locker.expect('T00 event=unlocked')
        wait_for(lambda: installed.read_bytes() != before, 15); settled(peer)
        locker.proc.stdin.write('quit\n'); locker.proc.stdin.flush(); locker.proc.wait(5); clean(locker)
        passed('lock-cancels-publication-and-unlock-applies-newest-input')

        # A conflicting target does not prevent another application's output update.
        owned_before_conflict = installed.read_bytes()
        installed.write_text('user-owned edit')
        other = config/'pearl/matugen/outputs/fluxer/output-0.css'
        old = other.read_bytes()
        Image.new('RGB', (64, 64), '#4488cc').save(wallpaper)
        wait_for(lambda: other.read_bytes() != old, 15)
        state = settled(peer)
        assert installed.read_text() == 'user-owned edit'
        assert state['applications']['targets'][0]['state'] == 'conflict', state
        assert state['applications']['applied_generation'] != state['applications']['desired_generation']
        passed('ownership-conflict-isolated-per-application')
        # Restore only the exact previously owned contents for subsequent acceptance.
        output = config/'pearl/matugen/outputs/zed/output-0.json'
        installed.write_bytes(owned_before_conflict)
        peer.theme('application_retry', revision=peer.state()['revision']); settled(peer)
        assert installed.read_bytes() == output.read_bytes()
        passed('retry-uses-current-wallpaper-snapshot')

        # Committed templates survive removal and restart, including changes while stopped.
        shutil.rmtree(profiles)
        before = installed.read_bytes()
        peer.close(); shell.stop(); clean(shell)
        Image.new('RGB', (64, 64), '#cc8844').save(wallpaper)
        shell = s.child('pearl-restart', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = Peer(s, ipc); settled(peer)
        assert installed.read_bytes() != before
        passed('restart-refreshes-wallpaper-with-removed-profile-assets')
        refresh('#448844')
        # Current path changes rebind the watcher, and the old image becomes irrelevant.
        old_wallpaper = wallpaper
        wallpaper = s.base/'next.png'
        Image.new('RGB', (64, 64), '#5544cc').save(wallpaper)
        apply(wallpaper=dict(path=str(wallpaper)))
        before_calls = len(generated())
        Image.new('RGB', (64, 64), '#fafafa').save(old_wallpaper)
        time.sleep(.7)
        assert len(generated()) == before_calls
        refresh('#aa8833')
        passed('committed-path-change-rebinds-watcher-without-adopting-assets')
        # Preference file edits use the same committed templates as the picker/CLI.
        newer = s.base/'external.png'
        Image.new('RGB', (64, 64), '#9933aa').save(newer)
        prefs = json.loads(peer.document('committed')); prefs['wallpaper']['path'] = str(newer)
        before = installed.read_bytes()
        (config/'pearl/preferences.json').write_text(json.dumps(prefs))
        wait_for(lambda: installed.read_bytes() != before, 15); settled(peer)
        wallpaper = newer
        passed('external-preference-edit-refreshes-committed-profiles')

        # Missing input at startup retains installed files and watches for recovery.
        before = installed.read_bytes()
        peer.close(); shell.stop(); clean(shell)
        wallpaper.unlink()
        shell = s.child('pearl-missing-image', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = Peer(s, ipc); settled(peer)
        assert installed.read_bytes() == before
        refresh('#33aa88')
        passed('missing-image-at-startup-recovers-on-file-recreation')
        watched_dir = s.base/'watched-images'; watched_dir.mkdir()
        wallpaper = watched_dir/'image.png'
        Image.new('RGB', (64, 64), '#88aaff').save(wallpaper)
        apply(wallpaper=dict(path=str(wallpaper)))
        shutil.rmtree(watched_dir)
        wait_for(lambda: peer.state()['applications']['watcher_error'] is not None, 10)
        settled(peer)
        watched_dir.mkdir()
        Image.new('RGB', (64, 64), '#ffaa88').save(wallpaper)
        before = installed.read_bytes()
        ctl(s, args.ctl, 'preferences', 'reload')
        wait_for(lambda: installed.read_bytes() != before, 15); settled(peer)
        assert peer.state()['applications']['watcher_error'] is None
        refresh('#aa88ff')
        passed('directory-watch-invalidation-reported-and-explicit-reload-reattaches')
        assert len(list((config/'pearl/matugen/snapshots').glob('*.json'))) <= 5
        assert len(list((Path(s.env['XDG_CACHE_HOME'])/'pearl/matugen').glob('render-cache-*.json'))) <= 16
        passed('snapshot-and-render-cache-storage-remains-bounded')
        apply(matugen=dict(enabled=False))
        before_calls = len(generated())
        Image.new('RGB', (64, 64), '#aabb33').save(wallpaper)
        time.sleep(.8); settled(peer)
        assert not any('json' in c['argv'] for c in generated()[before_calls:])
        passed('disabled-management-does-not-render-templates')
        # Cancellation during shutdown must reap the delayed generator.
        mode.write_text('slow')
        before_calls = len(generated())
        Image.new('RGB', (64, 64), '#abcdef').save(wallpaper)
        wait_for(lambda: len(generated()) > before_calls, 5)
        peer.close()
        started = time.monotonic(); shell.stop(); clean(shell)
        assert time.monotonic() - started < 4
        for call in generated():
            assert not Path('/proc').joinpath(str(call['pid'])).exists(), call
        passed('shutdown-cancels-and-reaps-generator')
    report = dict(status='passed', checks=checks, timings=timings, hardware=platform.platform(),
                  cpu=next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), 'unknown'))
    report['latency_summary_ms'] = {name: dict(p50=statistics.median(values), p95=sorted(values)[min(len(values)-1, int(len(values)*.95))], samples=len(values)) for name, values in timings.items()}
    (args.output/'acceptance.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
