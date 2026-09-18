#!/usr/bin/env python3
"""Live package changes, approvals and bounded lifetimes in one private Pearl session."""
import argparse
import json
import os
import shutil
import time
import threading
import uuid
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, ctl, wait_for, probe, clean
from test_settings_services import Peer
from test_plugin_host import digest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pearl', type=Path, default=ROOT/'zig-out/test/pearl-integration')
    p.add_argument('--settings', type=Path, default=ROOT/'zig-out/test/pearl-settings-test')
    p.add_argument('--ctl', type=Path, default=ROOT/'zig-out/bin/pearlctl')
    p.add_argument('--examples', type=Path, default=ROOT/'.cache/plugin-examples')
    p.add_argument('--prefix', type=Path, default=ROOT/'.cache/aqueous-activity-production')
    p.add_argument('--output', type=Path, default=ROOT/'.cache/plugin-discovery')
    p.add_argument('--cycles', type=int, default=100)
    p.add_argument('--no-monitors', action='store_true')
    p.add_argument('--runtime-disabled', action='store_true')
    args = p.parse_args()
    for key, value in vars(args).items():
        if isinstance(value, Path): setattr(args, key, value.resolve())
    checks = []
    with PrivateSession(args.output, tool_prefix=args.prefix) as s:
        s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
        s.child('system-bus', ['dbus-daemon', '--session', '--nofork', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda: s.run(['busctl', '--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'], 'list'], check=False).returncode == 0)
        s.env['PEARL_SECURITY_LOG'] = str(s.output/'security.jsonl')
        fixture = s.child('authority', ['python3', ROOT/'tests/fixtures/session_security.py'], input_pipe=True)
        fixture.expect('event=ready')
        # Both installation roots are private, including executable-relative system data.
        distribution = s.output/'distribution'
        (distribution/'bin').mkdir(parents=True)
        shutil.copy2(args.pearl, distribution/'bin/pearl')
        helper = args.pearl.parent/'pearl-plugin-host'
        if not args.runtime_disabled: shutil.copy2(helper, distribution/'bin/pearl-plugin-host')
        system = distribution/'share/pearl/plugins'
        system.mkdir(parents=True)
        shutil.copytree(args.examples/'counter-zig', system/'counter-zig')
        root = Path(s.env['XDG_DATA_HOME'])/'pearl/plugins'
        assert not root.exists()
        config = Path(s.env['XDG_CONFIG_HOME'])/'pearl/preferences.json'
        config.parent.mkdir(exist_ok=True)
        config.write_text(json.dumps(dict(bar=dict(groups=dict(center='plugin:pearl.timer-c/main')))))
        if args.no_monitors: s.env['PEARL_TEST_PLUGIN_NO_MONITORS'] = '1'
        ipc = IPC(s)
        shell = s.child('pearl', [distribution/'bin/pearl'], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        shell_pid = shell.proc.pid
        def listed(): return ctl(s, args.ctl, 'plugins', 'list')['result']
        def packages():
            result = listed(); values = result['packages']
            while result.get('next_offset') is not None:
                result = ctl(s, args.ctl, 'plugins', 'list', '--offset', str(result['next_offset']))['result']
                values += result['packages']
            return {x['id']: x for x in values}
        def refresh():
            ticket = ctl(s, args.ctl, 'plugins', 'refresh')['result']['requested']
            return wait_for(lambda: (v if (v:=listed())['completed'] >= ticket and not v.get('pending') else False), 20)
        def changed():
            if args.no_monitors: refresh()
        def package(id, **expected):
            return wait_for(lambda: (v if (v:=packages().get(id)) and all(v.get(k)==value for k,value in expected.items()) else False), 20)
        def installed(name, dest=None):
            root.mkdir(parents=True, exist_ok=True)
            shutil.copytree(args.examples/name, root/(dest or name))
            changed()
        def approve(peer, id, path, expected_status=None, **extra):
            document = json.loads(peer.document())
            entries = [x for x in document.get('plugins', {}).get('entries', []) if x['id'] != id]
            entries.append(dict(id=id, enabled=True, digest=digest(path), **extra))
            document['plugins'] = dict(entries=entries)
            peer.keep(json.dumps(document))
            result = peer.action('apply')
            assert result['state'] == 'succeeded', result
            return package(id, status='unavailable' if args.runtime_disabled else (expected_status or 'active'))
        wait_for(lambda: not listed()['loading'])
        assert packages()['pearl.counter-zig']['source'] == 'system'
        app = s.child('settings', [args.settings, '--page', 'plugins'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created')
        wait_for(lambda: probe(s, ipc)['editor']['ready'])
        peer = Peer(s, ipc); peer.enter('plugins')
        assert peer.page()['live']['refresh_available']
        assert peer.call('plugin.refresh', view=peer.view, operation=uuid.uuid4().hex)['ok']
        stable_id = 'pearl.counter-rust'
        started = time.monotonic(); installed('counter-rust')
        package(stable_id, status='disabled')
        latency = time.monotonic()-started
        assert latency < (5 if args.no_monitors else 2.5), latency
        stable = approve(peer, stable_id, root/'counter-rust')
        stable_generation = stable['generation']
        refresh(); assert packages()[stable_id]['generation'] == stable_generation
        checks.append('absent-user-root-install-and-no-op-refresh-preserves-instance')
        # A failed unchanged guest is not restarted by refresh. In degraded mode,
        # the first discovery here deliberately relies on the 30-second poll.
        shutil.copytree(args.examples/'fault-1', root/'fault-1')
        wait_for(lambda: 'pearl.fault-1' in packages(), 40)
        if args.no_monitors:
            assert listed()['monitoring'] == 'polling'
            checks.append('missing-monitors-recover-through-automatic-30-second-poll')
        fault = approve(peer, 'pearl.fault-1', root/'fault-1', expected_status='failed')
        refresh(); refresh()
        assert packages()['pearl.fault-1']['generation'] == fault['generation']
        shutil.rmtree(root/'fault-1'); changed()
        wait_for(lambda: 'pearl.fault-1' not in packages())
        checks.append('unchanged-failed-plugin-does-not-crash-loop-on-refresh')
        start_revision = listed()['discovery_revision']
        def storm():
            until = time.monotonic()+2
            while time.monotonic() < until:
                (root/'install.tmp').write_text('unrelated temporary data')
                time.sleep(.005)
        writer = threading.Thread(target=storm); writer.start()
        tickets = [ctl(s, args.ctl, 'plugins', 'refresh')['result']['requested'] for _ in range(20)]
        writer.join(); refresh()
        after_storm = listed()
        assert after_storm['completed'] >= max(tickets)
        assert after_storm['discovery_revision']-start_revision <= 5, after_storm
        assert packages()[stable_id]['generation'] == stable_generation
        (root/'install.tmp').unlink()
        checks.append('event-storm-and-manual-refresh-requests-coalesce')
        # Exhaust the global walk budget: retain the last complete index.
        for i in range(2050): (root/f'{i}.tmp').touch()
        refresh(); assert listed()['error_code'] == 'PluginTraversalLimit', listed()
        assert packages()[stable_id]['generation'] == stable_generation
        for path in root.glob('*.tmp'): path.unlink()
        refresh(); assert 'error_code' not in listed(), listed()
        checks.append('global-traversal-budget-fails-without-false-uninstall')
        installed('timer-c'); timer_id = 'pearl.timer-c'; timer_dir = root/'timer-c'
        package(timer_id, status='disabled'); approve(peer, timer_id, timer_dir)
        # A retained unrelated draft must survive discovery without preference writes.
        draft = json.loads(peer.document()); draft['bar']['groups']['left'] = 'launcher'
        peer.keep(json.dumps(draft)); kept = peer.document(); disk = config.read_bytes()
        manifest_path = timer_dir/'plugin.json'; original = manifest_path.read_bytes()
        manifest = json.loads(original); manifest['version'] = 'updated'
        manifest_path.write_text(json.dumps(manifest)); changed()
        package(timer_id, status='unavailable', error_code='PluginApprovalRequired')
        assert peer.document() == kept and config.read_bytes() == disk
        # Approve this digest in a draft, then change the package before Apply.
        stale = json.loads(peer.document())
        next(x for x in stale['plugins']['entries'] if x['id']==timer_id)['digest'] = digest(timer_dir)
        peer.keep(json.dumps(stale)); manifest['version'] = 'newer'
        manifest_path.write_text(json.dumps(manifest)); changed()
        package(timer_id, digest=digest(timer_dir))
        rejected = peer.action('apply'); assert rejected['state'] == 'failed', rejected
        approve(peer, timer_id, timer_dir)
        checks.append('changed-content-requires-approval-stale-apply-rejected-draft-preserved')
        # Corrupt/partial replacements never run; exact approved restoration resumes.
        approved = manifest_path.read_bytes(); approved_digest = digest(timer_dir)
        manifest_path.write_text('{'); changed()
        package(timer_id, status='unavailable')
        manifest_path.write_bytes(approved); changed()
        package(timer_id, digest=approved_digest, status='unavailable' if args.runtime_disabled else 'active')
        shutil.copytree(timer_dir, root/'timer-duplicate')
        duplicate=root/'timer-duplicate/plugin.json'
        duplicate.write_text(json.dumps(json.loads(duplicate.read_text()) | dict(version='different-version')))
        changed()
        package(timer_id, error_code='PluginIdConflict', status='unavailable')
        shutil.rmtree(root/'timer-duplicate'); changed()
        package(timer_id, status='unavailable' if args.runtime_disabled else 'active')
        checks.append('invalid-replacement-and-same-root-conflict-recovery')
        # User priority over system, including an invalid override and removal.
        installed('counter-zig'); package('pearl.counter-zig', source='user', shadowed=1)
        (root/'counter-zig/plugin.json').write_text('{'); changed()
        package('pearl.counter-zig', source='user', status='unavailable')
        shutil.rmtree(root/'counter-zig'); changed()
        package('pearl.counter-zig', source='system', status='disabled')
        checks.append('deterministic-user-priority-invalid-override-does-not-fall-through')
        # A root scan error preserves the last complete index.
        root.chmod(0); refresh()
        assert listed()['error_code'] == 'PluginRootUnreadable', listed()
        assert stable_id in packages()
        root.chmod(0o755); refresh()
        # Rename the entire root; its parent watch must survive the replacement.
        moved = root.with_name('plugins-staging'); root.rename(moved); changed()
        wait_for(lambda: stable_id not in packages())
        moved.rename(root); changed()
        package(stable_id, status='unavailable' if args.runtime_disabled else 'active')
        stable_generation = packages()[stable_id]['generation']
        checks.append('unreadable-root-preserved-and-root-rename-rearms-watches')
        # Update/remove while inactive: discovery continues but no guest can start.
        fixture.proc.stdin.write('{"active":false}\n'); fixture.proc.stdin.flush()
        package(stable_id, status='suspended')
        shutil.rmtree(timer_dir); changed(); wait_for(lambda: timer_id not in packages())
        installed('timer-c'); package(timer_id, status='suspended')
        fixture.proc.stdin.write('{"active":true}\n'); fixture.proc.stdin.flush()
        package(stable_id, status='unavailable' if args.runtime_disabled else 'active')
        approve(peer, timer_id, timer_dir)
        stable_generation = packages()[stable_id]['generation']
        checks.append('inactive-install-removal-cannot-start-helpers')
        # The cat has nested PNGs: an asset-only change must retire its old view.
        installed('companion-c'); cat_dir = root/'companion-c'; cat_id = 'pearl.companion'
        package(cat_id, status='disabled')
        approve(peer, cat_id, cat_dir, grants=dict(overlay=True), placement=dict(mode='overlay'))
        cat_manifest = json.loads((cat_dir/'plugin.json').read_text())
        png = cat_dir/cat_manifest['assets'][0]['path']; old_png = png.read_bytes()
        png.write_bytes(old_png+b'new asset revision'); changed()
        package(cat_id, error_code='PluginApprovalRequired')
        approve(peer, cat_id, cat_dir, grants=dict(overlay=True), placement=dict(mode='overlay'))
        shutil.rmtree(cat_dir); changed(); wait_for(lambda: cat_id not in packages())
        checks.append('nested-asset-only-update-and-animated-view-removal')
        # Disabled then enabled is entirely live, preserving the approved digest.
        revision = wait_for(lambda: (v['revision'] if not (v:=ctl(s, args.ctl, 'preferences', 'status')['result'])['busy'] else False))
        ctl(s, args.ctl, 'plugins', 'disable', '--path', timer_id, '--revision', str(revision))
        package(timer_id, status='disabled')
        revision = wait_for(lambda: (v['revision'] if not (v:=ctl(s, args.ctl, 'preferences', 'status')['result'])['busy'] else False))
        ctl(s, args.ctl, 'plugins', 'enable', '--path', timer_id, '--text', digest(timer_dir), '--revision', str(revision))
        package(timer_id, status='unavailable' if args.runtime_disabled else 'active')
        refresh()
        def resources():
            status = listed()
            return dict(fds=len(list(Path(f'/proc/{shell_pid}/fd').iterdir())), watches=status['watch_count'], bytes=status['retained_bytes'], helpers=len(Path(f'/proc/{shell_pid}/task/{shell_pid}/children').read_text().split()))
        baseline = resources()
        idle_revision = listed()['discovery_revision']
        def cpu_ticks():
            fields = Path(f'/proc/{shell_pid}/stat').read_text().split(') ', 1)[1].split()
            return int(fields[11])+int(fields[12])
        ticks_before = cpu_ticks(); idle_start = time.monotonic(); time.sleep(3)
        idle_cpu = 100*(cpu_ticks()-ticks_before)/os.sysconf('SC_CLK_TCK')/(time.monotonic()-idle_start)
        if not args.no_monitors: assert listed()['discovery_revision'] == idle_revision
        for cycle in range(args.cycles):
            manifest_path.write_text(json.dumps(json.loads(original) | dict(version=f'cycle-{cycle}'))); changed()
            package(timer_id, error_code='PluginApprovalRequired')
            shutil.rmtree(timer_dir); changed(); wait_for(lambda: timer_id not in packages())
            installed('timer-c'); package(timer_id, status='unavailable' if args.runtime_disabled else 'active')
            assert shell.proc.poll() is None and packages()[stable_id]['generation'] == stable_generation
            if (cycle+1) % 10 == 0: print(f'completed {cycle+1}/{args.cycles} replacement/removal/reinstall cycles', flush=True)
        refresh(); time.sleep(.3)
        final = resources()
        assert final['helpers'] == baseline['helpers'], (baseline, final)
        assert final['watches'] == baseline['watches'], (baseline, final)
        assert final['bytes'] == baseline['bytes'], (baseline, final)
        assert final['fds'] <= baseline['fds']+2, (baseline, final)
        assert packages()[stable_id]['generation'] == stable_generation
        assert shell.proc.pid == shell_pid and shell.proc.poll() is None
        checks.append(f'{args.cycles}-cycles-stable-shell-unrelated-helper-and-resource-baseline')
        peer.close(); app.signal(); app.wait(timeout=5)
        app = s.child('settings-reopened', [args.settings, '--page', 'plugins'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created'); wait_for(lambda: probe(s, ipc)['editor']['ready'])
        ctl(s, args.ctl, 'quit'); clean(shell); app.signal(); app.wait(timeout=5); ipc.close()
        report = dict(status='passed', checks=checks, install_seconds=latency, baseline=baseline, final=final, shell_pid=shell_pid, idle_cpu_percent=idle_cpu)
        (s.output/'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
