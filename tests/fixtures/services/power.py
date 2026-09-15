#!/usr/bin/env python3
"""Private system-bus peer; never connect without an explicit private address."""
import gi
from gi.repository import Gio, GLib
import json, os, sys
from pathlib import Path
assert os.environ['DBUS_SYSTEM_BUS_ADDRESS'].startswith('unix:path=/tmp/pearl-dev-')
root=Path(os.environ['PEARL_TEST_BACKLIGHT'])
log=Path(os.environ['PEARL_TEST_POWER_LOG'])
bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
loop=GLib.MainLoop()
denied=False; delay=180
battery={'IsPresent':GLib.Variant('b',True),'Percentage':GLib.Variant('d',72.5),'State':GLib.Variant('u',2),'TimeToEmpty':GLib.Variant('x',7200),'TimeToFull':GLib.Variant('x',0)}
profile={'ActiveProfile':GLib.Variant('s','balanced'),'Profiles':GLib.Variant('aa{sv}',[{'Profile':GLib.Variant('s',n)} for n in ('power-saver','balanced','performance')]),'PerformanceDegraded':GLib.Variant('s','')}
session={'Active':GLib.Variant('b',True),'Id':GLib.Variant('s','test'),'Class':GLib.Variant('s','user'),'User':GLib.Variant('(uo)',(os.getuid(),'/org/freedesktop/login1/user/test'))}
upower={'OnBattery':GLib.Variant('b',True)}
objects={}
PROFILE_BUS = 'net.hadess.PowerProfiles' if os.environ.get('PEARL_TEST_LEGACY_PROFILES') else 'org.freedesktop.UPower.PowerProfiles'
PROFILE_PATH = '/net/hadess/PowerProfiles' if os.environ.get('PEARL_TEST_LEGACY_PROFILES') else '/org/freedesktop/UPower/PowerProfiles'
props_xml='''<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method><method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method><method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method><signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal></interface></node>'''

def record(kind,**values):
    with log.open('a') as f: f.write(json.dumps(dict(kind=kind,**values))+'\n')

def changed(path,interface,values):
    bus.emit_signal(None,path,'org.freedesktop.DBus.Properties','PropertiesChanged',GLib.Variant('(sa{sv}as)',(interface,values,[])))

def complete(invocation,kind,action):
    reject=denied is True or denied==kind
    def done():
        if reject:
            record(kind,denied=True)
            invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied','Private fixture denied permission')
        else:
            action(); invocation.return_value(GLib.Variant('()',()))
        return False
    GLib.timeout_add(delay,done)

def method(connection,sender,path,interface,name,args,invocation):
    values=args.unpack()
    target_interface,properties=objects[path]
    if interface=='org.freedesktop.DBus.Properties':
        if name=='GetAll': invocation.return_value(GLib.Variant('(a{sv})',(properties,)))
        elif name=='Get': invocation.return_value(GLib.Variant('(v)',(properties[values[1]],)))
        elif name=='Set':
            key,value=values[1:]
            if key!='ActiveProfile' or value not in ('balanced','power-saver','performance'):
                invocation.return_dbus_error('org.freedesktop.DBus.Error.InvalidArgs','Invalid profile'); return
            def apply():
                properties[key]=GLib.Variant('s',value); changed(path,target_interface,{key:properties[key]}); record('profile',value=value)
            complete(invocation,'profile',apply)
    elif name in ('CanPowerOff','CanReboot'):
        invocation.return_value(GLib.Variant('(s)',('yes',)))
    elif name=='GetSessionByPID':
        invocation.return_value(GLib.Variant('(o)',('/org/freedesktop/login1/session/test',)))
    elif name=='SetBrightness':
        subsystem,device,value=values
        if subsystem!='backlight' or device!='test_panel' or not (1<=value<=1000) or not (root/device).exists():
            invocation.return_dbus_error('org.freedesktop.DBus.Error.InvalidArgs','Missing device'); return
        def apply():
            (root/device/'brightness').write_text(str(value)+'\n'); record('brightness',value=value)
        complete(invocation,'brightness',apply)
    elif name in ('PowerOff','Reboot'):
        assert values==(False,),values
        complete(invocation,name,lambda:record(name,accepted=True))
    else: invocation.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod',name)

def register(path,interface,properties,methods=''):
    objects[path]=(interface,properties)
    propdefs=''.join(f'<property name="{k}" type="{v.get_type_string()}" access="read"/>' for k,v in properties.items())
    info=Gio.DBusNodeInfo.new_for_xml(f'<node><interface name="{interface}">{methods}{propdefs}</interface></node>')
    bus.register_object(path,info.interfaces[0],method,lambda c,s,p,i,n:properties[n],None)
    info=Gio.DBusNodeInfo.new_for_xml(props_xml)
    bus.register_object(path,info.interfaces[0],method,None,None)

register('/org/freedesktop/UPower','org.freedesktop.UPower',upower)
register('/org/freedesktop/UPower/devices/DisplayDevice','org.freedesktop.UPower.Device',battery)
register(PROFILE_PATH,PROFILE_BUS,profile)
register('/org/freedesktop/login1/session/test','org.freedesktop.login1.Session',session,'<method name="SetBrightness"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="u" direction="in"/></method>')
register('/org/freedesktop/login1','org.freedesktop.login1.Manager',{},''.join(f'<method name="{n}"><arg type="s" direction="out"/></method>' for n in ('CanPowerOff','CanReboot'))+'<method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>'+''.join(f'<method name="{n}"><arg type="b" direction="in"/></method>' for n in ('PowerOff','Reboot')))
for name in ('org.freedesktop.UPower','org.freedesktop.login1',PROFILE_BUS):
    bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',(name,0)),GLib.VariantType.new('(u)'),Gio.DBusCallFlags.NONE,2000,None)

def command(channel,condition):
    global denied,delay
    line=sys.stdin.readline()
    if not line: loop.quit(); return False
    data=json.loads(line)
    if 'deny' in data: denied=data['deny']
    if 'delay' in data: delay=data['delay']
    if 'battery' in data:
        battery['Percentage']=GLib.Variant('d',data['battery']); changed('/org/freedesktop/UPower/devices/DisplayDevice','org.freedesktop.UPower.Device',battery)
    if 'present' in data:
        battery['IsPresent']=GLib.Variant('b',data['present']); changed('/org/freedesktop/UPower/devices/DisplayDevice','org.freedesktop.UPower.Device',battery)
    if 'active' in data:
        session['Active']=GLib.Variant('b',data['active']); changed('/org/freedesktop/login1/session/test','org.freedesktop.login1.Session',session)
    if 'profile' in data:
        profile['ActiveProfile']=GLib.Variant('s',data['profile']); changed(PROFILE_PATH,PROFILE_BUS,profile)
    if 'preparing' in data:
        bus.emit_signal(None,'/org/freedesktop/login1','org.freedesktop.login1.Manager','PrepareForShutdown',GLib.Variant('(b)',(data['preparing'],)))
    print('command='+json.dumps(data,sort_keys=True),flush=True)
    return True
GLib.io_add_watch(sys.stdin,GLib.IO_IN|GLib.IO_HUP,command)
print('event=ready',flush=True)
loop.run()
