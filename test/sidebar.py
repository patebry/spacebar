#!/usr/bin/env python3
"""The sidebar and the file browser in the page on its own, outside Quick Look: Preview/web in the offscreen harness
(test/web/main.swift), which lists the tree with the extension's FolderListing, renders each file with its FileView, routes
"list", "open", "openFile" and "reveal" through the same checks as the extension, and sends "setting" through the extension's
gate (Settings.panelPatch) and the writer's update (SettingsFile.updateFromPanel) into a scratch SPACEBAR_SUPPORT_DIR.

Checks the tree (folders first, icons, lazy expand and collapse, remembered expansion, the current file's folders opened, hidden
files, the cap, links out of the root), every file view (Markdown, image, SVG, PDF, code, JSON, CSV, text, the info card), the
hostile fixtures in test/hostile/browser beside a link to /etc and names made of dots, the resize handle, the no-flash
document-start state, the toggle and its persistence, the message gate, and that inline editing, task toggles, the TOC, the Aa
popover, themes and narrow panels still work with the sidebar open or collapsed. A sandboxed copy of the harness, signed with
the extension's entitlements, shows that a PDF and an image render under the extension's sandbox."""
import json, os, random, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, ROOT, THEMES, HELPERS, click
import hostile

HOSTILE = 'z<img src=x onerror="window.__pwned=1">.md'
STATE = """const s = document.getElementById('sidebar'), t = document.getElementById('side-toggle'), d = document.getElementById('doc');
  const cs = getComputedStyle(s);
  return { attr: document.documentElement.dataset.sidebar, hidden: s.hidden, width: cs.width, visibility: cs.visibility,
    position: cs.position, expanded: t.getAttribute('aria-expanded'), title: t.title, toggleHidden: t.hidden,
    docLeft: Math.round(d.getBoundingClientRect().left), docWidth: Math.round(d.getBoundingClientRect().width),
    head: document.getElementById('side-head').textContent, names: [...s.querySelectorAll('#side-list a.row')].map((a) => a.textContent),
    active: [...s.querySelectorAll('#side-list a.active')].map((a) => [a.textContent, a.getAttribute('aria-current')]),
    more: document.getElementById('side-more').hidden ? '' : document.getElementById('side-more').textContent,
    toc: getComputedStyle(document.getElementById('toc')).display, peek: document.documentElement.classList.contains('sb-peek'),
    view: document.documentElement.dataset.view, crumbs: document.getElementById('crumbs').hidden ? null : document.getElementById('crumbs').textContent,
    rows: [...s.querySelectorAll('#side-list a.row')].map((a) => [a.textContent, +a.getAttribute('aria-level'), a.dataset.dir ? 'd' : 'f',
      (a.querySelector('svg.ic') || { classList: [] }).classList[1] || '', a.getAttribute('aria-expanded')]),
    notes: [...s.querySelectorAll('#side-list .row-note')].map((n) => n.textContent),
    editing: (document.querySelector('#doc > .md-editing') || {}).textContent || null, title1: (d.querySelector('h1') || {}).textContent || null };"""


