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
  lineHeight: 1.6, width: 'medium', frontMatter: 'table', toc: 'auto', stats: false, math: true, mermaid: true, rawHTML: 'sanitized',
  remoteImages: false, inlineEditing: true, taskToggles: true, sidebarCollapsed: false, sidebarWidth: 240, minimalChrome: false, customCSSURL: null,
  userThemeURL: null, rawMarkdown: false, rawJSON: false, rawNotebook: false, rawCSV: false, rawXML: false, rawCSS: false };
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
      box.content = `<input type="checkbox" data-line="${li.map[0]}"${m[1] === ' ' ? '' : ' checked'}><span class="task-text">`;
      const close = new state.Token('html_inline', '', 0);
      close.content = '</span>';
      inline.children.unshift(box);
      inline.children.push(close);
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
  labelTasks(frag);
  if (!settings.taskToggles) frag.querySelectorAll('input[type=checkbox]').forEach((n) => { n.disabled = true; });
  if (settings.remoteImages !== true && current.remoteImagesOnce !== true) blockRemoteImages(frag);
  if (depth === 0) frag.querySelectorAll('img').forEach(watchImage);
  const head = fm && frontMatterNode(fm);
  if (head) frag.prepend(head);
  return frag;
}

/** Names each task checkbox by its item's text. The sanitizer drops <label> and prefixes the document's ids, so the ids are
 *  given here, after it, from a counter no document id can take. */
let taskLabels = 0;
function labelTasks(frag) {
  for (const t of frag.querySelectorAll('li.task span.task-text:not([id])')) {
    const box = t.previousElementSibling;
    if (!box || !box.matches('input[type=checkbox]')) continue;
    t.id = `sb-task-${++taskLabels}`;
    box.setAttribute('aria-labelledby', t.id);
  }
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

// ---------- an image that did not load ----------
// Its placeholder shows the alt text, the path as the document wrote it and why. For a local file the extension answers why
// (imageStatus), for the paths that failed only. The Reveal button is made here and remembered, like the load button, so
// nothing in the document can press it.
const IMG_REASONS = { missing: 'Not found', unreadable: 'Can’t read', unsupported: 'Unsupported format', tooLarge: 'Too large to show',
  notDownloaded: 'Not downloaded from iCloud' };
const IMG_ASK_MAX = 256;
let imgAsked = new Set();
let imgStatus = new Map();
const imgWaiting = new Map();
const imgOf = new WeakMap();
const imgRetried = new WeakSet();
const revealButtons = new WeakMap();
let imgAsk = null;

function watchImage(img) { img.addEventListener('error', () => imageFailed(img), { once: true }); }

function imageFailed(img) {
  if (!img.parentNode) return;
  const src = img.getAttribute('src') || '';
  let url = null, written = img.classList.contains('wl-img') ? img.dataset.wl || '' : src;
  try { url = new URL(src, document.baseURI); } catch { /* shown as written */ }
  try { written = decodeURI(written); } catch { /* kept encoded */ }
  const box = el('span', 'img-missing');
  const text = el('span', 'img-missing-text');
  const alt = img.getAttribute('alt');
  if (alt) text.append(el('span', 'img-missing-alt', alt));
  if (written) text.append(el('span', 'img-missing-path', written));
  const why = text.appendChild(el('span', 'img-missing-why'));
  box.append(icon('image', 20), text);
  box.title = written;
  imgOf.set(box, img);
  img.replaceWith(box);
  let path = null;
  if (url && url.protocol === 'spacebar:' && url.host === 'file') try { path = decodeURIComponent(url.pathname); } catch { /* not asked about */ }
  if (path) {
    if (imgStatus.has(path)) imageReason(box, path, imgStatus.get(path));
    else askImage(path, box);
  } else if (url && /^https?:$/.test(url.protocol)) {
    why.append(el('span', 'img-reason', 'Couldn’t load'), el('span', 'img-host', url.hostname));
  } else why.append(el('span', 'img-reason', 'Couldn’t load'));
}

function askImage(path, box) {
  if (!imgWaiting.has(path)) imgWaiting.set(path, []);
  imgWaiting.get(path).push(box);
  if (imgAsk) return;
  imgAsk = setTimeout(() => {
    imgAsk = null;
    const paths = [...imgWaiting.keys()].filter((p) => !imgAsked.has(p) && imgAsked.size < IMG_ASK_MAX && imgAsked.add(p));
    for (let i = 0; i < paths.length && current.path; i += 64) post({ type: 'imageStatus', doc: current.path, paths: paths.slice(i, i + 64) });
  }, 0);
}

function imageReason(box, path, s) {
  const img = imgOf.get(box);
  if (s.reason === 'ok') {
    // Readable now (it appeared, or its read was cut short): tried once more, and a second failure is the file itself.
    imgStatus.set(path, { ...s, reason: 'unsupported' });
    if (!img || imgRetried.has(img) || !box.isConnected) return imageReason(box, path, imgStatus.get(path));
    const again = img.cloneNode(false);
    imgRetried.add(again);
    watchImage(again);
    box.replaceWith(again);
    return;
  }
  const why = box.querySelector('.img-missing-why');
  why.replaceChildren(el('span', 'img-reason', IMG_REASONS[s.reason] || 'Couldn’t load'));
  if (typeof s.suggest === 'string' && s.suggest) why.append(el('span', 'img-hint', `Did you mean ${s.suggest}?`));
  if (s.folder === true) {
    const b = el('button', 'img-reveal', 'Reveal folder');
    b.type = 'button';
    b.title = 'Shows the folder this image should be in, in Finder';
    revealButtons.set(b, path);
    b.addEventListener('pointerdown', (e) => { armed = e.isTrusted ? b : null; });
    b.addEventListener('click', revealImageFolder);
    why.append(b);
  }
}

/** As loadRemoteImages: only a real click that went down on one of the page's own Reveal buttons. */
function revealImageFolder(e) {
  e.preventDefault();
  e.stopPropagation();
  const b = e.currentTarget, pressed = armed === b, path = revealButtons.get(b);
  armed = null;
  if (!e.isTrusted || !pressed || !path || !current.path) return;
  post({ type: 'revealImageFolder', doc: current.path, path });
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
  if (editing && !editing.whole && rawOn(current)) { stopEditing(); return; }
  $('kind').replaceChildren();
  if (!isMarkdown(current) || rawOn(current)) {
    $('doc').replaceChildren(viewNode(current));
    // The view no longer shows the file's text (Raw turned off): the edit ends.
    if (editing && editing.whole && !paintTextEditor()) {
      const seq = editing.seq;
      endTextEditing();
      post({ type: 'editStop', seq });
    }
    decorate();
    syncPdf();
    findAfterDraw();
    return;
  }
  const heights = [...document.querySelectorAll('#doc pre.mermaid')].map((n) => n.getBoundingClientRect().height);
  const frag = render(current.text);
  mountMermaid(frag, heights);
  $('doc').replaceChildren(frag);
  if (editing) spliceEditor([editing.start, editing.start + editing.lines]);
  decorate();
  syncPdf();
  findAfterDraw();
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
  if (editing.whole) paintTextEditor();
  else if (el) el.innerHTML = editorHTML();
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
  if (updateBusy) { window.sb.status('Updating…'); return; }
  // Find's index holds the text nodes the editor is about to change.
  closeFind();
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

// ---------- editing a whole text file (code, text, and the text of JSON and CSV) ----------

/** Offset in `code`'s text under a point. */
function textOffset(code, x, y) {
  const r = document.caretRangeFromPoint(x, y);
  if (!r || !code.contains(r.startContainer)) return null;
  const pre = document.createRange();
  pre.selectNodeContents(code);
  pre.setEnd(r.startContainer, r.startOffset);
  return pre.toString().length;
}

/** Draws the caret at `start` (len 0) or wraps the selection in `.sel`, among `root`'s text nodes (highlighted or one plain node). */
function markText(root, start, len) {
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walk.nextNode()) nodes.push(walk.currentNode);
  let pos = 0;
  if (!len) {
    // At a boundary the caret goes at the start of the next node: after a block's last line break it would open a line.
    for (const n of nodes) {
      if (start < pos + n.length) { n.splitText(start - pos).before(el('span', 'caret')); return; }
      pos += n.length;
    }
    (nodes.length ? nodes[nodes.length - 1].parentNode : root).append(el('span', 'caret'));
    return;
  }
  const end = start + len;
  for (let n of nodes) {
    const a = pos, b = pos + n.length;
    pos = b;
    if (b <= start || a >= end) continue;
    if (start > a) n = n.splitText(start - a);
    if (end < b) n.splitText(end - Math.max(a, start));
    const s = el('span', 'sel');
    n.before(s);
    s.append(n);
  }
}

// A plain edit's text in blocks of this many lines, so a keystroke lays out one block rather than the whole file.
const EDIT_CHUNK = 200;

function textChunks(code, text) {
  const chunks = [];
  let start = 0;
  do {
    let end = start;
    for (let n = 0; n < EDIT_CHUNK && end < text.length; n++) { const j = text.indexOf('\n', end); end = j < 0 ? text.length : j + 1; }
    chunks.push({ start, end, node: el('span', 'tchunk', text.slice(start, end)) });
    start = end;
  } while (start < text.length);
  code.replaceChildren(...chunks.map((c) => c.node));
  return chunks;
}

function unmark(root) {
  root.querySelectorAll('.caret').forEach((c) => c.remove());
  root.querySelectorAll('.sel').forEach((s) => s.replaceWith(...s.childNodes));
  root.normalize();
}

/** Replaces [from, to) of the text under `root` with `insert`, in its text nodes: what is typed takes the colour of the token
 *  it follows until the next highlight. */
function spliceText(root, from, to, insert) {
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walk.nextNode()) nodes.push(walk.currentNode);
  if (!nodes.length) { root.append(insert); return; }
  let pos = 0;
  for (const n of nodes) {
    const a = pos;
    pos += n.length;
    const s = Math.max(a, from), e = Math.min(pos, to);
    if (e > s) n.deleteData(s - a, e - s);
  }
  pos = 0;
  for (const n of nodes) {
    if (from === 0 || (from > pos && from <= pos + n.length) || n === nodes[nodes.length - 1]) { n.insertData(Math.min(from - pos, n.length), insert); return; }
    pos += n.length;
  }
}

let relightTimer = 0;
function relightSoon() {
  clearTimeout(relightTimer);
  relightTimer = setTimeout(() => { if (editing && editing.whole && editing.lit) { editing.lit = null; paintTextEditor(); } }, 200);
}

/** The block holding offset `at`: the first whose end is past it, else the last. */
function chunkAt(chunks, at) {
  let lo = 0, hi = chunks.length - 1;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (chunks[mid].end > at) hi = mid; else lo = mid + 1; }
  return lo;
}

/** The file's text with the caret or selection, in place of its code view's text: small files stay highlighted as they change,
 *  larger ones are plain until the edit ends, redrawn only in the blocks a change or the caret touch. `change` is the last
 *  update's { from, to, length } in the text before it. False when the view shows something other than the file's text. */
function paintTextEditor(scroll = false, change = null) {
  const pre = document.querySelector('#doc pre.code[data-file-text]');
  if (!pre || !editing || !editing.whole) return false;
  const code = pre.querySelector('code') || pre;
  const { text, selStart, selLen } = editing;
  pre.classList.add('text-editing');
  const lang = pre.dataset.lang;
  if (lang && text.length <= HIGHLIGHT_NOW) {
    // Highlighted: a change goes into the tokens around it at once, and the whole is highlighted again once typing pauses.
    editing.chunks = null;
    if (editing.lit === code) {
      unmark(code);
      if (change) { spliceText(code, change.from, change.to, text.substr(change.from, change.length)); relightSoon(); }
    } else {
      code.replaceChildren(highlighted(text, lang));
      editing.lit = code;
    }
  } else {
    editing.lit = null;
    let ch = editing.chunks && editing.chunks.length && editing.chunks[0].node.parentNode === code ? editing.chunks : null;
    const dirty = new Set(ch ? editing.marked : []);
    if (ch && change) {
      const i = chunkAt(ch, change.from), d = change.length - (change.to - change.from);
      if (i !== chunkAt(ch, Math.max(change.from, change.to - 1))) ch = null;
      else {
        ch[i].end += d;
        for (let k = i + 1; k < ch.length; k++) { ch[k].start += d; ch[k].end += d; }
        dirty.add(i);
        // A block must end at a line break, or its last line would show split from the next block's first.
        if (i < ch.length - 1 && text[ch[i].end - 1] !== '\n') ch = null;
      }
    }
    if (!ch) { ch = editing.chunks = textChunks(code, text); dirty.clear(); }
    for (const k of dirty) if (ch[k]) ch[k].node.textContent = text.slice(ch[k].start, ch[k].end);
    editing.marked = [];
    for (let k = chunkAt(ch, selStart); k <= chunkAt(ch, selStart + selLen); k++) editing.marked.push(k);
  }
  markText(code, selStart, selLen);
  const gutter = pre.parentElement.querySelector('.gutter');
  const n = Math.max(1, lineCount(text) + (text.endsWith('\n') && selStart + selLen >= text.length ? 1 : 0));
  if (gutter && +gutter.dataset.n !== n) { gutter.dataset.n = n; gutter.textContent = Array.from({ length: n }, (_, i) => i + 1).join('\n'); }
  if (scroll) { const c = code.querySelector('.caret, .sel'); if (c) c.scrollIntoView({ block: 'nearest', inline: 'nearest' }); }
  return true;
}

/** A click on the text of an editable file: the whole file is edited; the native side is told and takes the keyboard. */
function beginTextEdit(pre, e, tClick) {
  if (updateBusy) { window.sb.status('Updating…'); return; }
  const text = current.text;
  const at = textOffset(pre.querySelector('code') || pre, e.clientX, e.clientY);
  const caret = Math.min(at === null ? text.length : at, text.length);
  closeFind();
  const r = pre.getBoundingClientRect();
  editing = { seq: ++editSeq, whole: true, start: 0, lines: 0, text, selStart: caret, selLen: 0, tag: 'PRE' };
  const tMapped = now();
  paintTextEditor();
  jsonCheckSoon();
  post({ type: 'editText', path: current.path, seq: editing.seq, caret, len: text.length, clickX: e.clientX - r.left, clickY: e.clientY - r.top,
         width: r.width, height: r.height, tClick, tMapped });
  afterPaint(() => post({ type: 'caretPainted', t: now() }));
}

/** Ends a whole-file edit on the page: its text becomes the view's (a new object, so JSON and CSV parse it afresh). */
function endTextEditing() {
  if (editing && editing.whole) current = { ...current, text: editing.text };
  editing = null;
  retired = null;
}

// JSON as typed: where it stops being JSON, said quietly above the text. It is saved either way.
const strictJSON = (p) => p.view === 'json' && !/\.(jsonc|json5)$/i.test(p.name || '');
let jsonCheckTimer = 0;

function jsonCheckSoon() {
  clearTimeout(jsonCheckTimer);
  if (!strictJSON(current)) return;
  jsonCheckTimer = setTimeout(() => {
    const box = document.querySelector('#doc .viewer-json');
    if (!box || !editing || !editing.whole) return;
    const at = jsonErrorAt(editing.text);
    let n = box.querySelector('.json-warn');
    if (at === null) { if (n) n.remove(); return; }
    if (!n) { n = note(''); n.classList.add('json-warn'); box.querySelector('.viewer-head').after(n); }
    n.textContent = `Invalid JSON at ${jsonWhere(editing.text, at)}. It is saved as typed.`;
  }, 150);
}

function jsonWhere(text, at) {
  const before = text.slice(0, at);
  const nl = before.lastIndexOf('\n');
  return `line ${(before.match(/\n/g) || []).length + 1}, column ${at - nl}`;
}

/** The offset where `t` stops being JSON, or null when it is JSON. JSON.parse says only whether; this finds where, without
 *  recursion, so no nesting depth can overflow the stack. */
