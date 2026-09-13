#!/usr/bin/env python3
"""T09 protocol conversations on private session buses and headless Aqueous."""
import argparse,hashlib,json,os,sys,time,zlib,struct
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,status,capture,clean
from test_services import command
from t00 import Session as T00Session
FIX=ROOT/'tests/fixtures/session/desktop.py'
def state(s,binary):
    value=ctl(s,binary,'session','status')['result'];page=value['next_offset']
    while page is not None:
        more=ctl(s,binary,'session','status','--offset',str(page))['result']
        for part,key in [('notifications','records'),('media','players'),('tray','items')]: value[part][key].extend(more[part][key])
        page=more['next_offset']
    return value
def await_state(s,b,p,timeout=12): return wait_for(lambda:(lambda v:v if p(v) else False)(state(s,b)),timeout)
def action(s,b,name,code=0,**kw):
    args=['session','action','--command',name]
    for k,v in kw.items(): args.extend(['--'+k.replace('_','-'),str(v)])
    return ctl(s,b,*args,code=code)
def records(s): return [json.loads(x) for x in Path(s.env['PEARL_TEST_SESSION_LOG']).read_text().splitlines()]
def notified(s,fixture,**kw):
    n=sum(x['kind']=='notification' for x in records(s));command(fixture,notify=kw)
    values=[x for x in records(s) if x['kind']=='notification'];assert len(values)==n+1,records(s)[-5:];return values[-1]['id']
def closed(s,id,reason): return any(r['kind']=='notification-signal' and r['signal']=='NotificationClosed' and r['args']==[id,reason] for r in records(s))
def png(path):
    def chunk(k,v): return struct.pack('>I',len(v))+k+v+struct.pack('>I',zlib.crc32(k+v))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',96,96,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes([171,150,211,255])*96)*96))+chunk(b'IEND',b''))
