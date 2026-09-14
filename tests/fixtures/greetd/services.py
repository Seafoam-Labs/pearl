#!/usr/bin/env python3
"""Private AccountsService/logind fixture; no privileged actions."""
import gi
from gi.repository import Gio, GLib
import json, os, sys
from pathlib import Path
address=os.environ['DBUS_SYSTEM_BUS_ADDRESS'];assert address.startswith('unix:path=/tmp/pearl-')
bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
mode=os.environ.get('PEARL_FIXTURE_POWER','yes')
def method(conn,sender,path,interface,name,args,invocation):
    if name=='ListCachedUsers': invocation.return_value(GLib.Variant('(ao)',(['/org/freedesktop/Accounts/User1000','/org/freedesktop/Accounts/User1'],)))
    elif name=='GetAll': invocation.return_value(GLib.Variant('(a{sv})',({'UserName':GLib.Variant('s','fixture-user' if path.endswith('1000') else 'system-user'),'SystemAccount':GLib.Variant('b',not path.endswith('1000'))},)))
    elif name.startswith('Can'): invocation.return_value(GLib.Variant('(s)',(mode,)))
    elif name in ('Reboot','PowerOff'):
        assert args.unpack()==(False,)
        print('fixture-action='+name,flush=True);invocation.return_value(GLib.Variant('()',()))
    else: invocation.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod','Unknown fixture method')
def register(path,xml):
    for interface in Gio.DBusNodeInfo.new_for_xml(xml).interfaces:bus.register_object(path,interface,method,None,None)
register('/org/freedesktop/Accounts','<node><interface name="org.freedesktop.Accounts"><method name="ListCachedUsers"><arg type="ao" direction="out"/></method></interface></node>')
for path in ('/org/freedesktop/Accounts/User1000','/org/freedesktop/Accounts/User1'):
    register(path,'<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method></interface></node>')
register('/org/freedesktop/login1','<node><interface name="org.freedesktop.login1.Manager"><method name="CanReboot"><arg type="s" direction="out"/></method><method name="CanPowerOff"><arg type="s" direction="out"/></method><method name="Reboot"><arg type="b" direction="in"/></method><method name="PowerOff"><arg type="b" direction="in"/></method></interface></node>')
owners=[Gio.bus_own_name_on_connection(bus,name,Gio.BusNameOwnerFlags.NONE,None,None) for name in ('org.freedesktop.Accounts','org.freedesktop.login1')]
GLib.timeout_add(100,lambda:(print('event=ready',flush=True),False)[1]);GLib.MainLoop().run()