function jsonErrorAt(t) {
  try { JSON.parse(t); return null; } catch (e) { /* located below */ }
  const n = t.length, stack = [];
  let i = 0, want = 'value';
  const ws = () => { while (i < n && ' \t\n\r'.includes(t[i])) i++; };
  const str = () => {
    for (i++; i < n; i++) {
      const c = t.charCodeAt(i);
      if (c === 34) { i++; return true; }
      if (c < 32) return false;
      if (c === 92) {
        const e = t[i + 1];
        if (e === 'u') { if (!/^[0-9a-fA-F]{4}$/.test(t.substr(i + 2, 4))) return false; i += 5; } else if (e && '"\\/bfnrt'.includes(e)) i++; else return false;
      }
    }
    return false;
  };
  const SCALAR = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/y;
  for (;;) {
    ws();
    if (want === 'value') {
      const c = t[i];
      if (c === '{' || c === '[') {
        i++;
        ws();
        if (t[i] === (c === '{' ? '}' : ']')) { i++; want = 'after'; continue; }
        stack.push(c);
        want = c === '{' ? 'key' : 'value';
        continue;
      }
      if (c === '"') { if (!str()) return i; } else {
        SCALAR.lastIndex = i;
        const m = SCALAR.exec(t);
        if (!m) return i;
        i += m[0].length;
      }
      want = 'after';
    } else if (want === 'key') {
      if (t[i] !== '"' || !str()) return i;
      ws();
      if (t[i] !== ':') return i;
      i++;
      want = 'value';
    } else {
      const top = stack[stack.length - 1];
      if (!top) return i < n ? i : null;
      if (t[i] === ',') { i++; want = top === '{' ? 'key' : 'value'; } else if (t[i] === (top === '{' ? '}' : ']')) { i++; stack.pop(); } else return i;
    }
  }
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
  if (!isMarkdown(current) || rawOn(current)) {
    const code = $('doc').querySelector(':scope > .viewer > .code-view pre.code');
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
const RENDER_KEYS = ['frontMatter', 'toc', 'stats', 'math', 'mermaid', 'rawHTML', 'inlineEditing', 'taskToggles', 'remoteImages', 'rawMarkdown', 'rawJSON',
  'rawNotebook', 'rawCSV', 'rawXML', 'rawCSS'];
const LOOK_KEYS = ['theme', 'codeTheme', 'appearance', 'bodyFont', 'userThemeURL', 'customCSSURL'];

/** A large render's text, sent apart from its script (PageBody). Read synchronously, so this render finishes before the next
 *  one starts, as when the text came inline. Null when the body is no longer offered. */
function renderBody(url) {
  try {
    const x = new XMLHttpRequest();
    x.open('GET', url, false);
    x.send();
    return x.status === 200 ? x.responseText : null;
  } catch (e) {
    return null;
  }
}

window.sb = {
  async render(p) {
    const t0 = performance.now();
    const samePath = p.path === current.path;
    if (editing && samePath && (p.reason === 'edit' || p.reason === 'save' || p.reason === 'editEnd')) {
      requestAnimationFrame(() => post({ type: 'rendered', parseMs: 0, totalMs: performance.now() - t0, mermaid: 0, reason: p.reason, keyTime: p.keyTime }));
      return;
    }
    if (typeof p.textURL === 'string') {
      const text = renderBody(p.textURL);
      // Superseded: a newer render took the body's place and follows this one; it ends any edit and posts the paint.
      if (text === null) return;
      p = { ...p, text };
      delete p.textURL;
    }
    // The native side may not have started this edit yet; tell it the page dropped it so it never holds the keyboard for it.
    if (editing) post({ type: 'editCancel', seq: editing.seq });
    editing = null;
    retired = null;
    docVer = p.ver ?? docVer;
    const y = samePath ? window.scrollY : 0;
    if (!samePath && clearHint()) $('status').textContent = stickyStatus;
    // A re-render of the same file (a change on disk) keeps the app its Open button names; only a new file asks again.
    if (samePath && p.app === undefined && typeof current.app === 'string') p = { ...p, app: current.app };
    current = p;
    delete root.dataset.blank;
    imgStatus = new Map();
    imgAsked = new Set();
    imgWaiting.clear();
    // Each render may come with a new native PDF view (the extension closes it for anything else): place it afresh.
    pdfPosted = '';
    $('base').href = p.base;
    document.title = p.name;
    root.dataset.view = isMarkdown(p) ? 'markdown' : p.view;
    syncOpen(p);
    syncAa(p);
    syncTools(p);
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
    syncSideMenu();
    syncRaw(current);
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
    endTextEditing();
    draw();
  },
  /** ⌘F ended the edit, whose text is saved: find opens in its place. */
  editFind() { openFind(); },
  /** A change to the text of a whole-file edit, as UTF-16 offsets: [from, to) became `insert`. Keys of an edit that has ended
   *  still land in the view's text. */
  textUpdate(u) {
    const changed = u.from !== u.to || u.insert !== '';
    const apply = (t) => t.slice(0, u.from) + u.insert + t.slice(u.to);
    if (editing && editing.whole && editing.seq === u.seq) {
      if (changed) editing.text = current.text = apply(editing.text);
      Object.assign(editing, { selStart: u.selStart, selLen: u.selLen });
      paintTextEditor(true, changed ? { from: u.from, to: u.to, length: u.insert.length } : null);
      if (changed) jsonCheckSoon();
      requestAnimationFrame(() => post({ type: 'editPainted', keyTime: u.keyTime }));
    } else if (changed && !editing) {
      current = { ...current, text: apply(current.text) };
      draw();
    }
  },
  /** One folder of the sidebar's tree: the root, or a folder expanded in it. */
  setFiles(f) { setFolder(f); },
  /** A wikilink to a heading of the document already on screen. */
  scrollToHeading(m) { if (m && typeof m.heading === 'string') scrollToHeading(m.heading, true); },
  /** The file's thumbnail, made after its info card was shown: it takes the icon's place. */
  setThumb(t) {
    if (!t || t.path !== current.path || current.view !== 'info' || typeof t.thumb !== 'string') return;
    current.thumb = t.thumb;
    const old = document.querySelector('#doc .info-card > svg.ic'), img = thumbNode(current);
    if (old && img) old.replaceWith(img);
  },
  /** The panel is going away: nothing of this file may show when it next opens on another, until that one is drawn. */
  blank() { root.dataset.blank = ''; },
  /** Runs the renderers once on a sample, into nothing on screen, so the first document shown does not pay for their first run
   *  (the panel's page is loaded long before it). */
  warm() {
    try { render('# a\n\n**b** [c](#d) `e`\n\n- [ ] f\n\n| g | h |\n|---|---|\n| 1 | 2 |\n\n$x^2$\n\n```js\nconst i = 1;\n```\n'); codeBlock('let j = 1\n', 'swift'); }
    catch (e) { /* a warm-up only */ }
  },
  /** A two-finger double tap at (x, y), in CSS pixels of the viewport: the image viewer toggles as on a double-click. */
  smartZoom(m) {
    if (current.view !== 'image' || !m || !Number.isFinite(m.x) || !Number.isFinite(m.y)) return false;
    const stage = document.querySelector('#doc .img-stage'), img = stage && stage.querySelector('img'), label = zoomLabel();
    if (!stage || !img || !img.naturalWidth || !stage.contains(document.elementFromPoint(m.x, m.y))) return false;
    animateZoom(stage, img, label, toggleTarget(stage, img), m.x, m.y);
    return true;
  },
  /** The zoom of the image the extension draws (a bitmap view), as a whole percentage, for the caption. */
  imageZoom(z) {
    if (!z || z.path !== current.path || current.view !== 'bitmap' || !Number.isInteger(z.zoom)) return;
    const label = zoomLabel();
    if (label) label.textContent = `${z.zoom}%`;
  },
  /** An archive's contents, listed by the writer once its view is up, or why they could not be (then it is an info card). */
  setArchive(a) {
    if (!a || a.path !== current.path || current.view !== 'archive' || Array.isArray(current.entries)) return;
    if (Array.isArray(a.entries)) {
      current.entries = a.entries;
      current.truncated = a.truncated === true;
      // The same archive listed again (it changed on disk) keeps its open folders.
      if (archiveOpenPath !== current.path) archiveOpen = null;
    } else {
      current.view = 'info';
      current.note = typeof a.error === 'string' ? a.error : 'This archive’s contents can’t be listed.';
      root.dataset.view = 'info';
    }
    draw();
  },
  /** The app the viewer's Open button would use, named once the writer has looked it up. */
  setOpener(o) {
    if (!o || o.path !== current.path || typeof o.app !== 'string') return;
    current.app = o.app;
    current.editor = o.editor === true;
    document.querySelectorAll('#doc .viewer-open[data-action=openFile]').forEach((b) => { b.textContent = openLabel(current); });
    const b = $('edit');
    if (b.dataset.action === 'openFile') b.title = openTitle(current, 'openFile');
  },
  /** A newer release than this one: a dot on the Aa button and a row at the top of its popover. `state` is available,
   *  elsewhere (this copy is not the one the installer replaces), started, inProgress (still running after a while), done, or
   *  failed (with the reason, and whether the install command or the Update button is offered again). */
  update(u) {
    if (!u || typeof u.version !== 'string' || !['available', 'elsewhere', 'started', 'inProgress', 'done', 'failed'].includes(u.state)) return;
    showUpdate(u);
  },
  /** A new preview, or a controller with no update of its own: the page forgets the last one's state, busy included. */
  updateReset() {
    clearTimeout(updateTimer);
    updateBusy = false;
    $('aa-update').hidden = true;
    delete $('aa').dataset.update;
    $('aa').title = 'Appearance';
    syncUpdateButton();
  },
  /** Why the local images that failed did not load: {doc, images: {path: {reason, folder, suggest?}}}. */
  imageStatus(r) {
    if (!r || r.doc !== current.path || !r.images || typeof r.images !== 'object') return;
    for (const [path, s] of Object.entries(r.images)) {
      if (!s || typeof s !== 'object') continue;
      const boxes = imgWaiting.get(path) || [];
      imgWaiting.delete(path);
      if (s.reason !== 'ok') imgStatus.set(path, s);
      for (const b of boxes) if (b.isConnected) imageReason(b, path, s);
    }
  },
  /** The writer's answer to a copy: the Copy button shows a check for a moment, and the status line says what was copied. */
  copied(r) {
    const ok = !!r && r.ok === true, b = $('copy');
    window.sb.status(ok ? (r.truncated === true ? `Copied the first ${readCap(current)}` : 'Copied') : 'Could not copy');
    b.classList.toggle('done', ok);
    clearTimeout(copyTimer);
    copyTimer = setTimeout(() => b.classList.remove('done'), 1500);
  },
  /** The Space helper is on in the settings but did not take Space: one quiet line, which a click turns into Settings. */
  helperHint() {
    const s = $('status');
    if (s.textContent) return false;
    s.textContent = 'Space helper is off: open spacebar Settings';
    s.dataset.hint = '';
    s.title = 'Open spacebar Settings, General';
    return true;
  },
  installCopied(r) {
    const b = $('aa-copy');
    b.textContent = r && r.ok ? 'Copied' : 'Could not copy';
    setTimeout(() => { b.textContent = 'Copy Install Command'; }, 1600);
  },
  status(s, sticky) {
    if (sticky) stickyStatus = s;
    clearHint();
    $('status').textContent = s;
    if (!sticky) setTimeout(() => { if ($('status').textContent === s) $('status').textContent = stickyStatus; }, 2500);
  },
};

/** Takes the helper's hint down; whether it was up. */
function clearHint() {
  const s = $('status');
  if (!('hint' in s.dataset)) return false;
  delete s.dataset.hint;
  s.removeAttribute('title');
  s.textContent = '';
  return true;
}
$('status').addEventListener('click', () => { if ('hint' in $('status').dataset && clearHint()) post({ type: 'openSettings', tab: 'general' }); });

// ---------- file views: everything that is not Markdown, built from text nodes (never the file's own markup) ----------

const TEXT_VIEWS = new Set(['code', 'text', 'json']);
const HIGHLIGHT_MAX = 512 * 1024;
const HIGHLIGHT_NOW = 24 * 1024;
const CSV_ROWS = 50000;
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
  media: [DOC, FOLD, 'M7 7.6v4.3l3.4-2.15z'],
  code: [DOC, FOLD, 'M7.2 8.3 5.7 10l1.5 1.7M9.8 8.3l1.5 1.7-1.5 1.7'],
  data: [DOC, FOLD, 'M5.8 7.6h5.4v4.6H5.8zM5.8 9.9h5.4M8.5 7.6v4.6'],
  text: [DOC, FOLD, 'M6 7.5h5M6 9.5h5M6 11.5h3'],
  other: [DOC, FOLD],
  archive: [DOC, FOLD, 'M7.2 2v1.2M8.4 3.2v1.2M7.2 4.4v1.2M8.4 5.6v1.2', 'M6.9 8h3v2.6h-3z'],
  app: ['M2 3h12v10H2z', 'M2 5.6h12', 'M3.7 4.3h.01M5.1 4.3h.01M6.5 4.3h.01', 'M5 8.5h6M5 10.8h4'],
  font: [DOC, FOLD, 'M6.1 12.4 8.5 6.8l2.4 5.6M7 10.4h3'],
  doc: [DOC, FOLD, 'M6 7h5v1.8H6z', 'M6 10.3h5M6 12.3h3.6'],
  sheet: ['M2 2.5h12v11H2z', 'M2 5.5h12M2 8.3h12M2 11h12M6 2.5v11'],
  slides: ['M1.8 3h12.4v8H1.8z', 'M8 11v2.8M5.8 14h4.4', 'M5 8.8l2-2.2 1.6 1.4L11 5.6'],
  model: ['M8 1.8 13.6 5v6L8 14.2 2.4 11V5z', 'M2.4 5 8 8.2 13.6 5M8 8.2v6'],
  video: ['M1.8 3.5h12.4v9H1.8z', 'M6.8 6.1v3.8l3.2-1.9z'],
  audio: ['M6.5 11.8V3.9l6-1.4v7.9', 'M3.6 11.8a1.45 1.25 0 1 0 2.9 0 1.45 1.25 0 1 0-2.9 0zM9.6 10.4a1.45 1.25 0 1 0 2.9 0 1.45 1.25 0 1 0-2.9 0z'],
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
  b.textContent = p.canOpen === true ? openLabel(p) : 'Reveal in Finder';
  return b;
}

/** "Open in <editor>" for text going to a text editor, else "Open with <app>" (its default app). */
const openLabel = (p) => (p.app ? `${p.editor === true ? 'Open in' : 'Open with'} ${p.app}` : 'Open');

/** Open and Reveal only for a real click: the page's own buttons, never a script-made event. */
function viewerAction(b, e) {
  // A Markdown document can hold a look-alike button; the viewers exist only for other files.
  if (!current.path || isMarkdown(current)) return;
  const a = b.dataset.action;
  if ((a === 'openFile' || a === 'reveal') && e.isTrusted) post({ type: a, path: current.path });
  else if (a === 'csvSort') csvSortBy(+b.dataset.col);
  else if (a === 'jsonToggle' || a === 'jsonAll' || a === 'jsonMore') jsonAction(a, b);
  else if (a === 'archiveDir' && archiveOpen) {
    const path = b.dataset.path;
    if (!archiveOpen.delete(path)) archiveOpen.add(path);
    const y = window.scrollY;
    draw();
    window.scrollTo(0, y);
    const again = [...document.querySelectorAll('#doc .arc-dir')].find((d) => d.dataset.path === path);
    if (again) again.focus({ preventScroll: true });
  }
}

/** The row over a view: its own controls, and the Open button Minimal chrome shows here (the toolbar row has its own). */
function viewHead(p, ...extra) {
  const head = el('div', 'viewer-head');
  extra = extra.filter(Boolean);
  if (!extra.length) head.classList.add('bare');
  head.append(...extra, openButton(p));
  return head;
}

/** The file's kind and size (and whatever `more` adds) as quiet text in the toolbar. With `zoom`, the span an image's zoom is
 *  written to follows it; returned with the text's own span. */
function setKind(p, more = [], zoom = false) {
  const text = el('span', 'kind-text', [p.kindName, ...more].filter(Boolean).join(' · '));
  const z = zoom ? el('span', 'img-zoom') : null;
  $('kind').replaceChildren(...[text, z].filter(Boolean));
  return { text, zoom: z };
}
const zoomLabel = () => document.querySelector('#kind .img-zoom');

function note(text) { return el('div', 'viewer-note', text); }

const readCap = (p) => `${(typeof p.readCap === 'number' ? p.readCap : 2 << 20) >> 20} MB`;
function truncNote(p) { return p.truncated ? note(`Showing the first ${readCap(p)} of ${fmtSize(p.size)}.`) : null; }

const highlighted = (text, lang) => DOMPurify.sanitize(hljs.highlight(text, { language: lang, ignoreIllegals: true }).value,
  { ALLOWED_TAGS: ['span'], ALLOWED_ATTR: ['class'], RETURN_DOM_FRAGMENT: true });

/** Source with line numbers; highlighted by the bundled highlight.js when the language is known and the text is not huge.
 *  `file`: the text is the editable file's own, which a click edits. */
function codeBlock(text, lang, file = false) {
  const wrap = el('div', 'code-view');
  const n = Math.max(1, lineCount(text));
  const gutter = el('pre', 'gutter', Array.from({ length: n }, (_, i) => i + 1).join('\n'));
  gutter.dataset.n = n;
  wrap.append(gutter);
  const pre = el('pre', 'code');
  if (file) pre.dataset.fileText = '';
  const code = el('code', 'hljs');
  const highlight = () => {
    code.replaceChildren(highlighted(text, lang));
    // The matches drawn in the plain text are on nodes just replaced.
    if (code.isConnected) findAfterDraw();
  };
  // Plain text goes in as many text nodes, a few thousand characters each at line ends: WebKit measures a range in one of them
  // (find's matches) in time that grows with the node.
  for (let at = 0; at < text.length;) {
    let end = text.indexOf('\n', at + 8192);
    end = end >= 0 && end < at + 16384 ? end + 1 : Math.min(text.length, at + 8192);
    if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end++;
    code.append(text.slice(at, end));
    at = end;
  }
  if (lang && window.hljs && hljs.getLanguage(lang) && text.length <= HIGHLIGHT_MAX) {
    pre.dataset.lang = lang;
    // A long file is painted plain first: highlighting it would hold the first paint.
    if (text.length <= HIGHLIGHT_NOW) highlight();
    else afterPaint(() => { if (code.isConnected && !pre.classList.contains('text-editing')) highlight(); });
  }
  pre.append(code);
  wrap.append(pre);
  return wrap;
}

// ---------- JSON: a tree of text nodes, and a Jupyter notebook as its cells; Raw shows either as its text ----------

// The JSON on screen: parsed once per payload; the open nodes are kept while the same file is shown again.
let jsonState = null;
const JSON_CHUNK = 500;        // children of one node drawn before a "Show more" row
const JSON_ALL_MAX = 5000;     // rows "Expand all" opens at most
const JSON_AUTO_ROWS = 200;    // rows opened on arrival, level by level
const JSON_STR_MAX = 10000;    // characters of one string shown
const ptrKey = (k) => String(k).replace(/~/g, '~0').replace(/\//g, '~1');
const isBranch = (v) => v !== null && typeof v === 'object';
const branchSize = (v) => (Array.isArray(v) ? v.length : Object.keys(v).length);

function jsonModel(p) {
  if (jsonState && jsonState.p === p) return jsonState;
  let value, ok = false;
  if (!p.truncated) {
    try { value = JSON.parse(strictJSON(p) ? p.text : jsonLoose(p.text)); ok = true; } catch (e) { ok = false; }
  }
  const nb = ok && /\.ipynb$/i.test(p.name || '') && isBranch(value) && Array.isArray(value.cells);
  // One view: a notebook as its cells, an object or array as the tree; anything else is its text. Raw is the toolbar's toggle.
  const mode = nb ? 'notebook' : ok && isBranch(value) ? 'tree' : 'text';
  const same = jsonState && jsonState.p.path === p.path;
  jsonState = { p, value, ok, nb, mode, open: same ? jsonState.open : new Set(), more: same ? jsonState.more : new Map() };
  if (!same && mode === 'tree') jsonOpenLevels(jsonState, JSON_AUTO_ROWS);
  return jsonState;
}

/** JSONC and JSON5 text as JSON: comments and trailing commas out, strings untouched. Offsets are not kept; editing is on
 *  the file's own text. */
function jsonLoose(t) {
  const out = [];
  let last = -1, from = 0;
  const keep = (to) => { if (to > from) out.push(t.slice(from, to)); };
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < t.length && t[j] !== c && t[j] !== '\n') j += t[j] === '\\' ? 2 : 1;
      i = j;
      last = -1;
    } else if (c === '/' && (t[i + 1] === '/' || t[i + 1] === '*')) {
      keep(i);
      const j = t[i + 1] === '/' ? t.indexOf('\n', i) : t.indexOf('*/', i + 2);
      i = j < 0 ? t.length : t[i + 1] === '/' ? j - 1 : j + 1;
      from = i + 1;
      out.push(' ');
    } else if (c === ',') {
      keep(i);
      out.push(',');
      last = out.length - 1;
      from = i + 1;
    } else if ((c === '}' || c === ']') && last >= 0) {
      out[last] = '';
      last = -1;
    } else if (c !== ' ' && c !== '\t' && c !== '\n' && c !== '\r') last = -1;
  }
  keep(t.length);
  return out.join('');
}

