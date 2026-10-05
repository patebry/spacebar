#!/usr/bin/env python3
"""The chrome holds still: the page's toolbar, sidebar and text column, in the offscreen harness (test/web/main.swift), measured
the way a person sees jank, by sampling each element's rect on every animation frame (this WebKit reports no layout-shift
entries) and within the task that handles an input, which is what stays on screen until the next one.

A click lights the row it opens at once; a Markdown note with no table of contents takes the full measure, and each note's column
is final in its first frame; the toolbar's buttons keep their slots in Minimal chrome and in a narrow panel; the kind line, the image zoom and the
PDF page counter keep their widths as they fill in and count; the find field stays put as the count appears; the edit gutter keeps
its width past line 99; the overview's rows survive a listing; cut-off text has a tooltip; and the Contents search's status line
never resizes the list. Through an edit the kind line and the code stay put and the line count stays live; a new file never shows
the last one's stats; the TOC's entries survive a redraw; an archive entry's counter and a media file's late info keep the kind
line's place; and diagrams stay drawn through a redraw after the column's width changed. Also runs sidebar.py's steady_chrome and
steady_list, which these changes touch."""
import json, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, click
import sidebar as SB

SAMPLER = """const W = window.__jc = { frames: [], stop: false }, pick = SEL;
  const frame = () => { if (W.stop) return; const f = {};
    for (const [k, s] of Object.entries(pick)) { const e = document.querySelector(s); if (!e) { f[k] = null; continue; }
      const r = e.getBoundingClientRect(), cs = getComputedStyle(e);
      f[k] = cs.display === 'none' ? null : [r.left, r.width, r.top, r.height].map((v) => Math.round(v * 2) / 2).concat(cs.visibility === 'visible' ? 1 : 0); }
    f.extra = (() => EXTRA)(); W.frames.push(f); requestAnimationFrame(frame); };
  requestAnimationFrame(frame); return 1;"""


def sample(page, sel, extra='null'):
    page.js(SAMPLER.replace('SEL', json.dumps(sel)).replace('EXTRA', extra))


def sampled(page):
    return page.js('window.__jc.stop = true; return window.__jc.frames')


def spread(frames, key, idx=(0, 1)):
    """The distinct values of `key`'s rect fields `idx` over the frames that show it."""
    return sorted({tuple(f[key][i] for i in idx) for f in frames if f.get(key)})


def still(vals, tol=1):
    return bool(vals) and all(abs(a - b) <= tol for v in vals for a, b in zip(v, vals[0]))


LIT = """[...document.querySelectorAll('#side-list a.row')].filter((a) => getComputedStyle(a).backgroundColor !== 'rgba(0, 0, 0, 0)')
  .map((a) => a.querySelector('.nm').textContent)"""


def click_lights_row(page, check, out):
    d = os.path.join(out, 'click')
    os.makedirs(os.path.join(d, 'folder'))
    for i in range(6):
        open(os.path.join(d, f'{i}.txt'), 'w').write(f'{i}\n')
    open(os.path.join(d, 'folder', 'in.txt'), 'w').write('in\n')
    P = lambda n: os.path.join(d, n)
    page.cmd('@root:' + d)
    page.render(P('0.txt'))
    page.cmd('@wait:0.4')
    sample(page, {}, '[!!window.__clicked, ' + LIT + ']')
    now = page.js("""window.__clicked = true; const row = document.querySelector('#side-list a.row[data-path$="/3.txt"]'), r = row.getBoundingClientRect();
      for (const t of ['mousedown', 'mouseup', 'click']) row.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, clientX: r.left + 3, clientY: r.top + 3 }));
      return { lit: """ + LIT + """, current: current.path };""")
    page.cmd('@wait:0.4')
    frames = [f['extra'][1] for f in sampled(page) if f['extra'][0]]
    after = page.js('return { lit: ' + LIT + ', current: current.path }')
    check(now['current'] == P('0.txt') and now['lit'] == ['3.txt'] and frames and all(f == ['3.txt'] for f in frames) and after == {'lit': ['3.txt'], 'current': P('3.txt')},
          'jank J4: a click lights the row clicked at once, before its file arrives, and no frame lights the old one',
          json.dumps({'in the click': now, 'frames': frames[:12], 'after': after}))
    # A click on a folder opens no file: the file on screen keeps its highlight. The arrows still light the next row at once.
    click(page, '#side-list a.row[data-path$="/folder"]')
    fol = page.js('return ' + LIT)
    page.cmd('@eval:filterSession = { seq: 99, list: true }; cursor = current.path; markCursor(); 0')
    key = page.js("sb.filterKey({ seq: 99, key: 'down' }); return " + LIT)
    page.cmd('@wait:0.4')
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    check(fol == ['3.txt'] and key == ['4.txt'], 'jank J4: a click on a folder leaves the file\'s row lit; ↓ lights the next row at once',
          json.dumps([fol, key]))
    # The host refuses the open (unsaved text): no render comes, only the status line; the file on screen is lit again.
    page.render(P('0.txt'))
    page.cmd('@wait:0.3')
    page.cmd("@eval:(() => { window.__ro = sb.render; sb.render = () => {}; return 0; })()")
    click(page, '#side-list a.row[data-path$="/2.txt"]')
    lit = page.js('return ' + LIT)
    page.cmd("@eval:sb.status('Not switched: unsaved text'); 0")
    back = page.js('return [' + LIT + ', sideClicked, cursor === current.path]')
    page.cmd('@eval:sb.render = window.__ro; 0')
    check(lit == ['2.txt'] and back == [['0.txt'], '', True], 'jank J4: an open the host refuses gives the highlight back to the file on screen',
          json.dumps([lit, back]))
    page.cmd('@root:')


