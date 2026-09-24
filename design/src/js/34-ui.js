/* ── Toast ── */

let toastTimer = null;
function toast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
}

/* ── Long press (hold ~0.5 s) — a row's secondary action, e.g. a server's menu ──
   The click that follows the hold is swallowed: onclick checks longPressed(). */
let lpTimer = null, lpFired = false;
function longPress(e, fn) {
  lpFired = false;
  clearTimeout(lpTimer);
  const x = e.clientX, y = e.clientY, el = e.currentTarget;
  const stop = () => { clearTimeout(lpTimer); el.removeEventListener('pointermove', move); };
  const move = ev => { if (Math.abs(ev.clientX - x) + Math.abs(ev.clientY - y) > 8) stop(); };
  el.addEventListener('pointermove', move);
  el.addEventListener('pointerup', stop, { once: true });
  el.addEventListener('pointerleave', stop, { once: true });
  lpTimer = setTimeout(() => { lpFired = true; stop(); fn(); }, 500);
}
function longPressed() { const f = lpFired; lpFired = false; return f; }

/* ── Tabs ── */

function switchTab(name) {
  document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + name));
  document.querySelectorAll('.nav-btn[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('#view-' + name + ' > .scroll').forEach(el => el.scrollTop = 0);
}

