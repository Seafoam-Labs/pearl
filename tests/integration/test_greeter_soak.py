#!/usr/bin/env python3
"""1,000 private auth/cancel cycles; no real passwords or PAM attempts."""
import argparse,json,os
from pathlib import Path
import socket,subprocess,tempfile,threading
from test_greeter_ipc import receive,send
from test_lock import metrics

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--greeter',type=Path,required=True);p.add_argument('--output',type=Path,default=Path('artifacts/greeter/latest/soak.json'));p.add_argument('--passive',action='store_true');args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='pearl-soak-') as tmp:
        server=socket.socket(socket.AF_UNIX);server.bind(tmp+'/greetd.sock');server.listen();server.settimeout(15)
        ready=[threading.Event(),threading.Event()];release=[threading.Event(),threading.Event()];errors=[]
        def daemon():
            try:
                for i in range(1000):
                    conn,_=server.accept()
                    with conn:
                        assert receive(conn)['type']=='create_session'
                        if args.passive:
                            send(conn,{'type':'auth_message','auth_message_type':'info','auth_message':'Touch the reader'})
                            assert receive(conn)=={'type':'post_auth_message_response','response':None}
                        send(conn,{'type':'auth_message','auth_message_type':'secret','auth_message':'Fixture prompt'})
                        cancel,_=server.accept()
                        with cancel:
                            assert receive(cancel)=={'type':'cancel_session'}
                            if i in (9,999):
                                which=0 if i==9 else 1;ready[which].set();assert release[which].wait(5)
                            send(cancel,{'type':'success'})
            except Exception as e:errors.append(e);ready[0].set();ready[1].set()
        thread=threading.Thread(target=daemon,daemon=True);thread.start()
        with open(tmp+'/probe.log','w+') as log:
            proc=subprocess.Popen([str(args.greeter.resolve()),'--probe'],env=dict(os.environ,GREETD_SOCK=tmp+'/greetd.sock',PEARL_TEST_GREETER_CYCLES='1000'),stdout=subprocess.DEVNULL,stderr=log)
            try:
                assert ready[0].wait(15) and not errors,errors
                before=metrics(proc.pid);release[0].set()
                assert ready[1].wait(60) and not errors,errors
                after=metrics(proc.pid);release[1].set();assert proc.wait(timeout=10)==0
                thread.join(5);assert not thread.is_alive() and not errors,errors
                assert after['pss_bytes']-before['pss_bytes']<32*1024*1024
                assert after['fds']<=before['fds']+1
                log.seek(0);assert 'fixture-secret' not in log.read()
                report={'status':'passed','cycles':1000,'passive_ack_each_cycle':args.passive,'evidence':'mock authentication only','before':before,'after':after}
                args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
            finally:
                release[0].set();release[1].set()
                if proc.poll() is None:proc.kill();proc.wait()
                server.close()
if __name__=='__main__':main()