def toc_column(page, check, out):
    d = os.path.join(out, 'toc')
    os.makedirs(d)
    body = ('Words in a paragraph that is long enough to fill the measure. ' * 12) + '\n\n'
    notes = {'h0.md': body * 3, 'h2.md': '# A\n\n' + body + '## B\n\n' + body, 'h3.md': '# A\n\n' + body + '## B\n\n' + body + '## C\n\n' + body,
             'h5.md': ''.join(f'## H{i}\n\n' + body for i in range(5))}
    for n, t in notes.items():
        open(os.path.join(d, n), 'w').write(t)
    page.cmd('@root:' + d)
    P = lambda n: os.path.join(d, n)
    TOC = "const t = document.getElementById('toc'), cs = getComputedStyle(t); return [cs.display !== 'none' && cs.visibility === 'visible', t.querySelectorAll('a').length]"
    W = "return Math.round(document.querySelector('#doc p').getBoundingClientRect().width)"
    res, tocs = {}, {}
    for size in ('1100x760', '1300x760', '1500x900'):
        page.cmd('@size:' + size)
        page.render(P('h5.md'))
        page.cmd('@wait:0.3')
        cols = {}
        for n in ('h0.md', 'h3.md', 'h2.md', 'h5.md', 'h0.md'):
            sample(page, {'p': '#doc p'}, 'current.path')
            page.render(P(n))
            page.cmd('@wait:0.2')
            fr = [f for f in sampled(page) if f['extra'] == P(n)]
            cols.setdefault(n, set()).update(spread(fr, 'p'))
            tocs[f'{size} {n}'] = page.js(TOC)
        res[size] = {n: sorted(v) for n, v in cols.items()}
    shown = {k: v for k, v in tocs.items()}
    per = {s: {n: v[0] if len(v) == 1 else None for n, v in c.items()} for s, c in res.items()}
    check(all(None not in c.values() and c['h0.md'] == c['h2.md'] and c['h3.md'] == c['h5.md'] and c['h0.md'][1] >= c['h5.md'][1]
              for c in per.values()) and per['1100x760']['h0.md'][1] > per['1100x760']['h5.md'][1] + 100
          and all(v[0] == (k.split()[1] in ('h3.md', 'h5.md')) and (v[1] > 0) == v[0] for k, v in shown.items()),
          'jank J5: a note with no TOC (auto: under 3 headings) takes the full measure and a long one keeps the TOC and its narrower column; '
          'each note\'s column is the same in every frame from its first, at three panel widths',
          json.dumps({'column [left, width] per size and note': res, 'toc [shown, entries]': shown}))
    page.cmd('@size:1100x760')
    page.render(P('h5.md'))
    with_toc = page.js(W)
    page.render(P('h0.md'))
    page.cmd('@wait:0.2')
    no_toc = page.js(W)
    page.apply(toc='off')
    page.render(P('h5.md'))
    page.cmd('@wait:0.2')
    off = page.js("return [" + W[7:] + ", getComputedStyle(document.getElementById('toc')).display]")
    page.apply(toc='on')
    page.render(P('h2.md'))
    page.cmd('@wait:0.2')
    on = [page.js(W), page.js(TOC)]
    page.apply(width='narrow', toc='auto')
    page.render(P('h0.md'))
    page.cmd('@wait:0.2')
    narrow = page.js(W)
    page.apply(width='medium')
    check(off == [no_toc, 'none'] and on == [with_toc, [True, 2]] and no_toc > with_toc + 100 and narrow < no_toc,
          'jank J5: the TOC off gives every note the full measure, on gives a short note its TOC and column, and the Narrow width still holds',
          json.dumps({'with toc': with_toc, 'no toc': no_toc, 'off [h5 width, toc]': off, 'on [h2 width, toc]': on, 'narrow no toc': narrow}))

    # A live reload that takes the note under 3 headings widens the column and keeps the line being read.
    long = '# A\n\n' + body * 6 + '## B\n\n' + body * 6 + '## C\n\n' + body * 6
    open(P('live.md'), 'w').write(long)
    page.render(P('live.md'))
    page.cmd('@wait:0.3')
    page.cmd('@eval:window.scrollTo(0, document.querySelectorAll("#doc h2")[0].offsetTop - 120); 0')
    page.cmd('@wait:0.3')
    HEAD = "const h = document.querySelectorAll('#doc h2')[0]; return [Math.round(h.getBoundingClientRect().top), " + W[7:] + "]"
    before = page.js(HEAD)
    page.cmd('@eval:sb.render({ ...current, text: current.text.replace("## C\\n", "C\\n") }); 0')
    page.cmd('@wait:0.4')
    after = page.js(HEAD) + [page.js(TOC)[0]]
    check(abs(before[0] - after[0]) <= 2 and after[1] > before[1] + 100 and after[2] is False,
          'jank J5: a live reload that drops the TOC widens the column and keeps the line being read',
          json.dumps({'before [h2 top, width]': before, 'after [h2 top, width, toc]': after}))

    # A redraw while a heading of a 3-heading note is being edited keeps its TOC, so the column does not widen under the caret.
    page.render(P('h3.md'))
    page.cmd('@wait:0.3')
    pre = [page.js(W), page.js(TOC)[0]]
    click(page, '#doc h2')
    page.cmd('@wait:0.3')
    page.cmd('@eval:draw(); 0')
    page.cmd('@wait:0.3')
    mid = [page.js(W), page.js(TOC)[0], page.js('return !!editing && editing.tag')]
    page.cmd('@eval:sb.editEnd({}); 0')
    page.cmd('@wait:0.2')
    check(pre == [with_toc, True] and mid[:2] == pre and mid[2] == 'H2',
          'jank J5: a redraw while a heading is edited, in a note with just enough headings for a TOC, keeps the TOC and the column',
          json.dumps({'read [width, toc]': pre, 'editing [width, toc, tag]': mid}))

    # The reverse: a heading typed into a paragraph does not bring the TOC in while a block is edited, so the column does not
    # narrow under the caret; it comes in once the edit ends. In auto at the third heading, and in on at the first.
    CW = "return Math.round(document.querySelector('#doc > :not(.md-editing)').getBoundingClientRect().width)"
    typed = {}
    for mode, note in (('auto', 'h2.md'), ('on', 'h0.md')):
        page.apply(toc=mode)
        page.render(P(note))
        page.cmd('@wait:0.3')
        pre = [page.js(CW), page.js(TOC)[0]]
        click(page, '#doc > p')
        page.cmd('@wait:0.3')
        sample(page, {'col': '#doc > :not(.md-editing)', 'toc': '#toc'}, '!!editing')
        page.cmd('@eval:sb.editUpdate({ seq: editing.seq, at: editing.start, old: editing.lines, text: "## Third", ver: docVer, selStart: 8, selLen: 0 }); 0')
        page.cmd('@wait:0.2')
        click(page, '#doc > p:not(.md-editing)')
        page.cmd('@wait:0.3')
        fr = [f for f in sampled(page) if f['extra']]
        mid = [spread(fr, 'col'), sorted({f['toc'] is not None for f in fr}), page.js('return !!editing && editing.tag'),
               page.js("return document.querySelectorAll('#doc > :is(h1, h2, h3)').length")]
        page.cmd('@eval:sb.editEnd({}); 0')
        page.cmd('@wait:0.3')
        typed[mode] = {'read [width, toc]': pre, 'editing [cols, toc shown, tag, headings]': mid, 'ended [width, toc]': [page.js(CW), page.js(TOC)[0]]}
    page.apply(toc='auto')
    check(all(t['read [width, toc]'] == [no_toc, False]
              and still(t['editing [cols, toc shown, tag, headings]'][0]) and abs(t['editing [cols, toc shown, tag, headings]'][0][0][1] - no_toc) <= 1
              and t['editing [cols, toc shown, tag, headings]'][1:3] == [[False], 'P']
              and t['editing [cols, toc shown, tag, headings]'][3] == {'auto': 3, 'on': 1}[m]
              and t['ended [width, toc]'] == [with_toc, True] for m, t in typed.items()),
          'jank J5: a heading typed while a block is edited brings no TOC and the column holds; the TOC comes in when the edit ends (auto and on)',
          json.dumps(typed))
    page.cmd('@root:')


