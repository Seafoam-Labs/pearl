#!/usr/bin/env python3
"""Authenticated helper contract using harmless commands as the current test UID."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--greeter',type=Path,required=True);p.add_argument('--launcher',type=Path,required=True);args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-launch-') as tmp:
        root=Path(tmp);sessions=root/'sessions';sessions.mkdir();runtime=root/'runtime';runtime.mkdir(mode=0o700)
        entry=sessions/'other.desktop';entry.write_text('[Desktop Entry]\nType=Application\nName=Other\nExec=/usr/bin/env\nDesktopNames=Other;Example;\n')
        config=root/'config.json';config.write_text(json.dumps({'roots':[{'path':str(sessions),'type':'wayland'}]}))
        env=dict(os.environ,PEARL_TEST_GREETER_CONFIG=str(config))
        catalog=json.loads(subprocess.check_output([str(args.greeter.resolve()),'--catalog'],env=env,text=True));selected=catalog['sessions'][0]
        launch=dict(env,PEARL_SESSION_ID=selected['id'],PEARL_SESSION_FINGERPRINT=selected['fingerprint'],GREETD_SOCK='/tmp/greeter-private.sock',WAYLAND_DISPLAY='greeter-display',AQUEOUS_SOCKET='/tmp/greeter-aqueous.sock',DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/greeter-bus',XDG_RUNTIME_DIR=str(runtime),DISPLAY=':99',XAUTHORITY='/tmp/greeter-authority')
        proc=subprocess.run([str(args.launcher.resolve())],env=launch,capture_output=True,text=True,timeout=10)
        assert proc.returncode==0,proc.stderr
        actual=dict(line.split('=',1) for line in proc.stdout.splitlines() if '=' in line)
        assert actual['XDG_SESSION_TYPE']=='wayland' and actual['XDG_CURRENT_DESKTOP']=='Other:Example'
        assert actual['DESKTOP_SESSION']=='other' and actual['XDG_SESSION_DESKTOP']=='other'
        assert actual['XDG_RUNTIME_DIR']==str(runtime) and actual['HOME']==os.environ['HOME']
        for key in ('GREETD_SOCK','WAYLAND_DISPLAY','AQUEOUS_SOCKET','DBUS_SESSION_BUS_ADDRESS','DISPLAY','XAUTHORITY','PEARL_SESSION_ID','PEARL_SESSION_FINGERPRINT'):assert key not in actual,key
        entry.write_text(entry.read_text()+'Comment=changed\n')
        changed=subprocess.run([str(args.launcher.resolve())],env=launch,capture_output=True,text=True,timeout=10)
        assert changed.returncode!=0 and not changed.stdout
        launch['PEARL_SESSION_ID']='../../bad;command'
        invalid=subprocess.run([str(args.launcher.resolve())],env=launch,capture_output=True,text=True,timeout=10)
        assert invalid.returncode!=0 and not invalid.stdout
        print('Selected non-Pearl identity, PAM runtime preservation, greeter environment removal and changed/malicious selections passed; no real desktop was launched.')


if __name__=='__main__':main()
