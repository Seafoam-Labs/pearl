import sys, time, json, hashlib
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
root=Path('/home/zoey/Pearl')
sys.path[:0]=[str(root/'scripts'),str(root/'tests/integration')]
from pearl_session import PrivateSession
from test_preferences import settled, apply
from test_surfaces import status, ctl, capture, eventually_status
class AMDSession(PrivateSession):
    def child(self, name, argv, **kwargs):
        kwargs.update(VK_DRIVER_FILES='/usr/share/vulkan/icd.d/radeon_icd.json', WLR_RENDER_DRM_DEVICE='/dev/dri/renderD129', DRI_PRIME='pci-0000_7a_00_0')
        return super().child(name, argv, **kwargs)
base=Path('/tmp/pearl-redraw-fractional-results'); base.mkdir(exist_ok=True)
results=[]
for renderer,debug in [('vulkan',''),('vulkan','full-redraw')]:
    name=renderer+('-full' if debug else '-partial')
    result=dict(case=name)
    try:
        with AMDSession(base/name, aqueous=Path('/home/zoey/RiderProjects/Aqueous/compositor/zig-out/bin/aqueous'), renderer='vulkan', wm_extra='[blur]\nenabled = true\nradius = 8\npasses = 2\n') as s:
            s.run(['wlr-randr','--output','HEADLESS-2','--scale','1.25'])
            app=s.child('pearl',[root/'zig-out/bin/pearl'],GSK_RENDERER=renderer,GSK_DEBUG=debug,GDK_DEBUG='vulkan,opengl',VK_INSTANCE_LAYERS='VK_LAYER_KHRONOS_validation',VK_LAYER_ENABLES='VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT')
            app.expect('event=control-ready',30)
            state=eventually_status(s,root/'zig-out/bin/pearlctl',lambda v:len(v['outputs'])==2)
            output=state['outputs'][0]
            prefs=settled(s,root/'zig-out/bin/pearlctl')['preferences']
            prefs['bar']['background_opacity']={'mode':'custom','percent':45}
            apply(s,root/'zig-out/bin/pearlctl',prefs)
            title=s.child('title',['python','/tmp/pearl-redraw-title.py'],GSK_RENDERER=renderer)
            title.expect('title-ready')
            time.sleep(1)
            state=status(s,root/'zig-out/bin/pearlctl')
            output=next(o for o in state['outputs'] if o['title']=='Redraw probe')
            result['output']=output
            s.run(['wlrctl','pointer','move','-100000','-100000'])
            s.run(['wlrctl','pointer','move','1000','600'])
            time.sleep(1)
            first=capture(s,'initial',output['connector'])
            import signal
            title.signal(signal.SIGUSR1)
            # Move across workspace buttons, then return to the same pointer location.
            for cycle in range(4):
                for x in (50,90,130,170,210,250,290,330,370):
                    s.run(['wlrctl','pointer','move','-100000','-100000'])
                    s.run(['wlrctl','pointer','move',str(x),'24'])
                    time.sleep(.045)
            s.run(['wlrctl','pointer','move','-100000','-100000'])
            s.run(['wlrctl','pointer','move','1000','600'])
            time.sleep(1)
            title.expect('titles-complete')
            time.sleep(.5)
            last=capture(s,'after',output['connector'])
            area=(0,0,560,60)
            diff=ImageChops.difference(first.crop(area),last.crop(area))
            diff.save(base/name/'difference.png')
            result.update(diff_bbox=diff.getbbox(),mean_difference=ImageStat.Stat(diff).mean)
            result['renderer_log']=[line for line in app.lines if any(t in line for t in ('renderer','Vulkan','device','OpenGL','GL version'))][:35]
            ctl(s,root/'zig-out/bin/pearlctl','quit')
            result['exit']=app.wait()
    except Exception as e:
        result['error']=str(e)
    results.append(result)
    (base/'results.json').write_text(json.dumps(results,indent=2))
    print(json.dumps(result),flush=True)