def kind_line(page, check, out):
    d = os.path.join(out, 'kind')
    os.makedirs(d)
    open(os.path.join(d, 'a.md'), 'w').write('# Notes\n\nText.\n')
    open(os.path.join(d, 'photo.png'), 'wb').write(SB.make_png(1600, 1000, (40, 120, 200)))
    open(os.path.join(d, 'doc.pdf'), 'wb').write(SB.make_pdf('Hello PDF'))
    open(os.path.join(d, 'scan.tiff'), 'wb').write(b'II*\0' + b'\0' * 64)
    open(os.path.join(d, 'shape.svg'), 'w').write('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300"><rect width="400" height="300" fill="#c33"/></svg>')
    P = lambda n: os.path.join(d, n)
    page.cmd('@root:' + d)
    page.render(P('photo.png'))
    page.cmd('@wait:0.4')
    page.cmd('@eval:window.__png = JSON.parse(JSON.stringify(current)); 0')
    page.render(P('a.md'))
    page.cmd('@wait:0.4')
    # An image, as the extension sends it: in the task that draws it (before WebKit has decoded it) and on every frame after,
    # the kind line, its text and the zoom have the rects they end with.
    R = "[...['#kind', '#kind .kind-text', '#kind .img-zoom']].map((s) => { const r = document.querySelector(s).getBoundingClientRect(); return [Math.round(r.left * 2) / 2, Math.round(r.width * 2) / 2]; })"
    sample(page, {'kind': '#kind', 'text': '#kind .kind-text', 'zoom': '#kind .img-zoom'}, '!!window.__drawn')
    first = page.js('window.__drawn = true; sb.render(window.__png); return ' + R)
    page.cmd('@wait:0.6')
    fr = [f for f in sampled(page) if f['extra']]
    last = page.js('return ' + R)
    img = {k: spread(fr, k) for k in ('kind', 'text', 'zoom')}
    check(fr and all(still(v) for v in img.values()) and all(still([tuple(a), tuple(b)]) for a, b in zip(first, last)),
          'jank J8: an image\'s kind line, its text and its zoom have their final rects in the task that draws it and on every frame after',
          json.dumps({'in the render': first, 'after': last, 'frames': img}))
    G = """const k = document.querySelector('#kind .kind-text'), z = document.querySelector('#kind .img-zoom, #kind .pdf-page');
      return [z && z.textContent, z && Math.round(z.getBoundingClientRect().width), k && Math.round(k.getBoundingClientRect().left)];"""
    steps = [page.js(G)]
    for _ in range(10):
        page.cmd("@eval:zoomImage('+'); 0")
        page.cmd('@wait:0.2')
        steps.append(page.js(G))
    sample(page, {'zoom': '#kind .img-zoom', 'text': '#kind .kind-text'}, "document.querySelector('#kind .img-zoom').textContent")
    page.cmd("@eval:zoomImage('0'); 0")
    page.cmd('@wait:0.6')
    anim = sampled(page)
    labels = {f['extra'] for f in anim}
    check(len({s[0] for s in steps}) > 8 and len({tuple(s[1:]) for s in steps}) == 1 and len(labels) > 3 and still(spread(anim, 'zoom')) and still(spread(anim, 'text')),
          'jank J8: the zoom label keeps its width from 49% to 800% and through the zoom animation, so the kind text never moves',
          json.dumps({'steps': steps, 'animation labels': sorted(labels), 'zoom': spread(anim, 'zoom'), 'text': spread(anim, 'text')}))
    page.render(P('doc.pdf'))
    page.cmd('@wait:0.4')
    page.cmd('@eval:sb.render({ ...current, pages: 120, page: 1 }); 0')
    page.cmd('@wait:0.2')
    pages = []
    for n in (1, 9, 10, 99, 100, 120):
        page.cmd('@eval:sb.pdfPage({ path: current.path, page: ' + str(n) + ', pages: 120 }); 0')
        pages.append(page.js(G))
    check(len({p[0] for p in pages}) == 6 and len({tuple(p[1:]) for p in pages}) == 1,
          'jank J8: the PDF page counter keeps its width from 1 / 120 to 120 / 120', json.dumps(pages))
    page.render(P('scan.tiff'))
    page.cmd('@wait:0.4')
    view = page.js('return current.view')
    b0 = page.js(G)
    page.cmd("@eval:sb.imageZoom({ path: current.path, zoom: 37 }); 0")
    b1 = page.js(G)
    check(view == 'bitmap' and b1[0] == '37%' and b0[1:] == b1[1:], 'jank J8: a bitmap\'s zoom arriving from the extension moves nothing', json.dumps([view, b0, b1]))
    page.render(P('shape.svg'))
    page.cmd('@wait:0.4')
    svg = page.js("""const k = document.getElementById('kind').getBoundingClientRect(), t = document.querySelector('#kind .kind-text').getBoundingClientRect();
      return [!!document.querySelector('#kind .img-zoom'), Math.round(k.right - t.right), document.querySelector('#kind .kind-text').textContent];""")
    check(svg[0] is False and svg[1] == 0 and '400' in svg[2], 'jank J8: an SVG, which has no zoom percentage, keeps no room for one', json.dumps(svg))
    page.cmd('@root:')


