#!/usr/bin/env python3
"""S4 live audio, power, notifications and media in the normal Settings window."""
import argparse,json,time,wave,signal
from pathlib import Path
from test_settings_app import *
from test_settings_appearance import click,type_text,ready
from test_settings_services import Peer,find,navigate
from test_services import command,await_services,FIX
from test_session_services import FIX as SESSION_FIX,notified,state as session_state

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('settings','pearl','ctl','spike'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s4/devices')
    args=p.parse_args()
    for name in ('settings','pearl','ctl','spike','output'):setattr(args,name,getattr(args,name).resolve())
    args.output.mkdir(parents=True,exist_ok=True);checks={};report=dict(status='running',checks=checks)
    try:
      with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-082') as s:
        ipc=IPC(s);s.env['GSETTINGS_BACKEND']='memory'
        wm=Path(s.env['AQUEOUS_CONFIG']);wm.write_text(wm.read_text().replace('"floating"','"stacking"'))
        output=next(iter(ipc.outputs().values()));s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
        rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml';rules.write_text('[[window]]\napp_id="'+APP_ID+'"\nfloating=true\nwidth=1040\nheight=850\n');ipc.call('command',action='session.reload',fields={})
        s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
        s.child('system',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']]);wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
        s.env['PEARL_TEST_BACKLIGHT']=str(s.base/'backlight');root=Path(s.env['PEARL_TEST_BACKLIGHT']);(root/'test_panel').mkdir(parents=True)
        (root/'test_panel/max_brightness').write_text('1000\n');(root/'test_panel/brightness').write_text('420\n')
        s.env['PEARL_TEST_POWER_LOG']=str(s.output/'power-actions.jsonl');Path(s.env['PEARL_TEST_POWER_LOG']).write_text('')
        power=s.child('power',['python3',FIX/'power.py'],input_pipe=True);power.expect('event=ready')
        s.env['PULSE_SERVER']='unix:'+str(s.runtime/'pulse/native');s.env['PIPEWIRE_REMOTE']='pipewire-0'
        s.child('pipewire',['pipewire','-c',FIX/'pipewire.conf']);wait_for(lambda:(s.runtime/'pipewire-0').is_socket())
        s.child('pulse',['pipewire-pulse','-c',FIX/'pulse.conf']);wait_for(lambda:(s.runtime/'pulse/native').is_socket())
        wait_for(lambda:s.run(['pactl','info'],check=False).returncode==0)
        for name in ('test_output_a','test_output_b'):s.run(['pactl','load-module','module-null-sink','sink_name='+name,'sink_properties=device.description='+name])
        wait_for(lambda:'test_output_b' in s.run(['pactl','list','short','sinks']).stdout)
        s.run(['pactl','set-default-sink','test_output_a']);s.run(['pactl','set-default-source','test_output_a.monitor'])
        s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_output_a"}','Spa:String:JSON'])
        s.run(['pw-metadata','-n','default','0','default.audio.source','{"name":"test_output_a"}','Spa:String:JSON'])
        s.env['PEARL_TEST_SESSION_LOG']=str(s.output/'clients.jsonl');Path(s.env['PEARL_TEST_SESSION_LOG']).write_text('')
        clients=s.child('clients',['python3',SESSION_FIX],input_pipe=True);clients.expect('event=ready')
        shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        live=await_services(s,args.ctl,lambda v:v['audio']['ready'] and v['audio']['count']>=4 and v['brightness']['available'] and all(v['power']['profiles']))
        app=s.child('settings',[args.settings,'--page','sound'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        peer=Peer(s,ipc);peer.enter('sound')
        first=next(d for d in live['audio']['devices'] if d['name']=='test_output_a');row='sink:'+str(first['index'])
        click(s,ipc,row+'/volume');type_text(s,'55');keys(s,'Tab')
        wait_for(lambda:'55%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout)
        click(s,ipc,row+'/mute');wait_for(lambda:'yes' in s.run(['pactl','get-sink-mute','test_output_a']).stdout)
        checks['sound-pointer-volume-mute-real-libpulse']=True
        # Real application streams exercise nested device choices and routing.
        playback=s.child('playback',['pacat','--playback','--raw','--rate=48000','--channels=2'],input_pipe=True)
        playback.proc.stdin.write('0'*4096);playback.proc.stdin.flush()
        wait_for(lambda:any(r['id'].startswith('playback:') for r in peer.page()['live']['rows']))
        navigate(s,ipc,'sound');ready(s,ipc)
        stream=next(r for r in peer.page()['live']['rows'] if r['id'].startswith('playback:'))
        target=next(c for c in stream['controls'] if c['id']=='target');assert len(target['choices'])>=2
        r=peer.live_action(target,target=int(target['choices'][-1]['value']));assert r['ok'] and r['result']['state']!='failed',r
        checks['application-stream-target-choices-and-routing']=True
        navigate(s,ipc,'power');ready(s,ipc);peer.enter('power')
        click(s,ipc,'power/brightness');type_text(s,'63');keys(s,'Tab')
        wait_for(lambda:(root/'test_panel/brightness').read_text().strip()=='630')
        click(s,ipc,'power/performance');await_services(s,args.ctl,lambda v:v['power']['profile']=='performance' and not v['power']['pending'])
        capture(s,'power-real-controls',output['name'])
        checks['power-pointer-brightness-and-profile-with-stable-generation']=True
        command(power,deny='profile')
        r=peer.live_action(find(peer.page(),'power','power-saver'));assert r['ok'],r
        operation=r['result']['operation'];result=wait_for(lambda:(v if (v:=peer.call('operation.get',operation=operation))['result']['state']!='pending' else False))
        assert result['result']['state']=='failed',result
        command(power,deny=False);checks['denied-power-operation-receipt-and-feedback']=True
        # Confirmation is connection scoped and still only calls the private peer.
        page=peer.page();r=peer.live_action(find(page,'session','reboot'));assert r['result']['state']=='succeeded',r
        confirm=find(peer.page(),'session','reboot');assert 'confirmation' in json.loads(confirm['params'])
        other=Peer(s,ipc);other.enter('power');foreign=other.live_action(confirm);assert foreign['result']['state']=='failed',foreign
        own=peer.live_action(confirm);assert own['result']['state']!='failed',own
        wait_for(lambda:any(json.loads(line)['kind']=='Reboot' for line in Path(s.env['PEARL_TEST_POWER_LOG']).read_text().splitlines()))
        other.close();checks['power-confirmation-cannot-be-used-by-another-peer']=True
        navigate(s,ipc,'notifications');ready(s,ipc);peer.enter('notifications')
        click(s,ipc,'notifications/dnd');wait_for(lambda:session_state(s,args.ctl)['notifications']['dnd'])
        ident=notified(s,clients,summary='Standalone notification',body='Private fixture notification',resident=True)
        wait_for(lambda:any(r['title']=='Standalone notification' for r in peer.page()['live']['rows']))
        row=next(r for r in peer.page()['live']['rows'] if r['title']=='Standalone notification')
        r=peer.live_action(next(c for c in row['controls'] if c['id']=='dismiss'));assert r['result']['state']=='succeeded',r
        checks['notifications-dnd-history-and-stable-dismissal']=True
        navigate(s,ipc,'overview');ready(s,ipc);page=peer.enter('overview')
        media=next(r for r in page['live']['rows'] if any(c['op']=='media.action' for c in r['controls']))
        r=peer.live_action(next(c for c in media['controls'] if c['id']=='pause'));assert r['ok'],r
        wait_for(lambda:session_state(s,args.ctl)['media']['players'][0]['playback']=='Paused')
        click(s,ipc,media['id']+'/seek');type_text(s,'60');keys(s,'Tab')
        wait_for(lambda:session_state(s,args.ctl)['media']['players'][0]['position']==60000000)
        command(clients,capability='CanSeek',value=False)
        wait_for(lambda:not next(c for r in peer.page()['live']['rows'] if r['id']==media['id'] for c in r['controls'] if c['id']=='seek')['enabled'])
        checks['overview-media-actions-and-capability-state']=True
        for mode,variant in [('static','dark'),('static','light'),('gtk','light')]:
            apply_preferences(s,args.ctl,theme=dict(mode=mode,variant=variant))
            for page in ('sound','power','notifications'):
                navigate(s,ipc,page);ready(s,ipc);time.sleep(.2);capture(s,page+'-'+mode+'-'+variant,output['name'])
        rules.write_text('[[window]]\napp_id="'+APP_ID+'"\nfloating=true\nwidth=480\nheight=700\n');ipc.call('command',action='session.reload',fields={});time.sleep(.4)
        for page in ('sound','power','notifications','overview'):
            navigate(s,ipc,page);ready(s,ipc);v=probe(s,ipc);assert v['width']==480 and v['narrow'],v
            assert v['body_bounds']['height']>100;capture(s,page+'-narrow',output['name'])
        checks['live-pages-dark-light-native-and-480px-layout']=True
        # Lock hides the normal window and revokes the live page lease.
        locker=s.child('locker',[args.spike],input_pipe=True,PEARL_T00_ISOLATED='1',WLR_BACKENDS='headless',PEARL_T00_MODE='plain');locker.expect('T00 event=ready')
        locker.proc.stdin.write('lock\n');locker.proc.stdin.flush();locker.expect('T00 event=locked')
        wait_for(lambda:not probe(s,ipc)['visible'])
        denied=peer.call('power.action',view=peer.view,operation='f'*32,reboot=True)
        assert not denied['ok'] and denied['err']['code']=='Locked',denied
        locker.proc.stdin.write('unlock\n');locker.proc.stdin.flush();locker.expect('T00 event=unlocked');time.sleep(.3)
        assert not probe(s,ipc)['visible'];navigate(s,ipc,'power');wait_for(lambda:probe(s,ipc)['visible']);ready(s,ipc)
        locker.proc.stdin.write('quit\n');locker.proc.stdin.flush();clean(locker)
        checks['lock-hides-window-denies-actions-and-requires-activation']=True
        app.stop();clean(app);peer.close();playback.stop();shell.stop();clean(shell)
      report['status']='passed'
    except Exception as exc:report.update(status='failed',error=repr(exc));raise
    finally:(args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
