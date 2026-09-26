// Runs at document start as part of the WKUserScript (after `window.__sbInitial = <payload>;`), before <head> exists, and
// again from app.js through sbTheme.apply whenever the settings change. It only touches <html>: attributes, CSS variables,
// and the two user stylesheet links. Every bundled stylesheet sits in a cascade layer, so the user's CSS wins wherever it is
// inserted; custom.css is kept after the user theme so it wins over both.
(() => {
  const THEMES = ['apple', 'github', 'paper', 'solarized', 'nord', 'contrast'];
  const MEASURE = { narrow: '640px', medium: '760px', wide: '960px', full: 'none' };
  const pick = (v, allowed, dflt) => (allowed.includes(v) ? v : dflt);
  const num = (v, lo, hi, dflt) => (typeof v === 'number' && isFinite(v) ? Math.min(hi, Math.max(lo, v)) : dflt);
  const sb = (window.sbTheme = window.sbTheme || {});

  // The two links stay adjacent, user theme first, wherever the first one was put (<html> at document start, <head> later).
  function setLink(id, url) {
    let l = document.getElementById(id);
    if (typeof url !== 'string' || !url.startsWith('spacebar://user/')) { if (l) l.remove(); return; }
    if (l) { if (l.getAttribute('href') !== url) l.setAttribute('href', url); return; }
    l = document.createElement('link');
    l.id = id;
    l.rel = 'stylesheet';
    l.addEventListener('load', () => { if (typeof sb.onchange === 'function') sb.onchange(); });
    l.setAttribute('href', url);
    const theme = document.getElementById('sb-user-theme'), custom = document.getElementById('sb-custom-css');
    if (id === 'sb-user-theme' && custom) custom.before(l);
    else if (id === 'sb-custom-css' && theme) theme.after(l);
    else (document.head || document.documentElement).appendChild(l);
  }

  sb.apply = function apply(p) {
    if (!p || typeof p !== 'object') return;
    const r = document.documentElement;
    const d = r.dataset;
    d.theme = pick(p.theme, THEMES, 'apple');
    const code = pick(p.codeTheme, THEMES, '');
    if (code) d.codeTheme = code; else delete d.codeTheme;
    d.font = pick(p.bodyFont, ['system', 'serif', 'rounded', 'mono'], 'system');
    d.mono = pick(p.monoFont, ['system', 'menlo', 'monaco', 'courier'], 'system');
    d.width = pick(p.width, Object.keys(MEASURE), 'medium');
    d.editing = p.inlineEditing === false ? 'off' : 'on';
    d.remoteImages = p.remoteImages === true ? 'on' : 'off';
    r.style.setProperty('--font-size', Math.round(num(p.fontSize, 12, 24, 15)) + 'px');
    r.style.setProperty('--line-height', String(num(p.lineHeight, 1.2, 2, 1.6)));
    r.style.setProperty('--measure', MEASURE[d.width]);
    setLink('sb-user-theme', p.userThemeURL);
    setLink('sb-custom-css', p.customCSSURL);
  };

  if (window.__sbInitial) sb.apply(window.__sbInitial);
})();
