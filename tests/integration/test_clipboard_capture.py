#!/usr/bin/env python3
"""T14 native clipboard/capture: isolated compositor, buses, producers and PAM stack."""
import argparse, hashlib, json, math, os, subprocess, sys, time
from pathlib import Path
from types import SimpleNamespace
from PIL import Image, ImageChops, ImageStat, PngImagePlugin
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
from pearl_session import PrivateSession, wait_for
from t00 import Session as T00Session
from test_surfaces import IPC, ctl, status, capture, clean

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('pearl', 'ctl', 'locker', 'pam-module', 'producer'): parser.add_argument('--'+arg, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/t14/latest')
    args = parser.parse_args()
    for key, value in vars(args).items(): setattr(args, key, value.resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'status': 'running', 'checks': {}, 'binaries': {key: hashlib.sha256(getattr(args,key).read_bytes()).hexdigest() for key in ('pearl','ctl','locker','pam_module','producer')}}
    checks = report['checks']
    try:
        with PrivateSession(args.output/'session') as s:
            s.env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path='+str(s.runtime/'system-bus')
            s.child('system-bus', ['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
            wait_for(lambda: s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode == 0)
            s.env['PEARL_SECURITY_LOG'] = str(s.output/'security.jsonl'); Path(s.env['PEARL_SECURITY_LOG']).write_text('')
            s.env['PEARL_TEST_LOCKER'] = str(args.locker)
            pam = s.base/'pam'; pam.mkdir(); (pam/'pearl').write_text(f'auth required {args.pam_module}\naccount required {args.pam_module}\n')
            s.env['PEARL_TEST_PAM_DIR'] = str(pam)
            s.args = SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous'); T00Session.input_fixture(s)
            authority = s.child('authority', ['python3',ROOT/'tests/fixtures/session_security.py'], input_pipe=True); authority.expect('event=ready')
            app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); app.expect('event=control-ready')
            ipc = IPC(s)
            def clip(): return ctl(s,args.ctl,'clipboard','status')['result']
            def shot(): return ctl(s,args.ctl,'capture','status')['result']
            def until(fn, pred, timeout=12): return wait_for(lambda: (lambda v: v if pred(v) else False)(fn()),timeout)
            until(clip, lambda v: v['available'] and not v['locked']); until(shot, lambda v: v['available'] and not v['locked'])
            producer = None; serial = 0
            def offer(mode, payload='sample'):
                nonlocal producer, serial
                if producer: producer.stop()
                serial += 1; producer = s.child('producer-'+str(serial), [args.producer,mode,payload]); producer.expect('event=ready')
                return producer
            def empty(): ctl(s,args.ctl,'clipboard','clear'); assert not clip()['entries']
            offer('text','hello Pearl 👋'); first = until(clip,lambda v: len(v['entries']) == 1)['entries'][0]
            producer.stop(); assert clip()['entries'][0]['id'] == first['id']
            ctl(s,args.ctl,'clipboard','select','--generation',str(first['id']))
            assert s.run(['wl-paste','--no-newline']).stdout == 'hello Pearl 👋'
            checks['owner-disappearance-and-reselection-with-real-paste'] = True
            empty()
            for mode in ('invalid','large','unsupported','sensitive','vanish'):
                offer(mode, 'DO-NOT-RETAIN'); time.sleep(.3); assert clip()['entries'] == [], (mode,clip())
            checks['invalid-large-unsupported-sensitive-and-interrupted-payloads-rejected'] = True
            offer('stall'); until(clip,lambda v:v['pending']); until(clip,lambda v:not v['pending'],8); assert not clip()['entries']
            offer('stall'); until(clip,lambda v:v['pending']); offer('text','replacement'); until(clip,lambda v:len(v['entries'])==1)
            assert clip()['entries'][0]['preview'] == 'replacement'
            checks['stalled-transfer-timeout-and-selection-replacement'] = True
            empty()
            for n in range(24):
                offer('text', 'entry-'+str(n)); until(clip,lambda v:v['entries'] and v['entries'][0]['preview']=='entry-'+str(n))
            assert len(clip()['entries']) == 20
            victim = clip()['entries'][0]['id']; ctl(s,args.ctl,'clipboard','delete','--generation',str(victim)); assert len(clip()['entries']) == 19
            assert ctl(s,args.ctl,'clipboard','select','--generation',str(victim),code=4)['err']['code'] == 'Stale'
            checks['bounded-history-and-stale-entry-actions'] = True
            empty()
            png = s.output/'input.png'; metadata=PngImagePlugin.PngInfo(); metadata.add_text('private-note','metadata-must-not-survive',zip=True); Image.new('RGB',(64,32),(234,71,106)).save(png,pnginfo=metadata)
            offer('png',str(png)); entry = until(clip,lambda v:len(v['entries'])==1)['entries'][0]; assert entry['kind']=='png'
            ctl(s,args.ctl,'clipboard','select','--generation',str(entry['id']))
            data = subprocess.run(['wl-paste','--type','image/png'],env=s.env,stdout=subprocess.PIPE,check=True,timeout=8).stdout
            copied = s.output/'clipboard.png'; copied.write_bytes(data); assert Image.open(copied).size == (64,32); assert 'private-note' not in Image.open(copied).info
            # Receiver quits early; Pearl must survive EPIPE and release the transfer.
            reader = subprocess.Popen(['wl-paste','--type','image/png'],env=s.env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL); reader.stdout.close(); reader.wait(timeout=8)
            bad = s.output/'bad.png'; bad.write_bytes(png.read_bytes()[:33]); offer('png',str(bad)); time.sleep(.3); assert len(clip()['entries'])==1
            bomb = bytearray(png.read_bytes()); bomb[16:24] = (65535).to_bytes(4,'big')*2; bad.write_bytes(bomb); offer('png',str(bad)); time.sleep(.3); assert len(clip()['entries'])==1
            checks['png-decode-copy-truncation-and-dimension-bomb'] = True
            empty()
            for n in range(8):
                # Deterministically seeded random RGB avoids compressible test data masking the byte cap.
                import random
                noisy=Image.frombytes('RGB',(1024,768),random.Random(n).randbytes(1024*768*3)); noisy.save(png)
                previous={e['id'] for e in clip()['entries']}; offer('png',str(png)); until(clip,lambda v:v['entries'] and v['entries'][0]['id'] not in previous)
            assert sum(e['bytes'] for e in clip()['entries']) <= 16*1024*1024 and len(clip()['entries']) < 8
            checks['aggregate-byte-budget-and-metadata-stripping'] = True
            ctl(s,args.ctl,'clipboard','show'); time.sleep(.4); capture(s,'image-history'); ctl(s,args.ctl,'popup','hide')
            empty(); offer('text','Clipboard & capture — ready'); until(clip,lambda v:len(v['entries'])==1)
            output = status(s,args.ctl)['outputs'][0]; connector = output['connector']
            ctl(s,args.ctl,'clipboard','show','--output',output['id']); time.sleep(.3); capture(s,'text-history',connector); ctl(s,args.ctl,'popup','hide')
            ctl(s,args.ctl,'capture','show','--output',output['id']); time.sleep(.4); capture(s,'clipboard-capture-panel',connector); ctl(s,args.ctl,'popup','hide'); time.sleep(.2)
            def target(): return next(o for o in status(s,args.ctl)['outputs'] if o['connector']==connector)
            def take(region=None):
                old = shot()['generation']; o=target()
                ctl(s,args.ctl,'capture','region' if region else 'output','--output',o['id'],*(['--text',region] if region else []))
                return until(shot,lambda v:not v['pending'] and v['generation']>old)
            def save(value,name):
                path = s.output/(name+'.png'); path.unlink(missing_ok=True)
                ctl(s,args.ctl,'capture','save','--generation',str(value['generation']),'--path',str(path)); return Image.open(path).convert('RGB')
            # The keyboard action hides the panel before the delayed one-shot frame.
            ctl(s,args.ctl,'capture','show','--output',target()['id']); time.sleep(.2)
            old=shot()['generation']; s.run(['wtype','-s','150','-k','Tab','-s','150','-k','space','-s','150'])
            until(shot,lambda v:v['generation']>old and not v['pending']); assert status(s,args.ctl)['popup'] is None
            time.sleep(2.2)
            ctl(s,args.ctl,'capture','show','--output',target()['id']); time.sleep(.3); capture(s,'screenshot-preview',connector); ctl(s,args.ctl,'popup','hide')
            checks['keyboard-capture-hides-panel-and-shows-preview'] = True
            orientations = {}
            for transform in ('normal','90','180','270','flipped','flipped-90','flipped-180','flipped-270'):
                s.run(['wlr-randr','--output',connector,'--scale','1','--transform',transform]); time.sleep(.4)
                v=take(); img=save(v,'native-'+transform); ref=capture(s,'reference-'+transform,connector)
                assert img.size == ref.size,(transform,img.size,ref.size)
                if v.get('color_metadata_required'):
                    gamma=[round(255*(12.92*(i/255)**2.2 if (i/255)**2.2<=.0031308 else 1.055*((i/255)**2.2)**(1/2.4)-.055)) for i in range(256)]
                    ref=ref.point(gamma*3)
                mean=ImageStat.Stat(ImageChops.difference(img,ref)).mean
                assert max(mean)<2,(transform,mean)
                orientations[transform]={'size':img.size,'mean_error':mean}
            report['orientations']=orientations; checks['all-eight-output-transforms-match-reference'] = True
            for transform in ('normal','90'):
                s.run(['wlr-randr','--output',connector,'--scale','1.5','--transform',transform]); time.sleep(.4)
                full=save(take(),'fractional-full-'+transform); o=target(); r=(31,41,203,117)
                v=take(','.join(map(str,r))); crop=save(v,'fractional-crop-'+transform)
                x,y,w,h=r; bw,bh=o['bounds']['width'],o['bounds']['height']; iw,ih=full.size
                box=(x*iw//bw,y*ih//bh,math.ceil((x+w)*iw/bw),math.ceil((y+h)*ih/bh))
                ref=full.crop(box); assert crop.size==ref.size,(crop.size,ref.size)
                assert max(ImageStat.Stat(ImageChops.difference(crop,ref)).mean)<2
            checks['fractional-scale-output-local-crops-use-actual-buffer-extents'] = True
            assert ctl(s,args.ctl,'capture','region','--text','0,0,9999,9999','--output',target()['id'],code=4)['err']['code']=='InvalidRegion'
            v=shot(); path=str(s.output/'already.png'); Path(path).write_bytes(b'existing')
            assert ctl(s,args.ctl,'capture','save','--generation',str(v['generation']),'--path',path,code=4)['err']['code']=='Conflict'
            assert Path(path).read_bytes()==b'existing'; assert shot()['ready']
            ctl(s,args.ctl,'capture','copy','--generation',str(v['generation']))
            data=subprocess.run(['wl-paste','--type','image/png'],env=s.env,stdout=subprocess.PIPE,check=True,timeout=8).stdout
            assert data.startswith(b'\x89PNG'); assert not shot()['image_isolated']
            checks['save-conflict-recovery-and-screenshot-copy'] = True
            # Authentication dialogs also pause private data collection, without depending on their MIME hints.
            def authority_command(**data):
                authority.proc.stdin.write(json.dumps(data)+'\n'); authority.proc.stdin.flush(); authority.expect('command='+json.dumps(data,sort_keys=True))
            authority_command(begin=True); until(clip,lambda v:v['locked']); assert not clip()['entries'] and not shot()['ready']
            authority_command(cancel=True); until(clip,lambda v:not v['locked'] and v['available']); take()
            checks['authentication-dialog-privacy'] = True
            # Pending work is cancelled and all private previews are discarded at lock request.
            offer('stall'); until(clip,lambda v:v['pending'])
            ctl(s,args.ctl,'lock'); until(clip,lambda v:v['locked']); assert clip()['entries']==[] and not clip()['pending']
            assert shot()['locked'] and not shot()['ready']
            until(lambda:ctl(s,args.ctl,'lifecycle','status')['result'],lambda v:v['lock']['ready'] and v['lock']['locked'])
            offer('text','copied-while-locked'); time.sleep(.2); assert not clip()['entries']
            assert ctl(s,args.ctl,'capture','output',code=4)['err']['code']=='Locked'
            s.run(['wtype','-s','200','fixture-user','-k','Return','-s','300','fixture-secret','-k','Return','-s','200'])
            until(clip,lambda v:not v['locked'] and v['available']); time.sleep(.3); assert clip()['entries']==[]
            offer('text','after-unlock'); until(clip,lambda v:len(v['entries'])==1)
            checks['lock-cancels-purges-denies-and-does-not-import-locked-selection'] = True
            # Removing an output invalidates any in-flight target and future requests for its old ID.
            old=target()['id']; old_generation=shot()['generation']; ctl(s,args.ctl,'capture','output','--output',old)
            s.run(['wlr-randr','--output',connector,'--off']); until(shot,lambda v:not v['pending']); assert shot()['generation']==old_generation
            assert ctl(s,args.ctl,'capture','output','--output',old,code=4)['err']['code']=='OutputUnavailable'
            s.run(['wlr-randr','--output',connector,'--on']); time.sleep(.5); take()
            checks['output-removal-and-recovery'] = True
            # Repeated presentation/disposal must not leave signal callbacks pointing at old views.
            for _ in range(8): ctl(s,args.ctl,'clipboard','show'); ctl(s,args.ctl,'popup','hide')
            checks['panel-open-close-lifetime'] = True
            # Settings apply the same theme path to this new panel.
            prefs=until(lambda:ctl(s,args.ctl,'preferences','status')['result'],lambda v:not v['busy'])
            for mode in ('light','gtk'):
                settings=prefs['preferences']; settings['theme']['mode']='gtk' if mode=='gtk' else 'static'; settings['theme']['variant']='light'; settings['theme']['gtk_name']='Adwaita'
                ctl(s,args.ctl,'preferences','apply','--revision',str(prefs['revision']),'--text',json.dumps(settings))
                prefs=until(lambda:ctl(s,args.ctl,'preferences','status')['result'],lambda v:not v['busy'])
                ctl(s,args.ctl,'capture','show','--output',target()['id']); time.sleep(.4); capture(s,'panel-'+mode,connector); ctl(s,args.ctl,'popup','hide')
            checks['material-light-and-native-gtk-theme'] = True
            ctl(s,args.ctl,'quit'); clean(app); ipc.close()
        report['status']='passed'
    finally:
        (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__ == '__main__': main()
