/* ══════════════════════ RENDER: RULES ══════════════════════ */

function renderRules() {
  const el = document.getElementById('rules-list');
  el.innerHTML = ruleOrder.map(id => {
    const r = rulesData[id];
    return `<div class="config-row ${!r.enabled?'dimmed':''}">
      <div style="flex:1;min-width:0">
        <div class="config-name">${r.type}</div>
        <div class="config-sub" style="font-family:var(--mono)">${r.value}</div>
      </div>
      <span class="rule-action-badge ${r.action}">${r.action}</span>
      ${miniToggleHtml(id, 'toggleRuleEnabled', r.enabled)}
      <div class="row-del" onclick="removeRule('${id}')">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </div>
    </div>`;
  }).join('');
  const activeRules = ruleOrder.filter(id => rulesData[id].enabled).length;
  document.getElementById('rulesCardSub').textContent = activeRules + ' active · ' + ruleOrder.length + ' total';
}

function removeRule(id) {
  ruleOrder = ruleOrder.filter(x => x !== id);
  delete rulesData[id];
  renderRules();
}

