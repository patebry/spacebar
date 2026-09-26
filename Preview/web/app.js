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
  remoteImages: false, inlineEditing: true, taskToggles: true, customCSSURL: null, userThemeURL: null };
let settings = { ...DEFAULTS, ...(window.__sbInitial || {}) };
const THEMES = { apple: 'Apple', github: 'GitHub', paper: 'Paper', solarized: 'Solarized', nord: 'Nord', contrast: 'High Contrast' };
const theme = window.sbTheme && typeof window.sbTheme.apply === 'function' ? window.sbTheme : {
  apply(p) {
    const r = document.documentElement;
    Object.assign(r.dataset, { theme: p.theme, font: p.bodyFont, mono: p.monoFont, width: p.width, editing: p.inlineEditing ? 'on' : 'off' });
    r.style.setProperty('--font-size', p.fontSize + 'px');
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

  // Top-level blocks carry their source line range so a click can be mapped back to the markdown it came from.
  md.core.ruler.push('srcmap', (state) => {
    for (const t of state.tokens) if (t.level === 0 && t.nesting >= 0 && t.type !== 'inline' && t.map) t.attrSet('data-src', `${t.map[0]},${t.map[1]}`);
  });
  return md;
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

function render(text) {
  const fm = frontMatter(text);
  const md = settings.rawHTML === 'off' ? mdText : mdHTML;
  const frag = DOMPurify.sanitize(md.render(fm ? fm.body : text), PURIFY);
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
function tameMermaid(nodes) {
  const blocked = settings.remoteImages !== true && current.remoteImagesOnce !== true;
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
      s.onerror = reject;
      document.head.appendChild(s);
    });
  }
  return mermaidLoaded;
}

// Each diagram's source, kept so a theme change can draw it again. Runs are queued: mermaid's configuration is global.
const mermaidSrc = new WeakMap();
let mermaidQueue = Promise.resolve();
let mermaidSeq = 0;
/** Renders new diagrams, and with `redraw` draws already rendered ones again in the current theme's colours. */
function runMermaid(redraw = true) {
  const job = mermaidQueue.then(async () => {
    const nodes = [...document.querySelectorAll('#doc pre.mermaid')];
    if (!nodes.length || !settings.mermaid) return;
    const fresh = nodes.filter((n) => !mermaidSrc.has(n));
    if (!fresh.length && !redraw) return;
    fresh.forEach((n) => mermaidSrc.set(n, n.textContent));
    try {
      await loadMermaid();
      mermaid.initialize(mermaidConfig());
      if (fresh.length) await mermaid.run({ nodes: fresh });
      for (const n of redraw ? nodes : []) {
        if (fresh.includes(n) || !n.isConnected) continue;
        const { svg } = await mermaid.render(`sb-mermaid-${++mermaidSeq}`, mermaidSrc.get(n));
        if (n.isConnected) n.innerHTML = svg;
      }
    } catch (e) { post({ type: 'log', msg: 'mermaid: ' + (e && (e.message || JSON.stringify(e))) }); } finally { tameMermaid(nodes); }
  });
  mermaidQueue = job.catch(() => {});
  return job;
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => runMermaid());
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
  $('doc').replaceChildren(render(current.text));
  if (editing) spliceEditor([editing.start, editing.start + editing.lines]);
  decorate();
  if (settings.mermaid && document.querySelector('#doc pre.mermaid')) drawnMermaid = runMermaid(false);
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
  statsTimer = setTimeout(() => {
    const skip = '.katex-mathml, pre.mermaid, .frontmatter, .frontmatter-raw, svg';
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
    $('base').href = p.base;
    document.title = p.name;
    draw();
    if (p.files) renderSidebar(p.files, p.path);
    window.scrollTo(0, y);
    const t1 = performance.now();
    const nodes = document.querySelectorAll('#doc pre.mermaid');
    post({ type: 'painted', parseMs: t1 - t0, reason: p.reason || '' });
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
    if (RENDER_KEYS.some((k) => prev[k] !== settings[k]) && current.path) {
      const y = window.scrollY;
      draw();
      window.scrollTo(0, y);
    } else if (LOOK_KEYS.some((k) => prev[k] !== settings[k])) {
      runMermaid();
    }
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
  status(s, sticky) {
    if (sticky) stickyStatus = s;
    $('status').textContent = s;
    if (!sticky) setTimeout(() => { if ($('status').textContent === s) $('status').textContent = stickyStatus; }, 2500);
  },
};

function renderSidebar(files, active) {
  const nav = $('sidebar');
  nav.hidden = false;
  nav.innerHTML = files.map((f) => `<a href="#" data-path="${esc(f.path)}" class="${f.path === active ? 'active' : ''}">${esc(f.name)}</a>`).join('');
}

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

function showPopover(open) {
  pop.hidden = !open;
  $('aa').setAttribute('aria-expanded', String(open));
  if (open) syncPopover();
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
  const toc = e.target.closest('#toc a');
  if (toc) { e.preventDefault(); const h = tocTargets[+toc.dataset.toc]; if (h && h.isConnected) h.scrollIntoView({ behavior: 'smooth', block: 'start' }); return; }
  const side = e.target.closest('#sidebar a');
  if (side) { e.preventDefault(); post({ type: 'open', path: side.dataset.path }); return; }
  const a = e.target.closest('a[href], a[*|href]');
  const href = a && (a.getAttribute('href') ?? a.getAttributeNS('http://www.w3.org/1999/xlink', 'href'));
  if (a && href && !href.startsWith('#')) { e.preventDefault(); post({ type: 'link', href: new URL(href, document.baseURI).href }); return; }
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

$('edit').onclick = () => post({ type: 'edit' });

post({ type: 'ready' });
