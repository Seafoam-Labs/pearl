#!/usr/bin/env python3
"""Private NetworkManager/BlueZ peers. Logs record outcomes, never secret values."""
import argparse, json, os, sys
from pathlib import Path
from gi.repository import Gio, GLib
assert os.environ['DBUS_SYSTEM_BUS_ADDRESS'].startswith('unix:path=/tmp/pearl-dev-')
parser=argparse.ArgumentParser(); parser.add_argument('service',choices=['network','bluetooth']); args=parser.parse_args()
bus=Gio.bus_get_sync(Gio.BusType.SYSTEM,None); loop=GLib.MainLoop()
log=Path(os.environ['PEARL_TEST_CONNECTIVITY_LOG'])
V=GLib.Variant
NM='org.freedesktop.NetworkManager'; NR='/org/freedesktop/NetworkManager'; ND=NR+'/Devices/1'; AP=NR+'/AccessPoint/1'; SP=NR+'/Settings/1'; ACTIVE=NR+'/ActiveConnection/1'
BA='/org/bluez/hci0'; BD=BA+'/dev_00_11_22_33_44_55'
agent=None; delay=150; reject=False; prompt_kind='confirm'; activation_delay=0; attempt=0; pairing=None; saved_retry=False
objects={}; registrations={}; saved={}
def record(kind,**values):
    with log.open('a') as f: f.write(json.dumps(dict(service=args.service,kind=kind,**values))+'\n')
def later(ms,fn):
    def run(): fn(); return False
    GLib.timeout_add(ms,run)
def changed(path,iface,values):
    if path in objects and iface in objects[path]: objects[path][iface].update(values)
    bus.emit_signal(None,path,'org.freedesktop.DBus.Properties','PropertiesChanged',V('(sa{sv}as)',(iface,values,[])))
def method_xml(name,ins='',outs=''):
    # Signature fields are passed as space-separated complete types.
    return f'<method name="{name}">'+''.join(f'<arg type="{t}" direction="{direction}"/>' for direction,s in [('in',ins),('out',outs)] for t in s.split())+'</method>'
propsxml=method_xml('GetAll','s','a{sv}')+method_xml('Get','s s','v')+method_xml('Set','s s v')
def register(path,iface,props,methods=''):
    objects.setdefault(path,{})[iface]=props
    xml=f'<node><interface name="{iface}">{methods}'+''.join(f'<property name="{k}" type="{v.get_type_string()}" access="read"/>' for k,v in props.items())+'</interface></node>'
    info=Gio.DBusNodeInfo.new_for_xml(xml)
    registrations.setdefault(path,[]).append(bus.register_object(path,info.interfaces[0],method,lambda c,s,p,i,n:objects[p][i][n],None))
    if len(registrations[path])==1:
        info=Gio.DBusNodeInfo.new_for_xml('<node><interface name="org.freedesktop.DBus.Properties">'+propsxml+'</interface></node>')
        registrations[path].append(bus.register_object(path,info.interfaces[0],method,None,None))
def invoke_agent(method,params,signature,callback):
    if agent is None: callback(None,'missing-agent'); return
    dest,path,iface=agent
    def done(conn,res):
        try: value=conn.call_finish(res); callback(value,None)
        except GLib.Error as e: callback(None,Gio.DBusError.get_remote_error(e) or 'transport')
    bus.call(dest,path,iface,method,params,GLib.VariantType.new(signature),Gio.DBusCallFlags.NONE,95000,None,done)
def nm_auth(seq,ssid,profile,retry=False):
    if seq!=attempt: return
    settings={'connection':{'id':V('s','Fixture Wi-Fi'),'type':V('s','802-11-wireless')},'802-11-wireless':{'ssid':V('ay',ssid)},'802-11-wireless-security':{'key-mgmt':V('s','sae' if bytes(ssid)==b'Fixture WPA3' else 'wpa-psk'),'psk-flags':V('u',2)}}
    def answered(value,error):
        if seq!=attempt: return
        if error:
            record('secret-cancelled',error=error); changed(ND,NM+'.Device',{'State':V('u',30)}); return
        # Compare in memory; never print reply, input, or a hash of the password.
        secret=value.unpack()[0].get('802-11-wireless-security',{}).get('psk')
        valid=secret=='fixture-wifi-password'
        record('secret-answer',accepted=valid)
        if not valid:
            later(100,lambda:nm_auth(seq,ssid,profile,True)); return
        changed(ND,NM+'.Device',{'State':V('u',100),'ActiveConnection':V('o',ACTIVE)})
        changed(NR,NM,{'Connectivity':V('u',4)})
    invoke_agent('GetSecrets',V('(a{sa{sv}}osasu)',(settings,profile,'802-11-wireless-security',[],3 if retry else 1)),'(a{sa{sv}})',answered)
