#!/usr/bin/env python3
"""Remote images, off by default, in the offscreen harness (test/web/main.swift) with the extension's RemoteImageGate: the
content rule list blocks them, a blocked image's placeholder offers "Load images from the web", and only a real click on
that button loads the document's remote images, once, without touching settings.json or the CSP. The load itself needs the
network (an https image from apple.com); without it those two checks are reported as skipped."""
import json, os, shutil, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, ROOT

REMOTE = 'https://www.apple.com/favicon.ico'
DOC = f"""# Remote

![a remote picture]({REMOTE})

[![linked picture]({REMOTE}?linked)](https://example.com/)

<img srcset="{REMOTE}?srcset 2x" alt="srcset only">

<picture><source srcset="{REMOTE}?source"><img src="img.png" alt="picture"></picture>

A local one: ![local](img.png)

<button class="img-load" type="button">Load images from the web</button>

<table background="{REMOTE}?table"><tr><td>cell</td></tr></table>

<svg><filter id="f"><feImage href="{REMOTE}?fe"/></filter></svg>
"""

# A label forwards a click on any of its text to the first button inside it, as a trusted click (review of da63068).
LABEL = f"""<label>

## Click anywhere here

<span id="bait">Next page</span> text ![x]({REMOTE}?label)

</label>
"""

STATE = """
  const doc = document.getElementById('doc');
  return { buttons: doc.querySelectorAll('.img-blocked > button.img-load').length,
    remote: [...doc.querySelectorAll('img, source')].filter((n) => /https:/.test((n.getAttribute('src') || '') + (n.getAttribute('srcset') || ''))).length,
    local: [...doc.querySelectorAll('img')].filter((n) => /img\\.png/.test(n.getAttribute('src') || '')).map((n) => n.naturalWidth),
    remoteLoaded: [...doc.querySelectorAll('img')].filter((n) => /^https:/.test(n.currentSrc || n.src || '')).map((n) => n.naturalWidth),
    other: doc.querySelectorAll('[background], [poster], feImage, label').length,
    root: document.documentElement.dataset.remoteImages,
    csp: document.querySelector('meta[http-equiv=Content-Security-Policy]').content };
"""

# An <img> put straight into the DOM, past the page's own placeholders: only the content rule list can stop it.
PROBE = """
  window.__img = 'pending'; const i = new Image();
  i.onload = () => { window.__img = 'loaded ' + i.naturalWidth; }; i.onerror = () => { window.__img = 'blocked'; };
  i.src = SRC + '&n=' + Math.random(); return 0;
"""


