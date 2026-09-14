#!/usr/bin/env python3
"""T16 staged production install and offline DMS migration/rollback."""
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession
from t00 import Session as T00Session
from test_surfaces import ctl,clean
from test_preferences import settled

def run(argv, *, env=None, code=0):
    p=subprocess.run(list(map(str,argv)),env=env,text=True,capture_output=True,timeout=30)
    assert p.returncode==code,(argv,p.returncode,p.stdout,p.stderr)
    return p.stdout

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('pearl','ctl','locker'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/t16/install');a=p.parse_args()
    a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
    checks={};report={'status':'running','checks':checks,'binary_sha256':{n:hashlib.sha256(getattr(a,n).read_bytes()).hexdigest() for n in ('pearl','ctl','locker')}}
    try:
        with tempfile.TemporaryDirectory(prefix='pearl-release-') as temp:
            root=Path(temp);stage=root/'stage';binaries=root/'bin';binaries.mkdir()
            for source,name in ((a.pearl,'pearl'),(a.ctl,'pearlctl'),(a.locker,'pearl-lock')):shutil.copy2(source,binaries/name)
            run(['bash',ROOT/'packaging/install.sh'],env=dict(os.environ,DESTDIR=str(stage),PEARL_BINARY_DIR=str(binaries)))
            installed=stage/'usr/bin';pearl=installed/'pearl';control=installed/'pearlctl'
            assert sorted(x.name for x in installed.iterdir())==['pearl','pearl-lock','pearlctl']
            version=json.loads((ROOT/'packaging/release.json').read_text())['version']
            for binary in installed.iterdir():
                assert version in run([binary,'--version'])
                assert binary.stat().st_mode&0o7777==0o755
            assert (stage/'etc/pam.d/pearl').read_bytes()==(ROOT/'packaging/pam.d/pearl').read_bytes()
            for notice in (ROOT/'bindings/licenses').iterdir():assert (stage/'usr/share/licenses/pearl'/notice.name).read_bytes()==notice.read_bytes()
            assert (stage/'usr/share/applications/org.aqueous.Pearl.Settings.desktop').is_file()
            assert (stage/'usr/share/pearl/release.json').is_file()
            assert not list(stage.rglob('*.wants'))
            unit=(stage/'usr/lib/systemd/user/pearl.service').read_text()
            for field in ('KillMode=process','PartOf=graphical-session.target','Requisite=graphical-session.target','ConditionEnvironment=AQUEOUS_SOCKET','ConditionEnvironment=!AQUEOUS_NESTED=1','ExecCondition=/usr/bin/pearl --check-environment'):assert field in unit
            # Never exercise this guard by invoking the installer against host /.
            installer=(ROOT/'packaging/install.sh').read_text()
            assert 'realpath -m -- "$destination") != /' in installer and 'DESTDIR:?' in installer
            elf=run(['readelf','-d',pearl]);(a.output/'elf-dynamic.txt').write_text(elf)
            assert elf.index('libgtk4-layer-shell')<elf.index('libgtk-4.so')
            checks['staged-production-files-permissions-link-order-and-session-unit']=True
            with PrivateSession(a.output/'session') as s:
                s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
                assert 'valid' in run([pearl,'--check-environment'],env=s.env)
                run([pearl,'--check-environment'],env=dict(s.env,AQUEOUS_SOCKET=str(s.base/'missing.sock')),code=2)
                app=s.child('installed-pearl',[pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
                before=settled(s,control);base=root/'base.json';base.write_text(json.dumps(before['preferences']))
                source=root/'settings.json';source.write_text(json.dumps({'configVersion':18,'fontScale':1.25,'reduceMotion':True,'showDock':False,'unknownPlugin':{'secret':'not included in report'},'barConfigs':[{'enabled':True,'position':1,'screenPreferences':['all'],'leftWidgets':['launcherButton','workspaceSwitcher'],'centerWidgets':['clock'],'rightWidgets':['weather','controlCenterButton']}]}))
                session=root/'session.json';session.write_text(json.dumps({'configVersion':4,'isLightMode':True}))
                original=source.read_bytes();bundle=root/'bundle'
                command=[control,'migrate','dms','--input',source,'--session-file',session,'--base',base]
                dry=json.loads(run(command,env=s.env));assert dry['dry_run'] and dry['preferences']['bar']['edge']=='bottom'
                assert 'unknownPlugin' in str(dry['unsupported']) and 'not included in report' not in json.dumps(dry)
                assert settled(s,control)['revision']==before['revision'] and not bundle.exists()
                run(command+['--bundle',bundle],env=s.env)
                assert (bundle/'previous.json').read_bytes()==base.read_bytes()
                assert bundle.stat().st_mode&0o777==0o700
                for file in bundle.iterdir():assert file.stat().st_mode&0o777==0o600
                run(command+['--bundle',bundle],env=s.env,code=2)
                ctl(s,control,'preferences','apply','--revision',str(before['revision']),'--file',str(bundle/'preferences.json'))
                current=settled(s,control);assert current['err'] is None and current['preferences']['bar']['edge']=='bottom' and current['preferences']['font_size']==18,current
                ctl(s,control,'preferences','apply','--revision',str(before['revision']),'--file',str(bundle/'previous.json'),code=4)
                ctl(s,control,'preferences','apply','--revision',str(current['revision']),'--file',str(bundle/'previous.json'))
                restored=settled(s,control);assert restored['err'] is None and restored['preferences']==before['preferences']
                assert source.read_bytes()==original
                link=root/'link';link.symlink_to(source);fifo=root/'fifo';os.mkfifo(fifo);large=root/'large';large.write_bytes(b' '*65537)
                for invalid in (link,fifo,large):run([control,'migrate','dms','--input',invalid],env=s.env,code=2)
                ctl(s,control,'quit');clean(app)
                app=s.child('restored-pearl',[pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
                assert settled(s,control)['preferences']==before['preferences']
                ctl(s,control,'quit');clean(app)
                checks['installed-startup-dry-run-private-bundle-explicit-apply-conflict-rollback-restart-and-bounds']=True
        report['status']='passed'
    except Exception as error:
        report.update(status='failed',error=str(error));raise
    finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
