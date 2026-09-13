#!/usr/bin/env python3
"""T08 private NetworkManager and BlueZ conversations on Aqueous with real GTK input."""
import argparse, hashlib, json, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,status,capture,clean
from test_services import command
from t00 import Session as T00Session
FIX=ROOT/'tests/fixtures/services/connectivity.py'
NR='/org/freedesktop/NetworkManager'; ND=NR+'/Devices/1'; AP=NR+'/AccessPoint/1'; SP=NR+'/Settings/1'
BA='/org/bluez/hci0'; BD=BA+'/dev_00_11_22_33_44_55'
def state(s,binary):
    result=ctl(s,binary,'connectivity','status')['result']; page=result['next_offset']
    while page is not None:
        more=ctl(s,binary,'connectivity','status','--offset',str(page))['result']
        result['items'].extend(more['items']); page=more['next_offset']
    return result
def await_state(s,binary,predicate,timeout=15):
    return wait_for(lambda:(lambda v:v if predicate(v) else False)(state(s,binary)),timeout)
def action(s,binary,service,name,path=None,code=0,generation=None):
    generation=state(s,binary)[service]['generation'] if generation is None else generation
    return ctl(s,binary,'connectivity','action','--service',service,'--action',name,'--generation',str(generation),*(['--path',path] if path else []),code=code)
def focus(child):
    return next((line.rsplit('=',1)[-1] for line in reversed(child.lines) if 'event=connectivity-focus target=' in line),'')
def key(s,*args): s.run(['wtype','-s','100',*args,'-s','250'])
def answer_wifi(s,pearl,password):
    wait_for(lambda:focus(pearl)=='wifi-password'); key(s,password,'-k','Return')
