#!/usr/bin/env python3
"""Measure vertical bar allocations on private outputs, including live rotation."""
import argparse, copy, json, sys, time
from pathlib import Path
from PIL import Image
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import ctl, status, capture, clean, IPC, click
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/bar-layout')
    parser.add_argument('--icon-hotplug', action='store_true', help='Exercise output disable/enable (requires compositor with working output-management disable)')
    args = parser.parse_args()
    args.pearl = args.pearl.resolve(); args.ctl = args.ctl.resolve(); args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', cases=[])
    try:
        with PrivateSession(args.output / 'session', tool_prefix=ROOT / '.cache/aqueous-activity-production') as s:
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            T00Session.input_fixture(s)
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            base = copy.deepcopy(settled(s, args.ctl)['preferences'])
            first = status(s, args.ctl)['outputs'][0]
            def output():
                return next(o for o in status(s, args.ctl)['outputs'] if o['id'] == first['id'])
            def layout():
                return {v['name']: v for v in ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-layout')['result']['items']}
            baseline = wait_for(lambda: (lambda v: v if v['workspaces']['rect']['width'] > 0 else False)(layout()))
            workspace_count = len(baseline['workspaces']['parts'])
            assert workspace_count >= 9, baseline
            original_keyboard = output()['keyboard']
            from bar_opacity import verify, verify_missing_color
            verify(s, args, base, first, report)
            verify_missing_color(args, report)
            assert len(original_keyboard) > 2, original_keyboard
            custom = Path(s.env['XDG_DATA_HOME']) / 'themes/Pearl-Bar-Test/gtk-4.0'
            custom.mkdir(parents=True)
            (custom / 'gtk.css').write_text('.background {background:#203040;color:#ffffff;} button {color:#ffffff;background:#304050;}')
            icon_file = s.base/'launcher-transparent.png'
            Image.new('RGBA', (96, 48), (30, 180, 125, 180)).save(icon_file)
            def icon_probe():
                return ctl(s,args.ctl,'aqueous','status','--text','test-bar-layout:' + first['id'])['result']
            def icon_settled():
                return wait_for(lambda: (lambda v: v if not v['launcher_icon_loading'] else False)(icon_probe()))
            missing = s.base/'missing.png'
            corrupt = s.base/'corrupt.png'; corrupt.write_bytes(b'not a PNG')
            oversized = s.base/'oversized.png'; oversized.write_bytes(b'x' * (2*1024*1024 + 1))
            large = s.base/'large.png'; Image.new('RGBA',(2049,1)).save(large)
            animated = s.base/'animated.png'
            frames=[Image.new('RGBA',(8,8),color) for color in ('red','blue')]
            frames[0].save(animated,save_all=True,append_images=frames[1:],duration=100,loop=0)
            for name in (missing, corrupt, oversized, large, animated):
                prefs=copy.deepcopy(base); prefs['outputs']=[]
                prefs['bar']['launcher_icon']=dict(kind='file',value=str(name))
                apply(s,args.ctl,prefs)
                value=icon_settled()
                assert value['launcher_icon_failed'] and 'launcher' in layout(), value
            prefs['bar']['launcher_icon']=dict(kind='theme',value='pearl-no-such-icon')
            apply(s,args.ctl,prefs)
            assert icon_settled()['launcher_icon_failed']
            report['cases'].append(dict(name='launcher-icon-missing-corrupt-oversized-animated-fallback'))
            for theme, islands, font, size in [('static', True, 14, 48), ('static', False, 14, 48), ('gtk', True, 14, 48), ('static', True, 20, 48), ('gtk', False, 20, 64)]:
                for edge in ('left', 'right', 'top', 'bottom'):
                    prefs = copy.deepcopy(base)
                    prefs['theme'].update(mode=theme, gtk_name='Pearl-Bar-Test')
                    prefs['font_size'] = font
                    prefs['outputs'] = [dict(connector=first['connector'], bar=dict(edge=edge, size=size, islands=islands, background_opacity=dict(mode='custom',percent=50), groups=base['bar']['groups'], launcher_icon=dict(kind='file',value=str(icon_file))))]
                    apply(s, args.ctl, prefs)
                    wait_for(lambda: output()['bar_edge'] == edge)
                    time.sleep(.25)
                    assert not icon_settled()['launcher_icon_failed']
                    assert icon_probe()['background_opacity'] == dict(mode='custom',percent=50)
                    current = output(); widgets = layout()
                    assert len(widgets['workspaces']['parts']) == workspace_count, widgets
                    vertical = edge in ('left', 'right')
                    if vertical:
                        assert current['bar_size'] == size, current
                        assert len(current['keyboard']) <= 2, current
                        cells = widgets['workspaces']['parts']
                        assert len({round(c['x']) for c in cells}) == 1, cells
                        assert all(b['y'] >= a['y'] + a['height'] for a, b in zip(cells, cells[1:])), cells
                        for name in ('audio', 'network', 'notifications'):
                            parts = widgets[name]['parts']
                            assert len(parts) == 2 and parts[1]['y'] >= parts[0]['y'] + parts[0]['height'], (name, parts)
                        assert all(v['rect']['width'] <= size - 8 for v in widgets.values()), widgets
                    else:
                        assert current['keyboard'] == original_keyboard, current
                        parts = widgets['audio']['parts']
                        assert parts[1]['x'] >= parts[0]['x'] + parts[0]['width'], parts
                    label = f'{theme}-{islands}-{font}-{size}-{edge}'
                    capture(s, label, first['connector'])
                    report['cases'].append(dict(name=label, bar_size=current['bar_size'], widgets=widgets))
            # Display modes use exact output-local identities and follow external activation.
            ipc = IPC(s)
            def workspace_probe(oid=first['id']):
                return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-layout:' + oid)['result']
            local = sorted([e for e in ipc.state() if e['kind'] == 'workspace' and e['output'] == first['id']], key=lambda e: (e['number'], e['id']))
            def activate(index):
                ipc.call('command', action='workspace.activate', fields=dict(id=local[index]['id']))
                wait_for(lambda: ipc.outputs()[first['id']]['active_workspace'] == local[index]['id'])
            def expect_ids(expected, oid=first['id']):
                value = wait_for(lambda: (lambda v: v if v['workspace_ids'] == expected else False)(workspace_probe(oid)))
                assert value['keyboard_mode'] == 'none'
                cells = next(v['parts'] for v in value['items'] if v['name'] == 'workspaces')
                assert len(cells) == len(expected)
                return value
            for edge in ('top', 'bottom', 'left', 'right'):
                for mode, radius in [('small', 1), ('medium', 2), ('large', len(local))]:
                    prefs = copy.deepcopy(base)
                    prefs['bar'].update(edge=edge, workspace_mode=mode)
                    prefs['outputs'] = []
                    if edge == 'right': prefs['font_size'] = 20
                    apply(s, args.ctl, prefs)
                    for index in (0, 1, len(local)-2, len(local)-1, 4):
                        activate(index)
                        expected = [w['id'] for w in local[max(0,index-radius):index+radius+1]]
                        current = expect_ids(expected)
                        assert current['workspace_mode'] == mode
                    time.sleep(.3)
                    capture(s, 'workspace-' + mode + '-' + edge, first['connector'])
                    report['cases'].append(dict(name='workspace-' + mode + '-' + edge, workspace_ids=current['workspace_ids']))
            # A click on a filtered neighbor must activate its copied opaque ID.
            prefs = copy.deepcopy(base); prefs['bar'].update(edge='top', workspace_mode='small'); prefs['outputs']=[]
            apply(s, args.ctl, prefs); activate(4)
            current=expect_ids([w['id'] for w in local[3:6]])
            time.sleep(.3)
            current=workspace_probe()
            cells=next(v['parts'] for v in current['items'] if v['name']=='workspaces')
            cell=cells[-1]; bounds=ipc.outputs()[first['id']]['bounds']
            click(s, bounds['x']+cell['x']+cell['width']/2, bounds['y']+cell['y']+cell['height']/2, ipc.outputs())
            wait_for(lambda: ipc.outputs()[first['id']]['active_workspace']==local[5]['id'])
            expect_ids([w['id'] for w in local[4:7]])
            second=next(o for o in status(s,args.ctl)['outputs'] if o['id']!=first['id'])
            remote=sorted([e for e in ipc.state() if e['kind']=='workspace' and e['output']==second['id']],key=lambda e:(e['number'],e['id']))
            prefs['bar']['launcher_icon']=dict(kind='file',value=str(icon_file))
            prefs['outputs']=[dict(connector=second['connector'],bar=dict(workspace_mode='medium'))]
            apply(s,args.ctl,prefs)
            ipc.call('command',action='workspace.activate',fields=dict(id=remote[4]['id']))
            expect_ids([w['id'] for w in remote[2:7]],second['id'])
            expect_ids([w['id'] for w in local[4:7]])
            # Omitted mode in a complete display override must default to Large.
            del prefs['outputs'][0]['bar']['workspace_mode']; apply(s,args.ctl,prefs)
            expect_ids([w['id'] for w in remote],second['id'])
            assert icon_settled()['launcher_icon'] == dict(kind='file',value=str(icon_file))
            assert workspace_probe(second['id'])['launcher_icon']['kind'] == 'default'
            if args.icon_hotplug:
                s.run(['wlr-randr','--output',second['connector'],'--off'])
                wait_for(lambda: len(status(s,args.ctl)['outputs']) == 1)
                s.run(['wlr-randr','--output',second['connector'],'--on'])
                wait_for(lambda: len(status(s,args.ctl)['outputs']) == 2)
                restored=next(o for o in status(s,args.ctl)['outputs'] if o['connector']==second['connector'])
                assert workspace_probe(restored['id'])['launcher_icon']['kind'] == 'default'
                report['cases'].append(dict(name='launcher-icon-output-hotplug'))
            else:
                report['limitations']=['Icon output hotplug requires --icon-hotplug; pinned Aqueous asserts in OutputManager.validateConfigCoordinates when disabling a head.']
            report['cases'].append(dict(name='filtered-click-and-independent-display-icon-overrides'))
            ipc.close()
            for variant in ('dark','light'):
                compact=copy.deepcopy(base)
                compact['bar'].update(size=32,launcher_icon=dict(kind='default',value=''))
                compact['theme']['variant']=variant
                compact['outputs']=[]
                apply(s,args.ctl,compact)
                default_size=output()['bar_size']
                compact['bar']['launcher_icon']=dict(kind='file',value=str(icon_file))
                apply(s,args.ctl,compact)
                assert not icon_settled()['launcher_icon_failed']
                assert output()['bar_size']==default_size
                capture(s,'launcher-icon-minimum-'+variant,first['connector'])
            # Direct CLI rotation must rebuild immediately, including after scaling.
            apply(s, args.ctl, base)
            s.run(['wlr-randr', '--output', first['connector'], '--scale', '1.5'])
            for edge in ('left', 'right', 'top'):
                ctl(s, args.ctl, 'bar', 'set', '--output', first['id'], '--edge', edge, '--size', '48')
                wait_for(lambda: output()['bar_edge'] == edge)
                time.sleep(.3)
                if edge != 'top':
                    assert output()['bar_size'] == 48, output()
                    assert len({round(c['x']) for c in layout()['workspaces']['parts']}) == 1
                capture(s, 'scaled-cli-' + edge, first['connector'])
                if edge != 'top':
                    current = output(); bounds = current['bounds']
                    x = bounds['x'] + (24 if edge == 'left' else bounds['width'] - 24)
                    s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                    s.run(['wlrctl', 'pointer', 'move', str(x), str(bounds['y'] + bounds['height'] - 30)])
                    # Left-to-right rotation retains the existing scroll position.
                    s.run(['wlrctl', 'pointer', 'scroll', '-1000', '0'])
                    current = wait_for(lambda: (lambda v: v if v['island_rects'][0]['y'] >= 0 else False)(output()))
                    time.sleep(.25)
                    s.run(['wlrctl', 'pointer', 'move', '-100000', '-100000'])
                    s.run(['wlrctl', 'pointer', 'move', str(x), str(bounds['y'] + 100)])
                    time.sleep(.1)
                    before = current['island_rects'][2]['y']
                    s.run(['wlrctl', 'pointer', 'scroll', '1000', '0'])
                    current = wait_for(lambda: (lambda v: v if v['island_rects'][2]['y'] < before else False)(output()))
                    end = current['island_rects'][2]
                    assert end['y'] + end['height'] <= bounds['height'], current
                    capture(s, 'scaled-scrolled-' + edge, first['connector'])
                    # Native island input follows scrolled controls, not stale positions.
                    ipc = IPC(s)
                    click(s, x, bounds['y'] + end['y'] + end['height'] - 20, ipc.outputs())
                    wait_for(lambda: status(s, args.ctl)['popup'] is not None)
                    assert status(s, args.ctl)['popup']['pane'] == 'control'
                    ctl(s, args.ctl, 'popup', 'hide'); ipc.close()
            # Saved mode survives a shell restart, including a scaled display.
            restart_prefs=copy.deepcopy(base)
            restart_prefs['bar'].update(workspace_mode='medium',edge='top',launcher_icon=dict(kind='file',value=str(icon_file)))
            restart_prefs['outputs']=[]
            apply(s,args.ctl,restart_prefs)
            ipc=IPC(s)
            activate(4)
            expect_ids([w['id'] for w in local[2:7]])
            ctl(s, args.ctl, 'quit'); clean(app)
            app=s.child('pearl-restarted',[args.pearl],G_DEBUG='fatal-warnings')
            app.expect('event=control-ready')
            expect_ids([w['id'] for w in local[2:7]])
            assert workspace_probe()['workspace_mode']=='medium'
            assert not icon_settled()['launcher_icon_failed']
            assert icon_probe()['launcher_icon'] == dict(kind='file',value=str(icon_file))
            capture(s,'workspace-medium-restarted-scaled',first['connector'])
            report['cases'].append(dict(name='workspace-mode-persists-after-shell-restart-at-mixed-scale'))
            ipc.close()
            ctl(s,args.ctl,'quit');clean(app)
        report['status'] = 'passed'
    except Exception as error:
        report.update(status='failed', error=str(error)); raise
    finally:
        (args.output / 'metadata.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(status=report['status'], cases=len(report['cases']))))


if __name__ == '__main__':
    main()
