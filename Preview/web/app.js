'use strict';
const post = (msg) => window.webkit.messageHandlers.sb.postMessage(msg);
window.addEventListener('error', (e) => post({ type: 'log', msg: `${e.message} @${e.lineno}` }));
document.addEventListener('securitypolicyviolation', (e) => post({ type: 'log', msg: `csp blocked ${e.violatedDirective} ${e.blockedURI}` }));
window.addEventListener('unhandledrejection', (e) => post({ type: 'log', msg: 'rejection: ' + e.reason }));
const $ = (id) => document.getElementById(id);
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};

// The defaults of Shared/Settings.swift, then the document-start payload, then each sb.applySettings. settings.js (the
// document-start script) is absent in a plain browser, so the page falls back to a minimal apply of its own.
const DEFAULTS = { theme: 'apple', appearance: 'auto', codeTheme: 'auto', bodyFont: 'system', monoFont: 'system', fontSize: 15,
  lineHeight: 1.6, width: 'medium', frontMatter: 'table', toc: 'auto', stats: true, math: true, mermaid: true, rawHTML: 'sanitized',
  remoteImages: false, inlineEditing: true, taskToggles: true, sidebarCollapsed: false, sidebarWidth: 240, minimalChrome: false, customCSSURL: null,
  userThemeURL: null };
let settings = { ...DEFAULTS, ...(window.__sbInitial || {}) };
const THEMES = { apple: 'Apple', github: 'GitHub', paper: 'Paper', solarized: 'Solarized', nord: 'Nord', contrast: 'High Contrast' };
const theme = window.sbTheme && typeof window.sbTheme.apply === 'function' ? window.sbTheme : {
  apply(p) {
    const r = document.documentElement;
    Object.assign(r.dataset, { theme: p.theme, font: p.bodyFont, mono: p.monoFont, width: p.width, editing: p.inlineEditing ? 'on' : 'off',
      sidebar: p.sidebarCollapsed === true ? 'collapsed' : 'open', chrome: p.minimalChrome === true ? 'minimal' : 'app' });
    r.style.setProperty('--font-size', p.fontSize + 'px');
    r.style.setProperty('--side-saved', p.sidebarWidth + 'px');
  },
};
theme.apply(settings);

function markdown(html) {
  const md = window.markdownit({
    html,
    linkify: true,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) return hljs.highlight(code, { language: lang }).value;
      return '';
    },
  }).use(texmath, { engine: { renderToString: (tex, o) => `<span class="tex" data-display="${o.displayMode ? 1 : 0}" data-tex="${esc(tex)}"></span>` },
                     delimiters: 'dollars' });

  const fence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, idx, opts, env, self) => {
    const t = tokens[idx];
    if (t.info.trim() === 'mermaid' && settings.mermaid) return `<pre class="mermaid">${esc(t.content)}</pre>`;
    return fence(tokens, idx, opts, env, self);
  };
  // These renderers drop token attributes, so their top-level blocks are wrapped to carry the source range.
  for (const name of ['fence', 'math_block', 'math_block_eqno']) {
    const inner = md.renderer.rules[name];
    if (!inner) continue;
    md.renderer.rules[name] = (tokens, idx, opts, env, self) => {
      const t = tokens[idx];
      const src = t.attrGet('data-src');
      if (src === null) return inner(tokens, idx, opts, env, self);
      t.attrs = t.attrs.filter(([k]) => k !== 'data-src');
      return `<div class="blk" data-src="${src}">${inner(tokens, idx, opts, env, self)}</div>`;
    };
  }

  // GFM task items; data-line is the 0-based source line of the list item, used to toggle on disk.
  md.core.ruler.push('tasks', (state) => {
    const toks = state.tokens;
    for (let i = 2; i < toks.length; i++) {
      const inline = toks[i];
      if (inline.type !== 'inline' || toks[i - 1].type !== 'paragraph_open' || toks[i - 2].type !== 'list_item_open') continue;
      const m = /^\[([ xX])\]\s/.exec(inline.content);
      if (!m || !inline.children.length || inline.children[0].type !== 'text') continue;
      const li = toks[i - 2];
      li.attrJoin('class', 'task');
      inline.children[0].content = inline.children[0].content.slice(m[0].length);
      const box = new state.Token('html_inline', '', 0);
      box.content = `<input type="checkbox" data-line="${li.map[0]}"${m[1] === ' ' ? '' : ' checked'}>`;
      inline.children.unshift(box);
    }
  });

  md.inline.ruler.before('link', 'wikilink', wikiRule);
  md.inline.ruler.before('newline', 'tag', tagRule);
  md.renderer.rules.wikilink = (tokens, idx) => wikiHTML(tokens[idx].meta);
  md.renderer.rules.tag = (tokens, idx) => `<span class="tag">#${esc(tokens[idx].content)}</span>`;

  // Top-level blocks carry their source line range so a click can be mapped back to the markdown it came from.
  md.core.ruler.push('srcmap', (state) => {
    for (const t of state.tokens) if (t.level === 0 && t.nesting >= 0 && t.type !== 'inline' && t.map) t.attrSet('data-src', `${t.map[0]},${t.map[1]}`);
  });
  return md;
}
// ---------- Obsidian: [[wikilinks]], ![[embeds]], #tags and > [!callouts] ----------
// A link's target is resolved by the extension (LinkIndex), never here: the page only draws what the render payload's `links`
// and `embeds` name, and asks to open a path from them, which the extension checks again. Nothing of the document's own markup
// chooses a path or an image URL.

/** `[[target#heading|alias]]` or `![[...]]`, on one line, at most 400 characters. */
function wikiRule(state, silent) {
  const src = state.src, pos = state.pos;
  const embed = src.charCodeAt(pos) === 0x21;
  const open = embed ? pos + 1 : pos;
  if (src.charCodeAt(open) !== 0x5B || src.charCodeAt(open + 1) !== 0x5B) return false;
  const end = src.indexOf(']]', open + 2);
  if (end < 0) return false;
  const inner = src.slice(open + 2, end);
  if (!inner || inner.length > 400 || /[[\]\n]/.test(inner)) return false;
  if (!silent) state.push('wikilink', '', 0).meta = { inner, embed };
  state.pos = end + 2;
  return true;
}

/** `#tag` after a space or at the start: letters, digits, `_`, `-` and `/`, not only digits (so not `#1`). */
function tagRule(state, silent) {
  const pos = state.pos;
  if (state.src.charCodeAt(pos) !== 0x23 || (pos > 0 && !/\s/.test(state.src[pos - 1]))) return false;
  const m = /^#([\p{L}\p{N}_/-]{1,100})/u.exec(state.src.slice(pos, pos + 102));
  if (!m || /^[\d/_-]*$/.test(m[1])) return false;
  if (!silent) state.push('tag', '', 0).content = m[1];
  state.pos = pos + m[0].length;
  return true;
}

/** The parts of a link, as the extension parses them: `\|` (escaped inside a table) separates the alias too. */
function parseWiki(inner) {
  const s = inner.replace(/\\\|/g, '|');
  const bar = s.indexOf('|');
  const head = bar < 0 ? s : s.slice(0, bar);
  const hash = head.indexOf('#');
  return { target: (hash < 0 ? head : head.slice(0, hash)).trim(), heading: hash < 0 ? '' : head.slice(hash + 1).trim(),
           alias: bar < 0 ? '' : s.slice(bar + 1).trim() };
}

const own = (o, k) => !!o && typeof o === 'object' && Object.prototype.hasOwnProperty.call(o, k);
/** What the extension resolved `target` to in the document being drawn: {path, name, icon, kind, src?}, or null. */
function wikiTarget(target) {
  const r = own(current.links, target) ? current.links[target] : null;
  return r && typeof r === 'object' && typeof r.path === 'string' ? r : null;
}

let renderDepth = 0;
function wikiHTML(m) {
  const w = parseWiki(m.inner);
  const r = w.target ? wikiTarget(w.target) : null;
  const label = w.alias || (w.target ? w.target + (w.heading ? ' › ' + w.heading : '') : w.heading);
  if (m.embed && r && r.kind === 'image') {
    const size = /^(\d{1,4})(?:x(\d{1,4}))?$/.exec(w.alias);
    return `<img class="wl-img" data-wl="${esc(w.target)}" alt="${esc(size ? w.target : label)}"` +
      (size ? ` width="${size[1]}"${size[2] ? ` height="${size[2]}"` : ''}` : '') + '>';
  }
  if (m.embed && r && r.kind === 'markdown' && renderDepth === 0) return `<span class="wl-embed" data-wl="${esc(w.target)}"></span>`;
  // Until the extension has indexed the folder, a link it has not resolved yet looks like any other.
  // A folder too big to index completely may hold the note all the same.
  const missing = w.target && !r && current.linksReady !== false && current.linksComplete !== false;
  return `<a href="#" class="wikilink${missing ? ' unresolved' : ''}" data-wl="${esc(w.target)}" data-wl-h="${esc(w.heading)}">${esc(label)}</a>`;
}

// Callout types, as Obsidian names them, by colour family; anything else is a note.
const CALLOUTS = { note: 'blue', info: 'blue', todo: 'blue', abstract: 'cyan', summary: 'cyan', tldr: 'cyan', tip: 'teal', hint: 'teal',
  important: 'teal', success: 'green', check: 'green', done: 'green', question: 'yellow', help: 'yellow', faq: 'yellow',
  warning: 'orange', caution: 'orange', attention: 'orange', failure: 'red', fail: 'red', missing: 'red', danger: 'red', error: 'red',
  bug: 'red', example: 'purple', quote: 'gray', cite: 'gray' };

/** `> [!type] Title` blockquotes become callouts: a title row (the rest of the first line, or the type) above the body. */
function callouts(frag) {
  frag.querySelectorAll('blockquote').forEach((bq) => {
    const p = bq.firstElementChild;
    const first = p && p.tagName === 'P' ? p.firstChild : null;
    const m = first && first.nodeType === 3 ? /^\[!([A-Za-z][\w-]{0,30})\]([+-]?)[ \t]*/.exec(first.data) : null;
    if (!m) return;
    first.data = first.data.slice(m[0].length);
    const type = m[1].toLowerCase();
    const title = el('div', 'callout-title');
    const text = el('span', 'callout-text');
    for (let n = p.firstChild; n;) {
      const next = n.nextSibling;
      if (n.nodeName === 'BR') { n.remove(); break; }
      if (n.nodeType === 3 && n.data.includes('\n')) {
        const rest = n.splitText(n.data.indexOf('\n'));
        rest.data = rest.data.slice(1);
        if (n.data) text.append(n);
        break;
      }
      text.append(n);
      n = next;
    }
    if (!text.textContent.trim()) text.textContent = type[0].toUpperCase() + type.slice(1);
    title.append(el('span', 'callout-icon'), text);
    bq.classList.add('callout');
    bq.dataset.callout = CALLOUTS[type] || 'blue';
    bq.insertBefore(title, p);
    if (!p.textContent.trim() && !p.querySelector('img, input, .katex')) p.remove();
  });
}