def find_field(page, check, out):
    d = os.path.join(out, 'find')
    os.makedirs(d)
    f = os.path.join(d, 'many.txt')
    open(f, 'w').write('alpha beta gamma\n' * 4000)
    page.cmd('@root:' + d)
    page.render(f)
    page.cmd('@wait:0.4')
    page.cmd('@eval:openFind(false); 0')
    sample(page, {'field': '#find-q', 'next': '#find-next'}, "document.getElementById('find-count').textContent")
    seen = []
    for q in ('', 'a', 'al', 'alz', 'alpha', 'e', 'gamma', ''):
        r = page.js('findField.value = ' + json.dumps(q) + "; findInput(findField.value); const r = document.getElementById('find-q').getBoundingClientRect(); "
                    "return [document.getElementById('find-count').textContent, Math.round(r.left), Math.round(r.width)]")
        seen.append(r)
        page.cmd('@wait:0.25')
    fr = sampled(page)
    page.cmd('@eval:closeFind(); 0')
    counts = {f['extra'] for f in fr}
    check(len(counts) > 3 and len({tuple(s[1:]) for s in seen}) == 1 and still(spread(fr, 'field')),
          'jank J9: the find field stays where it is, every frame, as the count appears, changes and goes', json.dumps({'typed': seen, 'field': spread(fr, 'field')}))
    page.cmd('@root:')


def edit_gutter(page, check, out):
    d = os.path.join(out, 'gutter')
    os.makedirs(d)
    POS = """const w = document.createTreeWalker(document.querySelector('#doc pre.code code'), NodeFilter.SHOW_TEXT); let t = w.nextNode();
      while (t && !t.data.length) t = w.nextNode(); const r = document.createRange(); r.setStart(t, 0); r.setEnd(t, 1);
      return [Math.round(r.getBoundingClientRect().left), Math.round(document.querySelector('#doc .gutter').getBoundingClientRect().width)];"""
    res = {}
    page.cmd('@root:' + d)
    for lines in (99, 999):
        g = os.path.join(d, f'n{lines}.ts')
        open(g, 'w').write(''.join(f'let a{i} = {i};\n' for i in range(1, lines + 1)))
        page.render(g)
        page.cmd('@wait:0.4')
        click(page, '#doc pre.code')
        page.cmd('@wait:0.3')
        before = page.js(POS)
        sample(page, {'gutter': '#doc .gutter'})
        n = page.js('return editing.text.length')
        page.cmd('@eval:sb.textUpdate({ seq: editing.seq, from: ' + str(n) + ', to: ' + str(n) + ', insert: "x\\n", selStart: ' + str(n + 2) + ', selLen: 0, keyTime: 0 }); 0')
        page.cmd('@wait:0.2')
        after = page.js(POS)
        lc = page.js("return document.querySelector('#doc .gutter').textContent.split('\\n').length")
        fr = sampled(page)
        page.cmd('@eval:sb.editEnd({}); 0')
        res[lines] = {'before': before, 'after': after, 'gutter lines': lc, 'frames': spread(fr, 'gutter')}
    check(all(v['before'] == v['after'] and v['gutter lines'] == k + 2 and still(v['frames']) for k, v in res.items()),
          'jank J10: typing past line 99 or 999 keeps the gutter\'s width, so no character moves', json.dumps(res))
    page.cmd('@root:')


def overview_rows(page, check, out):
    d = os.path.join(out, 'overview')
    os.makedirs(d)
    for i in range(1, 8):
        open(os.path.join(d, f'f{i}.txt'), 'w').write('x\n')
    page.cmd('@folder:' + d)
    page.cmd('@wait:0.5')
    view = page.js('return current.view')
    page.cmd("@eval:document.querySelectorAll('#doc .ov-row').forEach((a) => { a.__kept = 1; }); 0")
    page.cmd('@relist')
    page.cmd('@wait:0.3')
    open(os.path.join(d, 'f0.txt'), 'w').write('new\n')
    page.cmd('@relist')
    page.cmd('@wait:0.3')
    rows = page.js("const r = [...document.querySelectorAll('#doc .ov-row')]; return [r.length, r.filter((a) => a.__kept).length, r.map((a) => a.querySelector('.ov-row-name').textContent)]")
    check(view == 'overview' and rows[0] == 8 and rows[1] == 7 and rows[2][0] == 'f0.txt',
          'jank J13: a listing of the root keeps the overview\'s rows (no hover flicker); a new file is put in its place', json.dumps([view, rows]))
    page.cmd('@root:')


def tooltips(page, check, out):
    LONG = 'a-very-long-folder-name-that-keeps-going-and-going'
    deep = os.path.join(out, 'tips', LONG, LONG + '-2')
    os.makedirs(deep)
    name = 'quarterly-financial-report-final-version-reviewed-by-everyone-2026-09-30'
    f = os.path.join(deep, name + '.docx')
    open(f, 'wb').write(b'PK\3\4' + b'\0' * 100)
    open(os.path.join(deep, 'photo.png'), 'wb').write(SB.make_png(1600, 1000, (40, 120, 200)))
    page.cmd('@size:760x600')
    page.cmd('@root:' + os.path.join(out, 'tips'))
    page.render(f)
    page.cmd('@wait:0.4')
    T = """const k = document.getElementById('kind'), t = k.querySelector('.kind-text'), c = document.getElementById('crumbs');
      return { text: t.textContent, cut: t.scrollWidth > t.clientWidth + 1, title: k.title, crumbs: c.title,
        steps: [...c.querySelectorAll('button.crumb')].map((b) => [b.textContent, b.title, Math.round(b.getBoundingClientRect().width)]) };"""
    a = page.js(T)
    page.render(os.path.join(deep, 'photo.png'))
    page.cmd('@wait:0.4')
    b = page.js(T)
    page.cmd('@size:1100x760')
    ok_kind = a['cut'] and a['title'] == a['text'] and b['title'] == b['text'] and '×' in b['title']
    ok_crumbs = a['crumbs'] == f and len(a['steps']) == 3 and any(s[2] < 30 for s in a['steps']) and all(
        s[1].split('\n')[0] == s[0] and s[1].split('\n')[1] in ('Show in the sidebar', 'Show the folder overview') for s in a['steps'])
    check(ok_kind and ok_crumbs, 'jank J14: a cut-off kind line and squeezed folder crumbs say in full what they are on hover; the path stays on the crumbs',
          json.dumps([a, b]))
    page.cmd('@root:')


