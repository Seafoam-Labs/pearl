#!/usr/bin/env python3
"""Real global taskbar windows, cross-workspace activation and native chooser lifetime."""
import argparse, copy, hashlib, json, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, eventually_status, capture, click, clean
from test_desktop import keys, desktop
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/running-apps')
    args = parser.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve()
    args.output.mkdir(parents=True,exist_ok=True)
    report=dict(status='running',checks={},binaries={n:hashlib.sha256(getattr(args,n).read_bytes()).hexdigest() for n in ('pearl','ctl')})
    def passed(name):
        report['checks'][name]=True;print('PASS',name,flush=True)
    try:
        with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
            s.args=SimpleNamespace(aqueous_source=str(ROOT/'.cache/aqueous-activity-production/source'))
            keyboard=T00Session.input_fixture(s)
            desktop(s,"Tasks0","Workbench","StartupWMClass=org.pearl.Tasks0\nIcon=org.gnome.TextEditor\n")
            ipc=IPC(s)
            shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
            prefs=copy.deepcopy(settled(s,args.ctl)['preferences'])
            prefs['bar']['groups']=dict(left='launcher,workspaces,running_apps',center='clock',right='control')
            apply(s,args.ctl,prefs)
            outputs=status(s,args.ctl)['outputs'];first,second=outputs[:2];oid=first['id']
            def probe():
                result=ctl(s,args.ctl,'aqueous','status','--text','test-running-apps')['result']
                result['rows']=[]
                for offset in range(0,result['row_count'],20):
                    result['rows']+=ctl(s,args.ctl,'aqueous','status','--text','test-running-apps:rows:'+str(offset))['result']
                for strip in result['strips']:
                    strip['rows']=ctl(s,args.ctl,'aqueous','status','--text','test-running-apps:bar:'+strip['output'])['result']
                return result
            def windows():return [e for e in ipc.state() if e['kind']=='window' and (e.get('app_id') or '').startswith('org.pearl.Tasks')]
            def window(wid):return next((e for e in windows() if e['id']==wid),None)
            def command(action,**fields):return ipc.call('command',action=action,fields=fields)
            def chord(text):keyboard.proc.stdin.write(text+'\n');keyboard.proc.stdin.flush();time.sleep(.25)
            def show():ctl(s,args.ctl,'running-apps','show','--output',oid);wait_for(lambda:probe()['popup_output']==oid);time.sleep(.15)
            def close():ctl(s,args.ctl,'popup','hide');wait_for(lambda:probe()['popup_output'] is None)
            def row(kind,id=None):return next((r for r in probe()['rows'] if r['kind']==kind and (id is None or r['id']==id)),None)
            def click_row(kind,id=None):
                value=wait_for(lambda:(lambda r:r if r and r['rect']['width']>0 and r['rect']['height']>0 else None)(row(kind,id)));rect=value['rect'];out=ipc.outputs()[oid]
                click(s,out['usable_bounds']['x']+rect['x']+rect['width']/2,out['usable_bounds']['y']+rect['y']+rect['height']/2,ipc.outputs())
            def strip():return next(x for x in probe()['strips'] if x['output']==oid)
            def click_strip(kind,id=None,secondary=False):
                value=wait_for(lambda:next((r for r in strip()['rows'] if r['kind']==kind and (id is None or r['id']==id) and r['rect']['width']>0 and r['rect']['height']>0),None));rect=value['rect'];out=ipc.outputs()[oid]
                x=out['bounds']['x']+rect['x']+rect['width']/2;y=out['bounds']['y']+rect['y']+rect['height']/2
                click(s,x,y,ipc.outputs())
                if secondary:
                    s.run(['wlrctl','pointer','click','right'])
            assert probe()['groups']==[] and all(not x['rows'] for x in probe()['strips'])
            passed('empty-widget-collapses-and-default-layout-roundtrips')
            fixture=s.child('tasks',['python3',ROOT/'tests/fixtures/desktop/task_windows.py']);fixture.expect('event=tasks-ready')
            wins=wait_for(lambda:(lambda v:v if len(v)==5 else False)(windows()))
            group0=sorted([w for w in wins if w['app_id']=='org.pearl.Tasks0'],key=lambda w:w['title'])
            workspaces=[e for e in ipc.state() if e['kind']=='workspace']
            first_ws=sorted([e for e in workspaces if e['output']==oid],key=lambda e:e['number'])
            second_ws=sorted([e for e in workspaces if e['output']==second['id']],key=lambda e:e['number'])
            for win,ws in zip(group0,[first_ws[0],first_ws[1],second_ws[2]]):command('window.move',id=win['id'],workspace=ws['id'])
            remote=group0[2]['id'];command('window.minimized',id=remote,value=True)
            wait_for(lambda:len(probe()['groups'])==3)
            check=probe();assert all(x['keyboard_mode']=='none' for x in check['strips']);assert next(g for g in check['groups'] if g['key']=='desktop:Tasks0.desktop')['count']==3
            passed('global-groups-include-inactive-workspaces-other-output-and-minimized-windows')
            command('workspace.activate', id=first_ws[4]['id'])
            large_slots=strip()['slots']; all_groups=probe()['groups']
            small=copy.deepcopy(prefs);small['bar']['workspace_mode']='small';apply(s,args.ctl,small)
            wait_for(lambda:strip()['slots']>large_slots)
            assert probe()['groups']==all_groups
            apply(s,args.ctl,prefs)
            wait_for(lambda:strip()['slots']==large_slots)
            passed('small-workspace-mode-frees-task-strip-space-without-changing-global-groups')
            time.sleep(.4);capture(s,'before-click',first['connector']);(s.output/'before-click.json').write_text(json.dumps(probe(),indent=2))
            click_strip('group','desktop:Tasks0.desktop');wait_for(lambda:row('window',remote));capture(s,'horizontal-chooser',first['connector'])
            click_row('window',remote)
            wait_for(lambda:(lambda w:w and w['focused'] and not w['minimized'] and w['workspace']==second_ws[2]['id'])(window(remote)))
            assert probe()['popup_output'] is None
            passed('bar-group-click-selects-restores-and-focuses-exact-remote-window')
            single=next(w for w in wins if w['app_id']=='org.pearl.Tasks1');command('window.move',id=single['id'],workspace=first_ws[2]['id'])
            click_strip('group','app:org.pearl.Tasks1');wait_for(lambda:window(single['id'])['focused']);assert probe()['popup_output'] is None
            passed('single-window-click-activates-without-chooser')
            show();keys(s,'Down');assert any(r['focused'] for r in probe()['rows']);keys(s,'Escape');wait_for(lambda:probe()['popup_output'] is None)
            passed('cli-keyboard-entry-arrows-escape-and-bar-focus-policy')
            show();click_row('group','desktop:Tasks0.desktop');wait_for(lambda:row('window',group0[0]['id']))
            command('window.close',id=group0[0]['id']);wait_for(lambda:row('window',group0[0]['id']) is None)
            click_row('window',group0[1]['id']);wait_for(lambda:window(group0[1]['id'])['focused'])
            passed('open-chooser-refreshes-after-window-close-without-stale-callback')
            show();click_row('group','desktop:Tasks0.desktop');wait_for(lambda:row('window',remote))
            duplicate=desktop(s,'TasksDuplicate','Other Workbench','StartupWMClass=org.pearl.Tasks0\n')
            wait_for(lambda:any(g['key']=='app:org.pearl.Tasks0' for g in probe()['groups']))
            wait_for(lambda:row('window',remote))
            duplicate.unlink();wait_for(lambda:any(g['key']=='desktop:Tasks0.desktop' for g in probe()['groups']))
            wait_for(lambda:row('window',remote));close()
            passed('catalog-rescan-reclassifies-group-without-losing-chooser')
            rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            for flag in ('skip_switcher','skip_taskbar'):
                rules.write_text('[[window]]\napp_id = "org.pearl.TasksFilter"\n'+flag+' = true\n')
                command('session.reload')
                time.sleep(.4)
                filtered=s.child('filtered-'+flag,['python3',ROOT/'tests/fixtures/desktop/application.py','--id','org.pearl.TasksFilter'])
                filtered.expect('event=fixture-ready')
                wait_for(lambda:any(w['app_id']=='org.pearl.TasksFilter' and w[flag] for w in windows()))
                wait_for(lambda:len(probe()['groups'])==(4 if flag=='skip_switcher' else 3))
                filtered.stop();wait_for(lambda:len(probe()['groups'])==3)
            rules.write_text('');command('session.reload')
            passed('taskbar-exclusion-does-not-confuse-switcher-exclusion')
            for edge in ('left','right','bottom','top'):
                changed=copy.deepcopy(prefs);changed['bar']['edge']=edge;apply(s,args.ctl,changed)
                wait_for(lambda:next(x for x in status(s,args.ctl)['outputs'] if x['id']==oid)['bar_edge']==edge)
                show();click_row('group','desktop:Tasks0.desktop');wait_for(lambda:row('window',remote));capture(s,'chooser-'+edge,first['connector']);close()
                assert strip()['keyboard_mode']=='none'
            passed('all-four-bar-edges-and-clamped-chooser')
            changed=copy.deepcopy(prefs);changed['bar']['size']=32
            without=copy.deepcopy(changed);without['bar']['groups']['left']='launcher,workspaces';apply(s,args.ctl,without)
            time.sleep(.3);minimum=next(x for x in status(s,args.ctl)['outputs'] if x['id']==oid)['bar_size']
            apply(s,args.ctl,changed)
            wait_for(lambda:next(x for x in status(s,args.ctl)['outputs'] if x['id']==oid)['bar_size']<=minimum)
            capture(s,'compact-bar',first['connector']);apply(s,args.ctl,prefs)
            passed('compact-bar-keeps-application-counts-without-growing-the-edge')
            changed=copy.deepcopy(prefs)
            changed['outputs']=[dict(connector=second['connector'],bar=dict(edge='top',size=48,groups=dict(left='launcher',center='clock',right='control')))]
            apply(s,args.ctl,changed);wait_for(lambda:len(probe()['strips'])==1)
            assert len(probe()['groups'])==3
            apply(s,args.ctl,prefs);wait_for(lambda:len(probe()['strips'])==2)
            passed('per-output-placement-preserves-global-window-scope')
            s.run(['wlr-randr','--output',second['connector'],'--scale','1.5'])
            changed=copy.deepcopy(prefs);changed['font_size']=20;changed['theme']['mode']='gtk';changed['bar']['edge']='left'
            apply(s,args.ctl,changed);show();click_row('group','desktop:Tasks0.desktop');wait_for(lambda:row('window',remote))
            assert all(r['rect']['width']<=48 for r in strip()['rows'])
            capture(s,'gtk-large-text-mixed-scale',first['connector']);close()
            apply(s,args.ctl,prefs);s.run(['wlr-randr','--output',second['connector'],'--scale','1'])
            passed('gtk-theme-large-text-and-mixed-scale')
            fixture.stop();wait_for(lambda:len(probe()['groups'])==0)
            many=s.child('many',['python3',ROOT/'tests/fixtures/desktop/task_windows.py','--groups','36','--windows','70']);many.expect('event=tasks-ready',timeout=30)
            wait_for(lambda:len(probe()['groups'])==36,timeout=30)
            assert next(g for g in probe()['groups'] if g['key']=='desktop:Tasks0.desktop')['count']==70
            assert strip()['shown']<36
            click_strip('overflow');wait_for(lambda:probe()['popup_output']==oid);capture(s,'overflow',first['connector']);close()
            show();click_row('group','desktop:Tasks0.desktop');wait_for(lambda:row('more'))
            # Keyboard traversal scrolls to the last currently loaded row.
            for _ in range(51):keys(s,'Down')
            assert row('more')['focused'];keys(s,'Return');wait_for(lambda:len([r for r in probe()['rows'] if r['kind']=='window'])==70)
            passed('more-than-32-apps-and-64-windows-remain-reachable')
            close();many.stop();wait_for(lambda:len(probe()['groups'])==0)
            ctl(s,args.ctl,'running-apps','show','--output',second['id'])
            wait_for(lambda:probe()['popup_output']==second['id'])
            protocol=ROOT/'.cache/aqueous-activity-production/source/compositor/protocol/upstream/wlr-output-power-management-unstable-v1.xml'
            power_dir=s.runtime/'output-power';power_dir.mkdir()
            # The cached compositor's SPDX comment precedes its XML declaration.
            normalized=power_dir/'protocol.xml'
            normalized.write_text(protocol.read_text().replace('<?xml version="1.0" encoding="UTF-8"?>',''))
            protocol=normalized
            s.run(['wayland-scanner','client-header',protocol,power_dir/'output-power.h'])
            s.run(['wayland-scanner','private-code',protocol,power_dir/'output-power.c'])
            s.run(['cc','-I'+str(power_dir),ROOT/'tests/fixtures/desktop/output_power.c',power_dir/'output-power.c','-lwayland-client','-o',power_dir/'output-power'])
            s.run([power_dir/'output-power',second['connector'],'off'])
            wait_for(lambda:len(status(s,args.ctl)['outputs'])==1 and probe()['popup_output'] is None)
            passed('powered-off-output-removes-surfaces-and-dismisses-chooser')
            # Published layout_index drives strip and chooser order; focus never reorders.
            order=s.child('tasks-order',['python3',ROOT/'tests/fixtures/desktop/task_windows.py']);order.expect('event=tasks-ready')
            wait_for(lambda:len(windows())==5)
            order_ws=first_ws[3]
            pair=[next(w for w in windows() if w['app_id']=='org.pearl.Tasks1'),next(w for w in windows() if w['app_id']=='org.pearl.Tasks2')]
            for w in pair:command('window.move',id=w['id'],workspace=order_ws['id'])
            command('workspace.activate',id=order_ws['id'])
            wait_for(lambda:all((window(w['id']) or {}).get('workspace')==order_ws['id'] for w in pair))
            def indices():return {w['id']:w.get('layout_index') for w in windows() if w['id'] in (pair[0]['id'],pair[1]['id'])}
            def group_order(rows):
                ids=[r['id'] for r in rows if r['id'] in ('app:org.pearl.Tasks1','app:org.pearl.Tasks2')]
                assert len(ids)==2,rows
                return ids
            def expected_groups(values):
                return ['app:org.pearl.Tasks1','app:org.pearl.Tasks2'] if values[pair[0]['id']]<values[pair[1]['id']] else ['app:org.pearl.Tasks2','app:org.pearl.Tasks1']
            def focus_first():
                current=wait_for(lambda:(lambda v:v if len(v)==2 and None not in v.values() else False)(indices()))
                first=min(current,key=lambda k:current[k])
                command('window.activate',id=first)
                wait_for(lambda:window(first)['focused'])
                return current
            def swapped(before,tag):
                # A no-op reorder must fail loudly instead of passing on stale values.
                values=wait_for(lambda:(lambda v:v if len(v)==2 and None not in v.values() and v!=before and sorted(v.values())==sorted(before.values()) else False)(indices()),timeout=10)
                assert group_order(strip()['rows'])==expected_groups(values),(tag,strip()['rows'])
                show();assert group_order(probe()['rows'])==expected_groups(values),(tag,probe()['rows'])
                capture(s,tag,first['connector']);close()
                return values
            def set_layout(name):
                ctl(s,args.ctl,'layout','set','--output',oid,'--layout',name)
                eventually_status(s,args.ctl,lambda v:v['layout']['value']==name and not v['layout']['pending'])
            set_layout('scrolling')
            start=focus_first()
            assert group_order(strip()['rows'])==expected_groups(start)
            chord('chord 106 65')
            current=swapped(start,'order-scrolling-window-move')
            other=pair[1]['id'] if window(pair[0]['id'])['focused'] else pair[0]['id']
            command('window.activate',id=other);wait_for(lambda:window(other)['focused']);time.sleep(.4)
            assert indices()==current and group_order(strip()['rows'])==expected_groups(current)
            passed('scrolling-window-move-reorders-strip-and-chooser-focus-does-not')
            set_layout('tile')
            start=focus_first()
            chord('chord 106 65')
            swapped(start,'order-tile-window-move')
            passed('tile-window-move-reorders-through-layout-swap')
            wm=Path(s.env['AQUEOUS_CONFIG']);wm.write_text(wm.read_text()+'\n[keybinds]\nmove_column_left = "Super+Shift+H"\nmove_column_right = "Super+Shift+L"\n')
            command('session.reload');time.sleep(.4)
            set_layout('scrolling')
            start=focus_first()
            # Guarantee the focused window starts its own left column; a
            # leftmost single-window column is already expelled and stays put.
            chord('chord 105 65')
            assert indices()==start
            chord('chord 38 65')
            swapped(start,'order-scrolling-column-move')
            passed('column-move-reorders-both-windows')
            per_window=copy.deepcopy(prefs);per_window['bar']['running_apps_per_window']=True;apply(s,args.ctl,per_window)
            def window_rows():
                rows=wait_for(lambda:(lambda v:v if v and all(r['kind']=='window' for r in v) else False)([r for r in strip()['rows'] if r['kind'] in ('group','window')]))
                return rows
            def pair_rows(rows):return [r['id'] for r in rows if r['id'] in (pair[0]['id'],pair[1]['id'])]
            def expected_windows():
                values=wait_for(lambda:(lambda v:v if len(v)==2 and None not in v.values() else False)(indices()))
                return [pair[0]['id'],pair[1]['id']] if values[pair[0]['id']]<values[pair[1]['id']] else [pair[1]['id'],pair[0]['id']]
            rows=window_rows()
            assert len(rows)==5 and pair_rows(rows)==expected_windows(),rows
            show();assert group_order(probe()['rows'])==expected_groups(indices());close()
            capture(s,'per-window-strip',first['connector'])
            before=indices();focus_first();chord('chord 106 65')
            wait_for(lambda:(lambda v:v!=before and len(v)==2 and None not in v.values())(indices()),timeout=10)
            wait_for(lambda:pair_rows(window_rows())==expected_windows(),timeout=10)
            apply(s,args.ctl,prefs)
            wait_for(lambda:(lambda v:v and all(r['kind']=='group' for r in v))(strip()['rows']))
            before=indices();other=pair[1]['id'] if window(pair[0]['id'])['focused'] else pair[0]['id']
            command('window.activate',id=other);wait_for(lambda:window(other)['focused']);time.sleep(.4)
            assert indices()==before and group_order(strip()['rows'])==expected_groups(before)
            passed('per-window-toggle-switches-strip-only-and-keeps-chooser-grouped')
            keyboard.stop();order.stop();wait_for(lambda:len(probe()['groups'])==0)
            shell.stop();clean(shell);ipc.close()
            passed('teardown-with-fatal-gtk-warnings-enabled')
        report['status']='passed'
    finally:
        (args.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
