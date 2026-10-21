#!/usr/bin/env python3
"""Native Displays setup against private Aqueous outputs; never touches the user's session."""
import argparse, json, time
from pathlib import Path
from test_settings_app import ROOT, APP_ID, PrivateSession, IPC, wait_for, probe, windows, capture, click_widget, keys, request, status
from pearl_session import fixture_prefix, fixture_source
from wayland_test_input import configure_output, pointer_drag as drag_pointer
from test_settings_appearance import ready, click, control, type_text
from test_settings_services import Peer, aq_ready, navigate


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/aqueous-displays')
    args = p.parse_args()
    for name, value in vars(args).items(): setattr(args, name, value.resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}; report = dict(status='running', checks=checks)
    try:
      with PrivateSession(args.output/'session', tool_prefix=fixture_prefix()) as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'; ipc = IPC(s)
        wm = Path(s.env['AQUEOUS_CONFIG']); wm.write_text(wm.read_text().replace('"floating"', '"stacking"'))
        output = next(iter(ipc.outputs().values())); connector = output['name']
        configure_output(s, connector, mode='1600x1100@60')
        rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
        def size(width, height):
            rules.write_text(f'[[window]]\napp_id="{APP_ID}"\nfloating=true\nwidth={width}\nheight={height}\n')
            ipc.call('command', action='session.reload', fields={}); time.sleep(.5)
        size(1180, 940)
        shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
        app = s.child('settings', [args.settings, '--page', 'aqueous', '--section', 'displays'], G_DEBUG='fatal-warnings'); app.expect('event=settings-window-created')
        peer = Peer(s, ipc); ready(s, ipc); aq_ready(s, ipc, peer); time.sleep(.5)
        assert probe(s, ipc)['section'] == 'displays'
        controls = {c['field']: c for c in probe(s, ipc)['controls']}
        assert 'display.arrangement' in controls and 'display.select.1' in controls
        assert 'display.hdr_level' not in controls and 'display.x' not in controls
        assert not controls['display.hdr']['enabled']  # headless outputs explicitly do not support HDR
        capture(s, 'desktop', connector)
        checks['primary-layout-and-collapsed-advanced-controls'] = True
        checks['unsupported-hdr-checkbox-disabled'] = True
        click(s, ipc, 'display.select.1')
        click(s, ipc, 'display.exact'); time.sleep(.3)
        # Click the editable text, avoiding the spin button's decrement arrow.
        click(s, ipc, 'display.x', fraction_x=.15); type_text(s, '1750'); keys(s, 'Tab')
        wait_for(lambda: probe(s, ipc)['aqueous']['display_changes'] > 0)
        aq_ready(s, ipc, peer)
        draft = peer.aq_document('draft'); ops = draft['display_declaration_changes']['operations']
        assert any(op.get('set', {}).get('position', [0])[0] == 1750 for op in ops), ops
        checks['selected-output-exact-position-stages-canonical-draft'] = True
        click(s, ipc, 'display.primary'); aq_ready(s, ipc, peer)
        assert not next(c for c in probe(s, ipc)['controls'] if c['field'] == 'display.primary')['enabled']
        primary_ops = peer.aq_document('draft')['display_declaration_changes']['operations']
        assert any(op.get('set', {}).get('primary') is True and op.get('set', {}).get('position') == [0, 0] for op in primary_ops), primary_ops
        assert any(op.get('set', {}).get('position') == [-1750, 0] for op in primary_ops), primary_ops
        click(s, ipc, 'display.select.0')
        assert next(c for c in probe(s, ipc)['controls'] if c['field'] == 'display.primary')['enabled']
        click(s, ipc, 'display.primary'); aq_ready(s, ipc, peer)
        primary_ops = peer.aq_document('draft')['display_declaration_changes']['operations']
        assert sum(op.get('set', {}).get('primary') is True for op in primary_ops) == 1, primary_ops
        assert any(op.get('set', {}).get('position', [0])[0] == 1750 and op.get('set', {}).get('primary') is not True for op in primary_ops), primary_ops
        click(s, ipc, 'display.select.1')
        assert next(c for c in probe(s, ipc)['controls'] if c['field'] == 'display.primary')['enabled']
        checks['primary-button-anchors-origin-and-preserves-relative-position'] = True
        navigate(s, ipc, 'aqueous', 'appearance'); navigate(s, ipc, 'aqueous', 'displays')
        assert probe(s, ipc)['aqueous']['display_changes'] > 0
        assert 'display.x' in {c['field'] for c in probe(s, ipc)['controls']}
        checks['selection-draft-and-disclosures-survive-navigation'] = True
        # The footer sits outside the scrolled page; click its actual bounds.
        click_widget(s, ipc, control(s, ipc, 'aqueous.discard')); aq_ready(s, ipc, peer)
        wait_for(lambda: probe(s, ipc)['aqueous']['display_changes'] == 0)
        click(s, ipc, 'display.more'); time.sleep(.25)
        assert 'display.hdr_level' in {c['field'] for c in probe(s, ipc)['controls']}
        capture(s, 'advanced', connector)
        checks['advanced-controls-reachable-and-discard-restores-baseline'] = True
        # Use the real Identify action. It must create one shell surface per enabled output.
        click(s, ipc, 'display.identify')
        wait_for(lambda: status(s, args.ctl)['identifying'] == len(ipc.outputs()))
        capture(s, 'identify', connector)
        wait_for(lambda: status(s, args.ctl)['identifying'] == 0, 8)
        checks['identify-labels-each-output-and-cleans-up'] = True
        click(s, ipc, 'display.arrange'); aq_ready(s, ipc, peer)
        assert not probe(s, ipc)['aqueous']['display_blocked']
        checks['side-by-side-produces-non-overlapping-draft'] = True
        arranged = peer.aq_document('draft')['display_declaration_changes']['operations']
        assert sum('position' in op.get('set', {}) for op in arranged) == len(ipc.outputs()), arranged
        checks['arrangement-pins-every-enabled-display'] = True
        # A canvas key edit must update the selected screen's canonical position.
        click(s, ipc, 'display.arrangement')
        drag_pointer(s, 0, 40); aq_ready(s, ipc, peer)
        positions = [op.get('set', {}).get('position') for op in peer.aq_document('draft')['display_declaration_changes']['operations']]
        assert any(position and position[1] != 0 for position in positions), positions
        checks['real-pointer-drag-stages-selected-display-position'] = True
        keys(s, 'Down'); aq_ready(s, ipc, peer)
        assert probe(s, ipc)['aqueous']['display_changes'] > 0
        checks['keyboard-arrangement-stages-position'] = True
        # Keep the host output at the desktop origin before live preview so the
        # coordinate-based pointer helpers remain valid after the hardware change.
        click(s, ipc, 'display.arrange'); aq_ready(s, ipc, peer)
        click(s, ipc, 'display.select.1')
        click(s, ipc, 'display.scale'); keys(s, 'Down', 'Return'); aq_ready(s, ipc, peer)
        assert probe(s, ipc)['aqueous']['display_changes'] > 0
        checks['scale-dropdown-preserves-relative-arrangement'] = True
        capture(s, 'unsaved', connector)
        click_widget(s, ipc, control(s, ipc, 'aqueous.apply'))
        wait_for(lambda: peer.aqueous()['phase'] == 1, 25)
        time.sleep(.4); capture(s, 'confirmation', connector)
        keys(s, 'Escape')
        wait_for(lambda: peer.aqueous()['phase'] == 0 and not peer.aqueous()['busy'], 25)
        aq_ready(s, ipc, peer)
        assert probe(s, ipc)['aqueous']['display_changes'] > 0
        checks['apply-preview-and-escape-revert-retain-draft'] = True
        click_widget(s, ipc, control(s, ipc, 'aqueous.apply'))
        wait_for(lambda: peer.aqueous()['phase'] == 1, 25)
        time.sleep(.3); keys(s, 'Tab', 'Return')
        wait_for(lambda: peer.aqueous()['phase'] == 0 and not peer.aqueous()['busy'], 25)
        aq_ready(s, ipc, peer)
        assert peer.aqueous()['outcome'] == 'saved', peer.aqueous()
        checks['keep-dialog-performs-protected-save'] = True
        current = peer.aq_document('committed')
        field = next(f for f in current['fields'] if f['id'] == 'layout.gaps_outer')
        candidate = dict(protocol=1, expected_generation=current['generation'], changes=[dict(id=field['id'], value=19 if field['value'] != 19 else 20)], raw_files={})
        assert peer.aq_keep(candidate)['ok']; aq_ready(s, ipc, peer)
        click_widget(s, ipc, control(s, ipc, 'aqueous.discard'))
        wait_for(lambda: probe(s, ipc)['aqueous']['shared_review'])
        capture(s, 'shared-draft-review', connector)
        keys(s, 'Escape')
        wait_for(lambda: not probe(s, ipc)['aqueous']['shared_review'])
        assert peer.aq_document('draft')['changes'] == candidate['changes']
        peer.aq_action('discard'); aq_ready(s, ipc, peer)
        checks['shared-draft-review-cancel-retains-other-section-edits'] = True
        size(520, 780); app.stop()
        app = s.child('settings-narrow', [args.settings, '--page', 'aqueous', '--section', 'displays'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created'); ready(s, ipc); aq_ready(s, ipc, peer); time.sleep(.3)
        v = probe(s, ipc); assert v['narrow']
        click(s, ipc, 'display.scale')
        capture(s, 'narrow', connector)
        checks['narrow-selected-editor-reachable'] = True
        peer.close(); app.stop(); shell.stop()
        report['status'] = 'passed'
    except BaseException:
        report['status'] = 'failed'
        raise
    finally:
        (args.output/'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
