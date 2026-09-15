#!/usr/bin/env python3
"""T12 and native-lock foundation: private login1/polkit and real GTK/PAM surfaces."""
import argparse, hashlib, json, os, signal, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from t00 import Session as T00Session
from test_surfaces import IPC,ctl,status,capture,clean

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('pearl','ctl','locker','pam-module'): p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/t12/latest')
    args=p.parse_args()
    for name in ('pearl','ctl','locker','pam_module','output'): setattr(args,name,getattr(args,name).resolve())
    args.output.mkdir(parents=True,exist_ok=True)
    checks={}; report={'status':'running','checks':checks,'binaries':{name:hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ('pearl','ctl','locker','pam_module')}}
    try:
        with PrivateSession(args.output/'session') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            s.env['PEARL_SECURITY_LOG']=str(s.output/'security.jsonl');Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            s.env['PEARL_TEST_LOCKER']=str(args.locker)
            s.env['PEARL_TEST_SESSION_DISCOVERY']='no-pid'
            pam_dir=s.base/'pam';pam_dir.mkdir();s.env['PEARL_TEST_PAM_DIR']=str(pam_dir)
            pam_stack=f'auth required {args.pam_module}\naccount required {args.pam_module}\n'
            (pam_dir/'pearl').write_text(pam_stack)
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
            fixture=s.child('authority',['python3',ROOT/'tests/fixtures/session_security.py'],input_pipe=True);fixture.expect('event=ready')
            pearl=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');pearl.expect('event=control-ready')
            ipc=IPC(s)
            def state(): return ctl(s,args.ctl,'lifecycle','status')['result']
            def wait(predicate,timeout=12): return wait_for(lambda:(lambda value:value if predicate(value) else False)(state()),timeout)
            def command(**data):
                fixture.proc.stdin.write(json.dumps(data)+'\n');fixture.proc.stdin.flush();fixture.expect('command='+json.dumps(data,sort_keys=True));time.sleep(.1)
            def records():
                path=Path(s.env['PEARL_SECURITY_LOG']);return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
            def preferences_ready():
                return wait_for(lambda:(lambda value:value if not value['busy'] else False)(ctl(s,args.ctl,'preferences','status')['result']))
            def locked(): return next(x for x in ipc.state() if x['kind']=='session')['locked']
            def action(name,code=0): return ctl(s,args.ctl,'lifecycle','action','--text',name,code=code)
            def key(*args): s.run(['wtype','-s','150',*args,'-s','200'])
            def unlock(secret='fixture-secret'):
                key('fixture-user','-k','Return');time.sleep(.3);key(secret,'-k','Return')
            ready=wait(lambda v:v['active'] and v['authentication']['registered'] and v['delay_inhibitor'] and v['idle_available'])
            assert ready['session_id']=='test' and ready['session_error'] is None
            assert any(r.get('method')=='GetUser' for r in records())
            checks['user-service-without-pid-session-registers-for-display-session']=True
            # Manager sessions must resolve the real display session too. A
            # missing display, foreign UID or greeter must never register.
            for discovery in ('manager','missing','foreign','greeter','direct'):
                command(discovery=discovery,restart='org.freedesktop.login1')
                wait(lambda v:not v['authentication']['registered'])
                if discovery in ('missing','foreign','greeter'):
                    value=wait(lambda v:v['session_error'] is not None)
                    assert not value['active'] and value['session_id']=='' and not value['authentication']['registered'],value
                else:
                    wait(lambda v:v['active'] and v['authentication']['registered'] and v['session_error'] is None)
            command(discovery='missing',restart='org.freedesktop.login1')
            wait(lambda v:v['session_error'] is not None and not v['authentication']['registered'])
            command(discovery='no-pid',session_new=True)
            wait(lambda v:v['active'] and v['authentication']['registered'] and v['session_error'] is None and v['delay_inhibitor'])
            command(begin=True);wait(lambda v:v['authentication']['pending'])
            command(active=False);wait(lambda v:not v['active'] and not v['authentication']['pending'])
            command(active=True);wait(lambda v:v['active'])
            checks['display-session-validation-recovery-and-inactivity-cancellation']=True
            checks['logind-session-native-idle-and-authority-registration']=True
            output=status(s,args.ctl)['outputs'][0]
            ctl(s,args.ctl,'control-center','show');time.sleep(.3);capture(s,'session-controls',output['connector']);ctl(s,args.ctl,'popup','hide')
            # Authority requests are sender-checked and cancellation is a real deferred D-Bus result.
            command(begin=True);wait(lambda v:v['authentication']['pending'] and v['authentication']['identities']==2)
            time.sleep(.3);capture(s,'polkit-identities',output['connector'])
            command(cancel=True);wait(lambda v:not v['authentication']['pending'])
            assert any(r['event']=='authentication' and r['outcome']=='cancelled' for r in records())
            command(begin=True,unsupported=True);wait(lambda v:not v['authentication']['pending'])
            checks['authority-identities-cancellation-and-unsupported-identity']=True
            command(begin=True);wait(lambda v:v['authentication']['pending'])
            command(restart='org.freedesktop.PolicyKit1');wait(lambda v:v['authentication']['registered'] and not v['authentication']['pending'])
            command(begin=True);wait(lambda v:v['authentication']['pending']);key('-k','Escape');wait(lambda v:not v['authentication']['pending'])
            checks['authority-restart-and-escape-cleanup']=True
            action('logout');assert state()['pending']=='logout'
            ctl(s,args.ctl,'lifecycle','action','--text','confirm','--generation','999999',code=4)
            action('cancel');assert state()['pending'] is None
            command(inhibit='sleep');action('suspend');generation=state()['confirmation']
            ctl(s,args.ctl,'lifecycle','action','--text','confirm','--generation',str(generation));wait(lambda v:not v['busy'])
            assert not locked() and not any(r['event']=='Suspend' for r in records())
            checks['confirmation-generation-and-sleep-inhibitor']=True
            command(inhibit='')
            ctl(s,args.ctl,'lock');wait(lambda v:v['lock']['ready'] and v['lock']['locked']);assert locked()
            checks['native-lock-acquisition-acknowledgement']=True
            time.sleep(.5)
            other=next(o for o in ipc.outputs().values() if o['name']!=output['connector'])
            s.run(['wlr-randr','--output',other['name'],'--off']);assert locked()
            s.run(['wlr-randr','--output',other['name'],'--on']);time.sleep(.4);assert locked()
            checks['output-removal-return-remains-locked']=True
            # Aqueous may forbid screenshots during lock; record that restriction explicitly.
            r=s.run(['grim','-o',output['connector'],s.output/'native-lock.png'],check=False)
            report['locked_capture_allowed']=r.returncode==0
            unlock('incorrect');time.sleep(.6);assert locked()
            key('-k','Escape');assert locked();time.sleep(2.1)
            # After cancellation the entry is disabled; Tab reaches the retry button.
            key('-k','Tab','-k','Return');time.sleep(.4)
            unlock();wait_for(lambda:not locked());wait(lambda v:not v['lock']['ready'])
            checks['pam-multi-message-failure-cancellation-and-success']=True
            # Each independent locker loads Pearl's persisted Material/GTK choice.
            original=ctl(s,args.ctl,'preferences','status')['result']['preferences']
            for variant in ('light','gtk'):
                prefs=preferences_ready()
                settings=json.loads(json.dumps(original))
                settings['theme']['mode']='gtk' if variant=='gtk' else 'static'
                settings['theme']['variant']='light'
                if variant=='gtk': settings['theme']['gtk_name']='Adwaita'
                ctl(s,args.ctl,'preferences','apply','--revision',str(prefs['revision']),'--text',json.dumps(settings))
                wait_for(lambda:not ctl(s,args.ctl,'preferences','status')['result']['busy'])
                ctl(s,args.ctl,'lock');wait(lambda v:v['lock']['ready'] and v['lock']['locked'])
                time.sleep(.6);capture(s,'native-lock-'+variant,output['connector'])
                unlock();wait_for(lambda:not locked());wait(lambda v:not v['lock']['ready'])
            prefs=preferences_ready()
            ctl(s,args.ctl,'preferences','apply','--revision',str(prefs['revision']),'--text',json.dumps(original))
            wait_for(lambda:not ctl(s,args.ctl,'preferences','status')['result']['busy'])
            checks['native-lock-material-light-and-gtk-theme']=True
            suspend_start=len(records())
            action('suspend');generation=state()['confirmation'];ctl(s,args.ctl,'lifecycle','action','--text','confirm','--generation',str(generation))
            wait(lambda v:v['lock']['locked'] and v['lock']['ready'] and v['lock']['preparing'])
            wait_for(lambda:any(r['event']=='Suspend' for r in records()))
            assert all(r['locked'] for r in records()[suspend_start:] if r['event'] in ('Suspend','delay-released'))
            command(prepare=False);wait(lambda v:v['delay_inhibitor'] and not v['lock']['preparing'])
            unlock();wait_for(lambda:not locked())
            checks['suspend-lock-before-call-delay-release-and-resume-rearm']=True
            # External sleep preparation must also acquire the real lock before release.
            command(prepare=True);wait(lambda v:v['lock']['locked'] and v['lock']['ready'] and not v['delay_inhibitor'])
            command(prepare=False);wait(lambda v:v['delay_inhibitor']);unlock();wait_for(lambda:not locked())
            checks['external-sleep-preparation']=True
            # Actual compositor idle, not injected service success.
            prefs=preferences_ready()
            settings=prefs['preferences'];settings['idle']={'ac':{'lock_seconds':2,'suspend_seconds':4},'battery':{'lock_seconds':3,'suspend_seconds':5}}
            ctl(s,args.ctl,'preferences','apply','--revision',str(prefs['revision']),'--text',json.dumps(settings))
            wait(lambda v:v['policy']['lock_seconds']==2)
            action('inhibit');command(battery=True);wait(lambda v:v['on_battery'] and v['policy']['lock_seconds']==3)
            command(battery=False);wait(lambda v:not v['on_battery'] and v['policy']['lock_seconds']==2)
            checks['ac-battery-policy-selection']=True
            time.sleep(4.3);assert not locked()
            action('uninhibit');wait(lambda v:v['lock']['locked'] and v['lock']['ready'],8)
            wait(lambda v:v['lock']['preparing'],8)
            assert all(r['locked'] for r in records() if r['event']=='Suspend')
            action('inhibit');command(prepare=False);unlock();wait_for(lambda:not locked())
            checks['actual-idle-policy-pause-and-automatic-suspend']=True
            command(restart='org.freedesktop.login1');wait(lambda v:v['active'] and v['delay_inhibitor'])
            checks['logind-restart']=True
            command(active=False);wait(lambda v:not v['active']);action('suspend',code=4)
            command(active=True);wait(lambda v:v['active'])
            checks['inactive-session-actions-gated']=True
            # A denied PAM account check must never unlock after a successful password.
            (pam_dir/'pearl').write_text(f'auth required {args.pam_module}\naccount required pam_deny.so\n')
            ctl(s,args.ctl,'lock');wait(lambda v:v['lock']['ready'] and v['lock']['locked']);unlock();time.sleep(.5);assert locked()
            (pam_dir/'pearl').write_text(pam_stack);key('-k','Escape');time.sleep(2.1);key('-k','Tab','-k','Return');time.sleep(.3);unlock();wait_for(lambda:not locked())
            checks['account-policy-denial-never-unlocks']=True
            # Shell shutdown must leave the native locker alive and allow normal unlock.
            ctl(s,args.ctl,'lock');wait(lambda v:v['lock']['ready'] and v['lock']['locked']);ctl(s,args.ctl,'quit');clean(pearl);assert locked();unlock();wait_for(lambda:not locked())
            checks['shell-exit-preserves-independent-lock']=True
            # Failure and false-ready fixtures cannot authorize a suspend.
            policy_file=Path(s.env['XDG_CONFIG_HOME'])/'pearl/preferences.json'
            current=json.loads(policy_file.read_text());current['idle']={'ac':{},'battery':{}};policy_file.write_text(json.dumps(current))
            count_suspend=sum(r['event']=='Suspend' for r in records())
            bad=s.base/'false-locker';bad.write_text('#!/usr/bin/python3\nimport os,time\nos.write(3,b"L")\ntime.sleep(10)\n');bad.chmod(0o700)
            s.env['PEARL_TEST_LOCKER']=str(bad)
            failure=s.child('pearl-false-lock',[args.pearl],G_DEBUG='fatal-warnings');failure.expect('event=control-ready')
            wait(lambda v:v['active'] and v['delay_inhibitor']);action('suspend');generation=state()['confirmation']
            ctl(s,args.ctl,'lifecycle','action','--text','confirm','--generation',str(generation))
            wait(lambda v:v['lock']['failed'],12)
            assert not locked() and sum(r['event']=='Suspend' for r in records())==count_suspend
            command(prepare=True);time.sleep(.4);assert state()['delay_inhibitor']
            command(prepare=False)
            ctl(s,args.ctl,'quit');clean(failure)
            checks['false-ready-times-out-no-suspend-and-failed-preparation-retains-delay']=True
            s.env['PEARL_TEST_LOCKER']=str(args.locker)
            recovery=s.child('pearl-recovery',[args.pearl],G_DEBUG='fatal-warnings');recovery.expect('event=control-ready')
            wait(lambda v:v['active'] and v['delay_inhibitor']);ctl(s,args.ctl,'lock');live=wait(lambda v:v['lock']['locked'] and v['lock']['ready'])
            os.kill(int(live['locker_pid']),signal.SIGKILL);wait(lambda v:v['locker_pid'] is None and v['lock']['failed']);assert locked()
            ctl(s,args.ctl,'lock');wait(lambda v:v['lock']['locked'] and v['lock']['ready']);unlock();wait_for(lambda:not locked())
            checks['locker-crash-fails-closed-and-aqueous-allows-authenticated-recovery']=True
            ctl(s,args.ctl,'lock');wait(lambda v:v['lock']['locked'] and v['lock']['ready'])
            os.kill(recovery.proc.pid,signal.SIGKILL);assert recovery.wait()==-signal.SIGKILL
            assert locked();unlock();wait_for(lambda:not locked())
            checks['shell-sigkill-preserves-owned-locker-and-authentication']=True
            command(restart='org.freedesktop.PolicyKit1')
            recovery=s.child('pearl-after-crash',[args.pearl],G_DEBUG='fatal-warnings');recovery.expect('event=control-ready')
            wait(lambda v:v['active'] and v['delay_inhibitor'])
            action('logout');generation=state()['confirmation'];ctl(s,args.ctl,'lifecycle','action','--text','confirm','--generation',str(generation))
            assert recovery.wait()==0,recovery.lines[-20:]
            assert any('reason=aqueous-logout' in line for line in recovery.lines),recovery.lines[-20:]
            checks['acknowledged-aqueous-logout-stops-shell']=True
            ipc.close()
            assert not any(word in line for line in pearl.lines for word in ('CRITICAL','WARNING','panic:','fixture-secret','incorrect'))
            report['status']='passed'
    except BaseException:
        report['status']='failed'
        raise
    finally:
        (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
