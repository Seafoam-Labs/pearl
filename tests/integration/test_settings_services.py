#!/usr/bin/env python3
"""S4 real standalone pages, bounded Aqueous editor and peer-owned services."""
import argparse, hashlib, json, time, uuid
from pathlib import Path
from types import SimpleNamespace
from test_settings_app import *
from t00 import Session as T00Session
from test_settings_appearance import click, control, type_text, ready
from settings_editor import EditorPeer
from test_settings_app import windows
from test_services import command
from test_connectivity import FIX, ND, AP, BA, BD

class Peer(EditorPeer):
    def enter(self, page):
        r=self.call('page.enter',page=page);assert r['ok'],r
        self.view=r['result']['view'];return r['result']
    def page(self):
        r=self.call('page.get',view=self.view);assert r['ok'],r
        return r['result']
    def live_action(self, control, **extra):
        return self.call(control['op'],**(json.loads(control['params']) | dict(view=self.view,operation=uuid.uuid4().hex) | extra))
    def aqueous(self):
        r=self.call('aqueous.get');assert r['ok'],r;return r['result']
    def aq_action(self, action, wait=True, **extra):
        state=self.aqueous();nonce=uuid.uuid4().hex
        r=self.call('aqueous.action',operation=nonce,expected_draft_revision=state['revision'],version=state['version'],action=action,**extra)
        assert r['ok'],r
        if wait:
            r=wait_for(lambda:(v if (v:=self.call('operation.get',operation=nonce))['result']['state']!='pending' else False),45)
        return r['result']
    def aq_document(self, kind):
        state=self.aqueous();key={'committed':'version','draft':'revision','base':'revision','review':'review_version','report':'report_version','preview':'report_version'}[kind]
        r=self.call('document.get',domain='aqueous',kind=kind,revision=state[key]);assert r['ok'],r
        meta=r['result'];data=b''
        while True:
            r=self.call('document.read',transfer=meta['transfer'],offset=str(len(data)));assert r['ok'],r
            data+=r['result']['text'].encode()
            if r['result']['done']:break
        assert len(data)==int(meta['bytes']) and hashlib.sha256(data).hexdigest()==meta['sha256']
        return json.loads(data)
    def aq_keep(self, candidate, expected=None):
        state=expected or self.aqueous();data=json.dumps(candidate).encode()
        r=self.call('document.begin',domain='aqueous',expected_draft_revision=state['revision'],base_revision=state['version'],bytes=str(len(data)),sha256=hashlib.sha256(data).hexdigest())
        if not r['ok']:return r
        transfer=r['result']['transfer']
        for offset in range(0,len(data),32768):
            r=self.call('document.write',transfer=transfer,offset=str(offset),text=data[offset:offset+32768].decode());assert r['ok'],r
        return self.call('document.finish',transfer=transfer,operation=uuid.uuid4().hex)

def wait_preview(peer):
    try:
        return wait_for(lambda:peer.aqueous()['phase']==1,45)
    except TimeoutError:
        raise AssertionError(('display preview did not present', peer.aqueous()))

def find(page,row,control):
    return next(c for r in page['live']['rows'] if r['id']==row for c in r['controls'] if c['id']==control)
def navigate(s,ipc,page,section=None):
    params=dict(page=page)
    if section:params['section']=section
    assert request(s,ipc,**params)['ok']
    try:wait_for(lambda:probe(s,ipc)['page']==page)
    except Exception:print('navigation failed',probe(s,ipc),flush=True);raise
    time.sleep(.3)