/** Opens the tree level by level, breadth first, while the rows shown stay within `budget`. */
function jsonOpenLevels(m, budget) {
  let level = [['', m.value]], rows = 1;
  while (level.length) {
    const next = [];
    for (const [ptr, v] of level) {
      const n = Math.min(branchSize(v), JSON_CHUNK);
      if (rows + n > budget) return;
      m.open.add(ptr);
      rows += n;
      const kids = Array.isArray(v) ? v.slice(0, n).map((x, i) => [i, x]) : Object.entries(v).slice(0, n);
      for (const [k, x] of kids) if (isBranch(x) && branchSize(x)) next.push([`${ptr}/${ptrKey(k)}`, x]);
    }
    level = next;
  }
}

function jsonView(p) {
  const m = jsonModel(p);
  const raw = m.mode === 'text' || rawOn(p);
  const box = el('div', 'viewer viewer-code viewer-json');
  const extra = [];
  if (!raw && m.mode === 'tree') {
    for (const [label, open] of [['Expand All', '1'], ['Collapse All', '0']]) {
      const b = el('button', 'json-all', label);
      b.type = 'button';
      Object.assign(b.dataset, { action: 'jsonAll', open });
      extra.push(b);
    }
  }
  setKind(p, [fmtSize(p.size)]);
  box.append(viewHead(p, ...extra));
  const t = truncNote(p);
  if (t) box.append(t, note(/\.ipynb$/i.test(p.name || '') ? 'A notebook this large is shown as its text.' : 'A file this large is shown as its text, not as a tree.'));
  if (!m.ok && !p.truncated) {
    const at = strictJSON(p) ? jsonErrorAt(p.text) : null;
    const n = note(at === null ? 'Not valid JSON: shown as is.' : `Not valid JSON at ${jsonWhere(p.text, at)}: shown as is.`);
    n.classList.add('json-warn');
    box.append(n);
  }
  if (raw) box.append(codeBlock(p.text, 'json', p.editable === true));
  else if (m.mode === 'tree') box.append(jsonTree(m));
  else box.append(notebookView(m.value));
  return box;
}

/** The tree as rows, one per key or item: an open object or array lists its children under it, JSON_CHUNK at a time. */
function jsonTree(m) {
  const tree = el('div', 'json-tree');
  tree.setAttribute('role', 'tree');
  tree.setAttribute('aria-label', 'JSON');
  const rows = [];
  const stack = [{ ptr: '', key: null, v: m.value, depth: 0 }];
  while (stack.length) {
    const it = stack.pop();
    if (it.more) { rows.push(jsonMoreRow(it)); continue; }
    const branch = isBranch(it.v), open = branch && m.open.has(it.ptr);
    rows.push(jsonRow(it, branch, open));
    if (!open) continue;
    const all = Array.isArray(it.v) ? it.v : Object.keys(it.v);
    const shown = Math.min(all.length, m.more.get(it.ptr) || JSON_CHUNK);
    const kids = [];
    for (let i = 0; i < shown; i++) {
      const k = Array.isArray(it.v) ? i : all[i];
      kids.push({ ptr: `${it.ptr}/${ptrKey(k)}`, key: k, index: Array.isArray(it.v), v: it.v[k], depth: it.depth + 1 });
    }
    if (shown < all.length) kids.push({ more: true, ptr: it.ptr, left: all.length - shown, depth: it.depth + 1 });
    for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
  }
  tree.append(...rows);
  return tree;
}

function jsonRow(it, branch, open) {
  const row = el('div', 'jt-row');
  row.dataset.ptr = it.ptr;
  row.setAttribute('role', 'treeitem');
  row.setAttribute('aria-level', String(it.depth + 1));
  row.style.setProperty('--d', it.depth);
  if (branch) {
    row.setAttribute('aria-expanded', String(open));
    const b = el('button', 'jt-tw', open ? '▾' : '▸');
    b.type = 'button';
    Object.assign(b.dataset, { action: 'jsonToggle', ptr: it.ptr });
    b.setAttribute('aria-label', open ? 'Collapse' : 'Expand');
    row.append(b);
  } else row.append(el('span', 'jt-tw', ''));
  if (it.key !== null) {
    row.append(it.index ? el('span', 'jt-index', String(it.key)) : el('span', 'jt-key hljs-attr', JSON.stringify(String(it.key))), el('span', 'jt-colon', ': '));
  }
  const v = it.v;
  if (branch) {
    const n = branchSize(v), arr = Array.isArray(v);
    row.append(el('span', 'jt-sum', `${arr ? '[' : '{'} ${n.toLocaleString()} ${arr ? (n === 1 ? 'item' : 'items') : (n === 1 ? 'key' : 'keys')} ${arr ? ']' : '}'}`));
  } else {
    row.append(el('span', `jt-val ${typeof v === 'string' ? 'hljs-string' : typeof v === 'number' ? 'hljs-number' : 'hljs-literal'}`, jsonLeaf(v)));
  }
  return row;
}

function jsonMoreRow(it) {
  const row = el('div', 'jt-row jt-more');
  row.style.setProperty('--d', it.depth);
  const b = el('button', 'jt-more-b', `Show ${Math.min(JSON_CHUNK, it.left).toLocaleString()} more (${it.left.toLocaleString()} not shown)`);
  b.type = 'button';
  Object.assign(b.dataset, { action: 'jsonMore', ptr: it.ptr });
  row.append(el('span', 'jt-tw', ''), b);
  return row;
}

/** The node at `ptr` in the value, or undefined. */
function jsonAt(v, ptr) {
  if (!ptr) return v;
  for (const part of ptr.slice(1).split('/')) {
    if (!isBranch(v)) return undefined;
    v = v[part.replace(/~1/g, '/').replace(/~0/g, '~')];
  }
  return v;
}

function jsonAction(a, b) {
  const m = jsonState;
  if (!m || m.p !== current) return;
  const y = window.scrollY;
  if (a === 'jsonToggle') { const p = b.dataset.ptr; if (!m.open.delete(p)) m.open.add(p); }
  else if (a === 'jsonMore') m.more.set(b.dataset.ptr, (m.more.get(b.dataset.ptr) || JSON_CHUNK) + JSON_CHUNK);
  else if (a === 'jsonAll') {
    m.open.clear();
    m.more.clear();
    if (b.dataset.open === '1') jsonOpenLevels(m, JSON_ALL_MAX);
  }
  draw();
  window.scrollTo(0, y);
  const again = a === 'jsonToggle' || a === 'jsonMore' ? [...document.querySelectorAll('#doc [data-action=jsonToggle]')].find((x) => x.dataset.ptr === b.dataset.ptr)
    : [...document.querySelectorAll(`#doc [data-action=${a}]`)].find((x) => x.dataset.open === b.dataset.open);
  if (again) again.focus({ preventScroll: true });
}

// ---------- a Jupyter notebook: Markdown cells through the document renderer, code highlighted, outputs as text or images ----------

const NB_CELLS = 2000;
const NB_IMAGE_MAX = 8 << 20;
const nbText = (x) => (Array.isArray(x) ? x.join('') : typeof x === 'string' ? x : '');
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]/g;

function notebookView(nb) {
  const box = el('div', 'notebook');
  const meta = isBranch(nb.metadata) ? nb.metadata : {};
  const lang = [meta.kernelspec && meta.kernelspec.language, meta.language_info && meta.language_info.name]
    .find((l) => typeof l === 'string' && window.hljs && hljs.getLanguage(l)) || null;
  const cells = nb.cells.slice(0, NB_CELLS);
  for (const c of cells) {
    if (!isBranch(c)) continue;
    const src = nbText(c.source);
    if (c.cell_type === 'markdown') {
      const md = el('div', 'nb-cell nb-md');
      md.append(nbMarkdown(src));
      box.append(md);
    } else if (c.cell_type === 'code') {
      const cell = el('div', 'nb-cell nb-code');
      const n = Number.isInteger(c.execution_count) ? String(c.execution_count) : ' ';
      cell.append(el('div', 'nb-prompt', `[${n}]:`), codeBlock(src, lang));
      const outs = Array.isArray(c.outputs) ? c.outputs : [];
      for (const o of outs.slice(0, 100)) { const node = nbOutput(o); if (node) cell.append(node); }
      box.append(cell);
    } else {
      const raw = el('div', 'nb-cell nb-raw');
      raw.append(el('pre', 'nb-out', src));
      box.append(raw);
    }
  }
  if (nb.cells.length > NB_CELLS) box.append(note(`Showing the first ${NB_CELLS.toLocaleString()} of ${nb.cells.length.toLocaleString()} cells.`));
  if (!nb.cells.length) box.append(note('This notebook has no cells.'));
  return box;
}

/** A Markdown cell, through the sanitizing renderer; nothing in it is editable or can tick a task in this file. */
function nbMarkdown(src) {
  const frag = render(src, 1);
  frag.querySelectorAll('[data-src]').forEach((n) => n.removeAttribute('data-src'));
  // A cell sits inside .viewer, where a click on any [data-action] is the viewer's own button (reveal, open with).
  frag.querySelectorAll('[data-action]').forEach((n) => n.removeAttribute('data-action'));
  frag.querySelectorAll('input[type=checkbox]').forEach((n) => { n.removeAttribute('data-line'); n.disabled = true; });
  // Diagrams are drawn for the document on screen only; here a diagram is its source.
  frag.querySelectorAll('pre.mermaid').forEach((n) => n.classList.remove('mermaid'));
  return frag;
}

/** An image output as a data: URL, from base64 checked here; SVG text is encoded (an <img> runs no script). */
function nbImage(type, data) {
  let src;
  if (type === 'image/svg+xml') {
    const svg = nbText(data);
    if (!svg || svg.length > NB_IMAGE_MAX) return null;
    src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  } else {
    const b64 = nbText(data).replace(/\s+/g, '');
    if (!b64 || b64.length > NB_IMAGE_MAX || !/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) return null;
    src = `data:${type};base64,${b64}`;
  }
  const img = document.createElement('img');
  img.className = 'nb-img';
  img.alt = 'Output';
  img.src = src;
  return img;
}

function nbOutput(o) {
  if (!isBranch(o)) return null;
  if (o.output_type === 'stream') return el('pre', `nb-out${o.name === 'stderr' ? ' nb-err' : ''}`, nbText(o.text).replace(ANSI, ''));
  if (o.output_type === 'error') {
    const tb = Array.isArray(o.traceback) ? o.traceback.map((l) => String(l).replace(ANSI, '')).join('\n') : '';
    return el('pre', 'nb-out nb-err', tb || `${o.ename || 'Error'}: ${o.evalue || ''}`);
  }
  if ((o.output_type === 'execute_result' || o.output_type === 'display_data') && isBranch(o.data)) {
    for (const type of ['image/png', 'image/jpeg', 'image/gif', 'image/svg+xml']) {
      if (own(o.data, type)) { const img = nbImage(type, o.data[type]); if (img) return img; }
    }
    if (own(o.data, 'text/markdown')) { const d = el('div', 'nb-out nb-md'); d.append(nbMarkdown(nbText(o.data['text/markdown']))); return d; }
    if (own(o.data, 'text/plain')) return el('pre', 'nb-out', nbText(o.data['text/plain']).replace(ANSI, ''));
    if (own(o.data, 'text/html')) return el('div', 'viewer-note nb-note', 'HTML output is not shown.');
  }
  return null;
}

/** CSV (RFC 4180 quoting) or TSV; the first row is the header. Rows past the cap are counted, not kept. */
function parseDelimited(text, sep, max) {
  const rows = [];
  let row = [], field = '', q = false, total = 0, at = 0;
  const endRow = () => { row.push(field); field = ''; if (total < max + 1) rows.push(row); total++; row = []; };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      // A run up to the next quote goes in at once.
      const j = text.indexOf('"', i);
      if (j < 0) { field += text.slice(i); i = text.length; break; }
      field += text.slice(i, j);
      i = j;
      if (text[i + 1] === '"') { field += '"'; i++; } else q = false;
    } else if (c === '"' && field === '') q = true;
    else if (c === sep) { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; endRow(); }
    else {
      // A run of plain characters goes in at once.
      at = i;
      while (i + 1 < text.length && !'"\n\r'.includes(text[i + 1]) && text[i + 1] !== sep) i++;
      field += text.slice(at, i + 1);
    }
  }
  if (field !== '' || row.length) endRow();
  return { rows, total };
}

/** The delimiter of a file without one by extension: whichever of , ; tab | splits its first lines most consistently. */
function sniffDelimiter(text) {
  const sample = text.slice(0, 64 * 1024);
  let best = ',', bestScore = 0;
  for (const d of [',', ';', '\t', '|']) {
    const counts = [];
    let n = 0, q = false;
    for (let i = 0; i < sample.length && counts.length < 40; i++) {
      const c = sample[i];
      if (c === '"') q = !q;
      else if (!q && c === d) n++;
      else if (!q && c === '\n') { counts.push(n); n = 0; }
    }
    if (n) counts.push(n);
    const freq = new Map();
    for (const k of counts) if (k) freq.set(k, (freq.get(k) || 0) + 1);
    let mode = 0, modeN = 0;
    for (const [k, v] of freq) if (v > modeN || (v === modeN && k > mode)) { mode = k; modeN = v; }
    const score = mode ? modeN / counts.length + Math.min(mode, 50) / 1000 : 0;
    if (score > bestScore) { best = d; bestScore = score; }
  }
  return best;
}

const DELIMITER_NAMES = { ',': 'comma', ';': 'semicolon', '\t': 'tab', '|': 'pipe' };
const CSV_VIRTUAL = 400;
const csvCollator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

/** A cell as a number, or NaN: 1,234.5, -3e2, 12%, $4, and with a semicolon delimiter a decimal comma (3,5). */
function csvNumber(s, sep) {
  const t = s.trim();
  if (!t || !/\d/.test(t)) return NaN;
  if (sep === ';' && /^[-+]?\d+,\d+$/.test(t)) return parseFloat(t.replace(',', '.'));
  if (!/^[-+]?[$€£¥]?\s?(\d{1,3}(,\d{3})+|\d+)?(\.\d+)?([eE][-+]?\d+)?\s?%?$/.test(t)) return NaN;
  return parseFloat(t.replace(/[$€£¥,%\s]/g, ''));
}

