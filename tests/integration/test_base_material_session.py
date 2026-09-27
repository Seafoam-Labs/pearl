#!/usr/bin/env python3
"""Base Material defaults through real Settings and GTK consumers in nested Aqueous."""
import argparse, json
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, probe, capture, resize, clean, keys
from test_settings_appearance import ready, click
from test_custom_themes import Peer

def settled(peer):
    return wait_for(lambda: (v if not (v:=peer.state())['busy'] and not v['applications']['busy'] else False),30)

def main():
    parser=argparse.ArgumentParser()
    for name in ['pearl','settings']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/base-material-matugen/session-test')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True);checks=[]
    with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND']='memory'
        ipc=IPC(s);output=next(iter(ipc.outputs().values()))
        s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
        resize(s,Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml',1040,850)
        shell=s.child('pearl',[args.pearl.resolve()],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        peer=Peer(s,ipc);settled(peer)
        app=s.child('settings',[args.settings.resolve(),'--page','appearance'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        wait_for(lambda:not probe(s,ipc)['theme_busy'],15)
        config=Path(s.env['XDG_CONFIG_HOME']);gtk=config/'gtk-4.0/gtk.css'
        assert not gtk.exists()
        click(s,ipc,'applications.defaults');ready(s,ipc)
        draft=json.loads(peer.document());assert draft['matugen']['defaults_revision']==1 and draft['matugen']['enabled']
        assert not gtk.exists()
        click(s,ipc,'discard');ready(s,ipc)
        assert json.loads(peer.document())['matugen']['defaults_revision']==0 and not gtk.exists()
        checks.append('defaults-shared-draft-discard-no-external-writes')
        click(s,ipc,'applications.defaults');ready(s,ipc);click(s,ipc,'apply');state=settled(peer);ready(s,ipc)
        assert gtk.exists(),state
        assert all(t['state'] not in ['failed','conflict','unsupported','unavailable'] for t in state['applications']['targets']),state
        capture(s,'material-defaults-dark',output['name'])
        checks.append('defaults-apply-and-visible-target-controls')
        # Named colors are consumed by fresh real GTK3/4 processes, not inferred from files.
        for variant,rgb in [('dark',(20,18,24)),('light',(253,247,255))]:
            if variant=='light':
                p=json.loads(peer.document('committed'));p['theme']['variant']='light';peer.keep(json.dumps(p));assert peer.action('apply')['state']=='succeeded';settled(peer);ready(s,ipc)
            for version in ['3.0','4.0']:
                code=f'''import gi,json
 gi.require_version('Gtk','{version}')
 from gi.repository import Gtk
 Gtk.init()
 w=Gtk.Window()
 context=w.get_style_context()
 found,color=context.lookup_color('window_bg_color')
 assert found
 print(json.dumps([round(color.red*255),round(color.green*255),round(color.blue*255)]))
'''.replace('\n ','\n')
                result=s.run(['python3','-c',code]);assert tuple(json.loads(result.stdout))==rgb,(version,variant,result.stdout)
            capture(s,'material-defaults-'+variant,output['name'])
        checks.append('real-gtk3-gtk4-dark-light-color-consumers')
        committed=json.loads(peer.document('committed'));assert committed['matugen']['defaults_revision']==1
        app.stop();clean(app);peer.close();shell.stop();clean(shell)
        shell=s.child('pearl-restart',[args.pearl.resolve()],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        peer=Peer(s,ipc);state=settled(peer);assert json.loads(peer.document('committed'))['matugen']['defaults_revision']==1
        p=json.loads(peer.document('committed'));p['matugen']['enabled']=False;peer.keep(json.dumps(p));assert peer.action('apply')['state']=='succeeded';settled(peer)
        assert not gtk.exists()
        peer.close();shell.stop();clean(shell);checks.append('restart-persistence-and-off-restoration')
    (args.output/'results.json').write_text(json.dumps({'status':'passed','checks':checks},indent=2)+'\n')
    print('PASS base Material session: '+', '.join(checks))
if __name__=='__main__':main()
