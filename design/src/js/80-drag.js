/* ══════════════════════ PRIORITY: DRAG TO REORDER (left grip) ══════════════════════
   Important: we must NOT re-render (replace DOM) the row while the drag is in
   progress — on touch devices the browser holds an implicit pointer capture on
   the element that received pointerdown, and destroying that element mid-gesture
   fires pointercancel immediately (symptom: row flashes gray once, then nothing
   moves). So during the drag we only visually translateY() the single dragged
   row; the actual array reorder + re-render happens once, on drop.
──────────────────────────────────────────────────────────────────────────── */

let dragCtx = null;
const DRAG_ANIM_MS = 180;

/* Sortable-list feel: the grabbed row follows the pointer (lifted), the rows it passes
   slide out of the way, and on drop it glides into its slot; only then the data is
   reordered and the list re-rendered. */
function startRowDrag(e, rowEl, itemSelector, order, render) {
  e.preventDefault();
  e.stopPropagation();
  if (!rowEl || dragCtx) return;
  const items = Array.from(rowEl.parentElement.querySelectorAll(':scope > ' + itemSelector));
  const rects = items.map(el => el.getBoundingClientRect());
  const origIndex = items.indexOf(rowEl);
  const gap = rects.length > 1 ? rects[1].top - rects[0].bottom : 0;
  dragCtx = {
    id: rowEl.dataset.id, rowEl, items, rects, order, render, origIndex,
    startY: e.clientY, target: origIndex, step: rects[origIndex].height + gap,
  };
  items.forEach(el => { if (el !== rowEl) el.style.transition = `transform ${DRAG_ANIM_MS}ms ease`; });
  rowEl.classList.add('dragging-row');
  rowEl.style.position = 'relative';
  rowEl.style.zIndex = '5';
}

function startConnectDrag(e, id) {
  const rowEl = document.querySelector('#connects-list .conn-row[data-id="'+id+'"]');
  startRowDrag(e, rowEl, '.conn-row', () => connectOrder, () => { renderConnects(); updateMainConnectCard(); });
}

function startSourceDrag(e, id) {
  const rowEl = document.querySelector('#nodes-list .src-card[data-id="'+id+'"]');
  startRowDrag(e, rowEl, '.src-card', () => sourceOrder, () => { renderNodes(); renderConnects(); });
}

// Target slot: a row below is passed once the dragged row's bottom edge crosses its centre,
// a row above once the top edge does. (Comparing centres fails for rows of different
// heights: a tall row could never pass a short last one within the drag bounds.)
function dragTargetIndex(dy) {
  const { rects, origIndex } = dragCtx;
  const o = rects[origIndex];
  let t = 0;
  rects.forEach((r, i) => {
    const mid = r.top + r.height / 2;
    if (i < origIndex ? o.top + dy >= mid : i > origIndex && o.bottom + dy > mid) t++;
  });
  return t;
}

function onRowDragMove(e) {
  if (!dragCtx || dragCtx.dropping) return;
  const c = dragCtx;
  const first = c.rects[0], last = c.rects[c.rects.length - 1], o = c.rects[c.origIndex];
  const dy = Math.max(first.top - o.top - 8, Math.min(last.bottom - o.bottom + 8, e.clientY - c.startY));
  c.dy = dy;
  c.rowEl.style.transform = `translateY(${dy}px) scale(1.02)`;
  const t = dragTargetIndex(dy);
  if (t === c.target) return;
  c.target = t;
  c.items.forEach((el, i) => {
    if (i === c.origIndex) return;
    const shift = (c.origIndex < i && i <= t) ? -c.step : (t <= i && i < c.origIndex) ? c.step : 0;
    el.style.transform = shift ? `translateY(${shift}px)` : '';
  });
}

function onRowDragEnd() {
  if (!dragCtx || dragCtx.dropping) return;
  const c = dragCtx;
  c.dropping = true;
  const { rects, origIndex: o, target: t } = c;
  const slot = t > o ? rects[t].bottom - rects[o].bottom : t < o ? rects[t].top - rects[o].top : 0;
  c.rowEl.style.transition = `transform ${DRAG_ANIM_MS}ms ease`;
  c.rowEl.style.transform = `translateY(${slot}px)`;
  setTimeout(() => {
    c.items.forEach(el => { el.style.transform = ''; el.style.transition = ''; });
    c.rowEl.style.position = '';
    c.rowEl.style.zIndex = '';
    c.rowEl.classList.remove('dragging-row');
    const order = c.order();
    const cur = order.indexOf(c.id);
    if (t !== cur) { order.splice(cur, 1); order.splice(t, 0, c.id); }
    dragCtx = null;
    c.render();
  }, (c.dy || 0) === slot ? 0 : DRAG_ANIM_MS);
}
window.addEventListener('pointermove', onRowDragMove);
window.addEventListener('pointerup', onRowDragEnd);
window.addEventListener('pointercancel', onRowDragEnd);
