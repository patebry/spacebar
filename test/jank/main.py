#!/usr/bin/env python3
"""Position and scroll state that must hold still, in the page on its own (the offscreen harness, test/web/main.swift): the line
being read through a reflow and through each frame of the sidebar's animation, the folder grid's place after Back, rows and the
edit caret clear of the toolbar row and the line numbers, the TOC's own scroll, the boxes' scroll through a redraw of the same
file, an info card under a late thumbnail, the line being read as KaTeX draws late, and the TOC's
column and scroll between notes with and without one. Also the line at the top of every view of text (wrapped code and text, a
notebook, Raw Markdown, a long paragraph) through a reflow, a setting's redraw, a change on disk and Raw turned on and off; the
caret of a Markdown block being typed into; the folder grid's selected tile through a change of width; the windowed lists and a
fitted image's zoom label through a resize; and Raw Markdown's column. Across the anchor and the chrome's work: the line
being read as a long file's highlight pieces land (and through the sidebar while they land), through a long note's held
column width, after a change on disk is highlighted again, and after Raw is turned on. This WebKit has no layout-shift entries, so positions are read before and after
each action, and per frame where the change animates."""
import base64, json, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from webthemes import Page, ROOT, click
from sidebar import make_png
import jankchrome as JC

LONG = ''.join(f'## Section {i}\n\n' + ('Some words that wrap differently at each width. ' * 25) + '\n\n' for i in range(60))
HEAD30 = "[...document.querySelectorAll('#doc h2')].find((x) => x.textContent === 'Section 30')"


def zipped(path, names):
    import zipfile
    with zipfile.ZipFile(path, 'w') as z:
        for n, data in names.items():
            z.writestr(n, data)


def reading_position(page, check, out):
    md = os.path.join(out, 'long.md')
    open(md, 'w').write(LONG)
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.render(md)
    page.cmd('@wait:0.4')
    top = lambda: page.js(f'return Math.round({HEAD30}.getBoundingClientRect().top)')

    def at30():
        page.cmd(f"@eval:{HEAD30}.scrollIntoView({{ block: 'start' }}); 0")
        page.cmd('@wait:0.3')
        return top()

    moved = {}
    for label, do, undo in [('sidebar hidden', {'sidebarCollapsed': True}, {'sidebarCollapsed': False}),
                            ('width wide', {'width': 'wide'}, {'width': 'medium'}),
                            ('text size 19', {'fontSize': 19}, {'fontSize': 15}),
                            ('TOC off (a redraw)', {'toc': 'off'}, {'toc': 'auto'})]:
        b = at30()
        page.cmd('@apply:' + json.dumps(do))
        page.cmd('@wait:0.5')
        moved[label] = top() - b
        page.cmd('@apply:' + json.dumps(undo))
        page.cmd('@wait:0.4')
    b = at30()
    page.cmd('@size:800x760')
    page.cmd('@wait:0.4')
    moved['panel 1100 to 800'] = top() - b
    page.cmd('@size:1100x760')
    page.cmd('@wait:0.4')
    check(all(abs(d) <= 2 for d in moved.values()), 'reading position: the heading at the top stays there through a reflow', json.dumps(moved))

    # Per frame, after the page's own resize handling and before paint (an observer made after the page's runs after it).
    at30()
    page.js(f"""const h = {HEAD30}, s = document.getElementById('sidebar'), W = window.__frames = [];
      (window.__ro = new ResizeObserver(() => W.push([Math.round(s.getBoundingClientRect().width), Math.round(h.getBoundingClientRect().top)])))
        .observe(document.getElementById('doc'));
      document.getElementById('side-toggle').click(); return 1;""")
    page.cmd('@wait:0.6')
    f = page.js('window.__ro.disconnect(); return window.__frames')
    tops = [t for _, t in f]
    widths = {w for w, _ in f}
    check(len(widths) >= 4 and f[0][0] - f[-1][0] >= 150 and max(tops) - min(tops) <= 2,
          'reading position: the heading holds still on every frame of the sidebar closing', json.dumps(f))
    page.cmd("@eval:document.getElementById('side-toggle').click(); 0")
    page.cmd('@wait:0.5')
    # At the top of the document a reflow keeps the top.
    page.cmd('@eval:window.scrollTo(0, 0); 0')
    page.cmd('@wait:0.2')
    page.apply(fontSize=19)
    page.cmd('@wait:0.4')
    y0 = page.js('return scrollY')
    page.apply(fontSize=15)
    page.cmd('@wait:0.3')
    check(y0 == 0, 'reading position: at the top of the document a reflow stays at the top', str(y0))


def grid_back(page, check, out):
    photos = os.path.join(out, 'photos')
    os.makedirs(photos)
    for i in range(120):
        shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(photos, f'p{i:03d}.png'))
    page.cmd('@size:1100x760')
    page.cmd('@root:')
    page.cmd('@folder:' + photos)
    page.cmd('@wait:0.8')
    SEL = """const s = document.querySelector('#doc .ov-grid a.gt.sel'), r = s && s.getBoundingClientRect();
      return { y: Math.round(scrollY), sel: s && s.dataset.path.split('/').pop(), top: r && Math.round(r.top),
        visible: !!r && r.top >= 40 && r.bottom <= innerHeight, view: current.view, rowH: grid && grid.rowH };"""
    for _ in range(12):
        page.cmd("@eval:gridKey('ArrowDown'); 0")
    before = page.js(SEL)
    page.cmd("@eval:gridKey('Enter'); 0")
    page.cmd('@wait:0.6')
    opened = page.js('return current.view')
    page.cmd('@eval:gridBack(); 0')
    page.cmd('@wait:0.8')
    back = page.js(SEL)
    check(before['y'] > 1000 and opened == 'image' and back['view'] == 'overview' and back['sel'] == before['sel'] and back['visible']
          and abs(back['y'] - before['y']) <= back['rowH'],
          "folder grid: Back from a file returns to the grid's scroll with its tile selected and in view", json.dumps([before, opened, back]))
    page.cmd('@root:')


