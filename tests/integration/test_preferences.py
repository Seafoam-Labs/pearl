#!/usr/bin/env python3
"""T10: isolated settings, GTK themes, palettes, wallpaper and ownership."""
import argparse, copy, hashlib, json, os, sys, time
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from test_surfaces import ctl,status,capture,clean
from test_session_services import png,key,focus_target
from types import SimpleNamespace
from t00 import Session as T00Session

def state(s,b): return ctl(s,b,'preferences','status')['result']
def settled(s,b,timeout=20): return wait_for(lambda:(lambda v:v if not v['busy'] else False)(state(s,b)),timeout)
def apply(s,b,p,expected_error=None):
    v=settled(s,b);ctl(s,b,'preferences','apply','--revision',str(v['revision']),'--text',json.dumps(p))
    result=settled(s,b)
    assert result['err']==expected_error,result
    return result

def external(path,p):
    temp=path.with_suffix('.new');temp.write_text(json.dumps(p) if isinstance(p,dict) else p);temp.replace(path)

from compact_editor import open_editor

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl',type=Path,required=True);parser.add_argument('--ctl',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/t10/latest');args=parser.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    checks={};metadata={'status':'running','checks':checks,'pearl_sha256':hashlib.sha256(args.pearl.read_bytes()).hexdigest(),'ctl_sha256':hashlib.sha256(args.ctl.read_bytes()).hexdigest()}
    try:
        with PrivateSession(args.output/'session') as s:
            # The chooser remembers its geometry without requiring a dconf service.
            s.env['GSETTINGS_BACKEND']='memory'
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');keyboard=T00Session.input_fixture(s)
            app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
            v=settled(s,args.ctl);assert v['appearance']==1 and v['err'] is None,v
            path=Path(v['path']);assert not path.exists();assert path.with_name('last-good.json').exists()
            p=v['preferences'];output=status(s,args.ctl)['outputs'][0]
            open_editor(s,args.ctl);time.sleep(.5);capture(s,'settings-static-dark',output['connector'])
            focus_target(s,app,'settings-wallpaper-choose');key(s,'-k','space');time.sleep(.5)
            capture(s,'wallpaper-picker',output['connector'])
            key(s,'-k','Escape')
            assert not state(s,args.ctl)['draft_dirty'] and status(s,args.ctl)['popup']['pane']=='settings'
            image=s.base/'chosen wallpaper.jpg'
            Image.new('RGB',(7680,2160),(171,150,211)).save(image)
            key(s,'-k','space');time.sleep(.5)
            key(s,'-M','ctrl','l','-m','ctrl',str(image));key(s,'-k','Return')
            wait_for(lambda:state(s,args.ctl)['draft_dirty'])
            assert not path.exists(),'Choosing an image must wait for Apply & save'
            focus_target(s,app,'settings-apply');key(s,'-k','space');v=settled(s,args.ctl)
            assert v['err'] is None and v['preferences']['wallpaper']['path']==str(image) and v['preferences']['wallpaper']['mode']=='cover',v
            p=v['preferences'];before=path.read_bytes()
            focus_target(s,app,'settings-wallpaper-choose');key(s,'-k','space');time.sleep(.5);key(s,'-k','Escape')
            assert path.read_bytes()==before and not state(s,args.ctl)['draft_dirty']
            key(s,'-k','space');time.sleep(.5);ctl(s,args.ctl,'popup','hide')
            assert status(s,args.ctl)['popup'] is None and app.proc.poll() is None
            open_editor(s,args.ctl);time.sleep(.3)
            focus_target(s,app,'settings-wallpaper-choose');key(s,'-k','space');time.sleep(.5);key(s,'-k','Escape')
            checks['wallpaper-picker-selection-cancel-save-and-parent-close']=True
            # Every accepted selection switches to Cover, including when the
            # previous image used Contain. Cancelling must preserve each mode.
            for fit in ('solid','cover','contain'):
                p['wallpaper']['mode']=fit;v=apply(s,args.ctl,p);before=path.read_bytes()
                focus_target(s,app,'settings-wallpaper-choose');key(s,'-k','space');time.sleep(.5);key(s,'-k','Escape')
                assert path.read_bytes()==before and not state(s,args.ctl)['draft_dirty']
                key(s,'-k','space');time.sleep(.5)
                key(s,'-M','ctrl','l','-m','ctrl',str(image));key(s,'-k','Return')
                wait_for(lambda:state(s,args.ctl)['draft_dirty'])
                assert path.read_bytes()==before,'Choosing an image must wait for Apply & save'
                focus_target(s,app,'settings-apply');key(s,'-k','space');v=settled(s,args.ctl)
                assert v['err'] is None and v['preferences']['wallpaper']['path']==str(image) and v['preferences']['wallpaper']['mode']=='cover',v
                p=v['preferences']
            checks['wallpaper-picker-sets-cover-from-every-fit-mode']=True
            p['theme']['variant']='light';v=apply(s,args.ctl,p)
            assert json.loads(path.read_text())==p and path.stat().st_mode&0o777==0o600
            assert status(s,args.ctl)['popup']['pane']=='settings';time.sleep(.4);capture(s,'settings-static-light',output['connector'])
            checks['defaults-atomic-save-and-live-popup-theme']=True
            other=next(o for o in status(s,args.ctl)['outputs'] if o['id']!=output['id'])
            ctl(s,args.ctl,'osd','show','--output',other['id'],'--text','Shared theme','--duration','10000')
            p['theme']['variant']='dark';apply(s,args.ctl,p);p['theme']['variant']='light';v=apply(s,args.ctl,p)
            time.sleep(.3);capture(s,'theme-second-output-osd',other['connector'])
            assert status(s,args.ctl)['osd']
            checks['one-theme-updates-bars-popup-wallpaper-and-second-output-osd']=True
            original=copy.deepcopy(p);revision=v['revision']
            external(path,'{invalid');wait_for(lambda:state(s,args.ctl)['err']=='SyntaxError');v=settled(s,args.ctl)
            assert v['preferences']==original and v['revision']>revision
            bad=ctl(s,args.ctl,'preferences','apply','--revision',str(revision),'--text','{}',code=4);assert bad['err']['code']=='Conflict',bad
            checks['corrupt-external-config-and-stale-revision']=True
            external(path,original);wait_for(lambda:state(s,args.ctl)['err'] is None and state(s,args.ctl)['revision']>v['revision']);settled(s,args.ctl)
            p=copy.deepcopy(original);p['wallpaper'].update(mode='cover',path=str(s.base/'missing.png'));v=apply(s,args.ctl,p,'InvalidImage');assert v['preferences']==original
            fifo=s.base/'fifo';os.mkfifo(fifo);p['wallpaper']['path']=str(fifo);apply(s,args.ctl,p,'InvalidFile')
            # An uncompressed portrait PNG exceeds the former 16 MiB file cap,
            # 4096px height cap and 8 Mi-pixel cap independently of JPEG width.
            large=s.base/'large wallpaper.png'
            Image.new('RGB',(2000,5000),(171,150,211)).save(large,compress_level=0)
            assert large.stat().st_size>16*1024*1024
            p['wallpaper']['path']=str(large);v=apply(s,args.ctl,p)
            assert v['preferences']==p
            ctl(s,args.ctl,'popup','hide');time.sleep(.3)
            pixels=capture(s,'large-wallpaper',output['connector'])
            assert pixels.getpixel((10,200))==(171,150,211)
            open_editor(s,args.ctl);time.sleep(.3)
            invalid=s.base/'invalid.png';invalid.write_bytes(b'not an image')
            bad=copy.deepcopy(p);bad['wallpaper']['path']=str(invalid)
            v=apply(s,args.ctl,bad,'InvalidImage');assert v['preferences']==p
            checks['wallpapers-exceed-former-dimension-pixel-and-file-size-caps']=True
            image=s.base/'wallpaper.png';png(image);p['wallpaper']['path']=str(image)
            p['theme'].update(mode='dynamic',source='wallpaper');v=apply(s,args.ctl,p)
            assert v['preferences']==p and not v['cache_hit'];time.sleep(.5);capture(s,'settings-dynamic-wallpaper',output['connector'])
            p['wallpaper']['mode']='contain';v=apply(s,args.ctl,p);assert v['cache_hit'],v
            checks['image-validation-fifo-rejection-and-dynamic-palette-cache']=True
            p['theme'].update(mode='static');p['font']='Pearl Nonexistent Font 9876';apply(s,args.ctl,p)
            checks['missing-font-falls-back']=True
            p['theme'].update(mode='gtk',gtk_name='NotInstalled9876');apply(s,args.ctl,p,'GtkThemeNotInstalled')
            custom=Path(s.env['XDG_DATA_HOME'])/'themes'/'Pearl-Test'/'gtk-4.0';custom.mkdir(parents=True)
            custom.joinpath('gtk.css').write_text('notebook > stack {background:#184a40;color:#ffffdd;} notebook > header {background:#103328;color:#ffffdd;} @define-color theme_bg_color #184a40; @define-color theme_fg_color #ffffdd; .background {background-color:#184a40;color:#ffffdd;} button {background:#664477;color:#fff;border:3px solid #eebbee;border-radius:3px;} entry {background:#fff;color:#121212;}')
            broken=custom.parent.parent/'Pearl-Broken'/'gtk-4.0';broken.mkdir(parents=True);broken.joinpath('gtk.css').write_text('button { background: definitely-not-a-color; }')
            p['theme'].update(mode='gtk',gtk_name='Pearl-Broken');before=path.read_bytes();apply(s,args.ctl,p,'InvalidGtkTheme');assert path.read_bytes()==before
            checks['broken-gtk-css-cannot-replace-working-theme-or-config']=True
            p['theme'].update(mode='gtk',gtk_name='Pearl-Test');p['font']='';p['wallpaper']['mode']='solid';v=apply(s,args.ctl,p)
            time.sleep(.5);capture(s,'settings-gtk-custom',output['connector'])
            pixels=Image.open(s.output/'settings-gtk-custom.png').convert('RGB')
            assert sum(n for n,c in pixels.getcolors(pixels.width*pixels.height) if c==(24,74,64))>10000,'Selected GTK theme did not render'
            p['theme']['gtk_name']='';v=apply(s,args.ctl,p);time.sleep(.5);capture(s,'settings-gtk-system',output['connector'])
            checks['installed-gtk-theme-and-system-follow-without-material-css']=True
            ctl(s,args.ctl,'frame','set','--output',output['id'],'--edge','left','--size','8')
            conflict=copy.deepcopy(p);conflict['bar']['edge']='left';before=path.read_bytes();apply(s,args.ctl,conflict,'EdgeOccupied');assert path.read_bytes()==before
            ctl(s,args.ctl,'frame','set','--output',output['id'],'--edge','left','--size','0')
            checks['bar-reservation-conflict-is-rejected-before-saving']=True
            p['theme'].update(mode='static',variant='dark');p['wallpaper']['mode']='gradient';p['font']='';p['outputs']=[{'connector':output['connector'],'bar':{'edge':'bottom','size':52,'groups':{'left':'launcher,title','center':'clock','right':'control'}}}];p['popup'].update(placement='centered',max_width=600,max_height=640,dismiss_outside=False)
            apply(s,args.ctl,p);wait_for(lambda:status(s,args.ctl)['outputs'][0]['bar_edge']=='bottom');time.sleep(.4);capture(s,'settings-output-policy',output['connector'])
            checks['per-connector-bar-and-popup-policies']=True
            focus_target(s,app,'settings-gtk-name');key(s,'-M','ctrl','a','-m','ctrl','Adwaita')
            assert state(s,args.ctl)['draft_dirty']
            ctl(s,args.ctl,'popup','hide');assert state(s,args.ctl)['draft_dirty']
            before=state(s,args.ctl);p['density']='compact';external(path,p)
            wait_for(lambda:state(s,args.ctl)['revision']>before['revision']);settled(s,args.ctl)
            open_editor(s,args.ctl);time.sleep(.2)
            assert state(s,args.ctl)['draft_revision']<state(s,args.ctl)['revision']
            focus_target(s,app,'settings-merge');key(s,'-k','space')
            assert state(s,args.ctl)['draft_revision']==state(s,args.ctl)['revision']
            focus_target(s,app,'settings-apply');key(s,'-k','space');v=settled(s,args.ctl)
            assert not v['draft_dirty'] and v['preferences']['theme']['gtk_name']=='Adwaita' and v['preferences']['density']=='compact',v
            p=v['preferences'];checks['gtk-draft-survives-close-external-edit-and-three-way-merge']=True
            p['outputs']=[];p['exports']=[{'name':'terminal.conf','template':'background={{surface}}\nforeground={{text}}\n'}];v=apply(s,args.ctl,p)
            export=path.parent/'exports'/'terminal.conf';first=export.read_text();p['theme']['variant']='light';apply(s,args.ctl,p)
            assert export.with_suffix('.conf.bak').read_text()==first
            export.write_text('user-owned edit');v=apply(s,args.ctl,p);assert v['export_error']=='ExportOwnershipConflict' and export.read_text()=='user-owned edit',v
            p['exports']=[];apply(s,args.ctl,p);assert export.read_text()=='user-owned edit'
            checks['opt-in-exports-ownership-backup-and-disable']=True
            before=path.read_bytes();path.parent.chmod(0o500)
            try: apply(s,args.ctl,p,'SaveFailed');assert path.read_bytes()==before
            finally: path.parent.chmod(0o700)
            checks['failed-save-retains-working-file']=True
            external(path,{'version':0,'dark':False});wait_for(lambda:state(s,args.ctl)['preferences']['density']=='normal');v=settled(s,args.ctl)
            assert v['preferences']['version']==1 and v['preferences']['theme']['variant']=='light' and json.loads(path.read_text())['version']==0
            p=v['preferences'];apply(s,args.ctl,p);assert json.loads(path.read_text())['version']==1
            checks['legacy-migration-is-validated-and-only-written-on-apply']=True
            large=copy.deepcopy(p);large['exports']=[{'name':'large.txt','template':'x'*6000}];external(path,large)
            wait_for(lambda:state(s,args.ctl)['preferences_truncated']);v=settled(s,args.ctl);assert v['preferences'] is None and json.loads(path.read_text())==large
            prior=v['appearance'];external(path,p);wait_for(lambda:state(s,args.ctl)['appearance']>prior);settled(s,args.ctl)
            checks['large-preferences-preserved-with-bounded-control-status']=True
            stable=settled(s,args.ctl);time.sleep(1);assert state(s,args.ctl)['jobs']==stable['jobs']
            checks['no-theme-work-at-idle']=True
            ctl(s,args.ctl,'quit');clean(app)
            external(path,'{broken');app=s.child('recovered',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');v=settled(s,args.ctl)
            assert v['recovered'] and v['preferences']==p and path.read_text()=='{broken',v
            checks['restart-uses-last-good-without-overwriting-corruption']=True
            ctl(s,args.ctl,'quit');clean(app)
            invalid=copy.deepcopy(p);invalid['theme'].update(mode='gtk',gtk_name='Pearl-Broken');external(path,invalid)
            app=s.child('css-recovered',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');v=settled(s,args.ctl)
            assert v['recovered'] and v['preferences']==p and v['err']=='InvalidGtkTheme' and json.loads(path.read_text())==invalid,v
            ctl(s,args.ctl,'quit');clean(app)
        with PrivateSession(args.output/'generator') as s:
            mode=s.base/'mode';mode.write_text('pass');calls=s.base/'calls.jsonl';calls.write_text('')
            s.env.update(PATH=str(ROOT/'tests/fixtures/theme')+':'+s.env['PATH'],PEARL_TEST_GENERATOR_MODE=str(mode),PEARL_TEST_GENERATOR_LOG=str(calls))
            app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');v=settled(s,args.ctl)
            p=v['preferences'];v=apply(s,args.ctl,p);path=Path(v['path']);original=path.read_bytes();initial=v['appearance']
            for i,(behavior,error) in enumerate([('fail','GeneratorFailed'),('invalid','InvalidPalette'),('huge','GeneratorOutputTooLarge'),('hang','GeneratorFailed')]):
                mode.write_text(behavior);p['theme'].update(mode='dynamic',seed=f'#{(i+1)*123456:06x}')
                v=apply(s,args.ctl,p,error);assert path.read_bytes()==original and v['appearance']==initial,v
            checks['generator-failure-malformed-output-bounds-and-deadline']=True
            mode.write_text('slow');p['theme']['seed']='#ab12cd';external(path,p)
            wait_for(lambda:any(json.loads(line)['mode']=='slow' for line in calls.read_text().splitlines()))
            start=time.monotonic();mode.write_text('pass');p['theme']['seed']='#aa6633';external(path,p)
            for i in range(20):
                p['theme']['seed']=f'#{0x338800+i:06x}';external(path,p)
            wait_for(lambda:state(s,args.ctl)['preferences']['theme']['seed']==p['theme']['seed'],8)
            v=settled(s,args.ctl);assert time.monotonic()-start<8 and v['appearance']==initial+1,v
            assert len([line for line in calls.read_text().splitlines() if json.loads(line)['mode']=='pass'])==1
            checks['rapid-edits-cancel-obsolete-generator-and-coalesce-latest']=True
            mode.write_text('slow');p['theme']['seed']='#abcdef';prior=len(calls.read_text().splitlines())
            ctl(s,args.ctl,'preferences','apply','--revision',str(v['revision']),'--text',json.dumps(p));wait_for(lambda:len(calls.read_text().splitlines())>prior)
            external(path,{'theme':{'variant':'light'}});mode.write_text('pass')
            # A prepared draft cannot overwrite an edit that arrived during generation.
            wait_for(lambda:state(s,args.ctl)['err']=='Conflict',13)
            wait_for(lambda:state(s,args.ctl)['preferences']['theme']['mode']=='static',5);settled(s,args.ctl)
            assert json.loads(path.read_text())=={'theme':{'variant':'light'}}
            checks['concurrent-disk-edit-blocks-save-before-atomic-replacement']=True
            mode.write_text('slow');p['theme']['seed']='#987654';external(path,p);prior=len(calls.read_text().splitlines())
            wait_for(lambda:len(calls.read_text().splitlines())>prior)
            started=time.monotonic();ctl(s,args.ctl,'quit');clean(app);assert time.monotonic()-started<4
            checks['shutdown-cancels-worker-and-reaps-generator']=True
            for call in map(json.loads,calls.read_text().splitlines()):
                try: os.kill(call['pid'],0)
                except ProcessLookupError: pass
                else: raise AssertionError(('Leaked generator',call))
            empty=s.base/'empty-bin';empty.mkdir();app=s.child('without-matugen',[args.pearl],G_DEBUG='fatal-warnings',PATH=str(empty));app.expect('event=control-ready');v=settled(s,args.ctl)
            assert v['recovered'] and v['preferences']['theme']['mode']=='static',v
            p=v['preferences'];p['theme']['variant']='dark';apply(s,args.ctl,p)
            ctl(s,args.ctl,'quit');clean(app);checks['static-theme-and-last-good-recovery-without-matugen']=True
        metadata['status']='passed'
    finally:
        (args.output/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps(metadata,indent=2))
if __name__=='__main__': main()
