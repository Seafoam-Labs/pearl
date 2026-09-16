#!/usr/bin/env python3
"""Private login1 and polkit authority. No host services or privileged mutations."""
import gi
from gi.repository import Gio, GLib
import json, os, sys, socket
from pathlib import Path
assert os.environ['DBUS_SYSTEM_BUS_ADDRESS'].startswith('unix:path=/tmp/pearl-dev-')
bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
loop=GLib.MainLoop(); owners={}; registered=None; cookie='fixture-cookie'; inhibited=''; active=True; counter=0; on_battery=False
discovery=os.environ.get('PEARL_TEST_SESSION_DISCOVERY','direct')
compositor_pid=int(os.environ.get('PEARL_TEST_COMPOSITOR_PID','0'))
log=Path(os.environ['PEARL_SECURITY_LOG'])
def record(event,**fields):
    with log.open('a') as f: f.write(json.dumps(dict(event=event,**fields))+'\n')
    print('event='+event,flush=True)
def own(name):
    owners[name]=Gio.bus_own_name_on_connection(bus,name,Gio.BusNameOwnerFlags.NONE,None,None)
def locked():
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(os.environ['AQUEOUS_SOCKET']); f=s.makefile('rb')
        s.sendall(b'{"ipc":1,"id":"1","op":"hello","params":{}}\n'); session=json.loads(f.readline())['result']['session']
        s.sendall((json.dumps(dict(ipc=1,id='2',op='snapshot',session=session,params={}))+'\n').encode())
        return next(x for x in json.loads(f.readline())['result']['batch']['upsert'] if x['kind']=='session')['locked']
def prepare(value):
    bus.emit_signal(None,'/org/freedesktop/login1','org.freedesktop.login1.Manager','PrepareForSleep',GLib.Variant('(b)',(value,)))
    record('prepare',value=value)