def under_the_bar(page, check, out):
    z = os.path.join(out, 'big.zip')
    zipped(z, {f'f{i:03d}.txt': f'{i}\n' for i in range(150)})
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.render(z)
    page.cmd('@wait:0.6')
    ROW = """const r = document.querySelector('#doc .viewer-archive tr.arc-sel'), b = r.getBoundingClientRect();
      const bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h')), hit = document.elementFromPoint(b.left + 40, b.top + b.height / 2);
      return [Math.round(b.top), Math.round(b.bottom), b.top >= bar && b.bottom <= innerHeight - 6 && !!hit && r.contains(hit)];"""
    page.cmd('@eval:arcFocus = true; arcKey("end"); 0')
    rows = []
    for i in range(40):
        page.cmd('@eval:arcKey("up"); 0')
        if i % 5 == 4:
            rows.append(page.js(ROW))
    page.cmd('@eval:arcKey("home"); 0')
    for i in range(40):
        page.cmd('@eval:arcKey("down"); 0')
        if i % 5 == 4:
            rows.append(page.js(ROW))
    check(all(r[2] for r in rows), 'archive: a row the arrows reach is clear of the toolbar row and the bottom edge, and takes the click', json.dumps(rows))

    f = os.path.join(out, 'code.ts')
    lines = [f'const v{i} = "{"x" * (300 if i == 150 else 10)}";' for i in range(300)]
    open(f, 'w').write('\n'.join(lines) + '\n')
    page.render(f)
    page.cmd('@wait:0.4')
    click(page, '#doc pre.code')
    page.cmd('@wait:0.3')
    off = lambda ln, col=0: sum(len(l) + 1 for l in lines[:ln]) + col
    CARET = """const c = document.querySelector('#doc pre.text-editing .caret, #doc pre.text-editing .sel'); if (!c) return null;
      const b = c.getBoundingClientRect(), g = document.querySelector('#doc .code-view .gutter').getBoundingClientRect();
      const bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h'));
      return [Math.round(b.top), Math.round(b.left), b.top >= bar && b.left >= g.right];"""
    carets = {}
    for label, at in [('line 299', off(299)), ('up to 280', off(280)), ('up to 240', off(240)), ('line 150 end', off(150, 300)),
                      ('line 150 col 20', off(150, 20)), ('line 150 col 2', off(150, 2))]:
        page.cmd('@eval:sb.textUpdate({ seq: editing.seq, from: 0, to: 0, insert: "", selStart: ' + str(at) + ', selLen: 0, keyTime: 0 }); 0')
        page.cmd('@wait:0.15')
        carets[label] = page.js(CARET)
    page.cmd('@eval:sb.editEnd({}); 0')
    check(all(c and c[2] for c in carets.values()), 'editing: the caret is revealed clear of the toolbar row and the line numbers', json.dumps(carets))

    md = os.path.join(out, 'long.md')
    open(md, 'w').write(LONG)
    page.render(md)
    page.cmd('@wait:0.3')
    page.cmd("@eval:scrollToHeading('Section 30', false); 0")
    page.cmd('@wait:0.2')
    t = page.js(f"return [Math.round({HEAD30}.getBoundingClientRect().top), parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h'))]")
    check(t[0] == t[1] + 16, 'headings: a heading scrolled to sits just under the toolbar row, as before', json.dumps(t))


def toc_scroll(page, check, out):
    md1, md2 = os.path.join(out, 'one.md'), os.path.join(out, 'two.md')
    open(md1, 'w').write(''.join(f'## Heading number {i}\n\n' + 'text ' * 120 + '\n\n' for i in range(80)))
    open(md2, 'w').write(''.join(f'## Other {i}\n\n' + 'text ' * 120 + '\n\n' for i in range(80)))
    page.cmd('@size:1300x700')
    page.cmd('@root:' + out)
    page.render(md1)
    page.cmd('@wait:0.4')
    TOC = """const t = document.getElementById('toc'), a = t.querySelector('a.active'), r = a && a.getBoundingClientRect(), tr = t.getBoundingClientRect();
      return { shown: getComputedStyle(t).display !== 'none', tocTop: t.scrollTop, active: a && a.textContent, activeVisible: !!r && r.top >= Math.max(tr.top, 40) && r.bottom <= tr.bottom };"""
    page.cmd('@eval:window.scrollTo(0, document.scrollingElement.scrollHeight * 0.8); 0')
    page.cmd('@wait:0.3')
    read = page.js(TOC)
    check(read['shown'] and read['active'] not in (None, 'Heading number 0') and read['activeVisible'],
          "TOC: the section being read is scrolled into the TOC's view", json.dumps(read))
    page.cmd("@eval:document.getElementById('toc').scrollTop = 900; 0")
    page.cmd('@wait:0.2')
    page.render(md2)
    page.cmd('@wait:0.4')
    nxt = page.js(TOC)
    check(nxt['shown'] and nxt['tocTop'] == 0 and nxt['active'] == 'Other 0' and nxt['activeVisible'],
          "TOC: the next document's contents open at their top", json.dumps(nxt))
    page.cmd('@size:1100x760')


def redraw_keeps_scroll(page, check, out):
    code = os.path.join(out, 'wide.ts')
    open(code, 'w').write(''.join(f'const v{i} = "{"x" * 400}";\n' for i in range(200)))
    md = os.path.join(out, 'doc.md')
    open(md, 'w').write('# Doc\n\n```js\nconst long = "' + 'y' * 600 + '";\n```\n\n| ' + ' | '.join(f'col {i} ' + 'w' * 30 for i in range(12)) + ' |\n|'
                        + '---|' * 12 + '\n| ' + ' | '.join('v' for _ in range(12)) + ' |\n\n' + 'para\n\n' * 200)
    img = os.path.join(out, 'big.png')
    open(img, 'wb').write(make_png(2400, 1600, (40, 120, 200)))
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    again = lambda extra: page.cmd('@eval:sb.render({ ...current, text: current.text + ' + json.dumps(extra) + ' }); 0')
    res = {}
    page.render(code)
    page.cmd('@wait:0.3')
    page.cmd("@eval:window.scrollTo(0, 1500); document.querySelector('#doc .code-view').scrollLeft = 1200; 0")
    CV = "return [Math.round(scrollY), document.querySelector('#doc .code-view').scrollLeft]"
    b = page.js(CV)
    again('// one more line\n')
    page.cmd('@wait:0.3')
    res['code view'] = [b, page.js(CV)]
    page.apply(stats=False)
    page.cmd('@wait:0.3')
    res['code view, a setting'] = [b, page.js(CV)]
    page.apply(stats=True)
    page.render(md)
    page.cmd('@wait:0.3')
    BOX = "return [Math.round(scrollY), document.querySelector('#doc pre:not(.mermaid)').scrollLeft, document.querySelector('#doc table').scrollLeft]"
    page.cmd("@eval:window.scrollTo(0, 100); document.querySelector('#doc pre:not(.mermaid)').scrollLeft = 900; document.querySelector('#doc table').scrollLeft = 600; 0")
    b = page.js(BOX)
    again('\nmore\n')
    page.cmd('@wait:0.3')
    res['markdown code block and table'] = [b, page.js(BOX)]
    page.render(img)
    page.cmd('@wait:0.5')
    page.cmd("@eval:applyZoom(document.querySelector('#doc .img-stage'), document.querySelector('#doc .img-stage img'), zoomLabel(), 1); const s = document.querySelector('#doc .img-stage'); s.scrollLeft = 700; s.scrollTop = 400; 0")
    ZB = "const s = document.querySelector('#doc .img-stage'); return [imgScale, s.scrollLeft, s.scrollTop];"
    b = page.js(ZB)
    page.cmd('@eval:sb.render({ ...current }); 0')
    page.cmd('@wait:0.5')
    res['zoomed image'] = [b, page.js(ZB)]
    check(all(x == y for x, y in res.values()) and res['code view'][0][1] == 1200 and res['zoomed image'][0][1] == 700,
          "redraw: the same file drawn again keeps each box's sideways scroll and a zoomed image's pan", json.dumps(res))
    page.render(code)
    page.cmd('@wait:0.3')
    sx = page.js("return document.querySelector('#doc .code-view').scrollLeft")
    check(sx == 0, 'redraw: another file starts at its left edge', str(sx))


