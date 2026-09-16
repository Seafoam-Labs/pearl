#!/usr/bin/env python3
"""Build an offline, interactive reference/GTK screenshot comparison from S6 evidence."""
import argparse, json, os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report',type=Path,default=ROOT/'artifacts/settings-app/s6/acceptance/presentation/results.json')
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/settings-app/s6/comparison.html')
    args=p.parse_args();args.output=args.output.resolve();args.report=args.report.resolve()
    report=json.loads(args.report.read_text());assert report['status']=='passed',report.get('error')
    captures=[]
    for capture in report['captures']:
        if capture['case'] not in ('dark','light','native','narrow-dark','narrow-light','narrow-native','large-text'):continue
        item=dict(capture)
        item['path']=os.path.relpath(args.report.parent/capture['path'],args.output.parent)
        captures.append(item)
    reference=os.path.relpath(ROOT/'docs/mockups/settings-navigation',args.output.parent)
    payload=json.dumps(dict(captures=captures,reference=reference)).replace('<','\\u003c')
    html='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pearl Settings — S6 visual review</title>
<style>
body{font:15px system-ui,sans-serif;background:#141218;color:#e6e0e9;margin:24px}h1{font-size:25px}a{color:#d0bcff}
label{display:inline-flex;align-items:center;gap:8px;margin:8px 18px 14px 0}select,button{font:inherit;color:inherit;background:#29252f;border:1px solid #777080;border-radius:8px;padding:8px}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:20px}.frame{position:relative;overflow:hidden;background:#201d24;border:1px solid #49434f;border-radius:12px}.frame img{position:absolute;max-width:none}
h2{font-size:18px}p,li{max-width:1100px;line-height:1.5}.note{color:#c4bccb}table{border-collapse:collapse;max-width:1200px}td,th{text-align:left;padding:10px;border-bottom:1px solid #49434f;vertical-align:top}
@media(max-width:850px){.pair{grid-template-columns:1fr}}
</style>
<h1>Pearl Settings — reference and real GTK window</h1>
<p>Actual captures use the production presentation code and private NetworkManager, BlueZ, PulseAudio and power fixtures. No sample-page mode is enabled. These images document layout; device names and state differ from the illustrative mockup.</p>
<label>Page <select id="page"></select></label><label>Presentation <select id="mode"></select></label>
<div class="pair"><section><h2 id="reference-title">Reference</h2><div class="frame" id="reference"></div><p><a id="reference-link">Open full reference</a></p></section>
<section><h2>Actual application</h2><div class="frame" id="actual"></div><p><a id="actual-link">Open full capture</a></p></section></div>
<p class="note" id="note"></p>
<h2>Comparison findings</h2><table><tr><th>Area</th><th>Assessment</th></tr>
<tr><td>Window and navigation</td><td>Normal window, 220 px sidebar, grouped routes, selected-page treatment and narrow Sections chooser follow the reference. GTK and compositor supply native titlebar controls and focus borders.</td></tr>
<tr><td>Spacing and scroll</td><td>Cards retain rounded surfaces and page-local scrolling. S6 removes irrelevant theme rows and excess service-card spacing. Only the selected category occupies the body; headings and save/review footer stay fixed.</td></tr>
<tr><td>Wallpaper</td><td>The real draft preview is inset and rounded. File path, fit and background controls expose the complete preference model. The reference's illustrative wallpaper is not installed as user data.</td></tr>
<tr><td>Actions and drafts</td><td>Service actions explicitly say they take effect immediately. Pearl preference edits use Apply &amp; save; an acknowledged draft remains visible across pages. Aqueous retains separate Apply and display-preview controls.</td></tr>
<tr><td>Intentional differences</td><td>Real device capability, identity, validation and unavailable states replace mock data. Numeric controls permit exact volume/brightness values. Static colors use Pearl's existing palette; configurable seed colors belong to dynamic mode. Native GTK intentionally follows the selected theme.</td></tr></table>
<p><a href="REVIEW.md">S6 results and limitations</a> · <a href="MANUAL.md">Physical activation and assistive-technology checklist</a></p>
<script type="application/json" id="evidence">PAYLOAD</script>
<script>
const data=JSON.parse(document.querySelector('#evidence').textContent),page=document.querySelector('#page'),mode=document.querySelector('#mode');
for(const [element,values] of [[page,['appearance','network','bluetooth','sound','power']],[mode,['dark','light','native','narrow-dark','narrow-light','narrow-native','large-text']]])for(const value of values){const option=document.createElement('option');option.value=value;option.textContent=value;element.append(option)}
function frame(id,path,rect){const box=document.getElementById(id),factor=box.clientWidth/rect.width;box.replaceChildren();box.style.height=(rect.height*factor)+'px';const img=new Image();img.src=path;img.style.left=(-rect.x*factor)+'px';img.style.top=(-rect.y*factor)+'px';img.onload=()=>{img.style.width=(img.naturalWidth*factor)+'px'};img.alt=id==='actual'?'Real GTK Settings window':'Design reference window';box.append(img);document.getElementById(id+'-link').href=path}
function draw(){const capture=data.captures.find(c=>c.case===mode.value&&c.page===page.value);let ref=page.value+'.png',rect={x:200,y:187,width:1040,height:740},note='Dark reference compared with the selected real theme.';
if(page.value==='appearance'&&mode.value==='light'){ref='light.png';note='Light Appearance reference and real GTK application.'}
if(page.value==='sound'&&mode.value.startsWith('narrow')){ref='narrow.png';rect={x:15,y:163,width:530,height:725};note='Narrow Sound reference and real Sections navigation.'}
frame('reference',data.reference+'/'+ref,rect);frame('actual',capture.path,capture.window);document.querySelector('#note').textContent=note+' Frames are fitted independently to compare layout, without altering the captures.'}
page.onchange=mode.onchange=draw;new ResizeObserver(draw).observe(document.querySelector('.pair'));draw();
</script></html>'''.replace('PAYLOAD',payload)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(html)
    print(args.output)
if __name__=='__main__':main()
