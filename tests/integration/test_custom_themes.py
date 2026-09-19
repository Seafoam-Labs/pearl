#!/usr/bin/env python3
"""Private desktop acceptance for native community themes and committed snapshots."""
import argparse
import hashlib
import json
from pathlib import Path
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, probe, capture, resize, clean
from test_settings_appearance import ready, settled, click
from settings_editor import EditorPeer
from test_theme_packages import fixture, archive, PALETTE

class Peer(EditorPeer):
    def call(self, op, **params):
        reply = super().call(op, **params)
        if op == 'hello' and reply['ok']:
            self.appearance = reply['result']['appearance']
            self.capabilities = reply['result']['capabilities']
        return reply
    def theme(self, action, error=None, **kw):
        reply = wait_for(lambda: (r if (r := self.call('theme.start', request=json.dumps(dict(action=action, **kw))))['ok'] or r.get('err', {}).get('code') != 'Busy' else False), 30)
        assert reply['ok'], reply
        status = wait_for(lambda: (v if not (v := self.call('theme.get')['result'])['busy'] else False), 60)
        assert status['error_code'] == error, status
        return status['result']

def main():
    parser=argparse.ArgumentParser()
    for name in ('pearl','settings'): parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/custom-themes')
    args=parser.parse_args(); args.output.mkdir(parents=True,exist_ok=True)
    report=dict(status='running',binaries={n:hashlib.sha256(getattr(args,n).read_bytes()).hexdigest() for n in ('pearl','settings')})
    (args.output/'acceptance.json').write_text(json.dumps(report,indent=2)+'\n')
    with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND']='memory'
        calls=s.base/'generator-calls'; calls.write_text('')
        mode=s.base/'generator-mode';mode.write_text('pass')
        s.env.update(PATH=str(ROOT/'tests/fixtures/theme')+':'+s.env['PATH'], PEARL_TEST_GENERATOR_LOG=str(calls),PEARL_TEST_GENERATOR_MODE=str(mode))
        ipc=IPC(s)
        output=next(iter(ipc.outputs().values()))
        s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
        resize(s,Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml',1040,850)
        source=s.base/'theme-source'; manifest=fixture(source)
        light=json.loads((ROOT/'themes/examples/meadow/light.json').read_text())
        (source/'light.json').write_text(json.dumps(light))
        manifest['palettes']['light']='light.json'
        (source/'theme.json').write_text(json.dumps(manifest))
        tokens=json.loads((ROOT/'themes/examples/meadow/tokens.json').read_text())
        tokens.update(card_radius=4,control_radius=3)
        (source/'tokens.json').write_text(json.dumps(tokens))
        bundle=s.base/'sample.tar.gz'; archive(source,bundle)
        report.update(manifest=manifest,palette=PALETTE,light_palette=light,tokens=tokens,archive_sha256=hashlib.sha256(bundle.read_bytes()).hexdigest())
        shell=s.child('pearl',[args.pearl.resolve()],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        peer=Peer(s,ipc);settled(peer)
        assert peer.capabilities['community_themes']
        peer.theme('import_archive',path=str(bundle))
        catalog=peer.theme('catalog');assert catalog['entries'][0]['id']==manifest['id']
        theme=dict(mode='package',package_id=manifest['id'],catalog_revision=catalog['revision'])
        preview=peer.theme('preview',theme=theme)
        assert preview['palette']==PALETTE and preview['tokens']['card_radius']==4
        prefs=json.loads(peer.document('committed'));prefs['theme'].update(theme)
        peer.keep(json.dumps(prefs));assert peer.action('apply')['state']=='succeeded';settled(peer)
        check=Peer(s,ipc);assert check.appearance['palette']==PALETTE
        assert check.appearance['style_tokens']['card_radius']==4
        assert check.appearance['style_css'];check.close()
        committed=json.loads(peer.document('committed'))
        assert len(committed['theme']['snapshot_digest'])==64
        app=s.child('settings',[args.settings.resolve(),'--page','appearance'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        wait_for(lambda: any(c['field']=='themes.preview.0' for c in probe(s,ipc)['controls']), 15)
        wait_for(lambda: not probe(s,ipc)['theme_busy'],15)
        click(s,ipc,'themes.preview.0')
        wait_for(lambda: probe(s,ipc)['theme_status'].startswith('Preview only'),15)
        assert json.loads(peer.document('committed'))==committed
        click(s,ipc,'themes.builtin.0')
        wait_for(lambda: peer.state()['dirty'],15)
        assert json.loads(peer.document())['theme']['mode']=='static'
        click(s,ipc,'discard');ready(s,ipc)
        assert json.loads(peer.document('committed'))==committed
        # Exercise the actual picker and Apply button, not just backend edits.
        click(s,ipc,'themes.builtin.0');ready(s,ipc)
        click(s,ipc,'apply')
        wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'],25)
        assert json.loads(peer.document('committed'))['theme']['mode']=='static'
        ready(s,ipc)
        # Separate color/style choices must not mask a later whole-theme choice.
        click(s,ipc,'themes.colors.0');ready(s,ipc)
        click(s,ipc,'themes.default_style.0');ready(s,ipc)
        click(s,ipc,'apply')
        wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'],25)
        check=Peer(s,ipc)
        assert check.appearance['palette']==PALETTE
        assert check.appearance['style_tokens']['card_radius']!=4
        check.close()
        ready(s,ipc)
        click(s,ipc,'themes.select.0');ready(s,ipc)
        assert json.loads(peer.document())['theme']['package_id']==manifest['id']
        assert json.loads(peer.document())['theme']['palette_id']==''
        assert json.loads(peer.document())['theme']['style_id']==''
        assert peer.state()['dirty']
        click(s,ipc,'apply')
        wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'],25)
        check=Peer(s,ipc)
        assert check.appearance['palette']==PALETTE
        assert check.appearance['style_tokens']['card_radius']==4
        check.close()
        committed=json.loads(peer.document('committed'))
        capture(s,'custom-palette',output['name'])
        assert probe(s,ipc)['style']=='dark'
        enlarged=json.loads(peer.document('committed'))
        enlarged.update(font_size=20,density='compact',reduced_motion=True)
        enlarged['theme']['variant']='light'
        peer.keep(json.dumps(enlarged));assert peer.action('apply')['state']=='succeeded';ready(s,ipc)
        check=Peer(s,ipc);assert check.appearance['palette']==light;check.close()
        rendered=probe(s,ipc)
        (args.output/'light-probe.json').write_text(json.dumps(rendered,indent=2))
        assert rendered['editor']['error_code']=='', rendered['editor']
        capture(s,'custom-light-compact-large-text',output['name'])
        peer.keep(json.dumps(committed));assert peer.action('apply')['state']=='succeeded';ready(s,ipc)
        # New package bytes cannot recolor the committed shell/Settings implicitly.
        fixture(source,version='2.0.0');(source/'tokens.json').write_text('{"card_radius":16}')
        archive(source,bundle);peer.theme('import_archive',path=str(bundle))
        check=Peer(s,ipc);assert check.appearance['style_tokens']['card_radius']==4;check.close()
        peer.keep(json.dumps(committed));assert peer.action('apply')['state']=='failed'
        assert peer.state()['error_code']=='ThemeCatalogChanged'
        peer.action('discard')
        # Rotate more than the retained snapshot budget. Each version changes
        # the content digest even when its declared fixed colors are identical.
        for version in range(18):
            fixture(source,version=f'3.0.{version}');archive(source,bundle)
            peer.theme('import_archive',path=str(bundle))
            catalog=peer.theme('catalog')
            candidate=json.loads(peer.document('committed'))
            candidate['theme']['catalog_revision']=catalog['revision']
            peer.keep(json.dumps(candidate));assert peer.action('apply')['state']=='succeeded'
        snapshots=Path(s.env['XDG_CONFIG_HOME'])/'pearl/theme-snapshots'
        assert len(list(snapshots.glob('*.json'))) <= 16
        # Removal preserves committed bytes across a full shell restart.
        peer.theme('remove',id=manifest['id'])
        app.stop();clean(app);peer.close();shell.stop();clean(shell)
        shell=s.child('pearl-restart',[args.pearl.resolve()],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        peer=Peer(s,ipc);settled(peer)
        check=Peer(s,ipc);assert check.appearance['palette']==PALETTE
        assert check.appearance['style_tokens']['card_radius']==4;check.close()
        # Explicit built-in recovery remains possible with a missing package.
        prefs=json.loads(peer.document('committed'))
        prefs['theme'].update(mode='static',package_id='',palette_id='',style_id='',catalog_revision='')
        peer.keep(json.dumps(prefs));assert peer.action('apply')['state']=='succeeded'
        assert json.loads(peer.document('committed'))['theme']['snapshot_digest']==''
        assert calls.read_text()=='', 'Fixed themes must never launch Matugen'
        # Explicit generated previews run in private scratch storage, preserve
        # the committed appearance and cancel subprocesses without publishing.
        peer.theme('import_archive',path=str(bundle))
        saved=peer.document('committed')
        dynamic=dict(mode='dynamic',source='seed',seed='#527a64',style_id=manifest['id'])
        rendered=peer.theme('preview_render',theme=dynamic)
        assert len(rendered['palette'])==13 and rendered['tokens']['card_radius']==4
        assert peer.document('committed')==saved
        mode.write_text('fail')
        peer.theme('preview_render',error='GeneratorFailed',theme=dynamic)
        mode.write_text('slow')
        job=peer.call('theme.start',request=json.dumps(dict(action='preview_render',theme=dynamic)))['result']
        wait_for(lambda:'"mode": "slow"' in calls.read_text(),10)
        assert peer.call('theme.cancel',serial=job['serial'])['ok']
        ended=wait_for(lambda:(v if not (v:=peer.call('theme.get',serial=job['serial'])['result'])['busy'] else False),10)
        assert ended['error_code'] in ('Cancelled','GeneratorCancelled','GeneratorFailed'),ended
        assert peer.document('committed')==saved
        assert not list((Path(s.env['XDG_CACHE_HOME'])/'pearl/theme-previews').iterdir())
        peer.close();shell.stop();clean(shell)
        report.update(status='passed',checks=['backend_jobs','exact_palette','independent_preview','gui_draft_discard','gui_theme_apply_replaces_overrides','light_compact_large_text','stale_catalog_rejection','bounded_snapshot_rotation','package_removal_restart_snapshot','builtin_recovery','no_matugen_for_fixed_palette','cancellable_generated_preview'])
        (args.output/'acceptance.json').write_text(json.dumps(report,indent=2)+'\n')
        print('PASS native theme jobs, fixed/generated previews, cancellation, exact live palette/style, bounded snapshots, restart and built-in recovery')

if __name__=='__main__':main()