def late_thumbnail(page, check, out):
    blob = os.path.join(out, 'thing.dat')
    open(blob, 'wb').write(bytes(range(256)) * 4)
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.render(blob)
    page.cmd('@wait:0.3')
    POS = "const q = (s) => Math.round(document.querySelector(s).getBoundingClientRect().top); return [q('#doc .info-name'), q('#doc .info-card dl')];"
    before = page.js(POS)
    thumb = 'data:image/png;base64,' + base64.b64encode(make_png(300, 300, (200, 60, 60))).decode()
    page.cmd('@eval:sb.setThumb(' + json.dumps({'path': blob, 'thumb': thumb}) + '); 0')
    page.cmd('@wait:0.3')
    after = page.js(POS)
    shown = page.js("const i = document.querySelector('#doc img.info-thumb'); return !!i && i.complete && i.getBoundingClientRect().height > 64")
    check(before == after and shown, "info card: a late thumbnail takes the icon's box; nothing below it moves", json.dumps([before, after, shown]))


def math_and_toc(page, check, out):
    # Lazy KaTeX (jank-chrome) under the reading anchor (jank-doc J1): formulas above the line being read grow from their
    # placeholders when KaTeX arrives, and the line stays put. KaTeX is held back until the page is scrolled and settled.
    tall = '$$\n\\begin{pmatrix} a & b \\\\ c & d \\\\ e & f \\\\ g & h \\end{pmatrix} = \\sum_{k=0}^{n} \\frac{x_k^2}{k!}\n$$\n\n'
    md = os.path.join(out, 'math.md')
    open(md, 'w').write(''.join(f'## Section {i}' + (' with $x_{%d}$' % i if i % 5 == 0 else '') + '\n\n'
                                + 'Words that run on, with $e^{i\\pi} + 1 = 0$ inline. ' * 6 + '\n\n' + tall for i in range(40)))
    page.cmd('@size:1300x700')
    page.cmd('@root:' + out)
    gated = page.js("""if (window.katex) return 'loaded';
      katexLoaded = new Promise((r) => { window.__releaseKatex = () => { const s = document.createElement('script');
        s.src = 'spacebar://bundle/vendor/katex.min.js'; s.onload = () => r(); document.head.appendChild(s); }; }); return 'gated';""")
    page.render(md)
    page.cmd('@wait:0.3')
    H = "[...document.querySelectorAll('#doc h2')].find((x) => x.textContent.startsWith('Section 20'))"
    page.cmd(f"@eval:{H}.scrollIntoView({{ block: 'start' }}); 0")
    page.cmd('@wait:0.4')
    before = page.js(f"""return {{ top: Math.round({H}.getBoundingClientRect().top), y: Math.round(scrollY), h: document.scrollingElement.scrollHeight,
      holders: document.querySelectorAll('#doc span.tex:empty').length, drawn: document.querySelectorAll('#doc .katex').length,
      tocTop: document.getElementById('toc').scrollTop }};""")
    # Per frame, after the page's own resize handling and before paint (an observer made after the page's runs after it).
    page.js(f"""const h = {H}, W = window.__mt = [];
      (window.__ro = new ResizeObserver(() => W.push(Math.round(h.getBoundingClientRect().top)))).observe(document.getElementById('doc'));
      window.__releaseKatex(); return 1;""")
    page.cmd('@wait:1.2')
    after = page.js(f"""const t = document.getElementById('toc'), a = t.querySelector('a.active'), r = a && a.getBoundingClientRect(), tr = t.getBoundingClientRect();
      return {{ top: Math.round({H}.getBoundingClientRect().top), y: Math.round(scrollY), h: document.scrollingElement.scrollHeight,
      holders: document.querySelectorAll('#doc span.tex:empty').length, drawn: document.querySelectorAll('#doc .katex').length,
      tocTop: t.scrollTop, active: a && a.textContent, activeVisible: !!r && r.top >= Math.max(tr.top, 40) && r.bottom <= tr.bottom }};""")
    tops = page.js('window.__ro.disconnect(); return window.__mt')
    check(gated == 'gated' and before['holders'] > 100 and before['drawn'] == 0 and after['holders'] == 0 and after['h'] - before['h'] > 200
          and abs(after['top'] - before['top']) <= 2 and max(tops) - min(tops) <= 2
          and after['active'] and after['active'].startswith('Section 2') and after['activeVisible'],
          'jank J1 + lazy KaTeX: a note with math read at its middle keeps the line being read, every frame, as KaTeX draws the '
          'formulas above it; the TOC rebuilt for the drawn headings keeps the entry being read in view',
          json.dumps({'before': before, 'after': after, 'heading top spread': [min(tops), max(tops)] if tops else None}))

    # J5 with J6: a TOC note, a note with none, another TOC note. The column never moves and each TOC opens at its top.
    body = ('Words in a paragraph that is long enough to fill the measure. ' * 12) + '\n\n'
    toc1, toc2, plain = (os.path.join(out, n) for n in ('toc1.md', 'toc2.md', 'plain.md'))
    open(toc1, 'w').write(''.join(f'## One {i}\n\n' + body for i in range(80)))
    open(toc2, 'w').write(''.join(f'## Two {i}\n\n' + body for i in range(80)))
    open(plain, 'w').write(body * 40)
    page.render(toc1)
    page.cmd('@wait:0.3')
    page.cmd('@eval:window.scrollTo(0, document.scrollingElement.scrollHeight * 0.8); 0')
    page.cmd('@wait:0.3')
    TOC = "const t = document.getElementById('toc'); return [t.scrollTop, t.querySelectorAll('a').length, getComputedStyle(t).visibility];"
    scrolled = page.js(TOC)
    JC.sample(page, {'p': '#doc p'})
    seen = {}
    for n, p in (('plain', plain), ('toc2', toc2), ('plain again', plain), ('toc1', toc1)):
        page.render(p)
        page.cmd('@wait:0.3')
        seen[n] = page.js(TOC)
    fr = JC.sampled(page)
    col = JC.spread(fr, 'p')
    check(scrolled[0] > 100 and JC.still(col) and seen['plain'][1] == 0 and seen['plain'][2] == 'hidden'
          and all(seen[k][0] == 0 and seen[k][1] == 80 and seen[k][2] == 'visible' for k in ('toc2', 'toc1')),
          'jank J5 + J6: between TOC notes and a note with none the column keeps its left edge and width on every frame, and each '
          "TOC opens at its top, not the last one's scroll", json.dumps({'toc scrolled first': scrolled, 'toc [scrollTop, entries, visibility]': seen, 'column [left, width]': col}))
    page.cmd('@size:1100x760')


