'use strict';
const $ = id => document.getElementById(id);
const options = [...$('accounts').querySelectorAll('[role=option]')];
let selectedUser = 'zoey';
let activeIndex = 0;
let pendingTimer;
let busy = false;
function status(text, error = false) {
  $('status').textContent = text;
  $('status').classList.toggle('error', error);
}
function closeMenu(restoreFocus = false) {
  $('accounts').hidden = true;
  $('account').setAttribute('aria-expanded', 'false');
  if (restoreFocus) $('account').focus();
}
function highlight(index) {
  activeIndex = (index + options.length) % options.length;
  options.forEach((option, i) => {
    option.id = 'user-option-' + i;
    option.classList.toggle('active', i === activeIndex);
  });
  $('accounts').setAttribute('aria-activedescendant', options[activeIndex].id);
}
function openMenu() {
  if (busy) return;
  $('accounts').hidden = false;
  $('account').setAttribute('aria-expanded', 'true');
  highlight(options.findIndex(option => option.dataset.user === selectedUser));
  $('accounts').focus();
}
function chooseUser(user) {
  selectedUser = user;
  $('account-value').textContent = user === 'other' ? 'Other user…' : user;
  options.forEach(option => option.setAttribute('aria-selected', String(option.dataset.user === user)));
  $('username-field').hidden = user !== 'other';
  $('username').value = '';
  $('password').value = '';
  status('Enter your password to sign in.');
  closeMenu();
  (user === 'other' ? $('username') : $('password')).focus();
}
function setBusy(value) {
  busy = value;
  for (const id of ['account', 'username', 'password', 'session', 'refresh', 'submit']) $(id).disabled = value;
  $('cancel').hidden = !value && !['fingerprint', 'otp'].includes($('preview').value);
}
function renderPreview() {
  clearTimeout(pendingTimer);
  setBusy(false);
  closeMenu();
  $('password').value = '';
  $('password').type = 'password';
  $('password-label').textContent = 'Password';
  $('password').placeholder = 'Enter your password';
  $('account-field').hidden = $('preview').value === 'empty';
  $('username-field').hidden = selectedUser !== 'other' && $('preview').value !== 'empty';
  $('caps').hidden = true;
  $('submit').textContent = 'Sign in';
  status('Enter your password to sign in.');
  if ($('preview').value === 'error') status('Authentication failed. Try again.', true);
  if ($('preview').value === 'empty') status('Enter your username and password.');
  if ($('preview').value === 'fingerprint') {
    status('Touch the fingerprint reader to sign in.');
    $('password').disabled = true;
    $('password').placeholder = 'Waiting for authentication instructions';
    $('submit').disabled = true;
    $('submit').textContent = 'Waiting for fingerprint…';
    for (const id of ['account', 'username', 'session', 'refresh']) $(id).disabled = true;
  }
  if ($('preview').value === 'otp') {
    $('password-label').textContent = 'Verification code';
    $('password').type = 'text';
    $('password').placeholder = 'Enter verification code';
    $('submit').textContent = 'Continue';
    status('Enter the verification code from your authenticator.');
    for (const id of ['account', 'username', 'session', 'refresh']) $(id).disabled = true;
  }
}
$('account').addEventListener('click', () => $('accounts').hidden ? openMenu() : closeMenu(true));
$('account').addEventListener('keydown', event => {
  if (['ArrowDown', 'ArrowUp'].includes(event.key)) { event.preventDefault(); openMenu(); }
});
$('accounts').addEventListener('keydown', event => {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); highlight(activeIndex + (event.key === 'ArrowDown' ? 1 : -1)); }
  if (event.key === 'Home' || event.key === 'End') { event.preventDefault(); highlight(event.key === 'Home' ? 0 : options.length - 1); }
  if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); chooseUser(options[activeIndex].dataset.user); }
  if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeMenu(true); }
  if (event.key === 'Tab') { closeMenu(true); }
  if (event.key.length === 1 && /[a-z]/i.test(event.key)) {
    const index = options.findIndex(option => option.textContent.trim().toLowerCase().startsWith(event.key.toLowerCase()));
    if (index >= 0) highlight(index);
  }
});
options.forEach(option => option.addEventListener('click', () => chooseUser(option.dataset.user)));
document.addEventListener('click', event => { if (!event.target.closest('.account-picker')) closeMenu(); });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && (busy || ['fingerprint', 'otp'].includes($('preview').value))) {
    $('preview').value = 'ready'; renderPreview(); status('Authentication cancelled.'); $('password').focus();
  }
});
$('login').addEventListener('submit', event => {
  event.preventDefault();
  if (busy || $('submit').disabled) return;
  const user = selectedUser === 'other' || $('preview').value === 'empty' ? $('username').value.trim() : selectedUser;
  if (!user) { status('Enter a username.', true); $('username').focus(); return; }
  if (!$('password').value) { status($('preview').value === 'otp' ? 'Enter a verification code.' : 'Enter your password.', true); $('password').focus(); return; }
  // The value is never copied, logged, saved, or sent anywhere.
  $('password').value = '';
  setBusy(true); status('Authenticating…'); $('submit').textContent = 'Signing in…';
  pendingTimer = setTimeout(() => {
    setBusy(false);
    $('submit').textContent = $('preview').value === 'otp' ? 'Continue' : 'Sign in';
    status('Preview complete. No account was authenticated.');
    $('password').focus();
  }, 1200);
});
$('cancel').addEventListener('click', () => { $('preview').value = 'ready'; renderPreview(); status('Authentication cancelled.'); $('password').focus(); });
$('refresh').addEventListener('click', () => { $('password').value = ''; status('Desktop list refreshed. Your user selection is kept.'); });
$('preview').addEventListener('change', renderPreview);
$('theme').addEventListener('change', () => document.body.classList.toggle('light', $('theme').value === 'light'));
$('larger').addEventListener('click', () => document.body.classList.toggle('large'));
$('move').addEventListener('click', () => document.body.classList.toggle('moved'));
$('contrast').addEventListener('change', () => document.body.classList.toggle('contrast', $('contrast').checked));
$('password').addEventListener('keydown', event => { $('caps').hidden = !event.getModifierState('CapsLock'); });
$('password').addEventListener('keyup', event => { $('caps').hidden = !event.getModifierState('CapsLock'); });
$('reset').addEventListener('click', () => {
  $('preview').value = 'ready'; $('session').value = 'pearl'; $('theme').value = 'dark';
  $('contrast').checked = false; $('motion').checked = true; document.body.className = '';
  chooseUser('zoey'); renderPreview(); $('password').focus();
});
renderPreview();
