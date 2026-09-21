'use strict';
const $ = s => document.querySelector(s);
const icons = {
  coral:'M6 21V11m0 5-3-3m3 0 4-4M12 21V5m0 7 4-4m-4 1L8 5m10 16V12m0 5 3-3M3 21h18',
  folder:'M3 7V5h6l2 2h10v13H3Z', document:'M6 3h8l4 4v14H6ZM14 3v5h4M9 12h6m-6 4h6',
  save:'M4 3h13l3 3v15H4ZM8 3v6h8V3M8 21v-8h8v8', search:'M10 17a7 7 0 1 0 0-14 7 7 0 0 0 0 14Zm5-2 6 6',
  settings:'M4 7h16M4 17h16M8 4v6m8 4v6', plus:'M12 5v14M5 12h14',
  spell:'m3 13 4-10 4 10M5 9h4m4 8 3 3 5-7', replace:'M4 7h14l-3-3m3 3-3 3M20 17H6l3-3m-3 3 3 3',
  check:'m5 12 4 4L19 6', warning:'m12 3 10 18H2ZM12 9v5m0 3v.2', close:'m6 6 12 12M6 18 18 6'
};
function icon(name){return `<svg class="icon-svg" viewBox="0 0 24 24" aria-hidden="true"><path d="${icons[name] || icons.document}"/></svg>`;}
function mountIcons(){document.querySelectorAll('[data-icon]').forEach(el => el.innerHTML = icon(el.dataset.icon));}
const esc = text => text.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const writing = `# A quieter workspace

A few notes on making space for the things that matter.

## Start with less

A good workspace doesn't need to do everything. It needs
 to make the everyday things feel a little more considered.

Keep the essentials close. Leave room for an unexpected
idea, a rough first draft, or a small moment of curiousity.

## Small things, done well

- A comfortable place to write and think
- Familiar shortcuts that stay out of the way
- A gentle nudge when a word isn't quite right
- The confidence that your work is saved

The details make a difference. A calmer colour, a useful
suggestion, a little more breathing room between thoughts.
That's where the rythym starts to feel right.

---

Next: take a walk, come back, and read it once more.
`.replace('\n to make','\nto make');
const todo = '# For another day\n\n- [ ] Pick up a new notebook\n- [ ] Finish the workspace notes\n- [x] Make a little room to think\n\nOne thing at a time.\n';
const zig = '// A small beginning\nconst std = @import("std");\n\npub fn main() void {\n    std.debug.print("Hello, Coral!\\n", .{});\n}\n';
const typos = {curiousity:['curiosity'], rythym:['rhythm'], mispelled:['misspelled'], teh:['the'], recieve:['receive']};
let serial = 0;
function doc(name,text,dirty=false){return {id:++serial,name,text,saved:dirty ? text.replace('A quieter','A quiet') : text,ignored:new Set(),cursor:0};}
let docs,active,scene='editor',spellEnabled=true,dictionary=true,personal=new Set(),language='en_US',toastTimer;
const current = () => docs.find(d => d.id===active);
const dirty = d => d.text !== d.saved;
const notes = {editor:'Your words, with room to breathe.',spelling:'A gentle correction, right where you need it.',search:'Find the thought. Make the change.',empty:'Every document begins with a little space.',missing:'Keep writing, even when a dictionary is unavailable.',conflict:'A clear choice when a file changes elsewhere.',unsaved:'Your work stays yours to keep.',preferences:'A few useful choices. Nothing to get lost in.'};
function issues(){if(!spellEnabled || !dictionary || current().name.endsWith('.zig'))return [];return [...current().text.matchAll(/\b(?:curiousity|rythym|mispelled|teh|recieve)\b/g)].filter(m => !current().ignored.has(m[0]) && !personal.has(m[0])).map(m=>({word:m[0],start:m.index,end:m.index+m[0].length}));}
function toast(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),3500);}
function setTheme(light){document.body.classList.toggle('light',light);$('#theme').textContent=light?'Dark':'Light';$('#theme').setAttribute('aria-label',`Switch to ${light?'dark':'light'} appearance`);}
function reset(view){
  if($('#modal').open)$('#modal').close();
  scene=view;$('#scene').value=view;spellEnabled=true;dictionary=view!=='missing';personal=new Set();
  docs=[doc('a quieter workspace.md',writing,true),doc('weekend.txt',todo),doc('hello.zig',zig)];active=docs[0].id;
  if(view==='empty'){docs=[doc('Untitled','')];active=docs[0].id;}
  $('#query').value=view==='search'?'little':'';$('#replacement').value=view==='search'?'more':'';
  $('#searchbar').hidden=view!=='search';$('#spelling-popover').hidden=true;
  $('#scene-note').textContent=notes[view];$('#scene-number').textContent=String(Object.keys(notes).indexOf(view)+1).padStart(2,'0');
  renderDocument();renderBanner();
  if(view==='spelling')showSpelling();
  if(view==='preferences')preferences();
  if(view==='unsaved')closeTab(active);
}
function renderTabs(){
  $('#tab-list').innerHTML=docs.map(d=>`<div class="tab-group ${d.id===active?'active':''}"><button class="tab" role="tab" aria-selected="${d.id===active}" data-tab="${d.id}" title="${esc(d.name)}">${icon('document')}<span class="tab-title">${esc(d.name)}</span>${dirty(d)?'<span class="dirty-dot" aria-label="Unsaved changes"></span>':''}</button><button class="tab-close" data-close="${d.id}" aria-label="Close ${esc(d.name)}">×</button></div>`).join('');
  $('#document-title').textContent=current().name;$('#dirty-label').hidden=!dirty(current());
  $('#language').textContent=current().name.endsWith('.md')?'Markdown':current().name.endsWith('.zig')?'Zig':'Plain Text';
}
function renderDocument(){renderTabs();$('#editor').value=current().text;$('#editor').setSelectionRange(current().cursor,current().cursor);$('#editor').scrollTop=0;renderText();}
function matches(){const q=$('#query').value;if(!q || $('#searchbar').hidden)return [];const t=current().text.toLowerCase(),n=q.toLowerCase(),out=[];let at=0;while((at=t.indexOf(n,at))!==-1){out.push({start:at,end:at+q.length});at+=q.length;}return out;}
function renderText(){
  const text=current().text,miss=issues(),found=matches();let offset=0;
  $('#highlight').innerHTML=text.split('\n').map(line=>{
    const start=offset;offset+=line.length+1;
    const ranges=[...miss.filter(r=>r.start>=start&&r.end<=start+line.length).map(r=>({...r,cls:'misspelled'})),...found.filter(r=>r.start>=start&&r.end<=start+line.length).map(r=>({...r,cls:'search-match'}))].sort((a,b)=>a.start-b.start);
    let html='',at=0;for(const range of ranges){const a=range.start-start,b=range.end-start;if(a<at)continue;html+=esc(line.slice(at,a))+`<span class="${range.cls}">${esc(line.slice(a,b))}</span>`;at=b;}html+=esc(line.slice(at));
    const cls=line.startsWith('#')?'syntax-heading':line.startsWith('//')||line==='---'?'syntax-marker':line.startsWith('const ')||line.startsWith('pub ')?'syntax-code':'';
    return `<span class="code-line ${cls}">${html || '\u200b'}</span>`;
  }).join('');
  $('#gutter').innerHTML=text.split('\n').map((_,i)=>`<span>${i+1}</span>`).join('');
  $('#word-count').textContent=`${text.trim()?text.trim().split(/\s+/).length:0} words`;
  $('#empty-hint').hidden=!!text;
  $('#match-count').textContent=`${found.length} match${found.length===1?'':'es'}`;
  $('#replace-one').disabled=!found.length;$('#replace-all').disabled=!found.length;
  $('#spelling-label').textContent=!dictionary?'Dictionary unavailable':!spellEnabled||current().name.endsWith('.zig')?'Spelling off':miss.length?`${miss.length} spelling suggestion${miss.length===1?'':'s'}`:'Spelling checked';
  $('#spelling-status').classList.toggle('unavailable',!dictionary);
  syncLayout();position();
}
function syncLayout(){const lines=$('#highlight').children;[...$('#gutter').children].forEach((el,i)=>el.style.height=`${lines[i].getBoundingClientRect().height}px`);syncScroll();}
function syncScroll(){$('#highlight').scrollTop=$('#editor').scrollTop;$('#highlight').scrollLeft=$('#editor').scrollLeft;$('#gutter').scrollTop=$('#editor').scrollTop;}
function position(){const e=$('#editor'),before=e.value.slice(0,e.selectionStart),line=before.split('\n').length,col=[...before.split('\n').pop()].length+1;current().cursor=e.selectionStart;$('#position').textContent=`Ln ${line}, Col ${col}`;[...$('#gutter').children].forEach((el,i)=>el.classList.toggle('current',i===line-1));}
function changeText(text,start=0,end=start){current().text=text;current().cursor=start;$('#editor').value=text;$('#editor').focus();$('#editor').setSelectionRange(start,end);$('#spelling-popover').hidden=true;renderTabs();renderText();}
function replaceRange(start,end,value){changeText(current().text.slice(0,start)+value+current().text.slice(end),start,start+value.length);}
function showSpelling(){
  if(!dictionary||!spellEnabled){preferences();return;}
  const issue=issues().find(i=>i.start<=$('#editor').selectionStart&&i.end>=$('#editor').selectionStart)||issues()[0];
  if(!issue){toast('No fixture spelling suggestions in this document.');return;}
  const pop=$('#spelling-popover');
  pop.innerHTML=`<header><strong>${esc(issue.word)}</strong><span>Spelling</span></header>${typos[issue.word].map(w=>`<button class="suggestion" data-correction="${w}">${icon('check')}${w}</button>`).join('')}<hr><button id="ignore-word">Ignore for this document</button><button id="add-word">Add to dictionary</button><hr><footer><span>${language==='en_GB'?'English (UK)':'English (US)'}</span><button id="change-language">Change…</button></footer>`;pop.hidden=false;
  pop.querySelectorAll('[data-correction]').forEach(b=>b.onclick=()=>{if(current().text.slice(issue.start,issue.end)!==issue.word){pop.hidden=true;return;}replaceRange(issue.start,issue.end,b.dataset.correction);toast('Spelling corrected in the sample document.');});
  $('#ignore-word').onclick=()=>{current().ignored.add(issue.word);pop.hidden=true;renderText();toast('Ignored in this document.');};
  $('#add-word').onclick=()=>{personal.add(issue.word);pop.hidden=true;renderText();toast('Added to the preview dictionary until reload.');};
  $('#change-language').onclick=preferences;
  const marker=[...document.querySelectorAll('.misspelled')].find(el=>el.textContent===issue.word);
  if(marker){
    const area=$('.editor').getBoundingClientRect();
    let word=marker.getBoundingClientRect();
    if(word.bottom>area.bottom-20 || word.top<area.top){$('#editor').scrollTop+=word.top-area.top-55;syncScroll();word=marker.getBoundingClientRect();}
    const left=Math.max(12,Math.min(word.left-area.left,area.width-pop.offsetWidth-12));
    const below=word.bottom-area.top+12;
    const top=below+pop.offsetHeight<=area.height-12?below:Math.max(12,word.top-area.top-pop.offsetHeight-12);
    pop.style.left=`${left}px`;pop.style.right='auto';pop.style.top=`${top}px`;
  }
}
function modal(title,body,actions=''){$('#spelling-popover').hidden=true;const el=$('#modal');el.innerHTML=`<div class="dialog-top"><h2 id="modal-title">${title}</h2><button class="icon" data-dismiss aria-label="Close dialog">×</button></div>${body}${actions?`<div class="dialog-actions">${actions}</div>`:''}`;el.querySelectorAll('[data-dismiss]').forEach(b=>b.onclick=()=>el.close());if(!el.open)el.showModal();}
function preferences(){
  modal('Make yourself at home',`<p>A few small choices for a comfortable writing space.</p><label class="option"><span>Appearance<small>Match your workspace</small></span><select id="pref-theme"><option value="dark">Pearl dark</option><option value="light">Pearl light</option></select></label><label class="option"><span>Text size<small>Monospace editor font</small></span><select id="pref-size"><option value="12">12 px</option><option value="14">14 px</option><option value="16">16 px</option><option value="18">18 px</option></select></label><label class="option"><span>Line numbers</span><input id="pref-lines" type="checkbox" ${$('#gutter').hidden?'':'checked'}></label><label class="option"><span>Check spelling<small>Local suggestions while you write</small></span><input id="pref-spell" type="checkbox" ${spellEnabled?'checked':''}></label><label class="option"><span>Spelling language<small>${dictionary?'Sample English dictionaries':'No dictionary installed in this scenario'}</small></span><select id="pref-language" ${dictionary?'':'disabled'}><option value="en_US">English (US)</option><option value="en_GB">English (UK)</option></select></label>`,'<button class="primary" data-dismiss>Done</button>');
  $('#pref-theme').value=document.body.classList.contains('light')?'light':'dark';$('#pref-theme').onchange=e=>setTheme(e.target.value==='light');
  $('#pref-size').value=String(parseInt(getComputedStyle(document.documentElement).getPropertyValue('--editor-size')));$('#pref-size').onchange=e=>{document.documentElement.style.setProperty('--editor-size',`${e.target.value}px`);document.documentElement.style.setProperty('--leading',`${Number(e.target.value)+14}px`);syncLayout();};
  $('#pref-lines').onchange=e=>{$('#gutter').hidden=!e.target.checked;syncLayout();};$('#pref-spell').onchange=e=>{spellEnabled=e.target.checked;renderText();};$('#pref-language').value=language;$('#pref-language').onchange=e=>{language=e.target.value;renderText();};
}
function newDoc(){const d=doc('Untitled','');docs.push(d);active=d.id;$('#banner').hidden=true;$('#spelling-popover').hidden=true;renderDocument();$('#editor').focus();}
function removeTab(id){docs=docs.filter(d=>d.id!==id);if(!docs.length){docs=[doc('Untitled','')];toast('Last tab closed. The preview starts a fresh document.');}if(active===id)active=docs[0].id;renderDocument();}
function closeTab(id){const d=docs.find(d=>d.id===id);if(!dirty(d)){removeTab(id);return;}modal('Save your changes?',`<p>Your changes to <strong>${esc(d.name)}</strong> haven't been saved. Keep them before closing this tab?</p>`,'<button data-dismiss>Cancel</button><button class="danger" id="discard">Discard</button><button class="primary" id="save-close">Save changes</button>');$('#discard').onclick=()=>{$('#modal').close();removeTab(id);};$('#save-close').onclick=()=>{active=id;$('#modal').close();save(()=>removeTab(id));};}
function save(after){if(scene==='conflict'){conflictDialog();return;}if(current().name==='Untitled'){modal('Save document','<p>Choose a name for this sample. No file will be written.</p><label class="sr-only" for="save-name">File name</label><input class="dialog-input" id="save-name" value="Untitled.txt">','<button data-dismiss>Cancel</button><button class="primary" id="save-named">Save preview</button>');$('#save-named').onclick=()=>{const name=$('#save-name').value.trim();if(!name)return;current().name=name;$('#modal').close();finishSave(after);};return;}finishSave(after);}
function finishSave(after){current().saved=current().text;renderTabs();toast('Saved in the preview. No file was written.');if(after)after();}
function renderBanner(){const b=$('#banner');b.hidden=!['missing','conflict'].includes(scene);if(scene==='missing'){b.innerHTML=`<span>${icon('spell')}</span><p>Spell checking needs a dictionary.<small>You can keep writing. Choose an installed language to check spelling.</small></p><button id="dictionary-info">Details</button>`;$('#dictionary-info').onclick=()=>modal('No spelling dictionary','<p>The native app will use locally installed Enchant dictionaries. This scenario illustrates the unavailable state; the preview does not install packages.</p>','<button data-dismiss class="primary">Keep writing</button>');}else if(scene==='conflict'){b.innerHTML=`<span>${icon('warning')}</span><p>This file changed on disk.<small>Your edits are still here. Review the change before saving.</small></p><button id="review-conflict">Review changes</button>`;$('#review-conflict').onclick=conflictDialog;}}
function conflictDialog(){modal('This file changed elsewhere',`<p>Keep your edits in a copy, reload the changed file, or overwrite it with your version. These actions affect sample text only.</p>`,'<button data-dismiss>Cancel</button><button id="reload-disk">Reload</button><button class="danger" id="overwrite">Overwrite</button><button class="primary" id="save-copy">Save a copy</button>');const resolve=()=>{$('#modal').close();scene='editor';$('#scene').value='editor';$('#banner').hidden=true;};$('#reload-disk').onclick=()=>{modal('Discard your current edits?','<p>Reloading replaces this tab with the simulated disk version.</p>','<button data-dismiss>Cancel</button><button class="danger" id="confirm-reload">Discard and reload</button>');$('#confirm-reload').onclick=()=>{resolve();changeText(writing.replace('A quieter workspace','Notes from another window'));finishSave();};};$('#overwrite').onclick=()=>{resolve();finishSave();};$('#save-copy').onclick=()=>{resolve();current().name='a quieter workspace (copy).md';finishSave();};}
function openSample(){modal('Open a sample document',`<p>Explore a few examples. These files live only in the preview.</p>${[['Weekend notes','weekend.txt'],['A small beginning','hello.zig']].map(([title,name])=>`<button class="file-option" data-sample="${name}">${icon('document')}<span>${title}<small>${name}</small></span></button>`).join('')}`);document.querySelectorAll('[data-sample]').forEach(b=>b.onclick=()=>{let d=docs.find(d=>d.name===b.dataset.sample);if(!d){d=doc(b.dataset.sample,b.dataset.sample.endsWith('.zig')?zig:todo);docs.push(d);}active=d.id;$('#modal').close();renderDocument();});}
function toggleSearch(show=true){$('#searchbar').hidden=!show;renderText();if(show)$('#query').focus();}
function nextMatch(back=false){const found=matches();if(!found.length)return;const e=$('#editor');let m=back?[...found].reverse().find(m=>m.start<e.selectionStart):found.find(m=>m.start>=e.selectionEnd);m=m||(back?found.at(-1):found[0]);e.focus();e.setSelectionRange(m.start,m.end);position();}
$('#tab-list').onclick=e=>{const close=e.target.closest('[data-close]'),tab=e.target.closest('[data-tab]');if(close)closeTab(Number(close.dataset.close));else if(tab){active=Number(tab.dataset.tab);$('#spelling-popover').hidden=true;renderDocument();}};
$('#editor').oninput=()=>{current().text=$('#editor').value;$('#spelling-popover').hidden=true;renderTabs();renderText();};
$('#editor').onscroll=syncScroll;$('#editor').onclick=position;$('#editor').onkeyup=position;
$('#editor').oncontextmenu=e=>{e.preventDefault();showSpelling();};
$('#query').oninput=renderText;$('#match-next').onclick=()=>nextMatch();$('#match-prev').onclick=()=>nextMatch(true);
$('#replace-one').onclick=()=>{const found=matches(),at=$('#editor').selectionStart;const m=found.find(m=>m.start>=at)||found[0];if(m)replaceRange(m.start,m.end,$('#replacement').value);};
$('#replace-all').onclick=()=>{const found=matches();if(!found.length)return;let text=current().text;for(const m of [...found].reverse())text=text.slice(0,m.start)+$('#replacement').value+text.slice(m.end);changeText(text);toast(`Replaced ${found.length} matches in the sample.`);};
$('#search-toggle').onclick=()=>toggleSearch($('#searchbar').hidden);$('#search-close').onclick=()=>toggleSearch(false);
$('#new').onclick=newDoc;$('#open').onclick=openSample;$('#save').onclick=()=>save();$('#preferences').onclick=preferences;$('#spelling-status').onclick=showSpelling;
$('#theme').onclick=()=>setTheme(!document.body.classList.contains('light'));$('#scene').onchange=e=>reset(e.target.value);
document.addEventListener('pointerdown',e=>{if(!e.target.closest('#spelling-popover,#spelling-status'))$('#spelling-popover').hidden=true;});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){$('#spelling-popover').hidden=true;if(!$('#modal').open)toggleSearch(false);return;}if($('#modal').open)return;const ctrl=e.ctrlKey||e.metaKey;if(ctrl&&['s','o','n','f','h','w'].includes(e.key.toLowerCase())){e.preventDefault();({s:()=>save(),o:openSample,n:newDoc,f:()=>toggleSearch(),h:()=>toggleSearch(),w:()=>closeTab(active)})[e.key.toLowerCase()]();}if(e.key==='F3'){e.preventDefault();nextMatch(e.shiftKey);}if(e.key==='F10'&&e.shiftKey){e.preventDefault();showSpelling();$('#spelling-popover button')?.focus();}if(ctrl&&e.key==='Tab'){e.preventDefault();const i=docs.findIndex(d=>d.id===active);active=docs[(i+(e.shiftKey?-1:1)+docs.length)%docs.length].id;renderDocument();}});
new ResizeObserver(syncLayout).observe($('.text-area'));
mountIcons();const params=new URLSearchParams(location.search);setTheme(params.get('theme')==='light');reset(Object.hasOwn(notes,params.get('view'))?params.get('view'):'editor');