# The character at the start of the line at the top of the page, right of a code view's line numbers, as a text offset in #doc;
# WHERE finds it again (by that offset once a redraw replaced its node) and reports its top.
MARK = """const bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h')) || 40, d = document.getElementById('doc');
  const pre = d.querySelector('.code-view > pre.code'), g = pre && pre.parentElement.querySelector('.gutter');
  const x = pre ? Math.max(pre.parentElement.getBoundingClientRect().left, pre.getBoundingClientRect().left + parseFloat(getComputedStyle(pre).paddingLeft),
    g && g.offsetWidth ? g.getBoundingClientRect().right : 0) + 6 : d.getBoundingClientRect().left + parseFloat(getComputedStyle(d).paddingLeft) + 6;
  const r = document.caretRangeFromPoint(x, bar + 10); if (!r || r.startContainer.nodeType !== 3) return null;
  const all = document.createRange(); all.selectNodeContents(d); all.setEnd(r.startContainer, r.startOffset);
  window.__off = all.toString().length; window.__node = r.startContainer; window.__o = r.startOffset;
  const k = document.createRange(); k.setStart(r.startContainer, r.startOffset); k.setEnd(r.startContainer, Math.min(r.startContainer.length, r.startOffset + 1));
  return { off: window.__off, top: Math.round(k.getClientRects()[0].top), y: Math.round(scrollY), ch: r.startContainer.data.slice(r.startOffset, r.startOffset + 12) };"""
WHERE = """if (!window.__node || !window.__node.isConnected) {
    const w = document.createTreeWalker(document.getElementById('doc'), NodeFilter.SHOW_TEXT); let n = 0, node;
    while ((node = w.nextNode())) { if (n + node.length > window.__off) { window.__node = node; window.__o = window.__off - n; break; } n += node.length; } }
  const k = document.createRange(); k.setStart(window.__node, window.__o); k.setEnd(window.__node, Math.min(window.__node.length, window.__o + 1));
  return { top: Math.round(k.getClientRects()[0].top), y: Math.round(scrollY), ch: window.__node.data.slice(window.__o, window.__o + 12) };"""


def reflow_every_view(page, check, out):
    """N2, N16: wrapped code and text, a notebook, Raw Markdown and a long paragraph of Markdown keep the line at the top through the
    sidebar, the text size, the panel's width and the wrap setting."""
    long_line = lambda i: f'line {i}: ' + ' '.join(f'word{k}' for k in range(60))
    files = {
        'wrapped.ts': ('\n'.join(f'const v{i} = "{long_line(i)}";' for i in range(400)) + '\n', {'wrapCode': True}),
        'wrapped.txt': ('\n'.join(long_line(i) for i in range(400)) + '\n', {'wrapText': True}),
        'nb.ipynb': (json.dumps({'nbformat': 4, 'nbformat_minor': 5, 'metadata': {}, 'cells': [
            {'cell_type': 'markdown', 'metadata': {}, 'source': [f'## Cell {i}\n', 'Words that wrap at every width of the column. ' * 12]} for i in range(80)]}), {}),
        'note.md': (''.join(f'## Section {i}\n\n' + 'Words that wrap at every width of the column. ' * 25 + '\n\n' for i in range(60)), {}),
    }
    for n, (t, _) in files.items():
        open(os.path.join(out, n), 'w').write(t)
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    actions = [('sidebar hidden', {'sidebarCollapsed': True}, {'sidebarCollapsed': False}),
               ('text size 19', {'fontSize': 19}, {'fontSize': 15}),
               ('panel 1100 to 820', '@size:820x760', '@size:1100x760')]
    act = lambda a: page.cmd(a if isinstance(a, str) else '@apply:' + json.dumps(a))

    def run(acts, at=0.5):
        res = {}
        for label, do, undo in acts:
            page.cmd(f'@eval:window.scrollTo(0, document.scrollingElement.scrollHeight * {at}); 0')
            page.cmd('@wait:0.3')
            b = page.js(MARK)
            act(do)
            page.cmd('@wait:0.6')
            a = page.js(WHERE)
            res[label] = (a['top'] - b['top']) if a and b and a['ch'] == b['ch'] else [b, a]
            act(undo)
            page.cmd('@wait:0.4')
        return res

    moved = {}
    for n, (_, s) in files.items():
        page.apply(**{'wrapCode': False, 'wrapText': False, **s})
        page.render(os.path.join(out, n))
        page.cmd('@wait:0.4')
        acts = actions + ([('wrap off (a redraw)', {'wrapCode': False, 'wrapText': False}, s)] if s else [])
        # In the note, the line at the top is inside a long paragraph (N16).
        moved[n] = run(acts, 0.5 if n != 'note.md' else 0.503)
    page.apply(wrapCode=False, wrapText=False, wrapMarkdown=True)
    page.render(os.path.join(out, 'note.md'))
    page.cmd('@wait:0.3')
    page.cmd("@eval:document.getElementById('raw').click(); 0")
    page.cmd('@wait:0.3')
    moved['note.md, Raw'] = run(actions)
    page.cmd("@eval:document.getElementById('raw').click(); 0")
    check(all(isinstance(d, int) and abs(d) <= 2 for r in moved.values() for d in r.values()),
          'reading position: wrapped code and text, a notebook, Raw Markdown and a long paragraph keep the line at the top through '
          'the sidebar, the text size, the panel and the wrap setting', json.dumps(moved))

    # Per frame, after the page's own resize handling and before paint.
    page.apply(wrapCode=True)
    page.render(os.path.join(out, 'wrapped.ts'))
    page.cmd('@wait:0.4')
    page.cmd('@eval:window.scrollTo(0, document.scrollingElement.scrollHeight * 0.5); 0')
    page.cmd('@wait:0.3')
    b = page.js(MARK)
    page.js("""const k = document.createRange(), s = document.getElementById('sidebar'), W = window.__frames = [];
      (window.__ro = new ResizeObserver(() => { k.setStart(window.__node, window.__o); k.setEnd(window.__node, window.__o + 1);
        W.push([Math.round(s.getBoundingClientRect().width), Math.round(k.getClientRects()[0].top)]); })).observe(document.getElementById('doc'));
      document.getElementById('side-toggle').click(); return 1;""")
    page.cmd('@wait:0.6')
    f = page.js('window.__ro.disconnect(); return window.__frames')
    tops = [t for _, t in f]
    check(b and len({w for w, _ in f}) >= 4 and f[0][0] - f[-1][0] >= 150 and max(tops) - min(tops) <= 2 and abs(tops[-1] - b['top']) <= 2,
          'reading position: wrapped code holds its line on every frame of the sidebar closing', json.dumps([b and b['top'], f]))
    page.cmd("@eval:document.getElementById('side-toggle').click(); 0")
    page.cmd('@wait:0.5')
    page.apply(wrapCode=False)


