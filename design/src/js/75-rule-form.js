/* ══════════════════════ ADD RULE ══════════════════════ */

function openAddRule() {
  document.getElementById('ar-value').value = '';
  document.getElementById('ar-type').querySelectorAll('.chip').forEach((c,i) => c.classList.toggle('active', i===0));
  document.getElementById('ar-action').querySelectorAll('.chip').forEach((c,i) => { c.classList.toggle('active', i===0); c.classList.remove('act-direct','act-block'); });
  ruleDraftAction = 'proxy';
  openSheet('addrule');
}

function saveAddRule() {
  const type = document.getElementById('ar-type').querySelector('.chip.active').textContent;
  const value = document.getElementById('ar-value').value.trim() || '*';
  const id = 'r' + (ruleSeq++);
  rulesData[id] = { id, type, value, action: ruleDraftAction, enabled:true };
  ruleOrder.push(id);
  renderRules();
  closeSheet('addrule');
}