def method(connection,sender,path,iface,name,params,invocation):
    global agent,attempt,pairing
    values=params.unpack()
    if iface=='org.freedesktop.DBus.ObjectManager':
        invocation.return_value(V('(a{oa{sa{sv}}})',(objects,))); return
    if iface=='org.freedesktop.DBus.Properties':
        target=objects[path][values[0]]
        if name=='GetAll': invocation.return_value(V('(a{sv})',(target,))); return
        if name=='Get': invocation.return_value(V('(v)',(target[values[1]],))); return
        if name=='Set':
            interface,key,value=values
            def apply():
                if reject: invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied','Denied by fixture'); record('property-denied'); return
                changed(path,interface,{key:V('b',value)}); invocation.return_value(V('()',())); record('property',key=key,value=value)
            later(delay,apply); return
    if name in ('RegisterWithCapabilities','RegisterAgent'):
        agent=(sender, NR+'/SecretAgent' if args.service=='network' else values[0], NM+'.SecretAgent' if args.service=='network' else 'org.bluez.Agent1')
        record('agent-registered',destination=sender); invocation.return_value(V('()',())); return
    if name=='GetSettings': invocation.return_value(V('(a{sa{sv}})',(saved[path],))); return
    if name=='RequestScan':
        record('scan'); later(delay,lambda:invocation.return_value(V('()',()))); return
    if name in ('ActivateConnection','AddAndActivateConnection2'):
        attempt+=1; seq=attempt
        if name=='AddAndActivateConnection2':
            settings,device,ap,options=values
            assert options['persist']=='volatile' and settings['connection']['autoconnect'] is False
            if ap!=NR+'/AccessPoint/3': assert settings['802-11-wireless-security']['psk-flags']==2
            record('activate-new',volatile=True,not_saved=True)
            ssid=objects[ap][NM+'.AccessPoint']['Ssid'].unpack(); profile=NR+'/Settings/temporary'
        else:
            profile,device,ap=values; ssid=b'Fixture Secure'; record('activate-saved')
        changed(ND,NM+'.Device',{'State':V('u',40),'ActiveConnection':V('o',ACTIVE)})
        def reply():
            invocation.return_value(V('(ooa{sv})',(profile,ACTIVE,{})) if name=='AddAndActivateConnection2' else V('(o)',(ACTIVE,)))
            if seq==attempt:
                if name=='AddAndActivateConnection2' and ap==NR+'/AccessPoint/3': changed(ND,NM+'.Device',{'State':V('u',100)})
                else: later(80,lambda:nm_auth(seq,ssid,profile))
        later(activation_delay,reply); return
    if args.service=='network' and name in ('Disconnect','DeactivateConnection'):
        attempt+=1
        invoke_agent('CancelGetSecrets',V('(os)',(NR+'/Settings/temporary','802-11-wireless-security')),'()',lambda v,e:None)
        changed(ND,NM+'.Device',{'State':V('u',30),'ActiveConnection':V('o','/')}); invocation.return_value(V('()',())); record('disconnect'); return
    if name in ('StartDiscovery','StopDiscovery'):
        def apply():
            changed(BA,'org.bluez.Adapter1',{'Discovering':V('b',name=='StartDiscovery')}); invocation.return_value(V('()',())); record(name)
        later(delay,apply); return
    if name=='Pair':
        pairing=invocation; record('pair-started')
        def answered(value,error):
            global pairing
            if pairing is None: return
            current=pairing; pairing=None
            valid=error is None and not reject
            if value is not None and prompt_kind=='passkey': valid=value.unpack()[0]==42
            if value is not None and prompt_kind=='pin': valid=value.unpack()[0]=='000042'
            if valid:
                if path in objects: changed(path,'org.bluez.Device1',{'Paired':V('b',True)})
                current.return_value(V('()',())); record('pair-accepted')
            else: current.return_dbus_error('org.bluez.Error.AuthenticationRejected','Rejected'); record('pair-rejected')
        def ask():
            if pairing is None: return
            spec={'confirm':('RequestConfirmation',V('(ou)',(path,42)),'()'), 'passkey':('RequestPasskey',V('(o)',(path,)),'(u)'), 'pin':('RequestPinCode',V('(o)',(path,)),'(s)'), 'authorize':('RequestAuthorization',V('(o)',(path,)),'()'), 'display':('DisplayPasskey',V('(ouq)',(path,42,0)),'()')}
            m,p,sig=spec[prompt_kind]; invoke_agent(m,p,sig,answered)
        later(delay,ask); return
    if name=='CancelPairing':
        current=pairing; pairing=None
        invoke_agent('Cancel',None,'()',lambda v,e:None)
        if current: current.return_dbus_error('org.bluez.Error.AuthenticationCanceled','Cancelled')
        invocation.return_value(V('()',())); record('pair-cancelled'); return
    if args.service=='bluetooth' and name in ('Connect','Disconnect'):
        def apply():
            if path in objects: changed(path,'org.bluez.Device1',{'Connected':V('b',name=='Connect')})
            invocation.return_value(V('()',())); record(name)
        later(delay,apply); return
    invocation.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod','Unknown method')

