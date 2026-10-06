#!/usr/bin/env python3
"""An HTML file made on this Mac while "Scripts in HTML files" is Ask, in the offscreen harness (test/web/main.swift): the
page's own bar above the area the file's view is laid over, with Run for files made on this Mac and Never. Only a real click
that went down on one of its buttons posts the answer; a script-made click posts nothing. No bar without scriptsAsk."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page

BAR = """
  const bar = document.querySelector('#doc .scripts-ask'), area = document.querySelector('#doc .pdf-area');
  if (!bar) return { bar: false, area: !!area };
  const b = bar.getBoundingClientRect(), a = area.getBoundingClientRect();
  return { bar: true, hidden: bar.hidden, text: bar.querySelector('.scripts-ask-text').textContent,
    buttons: [...bar.querySelectorAll('button')].map((n) => n.textContent), above: b.bottom <= a.top + 0.5, area: true };
"""


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    f = os.path.join(page.out, 'page.html')
    open(f, 'w').write('<p>x</p><script>1</script>')
    payload = {'path': f, 'name': 'page.html', 'view': 'html', 'kindName': 'HTML document', 'size': 27, 'canOpen': True, 'reason': 'open'}

    def show(**extra):
        page.cmd('@eval:sb.render(' + json.dumps({**payload, **extra}) + '); 0')
        page.cmd('@wait:0.3')
        return page.js(BAR)

    def answers(r):
        return [m for m in r['messages'] if m.get('type') == 'answerScripts']

    try:
        # The sidebar collapsed: with none listed, its empty column would take the clicks at the bar's left end.
        page.cmd('@load:{"sidebarCollapsed": true}')
        page.render(f)
        s = show()
        check(s == {'bar': False, 'area': True}, 'no scriptsAsk: no bar', json.dumps(s))
        s = show(scriptsAsk=True)
        check(s.get('bar') and not s['hidden'] and s['text'] == 'This page has scripts. Run them?'
              and s['buttons'] == ['Run for files made on this Mac', 'Never'] and s['above'],
              "scriptsAsk: the page's own bar, above the area the file's view covers", json.dumps(s))
        r = page.cmd("@eval:(() => { for (const b of document.querySelectorAll('#doc .scripts-ask button')) { b.click();"
                     " b.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); b.dispatchEvent(new MouseEvent('click', { bubbles: true })); } return 0; })()")
        check(not answers(r) and not page.js(BAR)['hidden'], 'a script-made press or click on its buttons posts nothing', json.dumps(r['messages'])[:200])
        r = page.cmd('@nativeclick:#doc .scripts-ask button:last-of-type')
        posted = answers(r)
        check(len(posted) == 1 and posted[0].get('path') == f and posted[0].get('run') in (False, 'false', '0') and page.js(BAR)['hidden'],
              'a real click on Never posts run false for this file, and hides the bar', json.dumps(r['messages'])[:300])
        again = show(scriptsAsk=True)
        # Past the double-click interval, so the press is a click of its own.
        page.cmd('@wait:0.8')
        r = page.cmd('@nativeclick:#doc .scripts-ask button:first-of-type')
        posted = answers(r)
        check(len(posted) == 1 and posted[0].get('path') == f and posted[0].get('run') in (True, 'true', '1'),
              'a real click on Run for files made on this Mac posts run true for this file', json.dumps([again, r['messages']])[:600])
        md = os.path.join(page.out, 'doc.md')
        open(md, 'w').write('# Doc\n\n<button class="scripts-ask-btn" type="button">Never</button>\n')
        page.render(md)
        page.cmd('@wait:0.3')
        r = page.cmd('@nativeclick:#doc button.scripts-ask-btn')
        check(not answers(r) and not page.js(BAR)['bar'], "a document's look-alike button posts nothing", json.dumps(r['messages'])[:200])
    finally:
        page.close()
    print(f'\n{sum(results)}/{len(results)} HTML scripts bar checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
