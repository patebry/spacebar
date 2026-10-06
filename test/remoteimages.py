#!/usr/bin/env python3
"""Remote images, off by default, in the offscreen harness (test/web/main.swift) with the extension's RemoteImageGate: the
content rule list blocks them, a blocked image's placeholder offers "Load images from the web", and only a real click on
that button loads the document's remote images, once, without touching settings.json. The page's CSP allows no remote image
at all: an allowed one comes through spacebar://remote, which the scheme handler serves only while the gate allows the file
on screen. remote.test is answered by the harness with a fixture picture; one real fetch (an https image from GitHub)
needs the network, and is reported as skipped without it."""
import json, os, shutil, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, ROOT

REMOTE = 'https://remote.test/pic.png'
NET_IMAGE = 'https://github.githubassets.com/favicons/favicon.png'
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
  const remote = (v) => /https:|spacebar:\\/\\/remote\\//.test(v || '');
  return { buttons: doc.querySelectorAll('.img-blocked > button.img-load').length,
    remote: [...doc.querySelectorAll('img, source')].filter((n) => remote(n.getAttribute('src')) || remote(n.getAttribute('srcset'))).length,
    direct: [...doc.querySelectorAll('img, source, image, feImage, [background], [poster]')].filter((n) =>
      ['src', 'srcset', 'href', 'xlink:href', 'background', 'poster'].some((a) => /^\\s*(https?:)?\\/\\//.test(n.getAttribute(a) || ''))).length,
    local: [...doc.querySelectorAll('img')].filter((n) => /img\\.png/.test(n.getAttribute('src') || '')).map((n) => n.naturalWidth),
    remoteLoaded: [...doc.querySelectorAll('img')].filter((n) => /^spacebar:\\/\\/remote\\//.test(n.currentSrc || n.src || '')).map((n) => n.naturalWidth),
    other: doc.querySelectorAll('[background], [poster], feImage, label').length,
    root: document.documentElement.dataset.remoteImages,
    csp: document.querySelector('meta[http-equiv=Content-Security-Policy]').content };
"""

# An <img> put straight into the DOM, past the page's own placeholders and its rewriting: the CSP stops a remote one whatever
# the setting (a securitypolicyviolation for img-src), and the scheme handler serves a spacebar://remote one only while the gate
# allows the file on screen.
PROBE = """
  window.__img = 'pending'; window.__csp = null; const i = new Image();
  if (!window.__cspSeen) { window.__cspSeen = true;
    document.addEventListener('securitypolicyviolation', (e) => { if (e.blockedURI.includes('probe')) window.__csp = e.violatedDirective; }); }
  i.onload = () => { window.__img = 'loaded ' + i.naturalWidth; }; i.onerror = () => { window.__img = 'blocked'; };
  i.src = SRC; return 0;
"""


def online():
    try:
        return urllib.request.urlopen(NET_IMAGE, timeout=5).status == 200
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
    probes = [0]

    def probe(proxied=False):
        """[what the image did, the CSP directive it violated, the remote images the scheme handler fetched]"""
        probes[0] += 1
        url = f'{REMOTE}?probe{probes[0]}'
        src = 'spacebar://remote/?u=' + urllib.request.quote(url, safe='') if proxied else url
        r = page.cmd('@eval:(() => { ' + PROBE.replace('SRC', json.dumps(src)) + ' })()')
        r2 = page.cmd('@wait:1.5')
        fetched = [m['url'] for m in r['messages'] + r2['messages'] if m.get('type') == '_remoteFetch']
        return [page.js('return window.__img'), page.js('return window.__csp'), fetched]

    def messages(r, t):
        return [m for m in r['messages'] if m.get('type') == t]

    try:
        page.cmd('@load:{}')
        page.render(doc)
        page.cmd('@wait:1')
        s = page.js(STATE)
        check(s['root'] == 'off' and s['buttons'] == 3 and s['remote'] == 0 and s['other'] == 0 and s['local'] and all(w > 0 for w in s['local']),
              'off by default: every remote <img> (src or srcset) is a placeholder with a load button, a remote <source> is dropped; local images load', json.dumps(s))
        check("https:" not in s['csp'] and "spacebar://remote" in s['csp'] and "default-src 'none'" in s['csp'],
              "the page's CSP allows no remote image itself, only the remote host", s['csp'])
        direct = probe()
        check(direct[0] == 'blocked' and direct[1] == 'img-src' and not direct[2],
              'off: a remote image put in the page past its own code is blocked by the CSP (securitypolicyviolation img-src)', json.dumps(direct))
        proxied = probe(proxied=True)
        check(proxied[0] == 'blocked' and not proxied[2], 'off: the remote host fetches nothing and serves nothing', json.dumps(proxied))

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

        # The real button, really clicked: a message, a re-render with the images through the remote host, the setting untouched.
        before = open(settings_file).read() if os.path.exists(settings_file) else None
        r = page.cmd('@nativeclick:.img-blocked > button.img-load')
        page.cmd('@wait:2')
        s = page.js(STATE)
        posted = messages(r, 'loadRemoteImages')
        check(len(posted) == 1 and posted[0].get('path') == doc and not messages(r, 'editBlock') and not messages(r, 'link'),
              'a real click on the load button posts loadRemoteImages for this file, and no edit or link', json.dumps(r['messages'])[:300])
        check(s['buttons'] == 0 and s['remote'] >= 3 and s['direct'] == 0, "after it, the document's remote images are in the page, each through the remote host",
              json.dumps(s))
        check(s['remoteLoaded'] and all(w > 0 for w in s['remoteLoaded']), 'and they load', json.dumps(s['remoteLoaded']))
        after = open(settings_file).read() if os.path.exists(settings_file) else None
        check(after == before and s['root'] == 'off', 'the setting is not saved or changed', f'settings.json {before!r} -> {after!r}')
        direct = probe()
        check(direct[0] == 'blocked' and direct[1] == 'img-src', 'allowed once: a remote image past the page\'s code is still blocked by the CSP', json.dumps(direct))
        proxied = probe(proxied=True)
        check(proxied[0].startswith('loaded') and len(proxied[2]) == 1, 'allowed once: the remote host serves this document', json.dumps(proxied))

        # Live reload keeps them for this document; another document, or a new preview, is blocked again.
        page.render(doc)
        page.cmd('@wait:0.5')
        check(page.js(STATE)['buttons'] == 0, 'a re-render of the same document keeps them loaded (live reload)')
        page.cmd('@remotereset')
        page.render(other)
        page.cmd('@wait:0.5')
        s = page.js(STATE)
        again = probe(proxied=True)
        check(s['buttons'] == 1 and s['remote'] == 0 and again[0] == 'blocked' and not again[2], 'the next document is blocked again, by the remote host too',
              f'{json.dumps(s)} probe {again}')
        page.cmd('@remotereset')
        page.render(doc)
        page.cmd('@wait:0.5')
        check(page.js(STATE)['buttons'] == 3, 'the same document in a new preview is blocked again')

        # remoteImages on: no placeholders; the images come through the remote host, and the CSP still allows nothing else.
        page.apply(remoteImages=True)
        page.render(doc)
        page.cmd('@wait:1')
        s = page.js(STATE)
        check(s['root'] == 'on' and s['buttons'] == 0 and s['remote'] >= 3 and s['direct'] == 0 and s['remoteLoaded'] and all(w > 0 for w in s['remoteLoaded']),
              'remoteImages on shows them without a placeholder, through the remote host', json.dumps(s))
        on = probe(proxied=True)
        check(on[0].startswith('loaded'), 'remoteImages on: the remote host serves', json.dumps(on))
        direct = probe()
        check(direct[0] == 'blocked' and direct[1] == 'img-src', 'remoteImages on: a remote image past the page\'s code is still blocked by the CSP',
              json.dumps(direct))
        if net:
            real = os.path.join(page.out, 'real.md')
            open(real, 'w').write(f'![apple]({NET_IMAGE})\n')
            page.render(real)
            page.cmd('@wait:4')
            s = page.js(STATE)
            check(s['remoteLoaded'] and all(w > 0 for w in s['remoteLoaded']), 'a real remote image loads through the remote host', json.dumps(s))
        else:
            print('SKIP a real remote image loads (offline)')
        page.apply(remoteImages=False)
        page.render(doc)
        page.cmd('@wait:0.5')
        off = probe(proxied=True)
        check(off[0] == 'blocked' and not off[2], 'turning it off again: the remote host serves nothing', json.dumps(off))

        csp = [l for l in page.logs if 'csp blocked' in l and 'probe' not in l]
        check(not csp, "no CSP violations but the probes'", json.dumps(csp)[:300])
    finally:
        page.close()
    print(f'\n{sum(results)}/{len(results)} remote image checks passed' + ('' if net else ' (offline: the real fetch skipped)'))
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
