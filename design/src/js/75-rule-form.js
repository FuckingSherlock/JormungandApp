/* ══════════════════════ RULE FORM (Rules → + Add / tap a rule) ══════════════════════
   Form | JSON tabs over one draft.
   Form: condition groups added with "+ Condition" (RULE_GROUPS); each field takes values as
   chips (Enter, comma or a pasted column); a bad value turns red and blocks Save.
   Action: Proxy (main flow or a target — stub picker), Direct, Block (drop / reject).
   If unavailable (with a target): Default / Main / Block / Direct when the target is off,
   empty or deleted (docs/rules.md §0).
   DNS: Auto (first ticked server with the matching route) or a server from Settings → DNS.
   JSON: the sing-box route rule. Groups map to one flat rule; a negated group, or Domains
   together with IP (sing-box ORs those in one rule), turns it into {type: logical, mode: and}.
   geosite / geoip stay names here: the core swaps them for its downloaded rule sets. Keys the
   form does not know are kept ("extra") and shown as a plaque; any other logical rule is
   "composite" — edited in JSON only. */

let ruleEditing = null, ruleDraft = null, rfTab = 'form', rfAddOpen = false;
// Empty fields stay folded as "+ Keyword" chips; a group with no values shows its first field.
let rfOpenFields = new Set();
const clone = o => JSON.parse(JSON.stringify(o));

function openRuleForm(id) {
  ruleEditing = id || null;
  ruleDraft = id ? clone(rulesData[id]) : newRule({ groups: { domain: { not: false, v: {} } } });
  rfTab = 'form'; rfAddOpen = false; rfOpenFields = new Set();
  document.getElementById('rfTitle').textContent = id ? 'Rule #' + (ruleOrder.indexOf(id) + 1) : 'New rule';
  document.getElementById('rf-delete').style.display = id ? '' : 'none';
  renderRuleForm();
  openSheet('ruleform');
}

function setRfTab(tab) {
  if (tab === rfTab) return;
  if (tab === 'form' && !rfApplyJson()) return;
  rfTab = tab;
  renderRuleForm();
}

