#!/usr/bin/env python3
"""T07: real private libpulse server and delayed/denied power-service fixtures."""
import argparse, hashlib, json, os, signal, socket, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import IPC,ctl,status,eventually_status,capture,clean,click
from t00 import Session as T00Session
FIX=ROOT/'tests/fixtures/services'

def services(s,binary):
    result=ctl(s,binary,'services','status')['result']
    page=result['audio']['next_offset']
    while page is not None:
        more=ctl(s,binary,'services','status','--offset',str(page))['result']
        result['audio']['devices'].extend(more['audio']['devices']); page=more['audio']['next_offset']
    return result
def await_services(s,binary,predicate,timeout=15):
    def check():
        r=s.run([binary,'services','status'],check=False)
        if r.returncode: return False
        value=services(s,binary)
        return value if predicate(value) else False
    return wait_for(check,timeout)
def service_focus(child):
    return next((line.rsplit('=',1)[-1] for line in reversed(child.lines) if 'event=services-focus target=' in line),'')
def command(child,**data):
    child.proc.stdin.write(json.dumps(data)+'\n'); child.proc.stdin.flush()
    child.expect('command='+json.dumps(data,sort_keys=True))
def records(s):
    p=Path(s.env['PEARL_TEST_POWER_LOG'])
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
def burst(s,binary,op,values,**fields):
    snapshot=status(s,binary)
    path=s.runtime/'pearl'/snapshot['session']/'control.sock'
    # Reuse one same-UID connection per request; no subprocess overhead obscures coalescing.
    for i,value in enumerate(values):
        req=dict(pearl=1,id=str(i+1),session=snapshot['session'],display=str(s.runtime/s.env['WAYLAND_DISPLAY']),op=op,**fields,**value)
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as sock:
            sock.connect(str(path)); sock.sendall(json.dumps(req).encode()+b'\n')
            reply=json.loads(sock.makefile('rb').readline()); assert reply['ok'],reply

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--pearl',type=Path,required=True); p.add_argument('--ctl',type=Path,required=True); p.add_argument('--output',type=Path,default=ROOT/'artifacts/t07/latest'); args=p.parse_args()
    args.pearl=args.pearl.resolve(); args.ctl=args.ctl.resolve(); args.output=args.output.resolve(); args.output.mkdir(parents=True,exist_ok=True)
    checks={}; result=dict(status='running',checks=checks,pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'services') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
            system_bus=s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            s.env['PULSE_SERVER']='unix:'+str(s.runtime/'pulse/native')
            s.env['PIPEWIRE_REMOTE']='pipewire-0'
            s.env['PEARL_TEST_BACKLIGHT']=str(s.base/'backlight'); root=Path(s.env['PEARL_TEST_BACKLIGHT']); (root/'test_panel').mkdir(parents=True)
            (root/'test_panel/max_brightness').write_text('1000\n'); (root/'test_panel/brightness').write_text('420\n')
            s.env['PEARL_TEST_POWER_LOG']=str(s.output/'power-actions.jsonl'); Path(s.env['PEARL_TEST_POWER_LOG']).write_text('')
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous'); keyboard=T00Session.input_fixture(s)
            power=s.child('power',['python3',FIX/'power.py'],input_pipe=True); power.expect('event=ready')
            native=s.child('pipewire',['pipewire','-c',FIX/'pipewire.conf']); wait_for(lambda:(s.runtime/'pipewire-0').is_socket())
            pulse=s.child('pulse',['pipewire-pulse','-c',FIX/'pulse.conf']); wait_for(lambda:(s.runtime/'pulse/native').is_socket())
            wait_for(lambda:s.run(['pactl','info'],check=False).returncode==0)
            modules=[]
            for name in ('test_output_a','test_output_b'):
                modules.append(s.run(['pactl','load-module','module-null-sink',f'sink_name={name}',f'sink_properties=device.description={name}']).stdout.strip())
            wait_for(lambda:'test_output_b' in s.run(['pactl','list','short','sinks']).stdout)
            s.run(['pactl','set-default-sink','test_output_a']); s.run(['pactl','set-default-source','test_output_a.monitor'])
            # Minimal fixture policy publishes effective defaults separately from configured defaults.
            s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_output_a"}','Spa:String:JSON'])
            s.run(['pw-metadata','-n','default','0','default.audio.source','{"name":"test_output_a"}','Spa:String:JSON'])
            pearl=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings',WAYLAND_DEBUG='client'); pearl.expect('event=control-ready')
            live=await_services(s,args.ctl,lambda v:v['audio']['ready'] and v['audio']['count']>=4 and v['power']['can_reboot'] and v['brightness']['available'] and all(v['power']['profiles']))
            assert live['power']['battery_present'] and live['power']['percentage']==72.5 and live['brightness']['percent']==42,live
            checks['initial-audio-battery-logind-profiles-and-validated-backlight']=True
            ui_output=status(s,args.ctl)['outputs'][0]
            ctl(s,args.ctl,'control-center','show','--output',ui_output['id']); time.sleep(.4); capture(s,'control-center-audio-power',ui_output['connector'])
            (s.output/'initial-state.json').write_text(json.dumps(services(s,args.ctl),indent=2)+'\n')
            for _ in range(40):
                s.run(['wtype','-s','100','-k','Tab','-s','35'])
                if service_focus(pearl)=='brightness': break
            else: raise AssertionError('Brightness keyboard focus missing')
            # Let GTK reveal the complete power card before the visual capture.
            for _ in range(5): s.run(['wtype','-s','100','-k','Tab','-s','35'])
            time.sleep(.3)
            capture(s,'battery-brightness-profiles',ui_output['connector'])
            ctl(s,args.ctl,'popup','hide'); ctl(s,args.ctl,'control-center','show','--output',ui_output['id'])
            devices=live['audio']['devices']; first=next(d for d in devices if d['name']=='test_output_a'); second=next(d for d in devices if d['name']=='test_output_b')
            gen=live['audio']['generation']
            burst(s,args.ctl,'audio_set',[{'volume':n} for n in range(5,81)],kind='sink',device=first['index'],generation=gen)
            final=await_services(s,args.ctl,lambda v:not v['audio']['pending'] and any(d['index']==first['index'] and d['kind']=='sink' and d['volume']==80 for d in v['audio']['devices']))
            assert '80%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout
            ctl(s,args.ctl,'audio','set','--kind','sink','--mute','true')
            await_services(s,args.ctl,lambda v:any(d['name']=='test_output_a' and d['mute'] for d in v['audio']['devices']))
            # A queued drag belongs to its captured device even if the default changes.
            burst(s,args.ctl,'audio_set',[{'volume':n} for n in range(20,68)],kind='sink',device=first['index'],generation=gen)
            s.run(['pactl','set-default-sink','test_output_b'])
            s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_output_b"}','Spa:String:JSON'])
            await_services(s,args.ctl,lambda v:v['audio']['default_sink']==second['index'] and not v['audio']['pending'] and any(d['name']=='test_output_a' and d['volume']==67 for d in v['audio']['devices']))
            ctl(s,args.ctl,'audio','set','--kind','sink','--volume','31')
            await_services(s,args.ctl,lambda v:any(d['name']=='test_output_b' and d['volume']==31 for d in v['audio']['devices']))
            assert '67%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout
            s.run(['pactl','set-sink-volume','test_output_a','20%','60%'])
            await_services(s,args.ctl,lambda v:any(d['name']=='test_output_a' and d['volume']==60 for d in v['audio']['devices']))
            ctl(s,args.ctl,'audio','set','--kind','sink','--generation',str(gen),'--device',str(first['index']),'--volume','90')
            await_services(s,args.ctl,lambda v:any(d['name']=='test_output_a' and d['volume']==90 for d in v['audio']['devices']))
            balance=s.run(['pactl','get-sink-volume','test_output_a']).stdout
            assert '30%' in balance and '90%' in balance,balance
            # The service setter selects the configured default; fixture policy then publishes it.
            ctl(s,args.ctl,'audio','set','--kind','sink','--generation',str(gen),'--device',str(first['index']),'--default','true')
            wait_for(lambda:'test_output_a' in s.run(['pw-metadata','-n','default','0','default.configured.audio.sink']).stdout)
            s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_output_a"}','Spa:String:JSON'])
            await_services(s,args.ctl,lambda v:v['audio']['default_sink']==first['index'])
            pulse.proc.send_signal(signal.SIGSTOP)
            try:
                ctl(s,args.ctl,'audio','set','--kind','sink','--volume','12')
                await_services(s,args.ctl,lambda v:v['audio']['in_flight'])
                burst(s,args.ctl,'audio_set',[{'volume':n} for n in range(30,74)],kind='sink',device=first['index'],generation=gen)
            finally: pulse.proc.send_signal(signal.SIGCONT)
            await_services(s,args.ctl,lambda v:not v['audio']['pending'] and any(d['name']=='test_output_a' and d['volume']==73 for d in v['audio']['devices']))
            checks['rapid-volume-final-value-mute-balance-and-default-change-bind-identity']=True
            # Pulse-compatible playback and recording streams are real separate clients.
            playback=s.child('playback',['pacat','--playback','--raw','--device=test_output_b','/dev/zero'])
            recording=s.child('recording',['pacat','--record','--raw','--device=test_output_a.monitor','/dev/null'])
            stream=await_services(s,args.ctl,lambda v:any(d['kind']=='playback' for d in v['audio']['devices']) and any(d['kind']=='recording' for d in v['audio']['devices']))
            play=next(d for d in stream['audio']['devices'] if d['kind']=='playback')
            ctl(s,args.ctl,'audio','set','--kind','playback','--generation',str(gen),'--device',str(play['index']),'--volume','45','--mute','true','--target',str(first['index']))
            await_services(s,args.ctl,lambda v:any(d['kind']=='playback' and d['volume']==45 and d['mute'] and d['target']==first['index'] for d in v['audio']['devices']))
            record_stream=next(d for d in stream['audio']['devices'] if d['kind']=='recording')
            ctl(s,args.ctl,'audio','set','--kind','recording','--generation',str(gen),'--device',str(record_stream['index']),'--volume','36','--mute','true')
            await_services(s,args.ctl,lambda v:any(d['kind']=='recording' and d['volume']==36 and d['mute'] for d in v['audio']['devices']))
            checks['playback-recording-streams-volume-mute-and-routing']=True
            playback.stop(); recording.stop()
            command(power,delay=250)
            ctl(s,args.ctl,'brightness','set','--percent','18')
            await_services(s,args.ctl,lambda v:v['brightness']['in_flight'])
            burst(s,args.ctl,'brightness_set',[{'percent':n} for n in range(1,89)])
            await_services(s,args.ctl,lambda v:not v['brightness']['pending'] and v['brightness']['percent']==88)
            assert (root/'test_panel/brightness').read_text().strip()=='880'
            writes=[r for r in records(s) if r['kind']=='brightness']; assert len(writes)<10,writes
            ctl(s,args.ctl,'profile','set','--profile','power-saver')
            await_services(s,args.ctl,lambda v:v['power']['profile_in_flight'])
            burst(s,args.ctl,'profile_set',[{'profile':n%3} for n in range(33)])
            await_services(s,args.ctl,lambda v:not v['power']['pending'] and v['power']['profile']=='performance')
            profile_writes=[r for r in records(s) if r['kind']=='profile']; assert len(profile_writes)<10,profile_writes
            checks['delayed-brightness-and-profile-writes-coalesce-final-intent']=True
            command(power,delay=1200)
            ctl(s,args.ctl,'profile','set','--profile','balanced')
            await_services(s,args.ctl,lambda v:v['power']['profile_in_flight'])
            ctl(s,args.ctl,'profile','set','--profile','power-saver')
            command(power,deny='brightness',delay=150)
            ctl(s,args.ctl,'brightness','set','--percent','15')
            denied=await_services(s,args.ctl,lambda v:v['power']['err'] is not None and 'Permission denied' in v['power']['err'])
            assert denied['brightness']['percent']==88
            eventually_status(s,args.ctl,lambda v:'Permission denied' in v['osd_text'])
            capture(s,'permission-denied',ui_output['connector'])
            await_services(s,args.ctl,lambda v:not v['power']['pending'] and v['power']['profile']=='power-saver')
            checks['brightness-denial-preserves-independent-pending-profile-intent']=True
            command(power,deny=True)
            ctl(s,args.ctl,'profile','set','--profile','balanced')
            await_services(s,args.ctl,lambda v:not v['power']['pending'] and v['power']['err'] is not None and 'Permission denied' in v['power']['err'])
            assert services(s,args.ctl)['power']['profile']=='power-saver'
            checks['permission-denied-retains-authoritative-value-and-visible-error']=True
            command(power,deny=False,battery=24.0,present=False,active=False)
            await_services(s,args.ctl,lambda v:not v['power']['battery_present'] and not v['brightness']['available'])
            response=ctl(s,args.ctl,'brightness','set','--percent','50',code=4); assert response['err']['code']=='Unavailable',response
            command(power,active=True,present=True)
            await_services(s,args.ctl,lambda v:v['brightness']['available'] and v['power']['percentage']==24.0)
            command(power,preparing=True)
            await_services(s,args.ctl,lambda v:v['power']['preparing'] and not v['brightness']['available'])
            command(power,preparing=False)
            checks['battery-removal-session-inactive-and-logind-preparation']=True
            # Remove the validated fixture device; no privileged file writes are used.
            (root/'test_panel/brightness').unlink(); (root/'test_panel/max_brightness').unlink(); (root/'test_panel').rmdir()
            await_services(s,args.ctl,lambda v:not v['brightness']['available'])
            checks['backlight-removal-does-not-crash-open-panel']=True
            # Owner loss drops an in-flight profile plus the queued replacement.
            command(power,delay=2000)
            ctl(s,args.ctl,'profile','set','--profile','performance'); time.sleep(.1)
            ctl(s,args.ctl,'profile','set','--profile','power-saver'); power.stop()
            await_services(s,args.ctl,lambda v:not any(v['power']['profiles']) and not v['power']['can_reboot'])
            power=s.child('power-restarted',['python3',FIX/'power.py'],input_pipe=True); power.expect('event=ready')
            await_services(s,args.ctl,lambda v:all(v['power']['profiles']) and v['power']['can_reboot'])
            time.sleep(.4); assert services(s,args.ctl)['power']['profile']=='balanced'
            checks['power-owner-restart-discards-old-pending-actions']=True
            power.stop()
            await_services(s,args.ctl,lambda v:not any(v['power']['profiles']))
            power=s.child('power-legacy',['python3',FIX/'power.py'],input_pipe=True,PEARL_TEST_LEGACY_PROFILES='1'); power.expect('event=ready')
            await_services(s,args.ctl,lambda v:all(v['power']['profiles']))
            ctl(s,args.ctl,'profile','set','--profile','power-saver')
            await_services(s,args.ctl,lambda v:not v['power']['pending'] and v['power']['profile']=='power-saver')
            checks['legacy-power-profile-service-fallback']=True
            power.stop(); system_bus.stop()
            await_services(s,args.ctl,lambda v:not v['power']['can_reboot'])
            system_bus=s.child('system-bus-restarted',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            power=s.child('power-after-bus',['python3',FIX/'power.py'],input_pipe=True); power.expect('event=ready')
            await_services(s,args.ctl,lambda v:all(v['power']['profiles']) and v['power']['can_reboot'],timeout=20)
            checks['system-bus-restart-does-not-exit-shell']=True
            pulse.stop()
            await_services(s,args.ctl,lambda v:not v['audio']['ready'] and v['audio']['count']==0)
            capture(s,'audio-disconnected',ui_output['connector'])
            pulse=s.child('pulse-restarted',['pipewire-pulse','-c',FIX/'pulse.conf']); wait_for(lambda:s.run(['pactl','info'],check=False).returncode==0)
            s.run(['pactl','load-module','module-null-sink','sink_name=test_restarted'])
            await_services(s,args.ctl,lambda v:v['audio']['ready'] and v['audio']['generation']>gen and any(d['name']=='test_restarted' for d in v['audio']['devices']))
            response=ctl(s,args.ctl,'audio','set','--kind','sink','--generation',str(gen),'--device',str(first['index']),'--volume','50',code=4)
            assert response['err']['code']=='Unavailable',response
            checks['audio-server-restart-reenumerates-and-rejects-stale-generation']=True
            ctl(s,args.ctl,'popup','hide')
            fixture=s.child('window',['python3',ROOT/'tests/fixtures/desktop/application.py','--id','org.pearl.ServiceTest','--mark','services','--title','Service focus test'])
            ipc=IPC(s); window=wait_for(lambda:next((e for e in ipc.state() if e['kind']=='window'),None)); ipc.call('command',action='window.activate',fields={'id':window['id']})
            before=next(e for e in ipc.state() if e['kind']=='seat')
            eventually_status(s,args.ctl,lambda v:not v['osd'])
            before_osd=sum('get_layer_surface' in line and '"pearl:osd"' in line for line in pearl.lines)
            burst(s,args.ctl,'osd_show',[{'text':f'Volume {n}%','duration_ms':800} for n in range(50)])
            after=next(e for e in ipc.state() if e['kind']=='seat'); assert (before['focus_kind'],before['window'])==(after['focus_kind'],after['window'])
            assert status(s,args.ctl)['osd_text']=='Volume 49%'
            capture(s,'coalesced-osd',ui_output['connector'])
            assert sum('get_layer_surface' in line and '"pearl:osd"' in line for line in pearl.lines)==before_osd+1
            eventually_status(s,args.ctl,lambda v:not v['osd'])
            checks['rapid-osd-replacement-keeps-focus-and-expires']=True
            ctl(s,args.ctl,'control-center','show','--output',ui_output['id'])
            def focus_name():
                return next((line.rsplit('=',1)[-1] for line in reversed(pearl.lines) if 'event=services-focus target=' in line),'')
            for _ in range(60):
                s.run(['wtype','-s','100','-k','Tab','-s','35'])
                if focus_name()=='reboot': break
            else: raise AssertionError('Could not focus the real restart button')
            command(power,deny=True)
            s.run(['wtype','-s','100','-k','space','-s','400'])
            assert not any(r['kind']=='Reboot' for r in records(s))
            capture(s,'power-confirmation',ui_output['connector'])
            s.run(['wtype','-s','100','-k','space','-s','400'])
            await_services(s,args.ctl,lambda v:v['power']['err'] is not None and 'Permission denied' in v['power']['err'])
            assert any(r['kind']=='Reboot' and r.get('denied') for r in records(s))
            command(power,deny=False)
            for _ in range(60):
                if focus_name()=='reboot': break
                s.run(['wtype','-s','100','-k','Tab','-s','35'])
            s.run(['wtype','-s','100','-k','space','-s','400','-k','space','-s','400'])
            wait_for(lambda:any(r['kind']=='Reboot' and r.get('accepted') for r in records(s)))
            checks['real-power-button-requires-confirmation-and-reflects-denial-and-acceptance']=True
            # Shutdown cancels/drains pending workers and D-Bus replies while views close.
            command(power,delay=2000)
            ctl(s,args.ctl,'profile','set','--profile','performance'); ctl(s,args.ctl,'control-center','show'); ctl(s,args.ctl,'quit'); clean(pearl)
            assert not any(r['kind']=='PowerOff' for r in records(s)),records(s)
            checks['pending-service-shutdown-and-no-incidental-power-off']=True
            ipc.close()
        result['status']='passed'
    finally:
        (args.output/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS T07 audio, power, brightness and OSD services')
if __name__=='__main__': main()
