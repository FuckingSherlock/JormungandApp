/* ══════════════════════ RULE FORM (Rules → + Add / tap a rule) ══════════════════════
   Form | JSON tabs over one draft.
   Form: condition cards; "+ Condition" adds a field (its card appears with it, RULE_GROUPS), a
   field's × removes it (the last one takes the card away). A field takes values as chips (Enter,
   comma or a pasted column); a bad value turns red and blocks Save. A field is on its card when its
   key is in group.v (an empty list = added, not filled yet); Local networks when group.flag is set.
   Action: Proxy (main flow or a target — stub picker), Direct, Block (drop / reject).
   Fallback (Then = Proxy, with a target or the main flow; same block as the per-app dialog,
   fallbackRowsHtml): Default | Proxy | Direct | Block + its own Via (Main flow or a target, not the
   rule's Via), for when the target is off, empty or deleted / the main flow is down; always in
   place, dimmed and inert on Direct / Block (docs/rules.md §0). rule.fallbackTarget goes with 'main'.
   DNS: Auto (first ticked server with the matching route) or a server from Settings → DNS.
   IP block (only with an IP / GeoIP / local-networks condition): "IP conditions only in TUN"
   (rule.ipTunOnly: the core adds no `resolve` for this rule) with a (?) that explains it and shows
   the state of Settings → DNS → Resolve for IP rules, and a link there (the DNS sheet opens above
   the form, the draft stays under it).
   JSON: the sing-box route rule. Groups map to one flat rule; a negated group, or Domains
   together with IP (sing-box ORs those in one rule), turns it into {type: logical, mode: and}.
   Whatever the form writes reads back into the same cards (empty cards carry no JSON: they are
   kept from the previous draft).
   geosite / geoip stay names here: the core swaps them for its downloaded rule sets. Keys the
   form does not know are kept ("extra") and shown as a plaque; any other logical rule is
   "composite" — edited in JSON only. */

let ruleEditing = null, ruleDraft = null, rfTab = 'form', rfAddOpen = false;
const clone = o => JSON.parse(JSON.stringify(o));