def search_status(page, check, out):
    d = os.path.join(out, 'status')
    os.makedirs(d)
    for i in range(80):
        open(os.path.join(d, f'note-{i:02d}.txt'), 'w').write(f'alpha {i}\n')
    page.cmd('@root:' + d)
    page.render(os.path.join(d, 'note-00.txt'))
    page.cmd('@wait:0.4')
    page.apply(sidebarWidth=160)
    page.cmd('@wait:0.3')
    G = """const l = document.getElementById('side-list').getBoundingClientRect(), m = document.getElementById('side-more');
      return [Math.round(l.top), Math.round(l.height), m.hidden ? null : m.textContent];"""
    empty = {'names': page.js(G)}
    page.cmd("@eval:setSideMode('contents'); 0")
    page.cmd('@wait:0.2')
    empty['contents'] = page.js(G)
    page.cmd("@eval:filterField.value = 'a'; setSideQuery('a'); 0")
    page.cmd('@wait:0.2')
    one = page.js(G)
    page.cmd("@eval:filterField.value = 'al'; setSideQuery('al'); 0")
    sample(page, {'list': '#side-list'}, "document.getElementById('side-more').textContent")
    seen = {'2 chars': page.js(G)}
    page.cmd("@eval:filterField.value = 'alp'; setSideQuery('alp'); searchSeq++; hits = { ...hits, seq: searchSeq, done: false, total: 56789, searched: 1234, version: hits.version + 1 }; renderSidebar(); 0")
    seen['searching'] = page.js(G)
    page.cmd("@eval:hits = { ...hits, done: true, list: hits.list.length ? hits.list : [{ path: current.path, name: 'note-00.txt', icon: 'text', count: 1, line: 1, snippet: 'alpha' }], version: hits.version + 1 }; renderSidebar(); 0")
    seen['found'] = page.js(G)
    page.cmd("@eval:hits = { ...hits, stopped: 'files', total: 56789, version: hits.version + 1 }; renderSidebar(); 0")
    seen['stopped'] = page.js(G)
    page.cmd('@wait:0.2')
    fr = sampled(page)
    page.cmd("@eval:filterField.value = ''; setSideQuery(''); setSideMode('names'); 0")
    page.apply(sidebarWidth=240)
    texts = {f['extra'] for f in fr}
    check(one == empty['contents'], 'jank J15: one character, which searches nothing, takes no room from the list', json.dumps([one, empty]))
    check(len({v[2] for v in seen.values()}) >= 2 and len({tuple(v[:2]) for v in seen.values()}) == 1 and still(spread(fr, 'list', (2, 3))) and len(texts) >= 3,
          'jank J15: the Contents search\'s status line keeps the list\'s size, every frame, as the search runs, wraps and changes', json.dumps(seen))
    check(empty['contents'] == empty['names'] and empty['names'][2] is None,
          'jank J15: with the field empty, Contents leaves the list the size it is in Names: no room is kept for a status yet', json.dumps(empty))
    page.cmd('@root:')


def lazy_math(page, check, out):
    d = os.path.join(out, 'math')
    os.makedirs(d)
    tex = '# Euler\n\nInline $e^{i\\pi} + 1 = 0$ here.\n\n$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$\n\n## With $x^2$ in a heading\n\n## b\n\n## c\n'
    files = {'plain.md': '# Notes\n\nNo formulas here.\n\n## a\n\n## b\n', 'rows.csv': 'a,b\n1,2\n', 'code.ts': 'export const a = 1;\n', 'math.md': tex}
    for n, t in files.items():
        open(os.path.join(d, n), 'w').write(t)
    page.cmd('@load:{}')
    page.cmd('@root:' + d)
    for n in ('plain.md', 'rows.csv', 'code.ts', 'plain.md'):
        page.render(os.path.join(d, n))
        page.cmd('@wait:0.2')
    page.cmd('@eval:sb.warm(); 0')
    page.cmd('@wait:0.3')
    none = page.js("return [typeof window.katex, [...document.querySelectorAll('script')].filter((s) => /katex/.test(s.src)).length]")
    check(none == ['undefined', 0], 'katex: a page with no math (Markdown, a table, code, the warm-up) never loads KaTeX', json.dumps(none))
    RAW = """(() => { const c = document.getElementById('doc').cloneNode(true); c.querySelectorAll('.katex-mathml').forEach((n) => n.remove());
      return /\\\\(int|frac|pi)|\\^\\{|\\$/.test(c.textContent); })()"""
    sample(page, {}, RAW)
    now = page.js('window.__math = true; sb.render({ ...current, path: ' + json.dumps(os.path.join(d, 'math.md')) + ", name: 'math.md', text: "
                  + json.dumps(tex) + " }); return { raw: " + RAW + ", holders: document.querySelectorAll('#doc span.tex:empty').length, "
                  "drawn: document.querySelectorAll('#doc .katex').length };")
    page.cmd('@wait:0.8')
    raw = [f['extra'] for f in sampled(page)]
    after = page.js("""return { raw: """ + RAW + """, holders: document.querySelectorAll('#doc span.tex:empty').length, drawn: document.querySelectorAll('#doc .katex').length,
      display: document.querySelectorAll('#doc .katex-display').length, toc: [...document.querySelectorAll('#toc a')].map((a) => a.textContent),
      loaded: typeof window.katex };""")
    check(not now['raw'] and now['holders'] + now['drawn'] == 3 and not any(raw) and after['holders'] == 0 and after['drawn'] == 3 and after['display'] == 1
          and not after['raw'] and after['loaded'] == 'object' and any('2' in t for t in after['toc']),
          'katex: a note with math loads it and draws every formula (inline, display, in a heading and its TOC entry); until then a placeholder, '
          'never the TeX, on any frame', json.dumps({'in the render': now, 'raw TeX on a frame': any(raw), 'after': after}))
    page.cmd('@root:')


