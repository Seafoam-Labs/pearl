#!/usr/bin/env python3
"""Private real D-Bus protocol clients and controllable MPRIS/SNI/DBusMenu peers."""
from gi.repository import Gio, GLib
import json, os, sys
from pathlib import Path
assert os.environ['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path=/tmp/pearl-dev-')
bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
loop=GLib.MainLoop(); log=Path(os.environ['PEARL_TEST_SESSION_LOG']); conflict='--conflict' in sys.argv
V=GLib.Variant; suffix=os.environ.get('PEARL_TEST_SUFFIX',''); player='org.mpris.MediaPlayer2.PearlFixture'+suffix; tray='org.test.PearlTray'+suffix; mp='/org/mpris/MediaPlayer2'; mi='org.mpris.MediaPlayer2.Player'; si='org.kde.StatusNotifierItem'; wn='org.kde.StatusNotifierWatcher'
np='/org/freedesktop/Notifications'; nn='org.freedesktop.Notifications'; delay=0; deny=False; revision=1; malformed=False
objects={}; registered=[]; note_ids=[]
def record(kind,**kw):
    with log.open('a') as f: f.write(json.dumps(dict(kind=kind,**kw))+'\n')
def call(dest,path,iface,name,args=None,signature=None):
    return bus.call_sync(dest,path,iface,name,args,GLib.VariantType.new(signature) if signature else None,Gio.DBusCallFlags.NO_AUTO_START,3000,None)
def own(name): return call('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',V('(su)',(name,4))).unpack()[0]
def release(name): call('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ReleaseName',V('(s)',(name,)))
def emit(path,iface,name,args): bus.emit_signal(None,path,iface,name,args)
def changed(path,iface): emit(path,'org.freedesktop.DBus.Properties','PropertiesChanged',V('(sa{sv}as)',(iface,objects[(path,iface)],[])))
def metadata(title='Night drive',url=''):
    return V('a{sv}',{'xesam:title':V('s',title),'xesam:artist':V('as',['Pearl Ensemble']),'mpris:trackid':V('o','/track/one'),'mpris:length':V('x',240000000),'mpris:artUrl':V('s',url)})
media={'PlaybackStatus':V('s','Playing'),'Rate':V('d',1),'Position':V('x',30000000),'Metadata':metadata(url=os.environ.get('PEARL_TEST_ART',''))}
for cap in ('CanControl','CanPlay','CanPause','CanGoNext','CanGoPrevious','CanSeek'): media[cap]=V('b',True)
pixels=bytes([255,186,161,240])*32*32
item={'Title':V('s','Pearl fixture'),'Status':V('s','Active'),'IconName':V('s',''),'IconPixmap':V('a(iiay)',[(32,32,pixels)]),'ToolTip':V('(sa(iiay)ss)',('',[],'Fixture tray tooltip','Nested menu test')),'Menu':V('o','/Menu'),'ItemIsMenu':V('b',False)}
def node(id,label,children=(),**props):
    p={'label':V('s',label),'enabled':V('b',True),'visible':V('b',True)};p.update(props)
    return (id,p,[V('(ia{sv}av)',c) for c in children])
def layout():
    children=[node(1,'Open'),node(2,'Playback',[node(3,'Repeat',**{'toggle-type':V('s','checkmark'),'toggle-state':V('i',1)}),node(4,'Advanced',[node(5,'Nested action')],**{'children-display':V('s','submenu')})],**{'children-display':V('s','submenu')}),node(6,'Unavailable',enabled=V('b',False)),node(7,'',type=V('s','separator')),node(8,'Hidden',visible=V('b',False))]
    if malformed: children=[node(i+1,'Overflow') for i in range(130)]
    return node(0,'',children)
def method(c,sender,path,iface,name,args,inv):
    global revision
    values=args.unpack(); record('call',path=path,interface=iface,method=name,args=values)
    if iface=='org.freedesktop.DBus.Properties':
        props=objects.get((path,values[0]),{})
        if name=='GetAll':
            result=V('(a{sv})',(dict(props),))
            if delay and path==mp: GLib.timeout_add(delay,lambda:(inv.return_value(result),False)[1])
            else: inv.return_value(result)
        elif name=='Get': inv.return_value(V('(v)',(props[values[1]],)))
        return
    if iface==mi:
        if deny: inv.return_dbus_error('org.freedesktop.DBus.Error.Failed','Fixture rejected');return
        if name in ('PlayPause','Play','Pause','Stop'):
            media['PlaybackStatus']=V('s',('Paused' if media['PlaybackStatus'].unpack()=='Playing' else 'Playing') if name=='PlayPause' else {'Play':'Playing','Pause':'Paused','Stop':'Stopped'}[name]);changed(mp,mi)
        if name=='SetPosition':
            assert values[0]==media['Metadata'].unpack()['mpris:trackid'];media['Position']=V('x',values[1]);emit(mp,mi,'Seeked',V('(x)',(values[1],)))
        inv.return_value(V('()',()));return
    if iface=='com.canonical.dbusmenu':
        if name=='GetLayout': inv.return_value(V('(u(ia{sv}av))',(revision,layout())))
        elif name=='AboutToShow': inv.return_value(V('(b)',(True,)))
        else: inv.return_value(V('()',()))
        return
    if iface==wn:
        if name=='RegisterStatusNotifierItem':
            reg=sender+values[0] if values[0].startswith('/') else values[0]+'/StatusNotifierItem'
            registered.append(reg);objects[('/StatusNotifierWatcher',wn)]['RegisteredStatusNotifierItems']=V('as',registered);emit('/StatusNotifierWatcher',wn,'StatusNotifierItemRegistered',V('(s)',(reg,)))
        inv.return_value(V('()',()));return
    if iface==nn:
        if name=='GetCapabilities': inv.return_value(V('(as)',(['body'],)))
        elif name=='GetServerInformation': inv.return_value(V('(ssss)',('Existing service','fixture','1','1.2')))
        else: inv.return_dbus_error('org.freedesktop.DBus.Error.NotSupported','Fixture')
        return
    inv.return_value(V('()',()))
