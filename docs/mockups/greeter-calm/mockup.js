'use strict';
const $ = id => document.getElementById(id);
let user = 'zoey';
let session = 'Pearl (Aqueous) · Wayland';
let activeAccount = 0;
let activeSession = 0;
const accountOptions = [...$('accounts').querySelectorAll('[role=option]')];
const sessionOptions = [...$('sessions').querySelectorAll('[role=option]')];

function status(text, error = false) {
  $('status').textContent = text;
  $('status').classList.toggle('error', error);
}
function closeMenus() {
  for (const [menu, button] of [[ $('accounts'), $('title-menu') ], [ $('sessions'), $('session-chip') ]]) {
    menu.hidden = true;
    button.setAttribute('aria-expanded', 'false');
  }
}
function closePower() {
  $('power-pop').hidden = true;
  $('power').setAttribute('aria-expanded', 'false');
  $('power-menu').hidden = false;
  $('power-confirm').hidden = true;
}
function highlight(options, index) {
  options.forEach((option, i) => {
    option.id = option.id || 'option-' + i;
    option.classList.toggle('active', i === index);
  });
}
function openMenu(menu, button, options, index) {
  closeMenus();
  menu.hidden = false;
  button.setAttribute('aria-expanded', 'true');
  highlight(options, index);
  menu.focus();
}
function render() {
  const mode = $('preview').value;
  closeMenus();
  closePower();
  $('login').classList.toggle('busy', mode === 'prompt');
  const manual = user === 'other';
  const choices = mode === 'choices';
  $('title-plain').hidden = choices;
  $('title-menu').hidden = !choices;
  $('title-plain').textContent = manual ? 'Other user' : user;
  $('account-value').textContent = user;
  $('session-caption').hidden = choices;
  $('session-chip').hidden = !choices;
  $('session-caption').textContent = session;
  $('session-value').textContent = session;
  $('username-field').hidden = !manual;
  $('password-label').hidden = mode !== 'prompt';
  $('password-label').textContent = 'Verification code';
  $('password').type = mode === 'prompt' ? 'text' : 'password';
  $('password').placeholder = mode === 'prompt' ? 'Verification code' : 'Password';
  $('password').setAttribute('aria-label', mode === 'prompt' ? 'Verification code' : 'Password');
  $('password').value = '';
  $('password').disabled = mode === 'prompt' ? false : false;
  $('caps').hidden = true;
  $('submit').textContent = mode === 'prompt' ? 'Continue' : 'Sign in';
  $('cancel').hidden = mode !== 'prompt';
  for (const id of ['title-menu', 'session-chip']) $(id).disabled = mode === 'prompt';
  if (mode === 'error') status('Authentication failed. Try again.', true);
  else if (mode === 'prompt') status('Enter the verification code from your authenticator.');
  else status('');
}
function chooseUser(next) {
  user = next;
  accountOptions.forEach(option => option.setAttribute('aria-selected', String(option.dataset.user === next)));
  render();
  (next === 'other' ? $('username') : $('password')).focus();
}
function chooseSession(next) {
  session = next;
  sessionOptions.forEach(option => option.setAttribute('aria-selected', String(option.dataset.session === next)));
  render();
  $('password').focus();
}
$('title-menu').addEventListener('click', () => {
  if ($('title-menu').disabled) return;
  $('accounts').hidden ? openMenu($('accounts'), $('title-menu'), accountOptions, activeAccount) : closeMenus();
});
$('session-chip').addEventListener('click', () => {
  if ($('session-chip').disabled) return;
  $('sessions').hidden ? openMenu($('sessions'), $('session-chip'), sessionOptions, activeSession) : closeMenus();
});
$('accounts').addEventListener('keydown', event => {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    activeAccount = (activeAccount + (event.key === 'ArrowDown' ? 1 : -1) + accountOptions.length) % accountOptions.length;
    highlight(accountOptions, activeAccount);
  }
  if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); chooseUser(accountOptions[activeAccount].dataset.user); }
  if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeMenus(); $('title-menu').focus(); }
});
$('sessions').addEventListener('keydown', event => {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    activeSession = (activeSession + (event.key === 'ArrowDown' ? 1 : -1) + sessionOptions.length) % sessionOptions.length;
    highlight(sessionOptions, activeSession);
  }
  if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); chooseSession(sessionOptions[activeSession].dataset.session); }
  if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeMenus(); $('session-chip').focus(); }
});
accountOptions.forEach((option, i) => option.addEventListener('click', () => { activeAccount = i; chooseUser(option.dataset.user); }));
sessionOptions.forEach((option, i) => option.addEventListener('click', () => { activeSession = i; chooseSession(option.dataset.session); }));
$('refresh').addEventListener('click', () => { closeMenus(); status('Desktop list refreshed. Your selection is kept.'); });
$('refresh').addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); $('refresh').click(); } });
document.addEventListener('click', event => {
  if (!event.target.closest('#accounts') && !event.target.closest('#title-menu')) $('accounts').hidden = true;
  if (!event.target.closest('#sessions') && !event.target.closest('#session-chip')) $('sessions').hidden = true;
  if (!event.target.closest('.cluster')) closePower();
});
document.addEventListener('keydown', event => { if (event.key === 'Escape') { closeMenus(); closePower(); } });
$('login').addEventListener('submit', event => {
  event.preventDefault();
  const mode = $('preview').value;
  if (mode === 'manual' || user === 'other') {
    if (!$('username').value.trim()) { status('Enter a username.', true); $('username').focus(); return; }
  }
  if (!$('password').value) { status(mode === 'prompt' ? 'Enter the verification code.' : 'Enter your password.', true); $('password').focus(); return; }
  // The value is never copied, logged, saved, or sent anywhere.
  $('password').value = '';
  status('Authenticating…');
  $('submit').textContent = mode === 'prompt' ? 'Continuing…' : 'Signing in…';
  $('cancel').hidden = false;
  setTimeout(() => { render(); status('Preview complete. No account was authenticated.'); }, 1200);
});
$('cancel').addEventListener('click', () => { render(); status('Authentication cancelled.'); $('password').focus(); });
function pressed(button, on) { button.setAttribute('aria-pressed', String(on)); }
$('larger').addEventListener('click', () => pressed($('larger'), document.body.classList.toggle('large')));
$('contrast').addEventListener('click', () => pressed($('contrast'), document.body.classList.toggle('contrast')));
$('power').addEventListener('click', () => {
  const open = $('power-pop').hidden;
  $('power-pop').hidden = !open;
  $('power').setAttribute('aria-expanded', String(open));
  if (open) { $('power-menu').hidden = false; $('power-confirm').hidden = true; }
});
for (const item of $('power-menu').querySelectorAll('.pop-item')) {
  item.addEventListener('click', () => {
    $('power-menu').hidden = true;
    $('power-confirm').hidden = false;
    $('power-confirm-text').textContent = (item.dataset.action === 'reboot' ? 'Restart' : 'Power off') + ' this machine?';
  });
}
$('power-yes').addEventListener('click', () => { closePower(); status('Preview complete. No power action was taken.'); });
$('power-no').addEventListener('click', closePower);
$('preview').addEventListener('change', render);
$('theme').addEventListener('change', () => document.body.classList.toggle('light', $('theme').value === 'light'));
$('password').addEventListener('keydown', event => { $('caps').hidden = !event.getModifierState('CapsLock'); });
$('password').addEventListener('keyup', event => { $('caps').hidden = !event.getModifierState('CapsLock'); });
$('reset').addEventListener('click', () => {
  $('preview').value = 'ready';
  $('theme').value = 'dark';
  document.body.className = '';
  for (const id of ['larger', 'contrast']) pressed($(id), false);
  user = 'zoey';
  session = 'Pearl (Aqueous) · Wayland';
  accountOptions.forEach(option => option.setAttribute('aria-selected', String(option.dataset.user === 'zoey')));
  sessionOptions.forEach(option => option.setAttribute('aria-selected', String(option.dataset.session === session)));
  render();
});
const initial = location.hash.slice(1);
if ([...$('preview').options].some(option => option.value === initial)) $('preview').value = initial;
render();
