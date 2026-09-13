#!/usr/bin/env python3
"""T06 preview gate: real desktop files, windows, bar actions and private sessions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import sys
import time
from types import SimpleNamespace
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC, ctl, status, eventually_status, click, capture, clean
from t00 import Session as T00Session
FIXTURE = ROOT / 'tests/fixtures/desktop/application.py'


def keys(s, *values):
    argv = ['wtype', '-s', '100']
    for value in values:
        argv += ['-k', value, '-s', '80']
    s.run([*argv, '-s', '100'])


def query(s, binary, text):
    before = status(s, binary)['popup']
    s.run(['wtype', '-s', '80', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', '-k', 'BackSpace', '-s', '50', text, '-s', '100'])
    time.sleep(.12)
    return status(s, binary)['popup']


def desktop(s, name, title, extra='', command=None):
    directory = Path(s.env['XDG_DATA_HOME']) / 'applications'
    directory.mkdir(exist_ok=True)
    path = directory / (name+'.desktop')
    command = command or f'/usr/bin/python3 {FIXTURE} --id org.pearl.{name} --mark {name} --title "{title}"'
    path.write_text(f'[Desktop Entry]\nType=Application\nName={title}\nExec={command}\nIcon=utilities-terminal\n{extra}')
    return path


def entries(s):
    path = Path(s.env['PEARL_TEST_LAUNCH_LOG'])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pearl', type=Path, required=True)
    p.add_argument('--ctl', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/t06/latest')
    args = p.parse_args()
    args.pearl = args.pearl.resolve(); args.ctl = args.ctl.resolve(); args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    result = dict(status='running', checks=checks, pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(), ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'desktop') as s:
            s.env['XDG_DATA_DIRS'] = str(s.base/'empty-system-data')
            Path(s.env['XDG_DATA_DIRS']).mkdir()
            s.env['PEARL_TEST_LAUNCH_LOG'] = str(s.output/'launches.jsonl')
            (s.output/'launches.jsonl').write_text('')
            # Persistent external Aqueous test client supplies an effective us,de
            # keyboard. It is never linked into Pearl and only sees private sockets.
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous')
            keyboard = T00Session.input_fixture(s)
            keyboard.stop()
            keyboard = s.child('keyboard', [s.runtime/'input-fixture/input', 'input'], input_pipe=True)
            keyboard.expect('ready')
            keyboard.proc.stdin.write('reload\n'); keyboard.proc.stdin.flush()
            ipc = IPC(s)
            current = ipc.outputs()
            first, second = list(current.values())[:2]
            s.run(['wlr-randr','--output',second['name'],'--scale','1.5'])
            # Desktop semantics: GIO filters these entries, never Exec parsing in Pearl.
            desktop(s,'Hidden','HiddenSecret','Hidden=true\n')
            desktop(s,'NoDisplay','HiddenSecret','NoDisplay=true\n')
            desktop(s,'NotHere','HiddenSecret','OnlyShowIn=AnotherDesktop;\n')
            desktop(s,'NotAqueous','HiddenSecret','NotShowIn=Aqueous;\n')
            desktop(s,'MissingExec','HiddenSecret','TryExec=pearl-no-such-executable\n')
            desktop(s,'Alpha','Alpha Editor','Keywords=write;documents;\nOnlyShowIn=Aqueous;\n')
            desktop(s,'Beta','Beta Browser')
            localized = desktop(s,'Cafe','Café Notes','Name[de]=Kaffee Notizen\nKeywords=coffee;\n')
            desktop(s,'Actions','Action Suite','Actions=Special;\n\n[Desktop Action Special]\nName=Special action\nExec=/usr/bin/python3 '+str(FIXTURE)+' --id org.pearl.Action --mark special --title SpecialWindow\n')
            working = s.base/'work'; working.mkdir()
            desktop(s,'Fields','Field Codes',f'Path={working}\n', f'/usr/bin/python3 {FIXTURE} --id org.pearl.Fields --mark fields --title %c "%%" %k %U')
            # A private terminal stub proves Terminal=true dispatch without starting
            # any installed terminal. GIO chooses xdg-terminal-exec on this build.
            bindir=s.base/'bin';bindir.mkdir()
            terminal=bindir/'xdg-terminal-exec'
            terminal.write_text('#!/usr/bin/python3\nimport os,sys\nfrom pathlib import Path\nPath(os.environ["PEARL_TEST_TERMINAL_LOG"]).write_text("called")\na=sys.argv[1:]\nwhile a and a[0] in ("--", "-e", "-x"):a.pop(0)\nos.execvp(a[0],a)\n')
            terminal.chmod(0o700)
            s.env['PATH']=str(bindir)+':'+s.env.get('PATH','/usr/bin')
            s.env['PEARL_TEST_TERMINAL_LOG']=str(s.output/'terminal.txt')
            (s.output/'terminal.txt').unlink(missing_ok=True)
            desktop(s,'Terminal','Terminal Launch','Terminal=true\n')
            desktop(s,'org.pearl.Activatable','Bus Launch','DBusActivatable=true\n',command='/usr/bin/false')
            for i in range(2000):
                desktop(s,f'Catalog{i:04d}',f'Catalog Application {i:04d}', command='/usr/bin/true')
            desktop(s,'Long','Long Application '+('wide title ' * 50))
            app = s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings')
            app.expect('event=control-ready'); app.expect('event=app-index-ready')
            live = eventually_status(s,args.ctl,lambda v:len(v['outputs'])==2 and v['apps']['ready'])
            assert live['apps']['count'] == 2009, live['apps']
            tid=first['id']; oid=second['id']
            capture(s,'bar')
            checks['gio-hidden-nodisplay-showin-tryexec-filtering'] = True
            ctl(s,args.ctl,'launcher','show','--output',tid)
            eventually_status(s,args.ctl,lambda v:v['popup'] and v['popup']['results']>0)
            assert query(s,args.ctl,'HiddenSecret')['results']==0
            assert query(s,args.ctl,'Catalog')['results']==200
            keys(s,*(['Down']*20)); capture(s,'launcher-many',first['name'])
            assert query(s,args.ctl,'Café')['results']==1
            capture(s,'launcher',first['name'])
            keys(s,'Return')
            wait_for(lambda:any(e['mark']=='Cafe' for e in entries(s)))
            eventually_status(s,args.ctl,lambda v:v['popup'] is None)
            checks['unicode-ranked-virtualized-search-and-enter-launch'] = True
            # %c, %% and %k are expanded by GIO and Path supplies the working dir.
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Field Codes')['results']==1
            keys(s,'Return')
            record=wait_for(lambda:next((e for e in entries(s) if e['mark']=='fields'),None))
            assert record['title']=='Field Codes' and record['argv'][0]=='%' and record['argv'][1].endswith('/Fields.desktop')
            assert record['cwd']==str(working) and record['endpoint']==s.env['AQUEOUS_SOCKET']
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Special action')['results']==1
            keys(s,'Return');wait_for(lambda:any(e['mark']=='special' for e in entries(s)))
            checks['gio-field-codes-working-directory-desktop-action-and-session-context'] = True
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Terminal Launch')['results']==1
            keys(s,'Return')
            wait_for(lambda:any(e['mark']=='Terminal' for e in entries(s)))
            assert (s.output/'terminal.txt').read_text()=='called'
            busapp=s.child('dbus-app',['python3',FIXTURE,'--id','org.pearl.Activatable','--unique','--mark','dbus','--title','D-Bus Receiver'])
            busapp.expect('event=fixture-ready')
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Bus Launch')['results']==1
            keys(s,'Return')
            wait_for(lambda:len([e for e in entries(s) if e['mark']=='dbus'])==2)
            checks['terminal-semantics-and-private-dbus-activation'] = True
            # Independent windows with identical titles retain distinct runtime IDs.
            one=s.child('one',['python3',FIXTURE,'--id','org.pearl.One','--mark','one','--title','Shared title'])
            two=s.child('two',['python3',FIXTURE,'--id','org.pearl.Two','--mark','two','--title','Shared title'])
            one.expect('event=fixture-ready');two.expect('event=fixture-ready')
            windows=wait_for(lambda:[e for e in ipc.state() if e['kind']=='window' and e.get('title')=='Shared title'])
            wait_for(lambda:len([e for e in ipc.state() if e['kind']=='window' and e.get('title')=='Shared title'])==2)
            windows=sorted([e for e in ipc.state() if e['kind']=='window' and e.get('title')=='Shared title'],key=lambda e:e['id'])
            ipc.call('command',action='window.move',fields=dict(id=windows[1]['id'],output=oid))
            for index,target in enumerate(windows):
                ctl(s,args.ctl,'launcher','show','--output',tid)
                assert query(s,args.ctl,'Shared title')['results']==2
                if index:keys(s,'Down')
                keys(s,'Return')
                wait_for(lambda:any(e['kind']=='seat' and e.get('window')==target['id'] for e in ipc.state()))
            checks['duplicate-titles-activate-by-runtime-id-across-outputs'] = True
            eventually_status(s,args.ctl,lambda v:any(o['title']=='Shared title' for o in v['outputs']))
            excluded=next(w for w in windows if w['app_id']=='org.pearl.One')
            rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.pearl.One"\nskip_switcher = true\n')
            wait_for(lambda:any(e['kind']=='window' and e['id']==excluded['id'] and e['skip_switcher'] for e in ipc.state()))
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Shared title')['results']==1
            rules.write_text('[[window]]\napp_id = "org.pearl.One"\nskip_taskbar = true\n')
            wait_for(lambda:any(e['kind']=='window' and e['id']==excluded['id'] and not e['skip_switcher'] and e['skip_taskbar'] for e in ipc.state()))
            assert query(s,args.ctl,'Shared title')['results']==2
            ctl(s,args.ctl,'launcher','hide')
            ipc.call('command',action='window.minimized',fields=dict(id=windows[0]['id'],value=True))
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Shared title')['results']==2
            capture(s,'minimized-and-visible',first['name'])
            ctl(s,args.ctl,'launcher','hide')
            ipc.call('command',action='window.minimized',fields=dict(id=windows[0]['id'],value=False))
            checks['switcher-exclusion-taskbar-distinction-and-minimized-state'] = True
            # Bar groups are atomically configurable; launcher is mandatory.
            ctl(s,args.ctl,'bar','groups','--output',tid,'--left','launcher,workspaces','--center','title','--right','clock,keyboard,control')
            configured=status(s,args.ctl)
            assert next(o for o in configured['outputs'] if o['id']==tid)['groups']['center']=='title'
            ctl(s,args.ctl,'bar','groups','--output',tid,'--left','workspaces','--center','clock','--right','control',code=2)
            # Restore a deterministic group arrangement for click coordinates.
            ctl(s,args.ctl,'bar','groups','--output',tid,'--left','launcher,workspaces','--center','clock','--right','keyboard,overview,control')
            workspaces=[e for e in ipc.state() if e['kind']=='workspace']
            duplicates={e['number'] for e in workspaces if e['output']==tid}&{e['number'] for e in workspaces if e['output']==oid}
            assert duplicates
            # The second workspace pill on the left targets this output's ID.
            local=sorted([e for e in workspaces if e['output']==tid],key=lambda e:(e['number'],e['id']))
            assert len(local)>=2
            output=ipc.outputs()[tid]
            click(s,output['bounds']['x']+120,output['bounds']['y']+24,ipc.outputs())
            wait_for(lambda:ipc.outputs()[tid]['active_workspace']==local[1]['id'])
            assert ipc.outputs()[oid]['active_workspace'] != local[1]['id']
            ipc.call('command',action='workspace.activate',fields=dict(id=local[-1]['id']))
            wait_for(lambda:ipc.outputs()[tid]['active_workspace']==local[-1]['id'])
            time.sleep(.1)
            capture(s,'workspace-overflow-active',first['name'])
            ipc.call('command',action='workspace.activate',fields=dict(id=local[1]['id']))
            wait_for(lambda:ipc.outputs()[tid]['active_workspace']==local[1]['id'])
            checks['configurable-groups-and-duplicate-workspace-numbers-target-output-id'] = True
            # Effective keyboard names follow the compositor's group/index.
            group=next(e for e in ipc.state() if e['kind']=='keyboard' and len(e['layouts'])>1)
            ipc.call('command',action='keyboard.set',fields=dict(group=group['id'],index=1))
            eventually_status(s,args.ctl,lambda v:all(o['keyboard']==group['layouts'][1] for o in v['outputs']))
            capture(s,'keyboard-effective',first['name'])
            ipc.call('command',action='keyboard.set',fields=dict(group=group['id'],index=0))
            checks['effective-keyboard-layout-follows-authoritative-state'] = True
            # Native layout has one-shot replies. Both get and set are asynchronous.
            ctl(s,args.ctl,'layout','get','--output',tid)
            eventually_status(s,args.ctl,lambda v:bool(v['layout']['value']) and not v['layout']['pending'])
            for layout in ('grid','monocle','float'):
                ctl(s,args.ctl,'layout','set','--output',tid,'--layout',layout)
                eventually_status(s,args.ctl,lambda v:v['layout']['value']==layout and not v['layout']['pending'])
            ctl(s,args.ctl,'control-center','show','--output',tid)
            eventually_status(s,args.ctl,lambda v:v['layout']['value']=='float')
            capture(s,'control-center',first['name'])
            ctl(s,args.ctl,'calendar','toggle','--output',oid)
            assert status(s,args.ctl)['popup']['pane']=='calendar'
            capture(s,'calendar-mixed-scale',second['name'])
            ctl(s,args.ctl,'calendar','toggle','--output',tid)
            capture(s,'calendar',first['name'])
            keys(s,'Escape');eventually_status(s,args.ctl,lambda v:v['popup'] is None)
            checks['calendar-control-center-unavailable-services-and-native-layout-query-set'] = True
            ctl(s,args.ctl,'overview','toggle','--output',tid)
            eventually_status(s,args.ctl,lambda v:v['osd'])
            checks['empty-overview-rejection-has-visible-feedback'] = True
            ipc.call('command',action='workspace.activate',fields=dict(id=local[0]['id']))
            wait_for(lambda:ipc.outputs()[tid]['active_workspace']==local[0]['id'])
            ctl(s,args.ctl,'overview','toggle','--output',tid)
            wait_for(lambda:any(e['kind']=='session' and e.get('overview_output')==tid for e in ipc.state()))
            ctl(s,args.ctl,'overview','toggle','--output',tid)
            checks['overview-control-uses-real-aqueous-action'] = True
            # The shared monitor refreshes without process restart.
            generation=status(s,args.ctl)['apps']['generation']
            added=desktop(s,'Added','Freshly Installed')
            eventually_status(s,args.ctl,lambda v:v['apps']['generation']>generation)
            ctl(s,args.ctl,'launcher','show','--output',oid)
            assert query(s,args.ctl,'Freshly Installed')['results']==1
            added.unlink()
            wait_for(lambda:query(s,args.ctl,'Freshly Installed')['results']==0)
            assert query(s,args.ctl,'Long Application')['results']==1
            capture(s,'long-text-mixed-scale',second['name'])
            checks['monitored-app-install-removal-and-long-text-mixed-scale'] = True
            for scale in ('1.25','2'):
                ctl(s,args.ctl,'launcher','hide')
                s.run(['wlr-randr','--output',second['name'],'--scale',scale])
                ctl(s,args.ctl,'launcher','show','--output',oid)
                query(s,args.ctl,'Catalog')
                capture(s,'launcher-scale-'+scale,second['name'])
            open_times=[]
            for _ in range(8):
                ctl(s,args.ctl,'launcher','hide')
                started=time.monotonic_ns()
                ctl(s,args.ctl,'launcher','show','--output',tid)
                eventually_status(s,args.ctl,lambda v:v['popup'] and v['popup']['latency_us']>0)
                open_times.append((time.monotonic_ns()-started)//1000)
            result['warm_launcher_open_us']=dict(samples=len(open_times),median=statistics.median(open_times),maximum=max(open_times))
            assert max(open_times)<100000, open_times
            # Close during queued searches; callbacks may drain after widgets disappear.
            for _ in range(8):
                ctl(s,args.ctl,'launcher','toggle','--output',tid)
                ctl(s,args.ctl,'launcher','hide')
            ctl(s,args.ctl,'quit'); clean(app)
            checks['fractional-125-150-200-percent-and-pending-search-teardown'] = True
            times=[int(m[1]) for line in app.lines if (m:=re.search(r'latency_us=(\d+)',line))]
            assert times
            result['launcher_latency_us']=dict(samples=len(times),median=statistics.median(times),p95=sorted(times)[min(len(times)-1,int(len(times)*.95))],maximum=max(times))
            assert result['launcher_latency_us']['p95']<50000, result['launcher_latency_us']
            translated=s.child('pearl-german',[args.pearl],G_DEBUG='fatal-warnings',LANGUAGE='de')
            translated.expect('event=control-ready');translated.expect('event=app-index-ready')
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'Kaffee')['results']==1
            capture(s,'launcher-german',first['name'])
            ctl(s,args.ctl,'control-center','show','--output',tid)
            capture(s,'control-center-german',first['name'])
            ctl(s,args.ctl,'quit');clean(translated)
            checks['localized-gio-desktop-labels-and-german-surface-text'] = True
            empty_data=s.base/'empty-data';(empty_data/'applications').mkdir(parents=True)
            empty=s.child('pearl-empty-catalog',[args.pearl],G_DEBUG='fatal-warnings',XDG_DATA_HOME=str(empty_data))
            empty.expect('event=control-ready');empty.expect('event=app-index-ready entries=0')
            assert status(s,args.ctl)['apps']['count']==0
            ctl(s,args.ctl,'launcher','show','--output',tid)
            assert query(s,args.ctl,'NoSuchApplication')['results']==0
            capture(s,'empty-catalog',first['name'])
            ctl(s,args.ctl,'quit');clean(empty)
            checks['empty-gio-catalog-and-no-results-state'] = True
            ipc.close()
        result['status']='passed'
        print('PASS T06 live desktop, discovery, launch, controls and latency',flush=True)
    finally:
        (args.output/'results.json').write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__':main()