def records(s): return [json.loads(line) for line in Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).read_text().splitlines()]
def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--pearl',type=Path,required=True); parser.add_argument('--ctl',type=Path,required=True); parser.add_argument('--output',type=Path,default=ROOT/'artifacts/t08/latest'); args=parser.parse_args()
    args.pearl=args.pearl.resolve(); args.ctl=args.ctl.resolve(); args.output=args.output.resolve(); args.output.mkdir(parents=True,exist_ok=True)
    checks={}; result={'status':'running','checks':checks,'pearl_sha256':hashlib.sha256(args.pearl.read_bytes()).hexdigest(),'ctl_sha256':hashlib.sha256(args.ctl.read_bytes()).hexdigest()}
    try:
        with PrivateSession(args.output/'connectivity') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
            system=s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            s.env['PEARL_TEST_CONNECTIVITY_LOG']=str(s.output/'actions.jsonl'); Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).write_text('')
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous'); keyboard=T00Session.input_fixture(s)
            network=s.child('network',['python3',FIX,'network'],input_pipe=True); network.expect('event=ready')
            bluetooth=s.child('bluetooth',['python3',FIX,'bluetooth'],input_pipe=True); bluetooth.expect('event=ready')
            pearl=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings'); pearl.expect('event=control-ready')
            initial=await_state(s,args.ctl,lambda v:v['network']['registered'] and v['bluetooth']['registered'] and v['count']==8 and not v['network']['settings_loading'])
            checks['object-manager-enumeration-and-agent-registration']=True
            for service,agent_path,method in [('network',NR+'/SecretAgent',NR.replace('/org/freedesktop/','org.freedesktop.')+'.SecretAgent.CancelGetSecrets'),('bluetooth','/org/aqueous/Pearl/BluetoothAgent','org.bluez.Agent1.Cancel')]:
                destination=next(x['destination'] for x in reversed(records(s)) if x['kind']=='agent-registered' and x['service']==service)
                denied=s.run(['gdbus','call','--system','--dest',destination,'--object-path',agent_path,'--method',method,*([NR+'/Settings/temporary','802-11-wireless-security'] if service=='network' else [])],check=False)
                assert denied.returncode!=0 and 'AccessDenied' in denied.stderr,denied
            checks['agent-calls-reject-unrelated-bus-senders']=True
            output=status(s,args.ctl)['outputs'][0]
            def show(): ctl(s,args.ctl,'control-center','show','--output',output['id']); time.sleep(.3)
            show(); capture(s,'control-center-connectivity',output['connector'])
            for _ in range(12):
                if focus(pearl)=='net-expander': break
                key(s,'-k','Tab')
            assert focus(pearl)=='net-expander'
            key(s,'-k','space'); time.sleep(.3); capture(s,'nearby-and-saved-networks',output['connector'])
            ctl(s,args.ctl,'popup','hide'); show()
            for _ in range(12):
                if focus(pearl)=='bt-expander': break
                key(s,'-k','Tab')
            assert focus(pearl)=='bt-expander'
            key(s,'-k','space'); time.sleep(.3); capture(s,'bluetooth-device-list',output['connector'])
            ctl(s,args.ctl,'popup','hide'); show()
            checks['keyboard-traversal-collapsed-and-expanded-connectivity-lists']=True
            action(s,args.ctl,'network','scan',ND); await_state(s,args.ctl,lambda v:not v['network']['scan_pending'])
            action(s,args.ctl,'network','scan',ND,code=4)
            assert sum(x['kind']=='scan' for x in records(s))==1
            checks['bounded-explicit-wifi-scan']=True
            command(network,saved_label='Updated saved network')
            await_state(s,args.ctl,lambda v:any(i['kind']=='saved' and i['label']=='Updated saved network' for i in v['items']))
            checks['saved-profile-updated-signal-refreshes-settings']=True
            action(s,args.ctl,'network','connect',AP)
            await_state(s,args.ctl,lambda v:v['network']['prompt']); answer_wifi(s,pearl,'wrong-password')
            await_state(s,args.ctl,lambda v:v['network']['prompt'] and v['network']['err'] is not None)
            capture(s,'wifi-rejected-credentials',output['connector'])
            wait_for(lambda:focus(pearl)=='wifi-password'); key(s,'fixture-')
            command(network,refresh=3); await_state(s,args.ctl,lambda v:v['network']['connectivity']==3)
            key(s,'wifi-password','-k','Return')
            await_state(s,args.ctl,lambda v:not v['network']['pending'] and any(i['kind']=='network_device' and i['connected'] for i in v['items']))
            assert any(x['kind']=='secret-answer' and not x['accepted'] for x in records(s))
            assert any(x['kind']=='secret-answer' and x['accepted'] for x in records(s))
            checks['secure-wifi-real-password-entry-rejection-and-retry']=True
            checks['unrelated-property-update-preserves-typed-password']=True
            action(s,args.ctl,'network','disconnect',ND); await_state(s,args.ctl,lambda v:not v['network']['pending'])
            action(s,args.ctl,'network','connect_saved',SP); await_state(s,args.ctl,lambda v:v['network']['prompt'])
            answer_wifi(s,pearl,'fixture-wifi-password'); await_state(s,args.ctl,lambda v:not v['network']['pending'])
            checks['saved-network-secret-agent-and-activation']=True
            action(s,args.ctl,'network','disconnect',ND); await_state(s,args.ctl,lambda v:not v['network']['pending'])
            action(s,args.ctl,'network','connect',NR+'/AccessPoint/2'); await_state(s,args.ctl,lambda v:v['network']['prompt'])
            answer_wifi(s,pearl,'fixture-wifi-password'); await_state(s,args.ctl,lambda v:not v['network']['pending'])
            checks['wpa3-sae-secret-agent']=True
            action(s,args.ctl,'network','disconnect',ND); await_state(s,args.ctl,lambda v:not v['network']['pending'])
            action(s,args.ctl,'network','connect',AP); await_state(s,args.ctl,lambda v:v['network']['prompt'])
            ctl(s,args.ctl,'popup','hide'); await_state(s,args.ctl,lambda v:not v['network']['pending'] and not v['network']['prompt'])
            show(); checks['panel-close-cancels-wifi-and-clears-secret-entry']=True
            command(network,activation_delay=600)
            action(s,args.ctl,'network','connect',AP)
            await_state(s,args.ctl,lambda v:v['network']['activation_waiting'])
            action(s,args.ctl,'network','cancel'); await_state(s,args.ctl,lambda v:not v['network']['pending'])
            assert not state(s,args.ctl)['network']['prompt']
            checks['late-activation-after-cancel-is-deactivated']=True
            command(network,activation_delay=0)
            command(network,hardware=False)
            await_state(s,args.ctl,lambda v:not v['network']['hardware_enabled'])
            action(s,args.ctl,'network','enable',code=4)
            command(network,hardware=True); await_state(s,args.ctl,lambda v:v['network']['hardware_enabled'])
            checks['hardware-radio-block-prevents-writes']=True
            action(s,args.ctl,'network','connect',NR+'/AccessPoint/4',code=4)
            assert 'editor' in state(s,args.ctl)['network']['err']; checks['enterprise-handoff']=True
            action(s,args.ctl,'bluetooth','discover',BA)
            await_state(s,args.ctl,lambda v:v['bluetooth']['discovering']); action(s,args.ctl,'bluetooth','stop_discovery')
            await_state(s,args.ctl,lambda v:not v['bluetooth']['discovery_pending'] and not v['bluetooth']['discovering'])
            checks['bluetooth-discovery-lease']=True
            started=time.monotonic(); action(s,args.ctl,'bluetooth','discover',BA)
            await_state(s,args.ctl,lambda v:v['bluetooth']['discovering'])
            await_state(s,args.ctl,lambda v:not v['bluetooth']['discovering'] and not v['bluetooth']['discovery_pending'],timeout=35)
            assert 29<=time.monotonic()-started<35
            checks['bluetooth-discovery-automatically-expires-after-30-seconds']=True
            command(bluetooth,delay=600)
            action(s,args.ctl,'bluetooth','discover',BA)
            ctl(s,args.ctl,'popup','hide')
            await_state(s,args.ctl,lambda v:not v['bluetooth']['discovery_pending'] and not v['bluetooth']['discovering'])
            assert sum(x['kind']=='StopDiscovery' for x in records(s))==3
            show(); command(bluetooth,delay=150)
            checks['late-discovery-start-after-panel-close-releases-lease']=True
            action(s,args.ctl,'bluetooth','pair',BD)
            await_state(s,args.ctl,lambda v:v['bluetooth']['prompt']=='confirm'); wait_for(lambda:focus(pearl)=='bluetooth-confirm')
            time.sleep(.4); capture(s,'bluetooth-passkey-confirmation',output['connector']); key(s,'-k','space')
            await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'] and any(i['kind']=='bluetooth_device' and i['paired'] for i in v['items']))
            action(s,args.ctl,'bluetooth','trust',BD); await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'])
            action(s,args.ctl,'bluetooth','connect',BD); await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'] and any(i['kind']=='bluetooth_device' and i['connected'] and i['trusted'] for i in v['items']))
            checks['passkey-confirmation-explicit-trust-and-connect']=True
            action(s,args.ctl,'bluetooth','disconnect',BD); await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'])
            command(bluetooth,paired=False)
            await_state(s,args.ctl,lambda v:any(i['kind']=='bluetooth_device' and not i['paired'] for i in v['items']))
            action(s,args.ctl,'bluetooth','pair',BD); await_state(s,args.ctl,lambda v:v['bluetooth']['prompt']=='confirm')
            action(s,args.ctl,'bluetooth','cancel'); await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'] and v['bluetooth']['prompt']=='none')
            checks['bluetooth-pair-cancellation']=True
            for kind in ('pin','passkey'):
                command(bluetooth,prompt=kind,paired=False)
                await_state(s,args.ctl,lambda v:any(i['kind']=='bluetooth_device' and not i['paired'] for i in v['items']))
                action(s,args.ctl,'bluetooth','pair',BD); await_state(s,args.ctl,lambda v:v['bluetooth']['prompt']==kind)
                wait_for(lambda:focus(pearl)=='bluetooth-input'); key(s,'000042','-k','Return')
                await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'] and any(i['kind']=='bluetooth_device' and i['paired'] for i in v['items']))
            checks['bluetooth-pin-and-passkey-input']=True
            command(bluetooth,prompt='confirm',paired=False,reject=True)
            await_state(s,args.ctl,lambda v:any(i['kind']=='bluetooth_device' and not i['paired'] for i in v['items']))
            action(s,args.ctl,'bluetooth','pair',BD); await_state(s,args.ctl,lambda v:v['bluetooth']['prompt']=='confirm')
            wait_for(lambda:focus(pearl)=='bluetooth-confirm'); key(s,'-k','space')
            await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'] and v['bluetooth']['err'] is not None)
            checks['bluetooth-authentication-rejected']=True
            command(bluetooth,reject=False)
            action(s,args.ctl,'bluetooth','pair',BD); await_state(s,args.ctl,lambda v:v['bluetooth']['prompt']=='confirm')
            command(bluetooth,remove=BD); await_state(s,args.ctl,lambda v:not v['bluetooth']['pending'] and v['bluetooth']['prompt']=='none' and not any(i['kind']=='bluetooth_device' for i in v['items']))
            checks['removed-device-cancels-conversation']=True
            old=state(s,args.ctl)['network']['generation']
            action(s,args.ctl,'network','connect',AP); await_state(s,args.ctl,lambda v:v['network']['prompt'])
            command(network,owner=False); await_state(s,args.ctl,lambda v:not v['network']['available'] and not v['network']['prompt'])
            command(network,owner=True); await_state(s,args.ctl,lambda v:v['network']['available'] and v['network']['registered'])
            action(s,args.ctl,'network','connect',AP,generation=old,code=4)
            checks['network-owner-replacement-drops-prompts-and-stale-actions']=True
            old=state(s,args.ctl)['bluetooth']['generation']
            command(bluetooth,owner=False); await_state(s,args.ctl,lambda v:not v['bluetooth']['available'])
            command(bluetooth,owner=True); await_state(s,args.ctl,lambda v:v['bluetooth']['available'] and v['bluetooth']['registered'])
            action(s,args.ctl,'bluetooth','discover',BA,generation=old,code=4)
            checks['bluez-owner-replacement-registers-new-agent']=True
            command(network,overflow=520)
            await_state(s,args.ctl,lambda v:not v['network']['available'])
            assert 'limit' in state(s,args.ctl)['network']['err']
            checks['oversized-object-snapshot-fails-closed']=True
            system.stop()
            await_state(s,args.ctl,lambda v:not v['network']['available'] and not v['bluetooth']['available'])
            system=s.child('system-bus-restarted',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
            network=s.child('network-restarted',['python3',FIX,'network'],input_pipe=True); network.expect('event=ready')
            bluetooth=s.child('bluetooth-restarted',['python3',FIX,'bluetooth'],input_pipe=True); bluetooth.expect('event=ready')
            await_state(s,args.ctl,lambda v:v['network']['available'] and v['bluetooth']['available'] and v['network']['registered'] and v['bluetooth']['registered'],timeout=20)
            checks['system-bus-reconnect-recreates-agents-and-state']=True
            (s.output/'final-state.json').write_text(json.dumps(state(s,args.ctl),indent=2)+'\n')
            action(s,args.ctl,'network','connect',AP); await_state(s,args.ctl,lambda v:v['network']['prompt'])
            command(bluetooth,delay=2000); action(s,args.ctl,'bluetooth','discover',BA)
            ctl(s,args.ctl,'quit'); clean(pearl)
            checks['shutdown-drains-pending-agent-and-discovery-callbacks']=True
            for path in (s.base/'config').rglob('*'):
                if path.is_file(): assert b'fixture-wifi-password' not in path.read_bytes(),path
            for path in s.output.rglob('*'):
                if path.is_file() and path.suffix in ('.log','.json','.jsonl'):
                    data=path.read_bytes(); assert b'fixture-wifi-password' not in data and b'wrong-password' not in data and b'000042' not in data,path
            checks['secrets-excluded-from-status-logs-and-persistent-shell-config']=True
        result['status']='passed'
    finally:
        (args.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