// The table on screen: parsed once per payload, its sort kept while the same file is shown again.
let csvState = null;

function csvModel(p) {
  if (csvState && csvState.p === p) return csvState;
  const text = p.text.replace(/^﻿/, '');
  const sep = p.tsv === true ? '\t' : sniffDelimiter(text);
  const parsed = parseDelimited(text, sep, CSV_ROWS);
  let { total } = parsed;
  const rows = parsed.rows;
  // A file cut short ends in a row cut short.
  if (p.truncated && rows.length > 1 && total <= CSV_ROWS + 1) { rows.pop(); total--; }
  const head = rows.length ? rows[0].slice(0, CSV_COLS) : [];
  const body = rows.slice(1, CSV_ROWS + 1);
  let cols = head.length;
  for (const r of body) if (r.length > cols) cols = r.length;
  cols = Math.min(CSV_COLS, cols);
  const numeric = [];
  for (let c = 0; c < cols; c++) {
    let filled = 0, nums = 0;
    for (let i = 0; i < body.length && filled < 2000; i++) {
      const v = body[i][c];
      if (v === undefined || !v.trim()) continue;
      filled++;
      if (!isNaN(csvNumber(v, sep))) nums++;
    }
    numeric.push(filled > 0 && nums / filled >= 0.9);
  }
  // The same file again (a change on disk) keeps its sort and where it was scrolled to.
  const same = csvState && csvState.p.path === p.path ? csvState : null;
  const keep = same && same.sort && same.sort.col < cols ? same.sort : null;
  csvState = { p, sep, head, body, total, cols, numeric, wide: rows.some((r) => r.length > CSV_COLS), sort: keep, order: null, rowH: 0,
    top: same ? same.top : 0, left: same ? same.left : 0, widths: null, widthsFont: '' };
  sortCsv(csvState);
  return csvState;
}

/** The rows' order for the sort: stable, numbers as numbers, blanks last either way. */
function sortCsv(m) {
  const n = m.body.length;
  m.order = Array.from({ length: n }, (_, i) => i);
  if (!m.sort) return;
  const { col, dir } = m.sort, num = m.numeric[col];
  const key = m.body.map((r) => { const v = r[col] === undefined ? '' : r[col]; return num ? csvNumber(v, m.sep) : v; });
  const blank = (i) => (num ? isNaN(key[i]) : !String(key[i]).trim());
  m.order.sort((a, b) => {
    const ba = blank(a), bb = blank(b);
    if (ba || bb) return ba === bb ? a - b : ba ? 1 : -1;
    const c = num ? key[a] - key[b] : csvCollator.compare(key[a], key[b]);
    return c ? c * dir : a - b;
  });
}

function csvView(p) {
  if (rawOn(p)) {
    const box = el('div', 'viewer viewer-code viewer-csv-raw');
    setKind(p, [fmtSize(p.size)]);
    box.append(viewHead(p));
    const t = truncNote(p);
    if (t) box.append(t);
    else if (p.editable !== true && settings.inlineEditing && p.size > 2 << 20) box.append(note('Too large to edit here.'));
    box.append(codeBlock(p.text, null, p.editable === true));
    return box;
  }
  const m = csvModel(p);
  const box = el('div', 'viewer viewer-csv');
  const shape = m.head.length ? `${Math.max(0, m.total - 1).toLocaleString()} ${m.total === 2 ? 'row' : 'rows'} × ${m.cols} ${m.cols === 1 ? 'column' : 'columns'}` : '';
  const sepName = m.sep === ',' || (m.sep === '\t' && p.tsv === true) ? '' : `${DELIMITER_NAMES[m.sep]}-separated`;
  setKind(p, [fmtSize(p.size), shape, sepName]);
  box.append(viewHead(p));
  const t = truncNote(p);
  if (t) box.append(t);
  else if (p.editable !== true && settings.inlineEditing && p.size > 2 << 20) box.append(note('Too large to edit here.'));
  if (m.total - 1 > CSV_ROWS) box.append(note(`Showing the first ${CSV_ROWS.toLocaleString()} of ${(m.total - 1).toLocaleString()} rows.`));
  if (m.wide) box.append(note(`Showing the first ${CSV_COLS} columns.`));
  const scroll = el('div', 'csv-scroll');
  const table = el('table', 'csv');
  const virtual = m.body.length > CSV_VIRTUAL;
  table.classList.toggle('virtual', virtual);
  table.setAttribute('aria-rowcount', String(m.body.length + 1));
  if (m.head.length) {
    const tr = table.appendChild(el('thead')).appendChild(el('tr'));
    tr.setAttribute('aria-rowindex', '1');
    const corner = tr.appendChild(el('th', 'rn', ''));
    corner.setAttribute('aria-label', 'Row');
    for (let c = 0; c < m.cols; c++) {
      const th = tr.appendChild(el('th', m.numeric[c] ? 'num' : ''));
      const sorted = m.sort && m.sort.col === c;
      th.setAttribute('aria-sort', sorted ? (m.sort.dir > 0 ? 'ascending' : 'descending') : 'none');
      const b = el('button', 'csv-sort');
      b.type = 'button';
      b.dataset.action = 'csvSort';
      b.dataset.col = c;
      b.title = sorted && m.sort.dir < 0 ? 'Click to restore the file’s order' : `Sort by this column${sorted ? ', descending' : ''}`;
      b.append(el('span', 'csv-h', m.head[c] === undefined ? '' : m.head[c]), el('span', 'csv-ind', sorted ? (m.sort.dir > 0 ? '▲' : '▼') : ''));
      th.append(b);
    }
  }
  const tb = table.appendChild(el('tbody'));
  scroll.append(table);
  box.append(scroll);
  const drawRows = () => csvRows(m, scroll, tb, virtual);
  m.shown = { scroll, draw: drawRows };
  let queued = false, restoring = true;
  scroll.addEventListener('scroll', () => {
    if (restoring) return;
    m.top = scroll.scrollTop;
    m.left = scroll.scrollLeft;
    if (!virtual || queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; drawRows(); });
  }, { passive: true });
  drawRows();
  // draw() puts the view in place in the same task: once it is, the widths are fixed, the window drawn and the scroll put back.
  queueMicrotask(() => {
    if (scroll.isConnected) {
      drawRows();
      scroll.scrollTop = m.top;
      scroll.scrollLeft = m.left;
      drawRows();
    }
    restoring = false;
  });
  return box;
}

/** A windowed table's column widths, fixed once from a sample of rows (its start, its end and evenly between), so they never
 *  follow whichever rows happen to be drawn. */
function csvWidths(m, table) {
  const cell = table.querySelector('tbody td') || table;
  const cs = getComputedStyle(cell);
  const font = `${cs.fontSize} ${cs.fontFamily}`;
  if (m.widths && m.widthsFont === font) return m.widths;
  const cx = document.createElement('canvas').getContext('2d');
  const size = parseFloat(cs.fontSize) || 13, pad = 21, max = size * 32, min = size * 3;
  const n = m.body.length, sample = new Set();
  for (let i = 0; i < Math.min(n, 300); i++) { sample.add(i); sample.add(n - 1 - i); }
  for (let i = 0; i < 400; i++) sample.add(Math.floor((i * n) / 400));
  const text = (v) => (v === undefined ? '' : String(v).slice(0, 200).replace(/\s+/g, ' '));
  const widths = [];
  cx.font = `${cs.fontSize} ${cs.fontFamily}`;
  const rn = cx.measureText(String(n)).width + pad;
  for (let c = 0; c < m.cols; c++) {
    let w = 0;
    for (const i of sample) if (i >= 0 && i < n) w = Math.max(w, cx.measureText(text(m.body[i][c])).width);
    widths.push(w);
  }
  cx.font = `600 ${cs.fontSize} ${cs.fontFamily}`;
  for (let c = 0; c < m.cols; c++) widths[c] = Math.max(widths[c], cx.measureText(text(m.head[c])).width + size * 1.4);
  m.widths = [Math.ceil(Math.max(rn, size * 2 + pad)), ...widths.map((w) => Math.ceil(Math.min(max, Math.max(min, w + pad))))];
  m.widthsFont = font;
  return m.widths;
}

function csvColgroup(table, widths) {
  let cg = table.querySelector('colgroup');
  if (!cg) { cg = document.createElement('colgroup'); table.prepend(cg); }
  cg.replaceChildren(...widths.map((w) => { const col = document.createElement('col'); col.style.width = w + 'px'; return col; }));
  table.style.width = widths.reduce((a, b) => a + b, 0) + 'px';
}

/** The table's rows: all of them, or with `virtual` those in the scroll box's view and a margin, between two spacer rows. */
function csvRows(m, scroll, tb, virtual) {
  const n = m.order.length;
  let a = 0, b = n;
  const h = m.rowH || 26;
  if (virtual && scroll.isConnected && tb.querySelector('td')) {
    const table = tb.parentElement, w = csvWidths(m, table);
    if (table.dataset.widths !== w.join()) { csvColgroup(table, w); table.dataset.widths = w.join(); delete tb.dataset.win; }
  }
  if (virtual) {
    const theadH = tb.previousElementSibling ? tb.previousElementSibling.getBoundingClientRect().height : 0;
    const top = Math.max(0, scroll.scrollTop - theadH), view = scroll.clientHeight || window.innerHeight;
    a = Math.max(0, Math.floor(top / h) - 20);
    b = Math.min(n, Math.ceil((top + view) / h) + 20);
    const key = `${a},${b},${h}`;
    if (tb.dataset.win === key) return;
    tb.dataset.win = key;
  }
  const out = [];
  const pad = (px) => {
    const tr = el('tr', 'pad');
    tr.setAttribute('aria-hidden', 'true');
    const td = tr.appendChild(el('td'));
    td.colSpan = m.cols + 1;
    td.style.height = px + 'px';
    return tr;
  };
  if (a > 0) out.push(pad(a * h));
  for (let k = a; k < b; k++) {
    const i = m.order[k], r = m.body[i];
    const tr = el('tr');
    tr.setAttribute('aria-rowindex', String(k + 2));
    const rn = tr.appendChild(el('th', 'rn', String(i + 1)));
    rn.scope = 'row';
    for (let c = 0; c < m.cols; c++) {
      const v = r[c] === undefined ? '' : r[c];
      const td = tr.appendChild(el('td', m.numeric[c] ? 'num' : '', v));
      if (virtual && (v.length > 60 || v.includes('\n'))) td.title = v.length > 2000 ? v.slice(0, 2000) + '…' : v;
    }
    out.push(tr);
  }
  if (b < n) out.push(pad((n - b) * h));
  tb.replaceChildren(...out);
  if (virtual) {
    const first = tb.querySelector('tr:not(.pad)');
    const got = first ? first.getBoundingClientRect().height : 0;
    if (got > 0 && Math.abs(got - h) > 0.5) { m.rowH = got; delete tb.dataset.win; csvRows(m, scroll, tb, virtual); return; }
  }
  if (finder.how === 'csv' && findOpen() && tb.isConnected) { finder.ranges = null; paintFind(); }
}

function csvSortBy(col) {
  const m = csvState;
  if (!m || col < 0 || col >= m.cols) return;
  // Ascending, then descending, then the file's own order.
  m.sort = !m.sort || m.sort.col !== col ? { col, dir: 1 } : m.sort.dir > 0 ? { col, dir: -1 } : null;
  sortCsv(m);
  draw();
  const b = document.querySelector(`#doc .csv-sort[data-col="${col}"]`);
  if (b) b.focus({ preventScroll: true });
}

/** Apple's thumbnail of the file (the extension makes it with QuickLookThumbnailing): a PNG data: URL only, else nothing. */
function thumbNode(p) {
  if (typeof p.thumb !== 'string' || !p.thumb.startsWith('data:image/png;base64,')) return null;
  const img = document.createElement('img');
  img.className = 'info-thumb';
  img.alt = '';
  img.src = p.thumb;
  img.addEventListener('error', () => { if (img.isConnected) img.replaceWith(icon(p.icon, 64)); });
  return img;
}

function infoCard(p, why) {
  const card = el('div', 'viewer info-card');
  card.append(thumbNode(p) || icon(p.icon, 64), el('div', 'info-name', plainName(p.name)), el('div', 'info-kind', p.kindName || 'Document'));
  const dl = el('dl');
  // Rows the extension read from the file itself (a disk image's format and encryption), as text.
  const details = Array.isArray(p.details) ? p.details.filter((r) => Array.isArray(r) && r.length === 2 && r.every((x) => typeof x === 'string')).slice(0, 8) : [];
  for (const [k, v] of [['Size', typeof p.size === 'number' ? `${fmtSize(p.size)}${p.size >= 1000 ? ` (${p.size.toLocaleString()} bytes)` : ''}` : ''],
    ...details, ['Modified', fmtDate(p.modified)], ['Where', typeof p.folder === 'string' ? p.folder : '']]) {
    if (v) dl.append(el('dt', '', k), el('dd', '', v));
  }
  card.append(dl);
  if (why) card.append(note(why));
  // Minimal chrome's Open; the toolbar row has its own.
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

// The image on screen is fitted to the panel (scale null) or drawn at `scale` × its own size; kept across redraws of that image.
let imgScale = null, imgScalePath = '';
const IMG_MAX = 8;

function imageView(p) {
  if (p.path !== imgScalePath) { imgScale = null; imgScalePath = p.path; }
  const box = el('figure', 'viewer viewer-image');
  const stage = el('div', 'img-stage');
  const img = document.createElement('img');
  const { text: meta, zoom } = setKind(p, [fmtSize(p.size)], true);
  img.alt = p.name;
  img.draggable = false;
  img.addEventListener('load', () => {
    meta.textContent = [p.kindName, `${img.naturalWidth} × ${img.naturalHeight}`, fmtSize(p.size)].filter(Boolean).join(' · ');
    applyZoom(stage, img, zoom, imgScale);
  });
  img.addEventListener('error', () => {
    if (!box.isConnected) return;
    $('kind').replaceChildren();
    box.replaceWith(infoCard(p, 'This image can’t be shown here.'));
  });
  img.src = p.src;
  stage.append(img);
  box.append(viewHead(p), stage);
  imageControls(stage, img, zoom);
  return box;
}

/** What the image is scaled to when fitted: never above its own size. */
function fitScale(stage, img) {
  if (!img.naturalWidth || !img.naturalHeight) return 1;
  const room = parseFloat(getComputedStyle(root).getPropertyValue('--img-room')) || 150;
  const w = stage.clientWidth || $('doc').clientWidth, h = Math.max(120, window.innerHeight - room);
  return Math.min(1, w / img.naturalWidth, h / img.naturalHeight);
}

/** Draws the image at `scale` (null: fitted), keeping the point at (ax, ay) in the viewport, if given, where it was. */
function applyZoom(stage, img, label, scale, ax, ay) {
  const fit = fitScale(stage, img);
  if (scale !== null && Math.abs(scale - fit) < 0.01) scale = null;
  const before = img.getBoundingClientRect();
  imgScale = scale;
  stage.classList.toggle('zoomed', scale !== null);
  stage.classList.toggle('zoomable', scale === null && img.naturalWidth > 0);
  if (scale === null) {
    img.style.removeProperty('width');
    img.style.removeProperty('height');
  } else {
    img.style.width = Math.round(img.naturalWidth * scale) + 'px';
    img.style.height = Math.round(img.naturalHeight * scale) + 'px';
  }
  const shown = scale === null ? fit : scale;
  if (label) label.textContent = img.naturalWidth ? `${Math.round(shown * 100)}%` : '';
  stage.title = scale === null ? 'Double-click to zoom to actual size' : 'Double-click to fit. Drag to move.';
  if (scale !== null && ax !== undefined && before.width > 0) {
    const fx = Math.min(1, Math.max(0, (ax - before.left) / before.width)), fy = Math.min(1, Math.max(0, (ay - before.top) / before.height));
    const after = img.getBoundingClientRect();
    stage.scrollLeft += after.left + fx * after.width - ax;
    stage.scrollTop += after.top + fy * after.height - ay;
  }
}

/** Where a double-click goes: fitted to actual size (twice that when actual size is about the fitted size), else to fitted. */
function toggleTarget(stage, img) {
  const fit = fitScale(stage, img);
  return imgScale === null ? (fit < 0.8 ? 1 : Math.min(IMG_MAX, 2)) : null;
}

// A running zoom animation (double-click, a two-finger double tap, ⌘ keys): where it goes, and its frame request.
let imgAnim = null;
const IMG_ANIM_MS = 180;

/** Zooms to `scale` (null: fitted) about (ax, ay) in an animation, or at once when the user asks for reduced motion. */
function animateZoom(stage, img, label, scale, ax, ay) {
  if (imgAnim) cancelAnimationFrame(imgAnim.frame);
  imgAnim = null;
  const fit = fitScale(stage, img), from = imgScale === null ? fit : imgScale, to = scale === null ? fit : scale;
  if (reducedMotion.matches || Math.abs(to - from) < 0.001) return applyZoom(stage, img, label, scale, ax, ay);
  const start = performance.now(), anim = { to: scale };
  const step = (now) => {
    const t = Math.min(1, (now - start) / IMG_ANIM_MS), k = 1 - (1 - t) ** 3;
    if (!stage.isConnected) { imgAnim = null; return; }
    if (t >= 1) { imgAnim = null; applyZoom(stage, img, label, scale, ax, ay); return; }
    applyZoom(stage, img, label, from + (to - from) * k, ax, ay);
    anim.frame = requestAnimationFrame(step);
  };
  imgAnim = anim;
  anim.frame = requestAnimationFrame(step);
}

/** The zoom a step starts from: where a running animation is going, else the zoom on screen. */
function zoomFrom(stage, img) {
  const goal = imgAnim ? imgAnim.to : imgScale;
  return goal === null ? fitScale(stage, img) : goal;
}

/** A double-click toggles fitted and actual size; a drag moves a zoomed image, and so do two fingers; a pinch zooms about the
 *  pointer, and so does a wheel with ctrl. */
function imageControls(stage, img, label) {
  let drag = null, moved = false;
  const clamp = (x) => Math.min(IMG_MAX, Math.max(fitScale(stage, img), x));
  stage.addEventListener('pointerdown', (e) => {
    moved = false;
    if (e.button !== 0 || imgScale === null) return;
    drag = { x: e.clientX, y: e.clientY, l: stage.scrollLeft, t: stage.scrollTop, id: e.pointerId };
  });
  stage.addEventListener('pointermove', (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!moved && Math.hypot(dx, dy) < 4) return;
    if (!moved) { moved = true; stage.classList.add('panning'); try { stage.setPointerCapture(e.pointerId); } catch (err) { /* panning still follows the pointer over the stage */ } }
    stage.scrollLeft = drag.l - dx;
    stage.scrollTop = drag.t - dy;
  });
  const end = () => { drag = null; stage.classList.remove('panning'); };
  stage.addEventListener('pointerup', end);
  stage.addEventListener('pointercancel', end);
  stage.addEventListener('dblclick', (e) => {
    if (moved || !img.naturalWidth) return;
    e.preventDefault();
    animateZoom(stage, img, label, toggleTarget(stage, img), e.clientX, e.clientY);
  });
  // WebKit sends a pinch as gesture events and, beside them, as wheel events with ctrl; the gesture events alone drive it.
  let pinchFrom = null;
  stage.addEventListener('wheel', (e) => {
    if (!e.ctrlKey || !img.naturalWidth) return;
    e.preventDefault();
    if (pinchFrom !== null) return;
    applyZoom(stage, img, label, clamp(zoomFrom(stage, img) * Math.exp(-e.deltaY * 0.01)), e.clientX, e.clientY);
  }, { passive: false });
  stage.addEventListener('gesturestart', (e) => {
    e.preventDefault();
    if (imgAnim) { cancelAnimationFrame(imgAnim.frame); imgAnim = null; }
    pinchFrom = imgScale === null ? fitScale(stage, img) : imgScale;
  });
  stage.addEventListener('gesturechange', (e) => {
    if (pinchFrom === null || !img.naturalWidth) return;
    e.preventDefault();
    applyZoom(stage, img, label, clamp(pinchFrom * e.scale), e.clientX, e.clientY);
  });
  stage.addEventListener('gestureend', (e) => { e.preventDefault(); pinchFrom = null; });
}

