const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const icons = {
  branch:"M6 4v13m0-5c7 0 10-2 10-7 M8 4a2 2 0 1 1-4 0 2 2 0 1 1 4 0 M8 19a2 2 0 1 1-4 0 2 2 0 1 1 4 0 M18 4a2 2 0 1 1-4 0 2 2 0 1 1 4 0",
  sidebar:"M3 4h18v16H3z M9 4v16",split:"M3 4h18v16H3z M12 4v16", layers:"m12 3 9 5-9 5-9-5z M3 12l9 5 9-5 M3 16l9 5 9-5",
  spark:"m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z",theme:"M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z",
  clip:"m8 13 6-6a3 3 0 0 1 4 4l-8 8a5 5 0 0 1-7-7l9-9",up:"M12 19V5 M6 11l6-6 6 6"
};
document.querySelectorAll("[data-i]").forEach(el => {el.innerHTML = '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="'+icons[el.dataset.i]+'"/></svg>';});
const files = {
  "session.zig":'const std = @import("std");\nconst Store = @import("store.zig").Store;\n\npub const Session = struct {\n    id: []const u8,\n    store: *Store,\n\n    /// Restore the last visible message.\n    pub fn restore(self: *Session) !usize {\n        const saved = try self.store.load(self.id);\n        return saved.cursor;\n    }\n\n    pub fn title(self: *Session) []const u8 {\n        return self.store.title(self.id);\n    }\n};',
  "store.zig":'pub const Store = struct {\n    cursor: usize,\n\n    pub fn lastCursor(self: *Store) usize {\n        return self.cursor;\n    }\n};',
  "events.zig":'pub const Event = union(enum) {\n    resumed: usize,\n    completed,\n    needs_attention,\n};',
  "build.zig":'const std = @import("std");\n\npub fn build(b: *std.Build) void {\n    _ = b;\n}'
};
const groups = [
  ["Restore session cursor","Running","◌","Keep the reading position when I reopen a session.","I found the restore path. A saved cursor can point past the final message after history is trimmed."],
  ["Review file watcher","Needs attention","◇","Check the watcher tests in the worktree.","The watcher change is ready. I need permission to run its focused test."],
  ["Tidy status labels","Completed","✓","Make completed sessions easier to scan.","Updated the labels and verified the three session states."]
];
const before = '        return saved.cursor;';
const after = '        return @min(saved.cursor, saved.last_index);';
const local = '        return saved.last_read;';
const params = new URLSearchParams(location.search);
const original = {...files};
let scene, file, session, split, opened, approval, applied, queues, messages, attachments, dock, selected, dirty, reviewLine;
const modelPicker = $("session-model");
const modelMenu = $("model-menu");
const modelChoices = Array.from(modelMenu.querySelectorAll("input"));
let sessionModels;
function announce(s){$("announce").textContent=s;}
function reset(view) {
  Object.assign(files, original);
  sessionModels = ["anthropic/claude-sonnet-4", "openai/gpt-4.1", "openai/gpt-4.1-mini"];
  scene = ["edit","review","conflict"].includes(view) ? view : "edit";
  $("scene").value=view==="model" ? "model" : scene; session=0; file="session.zig"; opened=[file,"store.zig"]; split=false; approval=null; applied=false; dirty=new Set();reviewLine=scene==="conflict"?local:before;
  queues=[["Add a regression test."],[],[]];messages=[[],[],[]];attachments=[{label:"session.zig · L9–12",text:files[file].split("\n").slice(8,12).join("\n")},null,null]; selected=null;
  dock=scene==="edit"?"Terminal":"Task output";$("prompt").value="";
  if(scene==="conflict"){files[file]=files[file].replace(before,local);dirty.add(file);}
  render();
  if (view === "model") modelMenu.showPopover();
  else modelMenu.hidePopover();
}
function syntax(s){
  return s.split(/(\/\/.*|"(?:[^"\\]|\\.)*"|\b(?:pub|const|fn|return|try|struct|usize|enum|union|void)\b|@\w+|\b\w+(?=\())/g).map((part,i)=>{
    if(i%2===0)return esc(part);
    const kind=part.startsWith("//")?"comment":part.startsWith('"')?"str":/^(pub|const|fn|return|try|struct|usize|enum|union|void)$/.test(part)?"kw":"fn";
    return '<span class="'+kind+'">'+esc(part)+'</span>';
  }).join("");
}
function pane(name,editable,title){
  const lines=files[name].split("\n");
  const numbered=lines.map((_,i)=>i+1).join("\n");
  const code=lines.map((s,i)=>{
    let html=syntax(s);
    if(name==="session.zig" && i===10 && s===before)html='<span class="bad">'+html+'</span>';
    return name==="session.zig" && i>=8 && i<=11 && !dirty.has(name)?'<span class="sel">'+html+'</span>':html;
  }).join("\n");
  return '<section class="codearea">'+(title?'<div class="panename">'+esc(title)+'</div>':'')+'<div class="codegrid"><pre class="nums" aria-hidden="true">'+numbered+'</pre><pre role="textbox" aria-label="'+name+'" aria-multiline="true" class="source" data-name="'+name+'" contenteditable="'+(editable?"plaintext-only":"false")+'" spellcheck="false">'+code+'</pre></div></section>';
}
function nav(){
  $("files").innerHTML=Object.keys(files).slice(0,3).map(n=>'<button data-file="'+n+'"><b class="zig">Z</b> '+n+'</button>').join("");
  document.querySelectorAll("[data-file]").forEach(b=>b.classList.toggle("current",b.dataset.file===file));
  $("sessions").innerHTML=groups.map((g,i)=>'<button class="session '+(session===i?"active":"")+'" aria-pressed="'+(i===session)+'" data-session="'+i+'"><span class="signal '+["","attention","done"][i]+'">'+g[2]+'</span><span>'+g[0]+'<small>'+status(i)+'</small></span></button>').join("");
}
function status(i){return i===1 && approval ? (approval==="Allowed"?"Running":"Paused") : i===0 && scene!=="edit" && !applied?"Needs review":groups[i][1];}
function editor(){
  $("filetabs").innerHTML=opened.map(n=>'<button class="'+(n===file?'active':'')+'" data-open="'+n+'"><b class="zig">Z</b> '+n+(dirty.has(n)?' •':'')+'</button>').join("");
  $("crumb").innerHTML=(file==="build.zig"?'pearl':'src <span>›</span> workspace')+' <span>›</span> '+file+(scene!=="edit"?' <span>›</span> Review':'');
  $("split").disabled=scene!=="edit";$("split").setAttribute("aria-pressed",String(split));
  const area=$("editorbody");
  if(scene==="edit"){
    const other=file==="store.zig"?"session.zig":"store.zig";
    area.innerHTML=split?'<div class="splits">'+pane(file,true,file)+pane(other,true,other)+'</div>':pane(file,true,"");
  }else{
    const conflict=scene==="conflict", verb=conflict?"Use agent line":"Apply hunk";
    const names=conflict?["Your unsaved buffer","Agent worktree"]:["Shared base","Agent worktree"];
    const changes='<div class="diff"><div class="hunk">@@ restore · lines 9–12 @@</div><div>  pub fn restore(self: *Session) !usize {</div><div>      const saved = try self.store.load(self.id);</div><div class="minus">− '+esc(before.trimStart())+'</div><div class="plus">+ '+esc(after.trimStart())+'</div><div>  }</div></div>';
    const side=(name,line)=>'<section class="codearea"><div class="panename">'+name+'</div><div class="diff"><div class="hunk">L11</div><div>'+esc(line.trim())+'</div></div></section>';
    area.innerHTML='<div class="reviewhead"><h1>'+(conflict?"Resolve overlapping edits":"Review agent change")+'</h1><p>'+(conflict?"Your unsaved edit and the agent changed the same line. Choose which line to keep in the editor.":"Clamp the restored cursor to the final message. One file changed in the agent worktree.")+'</p>'+(applied?'<span class="result">✓ '+esc(applied)+'</span>':'<button class="act" data-resolution="agent">'+verb+'</button> <button class="secondary" data-resolution="mine">'+(conflict?"Keep my line":"Skip hunk")+'</button>')+'</div><div class="panename">session.zig &nbsp; · &nbsp; +1 / −1</div>'+changes+(conflict?'<div class="compare">'+side(names[0],reviewLine)+side(names[1],after)+'</div>':'');
  }
  $("editstatus").textContent=dirty.has(file)?"Unsaved buffer · UTF-8":"UTF-8";
}
function chat(){
  const choice = modelChoices.find(input => input.value === sessionModels[session]);
  choice.checked = true;
  const modelName = choice.nextElementSibling.textContent;
  $("model-name").textContent = modelName;
  modelPicker.setAttribute("aria-label", "Change session model, currently " + modelName);
  const g=groups[session];
  let action='';
  if(session===0)action='<div class="actioncard"><strong>Changes in worktree</strong><code>session.zig <span class="add">+1</span> / −1</code><button class="secondary" id="viewchange">'+(scene==="edit"?"Review change":"Return to editor")+' →</button></div>';
  if(session===1)action='<div class="actioncard"><strong>Permission requested</strong><code>zig build test</code>'+(approval?'<span class="result">'+approval+'</span>':'<button class="act" data-permission="Allowed">Allow once</button> <button class="secondary" data-permission="Denied">Deny</button>')+'</div>';
  $("thread").innerHTML='<h1 class="threadtitle">'+g[0]+'</h1><div class="threadmeta">Pearl &nbsp;·&nbsp; '+status(session)+'</div><div class="speaker"><span class="avatar">Y</span>You</div><div class="userbubble">'+g[3]+'</div><div class="speaker"><span class="avatar">✧</span>OpenCode</div><p>'+g[4]+'</p>'+action+messages[session].map(m=>'<div class="speaker">You</div><p>'+esc(m)+'</p>').join("");
  $("queue").innerHTML=queues[session].length?'<div class="queuetitle">Queued prompts · '+queues[session].length+'</div>'+queues[session].map((q,i)=>'<div class="queueitem"><button aria-label="Remove queued prompt" data-remove="'+i+'">×</button>'+esc(q)+'</div>').join(""):"";
  const a=attachments[session];$("attachment").innerHTML=a?'<button type="button" id="detach" class="chip" aria-label="Remove attached selection" title="'+esc(a.text)+'">'+esc(a.label)+' ×</button>':"";
}
function bottom(){
  document.querySelectorAll("[data-dock]").forEach(b=>b.classList.toggle("active",b.dataset.dock===dock));
  $("dockcontent").innerHTML=dock==="Terminal"?'<span class="terminalprompt">pearl</span> <span class="quiet">~/Projects/pearl</span>  $ git branch --show-current\nworkspace-review\n<span class="terminalprompt">❯</span> ▏':dock==="Problems"?'<button id="problem">◇ session.zig · 11 &nbsp; Saved cursor may exceed the last message index →</button>':'<span class="quiet">Agent worktree / restore-session-cursor</span>\n<span class="terminalprompt">✓</span> Captured base revision\n<span class="terminalprompt">✓</span> Prepared change for review';
}
function render(){nav();editor();chat();bottom();$("footerstate").textContent="OpenCode · 3 sessions";}
function useFile(n){scene="edit";$("scene").value=scene;file=n;if(!opened.includes(n))opened.push(n);render();}
function noteSelection(){
  const selection=window.getSelection();
  if(!selection.rangeCount||selection.isCollapsed)return;
  const range=selection.getRangeAt(0), start=range.startContainer.parentElement?.closest(".source"),end=range.endContainer.parentElement?.closest(".source");
  if(!start || start!==end)return;
  const lead=range.cloneRange();lead.selectNodeContents(start);lead.setEnd(range.startContainer,range.startOffset);
  const first=lead.toString().split("\n").length,text=range.toString(),last=first+text.split("\n").length-1;
  selected={label:start.dataset.name+" · L"+first+(last===first?"":"–"+last),text};
}
document.addEventListener("selectionchange",noteSelection);
$("editorbody").addEventListener("input",e=>{
  const node=e.target.closest(".source");if(!node)return;
  const n=node.dataset.name;files[n]=node.innerText;dirty.add(n);
  node.closest(".codegrid").querySelector(".nums").textContent=files[n].split("\n").map((_,i)=>i+1).join("\n");
  const tab=Array.from(document.querySelectorAll("[data-open]")).find(b=>b.dataset.open===n);
  if(tab&&!tab.textContent.endsWith(" •"))tab.append(" •");
  $("editstatus").textContent="Unsaved buffer · UTF-8";
});
const drafts=["","",""];
$("prompt").addEventListener("input",()=>{drafts[session]=$("prompt").value;});
function selectModel(choice) {
  sessionModels[session] = choice.value;
  chat();
  modelMenu.hidePopover();
  modelPicker.focus();
  announce(groups[session][0] + " will use " + $("model-name").textContent + " for its next model call.");
}
modelMenu.addEventListener("click", event => {
  if (event.target.matches("input")) selectModel(event.target);
});
modelMenu.addEventListener("keydown", event => {
  if (event.key === "Enter" && event.target.matches("input")) {
    event.preventDefault();
    selectModel(event.target);
  }
});
modelPicker.addEventListener("keydown", event => {
  if (event.key === "ArrowDown") {
    event.preventDefault();
    modelMenu.showPopover();
    modelMenu.querySelector(":checked").focus();
  }
});
document.addEventListener("click",e=>{
  const b=e.target.closest("button");if(!b)return;
  if(b.dataset.file || b.dataset.open)useFile(b.dataset.file || b.dataset.open);
  else if(b.dataset.session!==undefined){session=Number(b.dataset.session);$("prompt").value=drafts[session];nav();chat();}
  else if(b.dataset.dock){dock=b.dataset.dock;bottom();}
  else if(b.id==="theme"){document.documentElement.dataset.theme=document.documentElement.dataset.theme==="light"?"dark":"light";}
  else if(b.id==="split"){split=!split;editor();}
  else if(b.id==="viewchange"){if(scene==="edit"){reviewLine=files["session.zig"].split("\n")[10]??"";scene=reviewLine===before || applied?"review":"conflict";}else{scene="edit";}file="session.zig";$("scene").value=scene;render();}
  else if(b.id==="problem"){useFile("session.zig");const src=document.querySelector(".source");src.focus();src.querySelector(".bad")?.scrollIntoView({block:"nearest"});}
  else if(b.dataset.permission){approval=b.dataset.permission;nav();chat();}
  else if(b.dataset.remove!==undefined){queues[session].splice(Number(b.dataset.remove),1);chat();}
  else if(b.id==="detach"){attachments[session]=null;chat();}
  else if(b.id==="attach"){if(selected){attachments[session]={...selected};chat();}else{announce("Highlight code in the editor first.");$("prompt").placeholder="Highlight code, then choose Selection.";}}
  else if(b.dataset.resolution){
    if(b.dataset.resolution==="mine")applied=scene==="conflict"?"Kept your line":"Skipped this hunk";
    else {
      const n="session.zig",old=reviewLine;
      const lines=files[n].split("\n");
      if(lines[10]!==old){announce("The buffer changed. Reopen the overlapping edits preview to compare its sample revisions.");return;}
      lines[10]=after;files[n]=lines.join("\n");dirty.add(n);applied="Applied to unsaved buffer";
    }
    render();announce(applied);
  }
});
$("composer").addEventListener("submit",e=>{
  e.preventDefault();const prompt=$("prompt").value.trim();if(!prompt)return;
  const a=attachments[session],entry=prompt+(a?" ["+a.label+"]":"");
  (session===2?messages:queues)[session].push(entry);
  drafts[session]="";$("prompt").value="";attachments[session]=null;chat();announce(session===2?"Message added to sample thread":"Prompt queued");
});
$("scene").addEventListener("change",()=>{drafts.fill("");reset($("scene").value);});
document.documentElement.dataset.theme=params.get("theme")==="light"?"light":"dark";
reset(params.get("view") || "model");