function renderRuleForm() {
  document.querySelectorAll('#sh-ruleform .sheet-tab').forEach(t => t.classList.toggle('active', t.dataset.tab === rfTab));
  const el = document.getElementById('rf-body');
  if (rfTab === 'json') {
    el.innerHTML = `<div class="form-group"><textarea class="form-input code-area tall" id="rf-json" spellcheck="false" oninput="rfCheckJson()">${esc(JSON.stringify(ruleJson(ruleDraft), null, 2))}</textarea>
      <div class="set-hint warn" id="rf-json-err"></div>
      <div class="set-hint">The sing-box route rule. Name, If unavailable and DNS live in the form.</div></div>`;
    return;
  }
  const d = ruleDraft;
  const plaque = d.composite ? `<div class="rf-plaque">Composite rule (${esc(d.composite.mode || '')} of ${(d.composite.rules || []).length}) — edit it in JSON</div>`
    : Object.keys(d.extra || {}).length ? `<div class="rf-plaque">Extra fields: ${Object.keys(d.extra).map(esc).join(', ')} — edit them in JSON</div>` : '';
  const groups = d.composite ? '' : RULE_GROUPS.filter(g => d.groups[g.key]).map(g => rfGroupHtml(g, d.groups[g.key])).join('');
  const unused = RULE_GROUPS.filter(g => !d.groups[g.key]);
  const addRow = d.composite || !unused.length ? '' : rfAddOpen
    ? `<div class="chip-row rf-add">${unused.map(g => `<div class="chip" onclick="rfAddGroup('${g.key}')">${g.title}${g.desktop ? ' · desktop' : ''}</div>`).join('')}</div>`
    : `<div class="node-add rf-add-btn" onclick="rfAddOpen=true;renderRuleForm()">+ Condition</div>`;
  const acts = [['proxy', 'Proxy'], ['direct', 'Direct'], ['block', 'Block']];
  const dnsOpts = [['auto', 'Auto · ' + ((dnsAutoFor(d.action === 'direct' ? 'direct' : 'vpn') || {}).name || '—')], ...dnsOrder.map(id => [id, dnsServers[id].name])];
  el.innerHTML = `
    <div class="form-group"><div class="form-label">Name</div><input class="form-input" id="rf-name" placeholder="optional" value="${esc(d.name)}" oninput="ruleDraft.name=this.value"></div>
    ${plaque}
    ${d.composite ? '' : `<div class="rf-label">If<span class="rules-note">values in a field: any · groups: all</span></div>`}
    ${groups}${addRow}
    <div class="rf-label">Then</div>
    <div class="rf-then">
      <div class="seg3 wide">${acts.map(([v, l]) => `<button class="${d.action === v ? 'on ' + v : ''}" onclick="ruleDraft.action='${v}';renderRuleForm()">${l}</button>`).join('')}</div>
      <div class="set-group">
        ${d.action === 'proxy' ? targetRowHtml('Via', d.target, 't => { ruleDraft.target = t; renderRuleForm(); }') : ''}
        ${d.action === 'proxy' && d.target ? `<div class="set-row rf-fallback"><div class="set-label">If unavailable<div class="set-hint">${d.fallback === 'default'
            ? 'Default: ' + fallbackName(quickCfg.fallback) + ' (Rules → Target unavailable)' : 'Off in Nodes, no working server or deleted'}</div></div></div>
          <div class="set-row"><div class="seg3 wide" id="rf-fallback">${[['default', 'Default'], ['main', 'Main'], ['block', 'Block'], ['direct', 'Direct']].map(([v, l]) =>
            `<button class="${d.fallback === v ? 'on ' + (v === 'main' ? 'proxy' : v) : ''}" onclick="ruleDraft.fallback='${v}';renderRuleForm()">${l}</button>`).join('')}</div></div>` : ''}
        ${d.action === 'block' ? `<div class="set-row"><div class="set-label">How</div><div class="chip-row">${[['drop', 'Drop silently'], ['reject', 'Reject']].map(([v, l]) =>
          `<div class="chip ${d.block === v ? 'active' : ''}" onclick="ruleDraft.block='${v}';renderRuleForm()">${l}</div>`).join('')}</div></div>` : ''}
        ${d.action !== 'block' ? `<div class="set-row"><div class="set-label">DNS</div><select class="set-select" id="rf-dns" onchange="ruleDraft.dns=this.value">${dnsOpts.map(([v, l]) =>
          `<option value="${v}" ${d.dns === v ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></div>` : ''}
      </div>
    </div>`;
}

function rfGroupHtml(g, d) {
  const any = (g.fields || []).some(([f]) => (d.v[f] || []).length);
  const shown = (g.fields || []).filter(([f], i) => (d.v[f] || []).length || rfOpenFields.has(g.key + '.' + f) || (!any && i === 0));
  const folded = (g.fields || []).filter(x => !shown.includes(x));
  const more = folded.length ? `<div class="rf-more">${folded.map(([f, label]) =>
    `<button onclick="rfOpenField('${g.key}','${f}')">+ ${label}</button>`).join('')}</div>` : '';
  const fields = shown.map(([f, label, ph, kind]) => {
    const vals = d.v[f] || [];
    return `<div class="rf-field"><div class="rf-flabel">${label}</div>
      <div class="chip-input" onclick="if (event.target === this) this.querySelector('input').focus()">${vals.map((v, i) => {
        const ok = validVal(kind, v);
        return `<span class="vchip ${ok ? '' : 'bad'}" ${ok ? '' : `title="${esc(VAL_HINT[kind])}"`}>${esc(v)}<b onclick="rfRemoveVal('${g.key}','${f}',${i})">×</b></span>`;
      }).join('')}<input data-g="${g.key}" data-f="${f}" placeholder="${vals.length ? '' : esc(ph)}" onkeydown="rfKey(event,this)" onpaste="rfPaste(event,this)" onblur="rfCommit(this)"></div>
      ${vals.some(v => !validVal(kind, v)) ? `<div class="set-hint warn">Red: ${esc(VAL_HINT[kind])}</div>` : ''}</div>`;
  }).join('');
  const choices = (g.choices || []).map(([f, label, opts]) => `<div class="rf-field"><div class="rf-flabel">${label}</div><div class="chip-row" style="padding:0">${opts.map(o =>
    `<div class="chip ${(d.v[f] || []).includes(o) ? 'active' : ''}" onclick="rfToggleChoice('${g.key}','${f}','${o}')">${o.toUpperCase()}</div>`).join('')}</div></div>`).join('');
  const flag = g.flag ? `<div class="rf-field rf-flag"><div class="rf-flabel" style="flex:1">${g.flag[1]}</div>
    <div class="mini-toggle ${d.flag ? 'on' : ''}" onclick="ruleDraft.groups.${g.key}.flag=!ruleDraft.groups.${g.key}.flag;renderRuleForm()"><div class="mini-toggle-thumb"></div></div></div>` : '';
  return `<div class="rf-group ${d.not ? 'not' : ''}" data-g="${g.key}">
    <div class="rf-ghead"><span class="rf-gtitle">${d.not ? 'Not ' : ''}${g.title}${g.desktop ? '<span class="conn-tag muted">desktop</span>' : ''}</span>
      <button class="rf-not ${d.not ? 'on' : ''}" onclick="ruleDraft.groups.${g.key}.not=!ruleDraft.groups.${g.key}.not;renderRuleForm()">except</button>
      <button class="rf-x" onclick="rfRemoveGroup('${g.key}')" title="Remove">×</button></div>
    ${fields}${more}${choices}${flag}</div>`;
}

function rfOpenField(g, f) {
  rfOpenFields.add(g + '.' + f);
  renderRuleForm();
  document.querySelector(`#rf-body input[data-g="${g}"][data-f="${f}"]`).focus();
}
function rfAddGroup(key) { ruleDraft.groups[key] = { not: false, v: {} }; rfAddOpen = false; renderRuleForm(); }
function rfRemoveGroup(key) { delete ruleDraft.groups[key]; renderRuleForm(); }
function rfRemoveVal(g, f, i) { ruleDraft.groups[g].v[f].splice(i, 1); renderRuleForm(); }
function rfToggleChoice(g, f, o) {
  const list = ruleDraft.groups[g].v[f] = ruleDraft.groups[g].v[f] || [];
  list.includes(o) ? list.splice(list.indexOf(o), 1) : list.push(o);
  renderRuleForm();
}
// Adds values typed or pasted into a field: split on commas / newlines / semicolons.
function rfAddValues(g, f, text, refocus = true) {
  const add = text.split(/[\n,;]+/).map(s => s.trim()).filter(Boolean);
  if (!add.length) return false;
  const list = ruleDraft.groups[g].v[f] = ruleDraft.groups[g].v[f] || [];
  add.forEach(v => { if (!list.includes(v)) list.push(v); });
  renderRuleForm();
  const again = document.querySelector(`#rf-body input[data-g="${g}"][data-f="${f}"]`);
  if (again && refocus) again.focus();
  return true;
}
function rfCommit(input, refocus = false) {
  const v = input.value;
  input.value = '';
  rfAddValues(input.dataset.g, input.dataset.f, v, refocus);
}
function rfKey(e, input) {
  if (e.key === 'Enter' || e.key === ',') { e.preventDefault(); rfCommit(input, true); }
  else if (e.key === 'Backspace' && !input.value) {
    const list = ruleDraft.groups[input.dataset.g].v[input.dataset.f];
    if (list && list.length) { list.pop(); renderRuleForm(); document.querySelector(`#rf-body input[data-g="${input.dataset.g}"][data-f="${input.dataset.f}"]`).focus(); }
  }
}
function rfPaste(e, input) {
  const text = (e.clipboardData || window.clipboardData).getData('text');
  if (!/[\n,;]/.test(text)) return;   // a single value: let it paste normally
  e.preventDefault();
  input.value = '';
  rfAddValues(input.dataset.g, input.dataset.f, text);
}

/* ── Draft ⇄ sing-box JSON ── */
const FIELD_GROUP = {};
RULE_GROUPS.forEach(g => (g.fields || []).concat(g.choices || []).forEach(([f]) => FIELD_GROUP[f] = g.key));

function groupJson(key, d) {
  const o = {};
  Object.entries(d.v).forEach(([f, list]) => {
    if (!list.length) return;
    if (f === 'port' || f === 'source_port') {
      const one = list.filter(v => !v.includes('-')).map(Number), rng = list.filter(v => v.includes('-')).map(v => v.replace('-', ':'));
      if (one.length) o[f] = one;
      if (rng.length) o[f + '_range'] = rng;
    } else if (f === 'ip_cidr' || f === 'source_ip_cidr') {
      o[f] = list.flatMap(v => /^[\d.]+-[\d.]+$/.test(v) && isIpVal(v) ? rangeToCidrs(...v.split('-')) : [v]);
    } else if (f === 'process') {
      const paths = list.filter(v => /[\\/]/.test(v)), names = list.filter(v => !/[\\/]/.test(v));
      if (names.length) o.process_name = names;
      if (paths.length) o.process_path = paths;
    } else o[f] = list.slice();
  });
  if (d.flag) o.ip_is_private = true;
  return o;
}
function actionJson(r) {
  if (r.action === 'block') return { action: 'reject', method: r.block === 'drop' ? 'drop' : 'default' };
  return { action: 'route', outbound: r.action === 'direct' ? 'direct' : targetTag(r.target) };
}
function ruleJson(r) {
  if (r.composite) return clone(r.composite);
  const gs = RULE_GROUPS.filter(g => r.groups[g.key]).map(g => [g.key, r.groups[g.key]]);
  // sing-box ORs domain and IP fields inside one rule: the form's AND needs logical then
  const body = gs.some(([, d]) => d.not) || (r.groups.domain && r.groups.ip)
    ? { type: 'logical', mode: 'and', rules: gs.map(([k, d]) => Object.assign(groupJson(k, d), d.not ? { invert: true } : {})) }
    : Object.assign({}, ...gs.map(([k, d]) => groupJson(k, d)));
  return Object.assign(body, actionJson(r), r.extra || {});
}

// A flat sing-box rule → groups; unknown keys → extra.
function keysToGroups(o, extra) {
  const groups = {};
  const put = (f, vals) => { const k = FIELD_GROUP[f]; (groups[k] = groups[k] || { not: false, v: {} }).v[f] = [].concat(groups[k].v[f] || [], vals); };
  Object.entries(o).forEach(([k, v]) => {
    const list = [].concat(v).map(String);
    if (FIELD_GROUP[k]) put(k, list);
    else if (k === 'port_range' || k === 'source_port_range') put(k.replace('_range', ''), list.map(x => x.replace(':', '-')));
    else if (k === 'process_name' || k === 'process_path') put('process', list);
    else if (k === 'ip_is_private') { (groups.ip = groups.ip || { not: false, v: {} }).flag = !!v; }
    else extra[k] = v;
  });
  return groups;
}
function ruleFromJson(o) {
  if (!o || typeof o !== 'object' || Array.isArray(o)) throw new Error('A rule must be a JSON object');
  const { action = 'route', outbound, method, ...rest } = o;
  const r = newRule({});
  if (action === 'reject') { r.action = 'block'; r.block = method === 'drop' ? 'drop' : 'reject'; }
  else if (action === 'route') {
    if (outbound === 'direct') r.action = 'direct';
    else { r.action = 'proxy'; r.target = allTargets().find(t => targetTag(t) === outbound) || ''; }
  } else rest.action = action;
  const extra = {};
  if (rest.type === 'logical') {
    const subs = rest.rules || [];
    const simple = rest.mode === 'and' && Object.keys(rest).every(k => ['type', 'mode', 'rules'].includes(k)) && subs.every(s => !s.type);
    const parts = simple ? subs.map(s => { const { invert, ...keys } = s, x = {}; const g = keysToGroups(keys, x); return [g, invert, x]; }) : [];
    // each part must be exactly one group, no unknown keys, groups not repeated
    const keys = parts.map(([g]) => Object.keys(g));
    if (simple && keys.every(k => k.length === 1) && new Set(keys.flat()).size === keys.length && parts.every(([, , x]) => !Object.keys(x).length)) {
      parts.forEach(([g, inv]) => { const k = Object.keys(g)[0]; r.groups[k] = Object.assign(g[k], { not: !!inv }); });
    } else r.composite = Object.assign({}, rest, actionJson(r));
  } else {
    r.groups = keysToGroups(rest, extra);
    if (extra.invert) { const ks = Object.keys(r.groups); if (ks.length === 1) { r.groups[ks[0]].not = true; delete extra.invert; } }
  }
  if (Object.keys(extra).length) r.extra = extra;
  return r;
}

function jsonErrorText(text, e) {
  const pos = /position (\d+)/.exec(e.message), line = /line (\d+)/.exec(e.message);
  const n = line ? +line[1] : pos ? text.slice(0, +pos[1]).split('\n').length : null;
  return (n ? 'Line ' + n + ': ' : '') + e.message.replace(/^JSON\.parse: |\s*\(line.*$| in JSON at position \d+.*$/g, '');
}
function rfCheckJson() {
  const text = document.getElementById('rf-json').value;
  let msg = '';
  try { ruleFromJson(JSON.parse(text)); } catch (e) { msg = e instanceof SyntaxError ? jsonErrorText(text, e) : e.message; }
  document.getElementById('rf-json-err').textContent = msg;
  return !msg;
}
// JSON tab → draft (keeps name, If unavailable, DNS, enabled). false if the JSON is invalid.
function rfApplyJson() {
  if (rfTab !== 'json') return true;
  if (!rfCheckJson()) { toast('Fix the JSON first'); return false; }
  const r = ruleFromJson(JSON.parse(document.getElementById('rf-json').value));
  ['id', 'name', 'enabled', 'fallback', 'dns'].forEach(k => r[k] = ruleDraft[k]);
  ruleDraft = r;
  return true;
}

function saveRuleForm() {
  if (!rfApplyJson()) return;
  const d = ruleDraft;
  if (!d.composite) {
    const gs = Object.entries(d.groups);
    const kindOf = f => RULE_GROUPS.flatMap(g => g.fields || []).find(x => x[0] === f);
    if (gs.some(([, g]) => Object.entries(g.v).some(([f, list]) => kindOf(f) && list.some(v => !validVal(kindOf(f)[3], v))))) { toast('Fix the values in red'); return; }
    Object.values(d.groups).forEach(g => Object.keys(g.v).forEach(f => { if (!g.v[f].length) delete g.v[f]; }));
    Object.keys(d.groups).forEach(k => { const g = d.groups[k]; if (!Object.keys(g.v).length && !g.flag) delete d.groups[k]; });
    if (!Object.keys(d.groups).length) { toast('Add at least one condition'); renderRuleForm(); return; }
  }
  if (!(d.action === 'proxy' && d.target)) d.fallback = 'default';
  if (ruleEditing) rulesData[ruleEditing] = Object.assign(d, { id: ruleEditing });
  else { d.id = 'r' + (ruleSeq++); rulesData[d.id] = d; ruleOrder.push(d.id); }
  closeSheet('ruleform');
  renderRules();
}
function deleteRule() {
  delete rulesData[ruleEditing];
  ruleOrder = ruleOrder.filter(x => x !== ruleEditing);
  closeSheet('ruleform');
  renderRules();
}
