#!/usr/bin/env python3
"""Long lines, logs, data views and Markdown's reading aids in the page on its own (the offscreen harness of webthemes.py):
wrapping per kind and its Aa toggle, a log's tail and tint, JSON strings and empty branches, the CSV view's frame, heading
anchors, footnotes, ==marks==, folded callouts, a code fence's language and Copy, and the editor's code font."""
import json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, click

results = []


def check(ok, name, detail=''):
    results.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))


d = tempfile.mkdtemp(prefix='spacebar-views-')
P = lambda n: os.path.join(d, n)
open(P('notes.txt'), 'w').write('A line of prose ' * 40 + '\n\nDone.\n')
open(P('code.py'), 'w').write('x = 1  # ' + 'long comment ' * 40 + '\n')
open(P('app.log'), 'w').write('2026-09-30 10:00:00 INFO start\n2026-09-30 10:00:01 WARN slow\n2026-09-30 10:00:02 ERROR failed\n')
with open(P('huge.log'), 'w') as f:
    for i in range(32000):
        f.write(f'{i:08d} ' + 'y' * 90 + '\n')
    f.write('ERROR the last line\n')
open(P('data.json'), 'w').write(json.dumps({'desc': 'word ' * 80, 'empty': {}, 'none': [], 'items': list(range(1200))}))
open(P('rows.csv'), 'w').write('a,b\n1,2\n3,4\n')
open(P('doc.md'), 'w').write("""# Guide

Read [Setup](#setup) and the note[^n]. ==Marked== text.

```bash
echo hi
```

| a | b |
|---|---|
| 1 | 2 |

> [!tip]- Folded
> Hidden.

## Setup

Text.

[^n]: The note.
""")

page = Page()
page.cmd('@size:1000x700')
view = lambda n: page.render(P(n))

view('notes.txt')
w = page.js("const v = document.querySelector('#doc .code-view'); return [v.classList.contains('wrap'), v.scrollWidth <= v.clientWidth, getComputedStyle(v.querySelector('.gutter')).display]")
check(w == [True, True, 'none'], 'text wraps by default, without line numbers', json.dumps(w))
view('code.py')
w = page.js("const v = document.querySelector('#doc .code-view'); return [v.classList.contains('wrap'), v.scrollWidth > v.clientWidth]")
check(w == [False, True], 'code does not wrap by default', json.dumps(w))
page.cmd('@nativeclick:#aa')
shown = page.js("return [!document.getElementById('aa-wrap').hidden, document.querySelector('#aa-wrap [data-wrap=\"0\"]').getAttribute('aria-checked')]")
r = page.cmd('@nativeclick:#aa-wrap [data-wrap="1"]')
posted = [m for m in r['messages'] if m.get('type') == 'setting']
w = page.js("return document.querySelector('#doc .code-view').classList.contains('wrap')")
check(shown == [True, 'true'] and posted and posted[0]['key'] == 'wrapCode' and str(posted[0]['value']).lower() in ('true', '1') and w,
      'Aa: Wrap Lines turns wrapping on for code, as a panel setting', json.dumps([shown, posted, w]))
page.cmd('@nativeclick:#aa')
view('notes.txt')
check(page.js("return document.querySelector('#doc .code-view').classList.contains('wrap')"), 'the setting is per kind: text still wraps')
page.apply(wrapCode=False)