def aq_ready(s,ipc,peer=None):
    def check():
        expected=peer.aqueous() if peer else None
        v=probe(s,ipc);aq=v['aqueous']
        return v if aq['ready'] and aq['fields']>=221 and not aq['dirty'] and not aq['busy'] and (expected is None or aq['revision']==int(expected['revision']) and aq['backend_version']==int(expected['version'])) else False
    return wait_for(check,20)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('settings','pearl','ctl','spike'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s4/acceptance')
    args=parser.parse_args()
    for name in ('settings','pearl','ctl','spike','output'):setattr(args,name,getattr(args,name).resolve())
    args.output.mkdir(parents=True,exist_ok=True);checks={};report=dict(status='running',checks=checks)
    try:
      with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
        s.env['GSETTINGS_BACKEND']='memory';ipc=IPC(s)
        s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
        wm=Path(s.env['AQUEOUS_CONFIG']);wm.write_text(wm.read_text().replace('"floating"','"stacking"'))
        output=next(iter(ipc.outputs().values()))
        s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
        rules=Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml';rules.write_text('[[window]]\napp_id="'+APP_ID+'"\nfloating=true\nwidth=1040\nheight=850\n');ipc.call('command',action='session.reload',fields={})
        s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
        system=s.child('system',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']]);wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
        s.env['PEARL_TEST_CONNECTIVITY_LOG']=str(s.output/'actions.jsonl');Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).write_text('')
        net=s.child('network',['python3',FIX,'network'],input_pipe=True);net.expect('event=ready')
        bt=s.child('bluetooth',['python3',FIX,'bluetooth'],input_pipe=True);bt.expect('event=ready')
        shell=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        app=s.child('settings',[args.settings,'--page','network'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created')
        peer=Peer(s,ipc);other=Peer(s,ipc);ready(s,ipc);aq_ready(s,ipc,peer)
        assert windows(ipc)[0]['backend']=='xdg'
        checks['normal-window-real-schema-221-fields']=True
        for page in ('network','bluetooth','sound','power','bar','session','notifications','overview'):
            navigate(s,ipc,page);ready(s,ipc);capture(s,page,output['name'])
            assert peer.enter(page)['available']
        checks['complete-sidebar-real-data-or-unavailable']=True
        # Each row must retain distinct identity and text after serialization.
        data=peer.enter('network');rows=data['live']['rows'];aprows=[r for r in rows if '/AccessPoint/' in r['id']]
        assert len({r['id'] for r in aprows})==4 and all('\0' not in r['title'] for r in aprows),aprows
        assert find(data,AP[:-1]+'4','connect')['op']=='network.editor'
        checks['network-stable-identities-and-advanced-editor-route']=True
        # Explicit scan plus independent frontend interest.
        r=peer.live_action(find(data,ND,'scan'));assert r['ok'],r
        other.enter('network');peer.enter('sound');assert other.page()['live']['rows']
        checks['explicit-scan-and-independent-page-owners']=True
        # Actual GTK pointer action changes radio state; generations reject stale calls.
        navigate(s,ipc,'network');click(s,ipc,'network/radio')
        wait_for(lambda:'off' in other.page()['live']['summary'].lower())
        click(s,ipc,'network/radio');wait_for(lambda:'off' not in other.page()['live']['summary'].lower())
        stale=other.live_action(find(other.page(),'network','radio'),generation='0');assert stale['result']['state']=='failed',stale
        checks['network-pointer-action-and-stale-generation']=True
        # Bluetooth discovery owned by this API peer survives another peer leaving.
        data=peer.enter('bluetooth');r=peer.live_action(find(data,BA,'discover'));assert r['ok'],r
        other.enter('bluetooth');other.enter('sound')
        wait_for(lambda:find(peer.page(),'bluetooth','stop')['enabled'])
        peer.enter('sound');peer.enter('bluetooth');assert not find(peer.page(),'bluetooth','stop')['enabled']
        checks['bluetooth-discovery-stops-only-with-owner']=True
        # Credential prompts are visible and answerable only to their initiating peer.
        data=peer.enter('network');other.enter('network')
        r=peer.live_action(find(data,AP,'connect'));assert r['ok'],r
        prompt=wait_for(lambda:peer.page()['live']['prompt'])
        assert other.page()['live']['prompt'] is None
        foreign=other.call('prompt.answer',view=other.view,operation=uuid.uuid4().hex,service='network',prompt=prompt['serial'],accept=True,text='fixture-wifi-password')
        assert foreign['result']['state']=='failed',foreign
        peer.enter('sound');wait_for(lambda:not other.page()['live']['pending'])
        assert other.page()['live']['prompt'] is None
        checks['network-prompts-private-and-navigation-cancels-owner']=True
        navigate(s,ipc,'network');ready(s,ipc);click(s,ipc,AP+'/connect')
        wait_for(lambda:probe(s,ipc)['service_prompt'])
        assert other.page()['live']['prompt'] is None
        s.run(['wtype','abandoned-test-secret'])
        app.proc.kill();app.proc.wait(5)
        wait_for(lambda:not other.page()['live']['pending'])
        assert not other.page()['live']['prompt']
        assert 'abandoned-test-secret' not in Path(s.env['PEARL_TEST_CONNECTIVITY_LOG']).read_text()
        app=s.child('settings-after-prompt-crash',[args.settings,'--page','network'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        assert not probe(s,ipc)['service_prompt']
        checks['frontend-crash-cancels-private-credential-prompt-without-secret-replay']=True
        click(s,ipc,AP+'/connect');wait_for(lambda:probe(s,ipc)['service_prompt'])
        s.run(['wtype','fixture-wifi-password','-k','Return'])
        wait_for(lambda:not probe(s,ipc)['service_prompt'] and not other.page()['live']['pending'])
        assert other.page()['live']['summary']=='Online'
        checks['normal-transient-network-password-entry-and-answer']=True

        navigate(s,ipc,'bluetooth');ready(s,ipc);click(s,ipc,BA+'/discover')
        wait_for(lambda:ctl(s,args.ctl,'connectivity','status')['result']['bluetooth']['discovering'])
        app.proc.kill();app.proc.wait(5)
        wait_for(lambda:not ctl(s,args.ctl,'connectivity','status')['result']['bluetooth']['discovering'])
        assert other.page()['live']['summary']=='Online'
        app=s.child('settings-after-discovery-crash',[args.settings,'--page','bluetooth'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');ready(s,ipc)
        checks['frontend-crash-stops-owned-discovery-and-preserves-network-connection']=True

        data=peer.enter('bluetooth');other.enter('bluetooth')
        r=peer.live_action(find(data,BD,'connect'));assert r['ok'],r
        prompt=wait_for(lambda:peer.page()['live']['prompt'])
        assert prompt['kind']=='confirm' and other.page()['live']['prompt'] is None
        answer=peer.call('prompt.answer',view=peer.view,operation=uuid.uuid4().hex,service='bluetooth',prompt=prompt['serial'],accept=True)
        assert answer['result']['state']=='succeeded',answer
        wait_for(lambda:not peer.page()['live']['pending'])
        checks['bluetooth-owned-pairing-confirmation-completes']=True
        # Pearl form changes retain their invalid intermediate values for repair.
        navigate(s,ipc,'bar');click(s,ipc,'bar.groups.left');type_text(s,'invalid_item');time.sleep(.4)
        assert not peer.state()['valid']
        click(s,ipc,'bar.groups.left');type_text(s,'launcher,workspaces');time.sleep(.4)
        assert peer.state()['valid'];checks['bar-invalid-intermediate-value-remains-editable']=True
        navigate(s,ipc,'sound');assert peer.state()['dirty'];peer.action('discard')
        checks['bar-shares-pearl-draft-across-service-pages']=True
        # Normal-window Aqueous field edits use the backend draft authority.
        navigate(s,ipc,'aqueous','layouts');aq_ready(s,ipc,peer)
        click(s,ipc,'layout.gaps_outer');type_text(s,'18');keys(s,'Tab')
        wait_for(lambda:peer.aqueous()['draft']);aq_ready(s,ipc,peer)
        draft=peer.aq_document('draft');assert any(c['id']=='layout.gaps_outer' and c['value']==18 for c in draft['changes']),draft
        capture(s,'aqueous-layouts-draft',output['name'])
        checks['aqueous-real-pointer-edit-and-shared-draft']=True
        # Child navigation transfers edits and preserves independent section positions.
        click(s,ipc,'layout.gaps_outer');type_text(s,'19')
        choose_navigation(s,ipc,'aqueous','input')
        aq_ready(s,ipc,peer)
        assert any(c['id']=='layout.gaps_outer' and c['value']==19 for c in peer.aq_document('draft')['changes'])
        choose_navigation(s,ipc,'sound')
        assert peer.aqueous()['draft']
        v=choose_navigation(s,ipc,'aqueous');assert v['section']=='input'
        choose_navigation(s,ipc,'aqueous','layouts')
        click(s,ipc,'layout.gaps_outer')
        body=probe(s,ipc)['body_bounds'];win=windows(ipc)[0]['geometry']
        s.run(['wlrctl','pointer','move','-100000','-100000'])
        s.run(['wlrctl','pointer','move',str(round(win['x']+body['x']+body['width']/2)),str(round(win['y']+body['y']+body['height']/2))])
        s.run(['wlrctl','pointer','scroll','200','0']);time.sleep(.3)
        focused=probe(s,ipc)
        assert focused['scroll']>0,focused['scroll']
        assert next(c for c in focused['controls'] if c['field']=='layout.gaps_outer')['focused']
        saved_scroll=focused['scroll']
        assert choose_navigation(s,ipc,'aqueous','input')['scroll']==0
        restored=choose_navigation(s,ipc,'aqueous','layouts')
        assert abs(restored['scroll']-saved_scroll)<1,(saved_scroll,restored['scroll'])
        assert next(c for c in restored['controls'] if c['field']=='layout.gaps_outer')['focused']
        # Refresh rebuilds all fields; old focus references must never be reused.
        peer.aq_action('refresh');aq_ready(s,ipc,peer)
        choose_navigation(s,ipc,'aqueous','input')
        choose_navigation(s,ipc,'aqueous','layouts')
        assert peer.aqueous()['draft'] and app.proc.poll() is None
        click(s,ipc,'layout.gaps_outer');type_text(s,'18');keys(s,'Tab');aq_ready(s,ipc,peer)
        checks['aqueous-sublist-draft-transfer-section-restoration-and-rebuild']=True
        for action in ('validate','apply'):
            time.sleep(.3)
            click_widget(s,ipc,control(s,ipc,'aqueous.'+action))
            try:wait_for(lambda:peer.aqueous()['outcome']==('validated' if action=='validate' else 'saved') and not peer.aqueous()['busy'],45)
            except Exception:print('action failed',action,peer.aqueous(),probe(s,ipc)['aqueous'],flush=True);raise
            aq_ready(s,ipc,peer)
        current=peer.aq_document('committed');assert next(f for f in current['fields'] if f['id']=='layout.gaps_outer')['value']==18
        checks['aqueous-validate-save-reload-and-receipt']=True
        # Concurrent revision checks retain the newer draft unchanged.
        state=peer.aqueous();candidate=dict(protocol=1,expected_generation=current['generation'],changes=[dict(id='layout.gaps_outer',value=19)],raw_files={})
        assert peer.aq_keep(candidate)['result']['state']=='succeeded'
        stale=other.aq_keep(candidate,state);assert not stale['ok'] and stale['err']['code']=='StaleDraft',stale
        assert peer.aq_document('draft')['changes'][0]['value']==19
        checks['aqueous-stale-writer-rejected-with-draft-retained']=True
        peer.aq_action('discard');aq_ready(s,ipc,peer)
        for section in ('appearance','layouts','input','keybinds','rules','displays','advanced'):
            navigate(s,ipc,'aqueous',section);capture(s,'aqueous-'+section,output['name'])
        checks['all-aqueous-sections-and-structured-editors-reachable']=True
        # Layout mutations are guarded by the output's active workspace identity.
        page=peer.enter('overview');layout=next(r for r in page['live']['rows'] if any(c['op']=='layout.get' for c in r['controls']))
        r=peer.live_action(layout['controls'][0]);assert r['ok'],r
        r=peer.live_action(layout['controls'][1],generation='0');assert r['result']['state']=='failed',r
        checks['workspace-layout-output-generation-guard']=True
        # Aqueous requests retain the existing multi-megabyte document budget.
        current=peer.aq_document('committed')
        large=dict(protocol=1,expected_generation=current['generation'],changes=[],raw_files={'layout':current['raw_files']['layout']+'\n# '+('bounded document '*6000)+'\n'})
        assert peer.aq_keep(large)['result']['state']=='succeeded'
        assert peer.aq_document('draft')==large;aq_ready(s,ipc,peer)
        state=peer.aqueous();too_large=peer.call('document.begin',domain='aqueous',expected_draft_revision=state['revision'],base_revision=state['version'],bytes=str(4*1024*1024+1),sha256='0'*64)
        assert not too_large['ok'] and too_large['err']['code']=='DocumentTooLarge',too_large
        peer.aq_action('discard');aq_ready(s,ipc,peer)
        checks['aqueous-chunked-document-over-64k-and-four-mib-bound']=True
        # Recording uses the application toplevel's shortcut inhibition.
        navigate(s,ipc,'aqueous','keybinds');aq_ready(s,ipc,peer)
        record=next(c['field'] for c in probe(s,ipc)['controls'] if c['field']=='record:spawn_terminal')
        click(s,ipc,record);wait_for(lambda:probe(s,ipc)['aqueous']['recording'])
        s.run(['wtype','-M','logo','-k','F12','-m','logo'])
        wait_for(lambda:not probe(s,ipc)['aqueous']['recording']);aq_ready(s,ipc,peer)
        assert peer.aqueous()['draft'];assert peer.aq_action('validate')['state']=='succeeded'
        peer.aq_action('discard');aq_ready(s,ipc,peer)
        click(s,ipc,record);wait_for(lambda:probe(s,ipc)['aqueous']['recording'])
        navigate(s,ipc,'sound');assert not probe(s,ipc)['aqueous']['recording']
        checks['normal-window-shortcut-recording-and-leave-cleanup']=True
        # Frontend-owned display preview survives page navigation; another peer
        # cannot confirm it, and closing the window waits for native rollback.
        ipc.call('command',action='window.maximized',fields=dict(id=windows(ipc)[0]['id'],value=True))
        wait_for(lambda:windows(ipc)[0]['maximized'])
        baseline={o['name']:o for o in json.loads(s.run(['wlr-randr','--json']).stdout)}
        peer.aq_action('refresh');aq_ready(s,ipc,peer);current=peer.aq_document('committed')
        target=baseline[output['name']]
        preview=dict(protocol=1,expected_generation=current['generation'],changes=[],raw_files={},monitor_changes=[dict(id='live:'+output['name'],name=output['name'],x=target['position']['x'],y=target['position']['y'],scale=1.25,transform='normal')])
        assert peer.aq_keep(preview)['result']['state']=='succeeded'
        navigate(s,ipc,'aqueous','displays');aq_ready(s,ipc,peer);time.sleep(.3)
        click_widget(s,ipc,control(s,ipc,'aqueous.apply'))
        wait_preview(peer)
        navigate(s,ipc,'sound');wait_for(lambda:probe(s,ipc)['aqueous']['phase']==1,5)
        denied=peer.aq_action('keep');assert denied['state']=='failed' and denied['error_code']=='NotOwner',denied
        capture(s,'display-preview-during-sound',output['name'])
        app.stop();clean(app);wait_for(lambda:not peer.aqueous()['busy'],45)
        assert next(o for o in json.loads(s.run(['wlr-randr','--json']).stdout) if o['name']==output['name'])['scale']==target['scale']
        assert peer.aqueous()['outcome'] in ('reverted','invalidated')
        app=s.child('settings-after-preview',[args.settings,'--page','aqueous'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');aq_ready(s,ipc,peer)
        peer.aq_action('discard');aq_ready(s,ipc,peer)
        checks['display-preview-navigation-owner-check-close-and-confirmed-rollback']=True
        # Abrupt frontend loss has no cleanup callback: backend disconnect and
        # the compositor lease must still restore the original display state.
        peer.aq_action('refresh');aq_ready(s,ipc,peer)
        current=peer.aq_document('committed');preview['expected_generation']=current['generation']
        peer.aq_keep(preview);navigate(s,ipc,'aqueous','displays');aq_ready(s,ipc,peer);time.sleep(.3)
        click_widget(s,ipc,control(s,ipc,'aqueous.apply'))
        wait_preview(peer)
        app.proc.kill();app.proc.wait(5)
        wait_for(lambda:not peer.aqueous()['busy'],45)
        assert next(o for o in json.loads(s.run(['wlr-randr','--json']).stdout) if o['name']==output['name'])['scale']==target['scale']
        assert peer.aqueous()['outcome'] in ('reverted','invalidated')
        peer.aq_action('discard')
        app=s.child('settings-after-crash',[args.settings,'--page','aqueous'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');aq_ready(s,ipc,peer)
        checks['frontend-crash-releases-display-preview-and-restores-output']=True
        peer.aq_action('refresh');aq_ready(s,ipc,peer)
        current=peer.aq_document('committed');preview['expected_generation']=current['generation']
        peer.aq_keep(preview);navigate(s,ipc,'aqueous','displays');aq_ready(s,ipc,peer);time.sleep(.3)
        click_widget(s,ipc,control(s,ipc,'aqueous.apply'));wait_preview(peer)
        locker=s.child('preview-locker',[args.spike],input_pipe=True,PEARL_T00_ISOLATED='1',WLR_BACKENDS='headless',PEARL_T00_MODE='plain');locker.expect('T00 event=ready')
        locker.proc.stdin.write('lock\n');locker.proc.stdin.flush();locker.expect('T00 event=locked')
        wait_for(lambda:not probe(s,ipc)['visible'])
        wait_for(lambda:not ctl(s,args.ctl,'aqueous','status')['result']['busy'],45)
        assert next(o for o in json.loads(s.run(['wlr-randr','--json']).stdout) if o['name']==output['name'])['scale']==target['scale']
        locker.proc.stdin.write('unlock\n');locker.proc.stdin.flush();locker.expect('T00 event=unlocked')
        navigate(s,ipc,'aqueous','displays');aq_ready(s,ipc,peer);peer.aq_action('discard');aq_ready(s,ipc,peer)
        locker.proc.stdin.write('quit\n');locker.proc.stdin.flush();clean(locker)
        checks['lock-during-frontend-preview-hides-window-and-restores-display']=True
        # Normal close acknowledges drafts, leaves shell running, and reopens them.
        current=peer.aq_document('committed');candidate['expected_generation']=current['generation']
        peer.aq_keep(candidate);aq_ready(s,ipc,peer);navigate(s,ipc,'sound')
        app.stop();clean(app);assert shell.proc.poll() is None and peer.aqueous()['draft']
        app=s.child('settings-reopened',[args.settings,'--page','aqueous','--section','layouts'],G_DEBUG='fatal-warnings');app.expect('event=settings-window-created');aq_ready(s,ipc,peer)
        assert peer.aq_document('draft')['changes'][0]['value']==19
        checks['aqueous-close-reopen-retains-acknowledged-draft']=True
        # Backend restart retains the frontend copy for explicit recovery only.
        peer.close();other.close();shell.stop();clean(shell)
        wait_for(lambda:not probe(s,ipc)['aqueous']['online'])
        assert probe(s,ipc)['aqueous']['recovery']
        shell=s.child('pearl-restarted',[args.pearl],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
        click_widget(s,ipc,probe(s,ipc)['retry_bounds'])
        wait_for(lambda:probe(s,ipc)['aqueous']['online'] and probe(s,ipc)['aqueous']['ready'],25)
        peer=Peer(s,ipc);assert not peer.aqueous()['draft']
        assert probe(s,ipc)['aqueous']['recovery']
        navigate(s,ipc,'aqueous','layouts');time.sleep(.3)
        capture(s,'aqueous-recovery-after-backend-restart',output['name'])
        click_widget(s,ipc,control(s,ipc,'aqueous.rebase'));aq_ready(s,ipc,peer)
        assert peer.aq_document('draft')['changes'][0]['value']==19
        assert not probe(s,ipc)['aqueous']['recovery']
        click_widget(s,ipc,control(s,ipc,'aqueous.discard'));wait_for(lambda:not peer.aqueous()['draft']);aq_ready(s,ipc,peer)
        checks['aqueous-backend-restart-no-replay-explicit-rebase-and-discard']=True
        app.stop();clean(app);peer.close();shell.stop();clean(shell)
      report['status']='passed'
    except Exception as exc:
      report.update(status='failed',error=repr(exc));raise
    finally:
      (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
