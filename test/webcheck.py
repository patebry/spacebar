#!/usr/bin/env python3
"""The page on its own, outside Quick Look: Preview/web in an offscreen WKWebView (test/web/main.swift) renders the hostile
corpus and the demo fixture. Hostile documents must post nothing but the page's own bookkeeping messages and leave no script,
frame, handler or script URL in the DOM; links a click reports are listed for the Swift-side policy (checked by hostile.py).
The demo must still render math, highlighting, mermaid, task boxes and its sibling image. A missing image gets its placeholder,
whose Reveal folder only a real click on the page's own button can press."""
import json, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hostile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE_TYPES = {'ready', 'painted', 'rendered', 'log', 'caretPainted', 'editBlock', 'editCancel', 'editStop', 'imageStatus'}

exe = os.path.join(hostile.OUT, 'webcheck')
# Compiled with the extension's own scheme handler and document-start settings script.
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos13.0',
                os.path.join(ROOT, 'test', 'web', 'main.swift'), os.path.join(ROOT, 'Shared', 'Settings.swift'),
                os.path.join(ROOT, 'Shared', 'WebShell.swift'),
                os.path.join(ROOT, 'Shared', 'FolderListing.swift'), os.path.join(ROOT, 'Shared', 'ArchiveListing.swift'), os.path.join(ROOT, 'Shared', 'FolderScan.swift'), os.path.join(ROOT, 'Shared', 'LinkPolicy.swift'), os.path.join(ROOT, 'Preview', 'PDFPane.swift'),
                        os.path.join(ROOT, 'Preview', 'Gestures.swift'), os.path.join(ROOT, 'Preview', 'Thumbnail.swift'), os.path.join(ROOT, 'Preview', 'ImagePane.swift'),
                        os.path.join(ROOT, 'test', 'nsevents.swift'), '-o', exe], check=True)
# A scratch settings folder: the harness must never read the real one.
env = dict(os.environ, SPACEBAR_SUPPORT_DIR=tempfile.mkdtemp(prefix='spacebar-support-'))
fixtures = [os.path.join(hostile.OUT, f) for f in hostile.materialize()]
for f in ('demo.md', 'img.png', 'other.md'):
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', f), hostile.OUT)
demo = os.path.join(hostile.OUT, 'demo.md')
out = subprocess.run([exe, os.path.join(ROOT, 'Preview', 'web')] + fixtures + [demo, '@csp'], capture_output=True, text=True, timeout=300, env=env)
results = []
for line in out.stdout.splitlines():
    r = json.loads(line)
    a, msgs = r['audit'], r['messages']
    logs = [m.get('msg', '') for m in msgs if m.get('type') == 'log']
    if r['file'] == '08-overlay.md' and not (a['katex'] >= 3 and a['mermaid'] >= 1 and a['aligned'] == 4):
        print(f"FAIL 08-overlay.md: math, mermaid or table alignment missing: {json.dumps(a)}"); results.append(False)
    if r['file'] == 'demo.md':
        ok = a['katex'] >= 2 and a['editHit'] and not a['hijacked'] and a['aligned'] == 0 and a['hljs'] > 0 and a['mermaid'] == 1 and a['tasks'] == 3 and a['imgs'] and a['imgs'][0] > 0 \
            and not [l for l in logs if 'csp blocked' in l or 'mermaid' in l]
        print(f"{'PASS' if ok else 'FAIL'} demo.md renders: {json.dumps(a)} logs={logs}")
    elif r['file'] == '@csp':
        blocked = [l for l in logs if 'csp blocked' in l]
        ok = a['pwned'] is None and not [m for m in msgs if m.get('type') == 'link'] and len(blocked) >= 3
        print(f"{'PASS' if ok else 'FAIL'} CSP alone blocks injected handlers and scripts: pwned={a['pwned']}, {len(blocked)} violations")
        for l in blocked: print('   ', l[:160])
    else:
        # _navigation and _refused are the harness's records of what the shell cancelled or the scheme handler refused.
        foreign = [m for m in msgs if m.get('type') not in PAGE_TYPES | {'link', '_navigation', '_refused'}]
        pwn_links = [m for m in msgs if m.get('type') == 'link' and 'pwned' in m.get('href', '')]
        off_main = [m for m in msgs if m.get('type') not in ('_navigation', '_refused') and (m.get('_mainFrame') not in ('1', 'true') or m.get('_origin') != 'spacebar://bundle')]
        links = sorted({m['href'] for m in msgs if m.get('type') == 'link'})
        ok = not foreign and not pwn_links and not off_main and a['pwned'] is None and not a['scripts'] and not a['frames'] \
            and not a['handlers'] and not a['scriptUrls'] and not a['forms'] and a['bases'] == 1 \
            and a['editHit'] and not a['overlays'] and not a['hijacked']
        print(f"{'PASS' if ok else 'FAIL'} {r['file']}: clicked {r['clicked']}, audit {json.dumps(a)}")
        for m in foreign + pwn_links + off_main: print('   BAD', json.dumps(m)[:240])
        for l in links: print('   link reported (Swift policy decides):', l[:160])
        for m in msgs:
            if m.get('type') == '_navigation': print('   navigation (cancelled, as the extension does):', m['url'][:160])
            if m.get('type') == '_refused': print('   scheme handler:', m['msg'][:160])
        for l in logs: print('   log:', l[:160])
    results.append(ok)
