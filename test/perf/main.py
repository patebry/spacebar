#!/usr/bin/env python3
"""The main thread stays free, in the page on its own (the offscreen harness, test/web/main.swift). This WebKit reports no
`longtask` entries, so a block is timed the way a person feels it: a message posted to itself, over and over, measures the
longest gap between two of them (any task, a frame's layout too), and animation frames are timed alongside.

Long code and Raw JSON are highlighted a slice at a time, the part on screen first, with no text moving as the colour lands;
a large note follows the sidebar's animation and a change on disk without long frames."""
import json, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from webthemes import Page

# The longest task between two heartbeats, and the longest gap between animation frames, from the frame it starts on.
BEAT = """const H = window.__hb = { task: 0, frame: 0, stop: false };
  requestAnimationFrame((t0) => {
    const ch = new MessageChannel(); let last = performance.now(), lastF = t0;
    ch.port1.onmessage = () => { const t = performance.now(); H.task = Math.max(H.task, t - last); last = t; if (!H.stop) ch.port2.postMessage(0); };
    ch.port2.postMessage(0);
    const f = (t) => { H.frame = Math.max(H.frame, t - lastF); lastF = t; if (!H.stop) requestAnimationFrame(f); };
    requestAnimationFrame(f);
  }); return 1;"""
BEATEN = 'window.__hb.stop = true; return [Math.round(window.__hb.task), Math.round(window.__hb.frame)]'
LONG_TASK = 50

# Highlighting so far: the share of the text inside a token, at the window's top line and at the file's end.
LIT = """const code = document.querySelector('#doc pre.code code'), bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h')) || 40;
  const up = (n) => (n.nodeType === 1 ? n : n.parentElement);
  const lit = (n) => !!(n && up(n).closest('#doc pre.code code span[class^=hljs-]'));
  const w = document.createTreeWalker(code, NodeFilter.SHOW_TEXT); let n, last = null, comment = [];
  while ((n = w.nextNode())) { if (n.data.trim()) last = n; if (n.data.includes('that runs over')) comment.push(!!up(n).closest('.hljs-comment')); }
  const box = code.getBoundingClientRect(), hit = document.caretRangeFromPoint(box.left + 30, bar + 30), part = hit && up(hit.startContainer).closest('.tpart');
  return { tokens: code.querySelectorAll('span[class^=hljs-]').length, topLit: part ? !!part.querySelector('span[class^=hljs-]') : !!hit && lit(hit.startContainer),
    endLit: lit(last), comment: comment.length ? comment.every(Boolean) : null, same: code.textContent === current.text };"""

# Where the text is: a character on the top line and one at the end of the window's last line, the page's height and the code's width.
PLACE = """const code = document.querySelector('#doc pre.code code'), bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h')) || 40;
  const at = (x, y) => { const r = document.caretRangeFromPoint(x, y); if (!r) return null; const q = document.createRange();
    q.setStart(r.startContainer, r.startOffset); q.setEnd(r.startContainer, Math.min(r.startContainer.length, r.startOffset + 1)); const b = q.getBoundingClientRect();
    const pre = document.createRange(); pre.selectNodeContents(code); pre.setEnd(r.startContainer, r.startOffset);
    return [pre.toString().length, Math.round(b.left * 2) / 2, Math.round(b.top * 2) / 2]; };
  const box = code.getBoundingClientRect();
  return [at(box.left + 60, bar + 30), at(box.left + 300, innerHeight - 30), document.scrollingElement.scrollHeight, Math.round(box.width)];"""


