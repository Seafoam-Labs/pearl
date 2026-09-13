#!/usr/bin/env python3
"""T10: isolated settings, GTK themes, palettes, wallpaper and ownership."""
import argparse, copy, hashlib, json, os, sys, time
from pathlib import Path
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

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl',type=Path,required=True);parser.add_argument('--ctl',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'artifacts/t10/latest');args=parser.parse_args()
    args.pearl=args.pearl.resolve();args.ctl=args.ctl.resolve();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    checks={};metadata={'status':'running','checks':checks,'pearl_sha256':hashlib.sha256(args.pearl.read_bytes()).hexdigest(),'ctl_sha256':hashlib.sha256(args.ctl.read_bytes()).hexdigest()}
    try:
        with PrivateSession(args.output/'session') as s:
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');keyboard=T00Session.input_fixture(s)
            app=s.child('pearl',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
            v=settled(s,args.ctl);assert v['appearance']==1 and v['err'] is None,v
            path=Path(v['path']);assert not path.exists();assert path.with_name('last-good.json').exists()
            p=v['preferences'];output=status(s,args.ctl)['outputs'][0]
            ctl(s,args.ctl,'settings','show');time.sleep(.5);capture(s,'settings-static-dark',output['connector'])
            p['theme']['variant']='light';v=apply(s,args.ctl,p)
            assert json.loads(path.read_text())==p and path.stat().st_mode&0o777==0o600
            assert status(s,args.ctl)['popup']['pane']=='settings';time.sleep(.4);capture(s,'settings-static-light',output['connector'])
            checks['defaults-atomic-save-and-live-popup-theme']=True
            original=copy.deepcopy(p);revision=v['revision']
            external(path,'{invalid');wait_for(lambda:state(s,args.ctl)['err']=='SyntaxError');v=settled(s,args.ctl)
            assert v['preferences']==original and v['revision']>revision
            bad=ctl(s,args.ctl,'preferences','apply','--revision',str(revision),'--text','{}',code=4);assert bad['err']['code']=='Conflict',bad
            checks['corrupt-external-config-and-stale-revision']=True
            external(path,original);wait_for(lambda:state(s,args.ctl)['err'] is None and state(s,args.ctl)['revision']>v['revision']);settled(s,args.ctl)
            p=copy.deepcopy(original);p['wallpaper'].update(mode='cover',path=str(s.base/'missing.png'));v=apply(s,args.ctl,p,'InvalidImage');assert v['preferences']==original
            fifo=s.base/'fifo';os.mkfifo(fifo);p['wallpaper']['path']=str(fifo);apply(s,args.ctl,p,'InvalidFile')
            image=s.base/'wallpaper.png';png(image);p['wallpaper']['path']=str(image)
            p['theme'].update(mode='dynamic',source='wallpaper');v=apply(s,args.ctl,p)
            assert v['preferences']==p and not v['cache_hit'];time.sleep(.5);capture(s,'settings-dynamic-wallpaper',output['connector'])
            p['wallpaper']['mode']='contain';v=apply(s,args.ctl,p);assert v['cache_hit'],v
            checks['bounded-images-fifo-rejection-and-dynamic-palette-cache']=True
            p['theme'].update(mode='static');p['font']='Pearl Nonexistent Font 9876';apply(s,args.ctl,p)
            checks['missing-font-falls-back']=True
            p['theme'].update(mode='gtk',gtk_name='NotInstalled9876');apply(s,args.ctl,p,'GtkThemeNotInstalled')
            custom=Path(s.env['XDG_DATA_HOME'])/'themes'/'Pearl-Test'/'gtk-4.0';custom.mkdir(parents=True)
            custom.joinpath('gtk.css').write_text('@define-color theme_bg_color #184a40; @define-color theme_fg_color #ffffdd; .background {background-color:#184a40;color:#ffffdd;} button {background:#664477;color:#fff;border:3px solid #eebbee;border-radius:3px;} entry {background:#fff;color:#121212;}')
            p['theme'].update(mode='gtk',gtk_name='Pearl-Test');p['font']='';p['wallpaper']['mode']='solid';v=apply(s,args.ctl,p)
            time.sleep(.5);capture(s,'settings-gtk-custom',output['connector'])
            p['theme']['gtk_name']='';v=apply(s,args.ctl,p);time.sleep(.5);capture(s,'settings-gtk-system',output['connector'])
            checks['installed-gtk-theme-and-system-follow-without-material-css']=True
            p['theme'].update(mode='static',variant='dark');p['wallpaper']['mode']='gradient';p['font']='';p['outputs']=[{'connector':output['connector'],'bar':{'edge':'bottom','size':52,'groups':{'left':'launcher,title','center':'clock','right':'control'}}}];p['popup'].update(placement='centered',max_width=600,max_height=640,dismiss_outside=False)
            apply(s,args.ctl,p);wait_for(lambda:status(s,args.ctl)['outputs'][0]['bar']['edge']=='bottom');time.sleep(.4);capture(s,'settings-output-policy',output['connector'])
            checks['per-connector-bar-and-popup-policies']=True
            p['outputs']=[];p['exports']=[{'name':'terminal.conf','template':'background={{surface}}\nforeground={{text}}\n'}];v=apply(s,args.ctl,p)
            export=path.parent/'exports'/'terminal.conf';first=export.read_text();p['theme']['variant']='light';apply(s,args.ctl,p)
            assert export.with_suffix('.conf.bak').read_text()==first
            export.write_text('user-owned edit');v=apply(s,args.ctl,p);assert v['export_error']=='ExportOwnershipConflict' and export.read_text()=='user-owned edit',v
            p['exports']=[];apply(s,args.ctl,p);assert export.read_text()=='user-owned edit'
            checks['opt-in-exports-ownership-backup-and-disable']=True
            stable=settled(s,args.ctl);time.sleep(1);assert state(s,args.ctl)['jobs']==stable['jobs']
            checks['no-theme-work-at-idle']=True
            ctl(s,args.ctl,'quit');clean(app)
            external(path,'{broken');app=s.child('recovered',[args.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready');v=settled(s,args.ctl)
            assert v['recovered'] and v['preferences']==p and path.read_text()=='{broken',v
            checks['restart-uses-last-good-without-overwriting-corruption']=True
            ctl(s,args.ctl,'quit');clean(app)
        metadata['status']='passed'
    finally:
        (args.output/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps(metadata,indent=2))
if __name__=='__main__': main()
