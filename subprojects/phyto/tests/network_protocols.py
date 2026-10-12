#!/usr/bin/env python3
"""Optional real SMB/SFTP qualification with disposable rootless server fixtures.

Requires bwrap, rootlesskit, OpenSSH and a Linux root tree containing smbd.
No downloads, host accounts, host SSH configuration, or system services change.
"""
import argparse, hashlib, json, os, pwd, shlex, socket, sys, time, uuid
from pathlib import Path
PROJECT=Path(__file__).resolve().parents[1]
PEARL=PROJECT.parents[1]
sys.path[:0]=[str(PEARL/'scripts'),str(PEARL/'tests/integration')]
from pearl_session import PrivateSession,fixture_prefix,wait_for
from test_surfaces import IPC

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--server-root',type=Path,required=True)
    p.add_argument('--rootlesskit',type=Path,default=PEARL/'.cache/phyto-container/tools/usr/bin/rootlesskit')
    p.add_argument('--output',type=Path,default=PROJECT/'artifacts/network/protocols')
    args=p.parse_args(); output=args.output.resolve(); output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','checks':[], 'binary_sha256':hashlib.sha256(args.binary.read_bytes()).hexdigest()}
    try:
        with PrivateSession(output/'session',tool_prefix=fixture_prefix()) as s:
            fixture=s.base/'servers'; fixture.mkdir()
            share=fixture/'share'; share.mkdir(); (share/'Notes.txt').write_text('Protocol fixture\n'); (share/'Folder').mkdir()
            sshport,smbport=port(),port()
            s.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',fixture/'hostkey'])
            s.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',fixture/'client'])
            # Only this container's synthetic root account is unlocked. SSH permits keys only.
            (fixture/'shadow').write_text('root::20000:0:99999:7:::\n')
            (fixture/'sshd.conf').write_text(f'''Port {sshport}
ListenAddress 127.0.0.1
HostKey /tmp/fixture/hostkey
PidFile /tmp/fixture/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
StrictModes no
AuthorizedKeysFile /tmp/fixture/client.pub
Subsystem sftp internal-sftp
''')
            for directory in ('lock','state','private','cache','pid'): (fixture/directory).mkdir()
            (fixture/'smb.conf').write_text(f'''[global]
server role = standalone server
interfaces = 127.0.0.1
bind interfaces only = yes
smb ports = {smbport}
map to guest = Bad User
guest account = root
security = user
load printers = no
printing = bsd
disable spoolss = yes
lock directory = /tmp/fixture/lock
state directory = /tmp/fixture/state
private dir = /tmp/fixture/private
cache directory = /tmp/fixture/cache
pid directory = /tmp/fixture/pid
log file = /tmp/fixture/smb.log
[fixture]
path = /tmp/fixture/share
read only = no
guest ok = yes
guest only = yes
force user = root
''')
            base=[str(args.rootlesskit.resolve()),'--net=host','--state-dir',str(fixture/'rootlesskit'),'bwrap','--die-with-parent','--uid','0','--gid','0','--ro-bind',args.server_root.resolve(),'/','--proc','/proc','--dev','/dev','--tmpfs','/run','--dir','/run/samba','--tmpfs','/tmp','--bind',fixture,'/tmp/fixture','--ro-bind',fixture/'shadow','/etc/shadow','--chdir','/tmp/fixture']
            account=pwd.getpwuid(os.getuid()).pw_name
            # OpenSSH also supports a non-root daemon serving only its own uid.
            ssh_config=(fixture/'sshd.conf').read_text().replace('/tmp/fixture',str(fixture)).replace('PermitRootLogin yes','PermitRootLogin no')
            (fixture/'sshd.conf').write_text(ssh_config+'AllowUsers '+account+'\n')
            ssh=s.child('sshd',['/usr/bin/sshd','-D','-e','-f',fixture/'sshd.conf'])
            smb=s.child('smbd',base+['/usr/bin/smbd','--foreground','--no-process-group','--debug-stdout','--configfile=/tmp/fixture/smb.conf'])
            def ready(child,number):
                if child.proc.poll() is not None: raise AssertionError(child.lines[-10:])
                try:
                    with socket.create_connection(('127.0.0.1',number),timeout=.2): return True
                except OSError: return False
            wait_for(lambda:ready(ssh,sshport)); wait_for(lambda:ready(smb,smbport))
            # GVfs locates ssh on PATH. Its wrapper pins keys and known-hosts to this fixture.
            wrapper=s.base/'bin'; wrapper.mkdir()
            hostkey=(fixture/'hostkey.pub').read_text().split()
            known=fixture/'known_hosts'; known.write_text(f'[127.0.0.1]:{sshport} {hostkey[0]} {hostkey[1]}\n')
            client_config=fixture/'ssh_config'
            client_config.write_text(f'Host *\n  IdentityFile {fixture}/client\n  UserKnownHostsFile {known}\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes\n  IdentitiesOnly yes\n  PasswordAuthentication no\n')
            (wrapper/'ssh').write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(client_config))+' "$@"\n'); (wrapper/'ssh').chmod(0o700)
            s.env['PATH']=str(wrapper)+':'+s.env['PATH']; s.env['GSETTINGS_BACKEND']='memory'; s.env['GVFS_REMOTE_VOLUME_MONITOR_IGNORE']='1'
            s.child('gvfs',['/usr/lib/gvfsd','--no-fuse'])
            endpoints={'sftp':f'sftp://{account}@127.0.0.1:{sshport}{share}','smb':f'smb://127.0.0.1:{smbport}/fixture'}
            config=Path(s.env['XDG_CONFIG_HOME'])/'phyto/connections.ini';config.parent.mkdir()
            config.write_text('[Connections]\nversion=1\n'+''.join(f'[Connection {uuid.uuid4()}]\nname={name.upper()} fixture\nuri={uri}\nreconnect=on-open\n' for name,uri in endpoints.items()))
            ipc=IPC(s)
            rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml';rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 900\n');ipc.call('command',action='session.reload',fields={})
            app=s.child('phyto',[args.binary.resolve(),'--height=900'],G_DEBUG='fatal-warnings')
            def windows(): return [w for w in ipc.state() if w['kind']=='window']
            win=wait_for(lambda:next(iter(windows()),None));ipc.call('command',action='window.activate',fields={'id':win['id']})
            def key(k,*mods):
                cmd=['wtype','-s','60']
                for m in mods:cmd+=['-M',m]
                cmd+=['-k',k]
                for m in reversed(mods):cmd+=['-m',m]
                s.run(cmd)
            def probe():
                assert app.proc.poll() is None,[l for l in app.lines if not l.startswith('PHYTO_PROBE')][-10:]
                start=len(app.lines);key('F12')
                return json.loads(wait_for(lambda:next((l[12:] for l in app.lines[start:] if l.startswith('PHYTO_PROBE ')),None)))
            wait_for(lambda:probe()['network_requests']==0,timeout=30)
            value=probe();report['states']=value['network_states']
            assert all(e['state']=='connected' for e in value['network_states']),report['states']
            assert value['uri'].startswith('file:')
            report['checks'].append('Real SMB guest and SFTP public-key startup mounts, with pinned temporary SSH host key')
            for name,uri in endpoints.items():
                key('l','ctrl');s.run(['wtype','-s','100','--',uri]);key('Return')
                wait_for(lambda:probe()['count']==2 and not probe()['loading'])
                rect=windows()[0]['geometry'];s.run(['grim','-g',f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}",output/(name+'.png')])
                assert s.run(['gio','cat',uri+'/Notes.txt']).stdout=='Protocol fixture\n'
                report['checks'].append(f'{name.upper()} native enumeration and GIO read preserve fixture bytes')
            key('w','ctrl');assert app.wait(10)==0
            assert not any('CRITICAL' in l or 'WARNING' in l for l in app.lines)
            report['status']='passed'
    except BaseException as e:
        report['status']='failed';report['error']=str(e);raise
    finally:
        (output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))

if __name__=='__main__':main()
