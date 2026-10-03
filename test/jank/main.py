#!/usr/bin/env python3
"""Position and scroll state that must hold still, in the page on its own (the offscreen harness, test/web/main.swift): the line
being read through a reflow and through each frame of the sidebar's animation, the folder grid's place after Back, rows and the
edit caret clear of the toolbar row and the line numbers, the TOC's own scroll, the boxes' scroll through a redraw of the same
file, an info card under a late thumbnail, the line being read as KaTeX draws late, and the TOC's
column and scroll between notes with and without one. This WebKit has no layout-shift entries, so positions are read before and after
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
      new ResizeObserver(() => W.push([Math.round(s.getBoundingClientRect().width), Math.round(h.getBoundingClientRect().top)]))
        .observe(document.getElementById('doc'));
      document.getElementById('side-toggle').click(); return 1;""")
    page.cmd('@wait:0.6')
    f = page.js('return window.__frames')
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
      new ResizeObserver(() => W.push(Math.round(h.getBoundingClientRect().top))).observe(document.getElementById('doc'));
      window.__releaseKatex(); return 1;""")
    page.cmd('@wait:1.2')
    after = page.js(f"""const t = document.getElementById('toc'), a = t.querySelector('a.active'), r = a && a.getBoundingClientRect(), tr = t.getBoundingClientRect();
      return {{ top: Math.round({H}.getBoundingClientRect().top), y: Math.round(scrollY), h: document.scrollingElement.scrollHeight,
      holders: document.querySelectorAll('#doc span.tex:empty').length, drawn: document.querySelectorAll('#doc .katex').length,
      tocTop: t.scrollTop, active: a && a.textContent, activeVisible: !!r && r.top >= Math.max(tr.top, 40) && r.bottom <= tr.bottom }};""")
    tops = page.js('return window.__mt')
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



def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    try:
        for i, part in enumerate([reading_position, grid_back, under_the_bar, toc_scroll, redraw_keeps_scroll, late_thumbnail, math_and_toc]):
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
