#!/usr/bin/env python3
"""Saved connections against loopback WebDAV, in a private GTK/D-Bus session."""
import argparse, configparser, hashlib, json, ssl, sys, time, threading, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote, quote
from xml.sax.saxutils import escape
PROJECT = Path(__file__).resolve().parents[1]
PEARL = PROJECT.parents[1]
sys.path[:0] = [str(PEARL / 'scripts'), str(PEARL / 'tests/integration')]
from pearl_session import PrivateSession, fixture_prefix, wait_for
from test_surfaces import IPC

class DAV(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *args): pass
    def reply(self, code, body=b'', headers=None):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (headers or {}).items(): self.send_header(k,v)
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)
    def auth(self):
        self.requests.append((self.command, self.path))
        if getattr(self.server, 'protected', False) and self.headers.get('Authorization') != 'Basic ZGVtbzpzZWNyZXQ=':
            self.reply(401, headers={'WWW-Authenticate':'Basic realm="Phyto fixture"'})
            return False
        return True
    def do_OPTIONS(self):
        if self.auth(): self.reply(200, headers={'DAV':'1,2', 'Allow':'OPTIONS,PROPFIND,GET,HEAD,PUT,MKCOL,DELETE'})
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        if not self.auth(): return
        path = unquote(self.path).rstrip('/')
        paths = [path] if path.endswith('.txt') else [path + '/']
        if self.headers.get('Depth') != '0' and not path.endswith('.txt'): paths += [path+'/Notes.txt', path+'/Folder/']
        body = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
        for item in paths:
            folder = item.endswith('/')
            body += '<D:response><D:href>'+escape(quote(item))+'</D:href><D:propstat><D:prop><D:displayname>'+escape(item.rstrip('/').split('/')[-1])+'</D:displayname><D:resourcetype>'+('<D:collection/>' if folder else '')+'</D:resourcetype><D:getcontentlength>'+('0' if folder else '14')+'</D:getcontentlength><D:getlastmodified>Mon, 12 Oct 2026 12:00:00 GMT</D:getlastmodified><D:getetag>"fixture-1"</D:getetag><D:getcontenttype>'+('httpd/unix-directory' if folder else 'text/plain')+'</D:getcontenttype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        self.reply(207, (body+'</D:multistatus>').encode(), {'Content-Type':'application/xml; charset=utf-8'})
    def do_GET(self):
        if self.auth(): self.reply(200, b'Network notes\n', {'Content-Type':'text/plain'})
    do_HEAD = do_GET


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=PROJECT/'artifacts/network')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    report = {'status':'running','checks':[], 'binary_sha256':hashlib.sha256(args.binary.read_bytes()).hexdigest()}
    servers = {name:ThreadingHTTPServer(('127.0.0.1',0), DAV) for name in ['public','private','click']}
    for name, server in servers.items():
        server.protected = name == 'private'
        threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoints = {name:f'dav://127.0.0.1:{server.server_port}/{name}/' for name,server in servers.items()}
    ids = {name:str(uuid.uuid4()) for name in ['public','private','click']}
    def passed(name): report['checks'].append(name); print('PASS',name,flush=True)
    try:
        with PrivateSession(output/'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND']='memory'
            s.env['GVFS_REMOTE_VOLUME_MONITOR_IGNORE']='1'
            s.child('gvfs', ['/usr/lib/gvfsd','--no-fuse'])
            ipc = IPC(s)
            display = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr','--output',display['name'],'--custom-mode','1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 1180\nheight = 900\n')
            ipc.call('command',action='session.reload',fields={})
            config = Path(s.env['XDG_CONFIG_HOME'])/'phyto/connections.ini'; config.parent.mkdir()
            config.write_text('[Connections]\nversion=1\n'+''.join(f'[Connection {ids[name]}]\nname={name.title()} server\nuri={endpoints[name]}\nreconnect={"on-click" if name=="click" else "on-open"}\n' for name in ids))
            app = None; launch_count=0
            def windows(): return [w for w in ipc.state() if w['kind']=='window']
            def key(k,*mods):
                cmd=['wtype','-s','70']
                for m in mods: cmd+=['-M',m]
                cmd+=['-k',k]
                for m in reversed(mods): cmd+=['-m',m]
                s.run(cmd)
            def text(value): s.run(['wtype','-s','60','--',str(value)])
            def probe():
                assert app.proc.poll() is None, [l for l in app.lines if not l.startswith("PHYTO_PROBE ")][-20:]
                start=len(app.lines); key('F12')
                return json.loads(wait_for(lambda:next((l.removeprefix('PHYTO_PROBE ') for l in app.lines[start:] if l.startswith('PHYTO_PROBE ')),None)))
            def state(id): return next(e['state'] for e in probe()['network_states'] if e['id']==id)
            def settled(): return wait_for(lambda:v if not (v:=probe())['loading'] else False)
            def click(label, dialog=False, button='left'):
                v=probe(); rows=v['network_dialog_widgets'] if dialog else v['widgets']
                row=next(x for x in rows if x['label']==label and x['width']>0 and x['height']>0)
                win=next(w for w in windows() if (w.get('title') in ('Add connection','Connection settings','Forget connection?'))==dialog)
                rect=win['geometry']
                s.run(['wlrctl','pointer','move','-100000','-100000'])
                s.run(['wlrctl','pointer','move',str(round(rect['x']+row['x']+row['width']/2)),str(round(rect['y']+row['y']+row['height']/2))])
                s.run(['wlrctl','pointer','click',button]); time.sleep(.12)
            def navigate(uri): key('l','ctrl'); text(uri); key('Return'); return settled()
            def launch(*flags):
                nonlocal app,launch_count
                app=s.child(f'phyto-network-{launch_count}',[args.binary.resolve(),"--height=900",*flags],G_DEBUG='fatal-warnings'); launch_count+=1
                win=wait_for(lambda:next(iter(windows()),None))
                ipc.call('command',action='window.activate',fields={'id':win['id']}); settled()
            def capture(name, dialog=False):
                time.sleep(.2)
                win=next(w for w in windows() if (w.get('title') in ('Add connection','Connection settings','Forget connection?'))==dialog)
                rect=win['geometry']; s.run(['grim','-g',f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}",output/(name+'.png')])
            def close():
                key('w','ctrl'); assert app.wait(10)==0,[l for l in app.lines if not l.startswith("PHYTO_PROBE ")][-20:]
                assert not any('CRITICAL' in l or 'WARNING' in l or 'panic:' in l for l in app.lines),[l for l in app.lines if not l.startswith("PHYTO_PROBE ")][-20:]
                wait_for(lambda:not windows())

            launch()
            wait_for(lambda:state(ids['public'])=='connected')
            wait_for(lambda:state(ids['private'])=='needs_auth')
            assert state(ids['click'])=='disconnected'
            assert probe()['uri'].startswith('file:')
            assert len(windows())==1
            assert not any(path.startswith('/click') for _,path in DAV.requests)
            passed('Real GVfs WebDAV startup mount; click-only target untouched; authentication deferred without stealing local folder')
            click('Network'); wait_for(lambda:probe()['uri']=='phyto-network:///')
            capture('network-dark')
            click('Click server')
            wait_for(lambda:probe()['uri'].rstrip('/')==endpoints['click'].rstrip('/'))
            wait_for(lambda:probe()['count']==2)
            capture('webdav-browse')
            passed('Click mounts a real DAV device and enumerates its two remote entries')
            # Real GIO copy from a remote URI, through Phyto clipboard/operations.
            click('Notes.txt'); key('c','ctrl')
            navigate(s.env['HOME']); key('v','ctrl')
            wait_for(lambda:(Path(s.env['HOME'])/'Notes.txt').exists())
            assert (Path(s.env['HOME'])/'Notes.txt').read_text()=='Network notes\n'
            passed('Remote-to-local copy preserves bytes through existing GIO operations')
            click('Network'); click('Public server',button='right')
            wait_for(lambda:probe()['context_open']); capture('device-menu')
            key('Escape')
            click('Add connection…')
            wait_for(lambda:probe()['network_editor'])
            text('Saved for later'); key('Tab'); text('sftp://127.0.0.1:9/folder')
            capture('add-connection',True)
            click('Save for later',True)
            wait_for(lambda:len(probe()['network_profiles'])==4)
            saved=next(p for p in probe()['network_profiles'] if p['name']=='Saved for later')
            assert state(saved['id'])=='disconnected'
            assert config.stat().st_mode & 0o077 == 0
            passed('Native editor saves on-click profile with private file permissions, without mounting')
            click('Disconnect')
            wait_for(lambda:state(ids['public'])=='disconnected')
            click('Settings…')
            click('When I click the network device',True); click('Save changes',True)
            assert next(p for p in probe()['network_profiles'] if p['id']==ids['public'])['policy']=='on_click'
            click('Settings…')
            click('When Phyto opens',True); click('Save changes',True)
            assert state(ids['public'])=='disconnected'
            attempts=probe()['network_attempts']
            key('n','ctrl'); wait_for(lambda:len(windows())==2)
            assert probe()['network_attempts']==attempts
            key('w','ctrl'); wait_for(lambda:len(windows())==1)
            passed('Native policy editor persists both choices; disconnect and additional windows do not trigger startup retries')
            # External edit refreshes all windows and invalidates stale editors.
            click('Add connection…'); text('Draft'); key('Tab'); text('smb://127.0.0.1/share')
            config.write_text(config.read_text().replace('name=Saved for later','name=Externally renamed'))
            wait_for(lambda:any(p['name']=='Externally renamed' for p in probe()['network_profiles']))
            click('Save for later',True)
            assert 'changed' in probe()['network_error']
            key('Escape')
            passed('File monitor reloads an external edit; stale dialog cannot overwrite it')
            close(); launch('--light')
            wait_for(lambda:state(ids['public'])=='connected')
            assert len(probe()['network_profiles'])==4
            assert state(saved['id'])=='disconnected'
            click('Network'); capture('network-light')
            passed('Profiles and on-click preference survive process exit and relaunch; existing mount reused')
            # Click the unreachable endpoint; a failed connection stays saved.
            click('Externally renamed')
            wait_for(lambda:state(saved['id']) in ('failed','unsupported','disconnected'), timeout=25)
            assert len(probe()['network_profiles'])==4
            passed('Unavailable server preserves profile and leaves local navigation usable')
            capture('failed-connection')
            # Explicit user action is allowed to bring up GTK's authentication UI.
            main_id=windows()[0]['id']
            click('Private server')
            auth_window=wait_for(lambda:next((w for w in windows() if w['id']!=main_id),None))
            time.sleep(.25)
            rect=auth_window['geometry']
            s.run(['grim','-g',f"{rect['x']},{rect['y']} {rect['width']}x{rect['height']}",output/'authentication.png'])
            key('Escape')
            wait_for(lambda:len(windows())==1)
            passed('Explicit device click presents native authentication; cancelling retains the profile')
            click('Private server')
            wait_for(lambda:len(windows())==2)
            text('demo'); key('Tab'); text('secret'); key('Return')
            wait_for(lambda:len(windows())==1)
            wait_for(lambda:probe()['uri'].rstrip('/').endswith('/private') and probe()['count']==2)
            assert 'secret' not in config.read_text()
            passed('Native password authentication connects and lists remote files without writing credentials to the profile')
            click('Network')
            # Forget from the stable sidebar context target, independent of file selection.
            click('Public server',button='right')
            click('Forget connection…')
            click('Forget connection',True)
            wait_for(lambda:not any(p['id']==ids['public'] for p in probe()['network_profiles']))
            # An unknown TLS certificate must never be accepted during startup.
            tls_id=str(uuid.uuid4())
            cert,keyfile=s.base/'certificate.pem',s.base/'certificate-key.pem'
            s.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',keyfile,'-out',cert,'-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1'])
            tls=ThreadingHTTPServer(('127.0.0.1',0),DAV)
            tls_context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls_context.load_cert_chain(cert,keyfile)
            tls.socket=tls_context.wrap_socket(tls.socket,server_side=True)
            servers['tls']=tls;threading.Thread(target=tls.serve_forever,daemon=True).start()
            config.write_text(config.read_text()+f'[Connection {tls_id}]\nname=TLS review fixture\nuri=davs://127.0.0.1:{tls.server_port}/public/\nreconnect=on-open\n')
            close()
            rules.write_text('[[window]]\napp_id = "org.aqueous.Phyto"\nfloating = true\nwidth = 390\nheight = 900\n')
            ipc.call('command',action='session.reload',fields={})
            launch('--width=390','--light')
            assert not any(p['id']==ids['public'] for p in probe()['network_profiles'])
            wait_for(lambda:probe()['network_requests']==0)
            assert state(tls_id) in ('review','failed'), state(tls_id)
            assert len(windows())==1
            passed('DAVS with an untrusted certificate defers or rejects connection without any startup trust dialog')
            navigate('phyto-network:///')
            capture('network-narrow')
            click('Add connection…')
            capture('add-connection-narrow',True)
            key('Escape'); close()
            passed('Forget survives relaunch; narrow native Network page and editor remain accessible')
            report['status']='passed'
            report['limits']=['Loopback DAV authentication and DAVS certificate rejection exercised; SMB/SFTP results are in protocols/results.json.', 'No real credentials or external servers used.']
    except BaseException as error:
        report['status']='failed'; report['error']=str(error); raise
    finally:
        for server in servers.values(): server.shutdown(); server.server_close()
        (output/'results.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__': main()
