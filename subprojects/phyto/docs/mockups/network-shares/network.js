'use strict';
const $ = s => document.querySelector(s);
const icons = {
  leaf: '<path d="M20 4C10 2 3 6 4 13s9 9 13 3c3-4 3-8 3-12Z"/><path d="M5 20 16 8"/>',
  home: '<path d="m3 10 9-7 9 7v10H3Z"/><path d="M9 20v-7h6v7"/>',
  network: '<rect x="8" y="3" width="8" height="6" rx="1"/><path d="M12 9v5M4 17v-3h16v3"/><rect x="1" y="17" width="6" height="4" rx="1"/><rect x="9" y="17" width="6" height="4" rx="1"/><rect x="17" y="17" width="6" height="4" rx="1"/>',
  server: '<rect x="4" y="3" width="16" height="8" rx="2"/><rect x="4" y="13" width="16" height="8" rx="2"/><path d="M8 7h.01M8 17h.01M13 7h3M13 17h3"/>',
  folder: '<path d="M3 6h7l2 3h9v11H3Z"/><path d="M3 9h18"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v3"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.server}</svg>`;
document.querySelectorAll('[data-icon]').forEach(el => el.innerHTML = icon(el.dataset.icon));
const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const key = 'phyto-network-proposal-v1';
const seeds = () => [
  {id:'studio', name:'Studio NAS', uri:'smb://nas.example/Design', policy:'on-open'},
  {id:'dev', name:'Development server', uri:'sftp://dev.example/home/zoey', policy:'on-click'},
  {id:'archive', name:'Design archive', uri:'davs://cloud.example/Archive', policy:'on-click'}
];
let profiles = seeds(), runtime = {}, jobs = new Map(), view = 'network', revision = 0;
let editing = null, authId = null, forgetId = null;
let storageAvailable = true;
try {
  const saved = localStorage.getItem(key);
  if (saved) {
    const parsed = JSON.parse(saved);
    if (Array.isArray(parsed) && parsed.every(p => p && typeof p.id === 'string' && typeof p.name === 'string' && typeof p.uri === 'string' && ['on-click','on-open'].includes(p.policy))) profiles = parsed;
  }
} catch { storageAvailable = false; }
function persist(next) {
  try { localStorage.setItem(key, JSON.stringify(next)); return true; }
  catch { $('#storage-note').textContent = 'Browser storage unavailable. Changes cannot be saved.'; return false; }
}
if (!storageAvailable) $('#storage-note').textContent = 'Browser storage unavailable. Changes cannot be saved.';
function state(id) { return runtime[id] || 'disconnected'; }
const statusLabel = value => ({connected:'Connected', connecting:'Connecting…', disconnected:'Disconnected', failed:'Could not connect', 'needs-auth':'Sign-in required'}[value]);
const policyLabel = p => p.policy === 'on-open' ? 'When Phyto opens' : 'When I click the network device';
function feedback(text) { $('#notice').textContent = text; }
function closePlaces() { $('.sidebar').classList.remove('open'); $('#places-toggle').setAttribute('aria-expanded','false'); }
function go(where) { revision++; view = where; closePlaces(); render(); }
function render() {
  $('#devices').innerHTML = profiles.map(p => `<button class="place device ${view === p.id ? 'active' : ''}" data-action="open" data-id="${escapeHTML(p.id)}">${icon('server')}<span class="device-copy"><strong>${escapeHTML(p.name)}</strong><small>${statusLabel(state(p.id))}</small></span></button>`).join('');
  $('#network').classList.toggle('active', view === 'network');
  $('#home').classList.toggle('active', view === 'home');
  const current = profiles.find(p => p.id === view);
  $('#location').textContent = current ? current.name : view === 'home' ? 'Home' : 'Network';
  $('.window-title').textContent = $('#location').textContent;
  $('#status-text').textContent = `${profiles.length} saved devices · ${profiles.filter(p => state(p.id) === 'connected').length} connected`;
  if (current && state(current.id) === 'connected') {
    $('#content').innerHTML = `<div class="browse-caption"><span class="badge connected">Connected</span><span>${escapeHTML(current.uri)}</span><button data-action="settings" data-id="${escapeHTML(current.id)}">Connection settings…</button></div><div class="folder-grid">${['Projects','Shared assets','Reference','Deliverables','Archive','Team'].map(n => `<div class="folder">${icon('folder')}<span>${n}</span></div>`).join('')}</div>`;
  } else if (view === 'home') {
    $('#content').innerHTML = `<div class="section-heading"><h2>Folders</h2><span>Local browsing stays available</span></div><div class="folder-grid">${['Documents','Downloads','Pictures'].map(n => `<div class="folder">${icon('folder')}<span>${n}</span></div>`).join('')}</div>`;
  } else {
    $('#content').innerHTML = `<div class="section-heading"><h2>Saved connections</h2><span>${profiles.length} devices</span></div>${profiles.length ? profiles.map(card).join('') : '<div class="empty-state">'+icon('network')+'<h3>Your servers, in one place</h3><p>Add a connection to keep it in Places and choose when it reconnects.</p><button class="primary" data-action="add">Add connection…</button></div>'}`;
  }
}
function card(p) {
  const s = state(p.id), id = escapeHTML(p.id);
  const action = s === 'connecting' ? 'cancel' : s === 'connected' ? 'open' : s === 'needs-auth' ? 'signin' : 'open';
  const label = s === 'connecting' ? 'Cancel' : s === 'connected' ? 'Open' : s === 'needs-auth' ? 'Sign in…' : s === 'failed' ? 'Retry' : 'Connect';
  return `<article class="connection-card" data-card="${id}"><div class="server-icon">${icon('server')}</div><div class="connection-info"><div class="card-title"><h3>${escapeHTML(p.name)}</h3><span class="badge ${s}">${statusLabel(s)}</span></div><p class="endpoint">${escapeHTML(p.uri)}</p><p class="policy">${icon('clock')}<span>${policyLabel(p)}</span></p>${s === 'failed' ? '<p class="failure">Server unavailable. Your connection is still saved.</p>' : ''}${s === 'needs-auth' ? '<p class="failure">Sign in when you’re ready. Your other files are available.</p>' : ''}</div><div class="card-buttons"><button class="tonal" data-action="${action}" data-id="${id}">${label}</button>${s === 'connected' ? `<button data-action="disconnect" data-id="${id}">Disconnect</button>` : ''}<button class="settings" data-action="settings" data-id="${id}" aria-label="Settings for ${escapeHTML(p.name)}" title="Connection settings">⚙</button><button data-action="forget" data-id="${id}" aria-label="Forget ${escapeHTML(p.name)}">Forget…</button></div></article>`;
}
function cancel(id) { const job = jobs.get(id); if (job) clearTimeout(job.timer); jobs.delete(id); runtime[id] = 'disconnected'; }
function connect(id, interactive = true, signedIn = false) {
  const p = profiles.find(p => p.id === id); if (!p) return;
  if (state(id) === 'connected') { if (interactive) go(id); return; }
  const intent = interactive ? revision : null;
  if (jobs.has(id)) { if (interactive) jobs.get(id).intent = intent; return; }
  const result = signedIn ? 'success' : $('#outcome').value;
  if (result === 'auth' && interactive) { showAuth(id); return; }
  runtime[id] = 'connecting'; render();
  const job = {intent, timer: null};
  job.timer = setTimeout(() => {
    if (jobs.get(id) !== job || !profiles.some(p => p.id === id)) return;
    jobs.delete(id);
    runtime[id] = result === 'offline' ? 'failed' : result === 'auth' ? 'needs-auth' : 'connected';
    if (state(id) === 'connected' && job.intent !== null && job.intent === revision) { view = id; revision++; }
    feedback(result === 'success' ? `${p.name} connected.${job.intent === null ? ' Your current folder stays open.' : ''}` : result === 'offline' ? `${p.name} is unavailable. The saved connection is ready to retry.` : `${p.name} needs sign-in. Click the device when you’re ready.`);
    render();
  }, 850);
  jobs.set(id, job);
}
function startup(message = true) {
  for (const id of jobs.keys()) cancel(id);
  runtime = {}; revision++; view = 'network'; render();
  if (message) feedback('Phyto reopened. Only devices set to “When Phyto opens” reconnect automatically.');
  profiles.filter(p => p.policy === 'on-open').forEach(p => connect(p.id, false));
}
function openEditor(id = null) {
  editing = id;
  const p = profiles.find(p => p.id === id);
  $('#connection-form').reset();
  $('#editor-title').textContent = p ? 'Connection settings' : 'Add connection';
  $('#name').value = p?.name || ''; $('#address').value = p?.uri || '';
  $(`input[name="policy"][value="${p?.policy || 'on-click'}"]`).checked = true;
  $('#save-later').hidden = !!p;
  $('#save-connect').textContent = p ? 'Save changes' : 'Save and connect';
  $('#form-error').hidden = true;
  $('#editor').showModal(); $('#name').focus();
}
function normalize(raw) {
  const uri = new URL(raw.trim());
  if (!['smb:','sftp:','dav:','davs:'].includes(uri.protocol) || !uri.hostname || /\s/.test(uri.host) || uri.search || uri.hash || uri.password || (uri.port && (+uri.port < 1 || +uri.port > 65535))) throw new Error('Use a valid SMB, SFTP or WebDAV address without a password, query or fragment.');
  uri.hostname = uri.hostname.toLowerCase();
  if ({'smb:':'445','sftp:':'22','dav:':'80','davs:':'443'}[uri.protocol] === uri.port) uri.port = '';
  if (!uri.pathname) uri.pathname = '/';
  return uri.href;
}
$('#connection-form').addEventListener('submit', event => {
  event.preventDefault();
  try {
    const name = $('#name').value.trim(); if (!name) throw new Error('Enter a connection name.');
    const uri = normalize($('#address').value);
    if (profiles.some(p => p.id !== editing && normalize(p.uri) === uri)) throw new Error('This address is already saved. Edit its existing connection in Network.');
    const p = {id:editing || crypto.randomUUID(), name, uri, policy:$('input[name="policy"]:checked').value};
    const old = profiles.find(item => item.id === editing);
    const next = editing ? profiles.map(item => item.id === editing ? p : item) : [...profiles,p];
    if (!persist(next)) throw new Error('Connection was not saved. Enable browser storage and try again. Your entries are still here.');
    if (old && old.uri !== p.uri) cancel(p.id);
    profiles = next; $('#editor').close(); render();
    feedback(`${p.name} saved. Reconnect: ${policyLabel(p)}.${editing ? ' Startup changes apply next time Phyto opens.' : ''}`);
    if (!editing && event.submitter?.value === 'connect') connect(p.id);
  } catch (err) { $('#form-error').textContent = err instanceof TypeError ? 'Enter a complete server address, such as smb://nas.example/Design.' : err.message; $('#form-error').hidden = false; }
});
function showAuth(id) { authId = id; runtime[id] = 'needs-auth'; render(); $('#auth-target').textContent = profiles.find(p => p.id === id)?.name || ''; $('#auth').showModal(); }
$('#demo-signin').onclick = () => { const id = authId; $('#auth').close(); connect(id, true, true); };
$('#auth').addEventListener('close', () => { authId = null; });
document.addEventListener('click', event => {
  const close = event.target.closest('[data-close]'); if (close) { $('#'+close.dataset.close).close(); return; }
  const example = event.target.closest('[data-example]');
  if (example) { const values = {smb:['Studio NAS','smb://nas.example/Design'], sftp:['Development server','sftp://dev.example/home/zoey'], davs:['Design archive','davs://cloud.example/Archive']}[example.dataset.example]; $('#name').value = values[0]; $('#address').value = values[1]; return; }
  const button = event.target.closest('[data-action]'); if (!button) return;
  const id = button.dataset.id;
  switch(button.dataset.action) {
    case 'add': openEditor(); break;
    case 'open': case 'signin': closePlaces(); connect(id); break;
    case 'settings': openEditor(id); break;
    case 'cancel': cancel(id); render(); feedback('Connection cancelled. The device is still saved.'); break;
    case 'disconnect': cancel(id); if (view === id) go('network'); else render(); feedback('Disconnected. The device and its reconnect preference are still saved.'); break;
    case 'forget': forgetId = id; $('#forget-target').textContent = profiles.find(p => p.id === id).name; $('#forget').showModal(); break;
  }
});
$('#confirm-forget').onclick = () => {
  const next = profiles.filter(p => p.id !== forgetId);
  if (!persist(next)) { $('#forget-target').textContent = 'Could not save the removal. Close this dialog and try again.'; return; }
  cancel(forgetId); profiles = next; if (view === forgetId) go('network');
  $('#forget').close(); render(); feedback('Saved connection forgotten. Remote files and existing mounts are unchanged.');
};
$('#add').onclick = $('#add-side').onclick = () => openEditor();
$('#network').onclick = $('#back').onclick = () => go('network');
$('#home').onclick = () => go('home');
$('#restart').onclick = () => startup();
$('#reset').onclick = () => { if (persist(seeds())) { profiles = seeds(); $('#outcome').value = 'success'; startup(); } };
$('#theme').onclick = () => { document.body.classList.toggle('light'); $('#theme').textContent = document.body.classList.contains('light') ? 'Dark appearance' : 'Light appearance'; };
$('#places-toggle').onclick = () => { const open = $('.sidebar').classList.toggle('open'); $('#places-toggle').setAttribute('aria-expanded', String(open)); };
document.addEventListener('keydown', event => { if (event.key === 'Escape') closePlaces(); });
startup(false);
if (new URLSearchParams(location.search).get('screen') === 'add') openEditor();