function openRuleForm(id) {
  ruleEditing = id || null;
  ruleDraft = id ? clone(rulesData[id]) : newRule({ groups: { domain: { not: false, v: { domain_suffix: [] } } } });
  rfTab = 'form'; rfAddOpen = false;
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
      <div class="set-hint">The sing-box route rule. Name, Fallback, DNS and "IP conditions only in TUN" live in the form.</div></div>`;
    return;
  }
  const d = ruleDraft;
  const plaque = d.composite ? `<div class="rf-plaque">Composite rule (${esc(d.composite.mode || '')} of ${(d.composite.rules || []).length}) — edit it in JSON</div>`
    : Object.keys(d.extra || {}).length ? `<div class="rf-plaque">Extra fields: ${Object.keys(d.extra).map(esc).join(', ')} — edit them in JSON</div>` : '';
  const groups = d.composite ? '' : RULE_GROUPS.filter(g => d.groups[g.key]).map(g => rfGroupHtml(g, d.groups[g.key])).join('');
  // + Condition offers every field not on the form yet, under its card's title
  const avail = RULE_GROUPS.map(g => [g, rfFieldsOf(g).filter(([f]) => !rfHasField(d.groups[g.key], g, f))]).filter(([, fs]) => fs.length);
  const addRow = d.composite || !avail.length ? '' : rfAddOpen
    ? `<div class="rf-add"><div class="rf-add-head"><span>Add a condition</span><button class="am-link" onclick="rfAddOpen=false;renderRuleForm()">Cancel</button></div>
      ${avail.map(([g, fs]) => `<div class="rf-add-t">${g.title}${g.desktop ? ' · desktop' : ''}</div><div class="chip-row">${fs.map(([f, label]) =>
        `<div class="chip" onclick="rfAddField('${g.key}','${f}')">${esc(label)}</div>`).join('')}</div>`).join('')}</div>`
    : `<div class="node-add rf-add-btn" onclick="rfAddOpen=true;renderRuleForm()">+ Condition</div>`;
  const acts = [['proxy', 'Proxy'], ['direct', 'Direct'], ['block', 'Block']];
  const dnsOpts = [['auto', 'Auto · ' + ((dnsAutoFor(d.action === 'direct' ? 'direct' : 'vpn') || {}).name || '—')], ...dnsOrder.map(id => [id, dnsServers[id].name])];
  el.innerHTML = `
    <div class="form-group"><div class="form-label">Name</div><input class="form-input" id="rf-name" placeholder="optional" value="${esc(d.name)}" oninput="ruleDraft.name=this.value"></div>
    ${plaque}
    ${d.composite ? '' : `<div class="rf-label">If<span class="rules-note">values in a field: any · groups: all</span></div>`}
    ${groups}${addRow}
    ${ruleHasIpCondition(d) ? rfIpBlockHtml(d) : ''}
    <div class="rf-label">Then</div>
    <div class="rf-then">
      <div class="seg3 wide">${acts.map(([v, l]) => `<button class="${d.action === v ? 'on ' + v : ''}" onclick="ruleDraft.action='${v}';renderRuleForm()">${l}</button>`).join('')}</div>
      <div class="set-group rf-fbgroup">
        ${d.action === 'proxy' ? targetRowHtml('Via', d.target, 't => { ruleDraft.target = t; renderRuleForm(); }')
          : `<div class="set-row tgt-row aa-inert"><div class="set-label">Via</div><span class="tgt-val aa-dash">—</span></div>`}
        ${fallbackRowsHtml(d, 'ruleDraft', 'renderRuleForm', 'rf-fallback', d.action === 'proxy', d.target)}
        <div class="set-hint rf-fb-hint">${d.action !== 'proxy' ? 'Fallback applies to Proxy only' : d.fallback === 'default'
          ? 'Default: ' + fallbackName(quickCfg.fallback) + ' (Rules → Target unavailable)'
          : d.target ? 'If the Via target is unavailable' : 'If the main flow is down'}</div></div>
      <div class="set-group">
        ${d.action === 'block' ? `<div class="set-row"><div class="set-label">How</div><div class="chip-row">${[['drop', 'Drop silently'], ['reject', 'Reject']].map(([v, l]) =>
          `<div class="chip ${d.block === v ? 'active' : ''}" onclick="ruleDraft.block='${v}';renderRuleForm()">${l}</div>`).join('')}</div></div>` : ''}
        ${d.action !== 'block' ? `<div class="set-row"><div class="set-label">DNS</div><select class="set-select" id="rf-dns" onchange="ruleDraft.dns=this.value">${dnsOpts.map(([v, l]) =>
          `<option value="${v}" ${d.dns === v ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></div>` : ''}
      </div>
    </div>`;
}

// Does the rule match on the destination IP: IP / CIDR, local networks, GeoIP. A JSON (composite) rule: any of
// those keys anywhere inside. Own rule sets are not looked into (an .srs does not say what it holds).
function ruleHasIpCondition(d) {
  const inJson = o => Array.isArray(o) ? o.some(inJson) : o && typeof o === 'object'
    && Object.entries(o).some(([k, v]) => k === 'ip_cidr' || k === 'ip_is_private' || k === 'geoip' || (k === 'rule_set' && [].concat(v).some(t => /^geoip-/.test(t))) || inJson(v));
  if (d.composite) return inJson(d.composite);
  const g = d.groups.ip;
  return !!g && (!!g.flag || (g.v.ip_cidr || []).length > 0 || (g.v.geoip || []).length > 0);
}
// Shown only for a rule with an IP condition. Through the proxy port a site arrives as a name: IP conditions
// see it only when the core resolves first (Settings → DNS → Resolve for IP rules) unless the rule opts out.
// The explanation and the current state live in the (?) (HELP.ruleip is filled when it opens).
function rfIpBlockHtml(d) {
  return `<div class="rf-ip" data-key="ipTunOnly">
    <div class="rf-ip-row" onclick="ruleDraft.ipTunOnly=!ruleDraft.ipTunOnly;renderRuleForm()"><div class="sub-checkbox ${d.ipTunOnly ? 'checked' : ''}"></div><div class="rf-flabel">IP conditions only in TUN</div>
      <button class="help-btn" onclick="event.stopPropagation();rfIpHelp()" title="What is this?">?</button></div>
    <button class="am-link rf-ip-link" onclick="rfOpenDnsResolve()">Open DNS settings ›</button></div>`;
}
function rfIpHelp() {
  const on = !!ruleDraft.ipTunOnly, off = dnsResolveEff() === 'off';
  HELP.ruleip = { title: 'IP conditions only in TUN', items: [
    ['Why', 'through the proxy port an app sends a site name, not an address, so an IP condition matches only if the core resolves the name first. In TUN mode the address is always known.'],
    ['Ticked', 'this rule never makes the core resolve a name: through the proxy port it matches only when the address is already known.'],
    ['Not ticked', 'the core resolves names for this rule, as set in Settings → DNS → Resolve for IP rules.'],
    ['Now', `this rule is ${on ? 'ticked' : 'not ticked'}; Resolve for IP rules is ${dnsResolveText()}${off && !on ? ', so the rule works in TUN only' : ''}.`],
  ] };
  openHelp('ruleip');
}
// The DNS sheet opens above the form (the form and its draft stay open under it); closing DNS any way
// (×, swipe, Back) lands on the form, and its state text is refreshed then.
function rfOpenDnsResolve() { openSheetOver(() => openDnsSettings('dnsResolve')); }
sheetCloseHooks.setdns = () => setTimeout(() => { if (sheetStack.some(s => s.name === 'ruleform')) renderRuleForm(); }, 0);

// Every field a card can hold, as [key, label]: value fields, choices, the flag (its key is flag[0]).
const rfFieldsOf = g => [...(g.fields || []), ...(g.choices || []), ...(g.flag ? [g.flag] : [])].map(([f, label]) => [f, label]);
const rfHasField = (d, g, f) => !!d && (g.flag && f === g.flag[0] ? d.flag !== undefined : f in d.v);
const rfXBtn = (g, f) => `<button class="rf-x" onclick="rfRemoveField('${g}','${f}')" title="Remove this field">×</button>`;

function rfGroupHtml(g, d) {
  const fields = (g.fields || []).filter(([f]) => f in d.v).map(([f, label, ph, kind]) => {
    const vals = d.v[f] || [];
    return `<div class="rf-field"><div class="rf-fhead"><div class="rf-flabel">${label}</div>${rfXBtn(g.key, f)}</div>
      <div class="chip-input" onclick="if (event.target === this) this.querySelector('input').focus()">${vals.map((v, i) => {
        const ok = validVal(kind, v);
        return `<span class="vchip ${ok ? '' : 'bad'}" ${ok ? '' : `title="${esc(VAL_HINT[kind])}"`}><span class="vchip-t" onclick="rfEditVal(this,'${g.key}','${f}',${i})">${esc(v)}</span><b onclick="rfRemoveVal('${g.key}','${f}',${i})">×</b></span>`;
      }).join('')}<input data-g="${g.key}" data-f="${f}" placeholder="${vals.length ? '' : esc(ph)}" onkeydown="rfKey(event,this)" onpaste="rfPaste(event,this)" onblur="rfCommit(this)"></div>
      ${vals.some(v => !validVal(kind, v)) ? `<div class="set-hint warn">Red: ${esc(VAL_HINT[kind])}</div>` : ''}</div>`;
  }).join('');
  const choices = (g.choices || []).filter(([f]) => f in d.v).map(([f, label, opts]) => `<div class="rf-field"><div class="rf-fhead"><div class="rf-flabel">${label}</div>${rfXBtn(g.key, f)}</div><div class="chip-row" style="padding:0">${opts.map(o =>
    `<div class="chip ${(d.v[f] || []).includes(o) ? 'active' : ''}" onclick="rfToggleChoice('${g.key}','${f}','${o}')">${o.toUpperCase()}</div>`).join('')}</div></div>`).join('');
  const flag = g.flag && d.flag !== undefined ? `<div class="rf-field rf-flag"><div class="rf-flabel" style="flex:1">${g.flag[1]}</div>
    <div class="mini-toggle ${d.flag ? 'on' : ''}" onclick="ruleDraft.groups.${g.key}.flag=!ruleDraft.groups.${g.key}.flag;renderRuleForm()"><div class="mini-toggle-thumb"></div></div>${rfXBtn(g.key, g.flag[0])}</div>` : '';
  return `<div class="rf-group ${d.not ? 'not' : ''}" data-g="${g.key}">
    <div class="rf-ghead"><span class="rf-gtitle">${d.not ? 'Not ' : ''}${g.title}${g.desktop ? '<span class="conn-tag muted">desktop</span>' : ''}</span>
      <button class="rf-not ${d.not ? 'on' : ''}" onclick="ruleDraft.groups.${g.key}.not=!ruleDraft.groups.${g.key}.not;renderRuleForm()">except</button>
      <button class="rf-x" onclick="rfRemoveGroup('${g.key}')" title="Remove">×</button></div>
    ${fields}${choices}${flag}</div>`;
}

// + Condition: the field goes on its card (the card is made if it is not there yet)
function rfAddField(g, f) {
  const grp = ruleDraft.groups[g] = ruleDraft.groups[g] || { not: false, v: {} };
  if (GROUP[g].flag && f === GROUP[g].flag[0]) grp.flag = true;
  else grp.v[f] = grp.v[f] || [];
  rfAddOpen = false;
  renderRuleForm();
  const input = document.querySelector(`#rf-body input[data-g="${g}"][data-f="${f}"]`);
  if (input) input.focus();
}
// A field's ×: the card goes with its last field
function rfRemoveField(g, f) {
  const grp = ruleDraft.groups[g];
  if (GROUP[g].flag && f === GROUP[g].flag[0]) delete grp.flag; else delete grp.v[f];
  if (!Object.keys(grp.v).length && grp.flag === undefined) delete ruleDraft.groups[g];
  renderRuleForm();
}
function rfRemoveGroup(key) { delete ruleDraft.groups[key]; renderRuleForm(); }
function rfRemoveVal(g, f, i) { ruleDraft.groups[g].v[f].splice(i, 1); renderRuleForm(); }
/* A chip's text taps into an inline input (caret at the end). Enter / blur commits: a changed value
   replaces the chip (a list with commas / newlines replaces it with those values), an empty one removes
   it, an invalid one (the field's own validator, as the red chips) stays in edit, red, with its hint;
   Esc cancels. The edit lives in the DOM only: a re-render ends it. */
function rfEditVal(el, g, f, i) {
  const chip = el.closest('.vchip'), old = ruleDraft.groups[g].v[f][i], kind = GROUP[g].fields.find(x => x[0] === f)[3];
  if (!chip || chip.querySelector('input')) return;
  const input = document.createElement('input');
  input.value = old; input.className = 'vchip-edit'; input.spellcheck = false;
  const fit = () => { input.style.width = Math.min(Math.max(input.value.length, 3) + 1, 40) + 'ch'; };
  const hint = bad => {
    const field = chip.closest('.rf-field');
    let h = field.querySelector('.rf-edit-hint');
    input.classList.toggle('bad', bad);
    if (bad && !h) { h = document.createElement('div'); h.className = 'set-hint warn rf-edit-hint'; field.appendChild(h); }
    if (h) { if (bad) h.textContent = 'Red: ' + VAL_HINT[kind]; else h.remove(); }
  };
  const commit = () => {
    if (input.dataset.done) return;
    const parts = input.value.split(/[\n,;]+/).map(s => s.trim()).filter(Boolean);
    if (parts.some(v => !validVal(kind, v))) { hint(true); return; }
    input.dataset.done = '1';
    const list = ruleDraft.groups[g].v[f];
    list.splice(i, 1, ...parts.filter(v => !list.includes(v) || v === old));
    ruleDraft.groups[g].v[f] = list.filter((v, k) => list.indexOf(v) === k);
    renderRuleForm();
  };
  input.addEventListener('input', () => { fit(); hint(false); });
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); commit(); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); input.dataset.done = '1'; renderRuleForm(); }
  });
  input.addEventListener('blur', commit);
  el.replaceWith(input);
  fit(); input.focus(); input.setSelectionRange(old.length, old.length);
}
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
  // an empty card says nothing: no JSON for it (a {} inside the logical rule would not read back)
  const gs = RULE_GROUPS.filter(g => r.groups[g.key] && Object.keys(groupJson(g.key, r.groups[g.key])).length).map(g => [g.key, r.groups[g.key]]);
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
// JSON tab → draft (keeps name, Fallback, DNS, enabled). false if the JSON is invalid.
function rfApplyJson() {
  if (rfTab !== 'json') return true;
  if (!rfCheckJson()) { toast('Fix the JSON first'); return false; }
  const r = ruleFromJson(JSON.parse(document.getElementById('rf-json').value));
  ['id', 'name', 'enabled', 'fallback', 'fallbackTarget', 'dns', 'ipTunOnly'].forEach(k => r[k] = ruleDraft[k]);
  if (r.action !== 'proxy') r.target = ruleDraft.target;   // the JSON has no place for what the action does not use
  if (r.action !== 'block') r.block = ruleDraft.block;
  // cards and fields not filled yet are not in the JSON: keep them as the form had them
  if (!r.composite) Object.entries(ruleDraft.groups).forEach(([k, g]) => {
    const n0 = r.groups[k], empty = Object.keys(g.v).filter(f => !g.v[f].length && !(n0 && f in n0.v));
    const flagOff = g.flag === false && !(n0 && n0.flag !== undefined);
    if (!empty.length && !flagOff) return;
    const n = r.groups[k] = n0 || { not: g.not, v: {} };
    empty.forEach(f => n.v[f] = []);
    if (flagOff) n.flag = false;
  });
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
  if (d.action !== 'proxy') d.fallback = 'default';   // Fallback only means something for Proxy (a target or the main flow)
  if (d.fallback !== 'main' || d.fallbackTarget === d.target) d.fallbackTarget = '';
  if (!ruleHasIpCondition(d) || !d.ipTunOnly) delete d.ipTunOnly;
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
