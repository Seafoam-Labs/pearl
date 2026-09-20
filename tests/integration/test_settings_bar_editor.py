#!/usr/bin/env python3
"""Selection-based native bar editor, shared drafts and saved layouts in private Aqueous."""
import argparse
import copy
import hashlib
import json
import time
from pathlib import Path
from PIL import Image
from test_settings_app import (ROOT, PrivateSession, IPC, wait_for, ctl, capture,
                               clean, request, probe, click_widget, keys, resize)
from test_settings_appearance import ready, click, control, type_text
from settings_editor import EditorPeer


def menu_click(s, ipc, field):
    wait_for(lambda: any(c['field'] == field for c in probe(s, ipc)['controls']))
    time.sleep(.15)
    click_widget(s, ipc, control(s, ipc, field))


def menu_closed(s, ipc):
    wait_for(lambda: not any(c['field'].startswith(('bar.action.', 'bar.pick.', 'bar.icon.preset.')) for c in probe(s, ipc)['controls']))


def choose(s, ipc, group, name, identifier):
    click(s, ipc, 'bar.add.' + group)
    wait_for(lambda: any(c['field'] == 'bar.picker.search' for c in probe(s, ipc)['controls']))
    # The picker focuses its native search entry. Filtering also makes the
    # result reachable without depending on the scroll position of the catalog.
    type_text(s, name)
    menu_click(s, ipc, 'bar.pick.' + identifier)
    menu_closed(s, ipc)


