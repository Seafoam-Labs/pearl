#!/usr/bin/env python3
"""Real global taskbar windows, cross-workspace activation and native chooser lifetime."""
import argparse, copy, hashlib, json, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture, click, clean
from test_desktop import keys, desktop
from test_preferences import settled, apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--require-order', action='store_true')
    parser.add_argument('--aqueous-prefix', type=Path, default=ROOT/'.cache/aqueous-activity-production')
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/running-apps')
    args = parser.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve()
    args.output.mkdir(parents=True,exist_ok=True)
    report=dict(status='running',checks={},binaries={n:hashlib.sha256(getattr(args,n).read_bytes()).hexdigest() for n in ('pearl','ctl')})
    def passed(name):
        report['checks'][name]=True;print('PASS',name,flush=True)
    try:
        with PrivateSession(args.output/'session',tool_prefix=args.aqueous_prefix) as s:
            s.args=SimpleNamespace(aqueous_source=str(s.tool_prefix/'source'))
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
            per_window=copy.deepcopy(prefs)
            per_window['bar']['running_apps_per_window']=True
            apply(s,args.ctl,per_window)
            def window_buttons(): return [r for r in strip()['rows'] if r['kind']=='window']
            wait_for(lambda:len(window_buttons())==5)
            assert {r['id'] for r in window_buttons()}=={w['id'] for w in windows()}
            # On an older compositor, the global fallback is opaque ID order.
            if not any(w.get('layout_index') is not None for w in windows()):
                assert [r['id'] for r in window_buttons()]==sorted(w['id'] for w in windows())
            show()
            assert len([r for r in probe()['rows'] if r['kind']=='group'])==3
            close()
            click_strip('window',remote)
            wait_for(lambda:window(remote)['focused'] and not window(remote)['minimized'])
            assert probe()['popup_output'] is None
            apply(s,args.ctl,prefs)
            wait_for(lambda:len([r for r in strip()['rows'] if r['kind']=='group'])==3)
            command('window.minimized',id=remote,value=True)
            passed('per-window-strip-keeps-grouped-chooser-and-activates-exact-window')
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
            publishes_order=all('layout_index' in w for w in windows())
            if args.require_order: assert publishes_order, windows()
            if publishes_order:
                # Put the remaining windows into one tiled scope, then exercise a real
                # compositor reorder while the strip displays individual windows.
                ordered_count=len(windows())
                for w in windows():command('window.move',id=w['id'],workspace=first_ws[0]['id'])
                command('workspace.activate',id=first_ws[0]['id'])
                ctl(s,args.ctl,'layout','set','--output',oid,'--layout','tile')
                def ordered_ids():
                    current=windows()
                    if len(current)!=ordered_count or any(w.get('layout_index') is None for w in current):return None
                    return [w['id'] for w in sorted(current,key=lambda w:(w['layout_index'],w['id']))]
                before=wait_for(ordered_ids)
                apply(s,args.ctl,per_window)
                wait_for(lambda:[r['id'] for r in window_buttons()]==ordered_ids())
                command('window.activate',id=before[0]);wait_for(lambda:window(before[0])['focused'])
                assert ordered_ids()==before
                keyboard.proc.stdin.write('chord 106 65\n');keyboard.proc.stdin.flush()
                wait_for(lambda:ordered_ids() and ordered_ids()!=before)
                wait_for(lambda:[r['id'] for r in window_buttons()]==ordered_ids())
                show();assert len([r for r in probe()['rows'] if r['kind']=='group'])==3;close()
                apply(s,args.ctl,prefs)
                passed('published-layout-order-follows-real-window-move-and-focus-is-stable')
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
            close();apply(s,args.ctl,per_window)
            wait_for(lambda:len(window_buttons())==strip()['shown'])
            assert strip()['shown']<len(windows())
            click_strip('overflow');wait_for(lambda:probe()['popup_output']==oid)
            assert len([r for r in probe()['rows'] if r['kind']=='group'])==36
            passed('per-window-overflow-keeps-all-application-groups-reachable')
            close();many.stop();wait_for(lambda:len(probe()['groups'])==0)
            icon_dir=s.runtime/'icons';icon_dir.mkdir()
            generated=[]
            protocols=Path('/usr/share/wayland-protocols')
            for name,xml in {
                'xdg-shell':protocols/'stable/xdg-shell/xdg-shell.xml',
                'xdg-toplevel-icon':protocols/'staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml',
                'security-context':protocols/'staging/security-context/security-context-v1.xml',
                'single-pixel-buffer':protocols/'staging/single-pixel-buffer/single-pixel-buffer-v1.xml',
            }.items():
                s.run(['wayland-scanner','client-header',xml,icon_dir/(name+'-client-protocol.h')])
                code=icon_dir/(name+'.c');generated.append(code)
                s.run(['wayland-scanner','private-code',xml,code])
            s.run(['cc','-I'+str(icon_dir),s.tool_prefix/'source/compositor/scripts/fixtures/xdg-toplevel-icon.c',*generated,'-lwayland-client','-o',icon_dir/'client'])
            icons=s.child('icons',[icon_dir/'client'],input_pipe=True);icons.expect('"ready":true')
            def icon_command(line):
                icons.proc.stdin.write(line+'\n');icons.proc.stdin.flush();time.sleep(.05)
            for line in ('icon 0','buffer 0 32 32 ffff0000 0','add 0 0 1','window 0 0 1'):icon_command(line)
            wait_for(lambda:len(window_buttons())==1)
            def icon_color(rgb):
                rect=window_buttons()[0]['rect']
                shot=capture(s,'window-icon',first['connector'])
                crop=shot.crop((int(rect['x']),int(rect['y']),int(rect['x']+rect['width']),int(rect['y']+rect['height'])))
                return sum(count for count,pixel in crop.getcolors(crop.width*crop.height) if all(abs(pixel[i]-rgb[i])<8 for i in range(3)))>20
            wait_for(lambda:icon_color((255,0,0)))
            for line in ('icon 1','buffer 1 32 32 ff00ff00 0','add 1 1 1','set 0 1','commit 0'):icon_command(line)
            wait_for(lambda:icon_color((0,255,0)))
            icon_command('set 0 -1');icon_command('commit 0')
            wait_for(lambda:not icon_color((0,255,0)))
            icons.stop();wait_for(lambda:len(probe()['groups'])==0)
            passed('window-icon-pixels-refresh-and-removal-restores-application-icon')
            ctl(s,args.ctl,'running-apps','show','--output',second['id'])
            wait_for(lambda:probe()['popup_output']==second['id'])
            protocol=s.tool_prefix/'source/compositor/protocol/upstream/wlr-output-power-management-unstable-v1.xml'
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
            shell.stop();clean(shell);ipc.close()
            passed('teardown-with-fatal-gtk-warnings-enabled')
        report['status']='passed'
    finally:
        (args.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
