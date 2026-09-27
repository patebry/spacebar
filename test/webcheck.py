#!/usr/bin/env python3
"""The page on its own, outside Quick Look: Preview/web in an offscreen WKWebView (test/web/main.swift) renders the hostile
corpus and the demo fixture. Hostile documents must post nothing but the page's own bookkeeping messages and leave no script,
frame, handler or script URL in the DOM; links a click reports are listed for the Swift-side policy (checked by hostile.py).
The demo must still render math, highlighting, mermaid, task boxes and its sibling image."""
import json, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hostile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE_TYPES = {'ready', 'painted', 'rendered', 'log', 'caretPainted', 'editBlock', 'editCancel', 'editStop'}

exe = os.path.join(hostile.OUT, 'webcheck')
# Compiled with the extension's own scheme handler and document-start settings script.
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos13.0',
                os.path.join(ROOT, 'test', 'web', 'main.swift'), os.path.join(ROOT, 'Shared', 'Settings.swift'),
                os.path.join(ROOT, 'Shared', 'WebShell.swift'),
                os.path.join(ROOT, 'Shared', 'FolderListing.swift'), os.path.join(ROOT, 'Shared', 'FolderScan.swift'), os.path.join(ROOT, 'Shared', 'LinkPolicy.swift'), os.path.join(ROOT, 'Preview', 'PDFPane.swift'), '-o', exe], check=True)
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
if out.returncode or len(results) != len(fixtures) + 2:
    print(out.stderr[-2000:])
    results.append(False)
print(f'\n{sum(results)}/{len(results)} page checks passed; files in {hostile.OUT}')
sys.exit(0 if all(results) else 1)