def online():
    try:
        return urllib.request.urlopen(REMOTE, timeout=5).status == 200
    except Exception:
        return False


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    net = online()
    page = Page()
    doc = os.path.join(page.out, 'remote.md')
    other = os.path.join(page.out, 'other.md')
    open(doc, 'w').write(DOC)
    open(other, 'w').write(f'![another]({REMOTE}?other)\n')
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), page.out)
    settings_file = os.path.join(page.support, 'settings.json')

    def probe():
        page.cmd('@eval:(() => { ' + PROBE.replace('SRC', json.dumps(REMOTE + '?probe')) + ' })()')
        page.cmd('@wait:3')
        return page.js('return window.__img')

    def messages(r, t):
        return [m for m in r['messages'] if m.get('type') == t]

    try:
        page.cmd('@load:{}')
        page.render(doc)
        page.cmd('@wait:1')
        s = page.js(STATE)
        check(s['root'] == 'off' and s['buttons'] == 3 and s['remote'] == 0 and s['other'] == 0 and s['local'] and all(w > 0 for w in s['local']),
              'off by default: every remote <img> (src or srcset) is a placeholder with a load button, a remote <source> is dropped; local images load', json.dumps(s))
        blocked = probe()
        check(blocked == 'blocked', 'the content rule list blocks a remote image the page did not replace', blocked)

        # Script-made clicks, on the real button and on the document's look-alike, ask for nothing.
        r = page.cmd("@eval:(() => { document.querySelector('.img-blocked > button.img-load').click();"
                     " document.querySelector('.img-blocked > button.img-load').dispatchEvent(new MouseEvent('click', { bubbles: true })); return 0; })()")
        check(not messages(r, 'loadRemoteImages'), 'a script-made click on the load button posts nothing', json.dumps(r['messages'])[:200])
        page.cmd("@eval:document.addEventListener('click', (e) => { window.__click = [e.isTrusted, e.target.tagName, !!e.target.closest('.img-blocked')]; }, true); 0")
        r = page.cmd('@nativeclick:#doc p > button.img-load')
        hit = page.js('return window.__click')
        check(r['result'] and hit == [True, 'BUTTON', False] and not messages(r, 'loadRemoteImages') and page.js(STATE)['buttons'] == 3,
              "a real click on the document's own look-alike button posts nothing", f"click {hit} {json.dumps(r['messages'])[:200]}")

        # A document <label> around the placeholder: a real click on its text must not reach the load button.
        label = os.path.join(page.out, 'label.md')
        open(label, 'w').write(LABEL)
        page.render(label)
        page.cmd('@wait:0.5')
        s = page.js(STATE)
        r = page.cmd('@nativeclick:#doc [id$=bait]')
        hit = page.js('return window.__click')
        check(r['result'] and hit and hit[0] and not messages(r, 'loadRemoteImages') and s['buttons'] == 1 and s['other'] == 0,
              'a real click on the text of a document <label> does not load (labels are dropped; the button needs its own press)',
              f"click {hit} state {json.dumps(s)[:120]} {json.dumps(r['messages'])[:200]}")
        page.cmd('@eval:sb.editEnd({}); 0')
        page.render(doc)
        page.cmd('@wait:0.5')

        # A forged request for another file is refused by the gate.
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'loadRemoteImages', path: '/etc/other.md' }); 0")
        page.cmd('@wait:0.3')
        r2 = page.cmd('@eval:0')
        refused = messages(r, '_remoteRefused') + messages(r2, '_remoteRefused')
        check(refused and page.js(STATE)['buttons'] == 3, 'a request naming a file other than the one on screen is refused', json.dumps(refused))

        # The real button, really clicked: a message, a re-render with the images, the setting untouched.
        before = open(settings_file).read() if os.path.exists(settings_file) else None
        r = page.cmd('@nativeclick:.img-blocked > button.img-load')
        page.cmd('@wait:3')
        s = page.js(STATE)
        posted = messages(r, 'loadRemoteImages')
        check(len(posted) == 1 and posted[0].get('path') == doc and not messages(r, 'editBlock') and not messages(r, 'link'),
              'a real click on the load button posts loadRemoteImages for this file, and no edit or link', json.dumps(r['messages'])[:300])
        check(s['buttons'] == 0 and s['remote'] >= 3, "after it, the document's remote images are in the page", json.dumps(s))
        after = open(settings_file).read() if os.path.exists(settings_file) else None
        check(after == before and s['root'] == 'off', 'the setting is not saved or changed', f'settings.json {before!r} -> {after!r}')
        check("img-src spacebar://bundle spacebar://file spacebar://user https: data:" in s['csp'] and "default-src 'none'" in s['csp'], 'the CSP is unchanged', s['csp'])
        if net:
            check(s['remoteLoaded'] and all(w > 0 for w in s['remoteLoaded']), 'the remote images load', json.dumps(s['remoteLoaded']))
            loaded = probe()
            check(loaded.startswith('loaded'), 'the rule list is lifted for this document', loaded)
        else:
            print('SKIP remote images load (offline)')

        # Live reload keeps them for this document; another document, or a new preview, is blocked again.
        page.render(doc)
        page.cmd('@wait:0.5')
        check(page.js(STATE)['buttons'] == 0, 'a re-render of the same document keeps them loaded (live reload)')
        page.cmd('@remotereset')
        page.render(other)
        page.cmd('@wait:0.5')
        s = page.js(STATE)
        again = probe()
        check(s['buttons'] == 1 and s['remote'] == 0 and again == 'blocked', 'the next document is blocked again', f'{json.dumps(s)} probe {again}')
        page.cmd('@remotereset')
        page.render(doc)
        page.cmd('@wait:0.5')
        check(page.js(STATE)['buttons'] == 3, 'the same document in a new preview is blocked again')

        # remoteImages on: no placeholders, no block.
        page.apply(remoteImages=True)
        page.render(doc)
        page.cmd('@wait:0.5')
        s = page.js(STATE)
        check(s['root'] == 'on' and s['buttons'] == 0 and s['remote'] >= 3, 'remoteImages on shows them without a placeholder', json.dumps(s))
        if net:
            on = probe()
            check(on.startswith('loaded'), 'remoteImages on lifts the rule list', on)
        page.apply(remoteImages=False)
        check(probe() == 'blocked', 'turning it off again blocks them')

        csp = [l for l in page.logs if 'csp blocked' in l]
        check(not csp, 'no CSP violations', json.dumps(csp)[:300])
    finally:
        page.close()
    print(f'\n{sum(results)}/{len(results)} remote image checks passed' + ('' if net else ' (offline: load checks skipped)'))
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
