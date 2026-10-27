#!/usr/bin/env python3
"""S4 live audio, power, notifications and media in the normal Settings window."""
import argparse,json,time,wave,signal,uuid
from pathlib import Path
from test_settings_app import *
from pearl_session import fixture_prefix, fixture_source
from test_settings_appearance import click,type_text,ready
from test_settings_services import Peer,find,navigate
from test_services import command,await_services,FIX
from test_session_services import FIX as SESSION_FIX,notified,state as session_state

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('settings','pearl','ctl','spike'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s4/devices')
    p.add_argument('--sound-only',action='store_true')
    p.add_argument('--power-only',action='store_true')
    args=p.parse_args()
    for name in ('settings','pearl','ctl','spike','output'):setattr(args,name,getattr(args,name).resolve())
    args.output.mkdir(parents=True,exist_ok=True);checks={};report=dict(status='running',checks=checks)
    try:
      with PrivateSession(args.output/'session',tool_prefix=fixture_prefix()) as s:
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
        if args.power_only:command(power,present=False,on_battery=False)
        s.env['PULSE_SERVER']='unix:'+str(s.runtime/'pulse/native');s.env['PIPEWIRE_REMOTE']='pipewire-0'
        s.child('pipewire',['pipewire','-c',FIX/'pipewire.conf']);wait_for(lambda:(s.runtime/'pipewire-0').is_socket())
        pulse=s.child('pulse',['pipewire-pulse','-c',FIX/'pulse.conf']);wait_for(lambda:(s.runtime/'pulse/native').is_socket())
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
        names={d['label'] for d in peer.page()['live']['sound']['devices']}
        assert 'test_output_a' in names and 'test_output_b' in names,names
        if not args.power_only:
            first=next(d for d in live['audio']['devices'] if d['name']=='test_output_a');row='sink:'+str(first['index'])
            click(s,ipc,row+'/volume');type_text(s,'55');keys(s,'Tab')
            wait_for(lambda:'55%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout)
            click(s,ipc,row+'/mute');wait_for(lambda:'yes' in s.run(['pactl','get-sink-mute','test_output_a']).stdout)
            checks['sound-pointer-volume-mute-real-libpulse']=True
            # Retained sliders and exact numeric entry share the real audio value.
            click(s,ipc,row+'/slider');keys(s,'Home');keys(s,'Right')
            wait_for(lambda:'1%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout)
            assert next(c for c in probe(s,ipc)['controls'] if c['field']==row+'/slider')['focused']
            click(s,ipc,row+'/volume');type_text(s,'55');keys(s,'Tab')
            wait_for(lambda:'55%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout)
            click(s,ipc,row+'/mute');wait_for(lambda:'no' in s.run(['pactl','get-sink-mute','test_output_a']).stdout)
            assert '55%' in s.run(['pactl','get-sink-volume','test_output_a']).stdout
            second=next(d for d in live['audio']['devices'] if d['name']=='test_output_b');other_row='sink:'+str(second['index'])
            assert other_row+'/volume' not in [c['field'] for c in probe(s,ipc)['controls']]
            click(s,ipc,'sound/other-outputs')
            click(s,ipc,other_row+'/volume');type_text(s,'37');keys(s,'Tab')
            wait_for(lambda:'37%' in s.run(['pactl','get-sink-volume','test_output_b']).stdout)
            assert s.run(['pactl','get-default-sink']).stdout.strip()=='test_output_a'
            click(s,ipc,'sound/other-outputs')
            click(s,ipc,row+'/menu');click(s,ipc,other_row+'/default')
            # This fixture has no session manager; acknowledge its configured default.
            wait_for(lambda:'test_output_b' in s.run(['pw-metadata','-n','default','0','default.configured.audio.sink']).stdout)
            s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_output_b"}','Spa:String:JSON'])
            wait_for(lambda:s.run(['pactl','get-default-sink']).stdout.strip()=='test_output_b')
            wait_for(lambda:any(c['field']==other_row+'/menu' for c in probe(s,ipc)['controls']))
            click(s,ipc,other_row+'/menu');click(s,ipc,row+'/default')
            wait_for(lambda:'test_output_a' in s.run(['pw-metadata','-n','default','0','default.configured.audio.sink']).stdout)
            s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_output_a"}','Spa:String:JSON'])
            wait_for(lambda:s.run(['pactl','get-default-sink']).stdout.strip()=='test_output_a')
            checks['sound-slider-focus-mute-preserves-volume-and-device-selection']=True
            # Real application streams exercise nested device choices and routing.
            playback=s.child('playback',['pacat','--playback','--raw','--rate=48000','--channels=2'],input_pipe=True)
            playback.proc.stdin.write('0'*4096);playback.proc.stdin.flush()
            wait_for(lambda:any(r['id'].startswith('playback:') for r in peer.page()['live']['rows']))
            assert 'test_output_a' in {d['label'] for d in peer.page()['live']['sound']['devices']}
            navigate(s,ipc,'sound');ready(s,ipc)
            stream=next(r for r in peer.page()['live']['rows'] if r['id'].startswith('playback:'))
            target=next(c for c in stream['controls'] if c['id']=='target');assert len(target['choices'])>=2
            r=peer.live_action(target,target=int(target['choices'][-1]['value']));assert r['ok'] and r['result']['state']!='failed',r
            checks['application-stream-target-choices-and-routing']=True
            wait_for(lambda:next(d for d in peer.page()['live']['sound']['devices'] if d['kind']=='playback')['target']==int(target['choices'][-1]['value']))
            click(s,ipc,stream['id']+'/menu')
            wait_for(lambda:any(c['field']==stream['id']+'/default' and c['enabled'] for c in probe(s,ipc)['controls']))
            capture(s,'sound-stream-menu',output['name'])
            click(s,ipc,stream['id']+'/default')
            (s.output/'sound-after-route.json').write_text(json.dumps(dict(probe=probe(s,ipc),live=peer.page()),indent=2))
            wait_for(lambda:next(d for d in peer.page()['live']['sound']['devices'] if d['kind']=='playback')['target']==first['index'])
            recorder=s.child('recorder',['parec','--raw','--rate=48000','--channels=2'])
            wait_for(lambda:any(d['kind']=='recording' for d in peer.page()['live']['sound']['devices']))
            capture(s,'sound-streams',output['name'])
            recorder.stop()
            wait_for(lambda:not any(d['kind']=='recording' for d in peer.page()['live']['sound']['devices']))
            checks['sound-stream-menu-routing-and-recording-hotplug']=True
            # The grouped view must include inventory beyond the legacy 16-row page.
            modules=[s.run(['pactl','load-module','module-null-sink','sink_name=extra_'+str(i)]).stdout.strip() for i in range(8)]
            wait_for(lambda:len(peer.page()['live']['sound']['devices'])>=21)
            assert len(peer.page()['live']['rows'])==16
            click(s,ipc,'sound/other-outputs')
            devices=peer.page()['live']['sound']['devices']
            ids={c['field'] for c in probe(s,ipc)['controls']}
            assert all('sink:'+str(d['index'])+'/volume' in ids for d in devices if d['kind']=='sink')
            for module in modules:s.run(['pactl','unload-module',module])
            wait_for(lambda:len(peer.page()['live']['sound']['devices'])==5)
            checks['sound-complete-inventory-beyond-generic-pagination']=True
            # Sound-specific presentation checks run independently of power/media.
            if args.sound_only:
                ctl(s,args.ctl,'session','action','--command','dnd_on')
                source=next(d for d in peer.page()['live']['sound']['devices'] if d['kind']=='source' and d['is_default'])
                source_row='source:'+str(source['index'])
                click(s,ipc,source_row+'/volume');type_text(s,'42');keys(s,'Tab')
                wait_for(lambda:'42%' in s.run(['pactl','get-source-volume','test_output_a.monitor']).stdout)
                click(s,ipc,source_row+'/mute')
                wait_for(lambda:'yes' in s.run(['pactl','get-source-mute','test_output_a.monitor']).stdout)
                assert '42%' in s.run(['pactl','get-source-volume','test_output_a.monitor']).stdout
                checks['sound-input-volume-and-mute']=True
                long_name='Studio_headphones_with_a_deliberately_long_device_name_for_wrapping'
                long_module=s.run(['pactl','load-module','module-null-sink','sink_name=test_long','sink_properties=device.description='+long_name]).stdout.strip()
                wait_for(lambda:any(d['label']==long_name for d in peer.page()['live']['sound']['devices']))
                s.run(['pactl','set-default-sink','test_long'])
                s.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"test_long"}','Spa:String:JSON'])
                first=wait_for(lambda:next((d for d in peer.page()['live']['sound']['devices'] if d['label']==long_name and d['is_default']),None))
                row='sink:'+str(first['index'])
                for width,height,font,mode,variant in [(1040,850,14,'static','dark'),(440,760,14,'static','light'),(360,700,14,'static','dark'),(480,760,24,'static','dark'),(440,760,14,'gtk','light')]:
                    apply_preferences(s,args.ctl,theme=dict(mode=mode,variant=variant),font_size=font)
                    rules.write_text('[[window]]\napp_id="'+APP_ID+'"\nfloating=true\nwidth='+str(width)+'\nheight='+str(height)+'\n')
                    ipc.call('command',action='session.reload',fields={})
                    app.stop();clean(app)
                    app=s.child('settings-'+str(width)+'-'+str(font)+'-'+mode,[args.settings,'--page','sound'],G_DEBUG='fatal-warnings')
                    app.expect('event=settings-window-created');ready(s,ipc)
                    wait_for(lambda:any(c['field']==row+'/volume' for c in probe(s,ipc)['controls']))
                    time.sleep(.3)
                    v=probe(s,ipc);assert v['width']==width,v
                    body=v['body_bounds']
                    for c in v['controls']:
                        if c['field'].startswith(('sink:','source:','playback:','sound/')):
                            bounds=c['bounds'];assert bounds and bounds['width']>0,c
                            assert bounds['x']>=body['x'] and bounds['x']+bounds['width']<=body['x']+body['width']+1,(width,font,c,body)
                    capture(s,'sound-'+str(width)+'-'+str(font)+'-'+mode+'-'+variant,output['name'])
                    click(s,ipc,row+'/volume');type_text(s,'58');keys(s,'Tab')
                    wait_for(lambda:'58%' in s.run(['pactl','get-sink-volume','test_long']).stdout)
                checks['sound-long-names-dark-light-native-360px-and-large-text']=True
                playback.stop()
                wait_for(lambda:not any(d['kind']=='playback' for d in peer.page()['live']['sound']['devices']))
                checks['sound-empty-application-list']=True
                s.run(['pactl','unload-module',long_module])
                wait_for(lambda:not any(d['index']==first['index'] and d['kind']=='sink' for d in peer.page()['live']['sound']['devices']))
                wait_for(lambda:row+'/volume' not in [c['field'] for c in probe(s,ipc)['controls']])
                capture(s,'sound-device-removed',output['name'])
                checks['sound-default-device-removal']=True
                pulse.stop()
                wait_for(lambda:not peer.page()['live']['sound']['ready'])
                wait_for(lambda:not any(c['field'].startswith(('sink:','source:')) for c in probe(s,ipc)['controls']))
                capture(s,'sound-unavailable',output['name'])
                s.child('pulse-reconnected',['pipewire-pulse','-c',FIX/'pulse.conf'])
                wait_for(lambda:s.run(['pactl','info'],check=False).returncode==0)
                s.run(['pactl','load-module','module-null-sink','sink_name=reconnected'])
                wait_for(lambda:peer.page()['live']['sound']['ready'] and len(peer.page()['live']['sound']['devices'])>0)
                capture(s,'sound-reconnected',output['name'])
                checks['sound-service-loss-and-reconnection']=True
                app.stop();clean(app);peer.close();shell.stop();clean(shell)
                report['status']='passed'
                print(json.dumps(report,indent=2))
                return
        navigate(s,ipc,'power');ready(s,ipc);peer.enter('power')
        if args.power_only:
            wait_for(lambda:'power/battery' not in {c['field'] for c in probe(s,ipc)['controls']})
            assert not peer.page()['live']['power']['battery_present']
            capture(s,'power-no-battery-startup',output['name'])
            checks['power-no-battery-at-startup']=True
            command(power,present=True,on_battery=True,battery=73)
            wait_for(lambda:peer.page()['live']['power']['battery_present'])
            wait_for(lambda:'power/battery' in {c['field'] for c in probe(s,ipc)['controls']})
            time.sleep(.3) # Let GTK allocate the inserted status card before pointer input.
        selected_display = peer.page()['live']['power']['selected_display']
        click(s,ipc,'power/display'); keys(s,'Home'); keys(s,'Down'); keys(s,'Return')
        wait_for(lambda:peer.page()['live']['power']['selected_display'] != selected_display)
        assert not peer.page()['live']['power']['brightness_available']
        click(s,ipc,'power/display'); keys(s,'Home'); keys(s,'Return')
        wait_for(lambda:peer.page()['live']['power']['selected_display'] == selected_display)
        checks['power-display-picker-shares-selection-and-unavailable-state']=True
        # Both settings and flyout now expose the same 0..100 range. Zero maps
        # to the backlight's minimum nonzero raw value.
        click(s,ipc,'power/brightness');keys(s,'Home');s.run(['wtype','-s','10']+['-k','Right','-s','10']*63)
        wait_for(lambda:(root/'test_panel/brightness').read_text().strip()=='630')
        click(s,ipc,'power/performance');await_services(s,args.ctl,lambda v:v['power']['profile']=='performance' and not v['power']['pending'])
        capture(s,'power-real-controls',output['name'])
        checks['power-pointer-brightness-and-profile-with-stable-generation']=True
        command(power,present=False,on_battery=False)
        wait_for(lambda:not peer.page()['live']['power']['battery_present'])
        fields=lambda:{c['field'] for c in probe(s,ipc)['controls']}
        wait_for(lambda:'power/battery' not in fields())
        assert not {'power/battery','power/source','power/automatic-saver'} & fields(),fields()
        assert {'power/brightness','power/balanced','power/screen-off','power/suspend-after'} <= fields(),fields()
        capture(s,'power-no-battery',output['name'])
        command(power,present=True,battery=0,on_battery=True)
        wait_for(lambda:'power/battery' in fields())
        assert peer.page()['live']['power']['percentage']==0
        command(power,battery_type=5)
        wait_for(lambda:'power/battery' not in fields())
        command(power,battery_type=2,battery=73)
        wait_for(lambda:'power/battery' in fields())
        command(power,battery=float('nan'),health=0)
        wait_for(lambda:peer.page()['live']['power']['percentage'] is None)
        assert 'power/battery' in fields()
        assert peer.page()['live']['power']['health'] is None
        command(power,battery=73,health=92,on_battery=False,battery_state=1)
        wait_for(lambda:peer.page()['live']['power']['state']==1)
        assert peer.page()['live']['power']['battery_present']
        command(power,on_battery=True,battery_state=2)
        checks['power-battery-absent-hotplug-zero-and-peripheral']=True
        def power_save(field,value,source='ac'):
            state=wait_for(lambda:(v if not (v:=peer.page()['live']['power'])['saving'] else False),45);nonce=uuid.uuid4().hex
            r=peer.call('power.settings',view=peer.view,operation=nonce,revision=state['revision'],source=source,field=field,value=value)
            assert r['ok'],r
            result=wait_for(lambda:(v if (v:=peer.call('operation.get',operation=nonce))['result']['state']!='pending' else False),45)['result']
            print('power_save',field,value,result,flush=True)
            return result
        assert power_save('screen_off_seconds',300)['state']=='succeeded'
        assert peer.page()['live']['power']['config']['ac']['screen_off_seconds']==300
        assert power_save('suspend_seconds',900)['state']=='failed' # automatic lock is still disabled
        assert peer.page()['live']['power']['config']['ac']['suspend_seconds']==0
        # A retained unrelated draft must survive an immediate power save.
        draft=json.loads(peer.document());draft['font_size']=18
        assert peer.keep(json.dumps(draft))['state']=='succeeded'
        assert power_save('screen_off_seconds',600)['state']=='succeeded'
        assert json.loads(peer.document())['font_size']==18
        assert json.loads(peer.document('committed'))['font_size']!=18
        assert json.loads(peer.document())['idle']['ac']['screen_off_seconds']==600
        draft=json.loads(peer.document());draft['idle']['ac']['screen_off_seconds']=900
        peer.keep(json.dumps(draft))
        assert power_save('screen_off_seconds',1200)['error_code']=='MergeConflict'
        assert json.loads(peer.document())['idle']['ac']['screen_off_seconds']==900
        assert json.loads(peer.document('committed'))['idle']['ac']['screen_off_seconds']==600
        assert peer.action('discard')['state']=='succeeded'
        assert power_save('automatic_saver',20)['state']=='succeeded'
        # Neither frontend keeps a power-page lease while the policy runs.
        navigate(s,ipc,'overview');peer.enter('overview')
        command(power,battery=19)
        await_services(s,args.ctl,lambda v:v['power']['profile']=='power-saver' and not v['power']['pending'])
        command(power,on_battery=False)
        await_services(s,args.ctl,lambda v:v['power']['profile']=='performance' and not v['power']['pending'])
        navigate(s,ipc,'power');ready(s,ipc);peer.enter('power')
        assert power_save('automatic_saver',0)['state']=='succeeded'
        command(power,battery=73,on_battery=True)
        checks['power-scoped-save-validation-draft-isolation-and-automatic-saver']=True
        # Exercise the real compositor idle and output-power path, then wake it.
        assert power_save('screen_off_seconds',4,'battery')['state']=='succeeded'
        assert power_save('dim',1,'battery')['state']=='succeeded'
        s.run(['wlrctl','pointer','move','1','1'])
        wait_for(lambda:(root/'test_panel/brightness').read_text().strip()=='200',8)
        wait_for(lambda:all(not x['powered'] for x in ipc.state() if x['kind']=='output'),8)
        s.run(['wtype','-k','Shift_L'])
        wait_for(lambda:all(x['powered'] for x in ipc.state() if x['kind']=='output'),8)
        wait_for(lambda:(root/'test_panel/brightness').read_text().strip()=='630',8)
        assert power_save('screen_off_seconds',0,'battery')['state']=='succeeded'
        assert power_save('dim',0,'battery')['state']=='succeeded'
        checks['power-real-idle-dim-screen-off-and-wake-restore']=True
        command(power,deny='profile')
        r=peer.live_action(find(peer.page(),'power','power-saver'));assert r['ok'],r
        operation=r['result']['operation'];result=wait_for(lambda:(v if (v:=peer.call('operation.get',operation=operation))['result']['state']!='pending' else False))
        assert result['result']['state']=='failed',result
        command(power,deny=False);checks['denied-power-operation-receipt-and-feedback']=True
        # Confirmation is connection scoped and still only calls the private peer.
        page=peer.page();r=peer.live_action(find(page,'session','reboot'));assert r['result']['state']=='succeeded',r
        cancel=find(peer.page(),'session','power-cancel')
        assert peer.live_action(cancel)['result']['state']=='succeeded'
        assert not any(c['id']=='power-cancel' for row in peer.page()['live']['rows'] for c in row['controls'])
        r=peer.live_action(find(peer.page(),'session','reboot'));assert r['result']['state']=='succeeded',r
        confirm=find(peer.page(),'session','reboot');assert 'confirmation' in json.loads(confirm['params'])
        other=Peer(s,ipc);other.enter('power');foreign=other.live_action(confirm);assert foreign['result']['state']=='failed',foreign
        own=peer.live_action(confirm);assert own['result']['state']!='failed',own
        wait_for(lambda:any(json.loads(line)['kind']=='Reboot' for line in Path(s.env['PEARL_TEST_POWER_LOG']).read_text().splitlines()))
        other.close();checks['power-confirmation-cannot-be-used-by-another-peer']=True
        if args.power_only:
            # Review the delivered page in both hardware states and responsive widths.
            ctl(s,args.ctl,'session','action','--command','dnd_on')
            command(power,profile='balanced')
            time.sleep(2)
            for width,height,size in ((1300,1000,'desktop'),(480,800,'narrow')):
                rules.write_text('[[window]]\napp_id="'+APP_ID+'"\nfloating=true\nwidth='+str(width)+'\nheight='+str(height)+'\n')
                ipc.call('command',action='session.reload',fields={});time.sleep(.4)
                for present in (True,False):
                    command(power,present=present,on_battery=present)
                    wait_for(lambda:peer.page()['live']['power']['battery_present']==present)
                    time.sleep(.2)
                    capture(s,'power-'+size+('-battery' if present else '-no-battery'),output['name'])
                    v=probe(s,ipc)
                    assert v['body_bounds']['x']+v['body_bounds']['width']<=v['width']+1,v
                    for c in v['controls']:
                        r=c['bounds']
                        if r:assert r['x']+r['width']<=v['width']+1,(c,v['width'])
            checks['power-desktop-and-narrow-battery-layouts']=True
            current=json.loads(peer.document('committed'));current['font_size']=24;current['theme']['variant']='light'
            peer.keep(json.dumps(current));assert peer.action('apply')['state']=='succeeded';ready(s,ipc)
            app.stop();clean(app)
            # A connected Settings instance follows the verified shell language,
            # even when its launcher environment asks for a different language.
            app=s.child('settings-language-inheritance',[args.settings,'--page','power'],G_DEBUG='fatal-warnings',LANGUAGE='de',LC_ALL='C.utf8')
            app.expect('event=settings-window-created');ready(s,ipc)
            v=probe(s,ipc);assert v['heading']=='Power & battery',v['heading']
            capture(s,'power-narrow-light-large-text-session-language',output['name'])
            for c in v['controls']:
                r=c['bounds']
                if r:assert r['x']+r['width']<=v['width']+1,(c,v['width'])
            checks['power-light-large-text-and-session-language']=True
            peer.close()
            report.update(status='passed',checks=checks)
            (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(report,indent=2))
            return
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
