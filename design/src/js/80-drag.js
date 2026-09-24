/* ══════════════════════ PRIORITY: DRAG TO REORDER (left grip) ══════════════════════
   Important: we must NOT re-render (replace DOM) the row while the drag is in
   progress — on touch devices the browser holds an implicit pointer capture on
   the element that received pointerdown, and destroying that element mid-gesture
   fires pointercancel immediately (symptom: row flashes gray once, then nothing
   moves). So during the drag we only visually translateY() the single dragged
   row; the actual array reorder + re-render happens once, on drop.
──────────────────────────────────────────────────────────────────────────── */

let dragCtx = null;

function startRowDrag(e, rowEl, itemSelector, order, render) {
  e.preventDefault();
  e.stopPropagation();
  if (!rowEl) return;
  const items = Array.from(rowEl.parentElement.querySelectorAll(':scope > ' + itemSelector));
  const rects = items.map(el => el.getBoundingClientRect());
  dragCtx = {
    id: rowEl.dataset.id, rowEl, items, rects, order, render,
    startY: e.clientY,
    origIndex: items.indexOf(rowEl),
  };
  rowEl.classList.add('dragging-row');
  rowEl.style.position = 'relative';
  rowEl.style.zIndex = '5';
}

function startConnectDrag(e, id) {
  const rowEl = document.querySelector('#connects-list .profile-item[data-id="'+id+'"]');
  startRowDrag(e, rowEl, '.profile-item', () => connectOrder, renderConnects);
}

function startSourceDrag(e, id) {
  const rowEl = document.querySelector('#nodes-list .src-card[data-id="'+id+'"]');
  startRowDrag(e, rowEl, '.src-card', () => sourceOrder, () => { renderNodes(); renderConnects(); });
}

function onRowDragMove(e) {
  if (!dragCtx) return;
  const dy = e.clientY - dragCtx.startY;
  dragCtx.rowEl.style.transform = 'translateY(' + dy + 'px)';
}

function onRowDragEnd(e) {
  if (!dragCtx) return;
  const dy = e.clientY - dragCtx.startY;
  const origRect = dragCtx.rects[dragCtx.origIndex];
  const draggedCenter = origRect.top + origRect.height / 2 + dy;

  let targetIndex = 0;
  dragCtx.items.forEach((el, i) => {
    if (i === dragCtx.origIndex) return;
    const r = dragCtx.rects[i];
    const c = r.top + r.height / 2;
    if (c < draggedCenter) targetIndex++;
  });

  dragCtx.rowEl.style.transform = '';
  dragCtx.rowEl.style.position = '';
  dragCtx.rowEl.style.zIndex = '';
  dragCtx.rowEl.classList.remove('dragging-row');

  const order = dragCtx.order();
  const curIndex = order.indexOf(dragCtx.id);
  if (targetIndex !== curIndex) {
    order.splice(curIndex, 1);
    order.splice(targetIndex, 0, dragCtx.id);
  }
  const render = dragCtx.render;
  dragCtx = null;
  render();
}
window.addEventListener('pointermove', onRowDragMove);
window.addEventListener('pointerup', onRowDragEnd);
window.addEventListener('pointercancel', onRowDragEnd);