/** ⌘+, ⌘− and ⌘0 (`key` '+', '-' or '0') on the image on screen, about the middle of what is shown. Whether it applied. */
function zoomImage(key) {
  if (current.view !== 'image') return false;
  const stage = document.querySelector('#doc .img-stage'), img = stage && stage.querySelector('img'), label = zoomLabel();
  if (!stage || !img || !img.naturalWidth) return false;
  const r = stage.getBoundingClientRect(), from = zoomFrom(stage, img);
  const cx = r.left + Math.min(r.width, window.innerWidth) / 2, cy = r.top + Math.min(r.height, window.innerHeight - r.top) / 2;
  let to;
  if (key === '+') to = Math.min(IMG_MAX, from * 1.25);
  else if (key === '-') to = Math.max(fitScale(stage, img), from / 1.25);
  else if (key === '0') to = null;
  else return false;
  animateZoom(stage, img, label, to, cx, cy);
  return true;
}
document.addEventListener('keydown', (e) => {
  if (!e.metaKey || e.altKey || e.ctrlKey) return;
  if (zoomImage(e.key === '=' ? '+' : e.key)) e.preventDefault();
});
window.addEventListener('resize', () => {
  const stage = document.querySelector('#doc .img-stage'), img = stage && stage.querySelector('img');
  if (stage && img && img.naturalWidth) applyZoom(stage, img, zoomLabel(), imgScale);
});

// An archive's listing (sent by the extension from the writer's bsdtar) as a tree of folders and files, built from text nodes.
const ARCHIVE_ALL_OPEN = 300;
// A crafted archive can name a path thousands of folders deep: past this depth the rest of a path is one name. Every walk of
// the tree below is a loop, not a recursion, for the same reason.
const ARCHIVE_MAX_DEPTH = 64;
/** The folders open in the archive on screen (archiveOpenPath), by path; null until its listing is first drawn. */
let archiveOpen = null;
let archiveOpenPath = null;

/** The flat listing as a tree: a folder with no entry of its own is implied by the files in it. */
function archiveTree(entries) {
  const top = { name: '', path: '', dir: true, kids: new Map(), size: null, modified: null };
  for (const e of entries) {
    if (!e || typeof e.name !== 'string') continue;
    const parts = e.name.split('/').filter((x) => x && x !== '.');
    if (parts.length > ARCHIVE_MAX_DEPTH) parts.splice(ARCHIVE_MAX_DEPTH - 1, Infinity, parts.slice(ARCHIVE_MAX_DEPTH - 1).join('∕'));
    let node = top;
    parts.forEach((part, i) => {
      const last = i === parts.length - 1;
      let k = node.kids.get(part);
      if (!k) {
        k = { name: part, path: node.path ? `${node.path}/${part}` : part, dir: !last, kids: new Map(), size: null, modified: null };
        node.kids.set(part, k);
      }
      if (!last || e.isDir === true) k.dir = true;
      if (last) {
        if (typeof e.size === 'number' && isFinite(e.size)) k.size = e.size;
        if (typeof e.modified === 'number' && isFinite(e.modified)) k.modified = e.modified;
      }
      node = k;
    });
  }
  let files = 0, folders = 0, total = 0;
  for (const k of archiveNodes(top)) if (k.dir) folders++; else { files++; total += k.size || 0; }
  return { top, files, folders, total };
}

/** Every node under `top`, in no particular order. */
function archiveNodes(top) {
  const out = [], stack = [top];
  while (stack.length) for (const k of stack.pop().kids.values()) { out.push(k); stack.push(k); }
  return out;
}

const archiveKids = (n) => [...n.kids.values()].sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : a.name.localeCompare(b.name, undefined, { numeric: true })));

/** Which folders start open: all of them in a small archive; in a large one, only a chain of lone folders from the top. */
function archiveInitialOpen(tree, count) {
  const open = new Set();
  if (count <= ARCHIVE_ALL_OPEN) { for (const k of archiveNodes(tree.top)) if (k.dir) open.add(k.path); return open; }
  let n = tree.top;
  while (n.kids.size === 1) {
    const k = n.kids.values().next().value;
    if (!k.dir) break;
    open.add(k.path);
    n = k;
  }
  return open;
}

function archiveView(p) {
  const box = el('div', 'viewer viewer-archive');
  setKind(p, [fmtSize(p.size)]);
  box.append(viewHead(p));
  if (!Array.isArray(p.entries)) {
    const wait = el('div', 'viewer-loading');
    wait.setAttribute('role', 'status');
    const spin = el('span', 'spinner');
    spin.setAttribute('aria-hidden', 'true');
    wait.append(spin, el('div', 'loading-text', 'Reading contents…'));
    box.append(wait);
    return box;
  }
  const tree = archiveTree(p.entries);
  // Folders kept open from an earlier listing of this archive count only while one of them is still in it.
  const dirs = new Set(archiveNodes(tree.top).filter((k) => k.dir).map((k) => k.path));
  if (archiveOpen && archiveOpen.size && ![...archiveOpen].some((d) => dirs.has(d))) archiveOpen = null;
  if (!archiveOpen) { archiveOpen = archiveInitialOpen(tree, p.entries.length); archiveOpenPath = p.path; }
  const plural = (n, one, many) => `${n.toLocaleString()} ${n === 1 ? one : many}`;
  const summary = [plural(tree.files, 'file', 'files'), tree.folders ? plural(tree.folders, 'folder', 'folders') : ''].filter(Boolean).join(', ');
  box.append(el('div', 'viewer-note archive-summary', [summary, tree.total ? `${fmtSize(tree.total)} uncompressed` : ''].filter(Boolean).join(' · ')));
  if (p.truncated === true) box.append(note(`Showing the first ${p.entries.length.toLocaleString()} entries.`));
  if (!tree.top.kids.size) { box.append(note('This archive is empty.')); return box; }
  const table = el('table', 'archive');
  const hr = table.appendChild(el('thead')).appendChild(el('tr'));
  ['Name', 'Size', 'Modified'].forEach((h) => hr.appendChild(el('th', '', h)));
  const tb = table.appendChild(el('tbody'));
  const stack = [];
  const push = (n, depth) => { const kids = archiveKids(n); for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], depth]); };
  push(tree.top, 0);
  while (stack.length) {
    const [k, depth] = stack.pop();
    const tr = tb.appendChild(el('tr', k.dir ? 'arc-folder' : 'arc-file'));
    const td = tr.appendChild(el('td', 'arc-name'));
    td.style.paddingLeft = `${8 + depth * 16}px`;
    const open = k.dir && archiveOpen.has(k.path);
    if (k.dir) {
      const b = el('button', 'arc-dir');
      b.type = 'button';
      b.dataset.action = 'archiveDir';
      b.dataset.path = k.path;
      b.setAttribute('aria-expanded', String(open));
      b.append(el('span', 'arc-chevron', open ? '▾' : '▸'), icon('folder'), el('span', 'arc-label', plainName(k.name)));
      td.append(b);
    } else {
      td.append(el('span', 'arc-chevron', ''), icon('other'), el('span', 'arc-label', plainName(k.name)));
    }
    tr.appendChild(el('td', 'arc-size', k.dir ? '' : fmtSize(k.size)));
    tr.appendChild(el('td', 'arc-date', fmtDate(k.modified)));
    if (open) push(k, depth + 1);
  }
  box.append(table);
  return box;
}

/** Views the extension draws natively over `.pdf-area`: a PDF (PDFKit), an HTML file (its own web view), video and audio (AVKit),
 *  RTF (AppKit's text view), the files Apple's Quick Look previews (Office, iWork, fonts, 3D), and images ImageIO decodes (bitmap). */
const NATIVE_VIEWS = new Set(['pdf', 'html', 'video', 'audio', 'rtf', 'quicklook', 'bitmap']);

/** The PDF itself is drawn by a native PDFView the extension lays over `.pdf-area`; the page only reserves the space and
 *  reports where it is (syncPdf), so WebKit's PDF plugin, and its unlabelled buttons, never load. */
function pdfView(p) {
  const box = el('div', `viewer viewer-pdf${p.view === 'audio' ? ' viewer-audio' : ''}${p.view === 'bitmap' ? ' viewer-image' : ''}`);
  // The extension's image view reports its zoom (sb.imageZoom) into the toolbar, as the page's own image viewer does.
  const dims = p.view === 'bitmap' && Number.isInteger(p.width) && Number.isInteger(p.height) ? `${p.width} × ${p.height}` : '';
  setKind(p, [dims, fmtSize(p.size)], p.view === 'bitmap');
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
  if (!area || !NATIVE_VIEWS.has(current.view)) return { path: current.path, hide: true };
  const r = area.getBoundingClientRect();
  // The sidebar shown over the page in a narrow panel, and the Aa popover, sit above the page; the native view must not.
  let left = r.left;
  const side = $('sidebar');
  if (root.classList.contains('sb-peek') && !side.hidden) left = Math.max(left, side.getBoundingClientRect().right);
  const bottom = Math.min(r.bottom, window.innerHeight);
  const c = themeColors();
  const bg = mixc(c.bg, c.fg, 0.06).map(Math.round);
  return { path: current.path, x: Math.round(left), y: Math.round(r.top), w: Math.max(0, Math.round(r.right - left)), h: Math.max(0, Math.round(bottom - r.top)),
    hide: !pop.hidden, bg, dark: (0.2126 * c.bg[0] + 0.7152 * c.bg[1] + 0.0722 * c.bg[2]) / 255 < 0.45, radius: appChrome() || current.view === 'audio' ? 8 : 0 };
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
  if (isMarkdown(p)) {
    const box = el('div', 'viewer viewer-code viewer-source');
    box.append(codeBlock(p.text, 'markdown'));
    return box;
  }
  switch (p.view) {
    case 'image': if (typeof p.src === 'string') return imageView(p); break;
    case 'pdf': case 'html': case 'video': case 'audio': case 'rtf': case 'quicklook': case 'bitmap': return pdfView(p);
    case 'loading': return loadingView(p);
    case 'overview': return overviewView(p);
    case 'json': if (typeof p.text === 'string') return jsonView(p); break;
    case 'csv': if (typeof p.text === 'string') return csvView(p); break;
    case 'archive': return archiveView(p);
    case 'code': case 'text':
      if (typeof p.text === 'string') {
        const box = el('div', 'viewer viewer-code');
        setKind(p, [fmtSize(p.size)]);
        box.append(viewHead(p));
        const t = truncNote(p);
        if (t) box.append(t);
        if (p.view === 'code' && p.lang && p.text.length > HIGHLIGHT_MAX) box.append(note('Highlighting is off for files over 512 KB.'));
        const kind = rawKind(p), pretty = kind && !rawOn(p) ? prettyText(p, kind) : null;
        if (kind && !rawOn(p) && pretty === null) box.append(note(kind === 'xml' ? 'Not well-formed XML: shown as is.' : 'Shown as is.'));
        box.append(codeBlock(pretty ?? p.text, p.view === 'code' ? p.lang : null, pretty === null && p.editable === true));
        return box;
      }
      break;
    default: break;
  }
  return infoCard(p, typeof p.note === 'string' ? p.note : undefined);
}

// ---------- the folder overview: what a folder holds, when it has no Markdown to open (text nodes only) ----------

