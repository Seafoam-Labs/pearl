#!/usr/bin/env python3
"""S5 staged desktop/CLI launch, package identity and compact flyout handoff."""
import argparse, hashlib, json, os, shutil, subprocess, tempfile, time
from pathlib import Path
from types import SimpleNamespace
from test_settings_app import ROOT, APP_ID, PrivateSession, IPC, wait_for, ctl, status, clean, windows, probe, keys, capture
from t00 import Session as T00Session


def close_window(s, ipc):
    for win in windows(ipc):
        ipc.call('command',action='window.close',fields=dict(id=win['id']))
    wait_for(lambda:not windows(ipc))
    time.sleep(.3)


def handoff(s, binary):
    # Use real keyboard input through the flyout's exclusive focus, never a test action.
    for _ in range(150):
        v=ctl(s,binary,'aqueous','status','--text','test-settings-page')['result']
        if v['button']=='Open full settings':
            keys(s,'Return');return
        keys(s,'Tab')
    raise AssertionError('handoff button was not reachable')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('pearl','production-pearl','ctl','settings','production-settings','spike','locker'):
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s5/integration')
    args=p.parse_args()
    for key,value in vars(args).items():setattr(args,key,value.resolve())
    args.output.mkdir(parents=True,exist_ok=True);checks={};report=dict(status='running',checks=checks,binary_sha256={name:hashlib.sha256(getattr(args,name).read_bytes()).hexdigest() for name in ('production_pearl','production_settings','ctl')})
    try:
      with tempfile.TemporaryDirectory(prefix='pearl-settings-stage-') as temp:
        root=Path(temp);source=root/'binaries';source.mkdir();stage=root/'installed tree'
        for src,name in [(args.production_pearl,'pearl'),(args.ctl,'pearlctl'),(args.production_settings,'pearl-settings'),(args.locker,'pearl-lock')]:shutil.copy2(src,source/name)
        subprocess.run(['bash',ROOT/'packaging/install.sh'],env=dict(os.environ,DESTDIR=str(stage),PEARL_BINARY_DIR=str(source)),check=True)
        bindir=stage/'usr/bin';shellbin=bindir/'pearl';ctlbin=bindir/'pearlctl';settings=bindir/'pearl-settings'
        desktop=stage/'usr/share/applications'/f'{APP_ID}.desktop'
        validation=subprocess.run(['desktop-file-validate',desktop],text=True,capture_output=True)
        # Preserve Aqueous's existing desktop filter. desktop-file-utils does not
        # register this compositor yet; no other validation error is permitted.
        if validation.returncode:
            lines=validation.stdout.strip().splitlines()
            assert len(lines)==3 and all('key "OnlyShowIn"' in line and any(f'unregistered value "{name}"' in line for name in ('Aqueous','Aqueous-Git','Aqueous-Intel-Git')) for line in lines),validation.stdout+validation.stderr
        (args.output/'desktop-validation.txt').write_text(validation.stdout+validation.stderr)
        assert 'Exec=pearl-settings\n' in desktop.read_text()
        assert (stage/'usr/share/icons/hicolor/scalable/apps'/f'{APP_ID}.svg').is_file()
        assert (stage/'usr/share/metainfo'/f'{APP_ID}.metainfo.xml').is_file()
        with PrivateSession(args.output/'session',tool_prefix=ROOT/'.cache/aqueous-activity-production') as s:
          s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
          s.env['PATH']=str(bindir)+os.pathsep+s.env['PATH']
          s.env['XDG_DATA_DIRS']=str(stage/'usr/share')+os.pathsep+s.env.get('XDG_DATA_DIRS','/usr/local/share:/usr/share')
          s.env['GSETTINGS_BACKEND']='memory'
          ipc=IPC(s)
          shell=s.child('pearl',[shellbin],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
          output=status(s,ctlbin)['outputs'][0]
          s.run(['wlr-randr','--output',output['connector'],'--custom-mode','1600x1100@60Hz'])
          (Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml').write_text('[[window]]\napp_id = "'+APP_ID+'"\nfloating = true\nwidth = 1040\nheight = 760\n')
          # Production desktop entry creates the matching normal xdg window.
          ctl(s,ctlbin,'launcher','show');time.sleep(.3)
          # Select the staged identity even when a host -git package shares its name.
          s.run(['wtype',f'{APP_ID}.desktop']);time.sleep(.5);keys(s,'Return')
          wait_for(lambda:len(windows(ipc))==1,20)
          assert windows(ipc)[0]['can_minimize'] and windows(ipc)[0]['can_maximize']
          ctl(s,ctlbin,'dock','pin','--text',f'{APP_ID}.desktop')
          wait_for(lambda:f'{APP_ID}.desktop' in ctl(s,ctlbin,'preferences','status')['result']['preferences']['pinned_apps'])
          time.sleep(.75)
          capture(s,'desktop-launched-settings',output['connector'])
          close_window(s,ipc)
          ctl(s,ctlbin,'settings','show','--page','sound');wait_for(lambda:len(windows(ipc))==1,20)
          close_window(s,ipc)
          checks['staged-production-desktop-normal-window-identity-and-dock-pin']=True
          shell.stop();clean(shell);shellbin.unlink();shutil.copy2(args.pearl,shellbin)
          shell=s.child('pearl-instrumented',[shellbin],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
          # Instrumentation exposes read-only route/geometry for exact assertions.
          settings.unlink();shutil.copy2(args.settings,settings)
          ctl(s,ctlbin,'settings','show');wait_for(lambda:len(windows(ipc))==1,20)
          wait_for(lambda:probe(s,ipc)['connected']);first=probe(s,ipc)['pid']
          assert probe(s,ipc)['page']=='overview'
          for page in ('appearance','network','bluetooth','sound','power','bar','notifications','session','advanced'):
            ctl(s,ctlbin,'settings','show','--page',page)
            wait_for(lambda:probe(s,ipc)['page']==page)
            assert probe(s,ipc)['pid']==first and len(windows(ipc))==1
          ctl(s,ctlbin,'aqueous','show','--text','layouts');wait_for(lambda:probe(s,ipc)['section']=='layouts')
          ctl(s,ctlbin,'aqueous','show','--section','input');wait_for(lambda:probe(s,ipc)['section']=='input')
          ctl(s,ctlbin,'settings','show','--page','aqueous','--section','displays');wait_for(lambda:probe(s,ipc)['section']=='displays')
          ctl(s,ctlbin,'control-center','show','--page','sound')
          ctl(s,ctlbin,'settings','show','--page','aqueous','--section','displays')
          wait_for(lambda:status(s,ctlbin)['popup'] is None)
          checks['cli-default-explicit-pages-repeated-activation-and-aqueous-compatibility']=True
          for invalid in [('settings','show','--page','unknown'),('settings','show','--page','sound','--section','input'),('aqueous','show','--text','unknown')]:
            assert s.run([ctlbin,*invalid],check=False).returncode==2
            assert probe(s,ipc)['page']=='aqueous' and probe(s,ipc)['section']=='displays'
          ctl(s,ctlbin,'settings','show','--output','unknown-output',code=4)
          assert probe(s,ipc)['section']=='displays'
          checks['invalid-page-section-output-do-not-change-visible-state']=True
          # All compact routes hand off their own destination and release popup input.
          for page in ('overview','network','bluetooth','sound','power'):
            previous_activation=probe(s,ipc)['activation_contexts']
            ipc.call('command',action='window.minimized',fields=dict(id=windows(ipc)[0]['id'],value=True))
            wait_for(lambda:windows(ipc)[0]['minimized'])
            ctl(s,ctlbin,'control-center','show','--page',page)
            assert status(s,ctlbin)['popup']['page']==page
            handoff(s,ctlbin)
            wait_for(lambda:status(s,ctlbin)['popup'] is None)
            wait_for(lambda:probe(s,ipc)['page']==page)
            wait_for(lambda:probe(s,ipc)['activation_contexts']>previous_activation)
            wait_for(lambda:not windows(ipc)[0]['minimized'] and probe(s,ipc)['active'])
            assert probe(s,ipc)['pid']==first
          checks['five-flyout-handoffs-carry-route-and-dismiss-after-accepted-launch']=True
          close_window(s,ipc)
          ctl(s,ctlbin,'settings','show','--page','appearance');wait_for(lambda:len(windows(ipc))==1,20)
          wait_for(lambda:probe(s,ipc)['page']=='appearance');assert probe(s,ipc)['pid']!=first
          close_window(s,ipc)
          checks['close-and-second-process-restart']=True
          # Missing on open: disabled with explanation, all compact controls remain.
          saved=bindir/'saved-settings';settings.rename(saved)
          ctl(s,ctlbin,'control-center','show','--page','sound')
          state=ctl(s,ctlbin,'aqueous','status','--text','test-settings-page')['result']
          assert not state['handoff_available'] and 'not installed' in state['handoff_error']
          assert ctl(s,ctlbin,'settings','show',code=4)['err']['code']=='SettingsNotInstalled'
          assert status(s,ctlbin)['popup']['page']=='sound'
          ctl(s,ctlbin,'popup','hide');saved.rename(settings)
          # Removed after open: button remains usable and explains dispatch failure.
          ctl(s,ctlbin,'control-center','show','--page','network');settings.rename(saved)
          handoff(s,ctlbin)
          state=ctl(s,ctlbin,'aqueous','status','--text','test-settings-page')['result']
          assert 'not installed' in state['handoff_error'] and state['page']=='network'
          capture(s,'handoff-missing-retains-flyout',output['connector'])
          ctl(s,ctlbin,'popup','hide');saved.rename(settings)
          settings.rename(saved);settings.write_bytes(b'not-an-executable\x00');settings.chmod(0o755)
          ctl(s,ctlbin,'control-center','show','--page','power');handoff(s,ctlbin)
          state=ctl(s,ctlbin,'aqueous','status','--text','test-settings-page')['result']
          assert 'could not be started' in state['handoff_error'] and state['page']=='power'
          assert ctl(s,ctlbin,'settings','show',code=4)['err']['code']=='SettingsLaunchFailed'
          settings.unlink();saved.rename(settings);ctl(s,ctlbin,'popup','hide')
          checks['absent-removed-and-invalid-executable-leave-usable-flyout-with-feedback']=True
          ctl(s,ctlbin,'settings','show');wait_for(lambda:len(windows(ipc))==1,20)
          wait_for(lambda:probe(s,ipc)['connected'])
          surviving_pid=probe(s,ipc)['pid']
          # Fixture stop() kills the whole process group; quit just the backend,
          # matching the installed service's KillMode=process contract.
          ctl(s,ctlbin,'quit');clean(shell)
          wait_for(lambda:not probe(s,ipc)['connected'])
          assert probe(s,ipc)['pid']==surviving_pid and len(windows(ipc))==1
          close_window(s,ipc)
          checks['spawned-frontend-survives-backend-exit']=True
          # Exercise the actual Git package() function against a private staging root.
          # The Pearl packages also carry the standalone Phyto build.
          subprocess.run(['zig','build','-Doptimize=ReleaseSafe','-Dcpu=baseline'],cwd=ROOT/'subprojects/phyto',check=True)
          git_source=root/'git-source';git_source.mkdir();(git_source/'pearl').symlink_to(ROOT)
          git_stage=root/'git-stage'
          subprocess.run(['bash','-c','source "$1"; srcdir="$2"; pkgdir="$3"; export PEARL_BINARY_DIR="$4"; package','stage',str(ROOT/'packaging/arch-git/PKGBUILD'),str(git_source),str(git_stage),str(source)],check=True)
          git_bin=git_stage/'usr/bin'
          git_id='org.aqueous.Pearl.Git.Settings'
          git_desktop=(git_stage/'usr/share/applications'/f'{git_id}.desktop').read_text()
          assert 'Exec=pearl-settings-git\n' in git_desktop and f'Icon={git_id}\n' in git_desktop and f'StartupWMClass={git_id}\n' in git_desktop
          assert (git_stage/'usr/share/icons/hicolor/scalable/apps'/f'{git_id}.svg').is_file()
          assert f'<binary>pearl-settings-git</binary>' in (git_stage/'usr/share/metainfo'/f'{git_id}.metainfo.xml').read_text()
          s.env['PATH']=str(git_bin)+os.pathsep+s.env['PATH']
          s.env['XDG_CURRENT_DESKTOP']='Aqueous-Git'
          shell=s.child('pearl-git',[git_bin/'pearl-git'],G_DEBUG='fatal-warnings');shell.expect('event=control-ready')
          ctl(s,git_bin/'pearlctl-git','settings','show','--page','sound')
          git_windows=lambda:[w for w in ipc.state() if w['kind']=='window' and w.get('app_id')=='org.aqueous.Pearl.Git.Settings']
          wait_for(lambda:len(git_windows())==1,20)
          assert not windows(ipc)
          ipc.call('command',action='window.close',fields=dict(id=git_windows()[0]['id']));wait_for(lambda:not git_windows())
          checks['git-package-matching-executable-and-window-identity']=True
          shell.stop();clean(shell)
        report['status']='passed'
    except Exception as error:report.update(status='failed',error=repr(error));raise
    finally:(args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
