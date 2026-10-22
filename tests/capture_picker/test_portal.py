#!/usr/bin/env python3
"""Real public portal, patched Aqueous backend, Pearl picker and PipeWire frames."""
import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
import uuid
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix, wait_for

def paint(connector):
    import gi
    gi.require_version('Gtk','4.0')
    from gi.repository import Gtk,Gdk,GLib
    app=Gtk.Application(application_id='org.aqueous.Pearl.CaptureFixture',flags=32)
    def activate(app):
        window=Gtk.ApplicationWindow(application=app,title='Capture fixture')
        display=Gdk.Display.get_default(); monitors=display.get_monitors()
        monitor=next(monitors.get_item(i) for i in range(monitors.get_n_items()) if monitors.get_item(i).get_connector()==connector)
        provider=Gtk.CssProvider();Gtk.StyleContext.add_provider_for_display(display,provider,Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        window.add_css_class('capture-fixture')
        count=[0]
        def frame():
            count[0]+=1
            color=('#e02020' if count[0]%2 else '#df2020') if connector=='HEADLESS-1' else ('#2030e0' if count[0]%2 else '#2030df')
            provider.load_from_string('.capture-fixture {background:'+color+';}')
            return True
        frame();GLib.timeout_add(80,frame)
        window.fullscreen_on_monitor(monitor);window.present()
        print('PAINT READY',connector,flush=True)
    app.connect('activate',activate);app.run([])

def client():
    import gi
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    base = '/org/freedesktop/portal/desktop'
    destination = 'org.freedesktop.portal.Desktop'
    replies = {}
    control = Path(os.environ['PICKER_CONTROL'])
    pidfile = Path(os.environ['PICKER_PID'])
    bus.signal_subscribe(destination, 'org.freedesktop.portal.Request', 'Response', None, None, 0,
                         lambda c,s,p,i,m,args,data: replies.update({p: args.unpack()}), None)
    def call(interface, method, args=None, path=base):
        return bus.call_sync(destination,path,interface,method,args,None,0,5000,None)
    def pump(predicate):
        def check():
            while GLib.MainContext.default().pending(): GLib.MainContext.default().iteration(False)
            return predicate()
        return wait_for(check, 12)
    def request(method, args):
        return call('org.freedesktop.portal.ScreenCast',method,args).unpack()[0]
    def response(handle):
        pump(lambda: handle in replies)
        return replies.pop(handle)
    def create():
        code, value = response(request('CreateSession',GLib.Variant('(a{sv})',({'handle_token':GLib.Variant('s','request_'+uuid.uuid4().hex),'session_handle_token':GLib.Variant('s','capture_'+uuid.uuid4().hex)},))))
        assert code == 0, value
        return value['session_handle']
    def start(session):
        pidfile.unlink(missing_ok=True)
        return request('Start',GLib.Variant('(osa{sv})',(session,'',{'handle_token':GLib.Variant('s','request_'+uuid.uuid4().hex)})))
    def select(session):
        return request('SelectSources',GLib.Variant('(oa{sv})',(session,{'handle_token':GLib.Variant('s','request_'+uuid.uuid4().hex),'types':GLib.Variant('u',1),'cursor_mode':GLib.Variant('u',1)})))
    def close(session):
        try: call('org.freedesktop.portal.Session','Close',path=session)
        except GLib.Error as error:
            if 'UnknownMethod' not in str(error): raise

    def dead(pid):
        try: os.kill(pid,0)
        except ProcessLookupError: return True
        return False
    assert call('org.freedesktop.DBus.Properties','Get',GLib.Variant('(ss)',('org.freedesktop.portal.Screenshot','version'))).unpack()[0] >= 1
    for index in (0,1):
        control.write_text(str(index)); session = create()
        code, result = response(select(session)); assert code == 0, result
        code, result = response(start(session))
        assert pidfile.exists(), 'Pearl picker was not invoked at Start'
        assert code == 0 and len(result['streams']) == 1, result
        node, properties = result['streams'][0]
        # Reconnect a consumer to exercise pause/resume on the same capture.
        for attempt in range(2):
            reply, fds = bus.call_with_unix_fd_list_sync(destination,base,'org.freedesktop.portal.ScreenCast','OpenPipeWireRemote',GLib.Variant('(oa{sv})',(session,{})),None,0,5000,None,None)
            fd = fds.get(reply.unpack()[0])
            target = Path(os.environ['CAPTURE_RESULTS']) / f'source-{index}-{attempt}.png'
            target.unlink(missing_ok=True)
            try:
                consumer = subprocess.Popen(['gst-launch-1.0','-q','pipewiresrc',f'fd={fd}',f'path={node}','num-buffers=1','!','videoconvert','!','video/x-raw,format=RGB','!','pngenc','snapshot=true','!','filesink',f'location={target}'],pass_fds=(fd,),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                try:
                    def ports(flag):
                        assert consumer.poll() is None, consumer.communicate()
                        return subprocess.check_output(['pw-link',flag],text=True).splitlines()
                    outputs = pump(lambda: ports('-o'))
                    inputs = pump(lambda: ports('-i'))
                    assert len(outputs) == len(inputs) == 1, (outputs,inputs)
                    subprocess.run(['pw-link',outputs[0],inputs[0]],check=True)
                    out, err = consumer.communicate(timeout=12)
                    assert consumer.returncode == 0 and target.stat().st_size > 0, err
                    gi.require_version('GdkPixbuf', '2.0')
                    from gi.repository import GdkPixbuf
                    frame = GdkPixbuf.Pixbuf.new_from_file(str(target))
                    offset = (frame.get_height()//2)*frame.get_rowstride() + (frame.get_width()//2)*frame.get_n_channels()
                    red,green,blue = frame.get_pixels()[offset:offset+3]
                    assert (red>180 and blue<80) if index==0 else (blue>180 and red<80), (index,red,green,blue)
                finally:
                    if consumer.poll() is None: consumer.kill()
                    consumer.wait()

            finally: os.close(fd)
        close(session)
        print('PASS public ScreenCast source',index,'PipeWire frames before/after consumer reconnect',properties,flush=True)
    for mode,expected in [('legacy',0),('failed',1)]:
        control.write_text(mode); session=create()
        code,value=response(select(session));assert code==0,(mode,code,value)
        code,value=response(start(session));assert code==expected,(mode,code,value)
        close(session)
    print('PASS custom chooser without trailing newline and failed chooser rejection',flush=True)
    control.write_text('cancel'); session = create()
    assert response(select(session))[0] == 0
    code, result = response(start(session)); assert code == 1 and not result, (code,result)
    close(session)
    control.write_text('hold'); session = create(); assert response(select(session))[0] == 0; handle = start(session)
    pump(pidfile.exists); pid = int(pidfile.read_text())
    time.sleep(.4)
    try:
        bus.call_sync('org.freedesktop.impl.portal.desktop.aqueous',handle,'org.freedesktop.impl.portal.Request','Close',None,None,0,5000,None)
    except GLib.Error as error:
        assert 'AccessDenied' in str(error), error
    else: raise AssertionError('Backend accepted Close from a sender other than the frontend')
    assert not dead(pid)
    call('org.freedesktop.portal.Request','Close',path=handle)
    pump(lambda: dead(pid))
    close(session)
    print('PASS public Request.Close terminates open Pearl picker without creating a stream',flush=True)
    # A session close while Start is pending must also release its UI.
    session = create(); assert response(select(session))[0] == 0; handle = start(session)
    pump(pidfile.exists); pid = int(pidfile.read_text()); time.sleep(.3)
    close(session); pump(lambda: dead(pid))
    print('PASS session closure terminates pending picker',flush=True)
    session = create(); assert response(select(session))[0] == 0; start(session)
    pump(pidfile.exists); pid = int(pidfile.read_text()); time.sleep(.3)
    os.kill(int(os.environ['FRONTEND_PID']),signal.SIGKILL)
    pump(lambda: dead(pid))
    print('PASS frontend owner loss terminates pending picker',flush=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--client',action='store_true');parser.add_argument('--paint');parser.add_argument('--backend',type=Path);parser.add_argument('--picker',type=Path,default=ROOT/'zig-out/capture-test/bin/pearl-capture-picker');parser.add_argument('--gst-plugin-path',type=Path);parser.add_argument('--output',type=Path,default=ROOT/'artifacts/capture-picker/portal');args=parser.parse_args()
    if args.paint: return paint(args.paint)
    if args.client: return client()
    if args.backend is None: parser.error('--backend must point to the rebuilt Aqueous capture backend')
    with PrivateSession(args.output,tool_prefix=fixture_prefix()) as session:
        if args.gst_plugin_path:
            session.env['GST_PLUGIN_PATH'] = str(args.gst_plugin_path.resolve())
        for connector in ['HEADLESS-1','HEADLESS-2']:
            fixture=session.child(connector,[sys.executable,__file__,'--paint',connector])
            fixture.expect('PAINT READY')
        control=session.base/'choice'; pidfile=session.base/'picker.pid'; chooser=session.base/'chooser'
        chooser.write_text('#!/bin/sh\necho $$ > '+shlex.quote(str(pidfile))+'\nmode=$(cat '+shlex.quote(str(control))+')\ncase "$mode" in\n legacy) head -n 1 | tr -d "\\n"; exit 0;;\n failed) head -n 1; exit 2;;\n cancel) export PEARL_CAPTURE_TEST_ACTION=cancel;;\n hold) ;;\n *) export PEARL_CAPTURE_TEST_SELECT="$mode" PEARL_CAPTURE_TEST_ACTION=share;;\nesac\nexec '+shlex.quote(str(args.picker.resolve()))+'\n')
        chooser.chmod(0o755)
        config=session.base/'capture.conf';config.write_text('[screencast]\nchooser_type=dmenu\nchooser_cmd='+str(chooser)+'\n')
        pw=session.base/'pipewire.conf';pw.write_text('''context.properties = { core.daemon = true core.name = pipewire-0 }
context.spa-libs = { support.* = support/libspa-support }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-adapter }
 { name = libpipewire-module-link-factory }
 { name = libpipewire-module-access args = { access.force = unrestricted } }
]
''')
        session.child('pipewire',['pipewire','-c',pw]);wait_for(lambda:(session.runtime/'pipewire-0').exists())
        backend=session.child('backend',[args.backend,'-c',config,'-l','DEBUG'])
        portals=session.base/'portals';portals.mkdir()
        (portals/'aqueous.portal').write_text('[portal]\nDBusName=org.freedesktop.impl.portal.desktop.aqueous\nInterfaces=org.freedesktop.impl.portal.ScreenCast;org.freedesktop.impl.portal.Screenshot;\nUseIn=Aqueous;\n')
        profiles=portals
        for name in ['pearl.portal','pearl-portals.conf']:
            (profiles/name).write_bytes((ROOT/'packaging/portal'/name).read_bytes())
        session.child('pearl-backend',[ROOT/'zig-out/bin/xdg-desktop-portal-pearl'])
        def owns(name):
            return 'true' in session.run(['gdbus','call','--session','--dest','org.freedesktop.DBus','--object-path','/org/freedesktop/DBus','--method','org.freedesktop.DBus.NameHasOwner',name]).stdout
        wait_for(lambda:owns('org.freedesktop.impl.portal.desktop.aqueous'))
        session.child('permission-store',['/usr/lib/xdg-permission-store'])
        frontend=session.child('frontend',['/usr/lib/xdg-desktop-portal','--verbose'],XDG_DESKTOP_PORTAL_DIR=str(portals),XDG_CURRENT_DESKTOP='Pearl:Aqueous')
        wait_for(lambda:owns('org.freedesktop.portal.Desktop'))
        result=subprocess.run([sys.executable,__file__,'--client'],env={**session.env,'PICKER_CONTROL':str(control),'PICKER_PID':str(pidfile),'CAPTURE_RESULTS':str(session.output),'FRONTEND_PID':str(frontend.proc.pid)},capture_output=True,text=True,timeout=65)
        print(result.stdout,flush=True)
        assert result.returncode==0,result.stderr
        assert backend.proc.poll() is None,backend.lines
        assert any('aqueous.portal' in line for line in frontend.lines)
if __name__=='__main__':main()