const OVERVIEW_KINDS = [['markdown', 'Markdown file', 'Markdown files', 'markdown'], ['image', 'image', 'images', 'image'], ['pdf', 'PDF', 'PDFs', 'pdf'],
  ['media', 'video or audio file', 'video and audio files', 'media'],
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

/** The toolbar's Open button: the editor for Markdown, else what the viewer offers (Open with, or Reveal in Finder). Its label
 *  is one short word whatever the app, so the toolbar keeps its place from file to file; the tooltip names the app. */
function syncOpen(p) {
  const b = $('edit');
  const doc = isMarkdown(p);
  b.hidden = !doc && (p.view === 'overview' || p.view === 'loading' || !p.path);
  b.dataset.kind = doc ? 'doc' : 'file';
  b.dataset.action = doc ? 'edit' : p.canOpen === true ? 'openFile' : 'reveal';
  b.textContent = b.dataset.action === 'reveal' ? 'Reveal' : 'Open';
  b.title = openTitle(p, b.dataset.action);
}

/** ⌘O opens the file only in the Space helper's panel; Quick Look never passes it on. */
function openTitle(p, action) {
  if (action === 'reveal') return 'Reveal in Finder';
  const key = window.__sbHost === 'panel' ? ' (⌘O)' : '';
  if (action === 'edit') return `Open in your editor${key}`;
  return `${p.app ? openLabel(p) : p.editor === true ? 'Open in your editor' : 'Open in its default app'}${key}`;
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
// The filter's text, lower-cased, and the row the arrow keys move from (a file or a folder, by path).
let sideQuery = '';
let cursor = '';
// The filter field holding the writer's key panel ({ seq }), and the last sequence number used.
let filterSession = null;
let filterSeq = 0;
// Files the keys opened, by path, with when: their renders, and any render while one is pending, leave the cursor where the
// keys put it since.
const keyed = new Map();

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
  if (filterSession && !filterSession.find) endFilter();
  sideQuery = '';
  $('side-q').value = '';
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
  const num = (v) => (typeof v === 'number' && isFinite(v) ? v : null);
  tree.dirs.set(f.dir, { entries: entries.map((e) => ({ name: e.name, path: e.path, dir: e.dir === true, icon: typeof e.icon === 'string' ? e.icon : 'other',
    size: num(e.size), modified: num(e.modified), broken: e.broken === true })),
    more: Math.max(0, +f.more || 0), stale: false });
  requested.delete(f.dir);
  treeVersion++;
  requestFolders();
  renderSidebar();
  autoListKeys();
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
  autoListKeys();
}

/** A row's tooltip: its name, then its size and when it was modified. */
function rowTitle(e) {
  const facts = [e.dir ? '' : fmtSize(e.size), e.modified !== null && e.modified !== undefined ? `Modified ${fmtDate(e.modified)}` : ''].filter(Boolean);
  return [plainName(e.name), facts.join(' · ')].filter(Boolean).join('\n');
}

function treeRow(r) {
  const { e, depth, open } = r;
  const a = el('a', `row ${e.dir ? 'folder' : 'file'}`);
  a.href = '#';
  a.title = rowTitle(e);
  a.dataset.path = e.path;
  a.style.setProperty('--depth', depth);
  a.setAttribute('role', 'treeitem');
  a.setAttribute('aria-level', depth + 1);
  a.setAttribute('aria-setsize', r.size);
  a.setAttribute('aria-posinset', r.pos);
  const tw = el('span', 'twisty');
  if (e.dir) {
    a.dataset.dir = '1';
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
  if (e.broken) { a.classList.add('broken'); a.title = `${plainName(e.name)}\nBroken link`; a.setAttribute('aria-disabled', 'true'); }
  if (!e.dir && e.path === current.path) { a.classList.add('active'); a.setAttribute('aria-current', 'page'); }
  return a;
}

// The tree as rows ({ e, depth, open, pos, size } or a { note }), every one of them; only those in view (and a margin) are in
// the DOM, between two spacers, once there are more than SIDE_VIRTUAL. Every row is SIDE_ROW_H tall (style.css).
let sideRows = [];
let sideWin = '';
const SIDE_ROW_H = 24, SIDE_VIRTUAL = 300, SIDE_OVERSCAN = 30;

function sideNode(r) {
  if (r.e) return treeRow(r);
  const n = el('div', 'row-note', r.note);
  n.style.setProperty('--depth', r.depth);
  return n;
}

function sidePad(h) {
  const d = el('div', 'side-pad');
  d.setAttribute('aria-hidden', 'true');
  d.style.height = h + 'px';
  return d;
}

/** Puts the rows in view into the list; with `force`, even when the same rows are already there. */
function drawSideWindow(force) {
  const list = $('side-list'), n = sideRows.length;
  let a = 0, b = n;
  if (n > SIDE_VIRTUAL) {
    const h = list.clientHeight || window.innerHeight, top = Math.min(list.scrollTop, Math.max(0, n * SIDE_ROW_H - h));
    a = Math.max(0, Math.floor(top / SIDE_ROW_H) - SIDE_OVERSCAN);
    b = Math.min(n, Math.ceil((top + h) / SIDE_ROW_H) + SIDE_OVERSCAN);
  }
  const key = `${a},${b}`;
  if (!force && key === sideWin) return;
  sideWin = key;
  const nodes = [];
  if (a > 0) nodes.push(sidePad(a * SIDE_ROW_H));
  for (let i = a; i < b; i++) nodes.push(sideNode(sideRows[i]));
  if (b < n) nodes.push(sidePad((n - b) * SIDE_ROW_H));
  list.replaceChildren(...nodes);
  markCursor();
}
let sideScrollQueued = false;
$('side-list').addEventListener('scroll', () => {
  if (sideScrollQueued || sideRows.length <= SIDE_VIRTUAL) return;
  sideScrollQueued = true;
  requestAnimationFrame(() => { sideScrollQueued = false; drawSideWindow(false); });
}, { passive: true });

function renderSidebar() {
  const on = !!tree.root;
  $('sidebar').hidden = !on;
  $('side-toggle').hidden = !on;
  syncToggle();
  syncSideMenu();
  const key = `${treeVersion}\n${current.path}\n${sideQuery}`;
  if (!on || key === sideDrawn) return;
  const moved = sideDrawn.split('\n')[1] !== current.path, refiltered = sideDrawn.split('\n')[2] !== sideQuery;
  sideDrawn = key;
  $('side-head').textContent = tree.name;
  $('side-head').title = `${tree.root}\nClick for an overview of this folder`;
  const list = $('side-list');
  const rows = [];
  const exp = expanded();
  const walk = (dir, depth) => {
    const d = tree.dirs.get(dir);
    if (!d) {
      if (depth) rows.push({ note: 'Loading…', depth });
      return;
    }
    d.entries.forEach((e, i) => {
      const open = e.dir && exp.has(e.path);
      rows.push({ e, depth, open, pos: i + 1, size: d.entries.length });
      if (open && depth < 64) walk(e.path, depth + 1);
    });
    if (d.more && depth) rows.push({ note: `${d.more.toLocaleString()} more not listed`, depth });
  };
  // Filtered: every listed folder is searched, expanded or not, and a folder stays while anything in it matches. Nothing new
  // is listed for it, so a folder past the cap is searched in its listed part only, and the list says so.
  let partial = false;
  const find = (dir, depth) => {
    const d = tree.dirs.get(dir), out = [];
    if (d && d.more) partial = true;
    for (const e of d ? d.entries : []) {
      const kids = e.dir && depth < 64 ? find(e.path, depth + 1) : [];
      if (kids.length || matches(e.name, sideQuery)) out.push({ e, depth, open: kids.length > 0 }, ...kids);
    }
    return out;
  };
  if (sideQuery) {
    rows.push(...find(tree.root, 0));
    // Filtered rows are numbered among the rows shown at their level under the same parent.
    const seen = new Map();
    for (const r of rows) { const k = parentOf(r.e.path); r.pos = (seen.get(k) || 0) + 1; seen.set(k, r.pos); }
    for (const r of rows) r.size = seen.get(parentOf(r.e.path));
    if (!rows.length) rows.push({ note: 'No matches', depth: 0 });
    if (partial) rows.push({ note: 'Only listed files were searched', depth: 0 });
  } else walk(tree.root, 0);
  const hadActive = sideRows.some((r) => r.e && r.e.path === current.path);
  sideRows = rows;
  const top = tree.dirs.get(tree.root);
  $('side-more').hidden = !(top && top.more) || !!sideQuery;
  $('side-more').textContent = top && top.more ? `${top.more.toLocaleString()} more not listed` : '';
  // Keep the document on screen in view; the list scrolls on its own, never the page.
  const at = sideRows.findIndex((r) => r.e && !r.e.dir && r.e.path === current.path);
  for (const [p, t] of keyed) if (performance.now() - t > 2000) keyed.delete(p);
  if (moved && !keyed.delete(current.path) && !keyed.size) cursor = current.path;
  // The list is drawn at its new height first: a scrollTop set while it still holds fewer rows would be clamped. A folder
  // opened or closed above the document leaves the list where it is.
  drawSideWindow(true);
  const y = at * SIDE_ROW_H;
  const off = y < list.scrollTop || y + SIDE_ROW_H > list.scrollTop + list.clientHeight;
  if (at >= 0 && (moved || ((refiltered || !hadActive) && off))) {
    list.scrollTop = Math.max(0, y - list.clientHeight / 3);
    drawSideWindow(false);
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
  // The filter must not keep the keyboard for a sidebar that is gone: collapsed, peeked away, or narrowed out of view.
  if (!open && filterSession && !filterSession.find) endFilter();
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

// ---------- the sidebar's filter and keys ----------

/** Case-insensitive, and fuzzy: the query's characters in order anywhere in the name, so "rdme" finds README.md. */
function matches(name, q) {
  const want = [...q];
  let i = 0;
  for (const c of name.toLowerCase()) if (c === want[i] && ++i === want.length) return true;
  return !want.length;
}

const filterField = $('side-q');
filterField.addEventListener('input', () => {
  sideQuery = filterField.value.trim().toLowerCase();
  renderSidebar();
});

function markCursor() {
  for (const r of $('side-list').querySelectorAll('a.row')) {
    const on = r.dataset.path === cursor;
    r.classList.toggle('cursor', on);
    if (on) r.setAttribute('aria-selected', 'true'); else r.removeAttribute('aria-selected');
  }
}

/** Scrolls the list, never the page, just enough to show the row, and draws the rows now in view. */
function revealRow(r) {
  const list = $('side-list'), y = sideRows.indexOf(r) * SIDE_ROW_H;
  if (y < 0) return;
  if (y < list.scrollTop) list.scrollTop = y;
  else if (y + SIDE_ROW_H > list.scrollTop + list.clientHeight) list.scrollTop = y + SIDE_ROW_H - list.clientHeight;
  drawSideWindow(false);
}

// A held arrow key moves the cursor at the key-repeat rate and opens the file it stops on.
let openTimer = 0;
function moveCursor(r, open, repeat) {
  cursor = r.e.path;
  revealRow(r);
  markCursor();
  clearTimeout(openTimer);
  if (!open || r.e.dir || r.e.broken || cursor === current.path) return;
  const path = cursor;
  keyed.set(path, performance.now());
  const go = () => { peek(false); post({ type: 'open', path }); };
  if (repeat) openTimer = setTimeout(go, 90); else go();
}

/** One of Finder's keys for the tree, by KeyboardEvent key name; false when it does nothing here. */
function sideKey(key, inFilter, repeat) {
  if (editing || !pop.hidden || !sidePop.hidden || !tree.root || !sidebarShown()) return false;
  const rows = sideRows.filter((x) => x.e);
  if (!rows.length) return false;
  const i = rows.findIndex((x) => x.e.path === cursor);
  const r = rows[i];
  const step = (d) => rows[i < 0 ? (d > 0 ? 0 : rows.length - 1) : Math.min(rows.length - 1, Math.max(0, i + d))];
  switch (key) {
    case 'ArrowDown': moveCursor(step(1), true, repeat); break;
    case 'ArrowUp': moveCursor(step(-1), true, repeat); break;
    case 'Home': moveCursor(rows[0], true, false); break;
    case 'End': moveCursor(rows[rows.length - 1], true, false); break;
    case 'ArrowRight':
      if (!r || !r.e.dir) return false;
      // Filtered, a folder shows what matches whether or not it is open: the arrows only move, never open or close one.
      if (sideQuery) {
        if (rows[i + 1] && rows[i + 1].depth > r.depth) moveCursor(rows[i + 1], true, false);
        else return false;
        break;
      }
      if (!r.open) toggleFolder(r.e.path);
      else if (rows[i + 1] && rows[i + 1].depth > r.depth) moveCursor(rows[i + 1], true, false);
      break;
    case 'ArrowLeft': {
      if (!r) return false;
      if (!sideQuery && r.e.dir && expanded().has(r.e.path) && r.open) { toggleFolder(r.e.path); break; }
      const up = rows.find((x) => x.e.path === parentOf(r.e.path));
      if (!up) return false;
      moveCursor(up, false, false);
      break;
    }
    case 'Enter':
      if (!r) { if (inFilter) moveCursor(rows[0], true, false); else return false; }
      else if (r.e.dir) toggleFolder(r.e.path);
      else moveCursor(r, true, false);
      break;
    default: return false;
  }
  $('side-list').classList.add('keyed');
  return true;
}

// The keys, when the page has the keyboard: never during an edit (the writer's panel has it then), with the Aa popover open, or
// in a field other than the filter, which passes on only ↑, ↓ and Return. Space is never taken: Quick Look closes on it.
document.addEventListener('keydown', (e) => {
  if (e.defaultPrevented || e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
  const inFilter = e.target === filterField;
  if (inFilter && e.key === 'Escape' && !editing) {
    e.preventDefault();
    if (filterField.value) { filterField.value = ''; sideQuery = ''; renderSidebar(); } else filterField.blur();
    return;
  }
  if (inFilter ? !['ArrowUp', 'ArrowDown', 'Enter'].includes(e.key) : e.target instanceof Element && e.target.closest('input, textarea, select, [contenteditable]')) return;
  if (sideKey(e.key, inFilter, e.repeat)) e.preventDefault();
});

// In Quick Look the page never gets keys, so a click in the filter field asks the writer's key panel (the one inline editing
// uses) to hold them over the field: it sends back the text and the list keys, and Esc on an empty field, a click outside the
// sidebar, an edit, or another preview ends it. Return opens a file and keeps the field, like the arrows do.
const FILTER_KEYS = { up: 'ArrowUp', down: 'ArrowDown', home: 'Home', end: 'End', return: 'Enter', left: 'ArrowLeft', right: 'ArrowRight' };
// ⌘F, ⌥⌘F and ⌘C while a list session holds the keys.
const LIST_COMMANDS = new Set(['find', 'filter', 'copy']);

function beginFilter(e) {
  if (filterSession && (filterSession.list || filterSession.find)) endFilter();
  if (filterSession || editing || !tree.root) return;
  if (updateBusy) { window.sb.status('Updating…'); return; }
  const r = filterField.getBoundingClientRect();
  filterSession = { seq: ++filterSeq };
  filterField.classList.add('held');
  post({ type: 'filterBegin', seq: filterSession.seq, text: filterField.value, clickX: e.clientX - r.left, clickY: e.clientY - r.top,
    width: r.width, height: r.height });
}

// A real click on a row asks for the same panel with no field (a list session): ↑ ↓ ← → Home End Return then move through the
// tree. Esc, Space (Quick Look's key: the next Space closes the preview), a click outside the sidebar or anything that ends a
// filter ends it. A filter session already holding the keys keeps them.
function beginListKeys(e, r) {
  if (filterSession && !filterSession.list) return;
  if (editing || !tree.root || updateBusy || !sidebarShown()) return;
  endFilter();
  filterSession = { seq: ++filterSeq, list: true };
  post({ type: 'filterBegin', list: true, seq: filterSession.seq, clickX: e.clientX - r.left, clickY: e.clientY - r.top, width: r.width, height: r.height });
}

// Quick Look showing the preview (again), or an edit or filter let go with Esc, asks for a list session no click began, so the
// arrows move through the sidebar at once instead of Finder's selection. It waits for the tree of that root to be listed, then
// starts only with the sidebar on screen and more than one row to move through.
let autoKeysRoot = '';
function autoListKeys() {
  if (!autoKeysRoot || autoKeysRoot !== tree.root) return;
  const d = tree.dirs.get(tree.root);
  if (!d || d.stale) return;
  autoKeysRoot = '';
  if (settings.sidebarKeys === false || filterSession || editing || updateBusy || !sidebarShown()) return;
  if (sideRows.filter((x) => x.e).length < 2) return;
  const r = ($('side-list').querySelector('a.cursor') || $('side-list')).getBoundingClientRect();
  filterSession = { seq: ++filterSeq, list: true, auto: true };
  post({ type: 'filterBegin', list: true, auto: true, seq: filterSession.seq, clickX: 0, clickY: 0, width: r.width, height: Math.min(r.height, SIDE_ROW_H) });
}

function endFilter() {
  if (!filterSession) return;
  post({ type: 'filterStop', seq: filterSession.seq });
  filterDone();
}

function filterDone() {
  filterSession = null;
  filterField.classList.remove('held');
  findField.classList.remove('held');
  // Esc in the writer's panel ends the session; the page never sees that key, so the sort menu opened meanwhile closes here.
  if (!sidePop.hidden) showSideMenu(false);
}

const ofFilter = (m) => !!m && !!filterSession && m.seq === filterSession.seq;
Object.assign(window.sb, {
  filterText(m) {
    if (!ofFilter(m) || filterSession.list || typeof m.text !== 'string') return;
    // The writer sends the text again before each ↵; only a change searches again.
    if (filterSession.find) { findField.value = m.text; if (m.text !== finder.q) findInput(m.text); return; }
    filterField.value = m.text;
    sideQuery = m.text.trim().toLowerCase();
    renderSidebar();
  },
  filterKey(m) {
    if (!ofFilter(m)) return;
    if (filterSession.find) { if (m.key === 'next' || m.key === 'prev') findStep(m.key === 'next' ? 1 : -1); return; }
    if (filterSession.list && LIST_COMMANDS.has(m.key)) { hostCommand(m.key); return; }
    if (!Object.hasOwn(FILTER_KEYS, m.key) || (!filterSession.list && (m.key === 'left' || m.key === 'right'))) return;
    sideKey(FILTER_KEYS[m.key], !filterSession.list, m.repeat === true);
  },
  listKeysWanted(m) {
    autoKeysRoot = m && typeof m.root === 'string' ? m.root : '';
    autoListKeys();
  },
  /** One session's end, or with `all` any session: a new preview's controller never began the one the page may hold. Esc in
   *  the find field closes the find bar. */
  filterEnd(m) {
    if (!ofFilter(m) && !(m && m.all === true && filterSession)) return;
    const find = filterSession.find;
    filterDone();
    if (find && m.reason === 'escape') closeFind();
  },
});
document.addEventListener('click', (e) => { if (filterSession && !e.target.closest(filterSession.find ? '#find' : '#sidebar')) endFilter(); }, true);

// The Space helper's panel is never key either: the helper takes Finder's keys and the panel sends them here. The list keys
// reach the sidebar through filterKey while a list session holds them (it starts on its own, as in Quick Look); these are the
// rest. Space and Esc close the panel in one press, so it never says "Press Space again".
const HOST = window.__sbHost === 'panel' ? 'panel' : 'quicklook';
const HOST_ZOOM = { zoomIn: '+', zoomOut: '-', zoomReset: '0' };
Object.assign(window.sb, {
  /** A list session ended with none after it: in Quick Look, Esc or Space gave the keys back, and the next Space closes. */
  listEnded(m) {
    if (HOST === 'quicklook' && m && m.reason === 'escape') window.sb.status('Press Space again to close');
  },
  /** A key the panel sends outside a list session. Returns whether the page used it; the panel zooms the page itself if not. */
  hostKey(m) {
    const key = m && m.key;
    if (HOST !== 'panel' || typeof key !== 'string') return false;
    if (LIST_COMMANDS.has(key)) return hostCommand(key);
    if (Object.hasOwn(HOST_ZOOM, key)) return zoomImage(HOST_ZOOM[key]);
    const page = Math.max(40, window.innerHeight * 0.9), max = document.scrollingElement.scrollHeight;
    const by = { up: -40, down: 40, pageup: -page, pagedown: page, home: -max, end: max }[key];
    if (by === undefined) return false;
    window.scrollBy({ top: by, behavior: 'instant' });
    return true;
  },
});

// ---------- the toolbar's tools: Formatted or Raw, Find and Copy, each shown only for the views they apply to ----------

// The Raw toggle's panel key for each kind of formatted view. Raw is always the file's own text, read only, in the code view.
const RAW_KEYS = { markdown: 'rawMarkdown', json: 'rawJSON', notebook: 'rawNotebook', csv: 'rawCSV', xml: 'rawXML', css: 'rawCSS' };
const RAW_NAMES = { markdown: 'Markdown source', json: 'raw JSON', notebook: 'raw JSON', csv: 'raw text', xml: 'raw XML', css: 'raw CSS' };
const FORMATTED_NAMES = { markdown: 'rendered', json: 'tree', notebook: 'cells', csv: 'table', xml: 'indented', css: 'laid out' };
const XML_FILES = /\.(xml|plist|xsd|xslt?)$/i;
const minified = (t) => t.length > 2000 && t.length / Math.max(1, lineCount(t)) > 300;
const hasText = (p) => !!p.path && typeof p.text === 'string' && (isMarkdown(p) || TEXT_VIEWS.has(p.view) || p.view === 'csv');

/** The kind of formatted view `p` is shown in, with the file's text behind it; '' when the view is that text already. */
function rawKind(p) {
  if (!hasText(p)) return '';
  if (isMarkdown(p)) return 'markdown';
  if (p.view === 'csv') return 'csv';
  if (p.view === 'json') { const m = jsonModel(p); return m.mode === 'text' ? '' : m.nb ? 'notebook' : 'json'; }
  if (p.view !== 'code' || p.truncated) return '';
  if (p.lang === 'xml' && XML_FILES.test(p.name || '')) return 'xml';
  if (p.lang === 'css' && minified(p.text)) return 'css';
  return '';
}
const rawOn = (p) => { const k = rawKind(p); return !!k && settings[RAW_KEYS[k]] === true; };

function syncRaw(p) {
  const b = $('raw'), k = rawKind(p), on = rawOn(p);
  b.hidden = !k;
  b.setAttribute('aria-pressed', String(on));
  b.title = `Show ${(on ? FORMATTED_NAMES : RAW_NAMES)[k] || 'raw text'}`;
}

function syncTools(p) {
  const text = hasText(p);
  $('copy').hidden = !text;
  $('find-btn').hidden = !text;
  if (!text) closeFind();
  syncRaw(p);
}

$('raw').addEventListener('click', () => {
  const k = rawKind(current);
  if (!k) return;
  if (editing) stopEditing();
  choose(RAW_KEYS[k], settings[RAW_KEYS[k]] !== true);
});

let prettyMemo = { p: null, kind: '', text: null };
/** The formatted text of an XML file or a minified stylesheet, made once per payload; null when it cannot be made. */
function prettyText(p, kind) {
  if (prettyMemo.p !== p || prettyMemo.kind !== kind) prettyMemo = { p, kind, text: kind === 'xml' ? prettyXML(p.text) : prettyCSS(p.text) };
  return prettyMemo.text;
}

/** XML indented two spaces a level: a tag, comment or declaration to a line, an element holding only text on one line. A
 *  scan of the text, never a parse into a document, so no entity is expanded and nothing loads; null when the tags do not nest. */
function prettyXML(text) {
  const tok = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[^[>]*(?:\[[\s\S]*?\][^[>]*)?>|<\/?[A-Za-z_:][^<>"']*(?:(?:"[^"]*"|'[^']*')[^<>"']*)*>|[^<]+/y;
  const out = [], open = [];
  const pad = () => '  '.repeat(open.length);
  let pos = 0;
  while (pos < text.length) {
    tok.lastIndex = pos;
    const m = tok.exec(text);
    if (!m) return null;
    const t = m[0];
    pos = tok.lastIndex;
    if (t[0] !== '<') { if (t.trim()) out.push(pad() + t.replace(/^\s*\n|\n\s*$/g, '')); continue; }
    if (t[1] === '!' || t[1] === '?') { out.push(pad() + t); continue; }
    const name = /^<\/?\s*([^\s/>]+)/.exec(t)[1];
    if (t[1] === '/') {
      if (open.pop() !== name) return null;
      out.push(pad() + t);
      continue;
    }
    if (/\/\s*>$/.test(t)) { out.push(pad() + t); continue; }
    const lt = text.indexOf('<', pos), gt = lt < 0 ? -1 : text.indexOf('>', lt);
    if (gt > 0 && text.startsWith('</' + name, lt) && !text.slice(lt + 2 + name.length, gt).trim()) {
      out.push(pad() + t + text.slice(pos, lt) + text.slice(lt, gt + 1));
      pos = gt + 1;
      continue;
    }
    out.push(pad() + t);
    open.push(name);
  }
  return open.length ? null : out.join('\n') + '\n';
}

/** A minified stylesheet laid out: a selector and each declaration to a line, indented by nesting. Strings, comments and
 *  parentheses (url(), calc()) are kept whole. */
function prettyCSS(text) {
  const tok = /\/\*[\s\S]*?(?:\*\/|$)|"(?:[^"\\]|\\[\s\S])*(?:"|$)|'(?:[^'\\]|\\[\s\S])*(?:'|$)|[{};]|\s+|(?:[^{};"'/\s()]|\((?:[^()"']|"(?:[^"\\]|\\[\s\S])*"|'(?:[^'\\]|\\[\s\S])*')*\))+|[\s\S]/y;
  const out = [];
  let line = '', depth = 0, pos = 0;
  const flush = () => { if (line.trim()) out.push('  '.repeat(depth) + line.trim()); line = ''; };
  while (pos < text.length) {
    tok.lastIndex = pos;
    const t = tok.exec(text)[0];
    pos = tok.lastIndex;
    if (t === '{') { line += ' {'; flush(); depth++; } else if (t === ';') { line += ';'; flush(); } else if (t === '}') {
      flush();
      depth = Math.max(0, depth - 1);
      out.push('  '.repeat(depth) + '}');
      if (!depth) out.push('');
    } else if (t.startsWith('/*')) { flush(); out.push('  '.repeat(depth) + t); } else if (/^\s+$/.test(t)) { if (line) line += ' '; } else line += t;
  }
  flush();
  return out.join('\n').replace(/\n+$/, '') + '\n';
}

// ---------- find in the file ----------
// Where a view draws only part of its model (a long table's rows in view, a JSON tree's open nodes) the model is searched and
// a match is scrolled into view before it is drawn; anywhere else, the text on screen. Matches are drawn with the CSS Custom
// Highlight API: the sanitized DOM is never changed.
const FIND_MAX = 10000;
// Matches drawn at once, those on and near the screen: WebKit repaints every registered range on each frame.
const FIND_PAINT = 150;
const FIND_SKIP = '.viewer-head, .viewer-note, .gutter, .katex-mathml, .md-editing, pre.mermaid, svg, button, .jt-sum';
const findBar = $('find'), findField = $('find-q');
const highlights = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight === 'function' ? CSS.highlights : null;
// q: the text looked for; how: 'dom', 'csv' or 'json'; hits: { s, e } in the text (dom), with { k, c } a table cell (k -1 the
// header) or { ptr, part } a JSON row's key or value; at: the current match, -1 before the first step.
let finder = { q: '', path: '', how: 'dom', hits: [], at: -1, more: false, index: null, ranges: null };
let findTimer = 0, findQuiet = false;
const findOpen = () => !findBar.hidden;
const reEscape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const jsonLeaf = (v) => (typeof v === 'string' ? JSON.stringify(v.length > JSON_STR_MAX ? v.slice(0, JSON_STR_MAX) + '…' : v) : String(v));

function findHow() {
  if (current.view === 'csv' && !rawOn(current) && csvState && csvState.p === current && csvState.shown) return 'csv';
  if (current.view === 'json' && !rawOn(current) && jsonState && jsonState.p === current && jsonState.mode === 'tree') return 'json';
  return 'dom';
}

/** The text on screen as one string, and where each of its text nodes starts in it. */
function domIndex() {
  const code = $('doc').querySelector(':scope > .viewer > .code-view pre.code > code');
  const nodes = [], starts = [], parts = [];
  const walk = document.createTreeWalker(code || $('doc'), NodeFilter.SHOW_TEXT, code ? null
    : { acceptNode: (n) => (n.parentElement && n.parentElement.closest(FIND_SKIP) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT) });
  let len = 0;
  while (walk.nextNode()) {
    const n = walk.currentNode;
    if (!n.data) continue;
    nodes.push(n);
    starts.push(len);
    parts.push(n.data);
    len += n.data.length;
  }
  return { nodes, starts, text: parts.join('') };
}

function domRange(ix, s, e) {
  const node = (off, end) => {
    let lo = 0, hi = ix.starts.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (end ? ix.starts[mid] < off : ix.starts[mid] <= off) lo = mid; else hi = mid - 1; }
    return lo;
  };
  const a = node(s, false), b = node(e, true), r = document.createRange();
  r.setStart(ix.nodes[a], s - ix.starts[a]);
  r.setEnd(ix.nodes[b], e - ix.starts[b]);
  return r;
}

function csvFind(m, scan) {
  for (let c = 0; c < m.head.length && c < m.cols; c++) if (m.head[c] && !scan(m.head[c], (s, e) => ({ k: -1, c, s, e }))) return;
  for (let k = 0; k < m.order.length; k++) {
    const r = m.body[m.order[k]];
    for (let c = 0; c < m.cols; c++) if (r[c] && !scan(r[c], (s, e) => ({ k, c, s, e }))) return;
  }
}

/** Keys and values in the order the tree shows them, each as its row shows it. */
function jsonFind(m, scan) {
  const stack = [{ ptr: '', key: null, index: false, v: m.value }];
  while (stack.length) {
    const it = stack.pop();
    if (it.key !== null && !scan(it.index ? String(it.key) : JSON.stringify(String(it.key)), (s, e) => ({ ptr: it.ptr, part: 'key', s, e }))) return;
    if (isBranch(it.v)) {
      const arr = Array.isArray(it.v), keys = arr ? null : Object.keys(it.v);
      for (let i = (arr ? it.v.length : keys.length) - 1; i >= 0; i--) {
        const k = arr ? i : keys[i];
        stack.push({ ptr: `${it.ptr}/${ptrKey(k)}`, key: k, index: arr, v: it.v[k] });
      }
    } else if (!scan(jsonLeaf(it.v), (s, e) => ({ ptr: it.ptr, part: 'val', s, e }))) return;
  }
}

/** Searches again for finder.q; `keep` keeps the current match's number (a redraw), else the first match is current. */
function findSearch(keep) {
  const f = finder;
  f.how = findHow();
  f.hits = [];
  f.more = false;
  f.index = null;
  f.ranges = null;
  if (f.q) {
    const re = new RegExp(reEscape(f.q), 'gi');
    const scan = (text, hit) => {
      re.lastIndex = 0;
      for (let m; (m = re.exec(text));) {
        if (f.hits.length >= FIND_MAX) { f.more = true; return false; }
        f.hits.push(hit(m.index, m.index + m[0].length));
      }
      return true;
    };
    if (f.how === 'csv') csvFind(csvState, scan);
    else if (f.how === 'json') jsonFind(jsonState, scan);
    else { f.index = domIndex(); scan(f.index.text, (s, e) => ({ s, e })); }
  }
  // A redraw of the same file keeps the current match's number; another file starts before its first match.
  f.at = !f.hits.length ? -1 : !keep ? 0 : f.path === current.path ? Math.min(f.at, f.hits.length - 1) : -1;
  f.path = current.path;
}

/** The matches that can be drawn now: `keys`, their numbers in order, and `get(i)`, a range. Every match of the text on screen
 *  (each range made when asked for, so few are ever alive), or those in the table rows or tree rows drawn (kept until the
 *  next search or redraw). */
function findRanges() {
  const f = finder;
  if (f.how === 'dom') return { keys: f.hits.map((_, i) => i), get: (i) => (f.hits[i] ? domRange(f.index, f.hits[i].s, f.hits[i].e) : undefined) };
  if (f.ranges) return f.ranges;
  const out = new Map();
  const range = (node, h) => {
    if (!node || node.nodeType !== 3 || h.e > node.length) return null;
    const r = document.createRange();
    r.setStart(node, h.s);
    r.setEnd(node, h.e);
    return r;
  };
  if (f.how === 'csv') {
    const box = csvState.shown.scroll, rows = new Map();
    for (const tr of box.querySelectorAll('tbody tr[aria-rowindex]')) rows.set(+tr.getAttribute('aria-rowindex') - 2, tr);
    f.hits.forEach((h, i) => {
      const cell = h.k < 0 ? box.querySelector(`thead .csv-sort[data-col="${h.c}"] .csv-h`) : rows.has(h.k) && rows.get(h.k).cells[h.c + 1];
      const r = cell && range(cell.firstChild, h);
      if (r) out.set(i, r);
    });
  } else {
    const rows = new Map();
    for (const row of $('doc').querySelectorAll('.json-tree .jt-row[data-ptr]')) rows.set(row.dataset.ptr, row);
    f.hits.forEach((h, i) => {
      const row = rows.get(h.ptr), span = row && row.querySelector(h.part === 'key' ? '.jt-key, .jt-index' : '.jt-val');
      const r = span && range(span.firstChild, h);
      if (r) out.set(i, r);
    });
  }
  f.ranges = { keys: [...out.keys()], get: (i) => out.get(i) };
  return f.ranges;
}

/** The match numbers among `ranges` on screen or within a screen of it, found by their position (matches run top to bottom). */
function visibleMatches(ranges) {
  const idx = ranges.keys;
  if (idx.length <= FIND_PAINT) return idx;
  const rect = (i) => ranges.get(idx[i]).getBoundingClientRect();
  let lo = 0, hi = idx.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (rect(mid).bottom < -innerHeight) lo = mid + 1; else hi = mid; }
  const out = [];
  for (let i = lo; i < idx.length && out.length < FIND_PAINT && rect(i).top <= 2 * innerHeight; i++) out.push(idx[i]);
  return out;
}

