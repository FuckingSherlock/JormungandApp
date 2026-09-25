/* ══════════════════════ THEMES ══════════════════════ */

const THEMES = [
  { id:'original', name:'Original', sub:'Navy, blue accent',         swatch:['#0B0F1A','#1A2035','#4F8EFF','#00C896'] },
  { id:'karing',   name:'Karing',   sub:'Neutral grey, blue accent', swatch:['#151515','#212121','#4F8EFF','#2FBF6A'] },
  { id:'github',  name:'GitHub',  sub:'GitHub Dark palette',       swatch:['#0D1117','#161B22','#2F81F7','#3FB950'] },
];
let currentTheme = 'original';
try { currentTheme = localStorage.getItem('jmg-theme') || 'original'; } catch (e) {}

function applyTheme(id) {
  currentTheme = THEMES.some(t => t.id === id) ? id : 'original';
  document.documentElement.setAttribute('data-theme', currentTheme);
  try { localStorage.setItem('jmg-theme', currentTheme); } catch (e) {}
  renderThemeList();
}

function renderThemeList() {
  document.getElementById('setLookSub').textContent = THEMES.find(t => t.id === currentTheme).name;
  document.getElementById('theme-list').innerHTML = THEMES.map(t => `<div class="settings-row" onclick="applyTheme('${t.id}')">
      <div class="theme-swatch">${t.swatch.map(c => `<span style="background:${c}"></span>`).join('')}</div>
      <div style="flex:1"><div class="settings-label">${t.name}</div><div class="settings-sub">${t.sub}</div></div>
      <div class="profile-radio ${t.id === currentTheme ? 'active' : ''}"></div>
    </div>`).join('');
}