def redraw_keeps_line(page, check, out):
    """N10, N11: the front-matter setting and a change on disk above the line being read keep that line, in Markdown and in code."""
    fm = os.path.join(out, 'fm.md')
    open(fm, 'w').write('---\ntitle: A note\ntags: [a, b, c]\nauthor: someone\n---\n'
                        + ''.join(f'## Section {i}\n\n' + 'Words that wrap at every width of the column. ' * 4 + '\n\n' for i in range(80)))
    H = "[...document.querySelectorAll('#doc h2')].find((x) => x.textContent === 'Section 40')"
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.apply(frontMatter='table')
    page.render(fm)
    page.cmd('@wait:0.4')
    top = lambda: page.js(f'return Math.round({H}.getBoundingClientRect().top)')

    def at40():
        page.cmd(f"@eval:{H}.scrollIntoView({{ block: 'start' }}); 0")
        page.cmd('@wait:0.3')
        return top()

    moved = {}
    for label, to in [('front matter table to hide', 'hide'), ('hide to raw', 'raw'), ('raw to table', 'table')]:
        b = at40()
        page.apply(frontMatter=to)
        page.cmd('@wait:0.4')
        moved[label] = top() - b
    page.apply(frontMatter='hide')
    for label, edit in [('5 lines inserted near the top on disk', lambda t: t.replace('## Section 1\n', '## Section 1\n\nInserted.\n\nAnother.\n\nThird.\n\n', 1)),
                        ('a paragraph appended on disk', lambda t: t + '\n\nAppended paragraph.\n')]:
        b = at40()
        text = page.js('return current.text')
        page.cmd('@eval:sb.render({ ...current, text: ' + json.dumps(edit(text)) + ' }); 0')
        page.cmd('@wait:0.4')
        moved[label] = top() - b
    page.apply(frontMatter='table')
    ts = os.path.join(out, 'grow.ts')
    open(ts, 'w').write(''.join(f'const v{i} = {i};\n' for i in range(800)))
    page.render(ts)
    page.cmd('@wait:0.4')
    page.cmd('@eval:window.scrollTo(0, 6000); 0')
    page.cmd('@wait:0.3')
    LINE = """const code = document.querySelector('#doc pre.code'), t = code.textContent, n = NTH;
      let at = 0; for (let k = 0; k < n; k++) at = t.indexOf('\\n', at) + 1;
      const w = document.createTreeWalker(code, NodeFilter.SHOW_TEXT); let c = 0, node;
      while ((node = w.nextNode()) && c + node.length <= at) c += node.length;
      const k = document.createRange(); k.setStart(node, at - c); k.setEnd(node, at - c + 1); return Math.round(k.getClientRects()[0].top);"""
    b = page.js(MARK)
    line = page.js('const code = document.querySelector("#doc pre.code"), r = document.createRange(); r.selectNodeContents(code); '
                   'r.setEnd(window.__node, window.__o); return r.toString().split("\\n").length - 1;')
    page.cmd('@eval:sb.render({ ...current, text: "// header line\\n".repeat(25) + current.text }); 0')
    page.cmd('@wait:0.3')
    a = page.js(LINE.replace('NTH', str(line + 25)))
    moved['25 lines added at the top of code on disk'] = a - b['top'] if b and line > 100 else [b, line]
    check(all(isinstance(d, int) and abs(d) <= 2 for d in moved.values()),
          'reading position: the front-matter setting and a change on disk above the line being read keep that line', json.dumps(moved))


def markdown_caret(page, check, out):
    """N1: Return pressed in a Markdown block near the window's bottom keeps the caret above the bottom edge."""
    md = os.path.join(out, 'paras.md')
    open(md, 'w').write(''.join(f'Paragraph {i} with some words in it.\n\n' for i in range(80)))
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.render(md)
    page.cmd('@wait:0.4')
    page.cmd("@eval:const p = [...document.querySelectorAll('#doc > p')][20]; window.scrollBy(0, p.getBoundingClientRect().bottom - (innerHeight - 40)); 0")
    page.cmd('@wait:0.3')
    click(page, '#doc > p:nth-of-type(21)')
    page.cmd('@wait:0.3')
    st = page.js('return editing && { start: editing.start, lines: editing.lines, text: editing.text, ver: docVer, seq: editing.seq }')
    CARET = """const c = document.querySelector('#doc .md-editing .caret'), r = c && c.getBoundingClientRect();
      return r && [Math.round(r.bottom), r.bottom <= innerHeight - 6, Math.round(scrollY)];"""
    seen = []
    if st:
        text, ver, lines = st['text'], st['ver'], st['lines']
        for i in range(8):
            nt = text + '\n' + f'new line {i}'
            u = {'seq': st['seq'], 'at': st['start'], 'old': lines, 'text': nt, 'ver': ver + 1, 'selStart': len(nt), 'selLen': 0, 'keyTime': 0}
            page.cmd('@eval:sb.editUpdate(' + json.dumps(u) + '); 0')
            page.cmd('@wait:0.1')
            text, ver, lines = nt, ver + 1, len(nt.split('\n'))
            seen.append(page.js(CARET))
        page.cmd('@eval:sb.editEnd({}); 0')
    check(len(seen) == 8 and all(c and c[1] for c in seen), 'editing: Return in a Markdown block near the bottom keeps the caret on screen',
          json.dumps(seen))