function paintFind() {
  const ranges = findRanges(), cur = ranges.get(finder.at);
  if (highlights) {
    highlights.set('sb-find', new Highlight(...visibleMatches(ranges).filter((i) => i !== finder.at).map((i) => ranges.get(i))));
    const h = cur ? new Highlight(cur) : new Highlight();
    h.priority = 1;
    highlights.set('sb-find-cur', h);
  }
  return cur;
}

function findLabel() {
  const n = finder.hits.length, more = finder.more ? '+' : '';
  $('find-count').textContent = !finder.q ? '' : !n ? 'No matches'
    : finder.at < 0 ? `${n.toLocaleString()}${more} ${n === 1 ? 'match' : 'matches'}` : `${(finder.at + 1).toLocaleString()} of ${n.toLocaleString()}${more}`;
}

/** Opens a JSON match's ancestors and shows enough of each to reach it; whether the tree must be drawn again. */
function jsonReveal(m, ptr) {
  let v = m.value, at = '', changed = false;
  for (const part of ptr.split('/').slice(1)) {
    if (!m.open.has(at)) { m.open.add(at); changed = true; }
    const key = part.replace(/~1/g, '/').replace(/~0/g, '~');
    const i = Array.isArray(v) ? +key : Object.keys(v).indexOf(key);
    if (i >= (m.more.get(at) || JSON_CHUNK)) { m.more.set(at, Math.ceil((i + 1) / JSON_CHUNK) * JSON_CHUNK); changed = true; }
    v = v[key];
    at = `${at}/${part}`;
  }
  return changed;
}

/** Scrolls a windowed table to a match's row, draws the rows now in view, and puts the row a third of the way down. */
function csvReveal(m, h) {
  const { scroll, draw: rows } = m.shown;
  if (!scroll.isConnected) return;
  const r0 = scroll.getBoundingClientRect();
  if (r0.top < 0 || r0.bottom > innerHeight) scroll.scrollIntoView({ block: 'nearest' });
  if (h.k < 0) { scroll.scrollTop = 0; rows(); return; }
  const head = scroll.querySelector('thead'), headH = head ? head.getBoundingClientRect().height : 0;
  const tr = () => scroll.querySelector(`tbody tr[aria-rowindex="${h.k + 2}"]`);
  if (!tr()) { scroll.scrollTop = Math.max(0, headH + h.k * (m.rowH || 26) - scroll.clientHeight / 3); rows(); }
  const t = tr();
  if (!t) return;
  const b = t.getBoundingClientRect(), s = scroll.getBoundingClientRect();
  if (b.top < s.top + headH || b.bottom > s.bottom) { scroll.scrollTop += b.top - s.top - headH - (s.height - headH) / 3; rows(); }
}

