import sys,time,json,hashlib,subprocess
from pathlib import Path
from PIL import Image,ImageChops,ImageStat
root=Path('/home/zoey/Pearl');sys.path[:0]=[str(root/'scripts'),str(root/'tests/integration')]
from pearl_session import PrivateSession,wait_for
from test_surfaces import status,ctl,capture,eventually_status
from test_preferences import settled,apply
class AMDSession(PrivateSession):
    def child(self,name,argv,**kwargs):
        kwargs.update(VK_DRIVER_FILES='/usr/share/vulkan/icd.d/radeon_icd.json',WLR_RENDER_DRM_DEVICE='/dev/dri/renderD129',DRI_PRIME='pci-0000_7a_00_0')
        return super().child(name,argv,**kwargs)
# Browser-specific HTML/JS test fixture: exercise page redraw and native title propagation.
page='''<!doctype html><meta charset="utf-8"><title>Redraw baseline</title>
<style>body{background:#282854;color:white}canvas{border:4px solid cyan}</style>
<h1>Isolated Firefox redraw test</h1><canvas id="c" width="700" height="350"></canvas>
<script>
const ctx=document.getElementById('c').getContext('2d');let n=0;
function paint(n){ctx.fillStyle='#282854';ctx.fillRect(0,0,700,350);for(let i=0;i<60;i++){ctx.fillStyle=`hsl(${i*11+n*7},80%,60%)`;ctx.fillRect((i*43+n*13)%680,(i*31+n*5)%330,20,20);}}
paint(0);
setTimeout(()=>{let timer=setInterval(()=>{n++;paint(n);document.title=['Short','A much longer page title with text that moves the panel boundary — Firefox redraw probe','🦊 Example 日本語 العربية é'][n%3];if(n===90){clearInterval(timer);paint(0);document.title='Redraw baseline';document.body.dataset.complete='true';}},80);},9000);
</script>'''
base=Path('/tmp/pearl-firefox-redraw-results');base.mkdir(exist_ok=True);results=[]
for browser in ['firefox-developer-edition','firefox']:
  for debug in ['', 'full-redraw']:
    name=browser+('-full' if debug else '-partial');result={'case':name,'browser_version':subprocess.check_output([browser,'--version'],text=True).strip()}
    try:
      with AMDSession(base/name,aqueous=Path('/home/zoey/RiderProjects/Aqueous/compositor/zig-out/bin/aqueous'),renderer='vulkan',wm_extra='[blur]\nenabled=true\nradius=8\npasses=2\n') as s:
        app=s.child('pearl',[root/'zig-out/bin/pearl'],GSK_RENDERER='vulkan',GSK_DEBUG=debug)
        app.expect('event=control-ready',30)
        prefs=settled(s,root/'zig-out/bin/pearlctl')['preferences'];prefs['bar']['background_opacity']={'mode':'custom','percent':45};apply(s,root/'zig-out/bin/pearlctl',prefs)
        profile=s.base/'firefox-profile';profile.mkdir()
        # Suppress first-run UI and background update checks; leave graphics preferences at defaults.
        (profile/'user.js').write_text('\n'.join('user_pref('+json.dumps(k)+', '+json.dumps(v)+');' for k,v in {'browser.shell.checkDefaultBrowser':False,'browser.aboutwelcome.enabled':False,'browser.startup.homepage_override.mstone':'ignore','datareporting.policy.dataSubmissionEnabled':False,'app.update.enabled':False}.items()))
        html=s.base/'redraw.html';html.write_text(page)
        ff=s.child('browser',[browser,'--no-remote','--profile',profile,html.as_uri()],MOZ_ENABLE_WAYLAND='1',WAYLAND_DEBUG='client',log_limit=200000)
        def ready():
          if ff.proc.poll() is not None:raise RuntimeError('Firefox exited: '+str(ff.proc.returncode))
          return next((o for o in status(s,root/'zig-out/bin/pearlctl')['outputs'] if 'Redraw baseline' in o['title']),None)
        output=wait_for(ready,40);result['output']=output
        s.run(['wlrctl','pointer','move','-100000','-100000']);s.run(['wlrctl','pointer','move','1000','600'])
        time.sleep(1);first=capture(s,'initial',output['connector'])
        wait_for(lambda:any('Redraw baseline' not in o['title'] and o['title']!='Desktop' for o in status(s,root/'zig-out/bin/pearlctl')['outputs']),15)
        capture(s,'during',output['connector'])
        output=wait_for(ready,20);time.sleep(1);last=capture(s,'after',output['connector'])
        box=(0,0,550,48);diff=ImageChops.difference(first.crop(box),last.crop(box));diff.save(base/name/'difference.png')
        result.update(diff_bbox=diff.getbbox(),mean_difference=ImageStat.Stat(diff).mean)
        result['title_events']=[l for l in ff.lines if 'set_title(' in l][-8:]
        result['dmabuf_used']=any('create_immed' in l for l in ff.lines)
        result['browser_errors']=[l for l in ff.lines if any(t in l for t in ('GFX1-','protocol error','ERROR'))][-15:]
        ctl(s,root/'zig-out/bin/pearlctl','quit');result['pearl_exit']=app.wait()
    except Exception as e:result['error']=str(e)
    results.append(result);(base/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(result),flush=True)