def make_pdf(text, catalog=''):
    """A one-page PDF: a blue page with white text, so a render shows as blue pixels. `catalog` adds entries (an OpenAction)."""
    objs = [f"<< /Type /Catalog /Pages 2 0 R {catalog}>>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    stream = f"0 0 1 rg 0 0 300 200 re f BT /F1 24 Tf 1 1 1 rg 40 90 Td ({text}) Tj ET"
    objs[3] = f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream"
    out, offs = "%PDF-1.4\n", []
    for i, o in enumerate(objs):
        offs.append(len(out))
        out += f"{i + 1} 0 obj\n{o}\nendobj\n"
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offs)
    return (out + f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n").encode('latin-1')


def make_tree(out):
    """The file browser's fixture: one of every kind, a subfolder two deep, a folder past the cap, hidden files, the hostile
    files of test/hostile/browser, a link to /etc, to /etc/hosts and to the parent, a dangling link, and names made of dots."""
    tree = os.path.join(out, 'tree')
    for d in ('sub/deep', 'many', 'hostile'):
        os.makedirs(os.path.join(tree, d))
    rnd = random.Random(7)
    files = {
        'README.md': '# Tree\n\nA paragraph to edit.\n', 'notes.txt': 'line one\nline two\n', '.secret.md': '# hidden\n',
        'code.ts': 'export interface Job { id: string; tries: number }\nconst queue: Job[] = [];\nexport function push(job: Job): number {\n'
                   '  queue.push(job);\n  return queue.length;\n}\n',
        'data.json': '{"name": "spacebar", "list": [1, 2], "nested": {"ok": true, "none": null}}',
        'table.csv': 'name,qty,note\napple,3,"red, crisp"\npear,5,"says ""hi"""\nfig,,"line one\nline two"\n',
        'big.csv': 'n,square\n' + ''.join(f'{i},{i * i}\n' for i in range(1500)),
        'run.sh': '#!/bin/sh\necho hi\n', 'wide.csv': ','.join(f'c{i}' for i in range(300)) + '\n' + ','.join('x' * 300) + '\n',
        'forged.md': '# Forged\n\n<div class="viewer"><button data-action="reveal">Continue</button><button data-action="openFile">Open</button></div>\n', '...': 'dots\n', '..txt': 'dots\n', '..%2F..%2Fetc%2Fpasswd.md': '# not a path\n',
        'notes..v2.txt': 'dots inside\n', 'sub/inner.md': '# Inner\n', 'sub/deep/deepest.txt': 'deep\n',
    }
    for name, text in files.items():
        open(os.path.join(tree, name), 'w').write(text)
    open(os.path.join(tree, 'huge.log'), 'w').write(('x' * 99 + '\n') * 31000)
    for name, n in (('archive.zip', 4096), ('movie.mp4', 2048), ('tool', 3000)):
        open(os.path.join(tree, name), 'wb').write(b'\0' + bytes(rnd.randrange(256) for _ in range(n - 1)))
    for name in ('tool', 'run.sh'):
        os.chmod(os.path.join(tree, name), 0o755)
    for i in range(520):
        open(os.path.join(tree, 'many', f'm-{i:03d}.txt'), 'w').write(f'{i}\n')
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(tree, 'photo.png'))
    open(os.path.join(tree, 'doc.pdf'), 'wb').write(make_pdf('Hello PDF'))
    hdir = os.path.join(tree, 'hostile')
    src = os.path.join(hostile.HERE, 'browser')
    for f in os.listdir(src):
        path = os.path.join(hdir, f)
        text = open(os.path.join(src, f)).read()
        open(path, 'w').write(text.replace('@@PAYLOAD@@', hostile.payload(f, path)).replace('@@DIRREL@@', hdir.lstrip('/')))
    open(os.path.join(hdir, 'evil.pdf'), 'wb').write(make_pdf('Evil', '/OpenAction << /S /JavaScript /JS (window.__pwned = 1; app.alert(1);) >> '))
    open(os.path.join(out, 'outside.md'), 'w').write('# outside the root\n')
    os.symlink('/etc', os.path.join(tree, 'etc'))
    os.symlink('/etc/hosts', os.path.join(tree, 'hosts.txt'))
    os.symlink('..', os.path.join(tree, 'up'))
    os.symlink('nowhere.md', os.path.join(tree, 'dangling.md'))
    return tree


ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.network.client</key><true/><key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array><string>/</string></array></dict></plist>"""
SANDBOX_ID = 'md.spacebar.test.webcheck'


def sandboxed(tree, check):
    """The harness signed with the preview extension's sandbox entitlements (build.sh's Preview.entitlements with the default
    READ_ACCESS=abs-ro): a PDF and an image from the `file` host must still render. macOS keeps a container for it under
    ~/Library/Containers/md.spacebar.test.webcheck."""
    out = tempfile.mkdtemp(prefix='spacebar-sandbox-')
    exe, ent, plist = (os.path.join(out, n) for n in ('webcheck', 'ent.plist', 'Info.plist'))
    open(ent, 'w').write(ENTITLEMENTS)
    open(plist, 'w').write(f'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{SANDBOX_ID}</string></dict></plist>')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos13.0'] +
                   [os.path.join(ROOT, *p) for p in (('test', 'web', 'main.swift'), ('Shared', 'Settings.swift'), ('Shared', 'WebShell.swift'),
                                                      ('Shared', 'FolderListing.swift'), ('Shared', 'LinkPolicy.swift'))] +
                   ['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', plist, '-o', exe], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '-i', SANDBOX_ID, '--entitlements', ent, exe], check=True, capture_output=True)
    ents = subprocess.run(['codesign', '-d', '--entitlements', '-', exe], capture_output=True, text=True).stdout
    proc = subprocess.Popen([exe, os.path.join(ROOT, 'Preview', 'web')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                            env=dict(os.environ, SPACEBAR_SUPPORT_DIR=os.path.join(out, 'support')))

    def cmd(c):
        proc.stdin.write(json.dumps(c) + '\n')
        proc.stdin.flush()
        line = proc.stdout.readline()
        return json.loads(line) if line else {'result': None, 'messages': []}
    try:
        cmd('@size:1000x760')
        cmd('@root:' + tree)
        r = cmd('@render:' + os.path.join(tree, 'doc.pdf'))
        cmd('@wait:1.5')
        rect = json.loads(cmd("@eval:JSON.stringify((() => { const r = document.querySelector('#doc .viewer-pdf iframe').getBoundingClientRect();"
                              " return [r.left + r.width / 2, r.top + r.height / 2]; })())")['result'])
        px = cmd('@pixel:%d,%d' % tuple(rect))['result']
        frames = [m.get('url') for m in r['messages'] if m.get('type') == '_frame']
        check('app-sandbox' in ents and frames and px and px[2] > 200 and px[0] < 60,
              'sandboxed like the extension: a PDF renders in the panel', f'pixel {px}, frames {frames}')
        cmd('@render:' + os.path.join(tree, 'photo.png'))
        cmd('@wait:0.5')
        w = cmd("@eval:(document.querySelector('#doc .viewer-image img') || {}).naturalWidth")['result']
        check(w and w > 0, 'sandboxed like the extension: an image renders from the file host', f'naturalWidth {w}')
    finally:
        proc.stdin.close()
        proc.wait(timeout=20)
        shutil.rmtree(out, ignore_errors=True)


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    folder = os.path.join(page.out, 'notes')
    os.makedirs(os.path.join(folder, 'sub'))
    heads = open(os.path.join(ROOT, 'test', 'corpus', 'headings.md')).read()
    files = {'README.md': '# Read me\n\nStart here.\n', 'b.md': '# Bee\n\nSecond.\n', 'a.md': heads,
             'tasks.md': '# Tasks\n\nA paragraph to edit.\n\n- [ ] one\n- [x] two\n', 'c10.md': '# Ten\n', 'c9.md': '# Nine\n',
             '.hidden.md': '# hidden\n', 'notes.txt': 'not markdown\n', HOSTILE: '# Hostile name\n'}
    for n, t in files.items():
        open(os.path.join(folder, n), 'w').write(t)
    os.symlink('/etc/hosts', os.path.join(folder, 'escape.md'))
    os.symlink('b.md', os.path.join(folder, 'link.md'))
    lone = os.path.join(page.out, 'lone')
    os.makedirs(lone)
    open(os.path.join(lone, 'only.md'), 'w').write('# Only\n')
    settings_file = os.path.join(page.support, 'settings.json')

    def disk():
        try:
            return json.load(open(settings_file))
        except FileNotFoundError:
            return {}

    def st():
        return page.js(STATE)

    def types(r):
        return [m.get('type') for m in r['messages']]

    try:
        # ---- document start: the saved state is on <html> before anything paints, and the first render does not animate ----
        # The render is called synchronously in the same task as the measurement, so this is the first layout the page shows.
        first = """const s = document.getElementById('sidebar'); let started = 0; s.addEventListener('transitionstart', () => started++);
          window.__started = () => started;
          sb.render(PAYLOAD); const cs = getComputedStyle(s);
          return { width: cs.width, visibility: cs.visibility, anims: s.getAnimations().length, anim: document.documentElement.classList.contains('sb-anim') };"""
        payload = {'text': '# Read me\n', 'path': os.path.join(folder, 'README.md'), 'name': 'README.md', 'reason': 'open', 'ver': 0,
                   'base': 'spacebar://file' + folder + '/', 'dir': os.path.realpath(folder), 'dirName': 'notes'}
        for collapsed, want in ((True, '0px'), (False, '240px')):
            page.cmd('@load:' + json.dumps({'sidebarCollapsed': collapsed}))
            p = page.js('return window.__sbProbe')
            f = page.js(first.replace('PAYLOAD', json.dumps(payload)))
            page.cmd('@wait:0.6')
            later = page.js("return [window.__started(), document.documentElement.classList.contains('sb-anim')]")
            attr = 'collapsed' if collapsed else 'open'
            check(p.get('startSidebar') == attr and p.get('dclSidebar') == attr and f['width'] == want and f['anims'] == 0 and not f['anim']
                  and later == [0, True], f'document start: sidebarCollapsed={collapsed} is in place before the first paint, no transition',
                  f'probe {p} first {f} later {later}')

        # ---- the list: same rules as folder mode, hidden files and links out of the folder skipped, names as text ----
        page.cmd('@load:{}')
        page.cmd('@size:1000x760')
        page.render(os.path.join(folder, 'b.md'))
        s = st()
        want = ['sub', 'README.md', 'a.md', 'b.md', 'c9.md', 'c10.md', 'link.md', 'notes.txt', 'tasks.md', HOSTILE]
        check(s['names'] == want and s['head'] == 'notes' and s['active'] == [['b.md', 'page']] and not s['hidden'] and not s['toggleHidden'],
              'single file: its folder listed, folders first, README first, names in Finder order, current file highlighted', json.dumps(s))
        check(page.js("return [document.querySelectorAll('#sidebar img').length, window.__pwned || null]") == [0, None],
              'a hostile file name is shown as text')
        page.cmd('@size:1000x760')
        page.apply(folderSort='modified')
        for i, n in enumerate(['tasks.md', 'c9.md', 'a.md']):
            os.utime(os.path.join(folder, n), (1e9 + i, 2e9 - i * 100))
        page.render(os.path.join(folder, 'b.md'))
        check(st()['names'][:5] == ['sub', 'README.md', 'tasks.md', 'c9.md', 'a.md'], 'sorted by date modified with README still first', json.dumps(st()['names']))
        page.apply(folderSort='name', folderReadmeFirst=False)
        page.render(os.path.join(folder, 'b.md'))
        check(st()['names'][1] == 'a.md', 'README first off: plain name order')
        page.apply(folderReadmeFirst=True)

        # ---- the folder watch: a file added or removed shows up in the list without a re-render ----
        page.render(os.path.join(folder, 'b.md'))
        open(os.path.join(folder, 'new.md'), 'w').write('# New\n')
        page.cmd('@relist')
        added = st()['names']
        os.remove(os.path.join(folder, 'new.md'))
        page.cmd('@relist')
        check('new.md' in added and 'new.md' not in st()['names'] and st()['active'] == [['b.md', 'page']],
              'a changed listing updates the list and keeps the highlight', json.dumps(added))

        # ---- click another file: it opens in the panel, reusing in-panel navigation ----
        r = click(page, '#side-list a[data-path$="/c9.md"]')
        opens = [m for m in r['messages'] if m.get('type') == 'open']
        page.cmd('@wait:0.3')
        s = st()
        check(len(opens) == 1 and s['title1'] == 'Nine' and s['active'] == [['c9.md', 'page']] and 'editBlock' not in types(r),
              'a sidebar click opens that file in the panel and moves the highlight', json.dumps(opens))
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'open', path: '/etc/hosts' }); 0")
        page.cmd('@wait:0.2')
        r2 = page.cmd('@eval:0')
        check('_openRefused' in types(r) + types(r2), 'an open for a file not in the list is refused')

        # ---- one component for single-file and folder previews ----
        page.render(os.path.join(folder, 'README.md'))
        folder_html = page.js("return document.getElementById('sidebar').outerHTML + document.getElementById('side-toggle').outerHTML")
        page.cmd('@renderfile:' + os.path.join(folder, 'README.md'))
        file_html = page.js("return document.getElementById('sidebar').outerHTML + document.getElementById('side-toggle').outerHTML")
        check(folder_html == file_html and 'README.md' in file_html, 'sidebar markup identical for a folder preview and a single file',
              f'{len(folder_html)} vs {len(file_html)} chars')
        page.render(os.path.join(lone, 'only.md'))
        s = st()
        check(s['names'] == ['only.md'] and s['head'] == 'lone' and s['width'] == '240px' and s['attr'] == 'open',
              'a folder with one Markdown file still shows the sidebar, in the saved state', json.dumps(s))

        # ---- the toggle: instant, animated, persisted through the writer, and the next preview starts in that state ----
        page.render(os.path.join(folder, 'b.md'))
        page.apply(width='full')
        open_left, open_w = st()['docLeft'], st()['docWidth']
        r = click(page, '#side-toggle')
        now = page.js("const s = document.getElementById('sidebar'); return [document.documentElement.dataset.sidebar, s.getAnimations().length]")
        posted = [m for m in r['messages'] if m.get('type') == 'setting']
        written = [m for m in r['messages'] if m.get('type') == '_written']
        page.cmd('@wait:0.5')
        s = st()
        check(now[0] == 'collapsed' and now[1] > 0, 'the toggle collapses at once, with a transition', json.dumps(now))
        check(len(posted) == 1 and posted[0].get('key') == 'sidebarCollapsed' and posted[0].get('value') in ('1', 'true')
              and posted[0].get('_mainFrame') in ('1', 'true') and posted[0].get('_origin') == 'spacebar://bundle',
              'the toggle posts sidebarCollapsed=true from the main frame of spacebar://bundle', json.dumps(posted))
        check(written and disk().get('sidebarCollapsed') is True, 'the writer saved it to settings.json', json.dumps(disk()))
        check(s['width'] == '0px' and s['visibility'] == 'hidden' and s['expanded'] == 'false' and s['title'] == 'Show sidebar'
              and s['docLeft'] == 0 and s['docWidth'] == 1000 and open_left == 240 and open_w == 760,
              'collapsed: the document takes the full width', f'open {open_left}/{open_w} -> {json.dumps(s)}')
        page.apply(width='medium')
        page.cmd('@loaddisk')
        p = page.js('return window.__sbProbe')
        page.render(os.path.join(folder, 'b.md'))
        check(p.get('dclSidebar') == 'collapsed' and st()['width'] == '0px', 'the next preview starts collapsed', json.dumps(p))
        r = click(page, '#side-toggle')
        page.cmd('@wait:0.5')
        check(disk().get('sidebarCollapsed') is False and st()['width'] == '240px' and st()['expanded'] == 'true',
              'toggled back open, and saved', json.dumps(disk()))

        # ---- another preview changed it: the live settings watch applies it here ----
        page.apply(sidebarCollapsed=True)
        a = st()
        page.apply(sidebarCollapsed=False)
        check(a['attr'] == 'collapsed' and a['expanded'] == 'false' and st()['attr'] == 'open', 'a change from elsewhere applies live', json.dumps(a))

        # ---- the message gate: only a boolean; only panel keys ----
        before = disk()
        bad = [('sidebarCollapsed', 1), ('sidebarCollapsed', 'true'), ('sidebarCollapsed', None), ('sidebarCollapsed', [True]),
               ('folderMode', True), ('remoteImages', True)]
        refused = 0
        for k, v in bad:
            r = page.cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': 'setting', 'key': k, 'value': v}) + '); 0')
            page.cmd('@wait:0.1')
            refused += '_settingRefused' in types(r) + types(page.cmd('@eval:0'))
        check(refused == len(bad) and disk() == before, 'non-boolean values and non-panel keys are refused; settings.json unchanged',
              f'{refused}/{len(bad)} refused, {json.dumps(disk())}')

        # ---- inline editing and task toggles with the sidebar open, and through a collapse ----
        page.render(os.path.join(folder, 'tasks.md'))
        r = click(page, '#doc > p')
        eb = [m for m in r['messages'] if m.get('type') == 'editBlock']
        check(eb and eb[0].get('text') == 'A paragraph to edit.' and eb[0].get('path', '').endswith('/tasks.md') and st()['editing'],
              'inline edit starts with the sidebar open', json.dumps(eb)[:200])
        r = click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        s = st()
        check(s['editing'] and s['editing'].startswith('A paragraph to edit.') and s['attr'] == 'collapsed'
              and not {'editStop', 'editCancel', 'editBlock'} & set(types(r)), 'collapsing keeps the edit open', json.dumps(types(r)))
        page.cmd('@eval:sb.editEnd({}); 0')
        click(page, '#side-toggle')
        r = page.cmd("@eval:(() => { const b = document.querySelector('#doc input[type=checkbox]'); b.click(); return 0; })()")
        tg = [m for m in r['messages'] if m.get('type') == 'toggle']
        check(tg and tg[0].get('line') == '4' and tg[0].get('checked') in ('1', 'true'), 'a task toggle posts with the sidebar open', json.dumps(tg))
        r = click(page, '#sidebar')
        check(not {'editBlock', 'editStop', 'open', 'link'} & set(types(r)), 'a click on the sidebar background does nothing', json.dumps(types(r)))

        # ---- the TOC rail, the Aa popover and narrow panels ----
        page.render(os.path.join(folder, 'a.md'))
        page.cmd('@size:1200x760')
        wide = st()['toc']
        page.cmd('@size:1000x760')
        mid_open = st()['toc']
        click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        mid_closed = st()['toc']
        click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        check(wide == 'block' and mid_open == 'none' and mid_closed == 'block', 'the TOC gives way to the open sidebar below 1100 px',
              f'1200 open {wide}, 1000 open {mid_open}, 1000 collapsed {mid_closed}')
        overlap = page.js("""const a = document.getElementById('sidebar').getBoundingClientRect(), b = document.getElementById('doc').getBoundingClientRect(),
          c = document.getElementById('side-toggle').getBoundingClientRect(), t = document.getElementById('toolbar').getBoundingClientRect();
          return [a.right <= b.left + 1, c.right < t.left, document.elementFromPoint(c.left + 4, c.top + 4).closest('#side-toggle') !== null]""")
        check(overlap == [True, True, True], 'sidebar, document, toggle and toolbar do not overlap', json.dumps(overlap))
        click(page, '#aa')
        r = click(page, '#aa-pop .swatch[data-value=nord]')
        check([m.get('value') for m in r['messages'] if m.get('type') == 'setting'] == ['nord'] and disk().get('theme') == 'nord'
              and st()['width'] == '240px', 'the Aa popover still works beside the sidebar', json.dumps(disk()))
        click(page, '#doc')
        page.apply(theme='apple')
        page.cmd('@size:600x700')
        s = st()
        check(s['width'] == '0px' and s['attr'] == 'open' and s['expanded'] == 'false' and s['docLeft'] == 0 and s['toc'] == 'none',
              'narrow: collapsed on screen, saved state unchanged', json.dumps(s))
        saved = disk()
        r = click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        s = st()
        check(s['peek'] and s['width'] == '240px' and s['position'] == 'fixed' and s['expanded'] == 'true' and 'setting' not in types(r)
              and disk() == saved, 'narrow: the toggle shows the sidebar over the page without saving', json.dumps(s))
        r = click(page, '#doc > p')
        check(not st()['peek'] and 'editBlock' not in types(r), 'narrow: a click outside closes it and starts no edit', json.dumps(types(r)))
        click(page, '#side-toggle')
        r = click(page, '#side-list a[data-path$="/b.md"]')
        page.cmd('@wait:0.3')
        check(not st()['peek'] and st()['title1'] == 'Bee' and 'open' in types(r), 'narrow: a file click opens it and closes the sidebar')
        page.cmd('@size:1000x760')
        check(not st()['peek'] and st()['width'] == '240px', 'widening restores the saved state')

        # ---- themes: sidebar text on its backgrounds, every theme light and dark ----
        low = []
        for mode in ('light', 'dark'):
            page.cmd('@appearance:' + mode)
            for t in THEMES:
                page.apply(theme=t)
                for p in page.js(HELPERS + """const side = document.getElementById('sidebar');
                    return [{ name: 'item', ...measure(side, 'var(--fg)', ['var(--bg)']) },
                            { name: 'active', ...measure(side, 'var(--fg)', ['var(--bg)', 'color-mix(in srgb, var(--accent) 12%, transparent)']) },
                            { name: 'hover', ...measure(side, 'var(--fg)', ['var(--bg)', 'color-mix(in srgb, var(--fg) 6%, transparent)']) },
                            { name: 'header', ...measure(side, 'var(--muted)', ['var(--bg)']) }];"""):
                    if p['ratio'] < 4.5:
                        low.append(f"{t} {mode} {p['name']} {p['ratio']}")
        check(not low, 'sidebar text reaches 4.5:1 in every theme, light and dark', '; '.join(low))
        page.cmd('@appearance:light')
        page.apply(theme='apple')

        # ---- reduced motion and the app's embedded sample ----
        rm = page.js("""const out = []; for (const sh of document.styleSheets) { let rules; try { rules = sh.cssRules; } catch (e) { continue; }
            const walk = (list) => { for (const r of list) { if (r.cssRules) walk(r.cssRules);
              if (r.media && /prefers-reduced-motion/.test(r.media.mediaText) && /#sidebar/.test(r.cssText) && /transition: none/.test(r.cssText)) out.push(r.media.mediaText); } };
            walk(rules); } return out.length""")
        check(rm >= 1, 'reduced motion turns the sidebar transition off')
        emb = page.js("""document.documentElement.classList.add('sb-embedded');
          const r = [getComputedStyle(document.getElementById('sidebar')).display, getComputedStyle(document.getElementById('side-toggle')).display];
          document.documentElement.classList.remove('sb-embedded'); return r""")
        check(emb == ['none', 'none'], "the app's embedded sample shows no sidebar or toggle", json.dumps(emb))

        # ================= the file browser =================
        tree = make_tree(page.out)
        T = lambda *p: os.path.join(tree, *p)
        pwn_types = ('_openFile', '_reveal', '_navigation')

        def pwned(r=None):
            msgs = (r or {}).get('messages', [])
            bad = [m for m in msgs if 'pwned' in json.dumps(m) or m.get('type') == 'edit']
            return page.js('return window.__pwned || null') or bad or None

        def view(path, root=tree):
            page.cmd('@root:' + root)
            r = page.render(path)
            page.cmd('@wait:0.3')
            return r

        # ---- the tree: folders first, each with its icon, links out of the root and hidden files left out ----
        page.apply(width='medium')
        page.cmd('@size:1200x800')
        view(T('README.md'))
        s = st()
        top = [r for r in s['rows'] if r[1] == 1]
        names = [r[0] for r in top]
        check(names[:3] == ['hostile', 'many', 'sub'] and all(r[2] == 'd' for r in top[:3]) and all(r[2] == 'f' for r in top[3:])
              and names[3] == 'README.md' and s['head'] == 'tree',
              'tree: the root, folders first, then README, then files', json.dumps(names))
        icons = {r[0]: r[3] for r in top}
        want_icons = {'hostile': 'ic-folder', 'README.md': 'ic-markdown', 'photo.png': 'ic-image', 'doc.pdf': 'ic-pdf', 'code.ts': 'ic-code',
                      'data.json': 'ic-data', 'table.csv': 'ic-data', 'notes.txt': 'ic-text', 'archive.zip': 'ic-other', 'tool': 'ic-other'}
        check(all(icons.get(k) == v for k, v in want_icons.items()), 'tree: every row has its type icon',
              json.dumps({k: icons.get(k) for k in want_icons}))
        check(not {'etc', 'up', 'hosts.txt', '.secret.md', 'dangling.md', '...', '..txt'} & set(names) and 'notes..v2.txt' in names,
              'tree: links to /etc, to the parent and to /etc/hosts, hidden files and dot names are left out',
              json.dumps(names))
        check(page.js("return document.querySelectorAll('#sidebar svg.ic').length === document.querySelectorAll('#side-list a.row').length"
                      " && !document.querySelector('#sidebar img, #sidebar use, #sidebar image')"), 'tree: icons are inline SVG drawn by the page')

        # ---- expand and collapse, lazily ----
        r = click(page, '#side-list a.row[data-path$="/sub"]')
        page.cmd('@wait:0.3')
        lists = [m.get('path') for m in r['messages'] if m.get('type') == 'list']
        s = st()
        kids = [r[0] for r in s['rows'] if r[1] == 2]
        check(lists == [T('sub')] and kids == ['deep', 'inner.md'] and ['sub', 1, 'd', 'ic-folder', 'true'] in s['rows'] and 'open' not in [m.get('type') for m in r['messages']],
              'expand: a folder click asks for that folder only, and its entries show one level down', json.dumps([lists, kids]))
        r = click(page, '#side-list a.row[data-path$="/sub"]')
        s = st()
        check([m.get('path') for m in r['messages'] if m.get('type') == 'unlist'] == [T('sub')] and not [x for x in s['rows'] if x[1] == 2]
              and ['sub', 1, 'd', 'ic-folder', 'false'] in s['rows'], 'collapse: its entries go and the folder is no longer watched')
        click(page, '#side-list a.row[data-path$="/sub"]')
        page.cmd('@wait:0.3')
        r = view(T('notes.txt'))
        check([x[0] for x in st()['rows'] if x[1] == 2] == ['deep', 'inner.md'] and not [m for m in r['messages'] if m.get('type') == 'list'],
              'expansion is remembered while another file of the root is shown')
        page.cmd('@session')
        r = view(T('README.md'))
        page.cmd('@wait:0.3')
        relisted = [m.get('path') for m in r['messages'] if m.get('type') == 'list']
        check(relisted == [T('sub')] and [x[0] for x in st()['rows'] if x[1] == 2] == ['deep', 'inner.md'],
              'a new preview of the same root keeps the expansion and asks for the folder again (to watch it)', json.dumps(relisted))
        click(page, '#side-list a.row[data-path$="/sub"]')
        r = view(T('sub', 'deep', 'deepest.txt'))
        page.cmd('@wait:0.4')
        s = st()
        check(['deep', 2, 'd', 'ic-folder', 'true'] in s['rows'] and s['active'] == [['deepest.txt', 'page']] and ['deepest.txt', 3, 'f', 'ic-text', None] in s['rows'],
              "the current file's folders open and it is highlighted", json.dumps(s['rows'][:6]))
        check(s['crumbs'] == 'tree›sub›deep›deepest.txt', 'the breadcrumb shows the path from the root', repr(s['crumbs']))
        page.cmd('@wait:0.2')
        click(page, '#side-list a.row[data-path$="/many"]')
        page.cmd('@wait:0.4')
        s = st()
        many = [x for x in s['rows'] if x[0].startswith('m-')]
        check(len(many) == 500 and s['notes'] == ['20 more not listed'], 'a folder of 520 files lists 500 with an "N more" note',
              f'{len(many)} rows, notes {s["notes"]}')
        click(page, '#side-list a.row[data-path$="/many"]')
        page.apply(showHiddenFiles=True)
        page.cmd('@relist')
        shown = [x[0] for x in st()['rows'] if x[1] == 1]
        dots = T('..%2F..%2Fetc%2Fpasswd.md')
        r = click(page, '#side-list a.row[data-path=' + json.dumps(dots) + ']')
        page.cmd('@wait:0.3')
        check({'...', '..txt', '..%2F..%2Fetc%2Fpasswd.md'} <= set(shown) and st()['title1'] == 'not a path' and st()['crumbs'].endswith('passwd.md'),
              'names made of dots and encoded slashes are plain files: listed with hidden files on, and open as themselves', json.dumps(shown[:8]))
        page.apply(showHiddenFiles=False)
        page.cmd('@relist')
        check('.secret.md' in shown and '.secret.md' not in [x[0] for x in st()['rows']] and 'etc' not in shown,
              'showHiddenFiles lists dot files; off again hides them; links out of the root stay out', json.dumps(shown[:6]))

        # ---- the gate: only folders and files the tree named, never above the root ----
        bad_lists = ['/etc', T('etc'), T('up'), T('..'), T('sub', '..'), T('sub', '..', '..'), tree + '/./sub', tree + '//sub', T('nope'), os.path.dirname(tree)]
        bad_opens = [T('hosts.txt'), T('etc', 'hosts'), '/etc/passwd', T('..', 'outside.md'), T('sub', '..', 'README.md'), T('up', 'README.md'), T('sub')]
        refused, before = 0, st()['crumbs']
        for kind, paths, want in (('list', bad_lists, '_listRefused'), ('open', bad_opens, '_openRefused')):
            for p in paths:
                r = page.cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': kind, 'path': p}) + '); 0')
                page.cmd('@wait:0.1')
                got = [m.get('type') for m in r['messages'] + page.cmd('@eval:0')['messages']]
                refused += want in got and 'rendered' not in got
        check(refused == len(bad_lists) + len(bad_opens) and st()['crumbs'] == before,
              'list and open refuse /etc, links out, "..", "." and "//" spellings, the parent, and folders as files',
              f'{refused}/{len(bad_lists) + len(bad_opens)}')

        # ---- file views ----
        r = view(T('photo.png'))
        page.cmd('@wait:0.4')
        im = page.js("const i = document.querySelector('#doc .viewer-image img'); return i && [i.naturalWidth, i.src.startsWith('spacebar://file/'), document.querySelector('#doc figcaption').textContent]")
        check(im and im[0] > 0 and im[1] and '×' in im[2] and st()['view'] == 'image', 'image: fitted, with its dimensions and size', json.dumps(im))
        check(page.js("const i = document.querySelector('#doc .viewer-image img'); const r = i.getBoundingClientRect(); return r.height <= innerHeight && r.width <= document.getElementById('doc').clientWidth"),
              'image: never larger than the panel')
        r = view(T('code.ts'))
        c = page.js("""return { kw: document.querySelectorAll('#doc .code-view .hljs-keyword').length, gutter: document.querySelector('#doc .gutter').textContent.split('\\n').length,
          text: document.querySelector('#doc pre.code').textContent, edit: document.getElementById('edit').hidden, stats: document.getElementById('stats').textContent,
          kind: document.querySelector('#doc .viewer-kind').textContent, button: document.querySelector('#doc button.viewer-open').textContent }""")
        check(c['kind'].startswith('Source code') and c['button'] == 'Reveal in Finder', '.ts is named as source and never opened as a video', json.dumps(c['kind']))
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({type:'openFile', path: " + json.dumps(T('code.ts')) + "}); 0")
        page.cmd('@wait:0.1')
        check('_openRefused' in [m.get('type') for m in r['messages'] + page.cmd('@eval:0')['messages']], 'openFile for a .ts file is refused')
        check(c['kw'] > 0 and c['gutter'] == 6 and c['text'] == open(T('code.ts')).read() and c['edit'] and c['stats'] == '6 lines',
              'code: highlighted, with line numbers; no "Open in editor" for anything but Markdown', json.dumps({k: v for k, v in c.items() if k != 'text'}))
        r = click(page, '#doc pre.code')
        check('editBlock' not in [m.get('type') for m in r['messages']] and not page.js("return document.querySelector('#doc .md-editing')"),
              'code: a click edits nothing (editing is for Markdown only)')
        view(T('data.json'))
        pretty = page.js("return document.querySelector('#doc pre.code').textContent")
        click(page, '#doc .viewer-toggle')
        raw = page.js("return [document.querySelector('#doc pre.code').textContent, document.querySelector('#doc .viewer-toggle').textContent]")
        click(page, '#doc .viewer-toggle')
        again = page.js("return document.querySelector('#doc pre.code').textContent")
        check(pretty == json.dumps(json.load(open(T('data.json'))), indent=2) and raw[0] == open(T('data.json')).read() and raw[1] == 'Formatted' and again == pretty
              and page.js("return document.querySelectorAll('#doc .hljs-attr').length") > 0, 'JSON: pretty-printed and highlighted, with a raw toggle',
              json.dumps([pretty, raw, again])[:300])
        view(T('table.csv'))
        t = page.js("return [[...document.querySelectorAll('#doc table.csv thead th')].map((x) => x.textContent), [...document.querySelectorAll('#doc table.csv tbody tr')].map((r) => [...r.cells].map((c) => c.textContent))]")
        check(t == [['name', 'qty', 'note'], [['apple', '3', 'red, crisp'], ['pear', '5', 'says "hi"'], ['fig', '', 'line one\nline two']]],
              'CSV: a table, first row as header, quotes, commas and newlines in cells', json.dumps(t))
        view(T('big.csv'))
        b = page.js("return [document.querySelectorAll('#doc table.csv tbody tr').length, [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
        check(b == [1000, ['Showing the first 1,000 of 1,500 rows.']], 'CSV: capped at 1,000 rows with a note', json.dumps(b))
        view(T('wide.csv'))
        wc = page.js("return [document.querySelectorAll('#doc table.csv thead th').length, document.querySelectorAll('#doc table.csv tbody td').length, [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
        check(wc == [200, 200, ['Showing the first 200 columns.']], 'CSV: capped at 200 columns with a note', json.dumps(wc))
        view(T('forged.md'))
        r = page.cmd('@nativeclick:#doc .viewer button')
        r2 = page.cmd('@nativeclick:#doc .viewer button + button')
        check(page.js("return !!document.querySelector('#doc .viewer button')") and not [m for m in r['messages'] + r2['messages'] if m.get('type') in ('reveal', 'openFile', '_reveal', '_openFile')],
              "a Markdown document's look-alike viewer buttons reveal and open nothing")
        page.cmd('@eval:sb.editEnd({}); 0')
        view(T('notes.txt'))
        check(page.js("return [document.querySelector('#doc pre.code').textContent, document.querySelectorAll('#doc pre.code span').length]") == [open(T('notes.txt')).read(), 0],
              'text: shown as is, with line numbers')
        view(T('huge.log'))
        h = page.js("return [document.querySelector('#doc pre.code').textContent.length, [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
        check(h[0] == 2 * 1024 * 1024 and h[1] == ['Showing the first 2 MB of 3.1 MB.'], 'text over 2 MB: its first 2 MB, with a note', json.dumps(h))
        r = view(T('archive.zip'))
        card = page.js("""const c = document.querySelector('#doc .info-card'); return c && { name: c.querySelector('.info-name').textContent,
          dt: [...c.querySelectorAll('dt')].map((x) => x.textContent), size: c.querySelector('dd').textContent, icon: !!c.querySelector('svg.ic'),
          button: c.querySelector('button').textContent, action: c.querySelector('button').dataset.action }""")
        check(card and card['name'] == 'archive.zip' and card['dt'] == ['Size', 'Modified', 'Where'] and card['size'] == '4.1 KB (4,096 bytes)'
              and card['icon'] and card['button'] == 'Reveal in Finder', 'other: an info card with icon, name, kind, size and date; an archive only reveals',
              json.dumps(card))
        r = click(page, '#doc .info-card button')
        synthetic = [m for m in r['messages'] if m.get('type') in ('reveal', 'openFile')]
        r = page.cmd('@nativeclick:#doc .info-card button')
        check(not synthetic and [m.get('type') for m in r['messages'] if m.get('type', '').startswith('_')] == ['_reveal'] and
              [m for m in r['messages'] if m.get('type') == 'reveal'][0].get('path') == T('archive.zip'),
              'Reveal in Finder posts reveal for the file on screen, for a real click only', json.dumps(r['messages'])[:300])
        view(T('movie.mp4'))
        r = page.cmd("@eval:sb.setOpener({ path: " + json.dumps(T('movie.mp4')) + ", app: 'QuickTime Player' }); 0")
        b = page.js("return [document.querySelector('#doc .info-card button').textContent, document.querySelector('#doc .info-card button').dataset.action]")
        r = page.cmd('@nativeclick:#doc .info-card button')
        check(b == ['Open with QuickTime Player', 'openFile'] and '_openFile' in [m.get('type') for m in r['messages']],
              'a document the link policy allows: "Open with <default app>", through the writer', json.dumps(b))
        for f in ('tool', 'run.sh'):
            view(T(f))
            b = page.js("return document.querySelector('#doc button.viewer-open').textContent")
            check(b == 'Reveal in Finder', f'{f}: an executable or a script only reveals', b)
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({type:'openFile', path: " + json.dumps(T('run.sh')) + "}); 0")
        page.cmd('@wait:0.1')
        check('_openRefused' in [m.get('type') for m in r['messages'] + page.cmd('@eval:0')['messages']], 'openFile for a script is refused')
        r = view(T('doc.pdf'))
        page.cmd('@wait:1.5')
        frames = [m.get('url') for m in r['messages'] if m.get('type') == '_frame']
        rect = page.js("const r = document.querySelector('#doc .viewer-pdf iframe').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]")
        px = page.cmd('@pixel:%d,%d' % (rect[0], rect[1]))['result']
        check(len(frames) == 1 and frames[0].startswith('spacebar://file' + T('doc.pdf') + '?v=') and px and px[2] > 200 and px[0] < 60,
              'PDF: rendered in the panel, in the one frame the shell allows', f'{frames} pixel {px}')

        # ---- hostile files: nothing runs, nothing renders as a document ----
        H = lambda f: T('hostile', f)
        r = view(H('page.html'))
        page.cmd('@wait:0.5')
        a = page.js("""const d = document.getElementById('doc'); return { view: document.documentElement.dataset.view, text: d.querySelector('pre.code').textContent.includes('<script>'),
          els: d.querySelectorAll('script, iframe, img, base, meta, a, object, embed').length, bases: document.querySelectorAll('base').length,
          base: document.getElementById('base').href.startsWith('spacebar://file/') }""")
        check(a == {'view': 'code', 'text': True, 'els': 0, 'bases': 1, 'base': True} and not pwned(r), 'hostile .html: shown as source, never rendered', json.dumps(a))
        r = view(H('image.svg'))
        page.cmd('@wait:0.5')
        a = page.js("const d = document.getElementById('doc'); return [document.documentElement.dataset.view, d.querySelectorAll('img').length, d.querySelectorAll('svg:not(.ic), script, iframe, object, embed').length, (d.querySelector('img') || {}).naturalWidth]")
        check(a == ['image', 1, 0, 40] and not pwned(r), 'hostile .svg: an <img> only, its script never runs', json.dumps(a))
        r = click(page, '#doc .viewer-image img')
        check(not pwned(r) and not [m for m in r['messages'] if m.get('type') in ('link', '_navigation')], 'hostile .svg: a click on it follows nothing')
        r = view(H('code.js'))
        page.cmd('@wait:0.3')
        check(page.js("return document.querySelectorAll('#doc img, #doc script').length") == 0 and not pwned(r), 'hostile .js: its source cannot break out of the code view')
        r = view(H('data.json'))
        check(page.js("return document.querySelectorAll('#doc img, #doc script').length") == 0 and not pwned(r), 'hostile JSON: markup in strings stays text')
        r = view(H('table.csv'))
        cells = page.js("return [...document.querySelectorAll('#doc table.csv tbody td')].map((c) => c.textContent)")
        check(page.js("return document.querySelectorAll('#doc img, #doc script, #doc a').length") == 0 and not pwned(r) and cells and cells[0].startswith('<img'),
              'hostile CSV: markup and formulas in cells stay text', json.dumps(cells)[:120])
        r = view(H('evil.pdf'))
        page.cmd('@wait:1.5')
        check(not pwned(r) and not [m for m in r['messages'] if m.get('type') == '_navigation'], 'hostile PDF: its JavaScript cannot reach the page')
        r = page.cmd("@eval:(() => { const f = document.createElement('iframe'); f.src = " + json.dumps('spacebar://file' + H('page.html')) + "; document.body.appendChild(f);"
                     " const g = document.createElement('iframe'); g.src = " + json.dumps('spacebar://file' + T('doc.pdf')) + "; document.body.appendChild(g); return 0; })()")
        page.cmd('@wait:0.8')
        r2 = page.cmd('@eval:0')
        navs = [m.get('url') for m in r['messages'] + r2['messages'] if m.get('type') == '_navigation']
        check(len(navs) == 2 and not [m for m in r['messages'] + r2['messages'] if m.get('type') == '_frame'] and not pwned(r2),
              'no frame loads but the PDF on screen: an HTML file or another PDF in an injected frame is cancelled', json.dumps(navs)[:200])
        page.cmd("@eval:document.querySelectorAll('body > iframe').forEach((f) => f.remove()); 0")

        # ---- Markdown in the browser: still edits, and the TOC and toggles work beside any view ----
        view(T('README.md'))
        r = click(page, '#doc > p')
        check([m for m in r['messages'] if m.get('type') == 'editBlock'] and st()['view'] == 'markdown' and not page.js("return document.getElementById('edit').hidden"),
              'Markdown opened from the tree still edits in place, with "Open in editor"')
        page.cmd('@eval:sb.editEnd({}); 0')

        # ---- resizing: dragged, clamped, saved once when the drag ends, reset by a double-click ----
        page.cmd('@root:')
        page.cmd('@size:1000x760')
        page.render(os.path.join(folder, 'b.md'))
        w0 = st()['width']
        r = page.cmd('@nativedrag:#side-resize,80')
        sets = [m for m in r['messages'] if m.get('type') == 'setting']
        check(w0 == '240px' and st()['width'] == '320px' and len(sets) == 1 and sets[0].get('key') == 'sidebarWidth' and sets[0].get('value') == '320'
              and disk().get('sidebarWidth') == 320 and st()['attr'] == 'open', 'drag: the width follows, one setting is saved when the drag ends',
              f'{w0} -> {st()["width"]}, {json.dumps(sets)}')
        r = page.cmd('@nativedrag:#side-resize,-600')
        check(st()['width'] == '160px' and st()['attr'] == 'open' and disk().get('sidebarWidth') == 160 and disk().get('sidebarCollapsed') is False,
              'drag below the minimum stops at 160 px and does not collapse', st()['width'])
        page.cmd('@nativedrag:#side-resize,900')
        check(st()['width'] == '450px' and disk().get('sidebarWidth') == 450, 'drag past the maximum stops at 45% of the panel', st()['width'])
        page.cmd('@size:1400x760')
        wide = st()['width']
        page.cmd('@nativedrag:#side-resize,300')
        check(wide == '450px' and st()['width'] == '480px' and disk().get('sidebarWidth') == 480, 'and never past 480 px', f'{wide} -> {st()["width"]}')
        page.cmd('@size:1000x760')
        r = page.cmd("@eval:document.getElementById('side-resize').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); 0")
        page.cmd('@wait:0.3')
        check(st()['width'] == '240px' and disk().get('sidebarWidth') == 240, 'double-click resets to the default width', st()['width'])
        page.cmd('@nativedrag:#side-resize,60')
        r = page.cmd("@eval:(() => { const h = document.getElementById('side-resize'); const r = h.getBoundingClientRect();"
                     " h.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 0, pointerId: 7, clientX: r.left + 2, clientY: 200 }));"
                     " for (let i = 1; i <= 20; i++) h.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, pointerId: 7, clientX: r.left + 2 + i * 3, clientY: 200 }));"
                     " return document.documentElement.style.getPropertyValue('--side-saved'); })()")
        mid = [m for m in r['messages'] if m.get('type') == 'setting']
        r2 = page.cmd("@eval:document.getElementById('side-resize').dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 7 })); 0")
        page.cmd('@wait:0.3')
        check(r['result'] == '360px' and not mid and len([m for m in r2['messages'] if m.get('type') == 'setting']) == 1 and disk().get('sidebarWidth') == 360,
              'twenty moves write nothing; the one save comes on release', f"{r['result']} {len(mid)}")
        page.cmd('@loaddisk')
        p0 = page.js('return window.__sbProbe')
        f0 = page.js(first.replace('PAYLOAD', json.dumps(payload)))
        check(f0['width'] == '360px' and f0['anims'] == 0, 'the next preview starts at the saved width, before the first paint (no jump)', json.dumps(f0))
        page.cmd('@size:600x700')
        click(page, '#side-toggle')
        page.cmd('@wait:0.3')
        n = st()
        click(page, '#doc')
        page.cmd('@size:1000x760')
        check(n['peek'] and n['width'] == '270px' and st()['width'] == '360px', 'narrow: shown over the page within 45% of it; widening restores the saved width',
              f"{n['width']} -> {st()['width']}")
        page.cmd("@eval:document.getElementById('side-resize').dispatchEvent(new MouseEvent('dblclick', { bubbles: true })); 0")
        page.cmd('@wait:0.3')

        csp = [l for l in page.logs if 'csp blocked' in l]
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l]
        check(not csp and not errs, 'no CSP violations or page errors logged', json.dumps(csp + errs)[:300])
        page.close()
        sandboxed(tree, check)
    finally:
        if page.proc.poll() is None:
            page.close()
        shutil.rmtree(page.out, ignore_errors=True)

    print(f'\n{sum(results)}/{len(results)} sidebar checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
