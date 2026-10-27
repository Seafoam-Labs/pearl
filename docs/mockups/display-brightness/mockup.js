'use strict';
const $ = id => document.getElementById(id);
const initial = () => [
  {id:'studio', name:'Studio display', detail:'DP-1 · External display', value:68, supported:true, on:true},
  {id:'builtin', name:'Built-in display', detail:'eDP-1 · Laptop display', value:42, supported:true, on:true},
  {id:'projector', name:'Projector', detail:'HDMI-A-1 · External display', value:100, supported:false, on:true}
];
let displays = initial(), selected = 'studio', expanded = true, pending = null, generation = 0;
const current = () => displays.find(d => d.id === selected);
function paint(input) { input.style.setProperty('--value', `${input.value}%`); }
function feedback(text, error = false) { $('feedback').textContent = text; $('feedback').classList.toggle('error', error); }
function render() {
  const d = current();
  $('selected-name').textContent = d.name;
  $('selected-detail').textContent = d.detail;
  $('count').textContent = `${displays.length} displays`;
  $('brightness').value = d.value;
  $('brightness').disabled = !d.supported || !d.on;
  $('brightness').setAttribute('aria-label', `${d.name} brightness`);
  $('brightness-value').textContent = d.supported ? `${d.value}%` : '—';
  paint($('brightness'));
  feedback(!d.on ? 'Screen is off. Brightness is remembered.' : !d.supported ? 'This display does not offer brightness control.' : 'Brightness is up to date.');
  $('power').textContent = d.on ? 'Turn off' : 'Restore screen';
  $('power').setAttribute('aria-label', `${d.on ? 'Turn off' : 'Restore'} ${d.name}`);
  $('power-title').textContent = d.on ? 'Screen power' : 'Screen is off';
  $('power-hint').textContent = d.on ? 'Keeps your desktop layout' : 'Move the mouse or press a key to wake';
  $('display-list').hidden = !expanded;
  $('display-picker').setAttribute('aria-expanded', String(expanded));
  $('chevron').textContent = expanded ? '⌃' : '⌄';
  $('display-list').replaceChildren(...displays.map(display => {
    const button = document.createElement('button');
    button.className = 'display-option';
    button.dataset.display = display.id;
    button.setAttribute('aria-pressed', String(display.id === selected));
    button.innerHTML = `<span class="check" aria-hidden="true">${display.id === selected ? '✓' : ''}</span><span class="display-copy"><strong>${display.name}</strong><small>${display.detail}</small></span><span class="reading">${!display.on ? 'Off' : display.supported ? `${display.value}%` : 'Unavailable'}</span>`;
    button.addEventListener('click', () => { cancelPending(); selected = display.id; render(); document.querySelector(`[data-display="${selected}"]`).focus(); });
    return button;
  }));
}
function cancelPending() { clearTimeout(pending); pending = null; generation++; }
$('brightness').addEventListener('input', () => {
  cancelPending(); const d = current(), token = generation, requested = Number($('brightness').value);
  paint($('brightness')); $('brightness-value').textContent = `${requested}%`; feedback(`Applying ${requested}%…`);
  pending = setTimeout(() => {
    if (token !== generation) return;
    pending = null;
    if ($('scenario').value === 'denied') {
      render(); feedback(`Couldn’t change brightness. Still ${d.value}%. Check display access and try again.`, true);
    } else { d.value = requested; render(); }
  }, 450);
});
$('display-picker').addEventListener('click', () => { cancelPending(); expanded = !expanded; render(); });
$('power').addEventListener('click', () => { cancelPending(); current().on = !current().on; render(); });
$('scenario').addEventListener('change', () => {
  cancelPending(); displays = initial(); selected = 'studio';
  if ($('scenario').value === 'unsupported') selected = 'projector';
  if ($('scenario').value === 'disconnect') { displays = displays.filter(d => d.id !== 'studio'); selected = 'builtin'; }
  render();
  if ($('scenario').value === 'denied') feedback('Move the slider to preview an unsuccessful update.');
  if ($('scenario').value === 'disconnect') feedback('Studio display disconnected. Built-in display selected.');
});
$('night').addEventListener('click', () => {
  const enabled = $('night').getAttribute('aria-checked') !== 'true';
  $('night').setAttribute('aria-checked', String(enabled));
  $('night-status').textContent = enabled ? 'On · Warmer colors' : 'Off · Sunset to sunrise';
});
$('theme').addEventListener('click', () => {
  const light = document.body.classList.toggle('light');
  $('theme').textContent = light ? 'Dark appearance' : 'Light appearance';
});
$('volume').addEventListener('input', () => { paint($('volume')); $('volume-value').textContent = `${$('volume').value}%`; });
paint($('volume')); render();