# A missing image: the placeholder, and a Reveal folder that the document's own buttons and script-made clicks cannot press.
imgdir = os.path.join(hostile.OUT, 'imgcheck')
os.makedirs(os.path.join(imgdir, 'media'), exist_ok=True)
shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), imgdir)
missing = os.path.join(imgdir, 'missing.md')
open(missing, 'w').write('# Missing\n\n![Shot](img.png)\n\n![Wispr Flow Insights](media/wispr-insights.png)\n\n'
                         '<div class="forged"><button class="img-reveal" type="button" data-action="reveal">Reveal folder</button></div>\n')
PLACEHOLDER = """JSON.stringify((() => { const b = document.querySelector('#doc p .img-missing');
  return { box: b && [b.querySelector('.img-missing-alt').textContent, b.querySelector('.img-missing-path').textContent,
    [...b.querySelectorAll('.img-missing-why > *')].map((n) => n.textContent)], img: document.querySelector('#doc img').naturalWidth }; })())"""
SYNTH = """(() => { const b = document.querySelector('#doc p .img-reveal'); for (const t of ['pointerdown', 'mousedown', 'mouseup', 'click'])
  b.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true })); b.click(); return 0; })()"""
out2 = subprocess.run([exe, os.path.join(ROOT, 'Preview', 'web'), '@render:' + missing, '@wait:1', '@eval:' + PLACEHOLDER, '@eval:' + SYNTH,
                       '@nativeclick:#doc .forged button', '@nativeclick:#doc p .img-reveal'], capture_output=True, text=True, timeout=120, env=env)
steps = [json.loads(l) for l in out2.stdout.splitlines()]
if len(steps) == 6:
    shown = json.loads(steps[2]['result'])
    reveals = [[m.get('type') for m in st['messages'] if 'eveal' in m.get('type', '')] for st in steps[3:]]
    ok = shown['box'] == ['Wispr Flow Insights', 'media/wispr-insights.png', ['Not found', 'Reveal folder']] and shown['img'] > 0
    print(f"{'PASS' if ok else 'FAIL'} missing image: placeholder with alt, path and reason; the image beside it renders: {json.dumps(shown)}")
    results.append(ok)
    ok = reveals == [[], [], ['revealImageFolder', '_revealFolder']] and all(st['result'] is True for st in steps[4:])
    print(f"{'PASS' if ok else 'FAIL'} missing image: Reveal folder only for a real click on the page's own button: {json.dumps(reveals)}")
    results.append(ok)
else:
    print('FAIL missing image: harness gave', len(steps), 'answers', out2.stderr[-500:])
    results += [False, False]
if out.returncode or len(results) != len(fixtures) + 4:
    print(out.stderr[-2000:])
    results.append(False)
print(f'\n{sum(results)}/{len(results)} page checks passed; files in {hostile.OUT}')
sys.exit(0 if all(results) else 1)
