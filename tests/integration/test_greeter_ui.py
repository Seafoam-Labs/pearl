#!/usr/bin/env python3
"""Real GTK/layer surfaces against fake greetd in private Aqueous. No real PAM."""
import argparse
import hashlib
import struct
import zlib
import json
import os
import subprocess
from pathlib import Path
import socket
import sys
import threading
import time
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC,capture
from test_greeter_ipc import receive,send
from test_lock import metrics


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--greeter',type=Path,required=True)
    parser.add_argument('--idle-seconds',type=int,default=65)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/greeter/latest/ui')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    report={'binary_sha256':hashlib.sha256(args.greeter.read_bytes()).hexdigest(),'evidence':'private Aqueous and fake greetd only','checks':[]}
    with PrivateSession(args.output/'session') as session:
        session.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(session)
        ipc=IPC(session);outputs=list(ipc.outputs().values());primary=outputs[0]['name'];secondary=outputs[1]['name']
        root=session.base/'sessions';root.mkdir()
        # A tiny opaque PNG fixture exercises bounded asset loading on every output.
        def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        wallpaper=session.base/'wallpaper.png'
        wallpaper.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\x1c\x1a\x22'))+chunk(b'IEND',b''))
        report['aqueous']={'path':str(session.aqueous),'sha256':hashlib.sha256(session.aqueous.read_bytes()).hexdigest()}
        (root/'pearl.desktop').write_text('[Desktop Entry]\nType=Application\nName=Pearl (Aqueous)\nExec=/usr/bin/true\nDesktopNames=Aqueous;\n')
        (root/'other.desktop').write_text('[Desktop Entry]\nType=Application\nName=Other desktop\nExec=/usr/bin/true\nDesktopNames=Other;\n')
        config=session.base/'greeter.json'
        def key(*keys):session.run(['wtype','-s','120',*keys,'-s','120'])
        for theme in ('material_dark','material_light','gtk','contrast','small','stale'):
            config.write_text(json.dumps({'theme':theme if theme in ('material_dark','material_light','gtk') else 'material_dark','roots':[{'path':str(root),'type':'wayland'}],'default_session':'wayland:pearl.desktop','accounts':False,'power':False,'remember_session':theme=='material_light','wallpaper':str(wallpaper) if theme=='material_light' else None}))
            if theme=='small':session.run(['wlr-randr','--output',primary,'--scale','2'])
            server=socket.socket(socket.AF_UNIX);path=str(session.base/f'greetd-{theme}.sock');server.bind(path);server.listen();server.settimeout(args.idle_seconds+30)
            errors=[];requests=[]
            def daemon():
                try:
                    conn,_=server.accept()
                    with conn:
                        conn.settimeout(args.idle_seconds+30)
                        create=receive(conn);requests.append(create)
                        assert create=={'type':'create_session','username':'fixture-user'},create
                        send(conn,{'type':'auth_message','auth_message_type':'secret','auth_message':'Fixture password:'})
                        answer=receive(conn)
                        assert answer=={'type':'post_auth_message_response','response':'fixture-secret'},answer
                        send(conn,{'type':'auth_message','auth_message_type':'info','auth_message':'Fixture authentication complete'})
                        assert receive(conn)=={'type':'post_auth_message_response','response':None}
                        send(conn,{'type':'success'})
                        if theme=='stale':
                            second,_=server.accept()
                            with second:
                                assert receive(second)=={'type':'cancel_session'}
                                send(second,{'type':'success'})
                            return
                        start=receive(conn);requests.append(start)
                        assert start['type']=='start_session' and start['cmd']==['/usr/lib/pearl/pearl-greeter-session']
                        assert 'PEARL_SESSION_ID=wayland:pearl.desktop' in start['env']
                        assert 'XDG_SESSION_TYPE=wayland' in start['env']
                        send(conn,{'type':'success'})
                except Exception as e:errors.append(e)
            thread=threading.Thread(target=daemon,daemon=True);thread.start()
            child=session.child('greeter-'+theme,[args.greeter.resolve()],GREETD_SOCK=path,PEARL_TEST_GREETER_CONFIG=str(config),PEARL_TEST_GREETER_STATE=str(session.base/'selections.json'),GTK_A11Y='test',G_DEBUG='fatal-warnings')
            child.expect('event=greeter-ready')
            if theme=='contrast':
                key(*(['-k','Tab']*6),'-k','space')
                child.expect('event=greeter-contrast enabled=true')
                key('-k','Tab','-k','space')
                child.expect('event=greeter-reduced-motion enabled=false')
                key('-k','space')
                child.expect('event=greeter-reduced-motion enabled=true')
                for _ in range(7):key('-M','shift','-k','ISO_Left_Tab','-m','shift')
            if theme=='material_dark':
                time.sleep(2); before=metrics(child.proc.pid);host_before=metrics(session.compositor.proc.pid);time.sleep(args.idle_seconds);after=metrics(child.proc.pid);host_after=metrics(session.compositor.proc.pid)
                report['compositor_idle']={'pss_bytes':host_after['pss_bytes'],'cpu_ticks':host_after['cpu_ticks']-host_before['cpu_ticks'],'interval_seconds':args.idle_seconds}
                report['idle']={'pss_bytes':after['pss_bytes'],'cpu_ticks':after['cpu_ticks']-before['cpu_ticks'],'interval_seconds':args.idle_seconds}
                assert after['pss_bytes']<=150*1024*1024
                assert (after['cpu_ticks']-before['cpu_ticks'])/os.sysconf('SC_CLK_TCK')/args.idle_seconds<.005,report['idle']
            if theme=='material_light':
                session.run(['wlr-randr','--output',secondary,'--off']);session.run(['wlr-randr','--output',secondary,'--on'])
                time.sleep(.3);capture(session,'greeter-wallpaper-hotplug',secondary)
                from PIL import Image
                assert Image.open(session.output/'greeter-wallpaper-hotplug.png').convert('RGB').getpixel((0,0))==(28,26,34)
            time.sleep(.3);capture(session,'greeter-'+theme,primary)
            key('fixture-user','-k','Return');child.expect('event=greeter-state state=prompt')
            if theme=='material_dark':
                # Secondary monitor changes cannot create another prompt controller.
                key('discard-on-output-loss')
                session.run(['wlr-randr','--output',primary,'--off']);time.sleep(.3)
                # The card moves to the remaining monitor and clears the unsent response.
                session.run(['wlr-randr','--output',primary,'--on'])
                time.sleep(.3)
                capture(session,'greeter-secret-prompt',primary)
            key('fixture-secret','-k','Return')
            wait_for(lambda:sum('event=greeter-state state=prompt' in line for line in child.lines)>=2)
            if theme=='stale':
                with (root/'pearl.desktop').open('a') as f:f.write('Comment=changed during authentication\n')
            key('-k','Return')
            if theme=='stale':
                child.expect('event=greeter-state state=idle');child.stop()
                thread.join(3);server.close();assert not errors and len(requests)==1,(errors,requests)
                report['checks'].append('changed selection cancels without a start');continue
            assert child.wait()==0,child.lines[-20:]
            thread.join(3);server.close();assert not thread.is_alive() and not errors,(theme,errors)
            assert len(requests)==2
            if theme=='material_light':
                state=json.loads((session.base/'selections.json').read_text());assert state==[{'username':'fixture-user','session':'wayland:pearl.desktop'}]
            if theme=='small':session.run(['wlr-randr','--output',primary,'--scale','1'])
            assert not any('fixture-secret' in line for line in child.lines)
            report['checks'].append(theme+' keyboard login, info acknowledgement and single handoff')
    report['status']='passed';(args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))


if __name__=='__main__':main()
