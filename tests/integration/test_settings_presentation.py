#!/usr/bin/env python3
"""S6 real service pages, window geometry, scales and output removal."""
import argparse, copy, hashlib, json, time
from pathlib import Path
from test_settings_app import ROOT, APP_ID, PrivateSession, IPC, wait_for, ctl, status, clean, probe, windows, capture, click_widget, keys, apply_preferences
from test_settings_appearance import ready, click, type_text
from test_settings_services import navigate, aq_ready, Peer
from test_connectivity import FIX as CONNECTIVITY
from test_services import FIX

PAGES=('overview','appearance','network','bluetooth','sound','power','bar','notifications','session','aqueous','advanced')
REFERENCE_PAGES=('appearance','network','bluetooth','sound','power')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('settings','pearl','ctl'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s6/presentation')
    args=p.parse_args()
    for name,value in vars(args).items():setattr(args,name,value.resolve())
    args.output.mkdir(parents=True,exist_ok=True)
    report=dict(status='running',checks={},captures=[],layouts=[],binaries={n:hashlib.sha256(getattr(args,n).read_bytes()).hexdigest() for n in ('settings','pearl','ctl')})
    checks=report['checks']
    try:
      with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND']='memory';ipc=IPC(s)
        wm=Path(s.env['AQUEOUS_CONFIG']);wm.write_text(wm.read_text().replace('"floating"','"stacking"'))
        output=next(iter(ipc.outputs().values()));connector=output['name']
        s.run(['wlr-randr','--output',connector,'--custom-mode','1600x1100@60Hz'])
        rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
        def size(width,height):
            rules.write_text('[[window]]\napp_id="'+APP_ID+'"\nfloating=true\nwidth='+str(width)+'\nheight='+str(height)+'\n')
            ipc.call('command',action='session.reload',fields={});time.sleep(.35)
        size(1040,760)
        s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
        s.child('system',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
        s.env['PEARL_TEST_CONNECTIVITY_LOG']=str(s.output/'connectivity.jsonl');Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).write_text('')
        for service in ('network','bluetooth'):
            child=s.child(service,['python3',CONNECTIVITY,service],input_pipe=True);child.expect('event=ready')
        s.env['PEARL_TEST_BACKLIGHT']=str(s.base/'backlight');backlight=Path(s.env['PEARL_TEST_BACKLIGHT'])/'test_panel';backlight.mkdir(parents=True)
        (backlight/'max_brightness').write_text('1000\n');(backlight/'brightness').write_text('420\n')
        s.env['PEARL_TEST_POWER_LOG']=str(s.output/'power.jsonl');Path(s.env['PEARL_TEST_POWER_LOG']).write_text('')
        power=s.child('power',['python3',FIX/'power.py'],input_pipe=True);power.expect('event=ready')
        s.env['PULSE_SERVER']='unix:'+str(s.runtime/'pulse/native');s.env['PIPEWIRE_REMOTE']='pipewire-0'
        s.child('pipewire',['pipewire','-c',FIX/'pipewire.conf']);wait_for(lambda:(s.runtime/'pipewire-0').is_socket())
        s.child('pulse',['pipewire-pulse','-c',FIX/'pulse.conf']);wait_for(lambda:(s.runtime/'pulse/native').is_socket())
        wait_for(lambda:s.run(['pactl','info'],check=False).returncode==0)
        s.run(['pactl','load-module','module-null-sink','sink_name=acceptance_output','sink_properties=device.description=Acceptance_output'])
        s.run(['pactl','set-default-sink','acceptance_output']);s.run(['pactl','set-default-source','acceptance_output.monitor'])
        shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        ctl(s,args.ctl,'session','action','--command','dnd_on')
        app=s.child('settings',[args.settings,'--page','appearance'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        peer=Peer(s,ipc);aq_ready(s,ipc,peer)
        initial=copy.deepcopy(json.loads(peer.document('committed')))
        custom=Path(s.env['XDG_DATA_HOME'])/'themes/Pearl-Acceptance/gtk-4.0';custom.mkdir(parents=True)
        (custom/'gtk.css').write_text('.background {background:#203040;color:#ffffff;} button {background:#304050;color:#ffffff;}')
        def layout(page,case,shot=False):
            navigate(s,ipc,page,'displays' if page=='aqueous' else None);ready(s,ipc)
            if page=='aqueous':aq_ready(s,ipc,peer)
            time.sleep(.15);v=probe(s,ipc);win=windows(ipc)[0]
            body=v['body_bounds'];footer=v['footer_bounds'];header=v['header_bounds']
            assert v['connected'] and not v['fixture'],v
            if page in ('network','bluetooth','sound','power','notifications','overview'):assert 'immediately' in v['footer_text'],v['footer_text']
            assert body['width']>0 and body['height']>0,(case,page,v)
            assert body['x']>=0 and body['x']+body['width']<=v['width']+1,(case,page,v)
            assert header['y']+header['height']<=body['y']+1,(case,page,v)
            assert body['y']+body['height']<=footer['y']+1 and footer['y']+footer['height']<=v['height']+1,(case,page,v)
            assert sum(link['active'] for link in v['links'])==1
            children=[link for link in v['links'] if link['section']]
            assert len(children)==7 and all(link['visible']==(page=='aqueous') for link in children)
            if page=='aqueous':
                assert v['heading']=='Displays'
                assert [link['section'] for link in children if link['active']]==['displays']
                if not v['narrow']:
                    active=next(link['bounds'] for link in children if link['active'])
                    viewport=v['navigation_bounds']
                    assert active['y']>=viewport['y']-1 and active['y']+active['height']<=viewport['y']+viewport['height']+1,(case,active,viewport)
            bounds=ipc.outputs()[win['output']]['bounds']
            assert v['width']<=bounds['width']+1 and v['height']<=bounds['height']+1,(case,page,v,bounds)
            report['layouts'].append(dict(case=case,page=page,width=v['width'],height=v['height'],body=body,footer=footer,narrow=v['narrow'],output=win['output']))
            if shot:
                name=case+'-'+page;capture(s,name,connector)
                report['captures'].append(dict(case=case,page=page,path='session/'+name+'.png',window=win['geometry']))
            return v
        # The first complete pass establishes the full route/schema inventory.
        for page in PAGES:layout(page,'inventory')
        assert probe(s,ipc)['aqueous']['fields']>=221
        checks['all-eleven-pages-and-complete-aqueous-inventory']=True
        for theme,variant,label,width,height,font in [
            ('static','dark','dark',1040,760,14),('static','light','light',1040,760,14),('gtk','light','native',1040,760,14),
            ('static','dark','narrow-dark',480,700,14),('static','light','narrow-light',480,700,14),('gtk','light','narrow-native',480,700,14),
            ('static','dark','large-text',480,700,24)]:
            apply_preferences(s,args.ctl,theme=dict(mode=theme,variant=variant,gtk_name='Pearl-Acceptance' if theme=='gtk' else ''),font_size=font,reduced_motion=True)
            wait_for(lambda:probe(s,ipc)['style']==('gtk' if theme=='gtk' else variant));size(width,height)
            # Start each reference size with its placement rule, avoiding a
            # previous wide page's minimum size constraining the next case.
            app.stop();clean(app)
            app=s.child('settings-'+label,[args.settings,'--page','aqueous','--section','displays'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created');ready(s,ipc);aq_ready(s,ipc,peer)
            if width<760:wait_for(lambda:probe(s,ipc)['narrow'])
            for page in (*REFERENCE_PAGES,'aqueous'):layout(page,label,True)
            if probe(s,ipc)['narrow']:
                click_widget(s,ipc,probe(s,ipc)['sections_bounds'])
                wait_for(lambda:probe(s,ipc)['sections_open'])
                capture(s,label+'-aqueous-sublist',connector)
                keys(s,'Escape')
        checks['five-reference-pages-dark-light-native-narrow-and-large-text']=True
        apply_preferences(s,args.ctl,theme=dict(mode='static',variant='dark',gtk_name=''),font_size=14)
        # Preserve an acknowledged draft through scale, size and monitor changes.
        navigate(s,ipc,'appearance');click(s,ipc,'font');type_text(s,'Sans');keys(s,'Tab');ready(s,ipc)
        candidate=peer.document();assert peer.state()['dirty']
        for scale in (1,1.25,1.5,2):
            s.run(['wlr-randr','--output',connector,'--scale',str(scale)])
            size(min(1040,int(1600/scale)-80),min(760,int(1100/scale)-130))
            for page in PAGES:layout(page,'scale-'+str(scale),page=='appearance')
            assert peer.document()==candidate
        checks['100-125-150-200-percent-all-pages-preserve-draft']=True
        s.run(['wlr-randr','--output',connector,'--scale','1'])
        size(480,400)
        for page in PAGES:layout(page,'short',page in (*REFERENCE_PAGES,'aqueous'))
        assert peer.document()==candidate
        checks['short-window-keeps-header-body-and-save-footer-reachable']=True
        # Moving to another output and disabling it must preserve the same owner.
        other=next(o for o in ipc.outputs().values() if o['name']!=connector)
        win=windows(ipc)[0];pid=probe(s,ipc)['pid']
        ipc.call('command',action='window.move',fields=dict(id=win['id'],output=other['id']))
        wait_for(lambda:windows(ipc)[0]['output']==other['id'])
        s.run(['wlr-randr','--output',other['name'],'--off'])
        wait_for(lambda:other['id'] not in ipc.outputs())
        assert probe(s,ipc)['pid']==pid and peer.document()==candidate
        # Headless disable retains the compositor's workspace/output assignment.
        # Record that policy separately from physical unplug, then use the normal
        # window move command to prove recovery on the remaining enabled output.
        report['disabled_output_auto_relocated']=windows(ipc)[0]['output']!=other['id']
        current_output=next(o for o in ipc.outputs().values() if o['name']==connector)
        ipc.call('command',action='window.move',fields=dict(id=win['id'],output=current_output['id']))
        wait_for(lambda:windows(ipc)[0]['output']==current_output['id'])
        navigate(s,ipc,'bar');layout('bar','output-removed');capture(s,'output-removed-draft-retained',connector)
        s.run(['wlr-randr','--output',other['name'],'--on'])
        checks['move-output-disable-and-explicit-recovery-preserve-window-and-draft']=True
        peer.action('discard');ready(s,ipc)
        app.stop();clean(app);peer.close();shell.stop();clean(shell);ipc.close()
      report['status']='passed'
    except Exception as error:report.update(status='failed',error=repr(error));raise
    finally:(args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('captures','layouts')},indent=2))
if __name__=='__main__':main()