/** After sanitizing: callouts, embedded images from the payload's URLs, and embedded notes one level deep (read only: their
 *  blocks cannot be edited and their tasks cannot be ticked, since their lines are another file's). */
function obsidian(frag, depth) {
  callouts(frag);
  frag.querySelectorAll('img.wl-img').forEach((img) => {
    const r = wikiTarget(img.dataset.wl || '');
    if (r && typeof r.src === 'string' && r.src.startsWith('spacebar://file/')) img.src = r.src;
    else img.replaceWith(el('span', 'wl-missing', img.alt || ''));
  });
  // Each note is embedded once, at most 16 times in all (as many as the extension sends): a document repeating an embed
  // thousands of times gets links, not thousands of copies.
  const filled = new Set();
  frag.querySelectorAll('span.wl-embed').forEach((span) => {
    const t = span.dataset.wl || '', r = wikiTarget(t);
    const e = depth === 0 && !filled.has(t) && filled.size < 16 && own(current.embeds, t) ? current.embeds[t] : null;
    if (e) filled.add(t);
    const head = el('a', 'wikilink wl-embed-head', r ? plainName(r.name || t) : t);
    head.href = '#';
    head.dataset.wl = t;
    head.dataset.wlH = '';
    if (!r || !e || typeof e.text !== 'string') { span.replaceWith(head); return; }
    head.prepend(icon('markdown', 14));
    const body = el('span', 'wl-embed-body');
    body.append(render(e.text, depth + 1));
    body.querySelectorAll('[data-src]').forEach((n) => n.removeAttribute('data-src'));
    body.querySelectorAll('input[type=checkbox]').forEach((n) => { n.removeAttribute('data-line'); n.disabled = true; });
    span.append(head, body);
  });
}

// rawHTML 'off' renders the document's HTML as text; 'sanitized' parses it. Both outputs go through the same sanitizer.
const mdHTML = markdown(true);
const mdText = markdown(false);

// Raw HTML in the document is untrusted (html:true), so the whole rendered page is sanitized before it reaches the DOM, and
// before mermaid runs. Math is rendered by KaTeX after sanitizing (texmath emits placeholders), so the sanitizer can drop every
// style attribute but a table cell's alignment: inline styles would let a link cover the whole preview and take every click.
// texmath wraps formulas in <eq>/<eqn>; the only inputs kept are task checkboxes.
const PURIFY = { ADD_TAGS: ['eq', 'eqn'], FORBID_TAGS: ['form', 'style', 'label'], SANITIZE_NAMED_PROPS: true, RETURN_DOM_FRAGMENT: true };
DOMPurify.addHook('uponSanitizeAttribute', (node, data) => {
  if (data.attrName === 'overflow') data.keepAttr = false;
  if (data.attrName === 'style' && !/^\s*text-align:\s*(left|right|center);?\s*$/i.test(data.attrValue)) data.keepAttr = false;
});

/** A leading YAML (---) or TOML (+++) front matter block, and the source with its lines blanked (not removed), so every
 *  data-src after it is still the true source line. */
function frontMatter(text) {
  const m = /^(---|\+\+\+)[ \t]*\r?\n/.exec(text);
  if (!m) return null;
  const lines = text.split('\n');
  for (let i = 1; i < lines.length; i++) {
    const l = lines[i].replace(/\r$/, '').trimEnd();
    if (l === m[1] || (m[1] === '---' && l === '...')) {
      return { toml: m[1] === '+++', fence: m[1], close: l, lines: lines.slice(1, i).map((x) => x.replace(/\r$/, '')),
               body: lines.map((x, j) => (j <= i ? '' : x)).join('\n') };
    }
  }
  return null;
}

