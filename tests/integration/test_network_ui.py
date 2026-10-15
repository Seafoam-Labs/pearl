#!/usr/bin/env python3
"""Network presentation, real GTK controls and isolated multi-adapter fixtures."""
import argparse, hashlib, json, time
from pathlib import Path
from types import SimpleNamespace
from test_settings_app import ROOT, APP_ID, PrivateSession, IPC, probe, windows, capture, apply_preferences, keys
from test_settings_services import Peer
from test_settings_appearance import ready, click
from test_surfaces import ctl, status, clean
from test_services import command
from test_connectivity import FIX, AP, ND
from settings_navigation import report as compact_report
from pearl_session import fixture_prefix, fixture_source, wait_for
from t00 import Session as T00Session


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('settings','pearl','ctl'): parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/network-ui/final')
    args=parser.parse_args()
    for key,value in vars(args).items(): setattr(args,key,value.resolve())
    args.output.mkdir(parents=True,exist_ok=True)
    result={'status':'running','checks':{},'captures':[], 'binaries':{key:hashlib.sha256(getattr(args,key).read_bytes()).hexdigest() for key in ('settings','pearl','ctl')}}; checks=result['checks']
    try:
      with PrivateSession(args.output/'session',tool_prefix=fixture_prefix()) as s:
        s.env['GSETTINGS_BACKEND']='memory'; ipc=IPC(s)
        s.args=SimpleNamespace(aqueous_source=str(fixture_source())); T00Session.input_fixture(s)
        wm=Path(s.env['AQUEOUS_CONFIG']);wm.write_text(wm.read_text().replace('"floating"','"stacking"'))
        output=next(iter(ipc.outputs().values()));connector=output['name']
        s.run(['wlr-randr','--output',connector,'--custom-mode','1600x1100@60Hz'])
        rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
        def size(width,height):
            rules.write_text(f'[[window]]\napp_id="{APP_ID}"\nfloating=true\nwidth={width}\nheight={height}\n')
            ipc.call('command',action='session.reload',fields={});time.sleep(.3)
        size(1040,850)
        s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
        s.child('system',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
        wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
        s.env['PEARL_TEST_CONNECTIVITY_LOG']=str(s.output/'actions.jsonl');Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).write_text('')
        net=s.child('network',['python3',FIX,'network'],input_pipe=True);net.expect('event=ready')
        shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        ctl(s,args.ctl,'session','action','--command','dnd_on')
        app=s.child('settings',[args.settings,'--page','network'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        peer=Peer(s,ipc);peer.enter('network')
        def snapshot(): return peer.page()['live']['network']
        def await_network(fn): return wait_for(lambda:(v if fn(v:=snapshot()) else False))
        def shot(name):
            time.sleep(1.2);capture(s,name,connector);result['captures'].append('session/'+name+'.png')
        initial=await_network(lambda v:v['radio']=='on' and len(v['rows'])==5)
        assert initial['status']=='offline' and len([r for r in initial['rows'] if r['section']=='nearby'])==4
        secure=next(r for r in initial['rows'] if r['section']=='nearby' and r['title']=='Fixture Secure')
        assert secure['action']=='connect_saved' and secure['profiles']==1
        assert not any(json.loads(line)['kind']=='scan' for line in Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).read_text().splitlines())
        checks['initial-list-visible-without-scan-and-saved-identity-match']=True;shot('settings-dark')
        # The button retains its widget and keyboard focus across unrelated updates.
        click(s,ipc,'network/refresh');wait_for(lambda:any(json.loads(line)['kind']=='scan' for line in Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).read_text().splitlines()))
        wait_for(lambda:not snapshot()['scanning'])
        assert snapshot()['scan_wait']
        checks['real-refresh-and-cooldown']=True
        for connectivity,state in ((2,'portal'),(3,'limited'),(0,'unknown'),(4,'online')):
            command(net,refresh=connectivity);await_network(lambda v:v['status']==state);shot('settings-'+state)
        checks['portal-limited-unknown-online-statuses']=True
        command(net,duplicate_ap=True)
        duplicated=await_network(lambda v:any(r['strength']==98 for r in v['rows']))
        matches=[r for r in duplicated['rows'] if r['section']=='nearby' and r['title']=='Fixture Secure']
        assert len(matches)==1 and matches[0]['key']==secure['key'] and matches[0]['action']=='connect_saved'
        command(net,extra_adapter=True)
        multiple=await_network(lambda v:len(v['devices'])==2)
        assert len([r for r in multiple['rows'] if r['section']=='nearby' and r['title']=='Fixture Secure'])==2
        wait_for(lambda:any(c['field']=='network/adapter' for c in probe(s,ipc)['controls']))
        click(s,ipc,'network/adapter');keys(s,'Down','Return');shot('settings-adapter-selection')
        checks['duplicate-AP-grouping-and-distinct-adapters']=True
        command(net,ethernet=True)
        await_network(lambda v:any(r['section']=='ethernet' and r['state']=='connected' for r in v['rows']))
        click(s,ipc,'network/radio');off=await_network(lambda v:v['radio']=='off')
        assert off['status']=='online' and all(r['section']!='nearby' for r in off['rows'])
        assert next(r for r in off['rows'] if r['section']=='ethernet')['enabled'];shot('settings-wifi-off-ethernet')
        command(net,hardware=False);await_network(lambda v:v['radio']=='blocked')
        wait_for(lambda:not next(c for c in probe(s,ipc)['controls'] if c['field']=='network/radio')['enabled'])
        checks['wired-internet-independent-of-wireless-power-and-hardware-block']=True;shot('settings-hardware-blocked')
        command(net,hardware=True);await_network(lambda v:v['radio']=='off')
        click(s,ipc,'network/radio');await_network(lambda v:v['radio']=='on')
        command(net,active_ap=AP);connected=await_network(lambda v:any(r['section']=='connected' and r['title']=='Fixture Secure' for r in v['rows']))
        assert not any(r['section']=='nearby' and r['device']==0 and r['title']=='Fixture Secure' for r in connected['rows'])
        assert any(r['section']=='saved' and r['state']=='connected' for r in connected['rows'])
        checks['active-network-removed-from-nearby-and-saved-state-accurate']=True
        command(net,extra_aps=36)
        many=await_network(lambda v:len([r for r in v['rows'] if r['section']=='nearby'])>32)
        assert len(many['rows'])<=104 and len(json.dumps(many).encode())<160*1024
        checks['complete-bounded-snapshot-exceeds-legacy-page-without-stitching']=True
        click(s,ipc,'network/saved');shot('settings-saved-networks')
        # Compact routing uses the same status and keeps the footer outside its scroll.
        ctl(s,args.ctl,'control-center','show','--page','network')
        wait_for(lambda:compact_report(s,args.ctl)['page']=='network')
        compact=compact_report(s,args.ctl)
        assert 'Internet available' in compact['labels'] and 'View all nearby networks' in compact['labels']
        assert 'Adapters, nearby and saved networks' not in compact['labels']
        shot('flyout-connected');ctl(s,args.ctl,'popup','hide')
        checks['compact-current-status-visible-list-and-more-action']=True
        command(net,owner=False)
        unavailable=await_network(lambda v:v['status']=='unavailable')
        assert not unavailable['rows'] and not unavailable['radio_enabled'];shot('settings-unavailable')
        command(net,owner=True);await_network(lambda v:v['status']=='online')
        checks['daemon-loss-clears-stale-rows-and-recovers']=True
        custom=Path(s.env['XDG_DATA_HOME'])/'themes/Pearl-Network-Test/gtk-4.0';custom.mkdir(parents=True)
        (custom/'gtk.css').write_text('.background {background:#203040;color:#ffffff;} button {background:#304050;color:#ffffff;}')
        for name,width,height,font,mode,variant in (
            ('light',1040,850,14,'static','light'),('native',1040,850,14,'gtk','dark'),
            ('narrow-440',440,850,14,'static','light'),('narrow-360',360,740,14,'static','dark'),
            ('large-text',440,850,24,'static','dark'),('short',440,400,14,'static','dark')):
            app.stop();clean(app)
            apply_preferences(s,args.ctl,theme=dict(mode=mode,variant=variant,gtk_name='Pearl-Network-Test'),font_size=font)
            size(width,height)
            app=s.child('settings-'+name,[args.settings,'--page','network'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
            v=probe(s,ipc);assert v['width']<=width+2,(name,v['width'])
            body=v['body_bounds'];assert body['width']>0 and body['height']>0
            assert body['x']+body['width']<=v['width']+1
            assert body['y']+body['height']<=v['footer_bounds']['y']+1
            click(s,ipc,'network/refresh');shot('settings-'+name)
        checks['light-native-360-440-large-text-short-window-controls-reachable']=True
        peer.close();app.stop();clean(app);ctl(s,args.ctl,'quit');clean(shell);ipc.close()
      result['status']='passed'
    except Exception as error:
        result.update(status='failed',error=str(error));raise
    finally: (args.output/'report.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':main()
