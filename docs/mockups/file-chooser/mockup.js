/* Offline design study. All files, changes, and selections are in memory. */
const $ = s => document.querySelector(s);
const escape = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
  folder:'M3 7h6l2-3h4l2 3h4v13H3Z', home:'m3 10 9-7 9 7M5 9v12h5v-7h4v7h5V9',
  image:'M3 3h18v18H3ZM3 17l6-6 5 5 3-3 4 4M15 7h.01', file:'M5 3h9l5 5v13H5ZM14 3v6h5M8 13h8M8 17h6',
  download:'M12 3v12m-5-5 5 5 5-5M4 17v4h16v-4', drive:'M4 4h16l2 14H2ZM2 18v3h20v-3M17 18h1',
  search:'M20 20l-5-5M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0', back:'m14 5-7 7 7 7', up:'m5 13 7-7 7 7M12 6v15',
  grid:'M3 3h7v7H3ZM14 3h7v7h-7ZM3 14h7v7H3ZM14 14h7v7h-7Z', list:'M8 5h13M8 12h13M8 19h13M3 5h.01M3 12h.01M3 19h.01',
  eye:'M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7ZM15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  plus:'M3 7h6l2-3h4l2 3h4v13H3ZM12 10v7M8.5 13.5h7', menu:'M3 5h18M3 12h18M3 19h18',
  warning:'m12 3 10 18H2ZM12 9v5M12 17h.01', lock:'M5 10h14v11H5ZM8 10V7a4 4 0 0 1 8 0v3', cloud:'M6 18a5 5 0 0 1-1-10 7 7 0 0 1 13 1 4.5 4.5 0 0 1 0 9M4 3l16 18'
};
function icon(name, cls=''){return `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name] || paths.file}"/></svg>`;}
function art(kind){
  const configs={coast:['#98b3bf','#d8d3bf','#516b76'],dunes:['#dbb19f','#f0d6b8','#a27165'],forest:['#9aa9a6','#526e67','#273f39'],sky:['#acaacb','#e7c8c3','#76718f'],lake:['#96b1c3','#ccd5cf','#506e80'],portrait:['#c4b7a9','#dfd6c1','#647d69']};
  const c=configs[kind]||configs.coast; const portrait=kind==='portrait';
  return `<svg class="art" role="img" aria-label="Illustrative ${kind} photograph" viewBox="0 0 ${portrait?180:320} 200" xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="200" fill="${c[0]}"/><circle cx="${portrait?125:250}" cy="48" r="25" fill="${c[1]}"/><path d="M0 130Q60 50 130 118T320 108V200H0Z" fill="${c[2]}"/><path d="M0 165Q70 97 165 151T330 142V200H0Z" fill="${c[1]}"/><path d="M0 187Q110 143 240 180T330 167V200H0Z" fill="${c[0]}"/></svg>`;
}
const photoFiles=[
  {name:'Coast.jpg',kind:'coast',meta:'3840 × 2400',size:'2.4 MB'},
  {name:'Dunes.jpg',kind:'dunes',meta:'3200 × 2000',size:'1.8 MB'},
  {name:'Forest.jpg',kind:'forest',meta:'4096 × 2560',size:'3.1 MB'},
  {name:'Morning sky.png',kind:'sky',meta:'2560 × 1600',size:'4.2 MB'},
  {name:'Portrait.jpg',kind:'portrait',meta:'1800 × 2000',size:'1.2 MB'},
  {name:'Still lake.jpg',kind:'lake',meta:'3200 × 2000',size:'2.1 MB'},
  {name:'Summer',folder:true,meta:'Folder'}, {name:'.reference.png',kind:'coast',meta:'Hidden image',size:'450 KB',hidden:true}
];
const textFiles=[{name:'Archive',folder:true,meta:'Folder'},{name:'Field notes.txt',meta:'Text document',size:'8 KB'},{name:'Project brief.md',meta:'Markdown',size:'12 KB'},{name:'Reading list.txt',meta:'Text document',size:'3 KB'},{name:'Sketch.png',kind:'sky',meta:'2560 × 1600',size:'1.6 MB'},{name:'.draft.txt',hidden:true,meta:'Text document',size:'2 KB'}];
const folders=[{name:'Archive',folder:true,meta:'12 items'},{name:'Fieldwork',folder:true,meta:'8 items'},{name:'Personal',folder:true,meta:'24 items'},{name:'Projects',folder:true,meta:'6 items'}];
const scenarios={
  wallpaper:{title:'Choose wallpaper',caller:'Pearl Settings',button:'Select image',path:'Home/Pictures/Wallpapers',filter:['PNG and JPEG images'],annotation:'Previews from the first visit',detail:'Visible images load first. Portraits keep their proportions. Selecting an image updates the Settings draft; Apply & save commits it.'},
  open:{title:'Open files',caller:'Coral',button:'Open',path:'Home/Documents',filter:['Text files','All files'],annotation:'One file or several, with the same controls',detail:'Use Ctrl or Shift to select multiple files. The footer shows the selection count. Folder navigation and file-type filtering stay in place.'},
  folder:{title:'Choose destination folder',caller:'Phyto · Copy 3 items',button:'Select folder',path:'Home/Documents',filter:['Folders'],annotation:'A clear destination before the operation starts',detail:'Select a folder, or choose the current location. Creating a folder is an explicit action; confirming the destination returns control to Phyto.'},
  save:{title:'Save document',caller:'Coral',button:'Save',path:'Home/Documents',filter:['Text document (.txt)','All files'],annotation:'Save with the destination in view',detail:'The filename stays visible while you browse. Existing names lead to an explicit replacement prompt. Coral still owns writing the document.'},
  portal:{title:'Attach files',caller:'Requested by Firefox',button:'Attach',path:'Home/Pictures/Wallpapers',filter:['Image files','All files'],annotation:'The same Pearl chooser for portal requests',detail:'The requesting application is identified above the files. Request-specific choices sit above the footer. Access is granted only after confirmation.'},
  batch:{title:'Save files',caller:'Requested by Firefox',button:'Save here',path:'Home/Downloads',filter:['Folders'],annotation:'A destination for a group of downloads',detail:'Review the incoming filenames before confirming. Conflicting names receive a visible numbered suffix; the portal returns destinations in request order.'}
};
let mode='wallpaper',state='ready',locationPath='',selection=new Set(),history=[],listView=false,hidden=false,reverse=false,extra=[],lastIndex=0,dialogAction='',dialogOpener=null,toastTimer;
let current=[];
function toast(message){$('#toast').textContent=message;$('#toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').hidden=true,4500);}
function modeFiles(){if(mode==='folder'||mode==='batch')return folders;if(mode==='open'||mode==='save')return textFiles;return photoFiles;}
function data(){const home=scenarios[mode].path;if(locationPath===home)return [...modeFiles(),...extra];if(locationPath==='Home')return [{name:'Documents',folder:true,meta:'Folder'},{name:'Pictures',folder:true,meta:'Folder'},{name:'Downloads',folder:true,meta:'Folder'}];if(locationPath==='Home/Pictures')return [{name:'Wallpapers',folder:true,meta:'Folder'},...photoFiles.slice(0,3)];if(locationPath==='Home/Documents')return textFiles;if(locationPath==='Home/Downloads')return folders;return extra;}
function navigate(path,remember=true){if(remember)history.push(locationPath);locationPath=path;selection.clear();extra=[];$('#search').value='';state='ready';$('#state').value=state;$('#location').hidden=true;$('#location-toggle').hidden=false;$('#sidebar').classList.remove('open');$('#places').setAttribute('aria-expanded','false');render();}
function render(){
  if(['loading','empty','denied','offline'].includes(state))selection.clear();
  const cfg=scenarios[mode];$('#chooser-title').textContent=cfg.title;$('#caller').textContent=cfg.caller;
  $('#location-toggle').innerHTML=locationPath.split('/').map(n=>`<span>${escape(n)}</span>`).join('<b>›</b>');
  $('#back').disabled=!history.length;$('#up').disabled=locationPath==='Home';
  $('#place-list').innerHTML=[['home','Home'],['file','Documents'],['image','Pictures'],['download','Downloads']].map(([i,n])=>`<button data-place="${n==='Home'?'Home':'Home/'+n}" class="${(n==='Home'?locationPath==='Home':locationPath.startsWith('Home/'+n))?'active':''}">${icon(i)}${n}</button>`).join('');
  document.querySelectorAll('[data-place]').forEach(b=>b.onclick=()=>navigate(b.dataset.place));
  const q=$('#search').value.toLocaleLowerCase();const filter=$('#filter').value;
  current=data().filter(f=>(hidden||!f.hidden)&&f.name.toLocaleLowerCase().includes(q)&&(!(mode==='open'&&filter==='Text files')||f.folder||/\.(txt|md)$/.test(f.name))).sort((a,b)=>Number(Boolean(b.folder))-Number(Boolean(a.folder))||(reverse?-1:1)*a.name.localeCompare(b.name));
  // A filtered-out file is not retained as an invisible selection in the study.
  const visible=new Set(current.map(f=>f.name));selection=new Set([...selection].filter(n=>visible.has(n)));
  $('#files').className='files'+(listView?' list':'');$('#files').hidden=state==='empty'||state==='denied'||state==='offline';$('#empty').hidden=true;
  if(state==='loading'){selection.clear();$('#files').innerHTML=Array.from({length:6},()=>'<div class="skeleton" aria-hidden="true"></div>').join('');}
  else $('#files').innerHTML=current.map((f,i)=>`<button class="file ${selection.has(f.name)?'selected':''}" data-index="${i}" aria-pressed="${selection.has(f.name)}" aria-label="${escape(f.name)}${f.folder?', folder':''}"><span class="thumb">${f.kind&&!(state==='failed'&&f.name==='Coast.jpg')?art(f.kind):icon(f.folder?'folder':f.kind?'image':'file','file-icon')}</span><span class="file-name">${escape(f.name)}</span><span class="file-meta">${state==='failed'&&f.name==='Coast.jpg'?'Preview unavailable':escape(listView?(f.size||f.meta):f.meta)}</span>${selection.has(f.name)?'<span class="check" aria-hidden="true">✓</span>':''}</button>`).join('');
  document.querySelectorAll('[data-index]').forEach(b=>{b.onclick=e=>select(Number(b.dataset.index),e);b.ondblclick=()=>activate(Number(b.dataset.index));b.onkeydown=e=>{let i=Number(b.dataset.index);if(e.key==='Enter'){e.preventDefault();activate(i);}if(['ArrowRight','ArrowLeft','ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();const cols=listView?1:(window.innerWidth<=680?2:3);i=Math.max(0,Math.min(current.length-1,i+({ArrowRight:1,ArrowLeft:-1,ArrowDown:cols,ArrowUp:-cols}[e.key])));document.querySelector(`[data-index="${i}"]`)?.focus();}};});
  if(['empty','denied','offline'].includes(state)||(!current.length&&state!=='loading')){
    const s=state==='denied'?['lock','This folder cannot be opened','You do not have permission to view its contents.','Try again']:state==='offline'?['cloud','This location is disconnected','Reconnect the location, then try again.','Try again']:['folder',q?'No matching files':'This folder is empty',q?'Try another name or clear the filter.':'Files you add here will appear in this view.',q?'Clear filter':'New folder'];
    $('#empty').hidden=false;$('#empty').innerHTML=`${icon(s[0])}<h3>${s[1]}</h3><p>${s[2]}</p><button id="retry">${s[3]}</button>`;$('#retry').onclick=()=>{if(q){$('#search').value='';render();}else if(s[3]==='New folder')newFolder();else{state='ready';$('#state').value=state;render();}};
  }
  $('#notice').hidden=state!=='failed';$('#notice').textContent='One preview could not be generated. You can still select the file.';
  $('#save-fields').hidden=mode!=='save';$('#batch-files').hidden=mode!=='batch';$('#portal-options').hidden=mode!=='portal';
  $('#view').innerHTML=icon(listView?'grid':'list');$('#view').setAttribute('aria-label',`Switch to ${listView?'grid':'list'} view`);$('#hidden').setAttribute('aria-pressed',String(hidden));$('#sort').textContent='Name '+(reverse?'↓':'↑');
  $('#annotation-title').textContent=cfg.annotation;$('#annotation-body').textContent=cfg.detail;
  $('#accept').textContent=cfg.button+(selection.size>1&&['open','portal'].includes(mode)?` ${selection.size} files`:'');
  const unavailable=['loading','denied','offline'].includes(state);
  const selected=current.filter(f=>selection.has(f.name));
  let valid=['folder','batch'].includes(mode)||(mode==='save'?validName($('#filename').value):selected.length>0&&selected.every(f=>!f.folder));
  if(mode==='folder')valid=selected.every(f=>f.folder);
  $('#accept').disabled=unavailable||!valid;
  $('#selection-status').textContent=state==='loading'?'Loading folder…':mode==='save'?'Save to '+locationPath.split('/').at(-1):mode==='folder'||mode==='batch'?(selected[0]?.name||locationPath.split('/').at(-1)):selected.length===1?selected[0].name:`${selected.length} files selected`;
  $('#preview').hidden=!['wallpaper','portal'].includes(mode);$('.workspace').classList.toggle('no-preview',$('#preview').hidden);
  const f=selected.length===1?selected[0]:null;
  $('#preview').innerHTML=`<span class="eyebrow">${selected.length>1?'SELECTION':'PREVIEW'}</span>${f?.kind&&!(state==='failed'&&f.name==='Coast.jpg')?`<div class="preview-image">${art(f.kind)}</div><h3>${escape(f.name)}</h3><p>${f.name.endsWith('.png')?'PNG':'JPEG'} image</p><dl><dt>Dimensions</dt><dd>${f.meta}</dd><dt>Size</dt><dd>${f.size}</dd><dt>Modified</dt><dd>8 Oct 2026</dd></dl><p class="preview-footnote">Original proportions<br>Full image visible</p>`:`<div class="empty">${icon(selected.length>1?'image':'file')}<p>${selected.length>1?`${selected.length} files selected`:f?'Preview unavailable':'Select an image to preview it.'}</p></div>`}`;
}
function select(i,e){const f=current[i];if(!f)return;const multi=['open','portal'].includes(mode);if(multi&&e.shiftKey){for(let n=Math.min(lastIndex,i);n<=Math.max(lastIndex,i);n++)if(!current[n].folder)selection.add(current[n].name);}else if(multi&&(e.ctrlKey||e.metaKey)){selection.has(f.name)?selection.delete(f.name):selection.add(f.name);}else selection=new Set([f.name]);lastIndex=i;if(mode==='save'&&!f.folder)$('#filename').value=f.name;render();document.querySelector(`[data-index="${i}"]`)?.focus();}
function activate(i){const f=current[i];if(!f)return;if(f.folder)navigate(locationPath+'/'+f.name);else{if(!selection.has(f.name))selection=new Set([f.name]);render();if(!$('#accept').disabled)accept();}}
function validName(n){return n.trim().length>0&&!/[\/\x00]/.test(n)&&n!=='.'&&n!=='..';}
function openDialog(action,title,copy,button){dialogAction=action;dialogOpener=document.activeElement;$('#confirm-title').textContent=title;$('#confirm-copy').textContent=copy;$('#confirm-ok').textContent=button;$('#confirm-ok').disabled=false;$('#folder-field').hidden=action!=='folder';$('#confirm-icon').innerHTML=icon(action==='folder'?'plus':'warning');$('#confirm').showModal();(action==='folder'?$('#folder-name'):$('#confirm-cancel')).focus();}
function newFolder(){openDialog('folder','Create a folder',`The new folder will be created in ${locationPath}.`,'Create folder');$('#folder-name').select();}
function accept(){if($('#accept').disabled)return;if(mode==='save'&&data().some(f=>f.name===$('#filename').value)){openDialog('replace',`Replace “${$('#filename').value}”?`,'A file with this name already exists in this folder. Saving will replace its contents.','Replace');return;}toast(mode==='save'?`Mock result: ${locationPath}/${$('#filename').value}`:mode==='batch'?'Mock result: 3 destinations returned in input order':`Mock result: ${[...selection].join(', ')||locationPath}`);}
function configure(value){mode=value in scenarios?value:'wallpaper';state='ready';selection=new Set(mode==='wallpaper'?['Coast.jpg']:mode==='open'?['Field notes.txt','Project brief.md']:mode==='portal'?['Coast.jpg','Dunes.jpg']:[]);locationPath=scenarios[mode].path;history=[];extra=[];listView=['open','folder','save','batch'].includes(mode);$('#search').value='';$('#scenario').value=mode;$('#state').value=state;$('#filename').value='Field notes.txt';$('#filter').innerHTML=scenarios[mode].filter.map(v=>`<option>${escape(v)}</option>`).join('');render();}
$('#scenario').onchange=e=>configure(e.target.value);$('#state').onchange=e=>{state=e.target.value;if(state!=='ready'&&state!=='failed')selection.clear();render();};$('#search').oninput=render;$('#filter').onchange=render;$('#filename').oninput=render;
$('#view').onclick=()=>{listView=!listView;render();};$('#hidden').onclick=()=>{hidden=!hidden;render();};$('#sort').onclick=()=>{reverse=!reverse;render();};$('#back').onclick=()=>{if(history.length)navigate(history.pop(),false);};$('#up').onclick=()=>navigate(locationPath.split('/').slice(0,-1).join('/')||'Home');
$('#places').onclick=()=>{const on=$('#sidebar').classList.toggle('open');$('#places').setAttribute('aria-expanded',String(on));};$('#new-folder').onclick=newFolder;
$('#location-toggle').onclick=()=>{$('#location-toggle').hidden=true;$('#location').hidden=false;$('#location').value=locationPath;$('#location').focus();$('#location').select();};$('#location').onkeydown=e=>{if(e.key==='Enter')navigate($('#location').value.replace(/^\/+|\/+$/g,'')||'Home');if(e.key==='Escape'){$('#location').hidden=true;$('#location-toggle').hidden=false;$('#location-toggle').focus();e.stopPropagation();}};
$('#accept').onclick=accept;$('#cancel').onclick=$('#close').onclick=()=>{selection.clear();render();toast('Mock result: cancelled. The caller keeps its previous selection.');};
$('#theme').onclick=()=>{const light=document.body.classList.toggle('light');$('#theme').textContent=light?'Dark appearance':'Light appearance';};
$('#folder-name').oninput=()=>{$('#confirm-ok').disabled=!validName($('#folder-name').value)||data().some(f=>f.name===$('#folder-name').value);};
$('#confirm').addEventListener('close',()=>{if($('#confirm').returnValue==='accept'){if(dialogAction==='folder'){extra.push({name:$('#folder-name').value,folder:true,meta:'Empty folder'});state='ready';$('#state').value=state;selection=new Set([$('#folder-name').value]);render();toast('Folder created in the mockup.');}else toast('Mock result: replacement confirmed. Coral would now save the document.');}if(dialogOpener?.isConnected)dialogOpener.focus();});
document.addEventListener('keydown',e=>{if($('#confirm').open)return;if(e.key==='Escape'){if($('#sidebar').classList.contains('open')){$('#sidebar').classList.remove('open');$('#places').setAttribute('aria-expanded','false');$('#places').focus();}else $('#cancel').click();}if(e.ctrlKey&&e.key.toLowerCase()==='l'){e.preventDefault();$('#location-toggle').click();}if(e.ctrlKey&&e.key.toLowerCase()==='h'){e.preventDefault();$('#hidden').click();}if(e.ctrlKey&&e.key.toLowerCase()==='f'){e.preventDefault();$('#search').focus();}if(e.ctrlKey&&e.key.toLowerCase()==='a'&&!['INPUT','SELECT'].includes(document.activeElement.tagName)&&['open','portal'].includes(mode)){e.preventDefault();selection=new Set(current.filter(f=>!f.folder).map(f=>f.name));render();}});
for(const [id,name] of [['back','back'],['up','up'],['places','menu'],['new-folder','plus'],['hidden','eye'],['search-icon','search']])$('#'+id).innerHTML=icon(name);
const params=new URLSearchParams(location.search);configure(params.get('mode')||'wallpaper');if(params.get('theme')==='light')$('#theme').click();if(params.has('state')){state=params.get('state');$('#state').value=state;render();}if(params.get('dialog')==='replace'&&mode==='save')accept();
