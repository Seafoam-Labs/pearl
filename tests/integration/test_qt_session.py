#!/usr/bin/env python3
"""Qt integration through the real shared draft, Settings UI and Aqueous session."""
import argparse
import json
import shutil
import time
from pathlib import Path
from PIL import Image
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, ctl, capture, clean, probe
from test_settings_appearance import ready, click, settled
from settings_editor import EditorPeer

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pearl', 'settings', 'ctl'): p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--libraries', type=Path)
    p.add_argument('--engine-prefix', type=Path)
    p.add_argument('--aqueous-source', type=Path, default=ROOT.parent/'RiderProjects/Aqueous')
    p.add_argument('--output', type=Path, default=ROOT/'artifacts/qtengine/session')
    args = p.parse_args()
    args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    checks = []
    with PrivateSession(args.output/'desktop', tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        if args.libraries: s.env['LD_LIBRARY_PATH'] = str(args.libraries.resolve())
        if args.engine_prefix:
            prefix=args.engine_prefix.resolve()
            s.env['QT_PLUGIN_PATH']=':'.join(str(prefix/f'lib/{q}/plugins') for q in ('qt','qt6'))
            s.env['LD_LIBRARY_PATH']=str(prefix/'lib')+(':'+s.env['LD_LIBRARY_PATH'] if s.env.get('LD_LIBRARY_PATH') else '')
        s.env['QT_QPA_PLATFORMTHEME'] = 'qtengine'
        s.env['GSETTINGS_BACKEND'] = 'memory'
        from types import SimpleNamespace
        from t00 import Session as T00Session
        s.args=SimpleNamespace(aqueous_source=str(args.aqueous_source)); T00Session.input_fixture(s)
        binaries=s.base/'binaries'; binaries.mkdir()
        shutil.copy2(args.pearl, binaries/'pearl')
        for version in (5,6): shutil.copy2(ROOT/f'zig-out/bin/pearl-qt{version}-probe', binaries)
        shell=s.child('pearl',[binaries/'pearl'],G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
        ipc=IPC(s)
        peer=EditorPeer(s,ipc); settled(peer)
        settings=s.child('settings',[args.settings.resolve(),'--page','appearance'],G_DEBUG='fatal-warnings')
        settings.expect('event=settings-window-created'); ready(s,ipc)
        config=Path(s.env['XDG_CONFIG_HOME']); qtroot=config/'pearl/qt'
        assert not qtroot.exists()
        click(s,ipc,'qt_enabled'); wait_for(lambda:json.loads(peer.document())['qt']['enabled'])
        assert not qtroot.exists(), 'Draft preview wrote external settings'
        click(s,ipc,'apply'); state=settled(peer)
        assert state['qt']['qt5']['state']==state['qt']['qt6']['state']==state['qt']['engine']['state']=='applied',state
        capture(s,'qt-appearance-enabled')
        checks.append('real-ui-opt-in-and-committed-apply')
        pref=json.loads(peer.document('committed'))
        for source in ('seed','wallpaper'):
            if source=='wallpaper':
                image=s.base/'wallpaper.png'; Image.new('RGB',(128,128),(65,135,180)).save(image)
                pref['wallpaper']={'path':str(image),'mode':'cover'}
            pref['theme']={'mode':'dynamic','source':source,'seed':'#248f71','variant':'dark'}
            peer.keep(json.dumps(pref)); peer.action('apply'); state=settled(peer)
            assert state['qt']['qt6']['state']=='applied',state
            assert state['qt']['desired_revision']==state['qt']['applied_revision'],state
            checks.append('dynamic-'+source+'-commit')
        pref['theme']={'mode':'gtk','gtk_name':'Adwaita','variant':'light'}
        peer.keep(json.dumps(pref)); peer.action('apply'); state=settled(peer)
        assert state['qt']['gtk_fallback'] and state['qt']['qt6']['state']=='applied',state
        checks.append('gtk-static-fallback')
        path=config/'qtengine/config.json'
        external=json.loads(path.read_text());external['theme']['style']='Fusion';path.write_text(json.dumps(external))
        state=peer.state(); assert peer.call('qt.retry',revision=state['revision'])['ok']
        assert settled(peer)['qt']['engine']['state']=='conflict'
        state=peer.state(); assert peer.call('qt.review',revision=state['revision'])['ok']
        state=settled(peer); assert 'style' in state['qt_review_text'] and state['qt_review_digest']
        assert peer.call('qt.reapply',revision=state['revision'],digest=state['qt_review_digest'])['ok']
        assert settled(peer)['qt']['engine']['state']=='applied'
        assert json.loads(path.read_text())['theme']['style']=='Darkly'
        checks.append('backend-review-and-explicit-reapply')
        pref['qt']['enabled']=False
        peer.keep(json.dumps(pref));peer.action('apply');state=settled(peer)
        assert state['qt']['qt5']['state']==state['qt']['qt6']['state']=='disabled',state
        assert json.loads(path.read_text()).get('theme',{}).get('style') is None
        checks.append('disable-restores')
        time.sleep(.4)
        assert probe(s,ipc)['connected']
        peer.close(); settings.stop(); clean(settings); shell.stop(); clean(shell)
    (args.output/'results.json').write_text(json.dumps({'status':'passed','checks':checks},indent=2)+'\n')
    print('Qt session: '+str(len(checks))+' groups passed')

if __name__=='__main__': main()
