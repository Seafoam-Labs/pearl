#!/usr/bin/env python3
"""Demonstrate Pearl against host NetworkManager/BlueZ in a private Aqueous display.

Default: read-only model verification. --scan temporarily enables Wi-Fi if needed,
requests one Wi-Fi scan and one Bluetooth discovery lease, then restores Wi-Fi.
It never pairs, trusts, disconnects a device, or explicitly activates a network.
NetworkManager may autoconnect an existing saved profile when Wi-Fi is enabled.
"""
import argparse, hashlib, json, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests/integration'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,status,capture,clean
from test_connectivity import state,await_state,action

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl',type=Path,default=ROOT/'zig-out/bin/pearl'); parser.add_argument('--ctl',type=Path,default=ROOT/'zig-out/bin/pearlctl')
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/t08/physical'); parser.add_argument('--scan',action='store_true')
    args=parser.parse_args(); args.pearl=args.pearl.resolve(); args.ctl=args.ctl.resolve(); args.output.mkdir(parents=True,exist_ok=True)
    result={'status':'running','mode':'scan' if args.scan else 'read-only','pearl_sha256':hashlib.sha256(args.pearl.read_bytes()).hexdigest(),'checks':{}}
    try:
        with PrivateSession(args.output/'session') as s:
            pearl=s.child('pearl',[args.pearl],DBUS_SYSTEM_BUS_ADDRESS='unix:path=/run/dbus/system_bus_socket',G_DEBUG='fatal-warnings'); pearl.expect('event=control-ready')
            initial=await_state(s,args.ctl,lambda v:v['network']['available'] and v['bluetooth']['available'] and not v['network']['settings_loading'])
            wifi=[i for i in initial['items'] if i['kind']=='network_device' and i['device_type']==2]
            adapters=[i for i in initial['items'] if i['kind']=='adapter']
            assert wifi and adapters,'Physical Wi-Fi and Bluetooth adapters are required'
            result['checks']['physical-wifi-adapter-enumerated']=True
            result['checks']['physical-bluetooth-adapter-enumerated']=True
            connected=[i['path'] for i in initial['items'] if i['kind']=='bluetooth_device' and i['connected']]
            result['initial']={'wifi_enabled':initial['network']['enabled'],'wifi_hardware_enabled':initial['network']['hardware_enabled'],'wifi_device_states':[i['state'] for i in wifi],'bluetooth_connected_devices':len(connected),'network_agent_registered':initial['network']['registered'],'bluetooth_agent_registered':initial['bluetooth']['registered']}
            output=status(s,args.ctl)['outputs'][0]; ctl(s,args.ctl,'control-center','show','--output',output['id']); time.sleep(.4)
            capture(s,'physical-connectivity',output['connector'])
            try:
                if args.scan:
                    if not initial['network']['enabled']:
                        action(s,args.ctl,'network','enable')
                        await_state(s,args.ctl,lambda v:v['network']['enabled'] and not v['network']['pending'] and any(i['kind']=='network_device' and i['device_type']==2 and i['state']>=30 for i in v['items']))
                    action(s,args.ctl,'network','scan',wifi[0]['path'])
                    live=await_state(s,args.ctl,lambda v:not v['network']['scan_pending'] and any(i['kind']=='access_point' for i in v['items']),timeout=25)
                    result['checks']['physical-wifi-scan-returned-access-points']=True
                    result['access_point_count']=sum(i['kind']=='access_point' for i in live['items'])
                    powered=next(i for i in adapters if i['powered'])
                    action(s,args.ctl,'bluetooth','discover',powered['path']); await_state(s,args.ctl,lambda v:v['bluetooth']['discovering'])
                    time.sleep(2); action(s,args.ctl,'bluetooth','stop_discovery'); await_state(s,args.ctl,lambda v:not v['bluetooth']['discovering'] and not v['bluetooth']['discovery_pending'])
                    result['checks']['physical-bluetooth-discovery-started-and-stopped']=True
            finally:
                current=state(s,args.ctl)
                if args.scan and current['network']['enabled']!=initial['network']['enabled']:
                    action(s,args.ctl,'network','enable' if initial['network']['enabled'] else 'disable')
                    await_state(s,args.ctl,lambda v:v['network']['enabled']==initial['network']['enabled'] and not v['network']['pending'])
                if args.scan: action(s,args.ctl,'bluetooth','stop_discovery')
            final=state(s,args.ctl)
            assert all(any(i['path']==path and i['connected'] for i in final['items']) for path in connected)
            result['checks']['existing-bluetooth-connections-preserved']=True
            result['checks']['original-wifi-radio-state-preserved']=initial['network']['enabled']==final['network']['enabled']
            ctl(s,args.ctl,'quit'); clean(pearl)
            result['status']='passed'
    finally:
        (args.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
