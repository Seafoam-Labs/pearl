#!/usr/bin/env python3
"""Private-bus backend conformance tests; never uses the developer's portal."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,fixture_prefix


def client(binary):
    import gi
    gi.require_version("GioUnix","2.0")
    from gi.repository import Gio,GLib,GioUnix
    address=os.environ['DBUS_SESSION_BUS_ADDRESS']
    flags=Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
    bus=Gio.DBusConnection.new_for_address_sync(address,flags,None,None)
    attacker=Gio.DBusConnection.new_for_address_sync(address,flags,None,None)
    bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',('org.freedesktop.portal.Desktop',4)),GLib.VariantType.new('(u)'),0,3000,None)
    shell=subprocess.Popen([str(ROOT/'artifacts/portal-replacement/session-harness')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert shell.stdout.readline().strip()=='Ready'
    process=subprocess.Popen([str(binary)],env={**os.environ,'DBUS_SYSTEM_BUS_ADDRESS':address},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    destination='org.freedesktop.impl.portal.desktop.pearl';path='/org/freedesktop/portal/desktop'
    def call(interface,member,params=None,connection=bus,object_path=path):
        return connection.call_sync(destination,object_path,interface,member,params,None,0,5000,None)
    def pump_until(predicate):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            while GLib.MainContext.default().pending(): GLib.MainContext.default().iteration(False)
            if predicate(): return
            time.sleep(.01)
        raise AssertionError('backend callback timed out')
    def expect_error(function,fragment):
        try:function()
        except GLib.Error as error:assert fragment in str(error),error
        else:raise AssertionError('Expected '+fragment)
    pending=[]
    def request(interface,member,params):
        result=[]
        def done(conn,res,data):
            try:result.append(conn.call_finish(res))
            except GLib.Error as error:result.append(error)
        bus.call(destination,path,'org.freedesktop.impl.portal.'+interface,member,params,None,0,15000,None,done,None)
        pending.append(result)
        return result
    try:
        assert process.stdout.readline().strip()=='Pearl portal ready'
        time.sleep(.15)
        raw=call('org.freedesktop.DBus.Introspectable','Introspect').unpack()[0]
        parsed=ET.fromstring(raw)
        baseline=json.loads((ROOT/'tests/fixtures/portal/baseline.json').read_text())
        implemented=subprocess.check_output([str(binary),'--interfaces'],text=True).splitlines()
        for entry in baseline['interfaces']:
            assert hashlib.sha256((ROOT/'tests/fixtures/portal'/entry['xml']).read_bytes()).hexdigest()==entry['sha256']
            if entry['name'] not in implemented:continue
            interface=next(i for i in parsed.findall('interface') if i.get('name')==entry['name'])
            for member in entry['members']:
                native=next((x for x in interface if x.tag==member['kind'] and x.get('name')==member['name']),None)
                assert native is not None,(entry['name'],member)
                assert [(x.get('type'),x.get('direction','out')) for x in native.findall('arg')]==[(x['type'],x.get('direction','out')) for x in member['args']]
        print('PASS pinned interface signatures and installed implementations',flush=True)
        setting=GLib.Variant('(ss)',('org.freedesktop.appearance','color-scheme'))
        expect_error(lambda:call('org.freedesktop.impl.portal.Settings','Read',setting,attacker),'NotAllowed')
        assert call('org.freedesktop.impl.portal.Settings','Read',setting).unpack()==(1,)
        values=call('org.freedesktop.impl.portal.Settings','ReadAll',GLib.Variant('(as)',(['org.freedesktop.*'],))).unpack()[0]
        assert set(values)=={'org.freedesktop.appearance'},values
        assert values['org.freedesktop.appearance']['accent-color']==(208/255,188/255,1)
        expect_error(lambda:call('org.freedesktop.impl.portal.Settings','Read',GLib.Variant('(ss)',('unknown','key'))),'NotFound')
        expect_error(lambda:call('org.freedesktop.DBus.Properties','Set',GLib.Variant('(ssv)',('org.freedesktop.impl.portal.Lockdown','disable-printing',GLib.Variant('b',False)))),'AccessDenied')
        print('PASS trusted frontend boundary, typed appearance, namespace filtering and policy ownership',flush=True)
        cases=[
            ('FileChooser','OpenFile','(osssa{sv})',('org.example.Test','','Select files',{})),
            ('FileChooser','SaveFile','(osssa{sv})',('org.example.Test','','Save files',{})),
            ('Access','AccessDialog','(osssssa{sv})',('org.example.Test','','Permission','Allow microphone?','For this call.',{})),
            ('Account','GetUserInformation','(ossa{sv})',('org.example.Test','',{})),
            ('AppChooser','ChooseApplication','(ossasa{sv})',('org.example.Test','',[],{})),
            ('Print','PreparePrint','(osssa{sv}a{sv}a{sv})',('org.example.Test','','Print',{}, {}, {})),
        ]
        for i,(interface,member,signature,args) in enumerate(cases):
            handle=path+'/request/test/r'+str(i)
            result=request(interface,member,GLib.Variant(signature,(handle,*args)))
            time.sleep(.3)
            expect_error(lambda:call('org.freedesktop.impl.portal.Request','Close',None,attacker,handle),'NotAllowed')
            call('org.freedesktop.impl.portal.Request','Close',object_path=handle)
            pump_until(lambda:result)
            assert not isinstance(result[0],GLib.Error),result
            assert result[0].unpack()==(1,{}),result[0]
            expect_error(lambda:call('org.freedesktop.impl.portal.Request','Close',object_path=handle),'UnknownMethod')
        def shell_call(member,params=None,interface='org.pearl.Test',object_path='/org/seafoam/Pearl/Test',connection=bus):
            return connection.call_sync('org.seafoam.Pearl.Session',object_path,interface,member,params,None,0,3000,None)
        expect_error(lambda:shell_call('Acquire',GLib.Variant('(sus)',('bad',1,'bad')),interface='org.seafoam.Pearl.Session.Inhibit',object_path='/org/seafoam/Pearl/Session'),'AccessDenied')
        mailroot=Path(os.environ['XDG_DATA_HOME'])/'applications';mailroot.mkdir(parents=True,exist_ok=True)
        capture=mailroot/'capture-mail.py';received=mailroot/'received.json'
        capture.write_text('import json,sys\nfrom pathlib import Path\nPath('+repr(str(received))+').write_text(json.dumps(sys.argv[1:]))\n')
        desktop=mailroot/'pearl-portal-test-mail.desktop'
        desktop.write_text('[Desktop Entry]\nType=Application\nName=Test mail composer\nExec=/usr/bin/python3 '+str(capture)+' %u\nMimeType=x-scheme-handler/mailto;\n')
        app=GioUnix.DesktopAppInfo.new_from_filename(str(desktop))
        assert app.set_as_default_for_type('x-scheme-handler/mailto')
        mail_options={'addresses':GLib.Variant('as',['person@example.test']), 'subject':GLib.Variant('s',"Unicode ✓ & literal $(echo nope)"), 'body':GLib.Variant('s','Line one\nLine two')}
        mail=request('Email','ComposeEmail',GLib.Variant('(ossa{sv})',(path+'/request/test/mail','org.example.Test','',mail_options)))
        pump_until(lambda:mail and received.exists())
        assert mail[0].unpack()==(0,{}),mail
        from urllib.parse import urlsplit,parse_qs
        uri=json.loads(received.read_text())[0];fields=parse_qs(urlsplit(uri).query)
        assert fields['subject']==[mail_options['subject'].unpack()]
        assert fields['body']==['Line one\nLine two']
        assert fields['to']==['person@example.test']
        print('PASS default mail composer handoff and literal Unicode/URI argument encoding',flush=True)
        notice={'title':GLib.Variant('s','A notification'), 'body':GLib.Variant('s','Body'), 'buttons':GLib.Variant('aa{sv}',[{'label':GLib.Variant('s','View'), 'action':GLib.Variant('s','view'), 'target':GLib.Variant('s','document')}])}
        notice_params=GLib.Variant('(ssa{sv})',('org.example.Test','notice',notice))
        call('org.freedesktop.impl.portal.Notification','AddNotification',notice_params)
        call('org.freedesktop.impl.portal.Notification','AddNotification',notice_params)
        assert shell_call('Notices').unpack()==(1,1)
        # Keep the notification server alive while restarting only the adapter.
        process.terminate()
        out,errors=process.communicate(timeout=5)
        assert process.returncode==0 and 'CRITICAL' not in errors and 'WARNING' not in errors,(out,errors)
        process=subprocess.Popen([str(binary)],env={**os.environ,'DBUS_SYSTEM_BUS_ADDRESS':address},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        assert process.stdout.readline().strip()=='Pearl portal ready'
        time.sleep(.2)
        actions=[]
        bus.signal_subscribe(destination,'org.freedesktop.impl.portal.Notification','ActionInvoked',path,None,0,lambda c,s,p,i,m,args,d:actions.append(args.unpack()),None)
        shell_call('Trigger')
        pump_until(lambda:actions)
        assert actions[0][:4]==('org.example.Test','notice','view',['document',{}]),actions
        call('org.freedesktop.impl.portal.Notification','AddNotification',notice_params)
        assert shell_call('Notices').unpack()==(1,2)
        other=GLib.Variant('(ssa{sv})',('org.example.Other','notice',notice))
        call('org.freedesktop.impl.portal.Notification','AddNotification',other)
        call('org.freedesktop.impl.portal.Notification','RemoveNotification',GLib.Variant('(ss)',('org.example.Test','notice')))
        assert shell_call('Notices').unpack()==(1,2)
        shell.terminate();shell.communicate(timeout=5)
        time.sleep(.1)
        shell=subprocess.Popen([str(ROOT/'artifacts/portal-replacement/session-harness')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        assert shell.stdout.readline().strip()=='Ready'
        time.sleep(.2)
        call('org.freedesktop.impl.portal.Notification','AddNotification',other)
        assert shell_call('Notices').unpack()==(1,0),'Reused numeric ID from the old notification service'
        call('org.freedesktop.impl.portal.Notification','RemoveNotification',GLib.Variant('(ss)',('org.example.Other','notice')))
        assert shell_call('Notices').unpack()==(0,0)
        print('PASS notification replacement, backend/service restart recovery, app isolation, persisted actions and withdrawal',flush=True)
        consent=request('Access','AccessDialog',GLib.Variant('(osssssa{sv})',(path+'/request/test/consent','org.example.Test','','Permission','Allow access?','Test request',{'choices':GLib.Variant('a(ssa(ss)s)',[('remember','Remember this choice',[],'true')])})))
        time.sleep(.3)
        subprocess.run(['wtype','-s','100','-k','Tab','-k','Return'],check=True)
        pump_until(lambda:consent)
        assert consent[0].unpack()==(0,{'choices':[('remember','true')]}),consent[0]
        print('PASS native explicit consent and application-choice round trip',flush=True)
        print_result=request('Print','PreparePrint',GLib.Variant('(osssa{sv}a{sv}a{sv})',(path+'/request/test/prepare','org.example.Test','','Print test',{}, {}, {'supported_output_file_formats':GLib.Variant('as',['pdf'])})))
        time.sleep(3)
        subprocess.run(['wtype','-s','100','-k','Tab','-k','Return'],check=True)
        time.sleep(.5)
        subprocess.run(['wtype','-s','100','-M','ctrl','-k','Return','-m','ctrl'],check=True)
        pump_until(lambda:print_result)
        response,values=print_result[0].unpack();assert response==0,(response,values)
        assert values['settings']['output-file-format']=='pdf'
        output=Path(os.environ['HOME'])/'Document.pdf';assert not output.exists()
        document=mailroot/'document.pdf';payload=b'%PDF-1.4\nportal fixture\n';document.write_bytes(payload)
        def print_token(app,token,handle):
            with document.open('rb') as stream:
                fds=Gio.UnixFDList.new();index=fds.append(stream.fileno())
                reply,returned=bus.call_with_unix_fd_list_sync(destination,path,'org.freedesktop.impl.portal.Print','Print',GLib.Variant('(osssha{sv})',(path+'/request/test/'+handle,app,'','Print document',index,{'token':GLib.Variant('u',token)})),None,0,8000,fds,None)
                return reply.unpack()
        assert print_token('org.example.Other',values['token'],'wrongapp')==(2,{})
        assert print_token('org.example.Test',values['token'],'printfile')==(0,{})
        assert output.read_bytes()==payload
        assert print_token('org.example.Test',values['token'],'replay')==(2,{})
        print('PASS native print preparation, app-scoped single-use token, FD transfer and print-to-file',flush=True)

        holds=[]
        for i,flags_value in enumerate([1,2,3,4,8,12,15]):
            handle=path+'/request/test/hold'+str(i)
            assert call('org.freedesktop.impl.portal.Inhibit','Inhibit',GLib.Variant('(ossua{sv})',(handle,'org.example.Test','',flags_value,{'reason':GLib.Variant('s','Unsaved work')}))).unpack()==()
            holds.append(handle)
        assert shell_call('Holds').unpack()==(15,)
        assert shell_call('InhibitorCount').unpack()==(4,)
        expect_error(lambda:call('org.freedesktop.impl.portal.Request','Close',connection=attacker,object_path=holds[0]),'NotAllowed')
        events=[]
        bus.signal_subscribe(destination,'org.freedesktop.impl.portal.Inhibit','StateChanged',path,None,0,lambda c,s,p,i,m,args,d:events.append(args.unpack()),None)
        session=path+'/session/test/monitor'
        assert call('org.freedesktop.impl.portal.Inhibit','CreateMonitor',GLib.Variant('(ooss)',(path+'/request/test/monitor',session,'org.example.Test',''))).unpack()==(0,)
        pump_until(lambda:events)
        assert events[-1][1]['session-state']==1
        shell_call('Lock',GLib.Variant('(b)',(True,)))
        pump_until(lambda:events[-1][1]['screensaver-active'])
        shell_call('End')
        pump_until(lambda:events[-1][1]['session-state']==2)
        call('org.freedesktop.impl.portal.Inhibit','QueryEndResponse',GLib.Variant('(o)',(session,)))
        pump_until(lambda:events[-1][1]['session-state']==1)
        for handle in holds:call('org.freedesktop.impl.portal.Request','Close',object_path=handle)
        pump_until(lambda:shell_call('Holds').unpack()==(0,) and shell_call('InhibitorCount').unpack()==(0,))
        call('org.freedesktop.impl.portal.Session','Close',object_path=session)
        print('PASS shell-owned holds, logind FD release, owner isolation, monitor state and query-end acknowledgement',flush=True)
        assert call('org.freedesktop.impl.portal.DynamicLauncher','RequestInstallToken',GLib.Variant('(sa{sv})',('org.example.Untrusted',{}))).unpack()==(2,)
        print('PASS request cancellation, owner isolation, removal and noninteractive installation denial',flush=True)
        handle=path+'/request/test/ownerloss'
        result=request('Access','AccessDialog',GLib.Variant('(osssssa{sv})',(handle,'org.example.Test','','Permission','Allow?','',{})))
        time.sleep(.3)
        bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ReleaseName',GLib.Variant('(s)',('org.freedesktop.portal.Desktop',)),None,0,3000,None)
        pump_until(lambda:result)
        assert result[0].unpack()==(1,{})
        expect_error(lambda:call('org.freedesktop.impl.portal.Settings','Read',setting),'NotAllowed')
        print('PASS frontend owner loss cancels pending consent and revokes authority',flush=True)
    finally:
        shell.terminate()
        shell.communicate(timeout=5)
        process.terminate()
        output,errors=process.communicate(timeout=5)
        assert process.returncode==0,(process.returncode,output,errors)
        assert 'CRITICAL' not in errors and 'WARNING' not in errors,errors
        attacker.close_sync(None);bus.close_sync(None)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--client',action='store_true');parser.add_argument('--binary',type=Path,default=ROOT/'zig-out/bin/xdg-desktop-portal-pearl');args=parser.parse_args()
    if args.client:return client(args.binary.resolve())
    output=ROOT/'artifacts/portal-replacement/session-harness'
    output.parent.mkdir(parents=True,exist_ok=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','gio-2.0'],text=True).split()
    subprocess.run(['cc',str(ROOT/'tests/portal/session_harness.c'),str(ROOT/'src/services/portal_session.c'),'-o',str(output),*flags],check=True)
    with PrivateSession(ROOT/'artifacts/portal-replacement/contracts',tool_prefix=fixture_prefix()) as session:
        result=subprocess.run([sys.executable,Path(__file__).resolve(),'--client','--binary',args.binary.resolve()],env={**session.env,'G_DEBUG':'fatal-warnings','GIO_USE_VFS':'local','GSETTINGS_BACKEND':'memory'},cwd=session.base,capture_output=True,text=True,timeout=40)
        print(result.stdout);print(result.stderr,file=sys.stderr)
        assert result.returncode==0,result.returncode

if __name__=='__main__':main()
