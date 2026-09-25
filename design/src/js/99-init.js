/* ══════════════════════ INITIAL RENDER ══════════════════════ */

applyTheme(currentTheme);
applyScale(uiScale);
purgeExpiredGone();
renderAutoMode();
renderConnSettings();
renderDns();
['mode', 'route', 'sys'].forEach(g => setSegment(g, segState[g]));

renderConnects();
initNodesPager();
renderNodes();
renderRules();
updateMainConnectCard();
