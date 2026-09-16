#!/usr/bin/env python3
"""Real QtEngine + Darkly consumers, shared JSON ownership and qtct migration."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--libraries', type=Path)
    parser.add_argument('--engine-prefix', type=Path)
    parser.add_argument('--quick-compatibility', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/qtengine/latest')
    args = parser.parse_args()
    args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    checks = []; reports = []; quick_reports = []; live_updates = {}
    with tempfile.TemporaryDirectory(prefix='pearl-qtengine-') as temp, ExitStack() as cleanup:
        base = Path(temp); config = base/'config'; config.mkdir()
        runtime = base/'runtime'; runtime.mkdir(mode=0o700)
        env = {k: os.environ[k] for k in ('PATH', 'LANG') if k in os.environ}
        env.update(HOME=str(base), XDG_CONFIG_HOME=str(config), XDG_CACHE_HOME=str(base/'cache'), XDG_DATA_HOME=str(base/'data'), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='qtengine', QT_QUICK_BACKEND='software')
        libraries = [str(args.libraries.resolve())] if args.libraries else []
        if args.engine_prefix:
            prefix = args.engine_prefix.resolve()
            libraries.insert(0, str(prefix/'lib'))
            env['QT_PLUGIN_PATH'] = ':'.join(str(prefix/f'lib/{q}/plugins') for q in ('qt','qt6'))
        if libraries: env['LD_LIBRARY_PATH'] = ':'.join(libraries)
        bus = subprocess.Popen(['dbus-daemon','--session','--nofork','--print-address=1'], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        cleanup.callback(lambda: (bus.terminate(), bus.wait(timeout=5)))
        env['DBUS_SESSION_BUS_ADDRESS'] = bus.stdout.readline().strip()
        assert env['DBUS_SESSION_BUS_ADDRESS']
        driver = base/'driver'; shutil.copy2(args.driver, driver)
        for version in (5,6):
            shutil.copy2(ROOT/f'zig-out/bin/pearl-qt{version}-probe', base)
            subprocess.run(['python3',str(ROOT/'scripts/build-qt-probe.py'),'--qt',str(version),'--source',str(ROOT/'tests/fixtures/qt_theme.cpp'),'--output',str(base/f'qt{version}')],check=True,capture_output=True)
        def apply(p, **extra):
            (config/'preferences.json').write_text(json.dumps(p))
            result = subprocess.run([str(driver)],env={**env, **extra},capture_output=True,text=True,timeout=15)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        def consume(version, **extra):
            result = subprocess.run([str(base/f'qt{version}')],env={**env, **extra},capture_output=True,text=True,timeout=10)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        def review():
            result = subprocess.run([str(driver)],env={**env,'PEARL_QT_TEST_REVIEW':'1'},capture_output=True,text=True,check=True)
            return json.loads(result.stdout)
        def reapply(digest):
            return subprocess.run([str(driver)],env={**env,'PEARL_QT_TEST_REAPPLY':digest},capture_output=True,text=True)
        assert apply({})['engine']['state']=='disabled' and not (config/'pearl/qt').exists()
        checks.append('disabled-no-writes')
        engine_dir = config/'qtengine'; engine_dir.mkdir(); path = engine_dir/'config.json'
        original = {'theme':{'style':'Fusion','font':{'family':'DejaVu Sans','size':10,'weight':600}},'misc':{'singleClickActivate':False},'custom':['preserve',42]}
        path.write_text(json.dumps(original))
        (config/'darklyrc').write_text('# Keep\n[Common]\nCornerRadius=7\n')
        p={'qt':{'enabled':True,'darkly':{'corner_radius':12}},'font_size':14}
        status=apply(p)
        assert status['qt5']['state']==status['qt6']['state']==status['engine']['state']=='applied',status
        state_dir=config/'pearl/qt'; marker=state_dir/'session.conf'
        assert marker.read_text()=='QT_QPA_PLATFORMTHEME=qtengine\n'
        assert not (config/'qt5ct').exists() and not (config/'qt6ct').exists()
        for version in (5,6):
            report=consume(version); reports.append(report)
            assert report['style']=='qtengine',report
            assert 'darkly' in (report['base_class']+report['base_style']).lower(),report
            assert report['palette']['0'][10]=='#ff141218' and report['palette']['0'][12]=='#ffd0bcff',report
            assert report['point_size']==11 and report['font'].startswith('DejaVu Sans,'),report
        checks.append('qt5-qt6-real-engine-darkly-palette-font')
        observed=json.loads(path.read_text()); assert observed['misc']==original['misc'] and observed['custom']==original['custom']
        assert observed['theme']['font']['weight']==600
        tracked=[path,*state_dir.glob('*.json'),*state_dir.glob('*.colors')]
        before={str(x):x.stat().st_mtime_ns for x in tracked}; apply(p)
        assert before=={str(x):x.stat().st_mtime_ns for x in tracked}
        checks.append('json-preservation-and-idempotence')
        startup=ROOT/'packaging/qt-environment.sh'
        def startup_value(**extra):
            return subprocess.check_output(['sh','-c','. "$1"; printf "%s" "${QT_QPA_PLATFORMTHEME:-}"','test',str(startup)],env={**env,'QT_QPA_PLATFORMTHEME':'',**extra},text=True)
        assert startup_value()=='qtengine' and startup_value(AQUEOUS_NESTED='1')==''
        assert startup_value(QT_QPA_PLATFORMTHEME='kde')=='kde'
        assert startup_value(QT_QPA_PLATFORMTHEME='qt5ct')=='qtengine'
        marker.write_text('$(touch '+str(base/'executed')+')\n')
        assert startup_value()=='' and not (base/'executed').exists()
        marker.write_text('QT_QPA_PLATFORMTHEME=qtengine\n')
        checks.append('fixed-marker-nested-and-override')
        if args.quick_compatibility:
            flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','Qt6QuickControls2','Qt6Quick','Qt6Qml'],text=True))
            subprocess.run(['c++','-std=c++17','-fPIC',str(ROOT/'tests/fixtures/qt_quick_theme.cpp'),'-o',str(base/'quick'),*flags],check=True,capture_output=True)
            for options in ([],['--kirigami']):
                result=subprocess.run([str(base/'quick'),*options],env={**env,'QT_QUICK_CONTROLS_STYLE':'Fusion'},capture_output=True,text=True,check=True,timeout=10)
                report=json.loads(result.stdout); quick_reports.append(report)
                assert report['pearlWindow']=='#141218' and report['pearlHighlight']=='#d0bcff',report
            checks.append('quick-kirigami-pearl-palette')
        watchers=[]
        try:
            for version in (5,6):
                output=base/f'live-{version}.json'
                process=subprocess.Popen([str(base/f'qt{version}'),'--watch'],env={**env,'PEARL_QT_REPORT':str(output)},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                watchers.append((version,process,output))
            time.sleep(.6)
            p['theme']={'variant':'light'}; assert apply(p)['engine']['state']=='applied'
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                for version,_,output in watchers:
                    try: live_updates[str(version)]=json.loads(output.read_text())['palette']['0'][10]=='#fffdf7ff'
                    except (OSError,ValueError): pass
                if len(live_updates)==2 and all(live_updates.values()):break
                time.sleep(.1)
            assert len(live_updates)==2 and all(live_updates.values()),live_updates
        finally:
            for _,process,_ in watchers: process.terminate(); process.wait(timeout=5)
        for version in (5,6): reports.append(consume(version))
        checks.append('both-running-runtimes-update')
        normal=consume(6)['button_height'];p['qt']['darkly']['sync_density']=True;p['density']='compact';apply(p)
        assert consume(6)['button_height']<normal
        for scale in ('1','1.5','2'):
            assert consume(6,QT_SCALE_FACTOR=scale,PEARL_QT_SCREENSHOT=str(args.output/f'qt6-light-{scale}.png'))['point_size']==11
        checks.append('density-and-scaled-point-fonts')
        changed=json.loads(path.read_text());changed['theme']['style']='Fusion';path.write_text(json.dumps(changed))
        assert apply(p)['engine']['state']=='conflict'
        generations=set(state_dir.glob('scheme-*.colors'));p['qt']['palette']='static_dark';apply(p)
        assert set(state_dir.glob('scheme-*.colors'))==generations
        p['qt']['palette']='follow_pearl';p['qt']['enabled']=False
        assert apply(p)['engine']['state']=='restore_incomplete'
        assert json.loads(path.read_text())==original
        assert 'CornerRadius=7' in (config/'darklyrc').read_text()
        checks.append('conflict-gc-and-conditional-restore')
        p['qt']['enabled']=True;apply(p); reviewed=review();assert 'style' in reviewed['text']
        changed=json.loads(path.read_text());changed['new']='external';path.write_text(json.dumps(changed))
        stale=reapply(reviewed['digest']);assert stale.returncode!=0 and 'QtReviewChanged' in stale.stderr
        fixed=reapply(review()['digest']);assert fixed.returncode==0,fixed.stderr
        assert json.loads(fixed.stdout)['engine']['state']=='applied'
        checks.append('reviewed-repair-and-stale-rejection')
        ledger_path=state_dir/'engine.json'; ledger=json.loads(ledger_path.read_text())
        record=next(x for x in ledger['records'] if x['key']=='style')
        record.update(original='"Fusion"',last='"Fusion"',owned=False,pending=True,next='"Darkly"',next_owned=True)
        ledger_path.write_text(json.dumps(ledger));changed=json.loads(path.read_text());changed['theme']['style']='Breeze';path.write_text(json.dumps(changed))
        assert apply(p)['engine']['state']=='conflict'
        fixed=reapply(review()['digest']);assert fixed.returncode==0,fixed.stderr
        assert json.loads(fixed.stdout)['engine']['state']=='applied'
        checks.append('interrupted-acquisition-review')
        # Legacy ownership ledgers are released conditionally; unmanaged qtct keys survive.
        for version in (5,6):
            old_dir=config/f'qt{version}ct';old_dir.mkdir();old=old_dir/f'qt{version}ct.conf'
            old.write_text('[Appearance]\nstyle=Darkly\ncustom=preserve\n')
            (state_dir/f'qt{version}.json').write_text(json.dumps({'version':1,'records':[{'group':'Appearance','key':'style','original':'Fusion','last':'Darkly','owned':True}]}))
        marker.write_text('QT_QPA_PLATFORMTHEME=qt5ct\n');assert startup_value()=='qt5ct'
        status=apply(p);assert status['engine']['state']=='applied'
        for version in (5,6):assert (config/f'qt{version}ct/qt{version}ct.conf').read_text()=='[Appearance]\nstyle=Fusion\ncustom=preserve\n'
        assert marker.read_text()=='QT_QPA_PLATFORMTHEME=qtengine\n'
        checks.append('legacy-qtct-restoration-and-marker-migration')
        legacy_ledger=state_dir/'qt5.json';legacy=json.loads(legacy_ledger.read_text())
        legacy['records'][0].update(owned=True,last='Darkly',pending=False)
        legacy_ledger.write_text(json.dumps(legacy))
        legacy_file=config/'qt5ct/qt5ct.conf';legacy_file.write_text('[Appearance]\nstyle=Breeze\ncustom=preserve\n')
        status=apply(p)
        assert status['engine']['state']=='applied' and status['qt5']['state']=='restore_incomplete',status
        assert 'style=Breeze' in legacy_file.read_text()
        fixed=reapply(review()['digest']);assert fixed.returncode==0,fixed.stderr
        assert 'style=Fusion' in legacy_file.read_text()
        checks.append('legacy-external-edit-preserved-and-reviewed')
        status=apply(p,QTENGINE_CONFIG=str(base/'other.json'));assert status['environment']['error_code']=='QtEngineConfigOverride'
        checks.append('config-override-diagnostic')
        for version in (5,6):(base/f'pearl-qt{version}-probe').write_text('#!/bin/sh\nexit 1\n')
        status=apply(p);assert status['qt5']['state']==status['qt6']['state']=='missing_dependency'
        assert marker.read_text()=='QT_QPA_PLATFORMTHEME=qtengine\n'
        p['qt']['targets']={'qt5':False,'qt6':False};status=apply(p)
        assert status['engine']['state']==status['darkly']['state']==status['kde']['state']=='disabled',status
        assert marker.read_text()==''
        checks.append('dependency-failure-and-all-checks-disabled')
        for version in (5,6):shutil.copy2(ROOT/f'zig-out/bin/pearl-qt{version}-probe',base)
        p['qt']['targets']={'qt5':True,'qt6':True}
        outside=base/'outside';outside.mkdir();sentinel=outside/'config.json';sentinel.write_text('{"sentinel":true}')
        shutil.rmtree(engine_dir);engine_dir.symlink_to(outside,target_is_directory=True)
        assert apply(p)['engine']['state']=='failed' and sentinel.read_text()=='{"sentinel":true}'
        checks.append('parent-symlink-rejection')
        staged=base/'stage'
        subprocess.run(['bash',str(ROOT/'packaging/install.sh')],env={**env,'DESTDIR':str(staged),'PEARL_BINARY_DIR':str(ROOT/'zig-out/bin')},check=True,capture_output=True)
        for version in (5,6): assert os.access(staged/f'usr/lib/pearl/pearl-qt{version}-probe',os.X_OK)
        assert 'libQt' not in subprocess.check_output(['ldd',str(staged/'usr/bin/pearl')],text=True)
        checks.append('staged-probes-and-gtk-only-shell')
    (args.output/'results.json').write_text(json.dumps({'status':'passed','checks':checks,'live_palette_updates':live_updates,'consumers':reports,'quick_compatibility':quick_reports},indent=2)+'\n')
    print(f'QtEngine integration: {len(checks)} groups passed')

if __name__=='__main__':main()