def sidebar_holds(page, check, out):
    d = os.path.join(out, 'holds')
    os.makedirs(os.path.join(d, 'zfolder'))
    for i in range(30):
        open(os.path.join(d, 'zfolder', f'z{i:02d}.txt'), 'w').write(f'{i}\n')
    for i in range(80):
        open(os.path.join(d, f'f{i:02d}.txt'), 'w').write(f'{i}\n')
    P = lambda *n: os.path.join(d, *n)
    TOP = "return document.getElementById('side-list').scrollTop"
    scroll = lambda t: page.cmd("@eval:(() => { const l = document.getElementById('side-list'); l.scrollTop = " + str(t)
                                + "; l.dispatchEvent(new Event('scroll')); return 0; })()")
    page.cmd('@root:' + d)
    page.cmd('@size:1000x500')
    page.render(P('f05.txt'))
    page.cmd('@wait:0.4')

    # A click opens a file whose render is slow; the wheel moves the list meanwhile; the render does not pull it back.
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    scroll(20 * 24)
    page.cmd('@wait:0.1')
    page.cmd("@eval:(() => { window.__r = []; window.__ro = sb.render; sb.render = (m) => { window.__r.push(m); }; return 0; })()")
    t0 = page.js(TOP)
    page.cmd('@nativeclick:#side-list a.row[data-path="' + P('f25.txt') + '"]')
    page.cmd('@nativescroll:#side-list,0,-400')
    page.cmd('@wait:0.4')
    t1 = page.js(TOP)
    held = page.js("sb.render = window.__ro; for (const m of window.__r) sb.render(m); return window.__r.length")
    page.cmd('@wait:0.6')
    t2 = page.js(TOP)
    cur = page.js('return current.path')
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    check(held >= 1 and t1 != t0 and t2 == t1 and cur == P('f25.txt'), 'sidebar: a wheel after a click, before the file arrives, is not undone when it does',
          json.dumps({'before': t0, 'after the wheel': t1, 'after the render': t2, 'held renders': held}))

    # A file opened in a folder not yet listed owes a reveal; a press on the list (a scroll bar drag) cancels it like the wheel.
    page.render(P('f00.txt'))
    page.cmd('@wait:0.3')
    page.cmd("@eval:(() => { window.__held = []; window.__so = sb.setFiles; sb.setFiles = (m) => { if (m && m.dir === " + json.dumps(P('zfolder'))
             + ") window.__held.push(m); else window.__so(m); }; return 0; })()")
    page.cmd('@eval:expanded().delete(' + json.dumps(P('zfolder')) + '); requested.delete(' + json.dumps(P('zfolder')) + '); tree.dirs.delete('
             + json.dumps(P('zfolder')) + '); treeVersion++; renderSidebar(); 0')
    page.render(P('zfolder', 'z25.txt'))
    page.cmd('@wait:0.3')
    owed = page.js("return sideOwed === current.path")
    page.cmd("@eval:(() => { const l = document.getElementById('side-list'); l.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); "
             "l.scrollTop = 600; l.dispatchEvent(new Event('scroll')); l.dispatchEvent(new PointerEvent('pointerup', { bubbles: true })); return 0; })()")
    page.cmd('@wait:0.1')
    # What is on screen: the first row in view and where it is. The listing puts rows in above it, which must not move it.
    SEEN = """const l = document.getElementById('side-list'), b = l.getBoundingClientRect();
      const f = [...l.querySelectorAll('a.row')].find((a) => a.getBoundingClientRect().bottom > b.top);
      return [f.dataset.path.split('/').pop(), Math.round(f.getBoundingClientRect().top - b.top), l.scrollTop];"""
    a = page.js(SEEN)
    n = page.js("sb.setFiles = window.__so; for (const m of window.__held) sb.setFiles(m); return window.__held.length")
    page.cmd('@wait:0.5')
    b = page.js(SEEN)
    check(owed and n >= 1 and a[2] == 600 and a[:2] == b[:2], 'sidebar: the list scrolled by its scroll bar while a listing is on its way does not jump when it arrives',
          json.dumps({'owed': owed, 'held listings': n, 'scrolled to [first row, y, scrollTop]': a, 'after the listing': b}))

    # Opened afresh on the last file, the list scrolls to its end with the top row whole and the file's row whole.
    page.cmd('@root:' + P('zfolder'))
    page.render(P('zfolder', 'z00.txt'))
    page.cmd('@root:' + d)
    ends = {}
    for size in ('1000x500', '1000x511', '1000x523'):
        page.cmd('@size:' + size)
        page.cmd('@root:' + P('zfolder'))
        page.render(P('zfolder', 'z00.txt'))
        page.cmd('@root:' + d)
        page.render(P('f79.txt'))
        page.cmd('@wait:0.4')
        ends[size] = page.js("""const l = document.getElementById('side-list'), b = l.getBoundingClientRect(), r = l.querySelector('a.row.active').getBoundingClientRect();
          const first = [...l.querySelectorAll('a.row')].find((a) => a.getBoundingClientRect().bottom > b.top).getBoundingClientRect();
          return { top: l.scrollTop, firstY: Math.round(first.top - b.top), low: Math.round(b.top + l.clientHeight - r.bottom) };""")
    page.cmd('@size:1100x760')
    check(all(e['firstY'] == 0 and e['low'] >= 0 for e in ends.values()), 'sidebar: opened on the last file, the top row is whole and so is the file\'s',
          json.dumps(ends))

    # A throw while revealFolder renders leaves no hold behind.
    held = page.js("const o = renderSidebar; renderSidebar = () => { throw new Error('x'); }; try { revealFolder(" + json.dumps(P('zfolder'))
                   + "); } catch (e) { } finally { renderSidebar = o; } return sideHold;")
    check(held is False, 'sidebar: a reveal that throws while it renders still releases its hold', json.dumps(held))
    page.cmd('@root:')


