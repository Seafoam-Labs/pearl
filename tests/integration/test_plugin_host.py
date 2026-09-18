#!/usr/bin/env python3
"""Exercise the real private helper without GTK or a user's desktop."""
import argparse, contextlib, hashlib, json, os, shutil, socket, struct, tempfile, time
from pathlib import Path

def digest(package):
    manifest = (package/'plugin.json').read_bytes()
    fields = [manifest, (package/json.loads(manifest).get('component', 'plugin.wasm')).read_bytes()]
    fields += [(package/asset['path']).read_bytes() for asset in json.loads(manifest).get('assets', [])]
    sha = hashlib.sha256()
    for field in fields: sha.update(struct.pack('<Q', len(field))); sha.update(field)
    return sha.hexdigest()

class Guest:
    def __init__(self, helper, package, approved=None):
        self.socket, child = socket.socketpair(); self.socket.settimeout(8)
        actions = [(os.POSIX_SPAWN_DUP2, child.fileno(), 3)]
        self.log = tempfile.TemporaryFile()
        actions += [(os.POSIX_SPAWN_DUP2, self.log.fileno(), 2)]
        self.pid = os.posix_spawn(str(helper), [str(helper)], dict(PEARL_PLUGIN_PACKAGE=str(package), PEARL_PLUGIN_DIGEST=approved or digest(package), PEARL_PLUGIN_GENERATION='7', PEARL_PLUGIN_ACTIVITY='0'), file_actions=actions)
        child.close(); self.stream = self.socket.makefile('rb'); self.seq = 0
    def call(self, kind, **params):
        self.seq += 1
        self.socket.sendall(json.dumps(dict(version=1, generation=7, sequence=self.seq, event=dict(kind=kind, **params))).encode()+b'\n')
        reply = self.stream.readline()
        if not reply:
            self.log.seek(0); raise AssertionError(self.log.read().decode(errors='replace'))
        result = json.loads(reply)
        assert result['generation'] == 7 and result['sequence'] == self.seq, result
        return result
    def close(self):
        self.stream.close(); self.socket.close()
        deadline = time.monotonic()+8
        while True:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid: self.log.close(); return os.waitstatus_to_exitcode(status)
            if time.monotonic() > deadline:
                os.kill(self.pid, 9); os.waitpid(self.pid, 0); raise AssertionError('Helper did not exit on EOF')
            time.sleep(.02)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--helper',type=Path,required=True);p.add_argument('--examples',type=Path,required=True)
    args=p.parse_args();helper=args.helper.resolve();root=args.examples.resolve();checks=[]
    for name in ('timer-c','counter-zig','counter-rust','companion-c'):
        guest=Guest(helper,root/name)
        try:
            result=guest.call('activate');assert not result.get('error_code'),result
            assert result['scene']['nodes'],result
            result=guest.call('click',node=2 if name in ('timer-c','companion-c') else 1)
            assert not result.get('error_code'),result
            if name=='timer-c':
                assert result['timer_ms']==1000
                assert guest.call('timer')['scene']['nodes'][0]['text']=='0:59'
            elif name=='companion-c':
                assert result['scene']['nodes'][0]['clip']=='tap-left'
                assert guest.call('preview',reduced_motion=True)['scene']['nodes'][0]['clip']=='idle'
            else:
                assert result['scene']['nodes'][0]['text'].endswith('1')
                for i in range(2,202): assert guest.call('click',node=1)['scene']['nodes'][0]['text'].endswith(str(i))
            guest.call('deactivate')
        finally: assert guest.close()==0
        checks.append(name)
    for case in range(1, 7):
        guest=Guest(helper,root/f'fault-{case}')
        started=time.monotonic()
        try:
            result=guest.call('activate')
            if case==6: assert result['scene']['nodes'][0]['text']=='growth rejected', result
            else: assert result.get('error_code') and not result.get('scene'),result
            assert time.monotonic()-started < 5
        finally: assert guest.close()==0
        checks.append(f'fault-{case}')
    with tempfile.TemporaryDirectory(prefix='pearl-package-test-') as temp:
        package=Path(temp)/'package';shutil.copytree(root/'timer-c',package)
        original=digest(package);(package/'plugin.json').write_text((package/'plugin.json').read_text()+' ')
        guest=Guest(helper,package,original)
        try: assert guest.stream.readline()==b''
        finally: assert guest.close()!=0
        checks.append('changed-package-rejected')
        (package/'plugin.wasm').unlink();(package/'plugin.wasm').symlink_to(root/'timer-c/plugin.wasm')
        guest=Guest(helper,package,original)
        try: assert guest.stream.readline()==b''
        finally: assert guest.close()!=0
        checks.append('symlink-rejected')
    guest=Guest(helper,root/'unknown-import')
    try: assert guest.stream.readline()==b''
    finally: assert guest.close()!=0
    checks.append('unapproved-import-rejected')
    guest=Guest(helper,root/'timer-c')
    guest.socket.sendall(b'{"version":1,"generation":8,"sequence":1,"event":{"kind":"activate"}}\n')
    try: assert guest.stream.readline()==b''
    finally: assert guest.close()!=0
    checks.append('stale-generation-rejected')
    print(json.dumps(dict(status='passed', checks=checks), indent=2))
if __name__=='__main__':main()
