/* ══════════════════════ SWIPE-DOWN-TO-DISMISS (all sheets) ══════════════════════ */

function makeDraggable(name) {
  const sheet = document.getElementById('sh-'+name);
  const zones = [sheet.querySelector('.sheet-handle'), sheet.querySelector('.sheet-head')];
  let startY = 0, dy = 0, dragging = false;

  function onDown(e) {
    dragging = true; dy = 0;
    startY = e.touches ? e.touches[0].clientY : e.clientY;
    sheet.classList.add('dragging');
  }
  function onMove(e) {
    if (!dragging) return;
    const y = e.touches ? e.touches[0].clientY : e.clientY;
    dy = Math.max(0, y - startY);
    sheet.style.transform = 'translateY(' + dy + 'px)';
  }
  function onUp() {
    if (!dragging) return;
    dragging = false;
    sheet.classList.remove('dragging');
    if (dy > 110) closeSheet(name);
    sheet.style.transform = '';
  }

  zones.forEach(zone => { if (zone) zone.addEventListener('pointerdown', onDown); });
  window.addEventListener('pointermove', onMove);
  window.addEventListener('pointerup', onUp);
}
['profiles','connections','rules','createprofile','createchain','sourceentry','ruleform','apps','ruleorder','ruleio','rulesets','rsform','dnsform','addmenu','nodesmore','actions','srcform','nodeform'].forEach(makeDraggable);