def grid_width(page, check, out):
    """N3: the folder grid keeps its selected tile where it was when the sidebar or the panel changes its width."""
    photos = os.path.join(out, 'photos')
    os.makedirs(photos)
    for i in range(300):
        shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(photos, f'p{i:03d}.png'))
    page.cmd('@size:1100x760')
    page.cmd('@root:')
    page.cmd('@folder:' + photos)
    page.cmd('@wait:0.8')
    SEL = """const s = document.querySelector('#doc .ov-grid a.gt.sel'), r = s && s.getBoundingClientRect();
      return { sel: s && s.dataset.path.split('/').pop(), top: r && Math.round(r.top), cols: grid.cols, rowH: grid.rowH };"""
    for _ in range(15):
        page.cmd("@eval:gridKey('ArrowDown'); 0")
    put = "@eval:{ const s = document.querySelector('#doc .ov-grid a.gt.sel'); window.scrollBy(0, s.getBoundingClientRect().top - 250); } 0"
    page.cmd(put)
    page.cmd('@wait:0.3')
    res = {}
    for label, do, undo in [('sidebar hidden', '@apply:{"sidebarCollapsed": true}', '@apply:{"sidebarCollapsed": false}'),
                            ('panel 1100 to 760', '@size:760x760', '@size:1100x760'),
                            ('panel 1100 to 1400', '@size:1400x760', '@size:1100x760')]:
        b = page.js(SEL)
        page.cmd(do)
        page.cmd('@wait:0.6')
        a = page.js(SEL)
        res[label] = [b, a]
        page.cmd(undo)
        page.cmd('@wait:0.6')
        page.cmd(put)
        page.cmd('@wait:0.3')
    check(all(a['sel'] == b['sel'] and a['top'] is not None and a['cols'] != b['cols'] and abs(a['top'] - b['top']) <= a['rowH'] / 2
              for b, a in res.values()), 'folder grid: the selected tile stays in place when the width changes the columns', json.dumps(res))
    page.cmd('@root:')


def windows_on_resize(page, check, out):
    """N5: the windowed CSV table and the sidebar's list draw the rows a taller panel shows, with no scroll."""
    for i in range(1500):
        open(os.path.join(out, f'n{i:04d}.txt'), 'w').write('x\n')
    csv = os.path.join(out, 'aaa-rows.csv')
    open(csv, 'w').write('id,name,value\n' + ''.join(f'{i},name {i},{i * 3}\n' for i in range(20000)))
    page.cmd('@size:1100x500')
    page.cmd('@root:' + out)
    page.render(csv)
    page.cmd('@wait:0.6')
    GEO = """const s = document.querySelector('#doc .csv-scroll'), sr = s.getBoundingClientRect(), rows = [...s.querySelectorAll('tbody tr:not(.pad)')];
      const last = rows[rows.length - 1].getBoundingClientRect(), l = document.getElementById('side-list'), lr = l.getBoundingClientRect();
      const srows = [...l.querySelectorAll('a.row')], sl = srows[srows.length - 1].getBoundingClientRect();
      return { csvBlank: Math.max(0, Math.round(Math.min(sr.bottom, innerHeight) - last.bottom)), sideBlank: Math.max(0, Math.round(lr.bottom - sl.bottom)) };"""
    page.cmd("@eval:document.querySelector('#doc .csv-scroll').scrollTop = 200000; document.getElementById('side-list').scrollTop = 12000; 0")
    page.cmd('@wait:0.4')
    before = page.js(GEO)
    page.cmd('@size:1100x1400')
    page.cmd('@wait:0.6')
    after = page.js(GEO)
    check(before == {'csvBlank': 0, 'sideBlank': 0} and after == before,
          'windowed lists: the CSV table and the sidebar draw the rows a taller panel shows', json.dumps([before, after]))
    page.cmd('@size:1100x760')
    page.cmd('@root:')


def raw_toggle(page, check, out):
    """N6, N14: Raw on a long note shows the source of the section being read, Raw off returns to it with the code block's and
    the table's sideways scroll, and Raw's source column is as wide as any code view's (no TOC column kept for it)."""
    md = '# Doc\n\n```js\nconst long = "' + 'y' * 600 + '";\n```\n\n| ' + ' | '.join(f'col {i} ' + 'w' * 30 for i in range(12)) + ' |\n|' + '---|' * 12 + \
         '\n| ' + ' | '.join('v' for _ in range(12)) + ' |\n\n' + ''.join(f'## Section {i}\n\n- item one\n- item two\n- item three\n\n> a quote\n\nShort line.\n\n' for i in range(60))
    note = os.path.join(out, 'note.md')
    open(note, 'w').write(md)
    want = md.split('\n').index('## Section 30') + 1
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.render(note)
    page.cmd('@wait:0.4')
    H = "[...document.querySelectorAll('#doc h2')].find((x) => x.textContent === 'Section 30')"
    page.cmd(f"@eval:{H}.scrollIntoView({{ block: 'start' }}); document.querySelector('#doc pre:not(.mermaid)').scrollLeft = 900; document.querySelector('#doc > table').scrollLeft = 300; 0")
    page.cmd('@wait:0.3')
    before = page.js(f'return Math.round({H}.getBoundingClientRect().top)')
    page.cmd("@eval:document.getElementById('raw').click(); 0")
    page.cmd('@wait:0.3')
    TOPLINE = """const cv = document.querySelector('#doc .code-view'), code = cv.querySelector('pre.code'), bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h'));
      const r = document.caretRangeFromPoint(code.getBoundingClientRect().left + 30, bar + 12), pre = document.createRange();
      pre.selectNodeContents(code); pre.setEnd(r.startContainer, r.startOffset); return pre.toString().split('\\n').length;"""
    raw = page.js(TOPLINE)
    page.cmd("@eval:document.getElementById('raw').click(); 0")
    page.cmd('@wait:0.3')
    back = page.js(f"return [Math.round({H}.getBoundingClientRect().top), document.querySelector('#doc pre:not(.mermaid)').scrollLeft, document.querySelector('#doc > table').scrollLeft]")
    check(abs(raw - want) <= 2 and abs(back[0] - before) <= 2 and back[1:] == [900, 300],
          'Raw: on shows the source of the section being read; off returns to it with the boxes\' sideways scroll',
          json.dumps({'source line': want, 'raw top line': raw, 'heading before': before, 'raw off [heading, code block, table]': back}))

    W = """const c = document.querySelector('#doc .code-view').getBoundingClientRect(); return [Math.round(c.left), Math.round(c.width)];"""
    ts = os.path.join(out, 'code.ts')
    open(ts, 'w').write(''.join(f'const v{i} = "' + 'w ' * 200 + '";\n' for i in range(20)))
    page.cmd('@size:1300x760')
    page.render(note)
    page.cmd('@wait:0.3')
    page.cmd("@eval:document.getElementById('raw').click(); 0")
    page.cmd('@wait:0.3')
    rawcol = page.js(W)
    page.cmd("@eval:document.getElementById('raw').click(); 0")
    page.render(ts)
    page.cmd('@wait:0.3')
    code = page.js(W)
    check(rawcol == code, "Raw: Markdown's source is drawn as wide as any code view, with no empty TOC column", json.dumps({'raw': rawcol, 'code': code}))
    page.cmd('@size:1100x760')