const unquote = (s) => s.replace(/^(["'])(.*)\1$/, '$2');

/** The front matter as settings.frontMatter asks: a key/value table, the raw block, or nothing. Text nodes only, no data-src. */
function frontMatterNode(fm) {
  if (settings.frontMatter === 'hide') return null;
  if (settings.frontMatter === 'raw') {
    const pre = el('pre', 'frontmatter-raw');
    pre.appendChild(el('code', '', [fm.fence, ...fm.lines, fm.close].join('\n')));
    return pre;
  }
  const pair = fm.toml ? /^([A-Za-z0-9_][\w.-]*)\s*=\s*(.*)$/ : /^([^\s#:-][^:]*?):(?:\s+(.*)|\s*)$/;
  const rows = [];
  for (const line of fm.lines) {
    const m = pair.exec(line);
    if (m) rows.push({ key: m[1].trim(), value: (m[2] || '').trim(), raw: [] });
    else if (line.trim() && !/^\s*#/.test(line)) {
      if (!rows.length) rows.push({ key: '', value: '', raw: [] });
      rows[rows.length - 1].raw.push(line);
    }
  }
  if (!rows.length) return null;
  const table = el('table', 'frontmatter');
  const body = table.appendChild(el('tbody'));
  for (const r of rows) {
    const tr = body.appendChild(el('tr'));
    tr.appendChild(el('th', '', r.key));
    const td = tr.appendChild(el('td'));
    const list = /^\[(.*)\]$/.exec(r.value);
    if (list && !/[[\]{}]/.test(list[1])) {
      for (const item of list[1].split(',').map((x) => unquote(x.trim())).filter(Boolean)) td.appendChild(el('span', 'fm-tag', item));
    } else if (r.value) td.appendChild(document.createTextNode(unquote(r.value)));
    if (r.raw.length) td.appendChild(el('pre')).appendChild(el('code', '', r.raw.join('\n')));
  }
  return table;
}

function render(text, depth = 0) {
  const fm = frontMatter(text);
  const md = settings.rawHTML === 'off' ? mdText : mdHTML;
  renderDepth = depth;
  let html;
  try { html = md.render(fm ? fm.body : text); } finally { renderDepth = 0; }
  const frag = DOMPurify.sanitize(html, PURIFY);
  frag.querySelectorAll('input:not([type=checkbox]), textarea, select').forEach((n) => n.remove());
  frag.querySelectorAll('span.tex[data-tex]').forEach((n) => {
    if (!settings.math) {
      const display = n.dataset.display === '1';
      const code = el('code', 'tex-src', display ? `$$\n${n.dataset.tex}\n$$` : `$${n.dataset.tex}$`);
      if (display) { const pre = el('pre', 'tex-src'); pre.appendChild(code); n.replaceWith(pre); } else n.replaceWith(code);
      return;
    }
    try { katex.render(n.dataset.tex, n, { displayMode: n.dataset.display === '1', throwOnError: false }); }
    catch (e) { n.textContent = n.dataset.tex; }
  });
  obsidian(frag, depth);
  if (!settings.taskToggles) frag.querySelectorAll('input[type=checkbox]').forEach((n) => { n.disabled = true; });
  if (settings.remoteImages !== true && current.remoteImagesOnce !== true) blockRemoteImages(frag);
  const head = fm && frontMatterNode(fm);
  if (head) frag.prepend(head);
  return frag;
}

// Swift's content rule list is what blocks remote images; this shows where they are and offers the one-shot load. The load
// button is made here and remembered, so a document's own <button>, whatever it looks like, can never ask for the load.
const REMOTE = /^\s*(https?:)?\/\//i;
const loadButtons = new WeakSet();
function blockRemoteImages(frag) {
  const remote = (v) => REMOTE.test(v || '') || /(^|,)\s*(https?:)?\/\//i.test(v || '');
  frag.querySelectorAll('source[srcset]').forEach((n) => { if (remote(n.getAttribute('srcset'))) n.remove(); });
  frag.querySelectorAll('image, feImage').forEach((n) => { if (remote(n.getAttribute('href') || n.getAttribute('xlink:href'))) n.remove(); });
  frag.querySelectorAll('[background], [poster]').forEach((n) => { n.removeAttribute('background'); n.removeAttribute('poster'); });
  frag.querySelectorAll('img').forEach((n) => {
    if (!remote(n.getAttribute('src')) && !remote(n.getAttribute('srcset'))) return;
    const box = el('span', 'img-blocked');
    box.append(el('span', 'img-alt', n.getAttribute('alt') || 'Remote image'));
    const b = el('button', 'img-load', 'Load images from the web');
    b.type = 'button';
    b.title = 'Loads this document\u2019s remote images once, for this preview. Their servers can see that it was opened.';
    loadButtons.add(b);
    b.addEventListener('pointerdown', (e) => { armed = e.isTrusted ? b : null; });
    b.addEventListener('click', loadRemoteImages);
    box.append(b);
    n.replaceWith(box);
  });
}

/** Only a real click on one of the page's own load buttons: never a script-made event, never a button from the document, and
 *  never a click forwarded from elsewhere (a label's activation is trusted too), so the pointer must have gone down on it. */
let armed = null;
function loadRemoteImages(e) {
  e.preventDefault();
  e.stopPropagation();
  const b = e.currentTarget, pressed = armed === b;
  armed = null;
  if (!e.isTrusted || !pressed || !loadButtons.has(b) || !current.path) return;
  post({ type: 'loadRemoteImages', path: current.path });
}

/** Mermaid's strict mode disables click directives but keeps markup in labels; links and positioning there are the document's. */
function tameMermaid(nodes, blocked = mermaidBlocked()) {
  for (const n of nodes) {
    if (blocked) n.querySelectorAll('img, image, feImage').forEach((i) => { if (/^\s*(https?:)?\/\//i.test(i.getAttribute('src') || i.getAttribute('href') || i.getAttribute('xlink:href') || '')) i.remove(); });
    n.querySelectorAll('a').forEach((a) => a.replaceWith(...a.childNodes));
    n.querySelectorAll('foreignObject [style]').forEach((e) => { if (/position|z-index|inset/i.test(e.getAttribute('style'))) e.removeAttribute('style'); });
  }
}

/** The theme's colours as #rrggbb: mermaid derives shades from its variables, so it needs concrete colours, not var() or
 *  system colour keywords. A translucent colour is flattened onto the background. */
function themeColors() {
  const probe = document.body.appendChild(el('span'));
  probe.hidden = true;
  const read = (v) => {
    probe.style.color = `var(${v})`;
    const s = getComputedStyle(probe).color;
    const n = (s.match(/[\d.]+%?/g) || []).map((x) => (x.endsWith('%') ? parseFloat(x) / 100 : parseFloat(x)));
    const srgb = s.startsWith('color(');
    const rgb = n.slice(0, 3).map((x) => (srgb ? x * 255 : x));
    return { rgb: rgb.length === 3 ? rgb : [128, 128, 128], a: n.length > 3 ? n[3] : 1 };
  };
  const bg = read('--bg').rgb;
  const flat = (v) => { const c = read(v); return c.rgb.map((x, i) => x * c.a + bg[i] * (1 - c.a)); };
  const out = { bg, fg: flat('--fg'), muted: flat('--muted'), border: flat('--border'), codeBg: flat('--code-bg'), accent: flat('--accent'),
    edge: flat('--diagram-edge'), line: flat('--diagram-line') };
  out.font = getComputedStyle(document.body).fontFamily;
  probe.remove();
  return out;
}

const hex = (c) => '#' + c.map((x) => Math.round(Math.max(0, Math.min(255, x))).toString(16).padStart(2, '0')).join('');
const mixc = (a, b, t) => a.map((x, i) => x * (1 - t) + b[i] * t);

function mermaidConfig() {
  const c = themeColors();
  const dark = (0.2126 * c.bg[0] + 0.7152 * c.bg[1] + 0.0722 * c.bg[2]) / 255 < 0.45;
  const node = hex(mixc(c.bg, c.accent, dark ? 0.2 : 0.1));
  return {
    startOnLoad: false, securityLevel: 'strict', htmlLabels: false, flowchart: { htmlLabels: false }, theme: 'base',
    themeVariables: {
      darkMode: dark, background: hex(c.bg), fontFamily: c.font, fontSize: '14px', textColor: hex(c.fg),
      primaryColor: node, primaryTextColor: hex(c.fg), primaryBorderColor: hex(c.edge),
      secondaryColor: hex(c.codeBg), secondaryTextColor: hex(c.fg), secondaryBorderColor: hex(c.border),
      tertiaryColor: hex(mixc(c.bg, c.fg, 0.05)), tertiaryTextColor: hex(c.fg), tertiaryBorderColor: hex(c.border),
      mainBkg: node, nodeBorder: hex(c.edge), lineColor: hex(c.line), titleColor: hex(c.fg),
      clusterBkg: hex(c.codeBg), clusterBorder: hex(c.border), edgeLabelBackground: hex(c.bg),
      noteBkgColor: hex(c.codeBg), noteTextColor: hex(c.fg), noteBorderColor: hex(c.border),
    },
  };
}

let mermaidLoaded = null;
function loadMermaid() {
  if (!mermaidLoaded) {
    mermaidLoaded = new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'spacebar://bundle/vendor/mermaid.min.js';
      s.onload = () => resolve();
      s.onerror = (e) => { mermaidLoaded = null; reject(e); };
      document.head.appendChild(s);
    });
  }
  return mermaidLoaded;
}

// Mermaid lays a diagram out inside the element it draws into, so drawing in the document showed the source, then an empty
// block, then a half-laid-out SVG. Every diagram is drawn off screen (#mm-stage) and put in whole; until then it is a blank
// placeholder, as tall as the diagram last drawn in its place. Runs are queued: mermaid's configuration is global.
const mermaidSrc = new WeakMap();
// Finished SVGs ({ svg, id }) by configuration, width and source, so a redraw (an edit, a live reload) puts an unchanged
// diagram back at once.
const mermaidCache = new Map();
const MERMAID_CACHE_MAX = 48;
const MERMAID_MIN_H = 120;
let mermaidQueue = Promise.resolve();
let mermaidSeq = 0;

const mermaidBlocked = () => settings.remoteImages !== true && current.remoteImagesOnce !== true;
// Some diagrams (gantt) size themselves to the width they are drawn at: the stage takes the document column's.
function docWidth() {
  const d = $('doc'), cs = getComputedStyle(d);
  return Math.max(200, Math.round(d.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)));
}
const mermaidKey = (cfg, blocked, width) => `${JSON.stringify(cfg)}|${blocked ? 'b' : 'a'}|${width}`;
function cacheSVG(key, entry) {
  mermaidCache.delete(key);
  mermaidCache.set(key, entry);
  if (mermaidCache.size > MERMAID_CACHE_MAX) mermaidCache.delete(mermaidCache.keys().next().value);
}

/** Mermaid's SVG, parsed inert (a template loads nothing) and tamed before it can reach the page. */
function tamedSVG(svg, blocked) {
  const t = document.createElement('template');
  t.innerHTML = svg;
  tameMermaid([t.content], blocked);
  return t.innerHTML;
}

/** A cached SVG under a fresh id (its markers and scoped styles use it), so two copies never share ids. */
function reId(entry) {
  const id = `sbm${++mermaidSeq}x`;
  return entry.svg.split(entry.id).join(id);
}

function mermaidStage() {
  let s = document.getElementById('mm-stage');
  if (!s) {
    s = el('div');
    s.id = 'mm-stage';
    s.setAttribute('aria-hidden', 'true');
    document.body.append(s);
  }
  return s;
}

/** Takes each diagram's source out of a freshly rendered fragment, so it is never painted: a diagram drawn before in these
 *  colours goes back at once, any other becomes a placeholder `heights[i]` tall (the diagram that was in its place). */
function mountMermaid(frag, heights) {
  const nodes = [...frag.querySelectorAll('pre.mermaid')];
  if (!nodes.length) return;
  const key = mermaidKey(mermaidConfig(), mermaidBlocked(), docWidth());
  nodes.forEach((n, i) => {
    const src = n.textContent;
    mermaidSrc.set(n, src);
    const hit = mermaidCache.get(key + '\n' + src);
    if (hit) { n.innerHTML = reId(hit); return; }
    n.textContent = '';
    n.classList.add('mm-wait');
    n.style.setProperty('--mm-h', Math.max(MERMAID_MIN_H, Math.round(heights[i] || 0)) + 'px');
  });
}

/** Draws the diagrams still waiting, and with `redraw` every diagram again in the current colours. Nothing on screen changes
 *  until every SVG of the run is finished; then all of them go in at once. */
function runMermaid(redraw = true) {
  const job = mermaidQueue.then(async () => {
    const nodes = [...document.querySelectorAll('#doc pre.mermaid')].filter((n) => mermaidSrc.has(n));
    const todo = redraw ? nodes : nodes.filter((n) => n.classList.contains('mm-wait'));
    if (!todo.length || !settings.mermaid) return;
    const done = new Map();
    try {
      await loadMermaid();
      if (document.fonts) await document.fonts.ready;
      const cfg = mermaidConfig();
      // Taken once: a remote-image grant during the run must not leave an untamed SVG under the blocked key.
      const blocked = mermaidBlocked(), width = docWidth();
      const key = mermaidKey(cfg, blocked, width);
      mermaid.initialize(cfg);
      const stage = mermaidStage();
      stage.style.width = width + 'px';
      for (const n of todo) {
        const src = mermaidSrc.get(n);
        const hit = mermaidCache.get(key + '\n' + src);
        if (hit) { done.set(n, reId(hit)); continue; }
        try {
          const id = `sbm${++mermaidSeq}x`;
          const svg = tamedSVG((await mermaid.render(id, src, stage)).svg, blocked);
          if (blocked === mermaidBlocked()) cacheSVG(key + '\n' + src, { svg, id });
          done.set(n, svg);
        } catch (e) {
          post({ type: 'log', msg: 'mermaid: ' + (e && (e.message || JSON.stringify(e))) });
          done.set(n, null);
        }
      }
    } catch (e) {
      post({ type: 'log', msg: 'mermaid: ' + (e && (e.message || JSON.stringify(e))) });
      // Mermaid did not load or start: a diagram still waiting shows its source rather than stay blank.
      for (const n of todo) if (!done.has(n) && n.classList.contains('mm-wait')) done.set(n, null);
    } finally {
      mermaidStage().replaceChildren();
    }
    for (const [n, svg] of done) {
      if (!n.isConnected) continue;
      const fresh = n.classList.contains('mm-wait');
      n.classList.remove('mm-wait');
      n.style.removeProperty('--mm-h');
      if (svg === null) {
        // Not a diagram mermaid can draw: its source, marked as such, is the honest thing to show.
        n.classList.add('mm-error');
        n.textContent = mermaidSrc.get(n);
        continue;
      }
      n.classList.remove('mm-error');
      // Only a diagram's first appearance fades in; a redraw in new colours is a plain swap.
      n.classList.toggle('mm-in', fresh);
      n.innerHTML = svg;
    }
  });
  mermaidQueue = job.catch(() => {});
  return job;
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { runMermaid(); syncPdf(); });
theme.onchange = () => runMermaid(); // a user theme or custom.css finished loading

// While editing, current.text is the page's own view of the document with the edit buffer applied (the native side saves the
// same text, so pushes of it are skipped), and editing.start/lines is the edited block's range in it.
let current = { text: '', path: '' };
let editing = null; // { seq, start, lines, text, selStart, selLen, tag } from the click until the edit ends
let retired = null; // { seq, start, lines } of the edit a click just replaced; its late keys still arrive
let editSeq = 0;
let docVer = 0;
let stickyStatus = ''; // a warning that must stay up (unsaved text); passing messages fall back to it // native document version of the last edit message applied here; a click's line numbers are relative to it

const INLINE_TAGS = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6']);

function editorHTML() {
  const { text, selStart, selLen } = editing;
  const mid = selLen ? `<span class="sel">${esc(text.slice(selStart, selStart + selLen))}</span>` : '<span class="caret"></span>';
  return esc(text.slice(0, selStart)) + mid + esc(text.slice(selStart + selLen)) + '\u200B';
}

const editorEl = () => document.querySelector('#doc > .md-editing');

/** Replaces the rendered blocks of the edited source range with the raw-source editor. */
function spliceEditor(range) {
  const [s, e] = range;
  const el = document.createElement(INLINE_TAGS.has(editing.tag) ? editing.tag : 'DIV');
  el.className = 'md-editing';
  el.dataset.src = `${s},${e}`;
  el.innerHTML = editorHTML();
  const blocks = [...$('doc').children];
  const inside = blocks.filter((b) => b.dataset.src && +b.dataset.src.split(',')[0] >= s && +b.dataset.src.split(',')[0] < e);
  const after = blocks.find((b) => b.dataset.src && +b.dataset.src.split(',')[0] >= e);
  $('doc').insertBefore(el, inside[0] || after || null);
  inside.forEach((b) => b.remove());
}

/** A rendered block's line range in current.text: blocks below the editor shift by the lines typed since the last render. */
function blockRange(b) {
  let [s, e] = b.dataset.src.split(',').map(Number);
  const ed = editorEl();
  if (editing && ed && b !== ed) {
    const [es, ee] = ed.dataset.src.split(',').map(Number);
    if (s >= ee) { const d = editing.lines - (ee - es); s += d; e += d; }
  }
  return [s, e];
}

/** Every redraw makes new diagram nodes holding their source; each is drawn here, whatever redrew the document. */
let drawnMermaid = Promise.resolve();
function draw() {
  if (!isMarkdown(current)) { $('doc').replaceChildren(viewNode(current)); decorate(); syncPdf(); return; }
  const heights = [...document.querySelectorAll('#doc pre.mermaid')].map((n) => n.getBoundingClientRect().height);
  const frag = render(current.text);
  mountMermaid(frag, heights);
  $('doc').replaceChildren(frag);
  if (editing) spliceEditor([editing.start, editing.start + editing.lines]);
  decorate();
  syncPdf();
  if (settings.mermaid && document.querySelector('#doc pre.mermaid.mm-wait')) drawnMermaid = runMermaid(false);
}

/** Rendered text of a range, without KaTeX's hidden MathML copy of each formula. */
function visibleText(range) {
  const frag = range.cloneContents();
  frag.querySelectorAll('.katex-mathml').forEach((n) => n.remove());
  return frag.textContent.replace(/\u200B/g, '');
}

/** Maps a click inside rendered text to an offset in the block's markdown by matching rendered characters in source order. */
function sourceOffset(block, src, x, y) {
  const r = document.caretRangeFromPoint(x, y);
  if (!r || !block.contains(r.startContainer)) return src.length;
  const pre = document.createRange();
  pre.selectNodeContents(block);
  pre.setEnd(r.startContainer, r.startOffset);
  const rendered = visibleText(pre);
  // A fenced block renders only its content, which starts after the opening fence line.
  let i = /^\s{0,3}(```|~~~)/.test(src) && src.includes('\n') ? src.indexOf('\n') + 1 : 0;
  for (const ch of rendered) {
    // Whitespace between rendered elements (list items, table cells) has no counterpart in the source.
    if (/\s/.test(ch)) { if (/\s/.test(src[i] || '')) i++; continue; }
    const j = src.indexOf(ch, i);
    if (j < 0) break;
    i = j + ch.length;
  }
  // Before a character, skip markup up to it on the same line (a list marker, `# `, `**`) so typing lands inside the text.
  const post = document.createRange();
  post.selectNodeContents(block);
  post.setStart(r.startContainer, r.startOffset);
  const next = [...visibleText(post)][0];
  if (next && !/\s/.test(next)) {
    const j = src.indexOf(next, i);
    if (j >= 0 && !src.slice(i, j).includes('\n')) i = j;
  }
  return i;
}

/** Offset in the edit buffer under a point in the editor, which shows the buffer verbatim plus a caret marker. */
function editorOffset(el, x, y) {
  const r = document.caretRangeFromPoint(x, y);
  if (!r || !el.contains(r.startContainer)) return editing.text.length;
  const pre = document.createRange();
  pre.selectNodeContents(el);
  pre.setEnd(r.startContainer, r.startOffset);
  return Math.min(pre.toString().replace(/\u200B/g, '').length, editing.text.length);
}

const words = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: 'word' }) : null;

/** The word under offset `i` (or just before it, at a word's end); an empty range between words. */
function wordAt(text, i) {
  if (!words || !text) return [i, i];
  const seg = words.segment(text);
  let w = seg.containing(Math.min(i, text.length - 1));
  if ((!w || !w.isWordLike) && i > 0) w = seg.containing(i - 1);
  return w && w.isWordLike ? [w.index, w.index + w.segment.length] : [i, i];
}

function select(start, len) {
  Object.assign(editing, { selStart: start, selLen: len });
  const el = editorEl();
  if (el) el.innerHTML = editorHTML();
  post({ type: 'editSelect', seq: editing.seq, start, length: len });
}

/** Replaces lines [at, at+old) of current.text and shifts the edit ranges below them. */
function splice(at, old, next, ver) {
  const lines = current.text.split('\n');
  lines.splice(at, old, ...next);
  current.text = lines.join('\n');
  const d = next.length - old;
  for (const r of [editing, retired]) if (r && r.start >= at + old) r.start += d;
  docVer = ver;
}

const now = () => performance.timeOrigin + performance.now();
const afterPaint = (f) => requestAnimationFrame(() => setTimeout(f, 0));

/** Shows the editor with its caret at once; the native side is told in parallel and ends the edit if it cannot take the keyboard. */
function beginEdit(block, e, tClick) {
  let [start, end] = blockRange(block);
  const all = current.text.split('\n');
  // A list's source range can take in the blank line after it; the editor shows the block's own lines only.
  while (end - 1 > start && !all[end - 1].trim()) end--;
  const src = all.slice(start, end).join('\n');
  const caret = sourceOffset(block, src, e.clientX, e.clientY);
  const r = block.getBoundingClientRect();
  const hadEditor = !!editing;
  retired = editing && { seq: editing.seq, start: editing.start, lines: editing.lines };
  editing = { seq: ++editSeq, start, lines: end - start, text: src, selStart: caret, selLen: 0, tag: block.tagName };
  const tMapped = now();
  if (hadEditor) draw(); else spliceEditor([start, end]);
  post({ type: 'editBlock', path: current.path, seq: editing.seq, start, end, text: src, caret, tag: block.tagName,
         clickX: e.clientX - r.left, clickY: e.clientY - r.top, width: r.width, height: r.height, ver: docVer, tClick, tMapped });
  afterPaint(() => post({ type: 'caretPainted', t: now() }));
}

// ---------- table of contents and reading stats (outside #doc, rebuilt after every draw) ----------

let tocTargets = [];
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

/** Scrolls to the document's heading named `h` (a wikilink's #heading, or a TOC entry's), exactly or else by prefix. */
function scrollToHeading(h, smooth) {
  const want = String(h).trim().toLowerCase();
  if (!want) return;
  const hs = [...$('doc').querySelectorAll(':scope > :is(h1, h2, h3, h4, h5, h6)')];
  const t = hs.find((x) => headingText(x).toLowerCase() === want) || hs.find((x) => headingText(x).toLowerCase().startsWith(want));
  if (t) t.scrollIntoView({ behavior: smooth && !reducedMotion.matches ? 'smooth' : 'auto', block: 'start' });
}

function headingText(h) {
  const c = h.cloneNode(true);
  c.querySelectorAll('.katex-mathml').forEach((n) => n.remove());
  return c.textContent.trim();
}

function buildToc() {
  const nav = $('toc');
  const hs = [...$('doc').querySelectorAll(':scope > h1, :scope > h2, :scope > h3')].filter((h) => !h.classList.contains('md-editing'));
  const show = settings.toc === 'on' ? hs.length > 0 : settings.toc === 'auto' && hs.length >= 3;
  tocTargets = show ? hs : [];
  if (!show) { nav.hidden = true; nav.replaceChildren(); return; }
  const top = Math.min(...hs.map((h) => +h.tagName[1]));
  nav.replaceChildren(el('div', 'toc-title', 'Contents'), ...hs.map((h, i) => {
    const a = el('a', 'l' + (+h.tagName[1] - top + 1), headingText(h));
    a.href = '#';
    a.dataset.toc = i;
    a.title = a.textContent;
    return a;
  }));
  nav.hidden = false;
  requestAnimationFrame(spy);
}

/** Marks the section being read: the last heading above the top of the window. */
function spy() {
  if (!tocTargets.length) return;
  let cur = 0;
  tocTargets.forEach((h, i) => { if (h.isConnected && h.getBoundingClientRect().top < 96) cur = i; });
  $('toc').querySelectorAll('a').forEach((a, i) => a.classList.toggle('active', i === cur));
}
let spyQueued = false;
window.addEventListener('scroll', () => {
  if (spyQueued || !tocTargets.length) return;
  spyQueued = true;
  requestAnimationFrame(() => { spyQueued = false; spy(); });
}, { passive: true });

let statsTimer = 0;
function updateStats() {
  clearTimeout(statsTimer);
  if (!settings.stats) { $('stats').textContent = ''; return; }
  if (!isMarkdown(current)) {
    const code = TEXT_VIEWS.has(current.view) && $('doc').querySelector('.code-view pre.code');
    const n = code ? lineCount(code.textContent) : 0;
    $('stats').textContent = n ? `${n.toLocaleString()} ${n === 1 ? 'line' : 'lines'}` : '';
    return;
  }
  statsTimer = setTimeout(() => {
    const skip = '.katex-mathml, pre.mermaid, .frontmatter, .frontmatter-raw, svg, .wl-embed-body';
    const walk = document.createTreeWalker($('doc'), NodeFilter.SHOW_TEXT,
      { acceptNode: (n) => (n.parentElement && n.parentElement.closest(skip) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT) });
    let text = '';
    while (walk.nextNode()) text += walk.currentNode.data + ' ';
    const n = words ? [...words.segment(text)].filter((s) => s.isWordLike).length : (text.match(/\S+/g) || []).length;
    $('stats').textContent = n ? `${n.toLocaleString()} ${n === 1 ? 'word' : 'words'} · ${Math.max(1, Math.round(n / 230))} min read` : '';
  }, 30);
}

function decorate() {
  buildToc();
  updateStats();
}

// ---------- settings ----------

// Keys that change what is rendered (a redraw) and keys that only change colours or fonts (mermaid draws its own).
const RENDER_KEYS = ['frontMatter', 'toc', 'stats', 'math', 'mermaid', 'rawHTML', 'inlineEditing', 'taskToggles', 'remoteImages'];
const LOOK_KEYS = ['theme', 'codeTheme', 'appearance', 'bodyFont', 'userThemeURL', 'customCSSURL'];

window.sb = {
  async render(p) {
    const t0 = performance.now();
    const samePath = p.path === current.path;
    if (editing && samePath && (p.reason === 'edit' || p.reason === 'save' || p.reason === 'editEnd')) {
      requestAnimationFrame(() => post({ type: 'rendered', parseMs: 0, totalMs: performance.now() - t0, mermaid: 0, reason: p.reason, keyTime: p.keyTime }));
      return;
    }
    // The native side may not have started this edit yet; tell it the page dropped it so it never holds the keyboard for it.
    if (editing) post({ type: 'editCancel', seq: editing.seq });
    editing = null;
    retired = null;
    docVer = p.ver ?? docVer;
    const y = samePath ? window.scrollY : 0;
    current = p;
    // Each render may come with a new native PDF view (the extension closes it for anything else): place it afresh.
    pdfPosted = '';
    $('base').href = p.base;
    document.title = p.name;
    root.dataset.view = isMarkdown(p) ? 'markdown' : p.view;
    syncOpen(p);
    // The popover's text settings do nothing for a PDF, and it would open under the native view.
    $('aa').hidden = p.view === 'pdf';
    if (p.view === 'pdf') showPopover(false);
    showFolder(p);
    showCrumbs(p);
    draw();
    window.scrollTo(0, y);
    if (typeof p.anchor === 'string' && p.anchor) scrollToHeading(p.anchor, false);
    const t1 = performance.now();
    const nodes = document.querySelectorAll('#doc pre.mermaid');
    post({ type: 'painted', parseMs: t1 - t0, reason: p.reason || '' });
    // The sidebar's state is in place from document start; only changes after the first paint animate.
    if (!document.documentElement.classList.contains('sb-anim')) afterPaint(() => document.documentElement.classList.add('sb-anim'));
    if (nodes.length) await drawnMermaid;
    requestAnimationFrame(() => post({ type: 'rendered', parseMs: t1 - t0, totalMs: performance.now() - t0, mermaid: nodes.length, reason: p.reason || '', keyTime: p.keyTime }));
  },
  /** New settings (the full payload of PageSettings.payload). Applies them live: an inline edit in progress stays open. */
  applySettings(p) {
    if (!p || typeof p !== 'object') return;
    const prev = settings;
    settings = { ...DEFAULTS, ...p };
    theme.apply(settings);
    syncPopover();
    syncToggle();
    if (RENDER_KEYS.some((k) => prev[k] !== settings[k]) && current.path) {
      const y = window.scrollY;
      draw();
      window.scrollTo(0, y);
    } else if (LOOK_KEYS.some((k) => prev[k] !== settings[k])) {
      runMermaid();
    }
    syncPdf();
    post({ type: 'log', msg: `settings applied theme=${settings.theme}` });
  },
  /** The native side found the clicked block elsewhere in its copy of the document (the page trailed it). */
  editMoved(m) {
    if (!editing || editing.seq !== m.seq) return;
    current.text = m.doc;
    editing.start = m.start;
    docVer = m.ver;
    draw();
  },
  /** Applies every splice the native side applied, whatever session it belongs to, so line numbers stay in step with it. */
  editUpdate(u) {
    const next = u.text.split('\n');
    splice(u.at, u.old, next, u.ver);
    if (editing && editing.seq === u.seq) {
      Object.assign(editing, { lines: next.length, text: u.text, selStart: u.selStart, selLen: u.selLen });
      const el = editorEl();
      if (el) el.innerHTML = editorHTML();
      requestAnimationFrame(() => post({ type: 'editPainted', keyTime: u.keyTime }));
    } else {
      if (retired && retired.seq === u.seq) retired.lines = next.length;
      draw();
    }
  },
  /** Backspace at the start of the block: name the block above so the native side can join the two. */
  prevBlock(q) {
    const el = editorEl();
    let prev = editing && editing.seq === q.seq && el ? el.previousElementSibling : null;
    while (prev && !prev.dataset.src) prev = prev.previousElementSibling;
    const [start, end] = prev ? prev.dataset.src.split(',').map(Number) : [-1, -1];
    post({ type: 'mergePrev', seq: q.seq, start, end, tag: prev ? prev.tagName : '', curTag: editing ? editing.tag : '' });
  },
  /** Replaces lines [at, at+old) with `lines` (native dropped an emptied block), keeping the page's line numbers in step. */
  spliceLines(s) {
    splice(s.at, s.old, s.lines, s.ver);
    draw();
  },
  /** A merge (Backspace at a block start) or a split (Enter): `repl` is what replaced lines [at, at+old) when it differs from the edited text. */
  editReset(r) {
    if (!editing || editing.seq !== r.seq) {
      // A newer click already moved on; still take the change so line numbers match the native side.
      splice(r.at, r.old, r.repl || r.text.split('\n'), r.ver);
      if (retired && retired.seq === r.seq) retired = null;
      draw();
      return;
    }
    current.text = r.doc;
    docVer = r.ver;
    const lines = r.text.split('\n').length;
    Object.assign(editing, { start: r.start, lines, text: r.text, selStart: r.caret, selLen: 0, tag: r.tag });
    retired = null;
    draw();
  },
  editEnd(e) {
    if (!editing || (e && e.seq !== undefined && e.seq !== editing.seq)) return;
    editing = null;
    retired = null;
    draw();
  },
  /** One folder of the sidebar's tree: the root, or a folder expanded in it. */
  setFiles(f) { setFolder(f); },
  /** A wikilink to a heading of the document already on screen. */
  scrollToHeading(m) { if (m && typeof m.heading === 'string') scrollToHeading(m.heading, true); },
  /** The app the viewer's Open button would use, named once the writer has looked it up. */
  setOpener(o) {
    if (!o || o.path !== current.path || typeof o.app !== 'string') return;
    current.app = o.app;
    document.querySelectorAll('#doc .viewer-open[data-action=openFile], #edit[data-action=openFile]').forEach((b) => { b.textContent = `Open with ${o.app}`; });
  },
  /** A newer release than this one: a dot on the Aa button and a row at the top of its popover. `state` is available,
   *  elsewhere (this copy is not the one the installer replaces), started, inProgress (still running after a while), done, or
   *  failed (with the reason, and whether the install command or the Update button is offered again). */
  update(u) {
    if (!u || typeof u.version !== 'string' || !['available', 'elsewhere', 'started', 'inProgress', 'done', 'failed'].includes(u.state)) return;
    showUpdate(u);
  },
  installCopied(r) {
    const b = $('aa-copy');
    b.textContent = r && r.ok ? 'Copied' : 'Could not copy';
    setTimeout(() => { b.textContent = 'Copy Install Command'; }, 1600);
  },
  status(s, sticky) {
    if (sticky) stickyStatus = s;
    $('status').textContent = s;
    if (!sticky) setTimeout(() => { if ($('status').textContent === s) $('status').textContent = stickyStatus; }, 2500);
  },
};

// ---------- file views: everything that is not Markdown, built from text nodes (never the file's own markup) ----------

const TEXT_VIEWS = new Set(['code', 'text', 'json']);
const HIGHLIGHT_MAX = 512 * 1024;
const CSV_ROWS = 1000;
const CSV_COLS = 200;
// Bidirectional controls in a file name could make it read as another type; they are dropped wherever a name is shown.
const plainName = (s) => String(s).replace(/[\u202A-\u202E\u2066-\u2069]/g, '');
const isMarkdown = (p) => !p.view || p.view === 'markdown';
const lineCount = (t) => (t ? t.split('\n').length - (t.endsWith('\n') ? 1 : 0) : 0);

function fmtSize(n) {
  if (typeof n !== 'number' || !isFinite(n)) return '';
  if (n < 1000) return `${n} ${n === 1 ? 'byte' : 'bytes'}`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n, i = -1;
  do { v /= 1000; i++; } while (v >= 1000 && i < units.length - 1);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}
const fmtDate = (ms) => (typeof ms === 'number' && isFinite(ms) ? new Date(ms).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '');

// The sidebar's and the info card's icons: drawn here, one set for every theme (colours come from style.css).
const SVG = 'http://www.w3.org/2000/svg';
const DOC = 'M4 1.5h5.5L13 5v9.5H4z';
const FOLD = 'M9.5 1.5V5H13';
const ICONS = {
  folder: ['M1.5 13.5V3.5h4.3l1.5 1.8h7.2v8.2z', 'M1.5 6.5h13'],
  markdown: [DOC, FOLD, 'M5.8 12V8.6l1.3 1.6 1.3-1.6V12', 'M10.6 8.6V12M9.6 11l1 1 1-1'],
  image: ['M2 3.5h12v9H2z', 'M2.5 12l3.5-4 2.5 3 1.8-1.8L13.5 12', 'M10.5 5.6a1 1 0 1 0 0 2 1 1 0 1 0 0-2z'],
  pdf: [DOC, FOLD, 'M6 8h5M6 10h5M6 12h3'],
  code: [DOC, FOLD, 'M7.2 8.3 5.7 10l1.5 1.7M9.8 8.3l1.5 1.7-1.5 1.7'],
  data: [DOC, FOLD, 'M5.8 7.6h5.4v4.6H5.8zM5.8 9.9h5.4M8.5 7.6v4.6'],
  text: [DOC, FOLD, 'M6 7.5h5M6 9.5h5M6 11.5h3'],
  other: [DOC, FOLD],
};
function icon(kind, size = 16) {
  const k = ICONS[kind] ? kind : 'other';
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('class', `ic ic-${k}`);
  ICONS[k].forEach((d, i) => {
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', d);
    if (i === 0) path.setAttribute('class', 'ic-body');
    svg.appendChild(path);
  });
  return svg;
}

/** The viewer's button: "Open with <app>" when the link policy allows the file, else Reveal in Finder (apps, scripts,
 *  executables, and anything the writer would refuse to open). */
function openButton(p) {
  const b = el('button', 'viewer-open');
  b.type = 'button';
  b.dataset.action = p.canOpen === true ? 'openFile' : 'reveal';
  b.textContent = p.canOpen === true ? (p.app ? `Open with ${p.app}` : 'Open') : 'Reveal in Finder';
  return b;
}

/** Open and Reveal only for a real click: the page's own buttons, never a script-made event. */
function viewerAction(b, e) {
  // A Markdown document can hold a look-alike button; the viewers exist only for other files.
  if (!current.path || isMarkdown(current)) return;
  const a = b.dataset.action;
  if ((a === 'openFile' || a === 'reveal') && e.isTrusted) post({ type: a, path: current.path });
  else if (a === 'raw') { jsonRaw = !jsonRaw; draw(); }
}

function viewHead(p, ...extra) {
  const head = el('div', 'viewer-head');
  head.append(el('span', 'viewer-kind', [p.kindName, fmtSize(p.size)].filter(Boolean).join(' · ')), ...extra, openButton(p));
  return head;
}

function note(text) { return el('div', 'viewer-note', text); }

function truncNote(p) { return p.truncated ? note(`Showing the first 2 MB of ${fmtSize(p.size)}.`) : null; }

/** Source with line numbers; highlighted by the bundled highlight.js when the language is known and the text is not huge. */
function codeBlock(text, lang) {
  const wrap = el('div', 'code-view');
  const n = Math.max(1, lineCount(text));
  wrap.append(el('pre', 'gutter', Array.from({ length: n }, (_, i) => i + 1).join('\n')));
  const pre = el('pre', 'code');
  const code = el('code', 'hljs');
  if (lang && window.hljs && hljs.getLanguage(lang) && text.length <= HIGHLIGHT_MAX) {
    const html = hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
    code.append(DOMPurify.sanitize(html, { ALLOWED_TAGS: ['span'], ALLOWED_ATTR: ['class'], RETURN_DOM_FRAGMENT: true }));
  } else code.textContent = text;
  pre.append(code);
  wrap.append(pre);
  return wrap;
}

let jsonRaw = false;
function jsonView(p) {
  let pretty = null;
  if (!p.truncated) { try { pretty = JSON.stringify(JSON.parse(p.text), null, 2); } catch (e) { pretty = null; } }
  const box = el('div', 'viewer viewer-code');
  const toggle = pretty !== null ? el('button', 'viewer-toggle', jsonRaw ? 'Formatted' : 'Raw') : null;
  if (toggle) { toggle.type = 'button'; toggle.dataset.action = 'raw'; toggle.setAttribute('aria-pressed', String(jsonRaw)); }
  box.append(viewHead(p, ...(toggle ? [toggle] : [])));
  const t = truncNote(p);
  if (t) box.append(t);
  if (pretty === null && !p.truncated) box.append(note('Not valid JSON: shown as is.'));
  box.append(codeBlock(pretty !== null && !jsonRaw ? pretty : p.text, 'json'));
  return box;
}

/** CSV (RFC 4180 quoting) or TSV; the first row is the header. Rows past the cap are counted, not kept. */
function parseDelimited(text, sep, max) {
  const rows = [];
  let row = [], field = '', q = false, total = 0;
  const endRow = () => { row.push(field); field = ''; if (total < max + 1) rows.push(row); total++; row = []; };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += c;
    } else if (c === '"' && field === '') q = true;
    else if (c === sep) { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; endRow(); }
    else field += c;
  }
  if (field !== '' || row.length) endRow();
  return { rows, total };
}

function csvView(p) {
  const box = el('div', 'viewer viewer-csv');
  box.append(viewHead(p));
  const t = truncNote(p);
  if (t) box.append(t);
  const { rows, total } = parseDelimited(p.text, p.tsv === true ? '\t' : ',', CSV_ROWS);
  const body = rows.slice(1, CSV_ROWS + 1);
  if (total - 1 > CSV_ROWS) box.append(note(`Showing the first ${CSV_ROWS.toLocaleString()} of ${(total - 1).toLocaleString()} rows.`));
  const table = el('table', 'csv');
  if (rows.length) {
    const tr = table.appendChild(el('thead')).appendChild(el('tr'));
    rows[0].slice(0, CSV_COLS).forEach((h) => tr.appendChild(el('th', '', h)));
  }
  const tb = table.appendChild(el('tbody'));
  const wide = rows.some((r) => r.length > CSV_COLS);
  if (wide) box.append(note(`Showing the first ${CSV_COLS} columns.`));
  for (const r of body) { const tr = tb.appendChild(el('tr')); r.slice(0, CSV_COLS).forEach((c) => tr.appendChild(el('td', '', c))); }
  box.append(table);
  return box;
}

function infoCard(p, why) {
  const card = el('div', 'viewer info-card');
  card.append(icon(p.icon, 64), el('div', 'info-name', plainName(p.name)), el('div', 'info-kind', p.kindName || 'Document'));
  const dl = el('dl');
  const rel = typeof p.root === 'string' && p.path.startsWith(p.root + '/') ? p.path.slice(p.root.length + 1) : p.path;
  for (const [k, v] of [['Size', typeof p.size === 'number' ? `${fmtSize(p.size)}${p.size >= 1000 ? ` (${p.size.toLocaleString()} bytes)` : ''}` : ''],
    ['Modified', fmtDate(p.modified)], ['Where', rel]]) {
    if (v) dl.append(el('dt', '', k), el('dd', '', v));
  }
  card.append(dl);
  if (why) card.append(note(why));
  card.append(openButton(p));
  return card;
}

/** The file is still being read (an iCloud download, or a slow disk): a quiet placeholder until the extension sends it. */
function loadingView(p) {
  const box = el('div', 'viewer viewer-loading');
  box.setAttribute('role', 'status');
  const spin = el('span', 'spinner');
  spin.setAttribute('aria-hidden', 'true');
  box.append(spin, el('div', 'loading-text', 'Loading…'));
  if (p.cloud === true) box.append(note('Downloading from iCloud'));
  return box;
}

function imageView(p) {
  const box = el('figure', 'viewer viewer-image');
  const img = document.createElement('img');
  const cap = el('figcaption', 'viewer-kind', [p.kindName, fmtSize(p.size)].filter(Boolean).join(' · '));
  img.alt = p.name;
  img.addEventListener('load', () => { cap.textContent = [p.kindName, `${img.naturalWidth} × ${img.naturalHeight}`, fmtSize(p.size)].filter(Boolean).join(' · '); });
  img.addEventListener('error', () => { if (box.isConnected) box.replaceWith(infoCard(p, 'This image can’t be shown here.')); });
  img.src = p.src;
  const head = el('div', 'viewer-head');
  head.append(cap, openButton(p));
  box.append(head, img);
  return box;
}

/** The PDF itself is drawn by a native PDFView the extension lays over `.pdf-area`; the page only reserves the space and
 *  reports where it is (syncPdf), so WebKit's PDF plugin, and its unlabelled buttons, never load. */
function pdfView(p) {
  const box = el('div', 'viewer viewer-pdf');
  box.append(viewHead(p));
  const area = el('div', 'pdf-area');
  area.setAttribute('role', 'document');
  area.setAttribute('aria-label', plainName(p.name));
  box.append(area);
  pdfObserver.disconnect();
  pdfObserver.observe(area);
  // Shown over a narrow page, the sidebar animates its width without moving the area.
  pdfObserver.observe($('sidebar'));
  return box;
}

// Where the native PDF view goes, in CSS pixels of the viewport, posted whenever it moves or changes size (the sidebar's
// animation, a drag of its edge, the panel resizing, the popover opening) and once with `hide` when no PDF is on screen.
let pdfPosted = '';
let pdfQueued = false;
function pdfRect() {
  const area = document.querySelector('#doc .pdf-area');
  if (!area || current.view !== 'pdf') return { path: current.path, hide: true };
  const r = area.getBoundingClientRect();
  // The sidebar shown over the page in a narrow panel, and the Aa popover, sit above the page; the native view must not.
  let left = r.left;
  const side = $('sidebar');
  if (root.classList.contains('sb-peek') && !side.hidden) left = Math.max(left, side.getBoundingClientRect().right);
  const bottom = Math.min(r.bottom, window.innerHeight);
  const c = themeColors();
  const bg = mixc(c.bg, c.fg, 0.06).map(Math.round);
  return { path: current.path, x: Math.round(left), y: Math.round(r.top), w: Math.max(0, Math.round(r.right - left)), h: Math.max(0, Math.round(bottom - r.top)),
    hide: !pop.hidden, bg, dark: (0.2126 * c.bg[0] + 0.7152 * c.bg[1] + 0.0722 * c.bg[2]) / 255 < 0.45, radius: appChrome() ? 8 : 0 };
}
const pdfObserver = new ResizeObserver(() => syncPdf());
window.addEventListener('resize', () => syncPdf());
window.addEventListener('scroll', () => syncPdf(), { passive: true });
function syncPdf() {
  if (pdfQueued) return;
  pdfQueued = true;
  requestAnimationFrame(() => {
    pdfQueued = false;
    const r = pdfRect();
    const key = JSON.stringify(r);
    if (key === pdfPosted) return;
    // Nothing to take down when no PDF was ever up.
    if (r.hide && !pdfPosted) return;
    pdfPosted = r.hide && !('x' in r) ? '' : key;
    post({ type: 'pdfRect', ...r });
  });
}

function viewNode(p) {
  switch (p.view) {
    case 'image': if (typeof p.src === 'string') return imageView(p); break;
    case 'pdf': return pdfView(p);
    case 'loading': return loadingView(p);
    case 'overview': return overviewView(p);
    case 'json': if (typeof p.text === 'string') return jsonView(p); break;
    case 'csv': if (typeof p.text === 'string') return csvView(p); break;
    case 'code': case 'text':
      if (typeof p.text === 'string') {
        const box = el('div', 'viewer viewer-code');
        box.append(viewHead(p));
        const t = truncNote(p);
        if (t) box.append(t);
        if (p.view === 'code' && p.lang && p.text.length > HIGHLIGHT_MAX) box.append(note('Highlighting is off for files over 512 KB.'));
        box.append(codeBlock(p.text, p.view === 'code' ? p.lang : null));
        return box;
      }
      break;
    default: break;
  }
  return infoCard(p, typeof p.note === 'string' ? p.note : undefined);
}

// ---------- the folder overview: what a folder holds, when it has no Markdown to open (text nodes only) ----------

const OVERVIEW_KINDS = [['markdown', 'Markdown file', 'Markdown files', 'markdown'], ['image', 'image', 'images', 'image'], ['pdf', 'PDF', 'PDFs', 'pdf'],
  ['code', 'code file', 'code files', 'code'], ['data', 'data file', 'data files', 'data'], ['text', 'text file', 'text files', 'text'],
  ['other', 'other item', 'other items', 'other']];

function shortDate(ms) {
  if (typeof ms !== 'number' || !isFinite(ms)) return '';
  const d = new Date(ms), now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  if (now - d < 6 * 864e5 && now > d) return d.toLocaleDateString(undefined, { weekday: 'short' });
  return d.toLocaleDateString(undefined, d.getFullYear() === now.getFullYear() ? { day: 'numeric', month: 'short' } : { day: 'numeric', month: 'short', year: 'numeric' });
}

function overviewView(p) {
  const box = el('div', 'viewer overview');
  const counts = p.counts && typeof p.counts === 'object' ? p.counts : {};
  const total = Math.max(0, +p.total || 0), folders = Math.max(0, +p.folders || 0);
  const loading = p.reason === 'loading';
  const head = el('div', 'ov-head');
  const title = el('div', 'ov-title');
  const sub = loading ? 'Reading this folder…'
    : [typeof p.label === 'string' ? p.label : 'Folder', total ? `${total.toLocaleString()}${p.complete === false ? '+' : ''} ${total === 1 ? 'item' : 'items'}` : 'Empty'].join(' · ');
  title.append(el('div', 'ov-name', plainName(p.name || '')), el('div', 'ov-sub', sub));
  head.append(icon('folder', 40), title);
  box.append(head);
  if (loading) return box;
  const chips = el('div', 'ov-counts');
  const chip = (ic, n, one, many) => {
    const c = el('span', 'ov-chip');
    c.append(icon(ic, 14), el('b', '', n.toLocaleString()), document.createTextNode(' ' + (n === 1 ? one : many)));
    chips.append(c);
  };
  if (folders) chip('folder', folders, 'folder', 'folders');
  for (const [k, one, many, ic] of OVERVIEW_KINDS) { const n = Math.max(0, +counts[k] || 0); if (n) chip(ic, n, one, many); }
  if (chips.childNodes.length) box.append(chips);
  const recent = Array.isArray(p.recent) ? p.recent.filter((r) => r && typeof r.path === 'string' && typeof r.name === 'string') : [];
  if (recent.length) {
    box.append(el('div', 'ov-section', 'Recently modified'));
    const list = el('div', 'ov-list');
    for (const r of recent) {
      const a = el('a', 'ov-row');
      a.href = '#';
      a.dataset.path = r.path;
      a.title = typeof r.rel === 'string' ? r.rel : r.name;
      const where = typeof r.rel === 'string' && r.rel.includes('/') ? r.rel.slice(0, r.rel.lastIndexOf('/')) : '';
      a.append(icon(typeof r.icon === 'string' ? r.icon : 'other', 16), el('span', 'ov-row-name', plainName(r.name)),
        el('span', 'ov-row-where', plainName(where)), el('span', 'ov-row-date', shortDate(r.modified)));
      list.append(a);
    }
    box.append(list);
  } else if (!total) {
    box.append(el('div', 'ov-empty', 'Nothing here yet.'));
  }
  if (p.complete === false) box.append(note(`A large folder: counted what could be read quickly, ${+p.depth || 3} folders deep.`));
  return box;
}

/** The toolbar's Open button: the editor for Markdown, else what the viewer offers (Open with, or Reveal in Finder). */
function syncOpen(p) {
  const b = $('edit');
  const doc = isMarkdown(p);
  b.hidden = !doc && (p.view === 'overview' || p.view === 'loading' || !p.path);
  b.dataset.kind = doc ? 'doc' : 'file';
  if (doc) { b.dataset.action = 'edit'; b.textContent = 'Open in editor'; b.title = 'Open this file in your editor'; return; }
  b.dataset.action = p.canOpen === true ? 'openFile' : 'reveal';
  b.textContent = p.canOpen === true ? (p.app ? `Open with ${p.app}` : 'Open') : 'Reveal in Finder';
  b.title = p.canOpen === true ? 'Open this file in its default app' : 'Show this file in Finder';
}

// ---------- the sidebar: the previewed folder as a tree, for a file and a folder alike (outside #doc, text only) ----------

const root = document.documentElement;
const narrow = matchMedia('(max-width: 639px)');
const tiny = matchMedia('(max-width: 479px)');
/** The toolbar row and outlined page are on: not Minimal chrome, and the panel is not too narrow for them. */
const appChrome = () => root.dataset.chrome !== 'minimal' && !tiny.matches;
// The tree of the root on screen: each listed folder by path. Expanded folders are remembered per root for this session
// (the page lives as long as the extension process), never saved.
let tree = { root: '', name: '', session: 0, dirs: new Map() };
const expandedByRoot = new Map();
const requested = new Set();
let sideDrawn = '';
let treeVersion = 0;

function expanded() {
  if (!tree.root) return new Set();
  let s = expandedByRoot.get(tree.root);
  if (!s) {
    s = new Set();
    expandedByRoot.set(tree.root, s);
    if (expandedByRoot.size > 64) expandedByRoot.delete(expandedByRoot.keys().next().value);
  }
  return s;
}

function resetTree(rootPath, name) {
  tree = { root: rootPath, name: name || rootPath.split('/').pop() || rootPath, session: 0, dirs: new Map() };
  requested.clear();
  treeVersion++;
}

const inTree = (p) => typeof p === 'string' && p.startsWith(tree.root === '/' ? '/' : tree.root + '/');
const parentOf = (p) => p.slice(0, p.lastIndexOf('/')) || '/';

function setFolder(f) {
  if (!f || typeof f.root !== 'string' || !f.root || typeof f.dir !== 'string') return;
  if (f.root !== tree.root) resetTree(f.root, f.rootName);
  if (f.dir !== tree.root && !inTree(f.dir)) return;
  // A new preview of the same root: what the page holds is kept on screen but asked for again, so the new preview watches it.
  if (f.session !== tree.session) {
    tree.session = f.session;
    requested.clear();
    for (const d of tree.dirs.values()) d.stale = true;
  }
  const entries = Array.isArray(f.entries) ? f.entries.filter((e) => e && typeof e.name === 'string' && typeof e.path === 'string' && parentOf(e.path) === f.dir) : [];
  tree.dirs.set(f.dir, { entries: entries.map((e) => ({ name: e.name, path: e.path, dir: e.dir === true, icon: typeof e.icon === 'string' ? e.icon : 'other' })),
    more: Math.max(0, +f.more || 0), stale: false });
  requested.delete(f.dir);
  treeVersion++;
  requestFolders();
  renderSidebar();
}

/** Asks for every expanded folder whose parent is listed and names it, so each request is for a folder Swift has seen. */
function requestFolders() {
  for (const p of expanded()) {
    const d = tree.dirs.get(p);
    if ((d && !d.stale) || requested.has(p) || !inTree(p)) continue;
    const parent = tree.dirs.get(parentOf(p));
    if (!parent || parent.stale || !parent.entries.some((e) => e.dir && e.path === p)) continue;
    requested.add(p);
    post({ type: 'list', path: p });
  }
}

function toggleFolder(p) {
  const s = expanded();
  if (s.has(p)) { s.delete(p); post({ type: 'unlist', path: p }); } else s.add(p);
  treeVersion++;
  requestFolders();
  renderSidebar();
}

/** A render names its root; the tree stays when the root is the same, and the current file's folders open. */
function showFolder(p) {
  const r = typeof p.root === 'string' && p.root ? p.root : typeof p.dir === 'string' ? p.dir : '';
  if (!r) { if (tree.root) resetTree('', ''); tree.root = ''; }
  else if (r !== tree.root) resetTree(r, p.rootName || p.dirName);
  if (tree.root && inTree(p.path)) {
    const s = expanded();
    for (let d = parentOf(p.path); d !== tree.root && inTree(d); d = parentOf(d)) s.add(d);
    requestFolders();
  }
  renderSidebar();
}

function treeRow(e, depth) {
  const a = el('a', `row ${e.dir ? 'folder' : 'file'}`);
  a.href = '#';
  a.title = e.name;
  a.dataset.path = e.path;
  a.style.setProperty('--depth', depth);
  a.setAttribute('role', 'treeitem');
  a.setAttribute('aria-level', depth + 1);
  const tw = el('span', 'twisty');
  if (e.dir) {
    a.dataset.dir = '1';
    const open = expanded().has(e.path);
    a.setAttribute('aria-expanded', String(open));
    if (open) a.classList.add('open');
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 10 10');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', 'M3.5 2 7 5 3.5 8z');
    svg.appendChild(path);
    tw.appendChild(svg);
  }
  a.append(tw, icon(e.dir ? 'folder' : e.icon), el('span', 'nm', plainName(e.name)));
  if (!e.dir && e.path === current.path) { a.classList.add('active'); a.setAttribute('aria-current', 'page'); }
  return a;
}

function renderSidebar() {
  const on = !!tree.root;
  $('sidebar').hidden = !on;
  $('side-toggle').hidden = !on;
  syncToggle();
  const key = `${treeVersion}\n${current.path}`;
  if (!on || key === sideDrawn) return;
  const moved = sideDrawn.split('\n')[1] !== current.path;
  sideDrawn = key;
  $('side-head').textContent = tree.name;
  $('side-head').title = `${tree.root}\nClick for an overview of this folder`;
  const list = $('side-list');
  const rows = [];
  const exp = expanded();
  const walk = (dir, depth) => {
    const d = tree.dirs.get(dir);
    if (!d) {
      if (depth) { const n = el('div', 'row-note', 'Loading…'); n.style.setProperty('--depth', depth); rows.push(n); }
      return;
    }
    for (const e of d.entries) {
      rows.push(treeRow(e, depth));
      if (e.dir && exp.has(e.path) && depth < 64) walk(e.path, depth + 1);
    }
    if (d.more && depth) { const n = el('div', 'row-note', `${d.more.toLocaleString()} more not listed`); n.style.setProperty('--depth', depth); rows.push(n); }
  };
  walk(tree.root, 0);
  list.replaceChildren(...rows);
  const top = tree.dirs.get(tree.root);
  $('side-more').hidden = !(top && top.more);
  $('side-more').textContent = top && top.more ? `${top.more.toLocaleString()} more not listed` : '';
  // Keep the document on screen in view; the list scrolls on its own, never the page.
  const at = list.querySelector('a.active');
  if (at && moved) at.classList.add('arrive');
  if (at && (moved || at.offsetTop < list.scrollTop || at.offsetTop + at.offsetHeight > list.scrollTop + list.clientHeight)) {
    list.scrollTop = Math.max(0, at.offsetTop - list.clientHeight / 3);
  }
}

/** The file on screen, as a path from the root: the panel's title stays the file Quick Look opened. */
function showCrumbs(p) {
  const c = $('crumbs');
  const r = typeof p.root === 'string' ? p.root : '';
  const atRoot = !!r && p.path === r;
  if (!r || typeof p.path !== 'string' || (!atRoot && !p.path.startsWith(r === '/' ? '/' : r + '/'))) { c.hidden = true; c.replaceChildren(); return; }
  const parts = [p.rootName || r.split('/').pop() || r, ...(atRoot ? [] : p.path.slice(r.length + (r === '/' ? 0 : 1)).split('/'))];
  c.replaceChildren(...parts.flatMap((name, i) => {
    const s = el('span', i === parts.length - 1 ? 'crumb here' : 'crumb', plainName(name));
    return i ? [el('span', 'crumb-sep', '›'), s] : [s];
  }));
  c.title = p.path;
  c.hidden = false;
}

// The breadcrumb in the toolbar row ends where the toolbar's buttons begin.
new ResizeObserver(() => root.style.setProperty('--tb-w', Math.ceil($('toolbar').getBoundingClientRect().width) + 'px')).observe($('toolbar'));

/** Open or collapsed as the setting says; below the narrow width it is always collapsed and the button shows it over the page. */
function sidebarShown() { return narrow.matches ? root.classList.contains('sb-peek') : settings.sidebarCollapsed !== true; }

function syncToggle() {
  const open = sidebarShown(), t = $('side-toggle');
  t.setAttribute('aria-expanded', String(open));
  t.title = open ? 'Hide sidebar' : 'Show sidebar';
}

function peek(open) {
  root.classList.toggle('sb-peek', open);
  syncToggle();
  syncPdf();
}

$('side-toggle').addEventListener('click', () => {
  if (narrow.matches) return peek(!root.classList.contains('sb-peek'));
  choose('sidebarCollapsed', settings.sidebarCollapsed !== true);
});
narrow.addEventListener('change', () => peek(false));
// While the sidebar shows over a narrow page, a click anywhere else only closes it.
document.addEventListener('click', (e) => {
  if (!root.classList.contains('sb-peek') || e.target.closest('#sidebar, #side-toggle')) return;
  peek(false);
  e.preventDefault();
  e.stopPropagation();
}, true);

// The resize handle: the width follows the pointer and is saved once, when the drag ends. It never collapses the sidebar.
const SIDE_MIN = 160, SIDE_MAX = 480, SIDE_DEFAULT = 240;
const sideLimit = () => Math.max(SIDE_MIN, Math.min(SIDE_MAX, Math.floor(window.innerWidth * 0.45)));
const clampSide = (w) => Math.round(Math.max(SIDE_MIN, Math.min(sideLimit(), w)));
let resizing = null;
const handle = $('side-resize');
handle.addEventListener('pointerdown', (e) => {
  if (e.button !== 0 || narrow.matches) return;
  e.preventDefault();
  try { handle.setPointerCapture(e.pointerId); } catch (err) { /* a pointer the page cannot capture still resizes while over the handle */ }
  resizing = { x: e.clientX, w: $('sidebar').getBoundingClientRect().width, now: null };
  root.classList.add('sb-resizing');
});
handle.addEventListener('pointermove', (e) => {
  if (!resizing) return;
  resizing.now = clampSide(resizing.w + e.clientX - resizing.x);
  root.style.setProperty('--side-saved', resizing.now + 'px');
});
function endResize() {
  if (!resizing) return;
  const w = resizing.now;
  resizing = null;
  root.classList.remove('sb-resizing');
  if (w !== null && w !== settings.sidebarWidth) choose('sidebarWidth', w);
  else root.style.setProperty('--side-saved', settings.sidebarWidth + 'px');
}
handle.addEventListener('pointerup', endResize);
handle.addEventListener('pointercancel', endResize);
handle.addEventListener('lostpointercapture', endResize);
handle.addEventListener('dblclick', (e) => { e.preventDefault(); choose('sidebarWidth', SIDE_DEFAULT); });

// ---------- the Aa popover (in #toolbar, outside #doc: nothing the document renders can reach these messages) ----------

const pop = $('aa-pop');
$('aa-themes').replaceChildren(...Object.entries(THEMES).map(([id, name]) => {
  const b = el('button', 'swatch');
  Object.assign(b, { type: 'button', title: name });
  b.setAttribute('aria-label', name);
  b.setAttribute('role', 'radio');
  Object.assign(b.dataset, { key: 'theme', value: id, t: id });
  b.append(el('span', 'swatch-dot', 'Aa'));
  return b;
}));

function syncPopover() {
  $('aa-size').textContent = `${settings.fontSize} pt`;
  $('aa-smaller').disabled = settings.fontSize <= 12;
  $('aa-larger').disabled = settings.fontSize >= 24;
  pop.querySelectorAll('[data-key]').forEach((b) => b.setAttribute('aria-checked', String(settings[b.dataset.key] === b.dataset.value)));
}

let updateTimer = 0;
function showUpdate(u) {
  const v = u.version, failed = u.state === 'failed', running = u.state === 'started' || u.state === 'inProgress';
  clearTimeout(updateTimer);
  const title = failed ? 'Update failed' : u.state === 'started' ? `Updating to spacebar ${v}…` : u.state === 'inProgress'
    ? `Still updating to spacebar ${v}…` : u.state === 'done' ? `spacebar ${v} is installed` : `spacebar ${v} is available`;
  $('aa-update-title').textContent = title;
  $('aa-update-sub').textContent = failed ? String(u.reason || 'The update did not start.')
    : u.state === 'elsewhere' ? `This copy is in ${u.place}, which the installer does not update. Replace it with the download on the release page.`
    : u.state === 'done' ? 'Close this preview and open it again to use it.'
    : 'Quick Look closes for a moment while it updates.';
  $('aa-install').hidden = !(u.state === 'available' || running || (failed && u.retry));
  $('aa-install').disabled = running;
  $('aa-install').textContent = running ? 'Updating…' : 'Update';
  $('aa-copy').hidden = !(failed && u.copy);
  $('aa-update').hidden = false;
  $('aa').dataset.update = '';
  $('aa').title = `Appearance · ${title}`;
  // A successful update quits this preview; one still here after a while asks whether the installer is still running.
  if (running) updateTimer = setTimeout(() => post({ type: 'updateCheck' }), u.state === 'started' ? 120000 : 60000);
}

function showPopover(open) {
  pop.hidden = !open;
  $('aa').setAttribute('aria-expanded', String(open));
  if (open) syncPopover();
  syncPdf();
}

/** A popover choice: applied here at once, and sent to the native side, which saves it (panel keys only) and echoes it back. */
function choose(key, value) {
  if (settings[key] === value) return;
  post({ type: 'setting', key, value });
  window.sb.applySettings({ ...settings, [key]: value });
}

$('aa').addEventListener('click', () => showPopover(pop.hidden));
pop.addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b || b.disabled) return;
  if (b.id === 'aa-settings') { showPopover(false); post({ type: 'openSettings', tab: 'appearance' }); return; }
  if (b.id === 'aa-install') {
    // The update quits Quick Look: the edit ends first, so its last keys are saved before the writer starts it.
    if (editing) stopEditing();
    b.disabled = true;
    post({ type: 'installUpdate' });
    return;
  }
  if (b.id === 'aa-copy') { post({ type: 'copyInstall' }); return; }
  if (b.id === 'aa-notes') { showPopover(false); post({ type: 'releaseNotes' }); return; }
  if (b.dataset.step) choose('fontSize', Math.min(24, Math.max(12, settings.fontSize + Number(b.dataset.step))));
  else if (b.dataset.key) choose(b.dataset.key, b.dataset.value);
});
// While the popover is open, a click anywhere else only closes it (it does not also start an edit or follow a link).
document.addEventListener('click', (e) => {
  if (pop.hidden || e.target.closest('#aa-pop, #aa')) return;
  showPopover(false);
  e.preventDefault();
  e.stopPropagation();
}, true);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !pop.hidden) showPopover(false); });
syncPopover();

