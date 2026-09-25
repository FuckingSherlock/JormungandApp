/* ══════════════════════ SHEETS (open/close + tabs) ══════════════════════ */

function openSheet(name) {
  document.getElementById('ov-'+name).classList.add('open');
  document.getElementById('sh-'+name).classList.add('open');
}
// A sheet may veto or clean up on close (any way: ×, overlay, swipe, Done).
const sheetCloseHooks = {};
sheetCloseHooks.profiles = () => { if (connectEdit) setConnectEdit(false); };   // the list reopens in view mode
function closeSheet(name) {
  if (sheetCloseHooks[name]) sheetCloseHooks[name]();
  document.getElementById('ov-'+name).classList.remove('open');
  document.getElementById('sh-'+name).classList.remove('open');
}

function pickChip(el, groupId) {
  document.getElementById(groupId).querySelectorAll('.chip').forEach(c => c.classList.remove('active'));
  el.classList.add('active');
}

let ruleDraftAction = 'proxy';
function pickActionChip(el, value) {
  ruleDraftAction = value;
  const group = document.getElementById('ar-action');
  group.querySelectorAll('.chip').forEach(c => c.classList.remove('active','act-direct','act-block'));
  el.classList.add('active');
  if (value === 'direct') el.classList.add('act-direct');
  if (value === 'block') el.classList.add('act-block');
}

