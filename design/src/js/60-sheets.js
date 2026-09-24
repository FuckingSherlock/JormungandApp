/* ══════════════════════ SHEETS (open/close + tabs) ══════════════════════ */

function openSheet(name) {
  document.getElementById('ov-'+name).classList.add('open');
  document.getElementById('sh-'+name).classList.add('open');
}
function closeSheet(name) {
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