// Clicks in the editor move the caret and double-clicks select a word; the page's own selection stays out of the editor.
document.addEventListener('mousedown', (e) => { if (editing && e.target.closest('#doc > .md-editing')) e.preventDefault(); });

document.addEventListener('dblclick', (e) => {
  const el = e.target.closest('#doc > .md-editing');
  if (!editing || !el) return;
  e.preventDefault();
  const [a, b] = wordAt(editing.text, editorOffset(el, e.clientX, e.clientY));
  select(a, b - a);
});

document.addEventListener('click', (e) => {
  const tClick = performance.timeOrigin + e.timeStamp;
  // The chrome around the document ends an edit like a click on the page's margin does; hiding or resizing the sidebar
  // only changes the layout, so the edit stays open.
  if (editing && e.target.closest('#sidebar, #crumbs, #toolbar, #toc') && !e.target.closest('#side-resize')) stopEditing();
  const toc = e.target.closest('#toc a');
  if (toc) {
    e.preventDefault();
    const h = tocTargets[+toc.dataset.toc];
    if (h && h.isConnected) h.scrollIntoView({ behavior: reducedMotion.matches ? 'auto' : 'smooth', block: 'start' });
    return;
  }
  if (e.target.closest('#side-head') && tree.root) { e.preventDefault(); peek(false); post({ type: 'overview' }); return; }
  const row = e.target.closest('#side-list a.row');
  if (row) {
    e.preventDefault();
    if (row.dataset.dir) { toggleFolder(row.dataset.path); return; }
    peek(false);
    if (row.dataset.path !== current.path) post({ type: 'open', path: row.dataset.path });
    return;
  }
  if (e.target.closest('#sidebar, #crumbs')) return;
  const act = e.target.closest('#doc .viewer [data-action]');
  if (act) { e.preventDefault(); viewerAction(act, e); return; }
  const ov = e.target.closest('#doc .overview a.ov-row');
  if (ov) { e.preventDefault(); if (ov.dataset.path !== current.path) post({ type: 'open', path: ov.dataset.path }); return; }
  const wl = e.target.closest('#doc a.wikilink');
  if (wl) { e.preventDefault(); followWiki(wl); return; }
  const a = e.target.closest('a[href], a[*|href]');
  const href = a && (a.getAttribute('href') ?? a.getAttributeNS('http://www.w3.org/1999/xlink', 'href'));
  if (a && href && !href.startsWith('#')) { e.preventDefault(); post({ type: 'link', href: new URL(href, document.baseURI).href }); return; }
  // An embedded note is another file: it is read here, never edited.
  if (e.target.closest('#doc .wl-embed')) return;
  const el = e.target.closest('#doc > .md-editing');
  if (editing && el) { if (e.detail < 2) select(editorOffset(el, e.clientX, e.clientY), 0); return; }
  if (a || e.target.closest('input, button, #toolbar') || getSelection().toString()) return;
  const block = e.target.closest('#doc > [data-src]');
  if (block && settings.inlineEditing) beginEdit(block, e, tClick);
  else if (editing) stopEditing();
});

