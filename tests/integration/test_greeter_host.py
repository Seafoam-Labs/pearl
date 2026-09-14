#!/usr/bin/env python3
"""Exercise supervisor teardown only; cannot certify compositor restrictions."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--host',type=Path,required=True);args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-host-') as tmp:
        childfile=Path(tmp)/'child'; fixture=Path(tmp)/'fixture.py'
        fixture.write_text('import subprocess,time,sys\np=subprocess.Popen(["/usr/bin/sleep","120"])\nopen(sys.argv[1],"w").write(str(p.pid))\ntime.sleep(120)\n')
        unrelated=subprocess.Popen(['/usr/bin/sleep','120'])
        try:
            host=subprocess.Popen([str(args.host.resolve()),'--fixture','/usr/bin/python3',str(fixture),str(childfile)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            deadline=time.monotonic()+10
            while not childfile.exists() and time.monotonic()<deadline: time.sleep(.02)
            assert childfile.exists()
            descendant=int(childfile.read_text());host.send_signal(signal.SIGTERM)
            _,err=host.communicate(timeout=8)
            assert host.returncode==0 and 'event=greeter-host-reaped' in err,err
            assert not Path(f'/proc/{descendant}').exists()
            assert unrelated.poll() is None
        finally:
            unrelated.terminate();unrelated.wait()
        print('Owned descendants reaped; unrelated process survived. Restricted Aqueous policy remains gated.')


if __name__=='__main__':main()
