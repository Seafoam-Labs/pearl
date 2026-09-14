#!/usr/bin/env python3
"""Private mock fprintd. No hardware, enrollment storage or polkit authorization."""
import json,os,sys
from pathlib import Path
import gi
gi.require_version('Gio','2.0')
from gi.repository import Gio,GLib

mode=sys.argv[1];output=Path(sys.argv[2])
assert os.environ['DBUS_SYSTEM_BUS_ADDRESS'].startswith('unix:path=/tmp/pearl-dev-')
interface='net.reactivated.Fprint.Device';device='/net/reactivated/Fprint/Device/0'
xml='''<node><interface name="net.reactivated.Fprint.Manager"><method name="GetDevices"><arg type="ao" direction="out"/></method></interface>
<interface name="net.reactivated.Fprint.Device">
<method name="ListEnrolledFingers"><arg type="s" direction="in"/><arg type="as" direction="out"/></method>
<method name="Claim"><arg type="s" direction="in"/></method><method name="Release"/>
<method name="VerifyStart"><arg type="s" direction="in"/></method><method name="VerifyStop"/>
<property name="name" type="s" access="read"/><property name="scan-type" type="s" access="read"/>
<signal name="VerifyFingerSelected"><arg type="s"/></signal><signal name="VerifyStatus"><arg type="s"/><arg type="b"/></signal>
</interface></node>'''
node=Gio.DBusNodeInfo.new_for_xml(xml);bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None)
state={'ready':False,'claimed':False,'claims':0,'starts':0,'stops':0,'releases':0,'disconnect_cleanup':0};owner=None
def save():output.write_text(json.dumps(state))
def result():
    if owner:
        value='verify-no-match' if mode=='no_match' else 'verify-match'
        bus.emit_signal(None,device,interface,'VerifyStatus',GLib.Variant('(sb)',(value,True)))
    return False
def selected():
    if owner:
        bus.emit_signal(None,device,interface,'VerifyFingerSelected',GLib.Variant('(s)',('right-index-finger',)))
        if mode not in ('no_scan','cancel'):GLib.timeout_add(60,result)
    return False
def method(connection,sender,path,iface,name,parameters,invocation):
    global owner
    if name=='GetDevices':invocation.return_value(GLib.Variant('(ao)',([] if mode=='no_device' else [device],)));return
    if name=='ListEnrolledFingers':invocation.return_value(GLib.Variant('(as)',([] if mode=='unenrolled' else ['right-index-finger'],)));return
    if name=='Claim':
        if mode=='busy':invocation.return_dbus_error('net.reactivated.Fprint.Error.AlreadyInUse','Busy fixture');return
        owner=sender;state['claimed']=True;state['claims']+=1
    elif name=='Release':owner=None;state['claimed']=False;state['releases']+=1
    elif name=='VerifyStart':
        assert owner==sender
        state['starts']+=1;GLib.timeout_add(20,selected)
    elif name=='VerifyStop':state['stops']+=1
    else:raise AssertionError(name)
    save();invocation.return_value(GLib.Variant('()',()))
def get_property(*args):return GLib.Variant('s','press' if args[-1]=='scan-type' else 'Private fixture reader')
bus.register_object('/net/reactivated/Fprint/Manager',node.interfaces[0],method,None,None)
bus.register_object(device,node.interfaces[1],method,get_property,None)
def owner_changed(connection,sender,path,iface,name,parameters):
    global owner
    changed,old,new=parameters.unpack()
    if owner==changed and not new:
        owner=None;state['claimed']=False;state['disconnect_cleanup']+=1;save()
bus.signal_subscribe('org.freedesktop.DBus','org.freedesktop.DBus','NameOwnerChanged','/org/freedesktop/DBus',None,Gio.DBusSignalFlags.NONE,owner_changed)
def acquired(*args):state['ready']=True;save()
Gio.bus_own_name_on_connection(bus,'net.reactivated.Fprint',Gio.BusNameOwnerFlags.NONE,acquired,None)
GLib.MainLoop().run()