def zoom_label(page, check, out):
    """N13: a fitted image's zoom label follows the stage when the sidebar hides or its width changes."""
    img = os.path.join(out, 'wide.png')
    open(img, 'wb').write(make_png(1600, 1000, (40, 120, 200)))
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.render(img)
    page.cmd('@wait:0.6')
    Z = "const i = document.querySelector('#doc .img-stage img'); return [document.querySelector('#kind .img-zoom').textContent, Math.round(100 * i.getBoundingClientRect().width / i.naturalWidth) + '%'];"
    res = {'fitted': page.js(Z)}
    page.apply(sidebarCollapsed=True)
    page.cmd('@wait:0.5')
    res['sidebar hidden'] = page.js(Z)
    page.apply(sidebarCollapsed=False, sidebarWidth=160)
    page.cmd('@wait:0.5')
    res['sidebar at 160'] = page.js(Z)
    page.apply(sidebarWidth=240)
    page.cmd('@wait:0.4')
    check(all(a == b for a, b in res.values()) and res['fitted'] != res['sidebar hidden'],
          "image: a fitted image's zoom label follows the sidebar's width", json.dumps(res))


# The character at the start of the line at the top, as an offset in the code view's text (or #doc's), held by that offset when a
# highlight piece landing replaces its node. FOLLOW samples its top on every frame after the page's own correction (an observer
# made after the page's, ticked each frame so frames where nothing resizes are sampled too), with the pieces still plain and
# whether the column's width is held. STOP ends it and returns the samples.
MARK_BOX = """const bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h')) || 40, d = document.getElementById('doc');
  const pre = d.querySelector('.code-view > pre.code'), g = pre && pre.parentElement.querySelector('.gutter'), box = pre || d;
  const x = pre ? Math.max(pre.parentElement.getBoundingClientRect().left, pre.getBoundingClientRect().left + parseFloat(getComputedStyle(pre).paddingLeft),
    g && g.offsetWidth ? g.getBoundingClientRect().right : 0) + 6 : d.getBoundingClientRect().left + parseFloat(getComputedStyle(d).paddingLeft) + 6;
  let r = null;  // the first row down with text: a blank line has none
  for (let y = bar + 10; y < bar + 80 && !(r && r.startContainer.nodeType === 3 && box.contains(r.startContainer)); y += 4) r = document.caretRangeFromPoint(x, y);
  if (!r || r.startContainer.nodeType !== 3 || !box.contains(r.startContainer)) return null;
  const all = document.createRange(); all.selectNodeContents(box); all.setEnd(r.startContainer, r.startOffset);
  const before = all.toString();
  window.__box = pre ? '#doc .code-view > pre.code' : '#doc'; window.__off = before.length; window.__node = r.startContainer; window.__o = r.startOffset;
  window.__at = () => { if (!window.__node || !window.__node.isConnected) {
      const w = document.createTreeWalker(document.querySelector(window.__box), NodeFilter.SHOW_TEXT); let n = 0, node;
      while ((node = w.nextNode())) { if (n + node.length > window.__off) { window.__node = node; window.__o = window.__off - n; break; } n += node.length; } }
    const k = document.createRange(); k.setStart(window.__node, window.__o); k.setEnd(window.__node, Math.min(window.__node.length, window.__o + 1));
    return Math.round(k.getClientRects()[0].top); };
  window.__plain = () => { const c = document.querySelector('#doc pre.code > code.parts');
    return c ? [...c.children].filter((n) => n.classList.contains('tpart') && n.childNodes.length === 1 && n.firstChild.nodeType === 3).length : -1; };
  return { off: window.__off, top: window.__at(), line: pre ? before.split('\\n').length - 1 : -1, plain: window.__plain(), y: Math.round(scrollY) };"""
FOLLOW = """const tick = document.createElement('div'), S = window.__samples = []; let on = true, n = 0;
  tick.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;pointer-events:none;visibility:hidden';
  document.body.append(tick);
  window.__ro = new ResizeObserver(() => S.push([window.__at(), window.__plain(), document.getElementById('doc').style.width ? 1 : 0]));
  window.__ro.observe(tick); window.__ro.observe(document.getElementById('doc'));
  const f = () => { if (!on) return; tick.style.width = (1 + (++n % 2)) + 'px'; requestAnimationFrame(f); };
  requestAnimationFrame(f);
  window.__stop = () => { on = false; window.__ro.disconnect(); tick.remove(); return S; };"""
STOP = 'return window.__stop()'
LANDED = 'return window.__plain()'
# MARK_BOX's result kept as `m`, so more can run in the same task before it is returned.
MARK_M = MARK_BOX.replace('return {', 'const m = {', 1) + ';'


def wait_landed(page, limit=40):
    """Waits for every highlight piece to land (0), or the code to have no pieces (-1)."""
    for _ in range(limit):
        if page.js(LANDED) <= 0:
            return
        page.cmd('@wait:0.1')


def held(b, frames, final, tol=2):
    tops = [t for t, _, _ in frames]
    return bool(b) and len(frames) >= 3 and max(tops) - min(tops) <= tol and abs(tops[0] - b['top']) <= tol and abs(final - b['top']) <= tol


def summary(b, frames, final):
    tops = [t for t, _, _ in frames]
    return {'mark': b, 'frames': len(frames), 'top range': [min(tops), max(tops)] if tops else None, 'final': final,
            'plain pieces first/last': [frames[0][1], frames[-1][1]] if frames else None, 'width held frames': sum(w for _, _, w in frames)}


def long_ts(n, wide=False):
    """TypeScript with a block comment that runs across highlight pieces every 300 lines."""
    out = []
    for i in range(n):
        if i % 300 == 150:
            out.append('/* a comment that runs over\n' + ''.join(f'   comment line {k} of block {i}\n' for k in range(120)) + '*/')
        out.append(f'export const value{i} = compute("{"wide words " * 30 if wide else "s"}", {i}) + other{i % 7};  // note {i}')
    return '\n'.join(out) + '\n'


def anchor_vs_highlight(page, check, out):
    """Cross: the reading anchor and chunked highlighting. A long code file read at its middle keeps the character at the top
    still on every frame while its pieces land, unwrapped (off-screen pieces skipped at their size) and wrapped; and wrapped code
    keeps it through the sidebar closing while pieces are still landing."""
    plain = os.path.join(out, 'long.ts')
    open(plain, 'w').write(long_ts(4200))
    wrapped = os.path.join(out, 'wide.ts')
    open(wrapped, 'w').write(long_ts(1100, wide=True))
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    res, ok = {}, True
    for label, path, wrap, toggle in [('unwrapped', plain, False, False), ('wrapped', wrapped, True, False),
                                      ('wrapped, sidebar closing while pieces land', wrapped, True, True)]:
        page.apply(wrapCode=wrap, sidebarCollapsed=False)
        page.render(path)
        b = page.js('window.scrollTo(0, document.scrollingElement.scrollHeight * 0.5); ' + MARK_M + FOLLOW
                    + (" document.getElementById('side-toggle').click();" if toggle else '') + ' return m;')
        page.cmd('@wait:0.8')
        wait_landed(page)
        page.cmd('@wait:0.2')
        f = page.js(STOP)
        final = page.js('return window.__at()')
        res[label] = summary(b, f, final)
        ok = ok and held(b, f, final) and b['plain'] > 0 and f[-1][1] == 0
        if toggle:
            page.apply(sidebarCollapsed=False)
            page.cmd('@wait:0.5')
    page.apply(wrapCode=False)
    check(ok, 'cross anchor x highlighting: long code read at its middle holds the character at the top on every frame as its pieces '
          'land, unwrapped and wrapped, and through the sidebar closing while they land', json.dumps(res))


