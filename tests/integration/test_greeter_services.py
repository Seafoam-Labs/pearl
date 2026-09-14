#!/usr/bin/env python3
"""Verify optional accounts and noninteractive power against a private bus."""
import argparse,json,os
from pathlib import Path
import subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[2]
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--greeter',type=Path,required=True);args=p.parse_args()
    for mode in ('yes','no','challenge'):
        with tempfile.TemporaryDirectory(prefix='pearl-services-') as tmp:
            env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS='unix:path='+tmp+'/bus',PEARL_FIXTURE_POWER=mode)
            bus=subprocess.Popen(['dbus-daemon','--session','--nofork','--address='+env['DBUS_SYSTEM_BUS_ADDRESS']],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            fixture=None
            try:
                for _ in range(100):
                    if Path(tmp+'/bus').exists():break
                    time.sleep(.02)
                fixture=subprocess.Popen(['python3',str(ROOT/'tests/fixtures/greetd/services.py')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                assert fixture.stdout.readline().strip()=='event=ready'
                proc=subprocess.run([str(args.greeter.resolve()),'--services-probe'],env=env,capture_output=True,text=True,timeout=10)
                assert proc.returncode==0,proc.stderr
                assert json.loads(proc.stdout)=={'accounts':1,'requested':mode=='yes'}
                if mode=='yes':assert fixture.stdout.readline().strip()=='fixture-action=Reboot'
            finally:
                if fixture:fixture.terminate();fixture.wait(timeout=5)
                bus.terminate();bus.wait(timeout=5)
    print('Accounts filter and yes/no/challenge power capability passed on private D-Bus; requests were noninteractive.')
if __name__=='__main__':main()