def method(conn,sender,path,iface,name,args,inv):
    global registered,counter
    if name=='GetSessionByPID':
        pid=args.unpack()[0]
        record('session-lookup',method=name,compositor=pid==compositor_pid)
        if discovery.startswith('compositor-') and pid==compositor_pid:
            session='manager' if discovery=='compositor-manager' else '5'
            inv.return_value(GLib.Variant('(o)',('/org/freedesktop/login1/session/'+session,)))
        elif discovery=='process-dual' and pid!=compositor_pid:
            inv.return_value(GLib.Variant('(o)',('/org/freedesktop/login1/session/5',)))
        elif discovery in ('direct','manager'):
            inv.return_value(GLib.Variant('(o)',('/org/freedesktop/login1/session/'+('manager' if discovery=='manager' else 'test'),)))
        else: inv.return_dbus_error('org.freedesktop.login1.NoSessionForPID','PID belongs to a user service, not a login session')
    elif name=='GetSession':
        session=args.unpack()[0]
        record('session-lookup',method=name,session=session)
        if session in ('3','5'):
            inv.return_value(GLib.Variant('(o)',('/org/freedesktop/login1/session/'+session,)))
        else: inv.return_dbus_error('org.freedesktop.login1.NoSuchSession','No such login session')
    elif name=='GetUser':
        assert args.unpack()[0]==os.getuid()
        record('session-lookup',method=name)
        inv.return_value(GLib.Variant('(o)',('/org/freedesktop/login1/user/test',)))
    elif name=='Get':
        assert args.unpack()==('org.freedesktop.login1.User','Display')
        display=('', '/') if discovery=='missing' else ('test','/org/freedesktop/login1/session/test')
        if discovery.startswith('compositor-') or discovery.startswith('environment-'): display=('3','/org/freedesktop/login1/session/3')
        inv.return_value(GLib.Variant('(v)',(GLib.Variant('(so)',display),)))
    elif name.startswith('Can'): inv.return_value(GLib.Variant('(s)',('yes',)))
    elif name=='GetAll':
        values={'OnBattery':GLib.Variant('b',on_battery)} if path=='/org/freedesktop/UPower' else {'Id':GLib.Variant('s','test'),'Active':GLib.Variant('b',active),'Class':GLib.Variant('s','manager' if path.endswith('/manager') else 'greeter' if discovery=='greeter' else 'user'),'User':GLib.Variant('(uo)',(os.getuid()+1 if discovery=='foreign' else os.getuid(),'/org/freedesktop/login1/user/test'))}
        if path.endswith(('/3','/5')):
            values['Id']=GLib.Variant('s',path.rsplit('/',1)[1])
            values['Active']=GLib.Variant('b',active and path.endswith('/5'))
            if discovery.endswith('-foreign'): values['User']=GLib.Variant('(uo)',(os.getuid()+1,'/org/freedesktop/login1/user/test'))
            if discovery.endswith('-greeter'): values['Class']=GLib.Variant('s','greeter')
        inv.return_value(GLib.Variant('(a{sv})',(values,)))
    elif name=='Inhibit':
        values=args.unpack(); assert values[0]=='sleep' and values[3]=='delay'
        r,w=os.pipe(); fds=Gio.UnixFDList.new(); index=fds.append(w); os.close(w); counter+=1; lease=counter
        inv.return_value_with_unix_fd_list(GLib.Variant('(h)',(index,)),fds)
        record('delay-acquired',lease=lease)
        def released(fd,condition):
            os.close(fd); record('delay-released',lease=lease,locked=locked()); return False
        GLib.io_add_watch(r,GLib.IOCondition.HUP,released)
    elif name=='ListInhibitors':
        values=[(inhibited,'Fixture','Private test','block',os.getuid(),os.getpid())] if inhibited else []
        inv.return_value(GLib.Variant('(a(ssssuu))',(values,)))
    elif name in ('Suspend','Hibernate'):
        record(name,locked=locked()); prepare(True); inv.return_value(GLib.Variant('()',()))
    elif name in ('PowerOff','Reboot'): record(name); inv.return_value(GLib.Variant('()',()))
    elif name=='RegisterAuthenticationAgent':
        session=args.unpack()[0]
        assert session[0]=='unix-session' and session[1]['session-id'] in ('test','3','5')
        if registered:
            inv.return_dbus_error('org.freedesktop.PolicyKit1.Error.Failed','Agent exists'); return
        registered=(sender,args.unpack()[2]); record('registered',sender=sender,session=session[1]['session-id']); inv.return_value(GLib.Variant('()',()))
    elif name=='UnregisterAuthenticationAgent': registered=None; record('unregistered'); inv.return_value(GLib.Variant('()',()))
    else: inv.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod','Fixture method unavailable')
def export(path,xml):
    for iface in Gio.DBusNodeInfo.new_for_xml(xml).interfaces: bus.register_object(path,iface,method,None,None)
export('/org/freedesktop/login1','''<node><interface name="org.freedesktop.login1.Manager">
<method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
<method name="GetSession"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
<method name="GetUser"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
<method name="CanSuspend"><arg type="s" direction="out"/></method><method name="CanHibernate"><arg type="s" direction="out"/></method>
<method name="CanPowerOff"><arg type="s" direction="out"/></method><method name="CanReboot"><arg type="s" direction="out"/></method>
<method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="h" direction="out"/></method>
<method name="ListInhibitors"><arg type="a(ssssuu)" direction="out"/></method>
<method name="Suspend"><arg type="b" direction="in"/></method><method name="Hibernate"><arg type="b" direction="in"/></method>
<method name="PowerOff"><arg type="b" direction="in"/></method><method name="Reboot"><arg type="b" direction="in"/></method>
<signal name="PrepareForSleep"><arg type="b"/></signal></interface></node>''')
export('/org/freedesktop/login1/session/test','''<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method><signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal></interface></node>''')
export('/org/freedesktop/login1/session/manager','''<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method></interface></node>''')
for session in ('3','5'):
    export('/org/freedesktop/login1/session/'+session,'<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method></interface></node>')