/** A click outside every block ends the edit; native saves what the writer still holds and re-renders. */
function stopEditing() {
  const seq = editing.seq;
  editing = null;
  retired = null;
  draw();
  post({ type: 'editStop', seq });
}

document.addEventListener('change', (e) => {
  const box = e.target;
  if (!box.matches('input[type=checkbox][data-line]') || !settings.taskToggles) return;
  // Keep the page's copy in step: a push of the saved text is skipped while a block is being edited.
  let line = +box.dataset.line;
  const ed = editorEl();
  if (editing && ed) { const [es, ee] = ed.dataset.src.split(',').map(Number); if (line >= ee) line += editing.lines - (ee - es); }
  const lines = current.text.split('\n');
  const text = lines[line];
  if (lines[line] !== undefined) { lines[line] = lines[line].replace(/\[[ xX]\]/, box.checked ? '[x]' : '[ ]'); current.text = lines.join('\n'); }
  post({ type: 'toggle', path: current.path, line, text, checked: box.checked, ver: docVer });
});

/** A wikilink: the file the extension resolved it to, opened in the panel (at its heading), or a heading of this document. */
function followWiki(a) {
  const t = a.dataset.wl || '', h = a.dataset.wlH || '';
  const r = t ? wikiTarget(t) : null;
  if (!t || (r && r.path === current.path)) { if (h) scrollToHeading(h, true); return; }
  if (!r) {
    window.sb.status(current.linksReady === false ? 'Still indexing this folder…'
      : current.linksComplete === false ? `“${plainName(t)}” was not found in the part of this folder that was indexed`
      : `Nothing named “${plainName(t)}” in ${plainName(tree.name || 'this folder')}`);
    return;
  }
  peek(false);
  post(h ? { type: 'open', path: r.path, anchor: h } : { type: 'open', path: r.path });
}

// The toolbar's Open button; a file's Open or Reveal is posted only for a real click, and the extension checks it again.
$('edit').addEventListener('click', (e) => {
  if (isMarkdown(current)) { post({ type: 'edit', path: current.path }); return; }
  const a = $('edit').dataset.action;
  if ((a === 'openFile' || a === 'reveal') && e.isTrusted && current.path) post({ type: a, path: current.path });
});

post({ type: 'ready' });