def highlight_slices(page, check, out):
    d = os.path.join(out, 'hl')
    os.makedirs(d)
    line = 'export function fn(a: number, b: string): string { return `${a}-${b}`; } // comment\n'
    block = '/* a block comment\n\n   that runs over a blank line */\nconst s = "a string";\n\n'
    files = {}
    for kb in (100, 480):
        body = line * (kb * 1024 // len(line) // 2)
        files[f'c{kb}.ts'] = body + block * 4 + body
    files['j250.json'] = json.dumps([{'id': i, 'name': f'item {i}', 'tags': ['a', 'b'], 'ok': True} for i in range(250 * 1024 // 55)], indent=1)
    for n, t in files.items():
        open(os.path.join(d, n), 'w').write(t)
    page.cmd('@size:1100x760')
    page.cmd('@root:' + d)
    res = {}
    for n, t in files.items():
        f = os.path.join(d, n)
        page.render(f)
        page.cmd('@wait:2.5')
        if n.endswith('.json'):
            page.js("document.getElementById('raw').click(); " + BEAT)
        else:
            page.cmd('@eval:window.__shown = current; 0')
            page.render(os.path.join(d, 'j250.json'))
            page.cmd('@wait:0.3')
            page.js('sb.render(window.__shown); ' + BEAT)
        plain = page.js(PLACE)
        page.cmd('@wait:2.5')
        lit = page.js(LIT)
        res[n] = {'longest [task, frame] ms': page.js(BEATEN), 'plain': plain, 'lit': page.js(PLACE), 'highlighting': lit}
        if n.endswith('.json'):
            page.cmd("@eval:document.getElementById('raw').click(); 0")
    ok = all(v['longest [task, frame] ms'][0] < LONG_TASK and v['plain'] == v['lit'] and v['highlighting']['tokens'] > 100
             and v['highlighting']['endLit'] and v['highlighting']['same'] and v['highlighting']['comment'] is not False for v in res.values())
    check(ok, f'N4: code of 100 and 480 KB and Raw JSON of 250 KB are highlighted with no task over {LONG_TASK} ms, to the last line, '
          'no character moves as the colour lands, and a comment cut by a blank line is still one comment', json.dumps(res))

    # Opened scrolled to its middle (a file shown again keeps its place): the lines on screen are lit first, while the end is still plain.
    page.render(os.path.join(d, 'c480.ts'))
    page.cmd('@wait:2.5')
    page.cmd('@eval:window.__c480 = current; 0')
    page.render(os.path.join(d, 'j250.json'))
    page.cmd('@wait:0.3')
    page.js('sb.render(window.__c480); window.scrollTo(0, document.scrollingElement.scrollHeight / 2); return 1')
    page.cmd('@wait:0.15')
    early = page.js(LIT)
    page.cmd('@wait:2.5')
    late = page.js(LIT)
    check(early['topLit'] and not early['endLit'] and late['topLit'] and late['endLit'],
          'N4: a long file opened in its middle is lit on screen first; the rest follows', json.dumps({'after 150 ms': early, 'after 2.6 s': late}))
    page.cmd('@root:')


# Frame gaps from the next frame on, for `n` frames.
GAPS = """window.__gaps = []; let last = 0, n = 0; const f = (t) => { if (last) window.__gaps.push(Math.round(t - last)); last = t; if (++n < NFR) requestAnimationFrame(f); };
  requestAnimationFrame(f); return 1;"""
# The block at the top of the page and its top, and the character starting the line at the top (by its offset in #doc) and its top:
# a block running under the toolbar row is held by that line, so the block's own top moves as the lines above it rewrap.
TOPBLOCK = """const bar = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--bar-h')) || 40, d = document.getElementById('doc');
  const b = [...d.children].find((k) => k.getBoundingClientRect().bottom > bar + 1);
  const top = (o) => { const w = document.createTreeWalker(d, NodeFilter.SHOW_TEXT); let n = 0, t;
    while ((t = w.nextNode()) && n + t.length <= o) n += t.length;
    const k = document.createRange(); k.setStart(t, o - n); k.setEnd(t, o - n + 1); return k.getClientRects()[0].top; };
  if (window.__topOff === undefined) {
    const r = document.caretRangeFromPoint(d.getBoundingClientRect().left + parseFloat(getComputedStyle(d).paddingLeft) + 6, bar + 10), all = document.createRange();
    all.selectNodeContents(d); all.setEnd(r.startContainer, r.startOffset); window.__topOff = all.toString().length;
    // A wrap space at the end of the line above, given for a line starting with an element, is not the line at the top.
    if (/\\s/.test(d.textContent[window.__topOff]) && top(window.__topOff + 1) > top(window.__topOff) + 1) window.__topOff++; }
  return [[...d.children].indexOf(b), Math.round(b.getBoundingClientRect().top), Math.round(top(window.__topOff))];"""


def large_note(page, check, out):
    d = os.path.join(out, 'big')
    os.makedirs(d)
    sec = '## Section\n\n' + ('Words with **bold** and `code` and a [link](x.md). ' * 12) + '\n\n'
    f = os.path.join(d, 'm500.md')
    open(f, 'w').write(sec * (500 * 1024 // len(sec)))
    page.cmd('@size:1100x760')
    page.cmd('@root:' + d)
    page.render(f)
    page.cmd('@wait:0.6')
    page.cmd('@eval:window.scrollTo(0, document.scrollingElement.scrollHeight / 2); 0')
    page.cmd('@wait:0.3')
    res = {}
    for label in ('sidebar hidden', 'sidebar shown'):
        # A scroll, so the page takes the line now at the top as the one being read.
        page.cmd('@eval:delete window.__topOff; window.scrollBy(0, 1); 0')
        page.cmd('@wait:0.3')
        before = page.js(TOPBLOCK)
        page.js("document.getElementById('side-toggle').click(); " + GAPS.replace('NFR', '24'))
        page.cmd('@wait:0.7')
        res[label] = {'frame gaps ms': page.js('return window.__gaps'), 'top block [index, top, top line]': [before, page.js(TOPBLOCK)]}
    still = lambda b, a: b[0] == a[0] and abs(b[2] - a[2]) <= 2
    ok = all(sum(g > 34 for g in v['frame gaps ms']) <= 1 and max(v['frame gaps ms']) < 80 and still(*v['top block [index, top, top line]'])
             for v in res.values())
    check(ok, 'N17: a 500 KB note follows the sidebar\'s animation with at most one frame over 34 ms (the one reflow, under 80) each way, and the line '
          'being read keeps its place', json.dumps(res))
    page.cmd('@root:')


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    try:
        for fn in (highlight_slices, large_note):
            fn(page, check, page.out)
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l or 'csp blocked' in l]
        check(not errs, 'no CSP violations or page errors logged', json.dumps(errs)[:300])
        page.close()
    finally:
        if page.proc.poll() is None:
            page.close()
        shutil.rmtree(page.out, ignore_errors=True)
    print(f'\n{sum(results)}/{len(results)} perf checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