manager='org.freedesktop.DBus.ObjectManager'
register('/org/freedesktop' if args.service=='network' else '/',manager,{},method_xml('GetManagedObjects','','a{oa{sa{sv}}}'))
if args.service=='network':
    register(NR,NM,{'WirelessEnabled':V('b',True),'WirelessHardwareEnabled':V('b',True),'Connectivity':V('u',1)},method_xml('AddAndActivateConnection2','a{sa{sv}} o o a{sv}','o o a{sv}')+method_xml('ActivateConnection','o o o','o')+method_xml('DeactivateConnection','o'))
    register(NR+'/AgentManager',NM+'.AgentManager',{},method_xml('RegisterWithCapabilities','s u'))
    register(ND,NM+'.Device',{'DeviceType':V('u',2),'Interface':V('s','test_wlan0'),'Managed':V('b',True),'State':V('u',30),'ActiveConnection':V('o','/'),'AvailableConnections':V('ao',[SP])},method_xml('Disconnect'))
    ap_paths=[NR+'/AccessPoint/'+str(i) for i in range(1,5)]
    register(ND,NM+'.Device.Wireless',{'AccessPoints':V('ao',ap_paths),'ActiveAccessPoint':V('o','/')},method_xml('RequestScan','a{sv}'))
    for path,ssid,bits in zip(ap_paths,[b'Fixture Secure',b'Fixture WPA3',b'Guest Wi-Fi',b'Enterprise'],[0x100,0x400,0,0x200]):
        register(path,NM+'.AccessPoint',{'Ssid':V('ay',ssid),'Flags':V('u',int(bits!=0)),'WpaFlags':V('u',0),'RsnFlags':V('u',bits),'Strength':V('y',78)})
    register(SP,NM+'.Settings.Connection',{},method_xml('GetSettings','','a{sa{sv}}'))
    saved[SP]={'connection':{'id':V('s','Saved secure network'),'type':V('s','802-11-wireless')},'802-11-wireless':{'ssid':V('ay',b'Fixture Secure')},'802-11-wireless-security':{'key-mgmt':V('s','wpa-psk')}}
else:
    register('/org/bluez','org.bluez.AgentManager1',{},method_xml('RegisterAgent','o s'))
    register(BA,'org.bluez.Adapter1',{'Alias':V('s','Desktop Bluetooth'),'Powered':V('b',True),'Discovering':V('b',False)},method_xml('StartDiscovery')+method_xml('StopDiscovery'))
    register(BD,'org.bluez.Device1',{'Adapter':V('o',BA),'Alias':V('s','Fixture headphones'),'Address':V('s','00:11:22:33:44:55'),'Paired':V('b',False),'Trusted':V('b',False),'Connected':V('b',False),'Blocked':V('b',False)},''.join(method_xml(x) for x in ('Pair','CancelPairing','Connect','Disconnect')))
name=NM if args.service=='network' else 'org.bluez'
bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',V('(su)',(name,0)),GLib.VariantType.new('(u)'),Gio.DBusCallFlags.NONE,2000,None)
def command(channel,condition):
    global delay,reject,prompt_kind,activation_delay,agent
    line=sys.stdin.readline()
    if not line: loop.quit(); return False
    data=json.loads(line)
    if 'delay' in data: delay=data['delay']
    if 'reject' in data: reject=data['reject']
    if 'prompt' in data: prompt_kind=data['prompt']
    if 'activation_delay' in data: activation_delay=data['activation_delay']
    if 'paired' in data: changed(BD,'org.bluez.Device1',{'Paired':V('b',data['paired'])})
    if 'remove' in data:
        path=data['remove']; removed=objects.pop(path,{})
        bus.emit_signal(None,'/org/freedesktop' if args.service=='network' else '/',manager,'InterfacesRemoved',V('(oas)',(path,list(removed))))
        record('removed')
    if 'owner' in data:
        op='RequestName' if data['owner'] else 'ReleaseName'; sig='(su)' if data['owner'] else '(s)'; val=(name,0) if data['owner'] else (name,)
        bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus',op,V(sig,val),GLib.VariantType.new('(u)'),Gio.DBusCallFlags.NONE,2000,None)
    if 'cancel_agent' in data:
        if args.service=='network': invoke_agent('CancelGetSecrets',V('(os)',(NR+'/Settings/temporary','802-11-wireless-security')),'()',lambda v,e:None)
        else: invoke_agent('Cancel',None,'()',lambda v,e:None)
    if 'saved_label' in data:
        saved[SP]['connection']['id']=V('s',data['saved_label'])
        bus.emit_signal(None,SP,NM+'.Settings.Connection','Updated',None)
    if 'hardware' in data: changed(NR,NM,{'WirelessHardwareEnabled':V('b',data['hardware'])})
    if 'overflow' in data:
        for i in range(data['overflow']): objects[f'/fixture/extra_{i}']={'org.fixture.Empty':{}}
        changed(NR,NM,{'Connectivity':V('u',1)})
    if 'refresh' in data:
        changed(NR,NM,{'Connectivity':V('u',data['refresh'])})
    print('command='+json.dumps(data,sort_keys=True),flush=True); return True
GLib.io_add_watch(sys.stdin,GLib.IO_IN|GLib.IO_HUP,command)
print('event=ready',flush=True); loop.run()