def edit_chrome(page, check, out):
    """N7: the toolbar row through an edit of a code file: read, edit, type past line 99, end, Undo arrives, edit again, end."""
    d = os.path.join(out, 'editchrome')
    os.makedirs(d)
    f = os.path.join(d, 'n98.ts')
    open(f, 'w').write(''.join(f'let a{i} = {i};\n' for i in range(1, 99)))
    page.cmd('@root:' + d)
    page.apply(stats=True)
    page.render(f)
    page.cmd('@wait:0.4')
    STATE = """const R = (id) => { const e = document.getElementById(id), r = e.getBoundingClientRect(); return getComputedStyle(e).display === 'none' ? null : Math.round(r.left); };
      const w = document.createTreeWalker(document.querySelector('#doc pre.code code') || document.querySelector('#doc pre.code'), NodeFilter.SHOW_TEXT); let t = w.nextNode();
      while (t && !t.data.length) t = w.nextNode(); const rg = document.createRange(); rg.setStart(t, 0); rg.setEnd(t, 1);
      return [R('kind'), Math.round(rg.getBoundingClientRect().left), document.getElementById('stats').textContent, R('undo') !== null,
        +document.querySelector('#doc .gutter').dataset.n];"""
    seq = {'read': page.js(STATE)}
    click(page, '#doc pre.code')
    page.cmd('@wait:0.3')
    seq['editing'] = page.js(STATE)
    n = page.js('return editing.text.length')
    page.cmd('@eval:sb.textUpdate({ seq: editing.seq, from: ' + str(n) + ', to: ' + str(n) + ', insert: "x\\ny\\nz\\n", selStart: ' + str(n + 6) + ', selLen: 0, keyTime: 0 }); 0')
    page.cmd('@wait:0.2')
    seq['typed to 101 lines'] = page.js(STATE)
    page.cmd('@eval:sb.editEnd({}); 0')
    page.cmd('@wait:0.2')
    seq['ended'] = page.js(STATE)
    page.cmd('@eval:sb.undoState({ undo: true, redo: false }); 0')
    page.cmd('@wait:0.1')
    seq['undo available'] = page.js(STATE)
    click(page, '#doc pre.code')
    page.cmd('@wait:0.3')
    seq['editing again'] = page.js(STATE)
    page.cmd('@eval:sb.editEnd({}); 0')
    page.cmd('@wait:0.2')
    seq['ended again'] = page.js(STATE)
    page.cmd('@eval:sb.undoState({ undo: false, redo: false }); 0')
    page.apply(stats=False)
    v = list(seq.values())
    check(len({s[0] for s in v}) == 1 and len({s[1] for s in v}) == 1 and seq['undo available'][3] and not seq['editing again'][3]
          and [s[2] for s in v] == ['98 lines'] * 2 + ['101 lines'] * 5,
          'jank N7: through an edit, Undo coming and going and typing past line 99, the kind text and the code never move; the line count stays live',
          json.dumps({k: dict(zip(['kind left', 'first char left', 'stats', 'undo shown', 'gutter lines'], s)) for k, s in seq.items()}))
    page.cmd('@root:')


def stats_switch(page, check, out):
    """N9: the reading stats never show the previous file's count beside the new file's kind; a short note's first frame is final."""
    d = os.path.join(out, 'statsswitch')
    os.makedirs(d)
    files = {'big.md': ''.join(f'## S{i}\n\n' + 'word ' * 300 + '\n\n' for i in range(40)), 'small.md': '# Small\n\nA few words.\n',
             'code.ts': ''.join(f'const v{i} = {i};\n' for i in range(12345))}
    for n, t in files.items():
        open(os.path.join(d, n), 'w').write(t)
    page.cmd('@root:' + d)
    page.apply(stats=True)
    ST = "[document.getElementById('stats').textContent, (document.querySelector('#kind .kind-text') || {}).textContent || '', Math.round(document.getElementById('kind').getBoundingClientRect().left)]"
    res = {}
    for a, b in [('big.md', 'small.md'), ('code.ts', 'small.md'), ('small.md', 'big.md')]:
        page.render(os.path.join(d, b))
        page.cmd('@wait:0.3')
        page.cmd('@eval:window.__b = current; 0')
        page.render(os.path.join(d, a))
        page.cmd('@wait:0.4')
        old = page.js('return ' + ST)
        sample(page, {}, ST)
        now = page.js('sb.render(window.__b); return ' + ST)
        page.cmd('@wait:0.4')
        fr = [now] + [f['extra'] for f in sampled(page)]
        new = [x for x in fr if x[1] != old[1]]
        res[f'{a} -> {b}'] = {'before': old, 'frames [stats, kind, kind left]': [list(x) for x in dict.fromkeys(tuple(x) for x in fr)]}
        ok_old = all(x[0] != old[0] or x[0] == '' for x in new)
        ok_small = b != 'small.md' or len({tuple(x) for x in new}) == 1
        res[f'{a} -> {b}']['ok'] = [ok_old, ok_small]
    page.apply(stats=False)
    check(all(all(v['ok']) for v in res.values()), 'jank N9: a new file never shows the last file\'s stats; a short note\'s first frame has its own count, so its kind does not move after',
          json.dumps(res))
    page.cmd('@root:')


def toc_kept(page, check, out):
    """N12: the TOC's entries survive a live reload and a setting's redraw; a renamed or added heading changes only its entry."""
    d = os.path.join(out, 'tockept')
    os.makedirs(d)
    f = os.path.join(d, 'toc.md')
    open(f, 'w').write(''.join(f'## Heading {i}\n\n' + 'text ' * 100 + '\n\n' for i in range(30)))
    page.cmd('@size:1300x760')
    page.cmd('@root:' + d)
    page.render(f)
    page.cmd('@wait:0.4')
    MARK = "@eval:document.querySelectorAll('#toc a').forEach((a) => { a.__mark = 1; }); 0"
    KEPT = "const a = [...document.querySelectorAll('#toc a')]; return [a.length, a.filter((x) => x.__mark).length, a[3].textContent, a.map((x) => x.dataset.toc).join() === a.map((x, i) => i).join()]"
    page.cmd(MARK)
    page.cmd('@eval:sb.render({ ...current, text: current.text + "\\n" }); 0')
    page.cmd('@wait:0.3')
    reload = page.js(KEPT)
    page.cmd(MARK)
    page.apply(math=False)
    page.cmd('@wait:0.3')
    setting = page.js(KEPT)
    page.apply(math=True)
    page.cmd(MARK)
    page.cmd('@eval:sb.render({ ...current, text: current.text.replace("## Heading 3\\n", "## Renamed\\n") + "\\n## Heading 30\\n\\nmore\\n" }); 0')
    page.cmd('@wait:0.3')
    renamed = page.js(KEPT)
    page.cmd('@size:1100x760')
    check(reload == [30, 30, 'Heading 3', True] and setting == [30, 30, 'Heading 3', True] and renamed == [31, 30, 'Renamed', True],
          'jank N12: the TOC keeps its entries through a live reload and a setting (no hover flicker); a renamed heading changes in place and a new one is added',
          json.dumps({'reload [entries, kept, 4th, indices]': reload, 'setting': setting, 'renamed + added': renamed}))
    page.cmd('@root:')