def anchor_vs_width_hold(page, check, out):
    """Cross: the reading anchor and N17. A note over 100 KB has its column's width held while the sidebar slides and released at
    the end; the line being read (inside a long paragraph) stays put on every frame, and after the release."""
    md = os.path.join(out, 'big.md')
    open(md, 'w').write(''.join(f'## Section {i}\n\n' + 'Words that wrap at every width of the column, and then some more. ' * 30 + '\n\n'
                                for i in range(80)))
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    page.apply(sidebarCollapsed=False)
    page.render(md)
    page.cmd('@wait:0.5')
    res, ok = {}, True
    for label in ['sidebar closing', 'sidebar opening']:
        page.cmd('@eval:window.scrollTo(0, document.scrollingElement.scrollHeight * 0.503); 0')
        page.cmd('@wait:0.3')
        b = page.js(MARK_BOX)
        page.js(FOLLOW + " document.getElementById('side-toggle').click(); return 1;")
        page.cmd('@wait:1.0')
        f = page.js(STOP)
        final = page.js('return window.__at()')
        released = page.js("return !document.getElementById('doc').style.width")
        res[label] = {**summary(b, f, final), 'released': released}
        ok = ok and held(b, f, final) and any(w for _, _, w in f) and released and not f[-1][2]
    page.apply(sidebarCollapsed=False)
    page.cmd('@wait:0.4')
    check(ok, 'cross anchor x N17 width hold: a note over 100 KB keeps the line being read on every frame of the sidebar sliding, '
          'with the width held, and after it is released', json.dumps(res))


def reload_vs_highlight(page, check, out):
    """Cross: live-reload line mapping and chunked highlighting. 25 lines added above the line being read in long code (wrapped and
    unwrapped) keep that line where it was, on every frame, once the new text's pieces have landed."""
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    res, ok = {}, True
    for label, name, text, wrap in [('unwrapped', 'reload.ts', long_ts(4200), False), ('wrapped', 'reload-wide.ts', long_ts(1100, wide=True), True)]:
        path = os.path.join(out, name)
        open(path, 'w').write(text)
        page.apply(wrapCode=wrap)
        page.render(path)
        page.cmd('@eval:window.scrollTo(0, document.scrollingElement.scrollHeight * 0.5); 0')
        page.cmd('@wait:0.3')
        wait_landed(page)
        page.cmd('@wait:0.2')
        b = page.js(MARK_BOX)
        add = '// header line\n' * 25
        p0 = page.js('sb.render({ ...current, text: ' + json.dumps(add) + ' + current.text }); window.__off += ' + str(len(add))
                     + '; window.__node = null; const p = window.__plain(); ' + FOLLOW + ' return p;')
        page.cmd('@wait:0.8')
        wait_landed(page)
        page.cmd('@wait:0.2')
        f = page.js(STOP)
        final = page.js('return window.__at()')
        res[label] = {**summary(b, f, final), 'plain right after reload': p0}
        ok = ok and held(b, f, final) and b['line'] > 100 and p0 > 0 and f[-1][1] == 0
    page.apply(wrapCode=False)
    check(ok, 'cross live reload x highlighting: lines added above the line being read keep it still once the re-highlighting lands',
          json.dumps(res))


def raw_vs_highlight(page, check, out):
    """Cross: Raw's line mapping and chunked highlighting. Raw on a long note lands on the source line of the section being read,
    and that line does not move as the source's pieces land, wrapped and unwrapped."""
    md = ''.join(f'## Section {i}\n\n- item one\n- item **two**\n\n> a quote\n\nA paragraph with `code` and a [link](https://example.com).\n\n'
                 + 'More words in this section. ' * 20 + '\n\n' for i in range(400))
    note = os.path.join(out, 'rawlong.md')
    open(note, 'w').write(md)
    want = md.split('\n').index('## Section 200') + 1
    H = "[...document.querySelectorAll('#doc h2')].find((x) => x.textContent === 'Section 200')"
    TOPLINE = """const code = document.querySelector('#doc .code-view pre.code'), bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h'));
      const r = document.caretRangeFromPoint(code.getBoundingClientRect().left + 30, bar + 12), pre = document.createRange();
      pre.selectNodeContents(code); pre.setEnd(r.startContainer, r.startOffset); return pre.toString().split('\\n').length;"""
    page.cmd('@size:1100x760')
    page.cmd('@root:' + out)
    res, ok = {}, True
    for label, wrap in [('wrapped', True), ('unwrapped', False)]:
        page.apply(wrapMarkdown=wrap)
        page.render(note)
        page.cmd('@wait:0.4')
        page.cmd(f"@eval:{H}.scrollIntoView({{ block: 'start' }}); 0")
        page.cmd('@wait:0.3')
        b = page.js("document.getElementById('raw').click(); " + MARK_M + FOLLOW + ' return m;')
        line = page.js(TOPLINE)
        page.cmd('@wait:0.8')
        wait_landed(page)
        page.cmd('@wait:0.2')
        f = page.js(STOP)
        final = page.js('return window.__at()')
        after = page.js(TOPLINE)
        res[label] = {**summary(b, f, final), 'source line': want, 'top line on Raw': line, 'top line once landed': after}
        ok = ok and held(b, f, final) and b['plain'] > 0 and f[-1][1] == 0 and abs(line - want) <= 2 and after == line
        page.cmd("@eval:document.getElementById('raw').click(); 0")
        page.cmd('@wait:0.3')
    page.apply(wrapMarkdown=True)
    check(ok, 'cross Raw x highlighting: Raw on a long note lands on the source line being read and holds it as the pieces land',
          json.dumps(res))


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    try:
        for i, part in enumerate([reading_position, grid_back, under_the_bar, toc_scroll, redraw_keeps_scroll, late_thumbnail, math_and_toc,
                                   reflow_every_view, redraw_keeps_line, markdown_caret, grid_width, windows_on_resize, raw_toggle, zoom_label,
                                   anchor_vs_highlight, anchor_vs_width_hold, reload_vs_highlight, raw_vs_highlight]):
            out = os.path.join(page.out, f'part{i}')
            os.makedirs(out)
            part(page, check, out)
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l]
        check(not errs, 'no page errors logged', json.dumps(errs)[:300])
        page.close()
    finally:
        if page.proc.poll() is None:
            page.close()
        shutil.rmtree(page.out, ignore_errors=True)
    print(f'\n{sum(results)}/{len(results)} jank checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