def focus(child): return next((line.rsplit('=',1)[-1] for line in reversed(child.lines) if 'event=session-focus target=' in line),'')
def key(s,*args): s.run(['wtype','-s','100',*args,'-s','300'])
def focus_target(s,child,target):
    for _ in range(24):
        if focus(child)==target: return
        key(s,'-k','Tab')
    raise AssertionError(('No keyboard focus',target,child.lines[-15:]))
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--pearl',type=Path,required=True);p.add_argument('--ctl',type=Path,required=True);p.add_argument('--production-pearl',type=Path,required=True);p.add_argument('--spike',type=Path,required=True);p.add_argument('--output',type=Path,default=ROOT/'artifacts/t09/latest');args=p.parse_args()
    args.production_pearl=args.production_pearl.resolve();args.spike=args.spike.resolve();args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    checks={};result=dict(status='running',checks=checks,pearl_sha256=hashlib.sha256(args.pearl.read_bytes()).hexdigest(),ctl_sha256=hashlib.sha256(args.ctl.read_bytes()).hexdigest(),production_sha256=hashlib.sha256(args.production_pearl.read_bytes()).hexdigest())
    try:
        with PrivateSession(args.output/'protocols') as s:
            s.env['PEARL_TEST_SESSION_LOG']=str(s.output/'clients.jsonl');Path(s.env['PEARL_TEST_SESSION_LOG']).write_text('')
            art=s.base/'cover.png';png(art);s.env['PEARL_TEST_ART']=art.as_uri()
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');keyboard=T00Session.input_fixture(s)
            fixture=s.child('clients',['python3',FIX],input_pipe=True);fixture.expect('event=ready')
            pearl=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');pearl.expect('event=control-ready')
            await_state(s,args.ctl,lambda v:v['notifications']['available'] and v['tray']['watcher'] and v['media']['count']==1 and v['media']['players'][0]['ready'])
            command(fixture,register=True);initial=await_state(s,args.ctl,lambda v:v['tray']['count']==1 and v['tray']['items'][0]['ready'])
            assert initial['tray']['items'][0]['image'];gen=initial['media']['players'][0]['generation'];traygen=initial['tray']['items'][0]['generation'];output=status(s,args.ctl)['outputs'][0]
            checks['initial-mpris-owner-discovery-and-sni-registration-pixmap']=True
            caps=s.run(['gdbus','call','--session','--dest','org.freedesktop.Notifications','--object-path','/org/freedesktop/Notifications','--method','org.freedesktop.Notifications.GetCapabilities']).stdout
            assert all(x in caps for x in ["'body'","'actions'","'persistence'"]) and 'markup' not in caps
            checks['truthful-notification-capabilities']=True
            id=notified(s,fixture,summary='New message',body='Hello <b>world</b>\x1b',resident=True)
            assert notified(s,fixture,replaces=id,summary='Updated message',resident=True)==id
            assert state(s,args.ctl)['notifications']['active']==1
            wait_for(lambda:status(s,args.ctl)['notification'])
            ctl(s,args.ctl,'notifications','toggle','--output',output['id']);time.sleep(.4);capture(s,'notification-center',output['connector'])
            assert status(s,args.ctl)['notification'] and status(s,args.ctl)['popup']['pane']=='notifications'
            checks['replacement-history-and-toast-popup-coexistence']=True
            focus_target(s,pearl,'notification-action');key(s,'-k','space')
            checks['notification-action-through-gtk-keyboard']=True
            wait_for(lambda:any(r['kind']=='notification-signal' and r['signal']=='ActionInvoked' and r['args']==[id,'default'] for r in records(s)))
            assert state(s,args.ctl)['notifications']['active']==1
            action(s,args.ctl,'dismiss',notification=id);wait_for(lambda:closed(s,id,2))
            id=notified(s,fixture,timeout=150,transient=True);wait_for(lambda:closed(s,id,1));assert all(n['id']!=id for n in state(s,args.ctl)['notifications']['records'])
            id=notified(s,fixture);command(fixture,close=id);wait_for(lambda:closed(s,id,3))
            action(s,args.ctl,'dismiss',notification=id,code=4)
            checks['action-residency-transient-expiry-and-all-closure-reasons']=True
            action(s,args.ctl,'dnd_on');id=notified(s,fixture,app='Mail',summary='Quiet delivery')
            assert state(s,args.ctl)['notifications']['toasts']==0 and not status(s,args.ctl)['notification']
            action(s,args.ctl,'dnd_off');assert state(s,args.ctl)['notifications']['toasts']==0
            command(fixture,close=id);command(fixture,burst=100)
            assert state(s,args.ctl)['notifications']['count']==64
            action(s,args.ctl,'clear_history');assert state(s,args.ctl)['notifications']['count']==0
            checks['dnd-history-no-replay-and-bounded-bursts']=True
            locker=s.child('locker',[args.spike],input_pipe=True,PEARL_T00_ISOLATED='1',WLR_BACKENDS='headless',PEARL_T00_MODE='plain');locker.expect('T00 event=ready')
            locker.proc.stdin.write('lock\n');locker.proc.stdin.flush();locker.expect('T00 event=locked')
            await_state(s,args.ctl,lambda v:v['notifications']['locked'])
            locked_id=notified(s,fixture,summary='Private locked content')
            locked=state(s,args.ctl);assert locked['notifications']['records'][0]['summary']=='' and locked['notifications']['toasts']==0
            action(s,args.ctl,'dismiss',notification=locked_id,code=4)
            assert status(s,args.ctl)['popup'] is None and not status(s,args.ctl)['notification']
            locker.proc.stdin.write('unlock\n');locker.proc.stdin.flush();locker.expect('T00 event=unlocked');await_state(s,args.ctl,lambda v:not v['notifications']['locked'])
            assert state(s,args.ctl)['notifications']['toasts']==0
            locker.proc.stdin.write('quit\n');locker.proc.stdin.flush();clean(locker)
            command(fixture,close=locked_id);action(s,args.ctl,'clear_history')
            checks['real-aqueous-lock-hides-content-blocks-actions-and-prevents-replay']=True
            ctl(s,args.ctl,'media','toggle','--output',output['id']);wait_for(lambda:status(s,args.ctl)['artwork']);time.sleep(.3);capture(s,'media-card',output['connector'])
            assert status(s,args.ctl)['media_views']==1
            focus_target(s,pearl,'media-play_pause');key(s,'-k','space');await_state(s,args.ctl,lambda v:v['media']['players'][0]['playback']=='Paused' and not v['media']['players'][0]['busy'])
            action(s,args.ctl,'play',generation=gen);await_state(s,args.ctl,lambda v:v['media']['players'][0]['playback']=='Playing' and not v['media']['players'][0]['busy'])
            focus_target(s,pearl,'media-position');key(s,'-k','Home','-k','Right');focus_target(s,pearl,'media-seek');time.sleep(1.2);key(s,'-k','space')
            wait_for(lambda:any(r['kind']=='call' and r['method']=='SetPosition' and r['args'][1]==2400000 for r in records(s)))
            action(s,args.ctl,'pause',generation=gen);await_state(s,args.ctl,lambda v:v['media']['players'][0]['playback']=='Paused' and not v['media']['players'][0]['busy'])
            checks['keyboard-seek-edit-survives-progress-timer-and-focus-change']=True
            action(s,args.ctl,'seek',generation=gen,position=60000000);await_state(s,args.ctl,lambda v:v['media']['players'][0]['position']==60000000 and not v['media']['players'][0]['busy'])
            command(fixture,capability='CanSeek',value=False);await_state(s,args.ctl,lambda v:not v['media']['players'][0]['seek']);action(s,args.ctl,'seek',generation=gen,position=100,code=4)
            command(fixture,deny=True);action(s,args.ctl,'next',generation=gen);await_state(s,args.ctl,lambda v:v['media']['err'] is not None);time.sleep(.3);assert state(s,args.ctl)['media']['err'] is not None;command(fixture,deny=False)
            checks['media-keyboard-controls-position-capabilities-and-rejection']=True
            command(fixture,title='Remote artwork',art='https://invalid.example/cover.png');await_state(s,args.ctl,lambda v:v['media']['players'][0]['title']=='Remote artwork');wait_for(lambda:not status(s,args.ctl)['artwork'] and not status(s,args.ctl)['artwork_pending'])
            big=s.base/'oversized.png';big.write_bytes(b'X'*(2*1024*1024+1));command(fixture,title='Oversized',art=big.as_uri());await_state(s,args.ctl,lambda v:v['media']['players'][0]['title']=='Oversized');wait_for(lambda:not status(s,args.ctl)['artwork_pending']);assert not status(s,args.ctl)['artwork']
            fifo=s.base/'cover-fifo';os.mkfifo(fifo);command(fixture,title='FIFO',art=fifo.as_uri());await_state(s,args.ctl,lambda v:v['media']['players'][0]['title']=='FIFO');wait_for(lambda:not status(s,args.ctl)['artwork_pending'])
            ctl(s,args.ctl,'popup','hide');assert status(s,args.ctl)['media_views']==0
            time.sleep(.3);assert not state(s,args.ctl)['media']['timer']
            checks['bounded-cancellable-artwork-local-only-and-hidden-view-timers']=True
            action(s,args.ctl,'tray_activate',generation=traygen);action(s,args.ctl,'tray_secondary',generation=traygen)
            action(s,args.ctl,'tray_menu',generation=traygen);v=await_state(s,args.ctl,lambda v:v['tray']['items'][0]['menu_ready']);menu_revision=v['tray']['items'][0]['menu_revision'];assert v['tray']['items'][0]['nodes']==9
            ctl(s,args.ctl,'tray','toggle','--output',output['id']);time.sleep(.3);capture(s,'tray-menu',output['connector'])
            focus_target(s,pearl,'tray-2');key(s,'-k','space');focus_target(s,pearl,'tray-4');key(s,'-k','space');focus_target(s,pearl,'tray-5');key(s,'-k','space');capture(s,'tray-nested-menu',output['connector'])
            v=await_state(s,args.ctl,lambda v:v['tray']['items'][0]['menu_revision']>menu_revision);menu_revision=v['tray']['items'][0]['menu_revision']
            action(s,args.ctl,'tray_click',generation=traygen,revision=menu_revision,menu_id=5)
            action(s,args.ctl,'tray_click',generation=traygen,revision=menu_revision,menu_id=6,code=4)
            action(s,args.ctl,'tray_click',generation=traygen,revision=menu_revision,menu_id=8,code=4)
            wait_for(lambda:any(r['kind']=='call' and r['method']=='Event' and r['args'][0]==5 for r in records(s)))
            checks['tray-activation-secondary-and-nested-dbusmenu-keyboard-actions']=True
            command(fixture,menu_overflow=True);await_state(s,args.ctl,lambda v:not v['tray']['items'][0]['menu_ready'] and v['tray']['items'][0]['nodes']==0)
            action(s,args.ctl,'tray_click',generation=traygen,revision=menu_revision,menu_id=5,code=4)
            command(fixture,menu_overflow=False);await_state(s,args.ctl,lambda v:v['tray']['items'][0]['menu_ready'])
            command(fixture,bad_pixmap=True);await_state(s,args.ctl,lambda v:not v['tray']['items'][0]['image'])
            checks['malformed-pixmaps-menu-limits-and-stale-menu-rejection']=True
            command(fixture,delay=1000,title='Obsolete reply');time.sleep(.2);command(fixture,release_player=True);await_state(s,args.ctl,lambda v:v['media']['count']==0)
            action(s,args.ctl,'play',generation=gen,code=4);command(fixture,delay=0,title='New owner',own_player=True)
            live=await_state(s,args.ctl,lambda v:v['media']['count']==1 and v['media']['players'][0]['ready']);assert live['media']['players'][0]['generation']!=gen
            time.sleep(1.2);assert state(s,args.ctl)['media']['players'][0]['title']=='New owner'
            command(fixture,release_tray=True);await_state(s,args.ctl,lambda v:v['tray']['count']==0);action(s,args.ctl,'tray_activate',generation=traygen,code=4)
            command(fixture,own_tray=True);command(fixture,register=True);await_state(s,args.ctl,lambda v:v['tray']['count']==1 and v['tray']['items'][0]['ready'])
            checks['owner-loss-restart-and-stale-replies-clean-cards']=True
            second=s.child('second-player',['python3',FIX],input_pipe=True,PEARL_TEST_SUFFIX='Second');second.expect('event=ready')
            live=await_state(s,args.ctl,lambda v:v['media']['count']==2 and all(p['ready'] for p in v['media']['players']))
            secondgen=next(p['generation'] for p in live['media']['players'] if p['name'].endswith('Second'))
            action(s,args.ctl,'select',generation=secondgen);assert state(s,args.ctl)['media']['selected']==secondgen
            second.stop();live=await_state(s,args.ctl,lambda v:v['media']['count']==1);assert live['media']['selected']!=secondgen
            checks['player-selection-falls-back-after-owner-exit']=True
            command(fixture,delay=2000,title='Pending at shutdown');time.sleep(.2)
            ctl(s,args.ctl,'quit');clean(pearl);checks['clean-shutdown']=True
        with PrivateSession(args.output/'ownership') as s:
            s.env['PEARL_TEST_SESSION_LOG']=str(s.output/'clients.jsonl');Path(s.env['PEARL_TEST_SESSION_LOG']).write_text('')
            fixture=s.child('existing-services',['python3',FIX,'--conflict'],input_pipe=True);fixture.expect('event=ready')
            pearl=s.child('pearl',[args.production_pearl],G_DEBUG='fatal-warnings');pearl.expect('event=control-ready')
            live=await_state(s,args.ctl,lambda v:v['tray']['external'] and v['tray']['count']==1 and v['tray']['items'][0]['ready'])
            assert not live['notifications']['available'] and not live['tray']['watcher']
            wait_for(lambda:any(r['kind']=='call' and r['method']=='RegisterStatusNotifierHost' for r in records(s)))
            checks['existing-daemon-respected-and-external-watcher-hosting']=True
            fixture.stop();await_state(s,args.ctl,lambda v:v['notifications']['available'] and v['tray']['watcher'] and v['media']['count']==0 and v['tray']['count']==0)
            checks['queued-names-acquired-after-existing-services-exit']=True
            old_bus=next(c for c in s.children if c.logfile.name=='bus.log');old_bus.stop()
            await_state(s,args.ctl,lambda v:not v['connected'])
            bus=s.child('bus-restarted',['dbus-daemon','--nofork','--config-file='+str(s.base/'bus.conf')]);wait_for(lambda:(s.runtime/'bus').is_socket())
            fixture=s.child('clients-restarted',['python3',FIX],input_pipe=True);fixture.expect('event=ready')
            await_state(s,args.ctl,lambda v:v['notifications']['available'] and v['tray']['watcher'] and v['media']['count']==1 and v['media']['players'][0]['ready'],timeout=20)
            command(fixture,register=True);await_state(s,args.ctl,lambda v:v['tray']['count']==1 and v['tray']['items'][0]['ready'])
            checks['production-session-bus-reconnect-restores-protocols']=True
            ctl(s,args.ctl,'quit');clean(pearl)
        result['status']='passed'
    finally: (args.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
