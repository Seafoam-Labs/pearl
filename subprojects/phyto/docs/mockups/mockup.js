/* Fictional, in-memory review UI. No filesystem, network or persistence APIs. */
const $ = s => document.querySelector(s);
const paths = {
  folder:'M3 6h6l2 2h10v11H3z M3 6V4h6l2 2',
  home:'m3 10 9-7 9 7 M5 9v12h5v-7h4v7h5V9',
  download:'M12 3v12 m-5-5 5 5 5-5 M4 17v4h16v-4',
  file:'M5 3h9l5 5v13H5z M14 3v6h5 M8 13h8 M8 17h6',
  image:'M3 4h18v16H3z m0 12 6-6 5 5 3-3 4 4 M16 8h.01',
  music:'M9 18V5l11-2v13 M9 7l11-2 M9 18c0 4-6 4-6 1s6-4 6-1 M20 16c0 4-6 4-6 1s6-4 6-1',
  video:'M3 5h18v14H3z m7 4 6 3-6 3z',
  clock:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M12 7v5l3 2',
  trash:'M3 6h18 M9 6V3h6v3 M5 6l1 15h12l1-15 M10 10v7 M14 10v7',
  drive:'M5 4h14l3 13v3H2v-3z M3 15h18 M16 18h2',
  network:'M4 4h16v9H4z M12 13v6 M4 20h16 M4 18v3 M20 18v3',
  star:'m12 3 3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z',
  back:'m14 6-6 6 6 6',forward:'m10 6 6 6-6 6',up:'m6 14 6-6 6 6',
  search:'M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0 m-2 5 6 6',
  grid:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
  list:'M3 5h2 M9 5h12 M3 12h2 M9 12h12 M3 19h2 M9 19h12',
  split:'M3 4h18v16H3z M12 4v16',details:'M3 4h18v16H3z M15 4v16 M18 8h0 M18 12h0',
  more:'M5 12h.01 M12 12h.01 M19 12h.01',menu:'M4 6h16 M4 12h16 M4 18h16',
  transfer:'M3 8h16 m-4-4 4 4-4 4 M21 16H5 m4-4-4 4 4 4',
  leaf:'M5 19C0 7 12 3 21 3c0 10-4 20-16 16 M5 19l10-10',
  lock:'M5 10h14v11H5z M8 10V6a4 4 0 0 1 8 0v4 M12 14v3',
  check:'m5 12 4 4L20 5',plus:'M12 4v16 M4 12h16'
};
function icon(name){return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name]||paths.file}"/></svg>`;}
function escapeText(value){return String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
const fixtures = [
  ['Documents','folder','24 items','Today, 10:42'],['Downloads','folder','8 items','Today, 09:18'],
  ['Music','folder','16 items','Yesterday'],['Pictures','folder','32 items','Yesterday'],
  ['Projects','folder','6 items','Today, 11:05'],['Videos','folder','4 items','18 Sep 2026'],
  ['Design system.fig','design','2.4 MB','Today, 10:42'],['Coastline.png','landscape','4.8 MB','Yesterday'],
  ['Notes.md','file','3.2 KB','Today, 09:12'],['Release brief.pdf','file','840 KB','18 Sep 2026'],
  ['Palette.svg','image','12 KB','Yesterday'],['Welcome.txt','file','1.1 KB','18 Sep 2026']
].map(([name,type,size,date])=>({name,type,size,date}));
const projectFiles=[['Assets','folder','12 items'],['Mockups','folder','8 items'],['Research','folder','4 items'],['Design system.fig','design','2.4 MB'],['README.md','file','3.2 KB'],['Release brief.pdf','file','840 KB']].map(([name,type,size])=>({name,type,size,date:'Today, 10:42'}));
const downloadFiles=[['References','folder','6 items'],['Coastline.png','landscape','4.8 MB'],['Palette.svg','image','12 KB'],['Notes.md','file','3.2 KB']].map(([name,type,size])=>({name,type,size,date:'Today, 09:18'}));
const scenes = {
 grid:['01','Familiar places. A quieter workspace. Details when you need them.'],
 list:['02','A denser view, with filenames first and useful metadata in reach.'],
 split:['03','Two destinations. Independent tabs. One clearly active pane.'],
 search:['04','Find by name, with the search scope and every result’s location visible.'],
 transfer:['05','Progress stays visible. Conflicts wait for an explicit decision.'],
 empty:['06','A useful starting point, with navigation always available.'],
 error:['07','Explain the problem. Keep the path back. Offer a clear next step.']
};
const params=new URLSearchParams(location.search);
let state={scene:scenes[params.get('view')]?params.get('view'):'grid',mode:'grid',place:'Home',selected:'Design system.fig',details:true,hidden:false,sort:'name',activePane:0,split:false,paneModes:['list','grid'],paneSelections:['Design system.fig',''],query:'design'};
const mappings={'brand-icon':'leaf',back:'back',forward:'forward',up:'up','places-toggle':'menu','search-toggle':'search',jobs:'transfer',more:'more','split-toggle':'split','grid-view':'grid','list-view':'list','details-toggle':'details'};
Object.entries(mappings).forEach(([id,symbol])=>$('#'+id).innerHTML=icon(symbol));
document.body.classList.toggle('light',params.get('theme')==='light');
document.body.classList.toggle('compact',params.get('compact')==='1');
function notify(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(notify.timer);notify.timer=setTimeout(()=>$('#toast').classList.remove('visible'),3500);}
function art(file){return ['design','landscape'].includes(file.type)?`<span class="art-preview ${file.type}" aria-hidden="true"></span>`:icon(file.type);}
function places(){
 const groups=[['PLACES',[['Home','home'],['Recent','clock'],['Documents','file'],['Downloads','download'],['Pictures','image'],['Music','music'],['Videos','video'],['Trash','trash']]],['BOOKMARKS',[['Projects','folder']]],['DEVICES',[['File System','drive'],['Studio SSD','drive'],['Network','network']]]];
 $('#places').innerHTML=groups.map(([label,rows])=>`<div class="side-group">${label}</div>${rows.map(([name,symbol])=>`<button class="place ${name===state.place?'active':''}" data-place="${name}" ${name===state.place?'aria-current="page"':''}>${icon(symbol)}<span>${name}</span>${name==='Studio SSD'?'<span class="eject" aria-hidden="true">⏏</span>':''}</button>`).join('')}`).join('');
}
function filesFor(place){
 let files=place==='Home'?fixtures:place==='Projects'?projectFiles:place==='Downloads'?downloadFiles:fixtures.filter(f=>f.type!=='folder');
 if(place==='Pictures')files=files.filter(f=>['image','landscape'].includes(f.type));
 if(['Trash','Music','Videos','Network','Studio SSD','File System','Recent'].includes(place))files=[];
 if(state.hidden)files=[...files,{name:'.config',type:'folder',size:'18 items',date:'Yesterday'}];
 return [...files].sort((a,b)=>(a.type==='folder'?0:1)-(b.type==='folder'?0:1)||(state.sort==='type'?a.type.localeCompare(b.type):0)||a.name.localeCompare(b.name));
}
function fileCard(f,selected=state.selected){return `<button class="file-card ${f.type==='folder'?'folder':''} ${f.name===selected?'selected':''}" data-file="${escapeText(f.name)}" title="${escapeText(f.name)}" aria-pressed="${f.name===selected}">${art(f)}<span class="filename">${escapeText(f.name)}</span>${f.type==='folder'?`<span class="file-meta">${f.size}</span>`:''}</button>`;}
function fileList(files,search=false,selected=state.selected){return `<div class="list-head ${search?'search-result':''}"><span>Name ↑</span><span>${search?'Location':'Size'}</span><span>${search?'Size':'Modified'}</span></div>${files.map(f=>`<button class="file-row ${search?'search-result':''} ${f.name===selected?'selected':''}" data-file="${escapeText(f.name)}" aria-pressed="${f.name===selected}"><span class="name">${icon(f.type==='folder'?'folder':f.type==='landscape'?'image':'file')}<span>${escapeText(f.name)}</span></span><span class="cell">${search?escapeText(f.path):f.size}</span><span class="cell">${search?f.size:f.date}</span></button>`).join('')}`;}
function emptyState(kind){const error=kind==='error';return `<div class="empty-state">${icon(error?'lock':'folder')}<h3>${error?'This folder is private':'A little room for something new'}</h3><p>${error?'You don’t have permission to view “Archive”. Try again after access has been granted, or return to Home.':'This folder is empty. Create a folder or copy files here to get started.'}</p><div class="actions">${error?'<button class="tonal" data-go-home>Go to Home</button><button class="primary" data-retry>Try again</button>':'<button class="tonal" data-new-folder>New folder</button>'}</div></div>`;}
function searchFiles(){return [{name:'Design system.fig',type:'design',size:'2.4 MB',date:'Today',path:'Home'},{name:'Design notes.md',type:'file',size:'8 KB',date:'Today',path:'Documents / Pearl'},{name:'Design review.pdf',type:'file',size:'1.2 MB',date:'Yesterday',path:'Projects / Phyto'}].filter(f=>f.name.toLowerCase().includes(state.query.toLowerCase()));}
function pane(place,index,mode){
 let files=filesFor(place), content='';
 const selected=state.split?state.paneSelections[index]:state.selected;
 if(['empty','error'].includes(state.scene))content=emptyState(state.scene);
 else if(state.scene==='search'){files=searchFiles();content=files.length?fileList(files,true):'<div class="empty-state">'+icon('search')+'<h3>No matching filenames</h3><p>Try a shorter name or a different search.</p></div>';}
 else if(!files.length)content=emptyState('empty');
 else if(mode==='list')content=fileList(files,false,selected);
 else {const folders=files.filter(f=>f.type==='folder'),regular=files.filter(f=>f.type!=='folder');content=(folders.length?`<div class="section-label">FOLDERS</div><div class="file-grid">${folders.map(f=>fileCard(f,selected)).join('')}</div>`:'')+(regular.length?`<div class="section-label">FILES</div><div class="file-grid">${regular.map(f=>fileCard(f,selected)).join('')}</div>`:'');}
 return `<section class="pane ${state.split&&index===state.activePane?'active-split':''} ${state.split&&index!==state.activePane?'inactive-narrow':''}" data-pane="${index}" aria-label="${state.split?(index===state.activePane?'Active ':'')+(index===0?'left':'right')+' pane: ':''}${escapeText(place)}"><div class="tabs"><button class="tab active" data-tab="${escapeText(place)}">${icon('folder')}${escapeText(place)}</button>${!state.split?'<button class="tab" data-tab="Projects">'+icon('folder')+'Projects</button>':''}<button class="tab-plus" data-add-tab aria-label="New tab">+</button></div>${state.split?`<div class="pane-label"><span>Home / ${escapeText(place)}</span>${index===state.activePane?'<strong>ACTIVE PANE</strong>':''}<button class="pane-switch" data-switch-pane>Switch pane</button></div>`:''}<div class="files">${content}</div>${state.split?`<div class="pane-footer">${files.length} items${selected?' · 1 selected':''}</div>`:''}</section>`;
}
function renderDetails(){
 const f=[...fixtures,...projectFiles,...downloadFiles,...searchFiles()].find(f=>f.name===state.selected);
 $('#details').hidden=!state.details||state.split||['empty','error','search'].includes(state.scene)||!f;
 if(!f)return;
 $('#details').innerHTML=`<div class="details-header"><span>File details</span><button aria-label="Close file details" id="close-details">×</button></div><div class="details-art">${art(f)}</div><h3>${escapeText(f.name)}</h3><p class="filetype">${f.type==='folder'?'Folder':f.type==='design'?'Figma document':f.type==='landscape'?'PNG image':'Document'}</p><dl><dt>Location</dt><dd>Home${state.place==='Home'?'':' / '+escapeText(state.place)}</dd><dt>Size</dt><dd>${f.size}</dd><dt>Modified</dt><dd>${f.date}</dd><dt>Access</dt><dd>You can read and write</dd></dl><button class="properties" id="properties">Properties</button>`;
 $('#close-details').onclick=()=>{state.details=false;render();};
 $('#properties').onclick=()=>notify('Properties would show full metadata, permissions and the application used to open this file.');
}
function render(){
 if(state.split){state.place=state.activePane===0?'Projects':'Downloads';state.mode=state.paneModes[state.activePane];state.selected=state.paneSelections[state.activePane];}
 $('#scene').value=state.scene;
 $('#theme').textContent=document.body.classList.contains('light')?'Dark':'Light';
 $('#density').setAttribute('aria-pressed',document.body.classList.contains('compact'));
 places();
 const title=state.scene==='search'?'Search results':state.scene==='empty'?'New project':state.scene==='error'?'Archive':state.split?'Projects & Downloads':state.place;
 $('.window-title').textContent=title;
 $('#breadcrumbs').innerHTML=`<button class="ancestor" data-go-home aria-label="Go to Home">${icon('home')}</button><span class="divider">›</span><button class="current" id="location-edit">${escapeText(state.split?(state.activePane===0?'Projects':'Downloads'):state.scene==='search'?'Home':title)}</button>`;
 $('#location-edit').onclick=()=>notify('Native Ctrl+L will let you enter any local path or supported URI. Use Places to navigate this fixture.');
 $('#grid-view').setAttribute('aria-pressed',state.mode==='grid');$('#list-view').setAttribute('aria-pressed',state.mode==='list');
 $('#details-toggle').setAttribute('aria-pressed',state.details);$('#split-toggle').setAttribute('aria-pressed',state.split);
 $('.searchbar').hidden=state.scene!=='search';
 if(document.activeElement!==$('#query'))$('#query').value=state.query;
 $('#panes').innerHTML=state.split?pane('Projects',0,state.paneModes[0])+pane('Downloads',1,state.paneModes[1]):pane(state.place,0,state.mode);
 renderDetails();
 let count=state.scene==='search'?searchFiles().length:filesFor(state.place).length;
 $('#status-text').textContent=state.split?'Left: Projects  ·  Right: Downloads':state.scene==='error'?'Permission denied':state.scene==='empty'?'0 items':state.scene==='search'?`${count} matches · Search complete`:`${count} items${state.selected?' · 1 selected':''}`;
 $('#status-right').textContent=state.hidden?'Hidden files visible':'184 GB available';
 $('#scenario-number').textContent=scenes[state.scene][0];$('#scenario-note').textContent=scenes[state.scene][1];
}
function setScene(scene){
 state.scene=scene;state.mode=['list','search'].includes(scene)?'list':'grid';state.split=scene==='split';state.place=scene==='split'?'Projects':'Home';state.selected=['empty','error'].includes(scene)?'':'Design system.fig';state.details=true;state.activePane=0;state.paneModes=['list','grid'];state.paneSelections=['Design system.fig',''];
 if($('#operation-dialog').open)$('#operation-dialog').close();
 render();if(scene==='transfer')openOperations(true);
}
function navigate(place){state.place=place;state.scene='grid';state.split=false;state.selected='';$('.sidebar').classList.remove('open');render();}
function openOperations(conflict=false){
 const dialog=$('#operation-dialog');
 dialog.innerHTML=`<div class="dialog-top"><h2 id="operation-title">File operations</h2><button class="icon" id="close-operations" aria-label="Close file operations">×</button></div><p class="muted" style="font-size:12px">Copying 8 files to Studio SSD</p><div class="job-summary"><b style="font-weight:500;font-size:14px">Projects → Studio SSD / Pearl</b><p>${conflict?'Waiting for your decision':'Copying Coastline.png'}</p><div class="progress"><i></i></div><div class="progress-meta"><span>5 of 8 files · 128 MB of 200 MB</span><span>${conflict?'Action needed':'24 MB/s · About 3 seconds left'}</span></div></div>${conflict?`<div class="conflict-heading">${icon('file')}<div><h3>A file with this name already exists</h3><p>Choose what to do with “Design system.fig”.</p></div></div><div class="compare"><div><span>COPYING FROM</span><b>Design system.fig</b><p>Projects / Pearl</p><p>2.4 MB · Today, 10:42</p></div><div><span>ALREADY AT DESTINATION</span><b>Design system.fig</b><p>Studio SSD / Pearl</p><p>1.8 MB · Yesterday, 16:20</p></div></div><label class="check"><input type="checkbox" id="all-conflicts"> Apply to remaining file conflicts in this transfer</label><div class="dialog-actions"><button data-resolution="Skip">Skip</button><button data-resolution="Replace">Replace</button><button class="primary" data-resolution="Keep both" autofocus>Keep both</button></div>`:'<div class="dialog-actions"><button class="tonal" id="cancel-copy">Cancel transfer</button></div>'}`;
 if(!dialog.open)dialog.showModal();
 $('#close-operations').onclick=()=>dialog.close();
 if($('#cancel-copy'))$('#cancel-copy').onclick=()=>{dialog.close();notify('Preview transfer cancelled. No real files were changed.');};
 dialog.querySelectorAll('[data-resolution]').forEach(button=>button.onclick=()=>{const choice=button.dataset.resolution;dialog.close();notify(choice==='Keep both'?'Preview: copy saved as “Design system (copy).fig”.':`Preview conflict choice: ${choice}. No real files were changed.`);});
}
$('#scene').onchange=e=>setScene(e.target.value);
$('#theme').onclick=()=>{document.body.classList.toggle('light');render();};
$('#density').onclick=()=>{document.body.classList.toggle('compact');render();};
$('#grid-view').onclick=()=>{state.mode='grid';if(state.split)state.paneModes[state.activePane]='grid';if(state.scene==='search')state.scene='grid';if(!state.split)state.scene='grid';render();};
$('#list-view').onclick=()=>{state.mode='list';if(state.split)state.paneModes[state.activePane]='list';if(!state.split)state.scene='list';render();};
$('#split-toggle').onclick=()=>setScene(state.split?'grid':'split');
$('#details-toggle').onclick=()=>{state.details=!state.details;render();};
$('#places-toggle').onclick=()=>{$('.sidebar').classList.toggle('open');$('#places-toggle').setAttribute('aria-expanded',$('.sidebar').classList.contains('open'));};
$('#search-toggle').onclick=()=>{setScene('search');$('#query').focus();$('#query').select();};
$('#clear-search').onclick=()=>setScene('grid');
$('#query').oninput=e=>{state.query=e.target.value;render();};
$('#jobs').onclick=()=>openOperations(false);
$('#more').onclick=()=>$('#options-dialog').showModal();
$('#options-done').onclick=()=>$('#options-dialog').close();
$('#hidden-files').onchange=e=>{state.hidden=e.target.checked;render();};
$('#sort').onchange=e=>{state.sort=e.target.value;render();};
$('#back').onclick=$('#up').onclick=()=>navigate('Home');
document.addEventListener('click',e=>{
 const place=e.target.closest('[data-place]');if(place){navigate(place.dataset.place);return;}
 if(e.target.closest('[data-go-home]')){navigate('Home');return;}
 if(e.target.closest('[data-retry]')){notify('Preview: access is still denied. Navigation remains available.');return;}
 if(e.target.closest('[data-new-folder]')){notify('New folder would open a name entry in the native application.');return;}
 if(e.target.closest('[data-switch-pane]')){state.activePane=1-state.activePane;render();return;}
 if(e.target.closest('[data-add-tab]')){notify('Native tabs will preserve independent location, selection and history. Try the Projects tab in this preview.');return;}
 const tab=e.target.closest('[data-tab]');if(tab&&!state.split){navigate(tab.dataset.tab);return;}
 const file=e.target.closest('[data-file]');if(file){state.selected=file.dataset.file;const p=file.closest('[data-pane]');if(p)state.activePane=Number(p.dataset.pane);if(state.split)state.paneSelections[state.activePane]=state.selected;render();const focused=[...document.querySelectorAll('[data-file]')].find(el=>el.dataset.file===state.selected&&(!state.split||Number(el.closest('[data-pane]').dataset.pane)===state.activePane));focused?.focus({preventScroll:true});}
});
document.addEventListener('keydown',e=>{
 if(e.key==='Escape'){$('.sidebar').classList.remove('open');$('#places-toggle').setAttribute('aria-expanded','false');return;}
 if(e.target.matches('input,select')||document.querySelector('dialog[open]'))return;
 if(e.key==='F3'){e.preventDefault();setScene(state.split?'grid':'split');}
 if(e.key==='F6'&&state.split){e.preventDefault();state.activePane=1-state.activePane;render();}
 if(e.ctrlKey&&e.key==='f'){e.preventDefault();setScene('search');$('#query').focus();$('#query').select();}
 if(e.ctrlKey&&e.key==='h'){e.preventDefault();state.hidden=!state.hidden;$('#hidden-files').checked=state.hidden;render();}
 if(e.ctrlKey&&['1','2'].includes(e.key)){e.preventDefault();$('#'+(e.key==='1'?'grid-view':'list-view')).click();}
});
setScene(state.scene);
