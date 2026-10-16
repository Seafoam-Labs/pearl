'use strict';
const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const clone = x => structuredClone(x);
const catalog = [
  {id:'cat', package:'pearl.companion', name:'Pearl Cat', description:'A small companion for your desktop.', symbol:'cat', overlay:true, activity:true},
  {id:'timer', package:'pearl.timer-c', name:'Countdown (C)', description:'A simple countdown, always within reach.', symbol:'timer'},
  {id:'zig', package:'pearl.counter-zig', name:'Counter (Zig)', description:'A tiny, clickable counter for your bar.', symbol:'counter'},
  {id:'rust', package:'pearl.counter-rust', name:'Counter (Rust)', description:'Another take on the everyday counter.', symbol:'counter'}
];
const paths = {cat:'<path d="M5 9 4 3l6 4h4l6-4-1 6v8c0 3-14 3-14 0Z"/><path d="M8 12h1m6 0h1m-6 4 2 1 2-1M2 14l4 1m12 0 4-1"/>', timer:'<circle cx="12" cy="13" r="8"/><path d="M12 9v5l3 2M9 2h6m-3 0v3m6 1 2-2"/>',counter:'<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M8 12h8m-4-4v8"/>'};
const icon = p => `<svg aria-hidden="true" viewBox="0 0 24 24">${paths[p.symbol]}</svg>`;
let scenario='installed', saved, draft, runtime, openCards=new Set(), reviewing=null, toastTimer, refreshTimer;
const base = () => Object.fromEntries(catalog.map((p,i)=>[p.id,{enabled:i!==2,approved:i!==2,mode:i===0?'overlay':'bar',activity:i===0,overlay:i===0,output:'',x:120,y:80,width:128,height:96,interactive:true,locked:false,fullscreen:true,seconds:60}]));
const available = id => scenario!=='empty' && !(scenario==='missing'&&id==='cat');
const changed = id => JSON.stringify(saved[id])!==JSON.stringify(draft[id]);
const dirty = () => catalog.filter(p=>changed(p.id));
const runnable = id => available(id)&&scenario!=='unavailable'&&saved[id].approved&&saved[id].enabled;
function tell(message){$('#toast').textContent=message;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').textContent='',4000);}
function status(id){
  if(!available(id))return ['Package missing','warn'];
  if(scenario==='unavailable')return ['Runtime unavailable','warn'];
  if(!saved[id].approved)return [scenario==='changed'&&id==='cat'?'Package changed':'Review needed','warn'];
  if(!saved[id].enabled)return ['Disabled',''];
  if(runtime[id]==='failed')return ['Stopped unexpectedly','error'];
  return ['Running','good'];
}
function switchControl(id,key,label,disabled=false){return `<button type="button" class="switch" role="switch" aria-label="${esc(label)}" aria-checked="${draft[id][key]}" data-toggle="${key}" data-id="${id}" ${disabled?'disabled':''}></button>`;}
function row(title,description,control){return `<div class="row"><div>${title}${description?`<p>${description}</p>`:''}</div>${control}</div>`;}
function details(p){const c=draft[p.id], disabled=!available(p.id);return `<div class="details-body"><fieldset ${disabled?'disabled':''} style="border:0;margin:0;padding:0;min-width:0">
${row('Placement',p.overlay?'Choose where this plugin appears.':'This plugin supports the bar.',p.overlay?`<select aria-label="${p.name} placement" data-field="mode" data-id="${p.id}"><option value="bar" ${c.mode==='bar'?'selected':''}>Bar</option><option value="overlay" ${c.mode==='overlay'?'selected':''}>Desktop overlay</option></select>`:'<span class="sub">Bar</span>')}
${p.overlay?row('Allow desktop overlay','Turning this off returns the plugin to the bar.',switchControl(p.id,'overlay','Allow desktop overlay')):''}
${p.activity?row('Keyboard & mouse activity','Coarse activity only; no keys, text or pointer positions.',switchControl(p.id,'activity','Allow keyboard and mouse activity')):''}
${p.overlay&&c.mode==='overlay'?`<div class="overlay-options">${row('Display','Leave blank to use the first output.',`<input type="text" maxlength="256" placeholder="Automatic (first output)" aria-label="Overlay output" value="${esc(c.output)}" data-id="${p.id}" data-field="output">`)}<div class="overlay-grid">${[['x','Horizontal position',0,65535],['y','Vertical position',0,65535],['width','Width',16,512],['height','Height',16,512]].map(([key,label,min,max])=>`<label>${label}<input type="number" min="${min}" max="${max}" value="${c[key]}" data-field="${key}" data-id="${p.id}"></label>`).join('')}</div>${row('Accept clicks','Turn off to let clicks pass through.',switchControl(p.id,'interactive','Accept clicks'))}${row('Lock placement','Keep the overlay in one place.',switchControl(p.id,'locked','Lock placement'))}${row('Hide over fullscreen windows','Keep fullscreen content unobstructed.',switchControl(p.id,'fullscreen','Hide over fullscreen windows'))}</div>`:''}
${p.id==='timer'?row('Starting seconds','From 1 second to 24 hours.',`<input aria-label="Starting seconds" type="number" min="1" max="86400" value="${c.seconds}" data-id="timer" data-field="seconds">`):''}
<div class="actions"><button class="outline" data-review="${p.id}">Review package</button><button class="outline" data-preview="${p.id}" ${runnable(p.id)&&runtime[p.id]!=='failed'?'':'disabled'}>Preview</button><button class="outline" data-retry="${p.id}" ${runnable(p.id)?'':'disabled'}>Retry</button>${p.id==='timer'?'<button data-reset="timer">Reset settings</button>':''}${p.overlay&&c.mode==='overlay'?'<button data-bar="cat">Add to bar</button>':''}</div></fieldset>
<details class="diagnostics"><summary>Package details & diagnostics</summary><dl><dt>Package ID</dt><dd><code>${p.package}</code></dd><dt>Version</dt><dd>0.1.0</dd><dt>Source</dt><dd>System · <code>/usr/share/pearl/plugins/${p.package}/</code></dd><dt>Fingerprint</dt><dd><code>${fingerprint(p.id)}</code></dd><dt>Approval</dt><dd>${saved[p.id].approved?'Saved approval matches this package':'Current package needs approval'}</dd><dt>Runtime</dt><dd>${runtime[p.id]==='failed'?'Sample error: guest callback failed; instance stopped.':status(p.id)[0]}</dd><dt>Input activity</dt><dd>${p.activity?(saved[p.id].activity?'Available in sample session':'Permission denied'):'Not requested'}</dd><dt>Other candidates</dt><dd>None · No shadowed or conflicting packages</dd></dl><p class="sub">Fingerprints and runtime details are illustrative sample values.</p></details></div>`;}
function fingerprint(id){return (scenario==='changed'&&id==='cat'?'b82f':'a91e')+'74c2'+({cat:'3a',timer:'4b',zig:'5c',rust:'6d'}[id]).repeat(28);}
function card(p){const c=draft[p.id],[label,tone]=status(p.id);return `<article class="card plugin-card" id="card-${p.id}"><div class="plugin-top"><div class="plugin-icon">${icon(p)}</div><div class="plugin-copy"><div class="plugin-title"><h3>${p.name}</h3><span class="version">0.1.0</span></div><p>${p.description}</p></div>${switchControl(p.id,'enabled',`Enable ${p.name}`,(!c.approved&&!c.enabled)||(!available(p.id)&&!c.enabled))}</div><div class="plugin-meta"><div class="badges"><span class="badge ${tone}">${tone==='good'?'●':tone==='error'?'!':tone==='warn'?'◇':'○'} ${label}</span><span class="badge">${saved[p.id].mode==='overlay'?'Desktop overlay':'Bar'}</span>${changed(p.id)?'<span class="badge staged">• Draft changed</span>':''}</div>${!c.approved&&available(p.id)?`<button class="text-button" data-review="${p.id}">Review & approve →</button>`:runtime[p.id]==='failed'&&runnable(p.id)?`<button class="text-button" data-retry="${p.id}">Retry now ↻</button>`:''}</div><details class="plugin-details" data-details="${p.id}" ${openCards.has(p.id)?'open':''}><summary>Settings & placement</summary>${details(p)}</details></article>`;}
function footer(){const count=dirty().length;$('#draft-status').textContent=count?`${count} plugin${count===1?'':'s'} with unsaved changes`:'All changes saved';$('#draft-status').classList.toggle('dirty',count>0);$('#apply').disabled=$('#discard').disabled=!count;}
function render(focusSelector){
  const query=$('#search').value.trim().toLowerCase(),filter=$('#filter').value;
  const all=scenario==='empty'?[]:catalog;
  const visible=all.filter(p=>(p.name+' '+p.package).toLowerCase().includes(query)&&(filter==='all'||filter==='enabled'&&draft[p.id].enabled||filter==='attention'&&['warn','error'].includes(status(p.id)[1])));
  $('#count').textContent=all.filter(p=>available(p.id)).length;
  $('#summary').textContent=scenario==='empty'?'Ready for your first addition':`${all.filter(p=>status(p.id)[0]==='Running').length} running · ${all.filter(p=>['warn','error'].includes(status(p.id)[1])).length} need attention`;
  $('#plugins').innerHTML=visible.map(card).join('')||`<div class="empty"><h3>${all.length?'No matching plugins':'A little extra starts here'}</h3><p>${all.length?'Try another name or clear your filters.':'Installed packages will appear here, ready for your review.'}</p>${all.length?'<button class="outline" id="clear-search">Clear filters</button>':'<p><a href="../../PLUGIN_DEVELOPMENT.md">Learn how to install a plugin ↗</a></p>'}</div>`;
  $('#plugins').querySelectorAll('[data-details]').forEach(d=>d.addEventListener('toggle',()=>{if(d.isConnected){if(d.open)openCards.add(d.dataset.details);else openCards.delete(d.dataset.details);}}));
  footer();if(focusSelector)$(focusSelector)?.focus({preventScroll:true});
}
function reset(value){clearTimeout(refreshTimer);$('#refresh').disabled=false;$('#refresh').textContent='↻ Refresh plugins';scenario=value;saved=base();runtime={cat:'running',timer:'running',zig:'idle',rust:'failed'};openCards.clear();if(value==='changed'){saved.cat.approved=false;saved.cat.activity=false;saved.cat.overlay=false;saved.cat.mode='bar';}draft=clone(saved);$('#search').value='';$('#filter').value='all';const notes={changed:'Pearl Cat was updated. Its old approval no longer applies. Review the new package and choose its permissions again.',missing:'Pearl Cat is no longer installed. Its preferences are retained; you can still disable it.',unavailable:'The plugin runtime is unavailable in this sample build. Preferences are retained. Install a Pearl build with plugin support to run plugins.'};$('#notice').hidden=!notes[value];$('#notice').textContent=notes[value]||'';$('#monitoring').textContent='Watching installed packages automatically';render();}
function review(id){reviewing=id;const p=catalog.find(x=>x.id===id),c=draft[id];$('#review-title').textContent=`Review ${p.name}`;$('#review-description').textContent='Approve this package version and choose optional permissions.';$('#review-body').innerHTML=`<div class="package-info"><p>${p.package} · Version 0.1.0 · System package</p><code>/usr/share/pearl/plugins/${p.package}/</code><p style="margin-top:12px">Package fingerprint · Illustrative</p><code>${fingerprint(id)}</code></div><h3>Optional permissions</h3>${p.activity?'<label class="permission"><input type="checkbox" id="grant-activity" '+(c.activity?'checked':'')+'><span>Keyboard & mouse activity<span class="sub">Receive coarse activity notifications. No typed text, key identities or pointer positions are exposed.</span></span></label>':''}${p.overlay?'<label class="permission"><input type="checkbox" id="grant-overlay" '+(c.overlay?'checked':'')+'><span>Desktop overlay<span class="sub">Display this plugin outside the bar. Placement is configured separately.</span></span></label>':''}${!p.activity&&!p.overlay?'<p class="sub" style="margin:12px 0">This plugin requests no optional permissions.</p>':''}<div class="approval-note">Approval is for this package fingerprint. Updated packages need a new review. Save this review, then enable the plugin and Apply & save.</div>`;$('#review-dialog').showModal();}
$('#review-form').addEventListener('submit',e=>{e.preventDefault();const c=draft[reviewing];c.approved=true;c.activity=$('#grant-activity')?.checked||false;c.overlay=$('#grant-overlay')?.checked||false;if(!c.overlay)c.mode='bar';$('#review-dialog').close();render(`[data-toggle="enabled"][data-id="${reviewing}"]`);tell('Package review added to the draft. Apply to save.');});
document.addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b||b.disabled)return;
  if(b.dataset.close){$('#'+b.dataset.close).close();return;}
  if(b.dataset.toggle){const id=b.dataset.id,key=b.dataset.toggle;draft[id][key]=!draft[id][key];if(key==='overlay'&&!draft[id].overlay)draft[id].mode='bar';render(`[data-toggle="${key}"][data-id="${id}"]`);return;}
  if(b.dataset.review){review(b.dataset.review);return;}
  if(b.dataset.retry){const id=b.dataset.retry;if(!runnable(id))return;runtime[id]='running';render(`[data-details="${id}"] summary`);tell('Plugin restarted in the preview using saved settings.');return;}
  if(b.dataset.preview){const id=b.dataset.preview;if(!runnable(id)||runtime[id]==='failed')return;$('#preview-title').textContent=catalog.find(p=>p.id===id).name;$('#preview-scene').innerHTML=id==='cat'?'<div class="cat" role="img" aria-label="Pearl Cat sample pose"></div>':id==='timer'?`<span>◷ ${String(Math.floor(saved.timer.seconds/60)).padStart(2,'0')}:${String(saved.timer.seconds%60).padStart(2,'0')}</span>`:'<span>Counter · 1</span>';$('#preview-dialog').showModal();return;}
  if(b.dataset.bar){draft.cat.mode='bar';draft.cat.overlay=false;render('[data-details="cat"] summary');return;}
  if(b.dataset.reset){draft.timer.seconds=60;render('[data-reset="timer"]');tell('Default starting seconds added to the draft.');return;}
  if(b.id==='clear-search'){$('#search').value='';$('#filter').value='all';render();$('#search').focus();}
});
$('#plugins').addEventListener('change',e=>{const input=e.target;if(!input.dataset.field)return;const id=input.dataset.id,key=input.dataset.field;if(!input.checkValidity()){input.reportValidity();return;}draft[id][key]=input.type==='number'?Number(input.value):input.value;if(key==='mode'){draft[id].overlay=input.value==='overlay';render(`[data-field="mode"][data-id="${id}"]`);}else footer();});
$('#plugins').addEventListener('input',e=>{if(e.target.matches('input[data-field]')){const {id,field}=e.target.dataset;draft[id][field]=e.target.type==='number'&&e.target.value!==''?Number(e.target.value):e.target.value;footer();}});
$('#apply').onclick=()=>{
  const bounds={seconds:[1,86400],x:[0,65535],y:[0,65535],width:[16,512],height:[16,512]};
  for(const p of catalog)for(const [key,[min,max]]of Object.entries(bounds)){
    if(key==='seconds'&&p.id!=='timer'||key!=='seconds'&&!p.overlay)continue;
    const value=draft[p.id][key];if(value===''||!Number.isInteger(value)||value<min||value>max){
      $('#search').value='';$('#filter').value='all';openCards.add(p.id);render();
      const field=$(`[data-id="${p.id}"][data-field="${key}"]`);if(field){field.required=true;field.focus();field.reportValidity();}tell(`Check ${p.name}: enter a whole number from ${min} to ${max}.`);return;
    }
  }
  saved=clone(draft);render();tell('Changes saved in this preview. Your real Pearl settings are unchanged.');
};
$('#discard').onclick=()=>{draft=clone(saved);render();tell('Draft discarded. Immediate runtime actions are retained.');};
$('#refresh').onclick=()=>{$('#refresh').disabled=true;$('#refresh').textContent='Refreshing…';$('#monitoring').textContent='Scanning sample package folders…';refreshTimer=setTimeout(()=>{$('#refresh').disabled=false;$('#refresh').textContent='↻ Refresh plugins';$('#monitoring').textContent='Up to date · Watching installed packages automatically';tell('Sample discovery refreshed. Unsaved changes are retained.');},550);};
$('#search').oninput=()=>render();$('#filter').onchange=()=>render();
$('#scenario').onchange=e=>{reset(e.target.value);tell('Preview scenario changed; sample preferences reset.');};
$('#theme').onclick=()=>{document.body.classList.toggle('light');$('#theme').textContent=document.body.classList.contains('light')?'Dark preview':'Light preview';};
const groups=[['General',[['Overview','overview']]],['Connections',[['Network','network'],['Bluetooth','bluetooth']]],['Devices',[['Sound','sound'],['Power & battery','power']]],['Desktop',[['Appearance','appearance'],['Assistant',null],['Bar & dock',null],['Notifications',null]]],['System',[['System',null],['Session & lock',null],['Aqueous',null],['Advanced',null],['Plugins','plugins']]]];
$('#navigation').innerHTML=groups.map(([group,items])=>`<div class="nav-group">${group.toUpperCase()}</div>${items.map(([name,route])=>route==='plugins'?'<span class="nav-item" aria-current="page">Plugins</span>':route?`<a class="nav-item" href="../settings-navigation/index.html#${route}">${name}</a>`:`<span class="nav-item">${name}</span>`).join('')}`).join('');
$('#sections').onclick=()=>{const open=$('#navigation').classList.toggle('open');$('#sections').setAttribute('aria-expanded',open);if(open)$('#navigation a').focus();};
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&$('#navigation').classList.contains('open')){$('#navigation').classList.remove('open');$('#sections').setAttribute('aria-expanded','false');$('#sections').focus();}});
const params=new URLSearchParams(location.search);if(params.get('theme')==='light')$('#theme').click();const initial=params.get('state');if([...$('#scenario').options].some(o=>o.value===initial))$('#scenario').value=initial;reset($('#scenario').value);if(params.get('view')==='details'){openCards.add('cat');render();}if(params.get('view')==='review')review('zig');