export('/org/freedesktop/login1/user/test','''<node><interface name="org.freedesktop.DBus.Properties"><method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method></interface></node>''')
export('/org/freedesktop/PolicyKit1/Authority','''<node><interface name="org.freedesktop.PolicyKit1.Authority"><method name="RegisterAuthenticationAgent"><arg type="(sa{sv})" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/></method><method name="UnregisterAuthenticationAgent"><arg type="(sa{sv})" direction="in"/><arg type="s" direction="in"/></method></interface></node>''')
export('/org/freedesktop/UPower','<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method><signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal></interface></node>')
for name in ('org.freedesktop.login1','org.freedesktop.PolicyKit1','org.freedesktop.UPower'): own(name)
def callback(conn,result,label):
    try: conn.call_finish(result); record(label,outcome='completed')
    except GLib.Error as e: record(label,outcome='cancelled' if 'Cancelled' in e.message else 'failed')
def command(fd,condition):
    global inhibited,active,registered,on_battery,discovery
    line=sys.stdin.readline()
    if not line: loop.quit(); return False
    data=json.loads(line)
    if 'discovery' in data: discovery=data['discovery']
    if data.get('session_new'): bus.emit_signal(None,'/org/freedesktop/login1','org.freedesktop.login1.Manager','SessionNew',GLib.Variant('(so)',('test','/org/freedesktop/login1/session/test')))
    if 'battery' in data:
        on_battery=data['battery'];bus.emit_signal(None,'/org/freedesktop/UPower','org.freedesktop.DBus.Properties','PropertiesChanged',GLib.Variant('(sa{sv}as)',('org.freedesktop.UPower',{'OnBattery':GLib.Variant('b',on_battery)},[])))
    if 'inhibit' in data: inhibited=data['inhibit']
    if 'prepare' in data: prepare(data['prepare'])
    if 'active' in data:
        active=data['active']; bus.emit_signal(None,'/org/freedesktop/login1/session/test','org.freedesktop.DBus.Properties','PropertiesChanged',GLib.Variant('(sa{sv}as)',('org.freedesktop.login1.Session',{'Active':GLib.Variant('b',active)},[])))
        for session in ('3','5'):
            bus.emit_signal(None,'/org/freedesktop/login1/session/'+session,'org.freedesktop.DBus.Properties','PropertiesChanged',GLib.Variant('(sa{sv}as)',('org.freedesktop.login1.Session',{'Active':GLib.Variant('b',active and session=='5')},[])))
    if 'begin' in data:
        assert registered
        identities=[('unix-user',{'uid':GLib.Variant('u',uid)}) for uid in (os.getuid(),65534)]
        if data.get('unsupported'): identities=[('unix-group',{'gid':GLib.Variant('u',0)})]
        bus.call(*registered,'org.freedesktop.PolicyKit1.AuthenticationAgent','BeginAuthentication',GLib.Variant('(sssa{ss}sa(sa{sv}))',('org.pearl.test','A private test needs authentication','',{},cookie,identities)),GLib.VariantType.new('()'),Gio.DBusCallFlags.NONE,150000,None,callback,'authentication')
    if 'cancel' in data and registered:
        bus.call(*registered,'org.freedesktop.PolicyKit1.AuthenticationAgent','CancelAuthentication',GLib.Variant('(s)',(cookie,)),None,Gio.DBusCallFlags.NONE,5000,None,callback,'cancel')
    if 'restart' in data:
        name=data['restart']; Gio.bus_unown_name(owners.pop(name));
        if name=='org.freedesktop.PolicyKit1': registered=None
        GLib.timeout_add(250,lambda:(own(name),False)[1])
    print('command='+json.dumps(data,sort_keys=True),flush=True); return True
GLib.io_add_watch(sys.stdin,GLib.IOCondition.IN,command)
record('ready'); loop.run()