def kind_counters(page, check, out):
    """N15: an archive entry's "N of M" and a media file's late info keep the kind line's left edge."""
    import wave, zipfile
    d = os.path.join(out, 'counters')
    os.makedirs(d)
    z = os.path.join(d, 'twelve.zip')
    with zipfile.ZipFile(z, 'w') as zz:
        for i in range(12):
            zz.writestr(f'f{i:02d}.txt', f'file {i:02d}\n')
    with wave.open(os.path.join(d, 'song.wav'), 'wb') as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(8000), w.writeframes(b'\0\0' * 8000)
    page.cmd('@size:1300x760')
    page.cmd('@root:' + d)
    K = "const k = document.getElementById('kind'); return [k.textContent, Math.round(k.getBoundingClientRect().left), k.title];"
    page.render(z)
    page.cmd('@wait:0.8')
    entries = []
    for key in ('f07.txt', 'f08.txt', 'f09.txt', 'f11.txt'):
        page.cmd("@eval:(() => { const r = [...document.querySelectorAll('#doc tr.arc-file')].find((t) => t.dataset.key === " + json.dumps(key)
                 + "); openEntry(r.querySelector('.arc-entry').dataset.entry, r.dataset.key); })(); 0")
        page.cmd('@wait:0.6')
        entries.append(page.js(K))
        page.cmd('@eval:archiveBack(); 0')
        page.cmd('@wait:0.6')
    page.render(os.path.join(d, 'song.wav'))
    page.cmd('@wait:0.5')
    media = {'before': page.js(K)}
    for text in ('0:01', '1920 × 1080 · 1:02:03'):
        page.cmd('@eval:sb.mediaInfo({ path: current.path, text: ' + json.dumps(text) + ' }); 0')
        media[text] = page.js(K)
    page.cmd('@size:1100x760')
    check(len({e[1] for e in entries}) == 1 and [e[0].endswith(f' of 12') for e in entries] == [True] * 4 and '10 of 12' in entries[2][2]
          and len({m[1] for m in media.values()}) == 1 and '1:02:03' in media['1920 × 1080 · 1:02:03'][2],
          'jank N15: stepping an archive\'s files ("8 of 12" to "12 of 12") and a media file\'s length arriving late keep the kind line\'s left edge; its tooltip says all of it',
          json.dumps({'entries [text, left, title]': entries, 'media': media}))
    page.cmd('@root:')


def mermaid_width(page, check, out):
    """N8: diagrams drawn before the column's width changed stay up through the next redraw; no fade, no blank frame."""
    d = os.path.join(out, 'mmwidth')
    os.makedirs(d)
    dia = '```mermaid\ngraph TD\n  A[Start] --> B{Is it?}\n  B -->|Yes| C[OK]\n  C --> D[Rethink]\n  D --> B\n  B ---->|No| E[End]\n```\n\n'
    f = os.path.join(d, 'dia.md')
    open(f, 'w').write('# Diagrams\n\n' + ''.join(f'## D{i}\n\n' + dia + 'Text after the diagram.\n\n' for i in range(4)))
    page.cmd('@root:' + d)
    page.apply(mermaid=True)
    page.render(f)
    page.cmd('@wait:2.0')
    S = """[...document.querySelectorAll('#doc pre.mermaid')].map((n) => [!!n.querySelector('svg'), n.classList.contains('mm-wait'),
      n.querySelector('svg') ? +getComputedStyle(n.querySelector('svg')).opacity * +getComputedStyle(n).opacity : 0])
      .reduce((a, x) => [a[0] + x[0], a[1] + x[1], Math.min(a[2], x[2])], [0, 0, 1])"""
    res = {}
    for label, act, undo in [('sidebar hidden', {'sidebarCollapsed': True}, {'sidebarCollapsed': False}), ('wide', {'width': 'wide'}, {'width': 'medium'})]:
        page.apply(**act)
        page.cmd('@wait:0.6')
        sample(page, {}, S)
        now = page.js('sb.render({ ...current, text: current.text + "\\n" }); return ' + S)
        page.cmd('@wait:2.0')
        fr = [now] + [f['extra'] for f in sampled(page)]
        res[label] = {'[drawn, placeholders, least opacity] seen': sorted({tuple(x) for x in fr}),
                      'redrawn at the new width': page.js("return document.querySelectorAll('#doc pre.mermaid.mm-stale').length === 0")}
        page.apply(**undo)
        page.cmd('@wait:0.6')
    page.apply(mermaid=False)
    check(all(v['[drawn, placeholders, least opacity] seen'] == [(4, 0, 1)] and v['redrawn at the new width'] for v in res.values()),
          'jank N8: after the column\'s width changed, a redraw keeps every diagram drawn on every frame (no blank, no fade) and redraws it at the new width',
          json.dumps(res))
    page.cmd('@root:')


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    try:
        lazy_math(page, check, page.out)
        page.cmd('@size:1100x760')
        for fn in (sidebar_holds, click_lights_row, toc_column, kind_line, find_field, edit_gutter, overview_rows, tooltips, search_status,
                   edit_chrome, stats_switch, toc_kept, kind_counters, mermaid_width):
            fn(page, check, page.out)
        SB.steady_chrome(page, check, os.path.join(page.out, 'sc'))
        SB.steady_list(page, check, os.path.join(page.out, 'sl'))
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l or 'csp blocked' in l]
        check(not errs, 'no CSP violations or page errors logged', json.dumps(errs)[:300])
        page.close()
    finally:
        if page.proc.poll() is None:
            page.close()
        shutil.rmtree(page.out, ignore_errors=True)
    print(f'\n{sum(results)}/{len(results)} jankchrome checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