def action(s, ipc, identifier, operation):
    click(s, ipc, 'bar.widget.' + identifier)
    menu_click(s, ipc, 'bar.action.' + operation)
    menu_closed(s, ipc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/bar-editor')
    args = parser.parse_args()
    for name in ('settings', 'pearl', 'ctl', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = dict(status='running', checks=checks, binaries={n: hashlib.sha256(getattr(args,n).read_bytes()).hexdigest() for n in ('settings','pearl','ctl')})
    def passed(name):
        checks[name] = True
        print('PASS', name, flush=True)
    try:
        with PrivateSession(args.output/'session', tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            s.run(['wlr-randr','--output',output['name'],'--custom-mode','1600x1100@60Hz'])
            rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
            resize(s, rules, 1200, 960)
            package=Path(s.env['XDG_DATA_HOME'])/'pearl/plugins/editor-fixture'
            package.mkdir(parents=True)
            manifest=dict(id='editor.fixture',name='Editor fixture',version='1')
            (package/'plugin.json').write_text(json.dumps(manifest))
            (package/'plugin.wasm').write_bytes(bytes([0,97,115,109,13,0,1,0]))
            from test_plugin_host import digest
            shell = s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            ctl(s,args.ctl,'session','action','--command','dnd_on')
            peer = EditorPeer(s,ipc)
            wait_for(lambda:not peer.state()['busy'])
            baseline = json.loads(peer.document('committed'))
            baseline['font_size'] = 15
            baseline['application_launchers'] = [dict(backend='xdg',identity='org.pearl.Custom',desktop_id='Custom.desktop')]
            baseline['plugins'] = dict(entries=[dict(id='editor.fixture',enabled=True,digest=digest(package))])
            baseline['bar']['groups']['center'] = 'clock,plugin:missing/main'
            baseline['outputs'] = [dict(connector='UNPLUGGED-1',bar=copy.deepcopy(baseline['bar']),dock=dict(enabled=False))]
            peer.keep(json.dumps(baseline))
            assert peer.action('apply')['state'] == 'succeeded'
            baseline = json.loads(peer.document('committed'))
            path=Path(ctl(s,args.ctl,'preferences','status')['result']['path'])
            disk=path.read_bytes()
            app=s.child('settings',[args.settings,'--page','bar'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created');ready(s,ipc)
            click(s, ipc, 'launchers.expand')
            click(s, ipc, 'launchers.remove.xdg.org.pearl.Custom')
            ready(s, ipc)
            assert json.loads(peer.document())['application_launchers'] == []
            assert json.loads(peer.document('committed'))['application_launchers'] == baseline['application_launchers']
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(peer.document())['application_launchers'] == baseline['application_launchers']
            click(s, ipc, 'launchers.remove.xdg.org.pearl.Custom')
            ready(s, ipc); click(s, ipc, 'apply'); ready(s, ipc)
            wait_for(lambda:not peer.state()['dirty'] and not peer.state()['busy'])
            assert json.loads(path.read_text())['application_launchers'] == []
            assert json.loads(path.read_text())['pinned_apps'] == baseline['pinned_apps']
            peer.keep(json.dumps(baseline)); assert peer.action('apply')['state'] == 'succeeded'; ready(s, ipc)
            disk=path.read_bytes()
            passed('launcher-choice-removal-apply-discard-and-retained-pins')

            def keep(text):
                peer.keep(text)
                expected=hashlib.sha256(text.encode()).hexdigest()
                wait_for(lambda:probe(s,ipc)['editor']['sha256']==expected)
                ready(s,ipc)
            fields={c['field'] for c in probe(s,ipc)['controls']}
            assert not {'bar.groups.left','bar.groups.center','bar.groups.right'} & fields
            assert {'bar.add.left','bar.add.center','bar.add.right','bar.widget.launcher','bar.widget.plugin:missing/main'} <= fields
            assert path.read_bytes()==disk and not peer.state()['dirty']
            capture(s,'bar-editor-desktop',output['name'])
            passed('opening-is-read-only-and-unavailable-plugin-is-retained')
            def icon_state():
                return ctl(s,args.ctl,'aqueous','status','--text','test-bar-layout:' + output['id'])['result']
            # Opacity uses the shared draft, and the scale and spin share a value.
            def opacity():
                return json.loads(peer.document())['bar']['background_opacity']
            click(s, ipc, 'bar.background_opacity.mode')
            keys(s, 'End', 'Return'); ready(s, ipc)
            assert opacity() == dict(mode='custom', percent=86), opacity()
            click(s, ipc, 'bar.background_opacity.percent')
            type_text(s, '50'); keys(s, 'Return'); ready(s, ipc)
            assert opacity()['percent'] == 50, opacity()
            assert icon_state()['background_opacity']['mode'] == 'automatic'
            assert path.read_bytes() == disk
            click(s, ipc, 'bar.background_opacity.slider')
            keys(s, 'Home'); ready(s, ipc)
            assert opacity()['percent'] == 0, opacity()
            keys(s, 'End'); ready(s, ipc)
            assert opacity()['percent'] == 100, opacity()
            click(s, ipc, 'discard'); ready(s, ipc)
            assert opacity() == baseline['bar']['background_opacity']
            click(s, ipc, 'bar.background_opacity.mode')
            keys(s, 'End', 'Return'); ready(s, ipc)
            click(s, ipc, 'bar.background_opacity.percent')
            type_text(s, '50'); keys(s, 'Return'); ready(s, ipc)
            click(s, ipc, 'apply'); ready(s, ipc)
            wait_for(lambda: icon_state()['background_opacity'] == dict(mode='custom', percent=50))
            assert json.loads(path.read_text())['bar']['background_opacity'] == opacity()
            assert json.loads(path.read_text())['outputs'] == baseline['outputs']
            capture(s, 'bar-opacity-custom-settings', output['name'])
            click(s, ipc, 'bar.background_opacity.mode')
            keys(s, 'Home', 'Return'); ready(s, ipc)
            assert opacity() == dict(mode='automatic', percent=50)
            click(s, ipc, 'apply'); ready(s, ipc)
            wait_for(lambda: icon_state()['background_opacity']['mode'] == 'automatic')
            # Reopening restores the saved mode and remembered custom percentage.
            request(s, ipc, page='appearance'); ready(s, ipc)
            request(s, ipc, page='bar'); ready(s, ipc)
            assert opacity() == dict(mode='automatic', percent=50)
            peer.keep(json.dumps(baseline)); assert peer.action('apply')['state'] == 'succeeded'; ready(s, ipc)
            disk = path.read_bytes()
            passed('bar-opacity-slider-number-draft-discard-save-and-reopen')
            def open_icon():
                click(s, ipc, 'bar.widget.launcher')
                menu_click(s, ipc, 'bar.icon.expand')
                time.sleep(.3)
                capture(s, 'launcher-icon-menu', output['name'])
            def icon_action(field):
                open_icon(); menu_click(s, ipc, 'bar.icon.' + field)
                menu_closed(s, ipc); ready(s, ipc)
            def icon_status():
                return next(c['text'] for c in probe(s, ipc)['controls'] if c['field'] == 'bar.icon.status')
            icon_action('preset.1')
            selected = dict(kind='theme', value='pearl-view-grid-symbolic')
            assert json.loads(peer.document())['bar']['launcher_icon'] == selected
            assert icon_state()['launcher_icon']['kind'] == 'default'
            assert path.read_bytes() == disk
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(peer.document()) == baseline
            icon_action('preset.1')
            click(s, ipc, 'apply'); ready(s, ipc)
            wait_for(lambda: icon_state()['launcher_icon'] == selected)
            assert json.loads(path.read_text())['bar']['launcher_icon'] == selected
            open_icon(); menu_click(s, ipc, 'bar.icon.name')
            type_text(s, 'pearl-missing-test-icon')
            menu_click(s, ipc, 'bar.icon.use'); menu_closed(s, ipc); ready(s, ipc)
            wait_for(lambda: 'unavailable' in icon_status())
            assert icon_state()['launcher_icon'] == selected
            click(s, ipc, 'discard'); ready(s, ipc)
            open_icon(); menu_click(s, ipc, 'bar.icon.file')
            wait_for(lambda: probe(s, ipc)['launcher_icon_picker'])
            time.sleep(.5); keys(s, 'Escape')
            wait_for(lambda: not probe(s, ipc)['launcher_icon_picker'])
            ready(s, ipc)
            assert not peer.state()['dirty']
            menu_closed(s, ipc)
            image = s.base/'launcher with spaces.png'
            Image.new('RGBA', (80, 40), (35, 180, 110, 180)).save(image)
            open_icon(); menu_click(s, ipc, 'bar.icon.file')
            s.run(['wtype','-s','300','-M','ctrl','l','-m','ctrl',str(image),'-k','Return'])
            wait_for(lambda: json.loads(peer.document())['bar']['launcher_icon'] == dict(kind='file',value=str(image)))
            menu_closed(s, ipc); ready(s, ipc)
            wait_for(lambda: icon_status() == '')
            click(s, ipc, 'apply'); ready(s, ipc)
            wait_for(lambda: icon_state()['launcher_icon']['kind'] == 'file' and not icon_state()['launcher_icon_loading'])
            assert not icon_state()['launcher_icon_failed']
            capture(s, 'launcher-icon-png', output['name'])
            image.unlink()
            icon_action('retry')
            wait_for(lambda: icon_state()['launcher_icon_failed'])
            wait_for(lambda: 'unavailable' in icon_status())
            Image.new('RGBA', (80, 40), (180, 100, 35, 180)).save(image)
            icon_action('retry')
            wait_for(lambda: not icon_state()['launcher_icon_loading'] and not icon_state()['launcher_icon_failed'])
            wait_for(lambda: icon_status() == '')
            assert not peer.state()['dirty']
            before_icon=json.loads(peer.document())
            bad=s.base/'invalid.png'; bad.write_bytes(image.read_bytes()[:-1] + b'0')
            open_icon(); menu_click(s, ipc, 'bar.icon.file')
            wait_for(lambda: probe(s, ipc)['launcher_icon_picker'])
            s.run(['wtype','-s','300','-M','ctrl','l','-m','ctrl',str(bad),'-s','500','-k','Return'])
            time.sleep(.5)
            if probe(s, ipc)['launcher_icon_picker']: keys(s, 'Return')
            wait_for(lambda: any(c['field']=='bar.icon.error' and 'Could not load PNG' in (c['text'] or '') for c in probe(s, ipc)['controls']))
            assert json.loads(peer.document())==before_icon
            keys(s, 'Escape'); menu_closed(s, ipc)
            # A newer draft cancels the chooser; its old callback cannot apply.
            open_icon(); menu_click(s, ipc, 'bar.icon.file')
            wait_for(lambda: probe(s, ipc)['launcher_icon_picker'])
            external=copy.deepcopy(before_icon); external['bar']['size']=52
            keep(json.dumps(external))
            wait_for(lambda: not probe(s, ipc)['launcher_icon_picker'])
            menu_closed(s, ipc)
            assert json.loads(peer.document())==external
            click(s, ipc, 'discard'); ready(s, ipc)
            icon_action('reset')
            assert json.loads(peer.document())['bar']['launcher_icon']['kind'] == 'default'
            # Changing the draft while a menu is open rejects the old selection.
            open_icon()
            external=copy.deepcopy(baseline); external['bar']['size']=52
            keep(json.dumps(external))
            menu_click(s, ipc, 'bar.icon.preset.1')
            assert json.loads(peer.document()) == external
            keys(s, 'Escape'); menu_closed(s, ipc)
            keep(json.dumps(baseline)); assert peer.action('apply')['state'] == 'succeeded'; ready(s, ipc)
            disk=path.read_bytes()
            passed('launcher-icons-preview-discard-apply-file-cancel-retry-reset-and-stale-edit')
            # This expanded suite exceeds the backend's bounded ten-minute
            # receipt ledger. Start a fresh shell for the remaining independent
            # editor cases, keeping the saved baseline and isolated session.
            app.stop(); clean(app); peer.close()
            ctl(s,args.ctl,'quit'); clean(shell)
            shell=s.child('pearl-icons-restarted',[args.pearl],G_DEBUG='fatal-warnings')
            shell.expect('event=control-ready')
            peer=EditorPeer(s,ipc)
            wait_for(lambda:not peer.state()['busy'])
            app=s.child('settings-icons-restarted',[args.settings,'--page','bar'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s,ipc)
            assert json.loads(peer.document())==baseline
            disk=path.read_bytes()
            def live_mode():
                return ctl(s,args.ctl,'aqueous','status','--text','test-bar-layout:' + output['id'])['result']['workspace_mode']
            assert live_mode() == 'large'
            def mode_control(mode):
                return next(c for c in probe(s, ipc)['controls'] if c['field'] == 'bar.workspace.mode.' + mode)
            def preview_text():
                return next(c['text'] for c in probe(s, ipc)['controls'] if c['field'] == 'bar.workspace.preview')
            for mode, example in [('small', '4  [5]  6'), ('medium', '3  4  [5]  6  7'), ('large', '1  2  3  4  [5]  6  7  8  9')]:
                click(s, ipc, 'bar.widget.workspaces')
                old_mode = json.loads(peer.document())['bar']['workspace_mode']
                assert mode_control(old_mode)['selected']
                menu_click(s, ipc, 'bar.workspace.mode.' + mode)
                menu_closed(s, ipc)
                wait_for(lambda: json.loads(peer.document())['bar']['workspace_mode'] == mode)
                ready(s, ipc)
                assert preview_text().endswith(example), preview_text()
                candidate = copy.deepcopy(baseline); candidate['bar']['workspace_mode'] = mode
                assert json.loads(peer.document()) == candidate
                assert path.read_bytes() == disk
                assert live_mode() == 'large'
                click(s, ipc, 'bar.widget.workspaces')
                assert mode_control(mode)['selected']
                capture(s, 'workspace-mode-' + mode, output['name'])
                keys(s, 'Escape'); menu_closed(s, ipc)
            click(s, ipc, 'discard'); ready(s, ipc)
            assert json.loads(peer.document()) == baseline
            passed('workspace-mode-radio-selection-preview-and-discard')
            click(s, ipc, 'bar.widget.workspaces')
            # A selected radio receives focus; Up chooses Medium from Large.
            menu_click(s, ipc, 'bar.workspace.mode.large')
            keys(s, 'Up'); menu_closed(s, ipc); ready(s, ipc)
            assert json.loads(peer.document())['bar']['workspace_mode'] == 'medium'
            click(s, ipc, 'apply'); ready(s, ipc)
            wait_for(lambda: not peer.state()['dirty'] and not peer.state()['busy'])
            assert json.loads(path.read_text())['bar']['workspace_mode'] == 'medium'
            wait_for(lambda: live_mode() == 'medium')
            app.stop(); clean(app)
            app=s.child('settings-workspace-reopened',[args.settings,'--page','bar'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created'); ready(s,ipc)
            click(s, ipc, 'bar.widget.workspaces')
            assert mode_control('medium')['selected']
            external=copy.deepcopy(baseline); external['bar']['workspace_mode']='small'
            keep(json.dumps(external))
            menu_click(s, ipc, 'bar.workspace.mode.large')
            assert json.loads(peer.document()) == external
            assert mode_control('medium')['selected']  # Rejected choice was restored.
            keys(s, 'Escape'); menu_closed(s, ipc)
            keep(json.dumps(baseline)); assert peer.action('apply')['state'] == 'succeeded'; ready(s, ipc)
            disk=path.read_bytes()
            wait_for(lambda: live_mode() == 'large')
            passed('workspace-keyboard-apply-reopen-and-stale-mode-rejection')
            choose(s,ipc,'left','Editor fixture','plugin:editor.fixture/main')
            wait_for(lambda:'plugin:editor.fixture/main' in json.loads(peer.document())['bar']['groups']['left'])
            action(s,ipc,'plugin:editor.fixture/main','remove')
            wait_for(lambda:'plugin:editor.fixture/main' not in json.loads(peer.document())['bar']['groups']['left'])
            assert json.loads(peer.document())['plugins']==baseline['plugins']
            click(s,ipc,'discard');ready(s,ipc)
            click(s,ipc,'bar.add.left');type_text(s,'Editor fixture')
            manifest['version']='2';(package/'plugin.json').write_text(json.dumps(manifest))
            wait_for(lambda:next(x for x in ctl(s,args.ctl,'plugins','list')['result']['packages'] if x['id']=='editor.fixture')['digest'] != baseline['plugins']['entries'][0]['digest'])
            # Wait for the page snapshot to observe the replacement package.
            time.sleep(.8)
            menu_click(s,ipc,'bar.pick.plugin:editor.fixture/main')
            assert not peer.state()['dirty']
            keys(s,'Escape');menu_closed(s,ipc)
            passed('plugin-catalog-placement-and-refresh-revalidate-approval')

            click(s,ipc,'bar.add.right')
            wait_for(lambda:any(c['field']=='bar.picker.search' for c in probe(s,ipc)['controls']))
            type_text(s,'Clock')
            used=next(c for c in probe(s,ipc)['controls'] if c['field']=='bar.pick.clock')
            assert not used['enabled']
            type_text(s,'Bluetooth')
            capture(s,'bar-editor-picker',output['name'])
            menu_click(s,ipc,'bar.pick.bluetooth');menu_closed(s,ipc)
            wait_for(lambda:'bluetooth' in json.loads(peer.document())['bar']['groups']['right'])
            assert path.read_bytes()==disk
            passed('native-picker-search-add-and-duplicate-prevention')
            click(s,ipc,'bar.widget.launcher')
            assert not next(c for c in probe(s,ipc)['controls'] if c['field']=='bar.action.remove')['enabled']
            assert not next(c for c in probe(s,ipc)['controls'] if c['field']=='bar.action.earlier')['enabled']
            capture(s,'bar-editor-required-actions',output['name'])
            menu_click(s,ipc,'bar.action.move.center');menu_closed(s,ipc)
            wait_for(lambda:json.loads(peer.document())['bar']['groups']['center'].endswith(',launcher'))
            assert peer.state()['valid']
            action(s,ipc,'clock','move.right')
            wait_for(lambda:json.loads(peer.document())['bar']['groups']['right'].endswith(',clock'))
            action(s,ipc,'clock','earlier')
            wait_for(lambda:json.loads(peer.document())['bar']['groups']['right'].endswith(',clock,bluetooth'))
            passed('launcher-protection-and-atomic-move-reorder')
            action(s,ipc,'bluetooth','remove')
            wait_for(lambda:'bluetooth' not in json.loads(peer.document())['bar']['groups']['right'])
            candidate=json.loads(peer.document())
            assert candidate['outputs']==baseline['outputs']
            for key in baseline:
                if key!='bar':assert candidate[key]==baseline[key],key
            assert 'plugin:missing/main' in candidate['bar']['groups']['center']
            request(s,ipc,page='appearance');ready(s,ipc)
            request(s,ipc,page='bar');ready(s,ipc)
            assert json.loads(peer.document())==candidate
            passed('remove-and-navigation-preserve-unrelated-shared-draft')
            click(s,ipc,'discard');ready(s,ipc)
            wait_for(lambda:not peer.state()['dirty'])
            assert json.loads(peer.document())==baseline
            choose(s,ipc,'left','Running applications','running_apps')
            wait_for(lambda:'running_apps' in json.loads(peer.document())['bar']['groups']['left'])
            action(s,ipc,'running_apps','move.center')
            action(s,ipc,'running_apps','earlier')
            action(s,ipc,'running_apps','remove')
            click(s,ipc,'discard');ready(s,ipc)
            choose(s,ipc,'left','Running applications','running_apps')
            passed('running-apps-picker-move-reorder-remove-and-discard')
            choose(s,ipc,'center','Bluetooth','bluetooth')
            wait_for(lambda:'bluetooth' in json.loads(peer.document())['bar']['groups']['center'])
            click(s,ipc,'apply');ready(s,ipc)
            wait_for(lambda:not peer.state()['dirty'] and not peer.state()['busy'])
            committed=json.loads(path.read_text())
            assert committed['bar']['groups']['center'].endswith(',bluetooth')
            assert 'running_apps' in committed['bar']['groups']['left']
            app.stop();clean(app)
            app=s.child('settings-reopened',[args.settings,'--page','bar'],G_DEBUG='fatal-warnings')
            app.expect('event=settings-window-created');ready(s,ipc)
            assert 'bar.widget.bluetooth' in {c['field'] for c in probe(s,ipc)['controls']}
            assert 'bar.widget.running_apps' in {c['field'] for c in probe(s,ipc)['controls']}
            passed('discard-apply-and-reopen-persist-selections')
            click(s,ipc,'bar.widget.clock')
            external=copy.deepcopy(committed);external['bar']['groups']['center']='plugin:missing/main,bluetooth'
            external['bar']['groups']['left'] += ',clock'
            keep(json.dumps(external))
            ready(s,ipc)
            menu_click(s,ipc,'bar.action.move.right')
            assert json.loads(peer.document())==external
            keys(s,'Escape');menu_closed(s,ipc)
            passed('stale-menu-cannot-overwrite-a-newer-layout')
            keep('{"bar":');ready(s,ipc)
            assert not probe(s,ipc)['editor']['can_apply']
            assert not next(c for c in probe(s,ipc)['controls'] if c['field']=='bar.add.left')['enabled']
            assert peer.document()=='{"bar":'
            click(s,ipc,'bar.repair');wait_for(lambda:probe(s,ipc)['page']=='advanced')
            assert peer.document()=='{"bar":'
            request(s,ipc,page='bar');ready(s,ipc)
            peer.action('discard');ready(s,ipc)
            passed('invalid-advanced-draft-is-retained-and-structured-edits-disabled')
            click(s,ipc,'bar.add.center');keys(s,'Escape');menu_closed(s,ipc)
            assert not peer.state()['dirty']
            assert next(c for c in probe(s,ipc)['controls'] if c['field']=='bar.add.center')['focused']
            passed('keyboard-escape-restores-focus-without-editing')
            for edge in ('left','right','bottom','top'):
                value=copy.deepcopy(committed);value['bar'].update(edge=edge,size=63,islands=False)
                keep(json.dumps(value));ready(s,ipc)
                wait_for(lambda:('Top · ' if edge in ('left','right') else 'Left · ') in '\n'.join(probe(s,ipc)['bar_groups']))
                assert peer.state()['valid']
            peer.action('discard');ready(s,ipc)
            passed('all-edge-labels-and-exact-size-roundtrip')
            for variant,font,width,height in [('dark',14,560,800),('light',20,560,900),('light',14,390,850)]:
                value=copy.deepcopy(committed);value['theme']['variant']=variant;value['font_size']=font
                keep(json.dumps(value));assert peer.action('apply')['state']=='succeeded';ready(s,ipc)
                resize(s,rules,width,height)
                time.sleep(.6)
                current=probe(s,ipc)
                body=current['body_bounds']
                assert all(c['bounds']['x'] >= body['x']-1 and c['bounds']['x']+c['bounds']['width'] <= body['x']+body['width']+1 for c in current['controls'] if c['field'].startswith('bar.') and c['bounds']),current
                click(s,ipc,'bar.add.left');type_text(s,'Overview')
                menu_click(s,ipc,'bar.pick.overview');menu_closed(s,ipc)
                wait_for(lambda:'overview' in json.loads(peer.document())['bar']['groups']['left'])
                click(s,ipc,'discard');ready(s,ipc)
                capture(s,f'bar-editor-{variant}-{font}-{width}',output['name'])
                click(s,ipc,'bar.widget.workspaces')
                capture(s,f'workspace-menu-{variant}-{font}-{width}',output['name'])
                menu_click(s,ipc,'bar.workspace.mode.small');menu_closed(s,ipc);ready(s,ipc)
                assert json.loads(peer.document())['bar']['workspace_mode']=='small'
                click(s,ipc,'discard');ready(s,ipc)
            passed('narrow-light-dark-and-large-text-menus')
            app.stop();clean(app);peer.close();ipc.close()
            ctl(s,args.ctl,'quit');clean(shell)
        report['status']='passed'
    except Exception as error:
        report.update(status='failed',error=str(error));raise
    finally:
        (args.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