props_xml='<node><interface name="org.freedesktop.DBus.Properties"><method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method><method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method><signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal></interface></node>'
paths=set()
def register(path,iface,props,methods=''):
    objects[(path,iface)]=props
    xml=f'<node><interface name="{iface}">{methods}'+''.join(f'<property name="{k}" type="{v.get_type_string()}" access="read"/>' for k,v in props.items())+'</interface></node>'
    info=Gio.DBusNodeInfo.new_for_xml(xml);bus.register_object(path,info.interfaces[0],method,lambda c,s,p,i,k:objects[(p,i)][k],None)
    if path not in paths:
        paths.add(path);info=Gio.DBusNodeInfo.new_for_xml(props_xml);bus.register_object(path,info.interfaces[0],method,None,None)
def meth(name,ins='',outs=''): return '<method name="'+name+'">'+''.join('<arg type="'+t+'" direction="in"/>' for t in ins)+''.join('<arg type="'+t+'" direction="out"/>' for t in outs)+'</method>'
register(mp,mi,media,''.join(meth(n) for n in ('Play','Pause','PlayPause','Stop','Next','Previous'))+meth('SetPosition','ox')+'<signal name="Seeked"><arg type="x"/></signal>')
register(mp,'org.mpris.MediaPlayer2',{'Identity':V('s','Pearl Music')})
register('/StatusNotifierItem',si,item,meth('Activate','ii')+meth('SecondaryActivate','ii')+meth('ContextMenu','ii')+meth('Scroll','is'))
register('/Menu','com.canonical.dbusmenu',{},meth('AboutToShow','i','b')+'<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>'+meth('Event','isvu'))
if conflict:
    registered=[tray+'/StatusNotifierItem']
    register('/StatusNotifierWatcher',wn,{'RegisteredStatusNotifierItems':V('as',registered),'IsStatusNotifierHostRegistered':V('b',False),'ProtocolVersion':V('i',0)},meth('RegisterStatusNotifierHost','s')+meth('RegisterStatusNotifierItem','s'))
    xml=(Path(__file__).resolve().parents[3]/'src/services/notifications.xml').read_text();info=Gio.DBusNodeInfo.new_for_xml(xml);bus.register_object(np,info.interfaces[0],method,None,None)
    assert own(nn)==1;assert own(wn)==1
assert own(player)==1;assert own(tray)==1
bus.signal_subscribe(None,nn,None,np,None,Gio.DBusSignalFlags.NONE,lambda c,s,p,i,n,args:record('notification-signal',signal=n,args=args.unpack()))
def send_notification(data):
    hints={k:V('b',data[k]) for k in ('resident','transient') if k in data}
    if 'urgency' in data: hints['urgency']=V('y',data['urgency'])
    result=call(nn,np,nn,'Notify',V('(susssasa{sv}i)',(data.get('app','Messages'),data.get('replaces',0),'',data.get('summary','Hello from Pearl'),data.get('body','A notification with <b>plain text</b>.'),data.get('actions',['default','Open']),hints,data.get('timeout',0))))
    id=result.unpack()[0];note_ids.append(id);record('notification',id=id);return id
def command(channel,condition):
    global delay,deny,revision,malformed
    line=sys.stdin.readline()
    if not line: loop.quit(); return False
    data=json.loads(line)
    try:
        if data.get('register'): call(wn,'/StatusNotifierWatcher',wn,'RegisterStatusNotifierItem',V('(s)',(tray,)))
        if 'notify' in data: send_notification(data['notify'])
        if 'close' in data: call(nn,np,nn,'CloseNotification',V('(u)',(data['close'],)))
        if 'burst' in data:
            for i in range(data['burst']):
                try: id=send_notification(dict(summary=f'Burst {i}',timeout=0));call(nn,np,nn,'CloseNotification',V('(u)',(id,)))
                except GLib.Error as e: record('error',message=str(e))
        if 'delay' in data: delay=data['delay']
        if 'deny' in data: deny=data['deny']
        if 'title' in data: media['Metadata']=metadata(data['title'],data.get('art',''));changed(mp,mi)
        if 'capability' in data: media[data['capability']]=V('b',data['value']);changed(mp,mi)
        if 'playback' in data: media['PlaybackStatus']=V('s',data['playback']);changed(mp,mi)
        if 'status' in data: item['Status']=V('s',data['status']);changed('/StatusNotifierItem',si)
        if data.get('bad_pixmap'): item['IconPixmap']=V('a(iiay)',[(2147483647,2,b'bad'),(32,32,b'bad')]);changed('/StatusNotifierItem',si)
        if 'menu_overflow' in data:
            malformed=data['menu_overflow'];revision+=1;emit('/Menu','com.canonical.dbusmenu','LayoutUpdated',V('(ui)',(revision,0)))
        if data.get('release_player'): release(player)
        if data.get('own_player'): own(player)
        if data.get('release_tray'): release(tray)
        if data.get('own_tray'): own(tray)
        if data.get('invalidate'): emit(mp,'org.freedesktop.DBus.Properties','PropertiesChanged',V('(sa{sv}as)',(mi,{},['Metadata','CanSeek'])))
    except Exception as e: record('error',message=str(e))
    print('command='+json.dumps(data,sort_keys=True),flush=True);return True
GLib.io_add_watch(sys.stdin,GLib.IO_IN,command)
print('event=ready',flush=True)
loop.run()
