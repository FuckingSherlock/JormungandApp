/* ── Toast ── */

let toastTimer = null;
// act: { label, fn } — a button in the toast (it then stays longer and takes taps).
function toast(msg, act) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  if (act) {
    const b = document.createElement('button');
    b.className = 'toast-act';
    b.textContent = act.label;
    b.onclick = () => { el.classList.remove('show'); act.fn(); };
    el.append(b);
  }
  el.classList.toggle('has-act', !!act);
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), act ? 6000 : 2200);
}

/* ── Tabs ── */

// The nav is always visible, so a tab tap also closes whatever sheets are open over the view.
function switchTab(name) {
  document.querySelectorAll('.sheet.open').forEach(el => closeSheet(el.id.slice(3)));
  justClosed = [];
  document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + name));
  document.querySelectorAll('.nav-btn[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('#view-' + name + ' > .scroll').forEach(el => el.scrollTop = 0);
  syncBackHistory();   // back from another tab goes Home (60-sheets.js)
  if (name === 'logs') openLogs();
}