view('app.log')
t = page.js("return [...document.querySelectorAll('#doc pre.code span')].map((s) => s.className + ':' + s.textContent.trim())")
check('log-warn:WARN slow' in t and 'log-err:ERROR failed' in t and 'log-time:2026-09-30 10:00:00' in t, 'a log: errors and warnings tinted, timestamps dimmed', json.dumps(t))
view('huge.log')
h = page.js("const c = document.querySelector('#doc pre.code').textContent; return [c.startsWith('000') && c.split('\\n')[0].length === 99, c.endsWith('ERROR the last line\\n'), [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
check(h[0] and h[1] and len(h[2]) == 1 and h[2][0].startswith('Showing the last 2 MB of '), 'a log over 2 MB: its newest 2 MB from a whole line, with a note', json.dumps(h))

view('data.json')
j = page.js("""const row = (k) => [...document.querySelectorAll('#doc .jt-row')].find((r) => r.textContent.startsWith(k));
  const t = document.querySelector('#doc .json-tree'); return [t.scrollWidth <= t.clientWidth, row('"desc"').getBoundingClientRect().height > 40,
  row('"empty"').textContent, !!row('"empty"').querySelector('button'), row('"none"').textContent]""")
check(j == [True, True, '"empty": {}', False, '"none": []'], 'JSON: a long string wraps; an empty object or array is a leaf', json.dumps(j))
page.cmd('@nativeclick:#doc .json-all[data-open="1"]')
n = page.js("return [document.querySelectorAll('#doc .jt-row[data-ptr^=\"/items/\"]').length, [...document.querySelectorAll('#doc .jt-more-b')].length]")
check(n == [1200, 0], 'JSON: Expand All opens past 500 items, within its cap', json.dumps(n))

view('rows.csv')
c = page.js("""const s = document.querySelector('#doc .csv-scroll').getBoundingClientRect(), doc = document.getElementById('doc').getBoundingClientRect();
  return [document.scrollingElement.scrollHeight <= innerHeight, s.width < doc.width / 2, document.getElementById('kind').textContent]""")
check(c[0] and c[1] and c[2].startswith('CSV · 2 rows × 2 columns'), 'CSV: the page does not scroll, a small table stays small, rows × columns before the size', json.dumps(c))

view('doc.md')
m = page.js("""return [[...document.querySelectorAll('#doc h1, #doc h2')].map((h) => h.id), document.querySelectorAll('#doc section.footnotes li').length,
  (document.querySelector('#doc mark') || {}).textContent, (document.querySelector('#doc .fence-lang') || {}).textContent,
  (document.querySelector('#doc details.callout-fold') || {}).open, document.getElementById('kind').textContent]""")
check(m[:5] == [['user-content-guide', 'user-content-setup'], 1, 'Marked', 'bash', False] and m[5].startswith('Markdown · '),
      'Markdown: heading ids, footnotes, marks, the fence language, a folded callout, its kind and size', json.dumps(m))
page.cmd('@size:1000x300')
r = page.cmd('@nativeclick:#doc a[href="#setup"]')
page.cmd('@wait:0.8')
y = page.js("return [window.scrollY > 0, Math.round(document.getElementById('user-content-setup').getBoundingClientRect().top)]")
check(y[0] and 0 <= y[1] < 120 and not [x for x in r['messages'] if x.get('type') == 'link'], 'Markdown: an #anchor link scrolls to its heading in the page', json.dumps(y))
page.cmd('@size:1000x700')
page.cmd('@eval:window.scrollTo(0, 0); 0')
r = click(page, '#doc .fence-copy')
check(not [x for x in r['messages'] if x.get('type') == 'copy'], 'fence Copy: a script-made click copies nothing')
r = page.cmd('@nativeclick:#doc .fence-copy')
got = [x for x in r['messages'] if x.get('type') == '_copied']
check(got and got[0].get('text') == 'echo hi' and not [x for x in r['messages'] if x.get('type') == 'editBlock'],
      'fence Copy: a real click copies the fence\'s code, read from the document, and starts no edit', json.dumps(got))
r = page.cmd('@nativedblclick:#doc .blk pre code')
dbl = [page.js("return getSelection().toString().trim()"), [x for x in r['messages'] if x.get('type') == 'editBlock'], page.js("return !!document.querySelector('#doc .md-editing')")]
check(dbl[0] and not dbl[1] and not dbl[2], 'a double-click on a fence selects a word and starts no edit', json.dumps(dbl))
page.cmd('@eval:getSelection().removeAllRanges(); 0')
page.cmd('@nativeclick:#doc .blk pre')
page.cmd('@wait:0.5')
e = page.js("const e = document.querySelector('#doc .md-editing'); return e && [e.classList.contains('mono'), getComputedStyle(e).fontFamily.includes('mono') || getComputedStyle(e).fontFamily.includes('Menlo') || getComputedStyle(e).fontFamily.includes('SF Mono')]")
check(e == [True, True], 'a single click on a fence edits it, in the code font', json.dumps(e))
page.cmd('@eval:sb.editEnd({}); 0')
page.close()
print(f'\n{sum(results)}/{len(results)} view checks passed')
sys.exit(0 if all(results) else 1)