/** Scrolls a match into view: sideways in a box that scrolls on its own (code, a table, the tree), then the page. */
function revealRange(r) {
  if (!r.getClientRects().length) return;
  const node = r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement;
  const box = node && node.closest('.code-view, .csv-scroll, .json-tree');
  let b = r.getBoundingClientRect();
  if (box && box.scrollWidth > box.clientWidth) {
    const bb = box.getBoundingClientRect(), side = box.querySelector(':scope > .gutter, th.rn');
    const left = bb.left + (side ? side.getBoundingClientRect().width : 0);
    if (b.left < left + 8 || b.right > bb.right - 8) { box.scrollLeft += b.left - left - (bb.right - left) / 3; b = r.getBoundingClientRect(); }
  }
  if (b.top < 96 || b.bottom > innerHeight - 24) window.scrollBy({ top: b.top - Math.max(96, innerHeight / 3), behavior: 'instant' });
}

/** Makes match `i` (wrapping around) current, scrolls to it and draws the matches. */
function findGo(i) {
  const f = finder, n = f.hits.length;
  if (!n) return findLabel();
  f.at = ((i % n) + n) % n;
  const h = f.hits[f.at];
  if (f.how === 'csv') csvReveal(csvState, h);
  else if (f.how === 'json' && jsonReveal(jsonState, h.ptr)) {
    findQuiet = true;
    try { draw(); } finally { findQuiet = false; }
    f.ranges = null;
  }
  const cur = paintFind();
  if (cur) {
    revealRange(cur);
    if (!highlights) { const sel = getSelection(); sel.removeAllRanges(); sel.addRange(cur); }
  }
  findLabel();
}

/** The field's text changed: every key searches at once in a small file; in a large one, once the typing pauses. */
function findInput(q) {
  finder.q = q;
  clearTimeout(findTimer);
  findTimer = 0;
  const run = () => { findTimer = 0; if (!findOpen()) return; findSearch(false); if (finder.at >= 0) findGo(finder.at); else { paintFind(); findLabel(); } };
  if (current.text && current.text.length > 256 * 1024) findTimer = setTimeout(run, 120); else run();
}

function findStep(d) {
  if (!findOpen()) return;
  if (findTimer) {
    clearTimeout(findTimer);
    findTimer = 0;
    findSearch(false);
    if (finder.at >= 0) return findGo(0);
    paintFind();
    return findLabel();
  }
  const n = finder.hits.length;
  if (n) findGo(finder.at < 0 ? (d > 0 ? 0 : n - 1) : finder.at + d);
}

/** After every draw: the matches are found again in what is now on screen, and the current one keeps its number. */
function findAfterDraw() {
  if (!findOpen() || findQuiet) return;
  if (!hasText(current)) return closeFind();
  findSearch(true);
  paintFind();
  findLabel();
}

/** Shows the find bar; with `keys` its field asks for the writer's key panel (the page itself never has the keyboard). */
function openFind(keys = true) {
  if (!hasText(current)) return false;
  if (editing) stopEditing();
  if (!findOpen()) {
    findBar.hidden = false;
    $('find-btn').setAttribute('aria-expanded', 'true');
    if (!pop.hidden) showPopover(false);
    findField.value = finder.q;
    findSearch(false);
    paintFind();
    findLabel();
  }
  // Only a page with the keyboard (a browser) types into the field itself; in the hosts the key panel does.
  if (document.hasFocus()) { findField.focus({ preventScroll: true }); findField.select(); }
  if (keys) beginFind();
  return true;
}

function closeFind() {
  if (!findOpen()) return;
  findBar.hidden = true;
  $('find-btn').setAttribute('aria-expanded', 'false');
  clearTimeout(findTimer);
  findTimer = 0;
  if (filterSession && filterSession.find) endFilter();
  if (document.activeElement === findField) findField.blur();
  Object.assign(finder, { hits: [], at: -1, more: false, index: null, ranges: null });
  if (highlights) { highlights.delete('sb-find'); highlights.delete('sb-find-cur'); }
}

/** The find field holding the writer's key panel, as the sidebar's filter does: its text comes back through sb.filterText,
 *  ↵ and ⇧↵ (⌘G, ⇧⌘G) through sb.filterKey as next and prev, and Esc closes the bar. */
function beginFind() {
  if (filterSession && filterSession.find) return;
  if (editing || updateBusy) return;
  if (filterSession) endFilter();
  const r = findField.getBoundingClientRect();
  filterSession = { seq: ++filterSeq, find: true };
  findField.classList.add('held');
  post({ type: 'filterBegin', find: true, seq: filterSession.seq, text: findField.value, clickX: r.width / 2, clickY: r.height / 2, width: r.width, height: r.height });
}

findField.addEventListener('input', () => findInput(findField.value));
let findScrollQueued = false;
window.addEventListener('scroll', () => {
  if (findScrollQueued || !findOpen() || finder.hits.length <= FIND_PAINT) return;
  findScrollQueued = true;
  requestAnimationFrame(() => { findScrollQueued = false; if (findOpen()) paintFind(); });
}, { passive: true });
$('find-btn').addEventListener('click', (e) => { if (findOpen()) closeFind(); else openFind(e.isTrusted); });
$('find-next').addEventListener('click', () => findStep(1));
$('find-prev').addEventListener('click', () => findStep(-1));
$('find-close').addEventListener('click', () => closeFind());

// ---------- copy: the file's text (a Markdown file's source) or the selection; in the panel ⌘C adds the file itself ----------

let copyTimer = 0;
/** `withFile`: the file goes on the clipboard beside its text, as Finder's ⌘C, where the host can (the Space panel). */
function copyFile(withFile = false) {
  if (!hasText(current)) return false;
  post(withFile ? { type: 'copy', path: current.path, withFile: true } : { type: 'copy', path: current.path });
  return true;
}

/** ⌘C: the selection when there is one, else the file and its text. */
function copyNow() {
  const sel = getSelection().toString();
  if (sel && current.path) { post({ type: 'copy', path: current.path, text: sel }); return true; }
  return copyFile(true);
}

$('copy').addEventListener('click', (e) => { if (e.isTrusted) copyFile(); });

/** ⌥⌘F: the sidebar's filter field takes the keys, as a click in it does. */
function focusFilter() {
  if (editing || updateBusy || !tree.root || !sidebarShown()) return false;
  const r = filterField.getBoundingClientRect();
  beginFilter({ clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 });
  return !!filterSession && !filterSession.list && !filterSession.find;
}

/** ⌘F, ⌥⌘F and ⌘C, from the Space helper's panel or from the writer's key panel while spacebar holds the keys. */
function hostCommand(key) {
  if (key === 'find') return openFind();
  if (key === 'filter') return focusFilter();
  if (key === 'copy') return copyNow();
  return false;
}

// The same keys when the page itself has the keyboard (a browser, the test harness): the hosts never give it any.
document.addEventListener('keydown', (e) => {
  if (e.defaultPrevented || e.isComposing || e.ctrlKey) return;
  if (e.metaKey) {
    const k = (e.altKey ? e.code.replace(/^Key/, '') : e.key).toLowerCase();
    let used = false;
    if (k === 'f' && !e.shiftKey) used = e.altKey ? focusFilter() : openFind();
    else if (k === 'g' && !e.altKey && findOpen()) { findStep(e.shiftKey ? -1 : 1); used = true; }
    else if (k === 'c' && !e.altKey && !e.shiftKey && !getSelection().toString() && !(e.target instanceof Element && e.target.closest('input, textarea'))) used = copyFile();
    if (used) e.preventDefault();
    return;
  }
  if (e.target !== findField || e.altKey) return;
  if (e.key === 'Enter') { findStep(e.shiftKey ? -1 : 1); e.preventDefault(); } else if (e.key === 'Escape') { closeFind(); e.preventDefault(); }
});

// ---------- the sidebar's menu: sort order (a panel key) and hidden files (the settings window's, never the page's) ----------

const sidePop = $('side-pop');
function syncSideMenu() {
  sidePop.querySelectorAll('[data-sort]').forEach((b) => b.setAttribute('aria-checked', String((settings.folderSort || 'name') === b.dataset.sort)));
  $('side-hidden').setAttribute('aria-checked', String(settings.showHiddenFiles === true));
}

function showSideMenu(open) {
  if (open) {
    const b = $('side-menu').getBoundingClientRect(), side = $('sidebar').getBoundingClientRect();
    sidePop.style.top = Math.round(b.bottom - side.top + 4) + 'px';
  }
  sidePop.hidden = !open;
  $('side-menu').setAttribute('aria-expanded', String(open));
  if (open) syncSideMenu();
}

$('side-menu').addEventListener('click', (e) => { e.preventDefault(); showSideMenu(sidePop.hidden); });
sidePop.addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  e.preventDefault();
  showSideMenu(false);
  if (b.dataset.sort) choose('folderSort', b.dataset.sort);
  else if (b.id === 'side-hidden') post({ type: 'openSettings', tab: 'folders' });
});
// While the menu is open, a click anywhere else only closes it.
document.addEventListener('click', (e) => {
  if (sidePop.hidden || e.target.closest('#side-pop, #side-menu')) return;
  showSideMenu(false);
  e.preventDefault();
  e.stopPropagation();
}, true);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !sidePop.hidden) { showSideMenu(false); e.preventDefault(); } });

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
// Asks after 10 s, 30 s, then every minute: an installer that fails at once (offline) frees edits quickly.
let updatePolls = 0;
/** An update has started: the installer quits this preview, so no edit, filter session or task toggle starts meanwhile. */
let updateBusy = false;
function showUpdate(u) {
  const v = u.version, failed = u.state === 'failed', running = u.state === 'started' || u.state === 'inProgress';
  clearTimeout(updateTimer);
  updateBusy = running;
  if (running && editing) stopEditing();
  if (running) endFilter();
  const title = failed ? 'Update failed' : u.state === 'started' ? `Updating to spacebar ${v}…` : u.state === 'inProgress'
    ? `Still updating to spacebar ${v}…` : u.state === 'done' ? `spacebar ${v} is installed` : `spacebar ${v} is available`;
  $('aa-update-title').textContent = title;
  $('aa-update-sub').textContent = failed ? String(u.reason || 'The update did not start.')
    : u.state === 'elsewhere' ? `This copy is in ${u.place}, which the installer does not update. Replace it with the download on the release page.`
    : u.state === 'done' ? 'Close this preview and open it again to use it.'
    : running ? 'Quick Look shows an error for a moment while spacebar updates. Press Space again in a few seconds.'
    : 'Quick Look shows an error for a moment while spacebar updates. Press Space again after.';
  $('aa-install').hidden = !(u.state === 'available' || running || (failed && u.retry));
  $('aa-install').disabled = running;
  $('aa-install').textContent = running ? 'Updating…' : 'Update';
  $('aa-copy').hidden = !(failed && u.copy);
  $('aa-update').hidden = false;
  $('aa').dataset.update = '';
  $('aa').title = `Appearance · ${title}`;
  $('upd').title = title;
  syncUpdateButton();
  // A successful update quits this preview; one still here after a while asks whether the installer is still running.
  if (u.state === 'started') updatePolls = 0;
  if (running) updateTimer = setTimeout(() => post({ type: 'updateCheck' }), [10000, 30000][updatePolls++] ?? 60000);
}

// What the Aa popover offers for the view on screen: everything for Markdown; text size and theme for the text views, whose code
// and tables follow both; nothing for the rest (an image, a PDF, media, an archive, an info card), where Aa is hidden and an
// update is shown by its own button instead.
const AA_TEXT_VIEWS = new Set(['code', 'text', 'json', 'csv']);
const aaMode = (p) => (isMarkdown(p) ? 'full' : AA_TEXT_VIEWS.has(p.view) ? 'text' : 'none');

function syncAa(p) {
  const mode = aaMode(p);
  $('aa').hidden = mode === 'none';
  if (!pop.hidden && pop.dataset.mode !== 'update' && (mode === 'none' || pop.dataset.mode !== mode)) showPopover(false);
  syncUpdateButton();
}

/** The update's own button: only when there is an update and Aa, which otherwise carries its dot, is hidden. */
function syncUpdateButton() {
  const b = $('upd'), show = $('aa').hidden && 'update' in $('aa').dataset;
  b.hidden = !show;
  if (!show && !pop.hidden && pop.dataset.mode === 'update') showPopover(false);
}

/** `mode`: 'full', 'text' or 'update' (the update row alone); closing takes none. */
function showPopover(open, mode = aaMode(current)) {
  pop.hidden = !open;
  if (open) pop.dataset.mode = mode;
  $('aa').setAttribute('aria-expanded', String(open && mode !== 'update'));
  $('upd').setAttribute('aria-expanded', String(open && mode === 'update'));
  if (open) syncPopover();
  syncPdf();
}

/** A popover choice: applied here at once, and sent to the native side, which saves it (panel keys only) and echoes it back. */
function choose(key, value) {
  if (settings[key] === value) return;
  post({ type: 'setting', key, value });
  window.sb.applySettings({ ...settings, [key]: value });
}

$('aa').addEventListener('click', () => showPopover(pop.hidden || pop.dataset.mode === 'update'));
$('upd').addEventListener('click', () => showPopover(pop.hidden || pop.dataset.mode !== 'update', 'update'));
pop.addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b || b.disabled) return;
  if (b.id === 'aa-settings') { showPopover(false); post({ type: 'openSettings', tab: 'appearance' }); return; }
  if (b.id === 'aa-install') {
    // The update quits Quick Look: the edit ends first, so its last keys are saved before the writer starts it.
    if (editing) stopEditing();
    endFilter();
    // Busy from the click: native may hold the update for the edit's saves, and refuses toggles meanwhile. Its answer clears it.
    updateBusy = true;
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
  if (pop.hidden || e.target.closest('#aa-pop, #aa, #upd')) return;
  showPopover(false);
  e.preventDefault();
  e.stopPropagation();
}, true);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !pop.hidden) showPopover(false); });
syncPopover();

// Clicks in the editor move the caret and double-clicks select a word; the page's own selection stays out of the editor.
document.addEventListener('mousedown', (e) => { if (editing && e.target.closest('#doc > .md-editing, #doc pre.text-editing')) e.preventDefault(); });

document.addEventListener('dblclick', (e) => {
  const el = e.target.closest('#doc > .md-editing, #doc pre.text-editing');
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
  if (e.target === filterField) { if (e.isTrusted) beginFilter(e); return; }
  if (e.target === findField) { if (e.isTrusted) beginFind(); return; }
  if (e.target.closest('#side-head') && tree.root) { e.preventDefault(); peek(false); post({ type: 'overview' }); return; }
  const row = e.target.closest('#side-list a.row');
  if (row) {
    e.preventDefault();
    cursor = row.dataset.path;
    keyed.clear();
    markCursor();
    // The cursor's ring is for the keys; a click shows only the highlight.
    $('side-list').classList.remove('keyed');
    const at = row.getBoundingClientRect();
    if (row.dataset.dir) toggleFolder(row.dataset.path);
    else if (!row.classList.contains('broken')) {
      peek(false);
      if (row.dataset.path !== current.path) post({ type: 'open', path: row.dataset.path });
    }
    if (e.isTrusted) beginListKeys(e, at);
    return;
  }
  if (e.target.closest('#sidebar, #crumbs')) return;
  const act = e.target.closest('#doc .viewer [data-action]');
  if (act) { e.preventDefault(); if (editing && editing.whole) stopEditing(); viewerAction(act, e); return; }
  const ov = e.target.closest('#doc .overview a.ov-row');
  if (ov) { e.preventDefault(); if (ov.dataset.path !== current.path) post({ type: 'open', path: ov.dataset.path }); return; }
  const wl = e.target.closest('#doc a.wikilink');
  if (wl) { e.preventDefault(); followWiki(wl); return; }
  const a = e.target.closest('a[href], a[*|href]');
  const href = a && (a.getAttribute('href') ?? a.getAttributeNS('http://www.w3.org/1999/xlink', 'href'));
  if (a && href && !href.startsWith('#')) { e.preventDefault(); post({ type: 'link', href: new URL(href, document.baseURI).href }); return; }
  // An embedded note is another file: it is read here, never edited.
  if (e.target.closest('#doc .wl-embed')) return;
  const el = e.target.closest('#doc > .md-editing, #doc pre.text-editing');
  if (editing && el) { if (e.detail < 2) select(editorOffset(el, e.clientX, e.clientY), 0); return; }
  if (a || e.target.closest('input, button, #toolbar') || getSelection().toString()) return;
  const text = e.target.closest('#doc pre.code[data-file-text]');
  if (text && settings.inlineEditing && current.editable === true && !isMarkdown(current)) { beginTextEdit(text, e, tClick); return; }
  const block = e.target.closest('#doc > [data-src]');
  if (block && settings.inlineEditing) beginEdit(block, e, tClick);
  else if (editing) stopEditing();
});

/** A click outside every block ends the edit; native saves what the writer still holds and re-renders. */
function stopEditing() {
  const seq = editing.seq;
  endTextEditing();
  draw();
  post({ type: 'editStop', seq });
}

document.addEventListener('change', (e) => {
  const box = e.target;
  if (!box.matches('input[type=checkbox][data-line]') || !settings.taskToggles) return;
  if (updateBusy) { box.checked = !box.checked; window.sb.status('Updating…'); return; }
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
