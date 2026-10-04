#!/usr/bin/env python3
"""Exercise new Aqueous centering fields through Pearl's existing schema UI.

Pass a local Aqueous prefix containing matching aqueous, aqueousctl and
aqueous-config binaries. This does not replace the pinned contract fixtures.
"""
import argparse
import json
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, probe, capture, windows
from test_settings_services import Peer, navigate, aq_ready
from test_settings_appearance import click, type_text
from test_aqueous_settings import state, settled
from test_surfaces import ctl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--expect-unavailable', action='store_true', help='Check omission with a helper predating the feature')
    parser.add_argument('--pearl', type=Path, default=ROOT / 'zig-out/bin/pearl')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/pearlctl')
    parser.add_argument('--settings', type=Path, default=ROOT / 'zig-out/bin/pearl-settings')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/single-window-centering')
    args = parser.parse_args()
    for key in ('prefix', 'pearl', 'ctl', 'settings', 'output'):
        setattr(args, key, getattr(args, key).resolve())
    with PrivateSession(args.output / 'session', tool_prefix=args.prefix) as s:
        wm = Path(s.env['AQUEOUS_CONFIG'])
        wm.write_text(wm.read_text().replace('"floating"', '"tile"'))
        shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        ipc = IPC(s)
        try:
            ctl(s, args.ctl, 'aqueous', 'refresh')
            assert settled(s, args.ctl)['err'] is None
            snapshot = json.loads(s.run([args.prefix / 'bin/aqueous-config', 'snapshot', '--shell', 'none']).stdout)
            fields = {f['id']: f for f in snapshot['fields']}
            prefixes = ['layout'] + ['layout.options.' + name for name in ('tile', 'grid', 'rows', 'dwindle', 'reverse-dwindle')]
            expected = [prefix + '.' + key for prefix in prefixes for key in ('center_single_window', 'single_window_aspect_ratio')]
            for id in ([] if args.expect_unavailable else expected):
                assert fields[id]['category'] == 'layouts', fields[id]
                assert fields[id]['type'] == ('boolean' if id.endswith('center_single_window') else 'double')
            app = s.child('settings', [args.settings, '--page', 'aqueous'], G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created')
            peer = Peer(s, ipc)
            try:
                navigate(s, ipc, 'aqueous', 'layouts')
                aq_ready(s, ipc, peer)
                rendered = {c['field'] for c in probe(s, ipc)['controls']}
                if args.expect_unavailable:
                    assert not set(expected).intersection(fields)
                    assert not set(expected).intersection(rendered)
                    (args.output / 'older-helper.json').write_text(json.dumps(dict(unavailable_fields_omitted=True), indent=2) + '\n')
                    print('PASS Pearl: older helpers omit unavailable centering controls')
                    return
                assert set(expected) <= rendered, (set(expected) - rendered)
                click(s, ipc, 'layout.center_single_window')
                wait_for(lambda: peer.aqueous()['draft'])
                aq_ready(s, ipc, peer)
                click(s, ipc, 'layout.single_window_aspect_ratio')
                type_text(s, '1.5')
                s.run(['wtype', '-k', 'Tab'])
                wait_for(lambda: any(c['id'] == 'layout.single_window_aspect_ratio' and c['value'] == 1.5 for c in peer.aq_document('draft')['changes']))
                aq_ready(s, ipc, peer)
                output = next(iter(ipc.outputs().values()))
                capture(s, 'centering-controls', output['name'])
                before = windows(ipc)[0]['geometry']
                ctl(s, args.ctl, 'aqueous', 'apply')
                result = settled(s, args.ctl)
                assert result['outcome'] == 'saved' and result['reload'] == 'applied', result
                for prefix in prefixes:
                    assert state(s, args.ctl, prefix + '.center_single_window')['value'] is True
                    assert state(s, args.ctl, prefix + '.single_window_aspect_ratio')['value'] == 1.5
                width = min(before['width'], int(before['height'] * 1.5 + .5))
                expected_geometry = dict(before, width=width, x=before['x'] + (before['width'] - width) // 2)
                wait_for(lambda: windows(ipc)[0]['geometry'] == expected_geometry)
                aq_ready(s, ipc, peer)
                click(s, ipc, 'layout.options.grid.center_single_window')
                wait_for(lambda: peer.aqueous()['draft'])
                aq_ready(s, ipc, peer)
                ctl(s, args.ctl, 'aqueous', 'apply')
                assert settled(s, args.ctl)['outcome'] == 'saved'
                assert state(s, args.ctl, 'layout.options.grid.center_single_window')['value'] is False
                assert state(s, args.ctl, 'layout.options.tile.center_single_window')['value'] is True
                # Capture only the new live schema fields; historical pinned
                # contract fixtures retain their actual source provenance.
                current = json.loads(s.run([args.prefix / 'bin/aqueous-config', 'snapshot', '--shell', 'none']).stdout)
                (args.output / 'fields.json').write_text(json.dumps([f for f in current['fields'] if f['id'] in expected], indent=2) + '\n')
                (args.output / 'results.json').write_text(json.dumps(dict(rendered=expected, pointer_edits=True, save=True, reload='applied', inheritance=True, per_layout_override=True, live_geometry=expected_geometry), indent=2) + '\n')
                print('PASS Pearl: generated controls, pointer edits, save, live rearrangement, inheritance and per-layout overrides')
            finally:
                peer.close()
        finally:
            ipc.close()


if __name__ == '__main__':
    main()
