#!/usr/bin/env python3
"""Private fingerprint-style protocol/PAM checks. Never claims a real reader."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

from test_greeter_ipc import receive, send

ROOT = Path(__file__).resolve().parents[2]


def protocol_case(greeter, mode):
    with tempfile.TemporaryDirectory(prefix='pearl-fingerprint-ipc-') as tmp:
        server = socket.socket(socket.AF_UNIX)
        server.bind(tmp+'/greetd.sock'); server.listen(); server.settimeout(8)
        errors = []; starts = []; acknowledgements = []
        def daemon():
            try:
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(8)
                    assert receive(conn) == {'type':'create_session', 'username':'fixture-user'}
                    if mode == 'queued_cancel':
                        send(conn, {'type':'auth_message','auth_message_type':'info','auth_message':'Touch the reader'})
                        cancel, _ = server.accept()
                        with cancel:
                            assert receive(cancel) == {'type':'cancel_session'}
                            assert conn.recv(1) == b'', 'cancelled passive message was acknowledged'
                            send(cancel, {'type':'success'})
                        return
                    messages = [('info','Touch the reader'), ('error','Remove and retry'), ('info','指をセンサーに置いてください')]
                    if mode == 'immediate_success': messages = []
                    if mode == 'long_status': messages = [('info','é'*8192)]
                    if mode in ('flood','absolute_deadline'): messages = [('info',f'Scan status {i}') for i in range(129)]
                    for kind, text in messages:
                        if mode == 'absolute_deadline': time.sleep(.12)
                        try:
                            send(conn, {'type':'auth_message','auth_message_type':kind,'auth_message':text})
                            reply = receive(conn)
                        except (EOFError, BrokenPipeError, ConnectionResetError):
                            assert mode in ('flood','absolute_deadline'), mode
                            if mode == 'absolute_deadline':
                                cancel, _ = server.accept()
                                with cancel:
                                    assert receive(cancel) == {'type':'cancel_session'}
                                    send(cancel, {'type':'success'})
                            return
                        assert reply == {'type':'post_auth_message_response','response':None}
                        acknowledgements.append(kind)
                    assert mode not in ('flood','absolute_deadline'), 'conversation escaped its bounds'
                    if mode in ('fallback','additional_factor'):
                        send(conn, {'type':'auth_message','auth_message_type':'secret','auth_message':'Fixture password:'})
                        assert receive(conn) == {'type':'post_auth_message_response','response':'fixture-secret'}
                    if mode == 'additional_factor':
                        send(conn, {'type':'auth_message','auth_message_type':'info','auth_message':'Another factor is required'})
                        assert receive(conn) == {'type':'post_auth_message_response','response':None}
                        send(conn, {'type':'auth_message','auth_message_type':'visible','auth_message':'Fixture factor:'})
                        assert receive(conn) == {'type':'post_auth_message_response','response':'fixture-user'}
                    if mode == 'account_denied':
                        send(conn, {'type':'error','error_type':'auth_error','description':'Denied after scan'})
                        cancel, _ = server.accept()
                        with cancel:
                            assert receive(cancel) == {'type':'cancel_session'}
                            send(cancel, {'type':'success'})
                        return
                    send(conn, {'type':'success'})
                    start = receive(conn); starts.append(start)
                    assert start == {'type':'start_session','cmd':['/usr/lib/pearl/pearl-greeter-session'],'env':['PEARL_SESSION_ID=wayland:fixture.desktop']}
                    send(conn, {'type':'success'})
            except Exception as error: errors.append(error)
        thread = threading.Thread(target=daemon, daemon=True); thread.start()
        env = dict(os.environ, GREETD_SOCK=tmp+'/greetd.sock')
        if mode == 'queued_cancel': env['PEARL_TEST_GREETER_CANCEL'] = '1'
        before = time.monotonic()
        child = subprocess.run([str(greeter), '--probe'], env=env, capture_output=True, timeout=10)
        thread.join(9); server.close()
        assert not thread.is_alive() and not errors, (mode, errors, child.stderr)
        successful = mode not in ('account_denied','flood','absolute_deadline')
        assert (child.returncode == 0) == successful, (mode, child.stderr)
        assert len(starts) == int(successful and mode != 'queued_cancel'), mode
        assert b'fixture-secret' not in child.stdout+child.stderr
        if mode == 'absolute_deadline':
            assert time.monotonic()-before < 2, 'automatic acknowledgements extended the absolute deadline'
            assert len(acknowledgements) < 10
        return {'case':mode,'status':'passed','passive_acknowledgements':len(acknowledgements),'starts':len(starts)}


def pam_conversation(locker, directory, answer=b'fixture-secret', cancel=False):
    """Run the existing non-installed helper with a private pam_start_confdir."""
    proc = subprocess.Popen([str(locker),'--pam'], env=dict(os.environ, PEARL_TEST_PAM_DIR=str(directory)),
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    kinds = []; statuses = []; cancelled = False
    try:
        while True:
            frame = b''
            while len(frame) < 1036:
                assert select.select([proc.stdout],[],[],5)[0], 'PAM fixture stalled'
                chunk = os.read(proc.stdout.fileno(),1036-len(frame))
                assert chunk, 'PAM helper closed without result'
                frame += chunk
            kind, value, length = struct.unpack_from('=III',frame)
            assert length < 1024
            kinds.append(kind)
            if kind == 100:
                proc.wait(timeout=3)
                assert not cancelled
                return value, kinds, statuses
            if kind in (3,4):
                statuses.append(frame[12:12+length].decode())
                if cancel:
                    proc.kill(); proc.wait(timeout=3); cancelled = True
                    return None, kinds, []
            elif kind in (1,2):
                response = b'fixture-user' if kind == 2 else answer
                proc.stdin.write(struct.pack('=III',101,0,len(response))+response.ljust(1024,b'\0')); proc.stdin.flush()
            else: raise AssertionError(kind)
    finally:
        if proc.poll() is None: proc.kill(); proc.wait(timeout=3)
        proc.stdin.close(); proc.stdout.close(); proc.stderr.close()


def pam_cases(locker, module):
    checks = []
    with tempfile.TemporaryDirectory(prefix='pearl-dev-fingerprint-pam-') as tmp:
        directory = Path(tmp)
        for mode, denied, wrong in [('fingerprint',False,False),('fingerprint',True,False),('fingerprint-fallback',False,False),('fingerprint-factor',False,False),('fingerprint-fallback',False,True),('fingerprint-input-status',False,False),('fingerprint-wait',False,False)]:
            (directory/'pearl').write_text(f'auth required {module} {mode}\naccount required {module} policy-{"denied" if denied else "success"}\n')
            result, kinds, _ = pam_conversation(locker,directory,answer=b'wrong-fixture' if wrong else b'fixture-secret',cancel=mode=='fingerprint-wait')
            assert result is None if mode=='fingerprint-wait' else (result == 0) == (not denied and not wrong)
            if mode=='fingerprint': assert 1 not in kinds and 2 not in kinds
            checks.append({'case':mode+('-denied' if denied else '-wrong' if wrong else ''),'status':'passed','message_kinds':kinds})
        # Exercise the example's actual control flow with Linux-PAM. Module results
        # are substituted; real reader, faillock storage and session policy are not certified.
        template=(ROOT/'packaging/greeter/fingerprint/pearl-fingerprint-auth.example').read_text()
        for mode in ('fingerprint','password','both_wrong','missing','busy','maxtries','module_error','precheck_denied','account_denied','extra_factor_denied','homed'):
            traces=[]; lines=[]
            for line in template.splitlines():
                if not line or line.startswith('#'):continue
                match=re.search(r'pam_(\w+)\.so',line);name=match[1]
                label=name
                result='success'
                if name=='faillock':
                    label=line.split()[-1]
                    result='denied' if label=='authfail' or mode=='precheck_denied' and label=='preauth' else 'success'
                elif name=='fprintd': result='success' if mode in ('fingerprint','account_denied','extra_factor_denied','precheck_denied') else {'maxtries':'maxtries','module_error':'error'}.get(mode,'unavailable')
                elif name=='systemd_home':result='success' if mode=='homed' else 'ignore'
                elif name=='unix':result='denied' if mode in ('both_wrong','homed') else 'success'
                replacement=str(directory/'missing.so') if mode=='missing' and name=='fprintd' else str(module)
                lines.append(line[:match.start()]+f'{replacement} policy-{result} {label}')
            (directory/'pearl-fingerprint-auth').write_text('\n'.join(lines)+'\n')
            (directory/'pearl').write_text('auth substack pearl-fingerprint-auth\n'+(f'auth required {module} policy-denied factor\n' if mode=='extra_factor_denied' else '')+f'account required {module} policy-{"denied" if mode=="account_denied" else "success"}\n')
            result, _, traces=pam_conversation(locker,directory)
            assert (result==0)==(mode not in ('both_wrong','precheck_denied','account_denied','extra_factor_denied')), (mode,result,traces)
            if mode=='precheck_denied':assert traces==['preauth'],traces
            if mode=='both_wrong':assert 'authfail' in traces and 'authsucc' not in traces,traces
            if mode in ('fingerprint','account_denied','extra_factor_denied'):assert 'unix' not in traces and 'authfail' not in traces,traces
            checks.append({'case':'policy-'+mode,'status':'passed','module_trace':traces})
    return checks


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('greeter','locker','pam-module'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/fingerprint/latest')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    args.greeter=args.greeter.resolve();args.locker=args.locker.resolve();args.pam_module=args.pam_module.resolve()
    report={'status':'running','evidence':'fake greetd and synthetic modules in real Linux-PAM only','real_device':False,'real_login':False,'binaries':{name:hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ('greeter','locker','pam_module')}}
    try:
        report['protocol']=[protocol_case(args.greeter,mode) for mode in ('passive_success','fallback','additional_factor','immediate_success','long_status','account_denied','queued_cancel','flood','absolute_deadline')]
        report['pam']=pam_cases(args.locker,args.pam_module)
        subprocess.run([sys.executable,str(ROOT/'tests/integration/test_greeter_soak.py'),'--greeter',str(args.greeter),'--passive','--output',str(args.output/'soak.json')],check=True,timeout=90)
        report['status']='passed'
    finally:(args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f"Fingerprint: {len(report['protocol'])} protocol cases, {len(report['pam'])} PAM/policy cases and 1,000 passive/cancel cycles passed. Real devices/login remain gated.")

if __name__=='__main__':main()
