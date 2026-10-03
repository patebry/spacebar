#!/usr/bin/env python3
"""The sidebar and the file browser in the page on its own, outside Quick Look: Preview/web in the offscreen harness
(test/web/main.swift), which lists the tree with the extension's FolderListing, renders each file with its FileView, routes
"list", "open", "openFile" and "reveal" through the same checks as the extension, and sends "setting" through the extension's
gate (Settings.panelPatch) and the writer's update (SettingsFile.updateFromPanel) into a scratch SPACEBAR_SUPPORT_DIR.

Checks the tree (folders first, icons, lazy expand and collapse, remembered expansion, the current file's folders opened, hidden
files, the cap, links out of the root), every file view (Markdown, image, SVG, PDF, code, JSON, CSV, text, the info card), the
hostile fixtures in test/hostile/browser beside a link to /etc and names made of dots, the resize handle, the no-flash
document-start state, the toggle and its persistence, the message gate, and that inline editing, task toggles, the TOC, the Aa
popover, themes and narrow panels still work with the sidebar open or collapsed, and the native PDF view: laid over the page's
PDF area, following the sidebar and the panel, and torn down cleanly. A sandboxed copy of the harness, signed with the
extension's entitlements, shows that a PDF and an image render under the extension's sandbox."""
import base64, json, os, random, shutil, struct, subprocess, sys, tempfile, urllib.parse, wave, zlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, ROOT, THEMES, HELPERS, TASK_NAMES, click
import hostile

# The outlined page's edge: a PDF sits inside it, the gap and the hairline in from the panel's edges.
EDGE = 7
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


def make_png(w, h, rgb=(230, 70, 90)):
    """A solid PNG, for the info card's thumbnail."""
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b''.join(b'\0' + bytes(rgb) * w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


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
    for name, n in (('blob.dat', 4096), ('movie.mp4', 2048), ('movie.webm', 2048), ('tool', 3000)):
        open(os.path.join(tree, name), 'wb').write(b'\0' + bytes(rnd.randrange(256) for _ in range(n - 1)))
    for name in ('tool', 'run.sh'):
        os.chmod(os.path.join(tree, name), 0o755)
    for i in range(5050):
        open(os.path.join(tree, 'many', f'm-{i:04d}.txt'), 'w').write(f'{i}\n')
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(tree, 'photo.png'))
    open(os.path.join(tree, 'doc.pdf'), 'wb').write(make_pdf('Hello PDF'))
    open(os.path.join(tree, 'broken.pdf'), 'wb').write(b'%PDF-1.4\nnot really a pdf\n')
    with wave.open(os.path.join(tree, 'song.wav'), 'wb') as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(8000), w.writeframes(b'\0\0' * 8000)
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


def make_vault(fx):
    """An Obsidian-style vault with its notes only in subfolders, a .obsidian folder, embeds, callouts, tags, a hostile note, and
    beside it folders of images and PDFs, a repository, an empty folder, a huge folder and an app bundle."""
    def put(rel, text='x\n', age=0):
        path = os.path.join(fx, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'wb' if isinstance(text, bytes) else 'w').write(text)
        if age:
            os.utime(path, (1.7e9 - age, 1.7e9 - age))
    put('Vault/.obsidian/app.json', '{}')
    put('Vault/Daily/2026-09-24.md', '# Yesterday\n', age=500)
    put('Vault/Daily/2026-09-25.md', '# Today\n\nSee [[Projects/Plan|Plan]], [[Ideas#Later|ideas]], [[Nowhere]] and [[#Heading here]]. #project and #area/sub, not #123.\n\n'
        '> [!warning] Careful\n> Body line.\n\n> [!info]-\n> Folded body.\n\n> A plain quote.\n\n![[pic.png|120]]\n\n![[Ideas]]\n\n'
        '`[[not a link]]` and `#notatag`\n\n## Heading here\n', age=10)
    put('Vault/Projects/Plan.md', '# Plan\n', age=300)
    put('Vault/Notes/Ideas.md', '# Ideas\n\n- [ ] an embedded task\n\n' + 'Filler paragraph.\n\n' * 60 + '## Later\n\nLater ideas.\n' + 'More.\n\n' * 40, age=400)
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(fx, 'Vault', 'Attachments', 'pic.png')) if os.makedirs(os.path.join(fx, 'Vault', 'Attachments'), exist_ok=True) is None else None
    put('outside/secret.md', '# secret\n')
    os.symlink(os.path.join(fx, 'outside', 'secret.md'), os.path.join(fx, 'Vault', 'secret.md'))
    put('Vault/Inbox/Hostile.md', '# Hostile\n\n[[../outside]] [[/etc/hosts]] [[../../../../etc/hosts]] [[secret]] [[.obsidian/app]] ![[../outside/secret]] ![[/etc/hosts]]\n\n'
        '<a class="wikilink" data-wl="../outside/secret.md" href="#">forged</a> <img class="wl-img" data-wl="/etc/hosts"> '
        '<span class="wl-embed" data-wl="../outside/secret"></span>\n', age=900)
    put('Vault/Inbox/Repeat.md', '# Repeat\n\n' + '![[Ideas]] ' * 1000 + '\n', age=950)
    for i, n in enumerate(('a.png', 'b.png', 'c.png')):
        shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(fx, 'images', n)) if os.makedirs(os.path.join(fx, 'images'), exist_ok=True) is None else None
        os.utime(os.path.join(fx, 'images', n), (1.7e9 - 100 + i * 10, 1.7e9 - 100 + i * 10))
    put('images/scan.pdf', make_pdf('scan'), age=500)
    put('pdfs/one.pdf', make_pdf('one'), age=10)
    put('pdfs/two.pdf', make_pdf('two'), age=20)
    put('repo/.git/HEAD', 'ref\n')
    put('repo/src/main.swift', 'print(1)\n')
    put('repo/node_modules/dep/README.md', '# dep\n')
    put('repo/docs/guide.md', '# Guide\n')
    os.makedirs(os.path.join(fx, 'empty'))
    os.makedirs(os.path.join(fx, 'huge'))
    for i in range(6000):
        open(os.path.join(fx, 'huge', f'f{i:05d}.txt'), 'w').close()
    os.makedirs(os.path.join(fx, 'Tool.app', 'Contents'))
    return os.path.join(fx, 'Vault')


ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.network.client</key><true/><key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array><string>/</string></array></dict></plist>"""
SANDBOX_ID = 'md.spacebar.test.webcheck'


def sandboxed(tree, check, runtime=False):
    """The harness signed with the preview extension's sandbox entitlements (and, `runtime`, under the hardened runtime, as the
    Space helper's viewer is signed) (build.sh's Preview.entitlements with the default
    READ_ACCESS=abs-ro): PDFKit must read the PDF, and an image from the `file` host must still render. macOS keeps a container for it under
    ~/Library/Containers/md.spacebar.test.webcheck."""
    out = tempfile.mkdtemp(prefix='spacebar-sandbox-')
    exe, ent, plist = (os.path.join(out, n) for n in ('webcheck', 'ent.plist', 'Info.plist'))
    open(ent, 'w').write(ENTITLEMENTS)
    open(plist, 'w').write(f'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{SANDBOX_ID}</string></dict></plist>')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos13.0'] +
                   [os.path.join(ROOT, *p) for p in (('test', 'web', 'main.swift'), ('test', 'offscreen.swift'), ('Shared', 'Settings.swift'), ('Shared', 'WebShell.swift'),
                                                      ('Shared', 'FolderListing.swift'), ('Shared', 'ArchiveListing.swift'), ('Shared', 'FolderScan.swift'), ('Shared', 'LinkPolicy.swift'), ('Preview', 'PDFPane.swift'),
                                                      ('Preview', 'Gestures.swift'), ('Preview', 'Thumbnail.swift'), ('Preview', 'ImagePane.swift'), ('test', 'nsevents.swift'))] +
                   ['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', plist, '-o', exe], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '-i', SANDBOX_ID] + (['--options', 'runtime'] if runtime else []) + ['--entitlements', ent, exe],
                   check=True, capture_output=True)
    ents = subprocess.run(['codesign', '-d', '--entitlements', '-', exe], capture_output=True, text=True).stdout
    flags = subprocess.run(['codesign', '-dv', exe], capture_output=True, text=True).stderr
    label = 'hardened like the viewer' if runtime else 'sandboxed like the extension'
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
        cmd('@render:' + os.path.join(tree, 'doc.pdf'))
        cmd('@wait:0.5')
        pdf = cmd('@pdf')['result']
        check('app-sandbox' in ents and pdf['open'] and pdf['placed'] and pdf['text'] == 'Hello PDF' and pdf.get('pixel') and pdf['pixel'][2] > 200,
              f'{label}: PDFKit reads and draws the PDF', json.dumps(pdf) + (' runtime flag missing' if runtime and 'runtime' not in flags else ''))
        if runtime:
            check('runtime' in flags, f'{label}: signed with the runtime flag', flags)
        cmd('@render:' + os.path.join(tree, 'photo.png'))
        cmd('@wait:0.5')
        w = cmd("@eval:(document.querySelector('#doc .viewer-image img') || {}).naturalWidth")['result']
        check(w and w > 0, f'{label}: an image renders from the file host', f'naturalWidth {w}')
    finally:
        proc.stdin.close()
        proc.wait(timeout=20)
        shutil.rmtree(out, ignore_errors=True)


CURSOR = """const t = (s) => (document.querySelector(s) || {}).textContent || null;
  return { cursor: t('#side-list a.cursor'), active: t('#side-list a.active'), focus: document.activeElement.id || document.activeElement.tagName,
    rows: [...document.querySelectorAll('#side-list a.row')].map((a) => [a.textContent, +a.getAttribute('aria-level'), a.getAttribute('aria-expanded')]),
    notes: [...document.querySelectorAll('#side-list .row-note')].map((n) => n.textContent), q: document.getElementById('side-q').value };"""


SHOTS = os.environ.get('SPACEBAR_SHOTS', '')


def shoot(page, name):
    """A screenshot of the page into $SPACEBAR_SHOTS, in light and dark, when it is set."""
    if not SHOTS:
        return
    os.makedirs(SHOTS, exist_ok=True)
    for mode in ('light', 'dark'):
        page.cmd('@appearance:' + mode)
        page.cmd('@wait:0.3')
        page.cmd(f'@shot:{os.path.join(SHOTS, name)}-{mode}.png')
    page.cmd('@appearance:light')


def dispatch_key(page, key, **mods):
    opts = dict(key=key, bubbles=True, cancelable=True, **mods)
    r = page.cmd('@eval:(() => { const e = new KeyboardEvent("keydown", ' + json.dumps(opts) + '); document.body.dispatchEvent(e); return String(e.defaultPrevented); })()')
    page.cmd('@wait:0.3')
    return r


EDITOR = """const p = document.querySelector('#doc pre.code.text-editing');
  return p && { text: p.textContent, caret: !!p.querySelector('.caret'), sel: (p.querySelector('.sel') || {}).textContent || null,
    spans: p.querySelectorAll('code span[class^=hljs-]').length, gutter: p.parentElement.querySelector('.gutter').textContent.split('\\n').length };"""


def text_editing(page, check, out, view, T):
    """Click-to-edit for every text-like file: a click on the text starts an edit of the whole file (the page asks with "editText"),
    changes arrive as the extension sends them and are saved in the file's own encoding (the harness's @type stands in for the
    writer and the extension), Raw on the JSON, CSV and XML views as the way to their text to edit, the quiet invalid-JSON warning, and what is never editable."""
    types = lambda r: [m.get('type') for m in r['messages']]
    d = os.path.join(out, 'edit')
    os.makedirs(d)
    files = {'notes.txt': 'line one\nline two\n', 'conf.yaml': 'name: spacebar\nlist:\n  - 1\n', 'Cargo.toml': '[package]\nname = "x"\n',
             'pom.xml': '<project>\n  <name>x</name>\n</project>\n', 'setup.ini': '[core]\nname = x\n', 'nginx.conf': 'server {\n  listen 80;\n}\n',
             '.env': 'TOKEN=abc\n', 'Makefile': 'all:\n\techo hi\n', 'code.ts': 'const a: number = 1;\n', 'data.json': '{"a": [1, 2], "b": {"c": true}}\n',
             'table.csv': 'name,qty\napple,3\npear,5\n', 'notes.tsv': 'a\tb\n1\t2\n'}
    for n, t in files.items():
        open(os.path.join(d, n), 'w').write(t)
    open(os.path.join(d, 'latin.txt'), 'wb').write('Café — 25 €\n'.encode('cp1252'))
    E = lambda n: os.path.join(d, n)
    typ = lambda text, at: page.cmd('@type:' + json.dumps({'text': text, 'selStart': at, 'selLen': 0}))['result']
    end = lambda: page.cmd('@eval:sb.editEnd({}); 0')
    asked = lambda r, n: [m for m in r['messages'] if m.get('type') == 'editText' and m.get('path', '').endswith('/' + n)]

    for n in ('notes.txt', 'conf.yaml', 'Cargo.toml', 'pom.xml', 'setup.ini', 'nginx.conf', '.env', 'Makefile', 'code.ts', 'notes.tsv'):
        view(E(n), root=d)
        formatted = n in ('notes.tsv', 'pom.xml')
        if formatted:
            page.cmd('@nativeclick:#raw')
        r = click(page, '#doc pre.code')
        e = page.js(EDITOR)
        check(asked(r, n) and e and e['text'] == files[n] and e['caret'] and int(asked(r, n)[0]['len']) == len(files[n]),
              f'click-to-edit: {n} is edited in place, the whole file{" (Raw)" if formatted else ""}', json.dumps([types(r), e])[:300])
        end()
        if formatted:
            page.cmd('@nativeclick:#raw')
    view(E('pom.xml'), root=d)
    r = click(page, '#doc pre.code')
    check(not asked(r, 'pom.xml'), 'XML: the indented view is not the file, and a click on it edits nothing')

    view(E('code.ts'), root=d)
    click(page, '#doc pre.code')
    res = typ('const a: number = 12;\nconst b = "two";\n', 36)
    page.cmd('@wait:0.2')
    e = page.js(EDITOR)
    check(res == 'saved' and e and e['text'] == 'const a: number = 12;\nconst b = "two";\n' and e['caret'] and e['spans'] > 3 and e['gutter'] == 2
          and open(E('code.ts')).read() == 'const a: number = 12;\nconst b = "two";\n',
          'auto-save: each change is on screen, highlighted as typed, with its line numbers, and saved with no Save step', json.dumps([res, e]))
    end()
    page.cmd('@wait:0.2')
    h = page.js("return [!!document.querySelector('#doc pre.text-editing'), document.querySelector('#doc pre.code').textContent, document.querySelectorAll('#doc .hljs-keyword').length]")
    check(h[0] is False and h[1] == 'const a: number = 12;\nconst b = "two";\n' and h[2] >= 2, 'the edit ends into the highlighted view of the new text', json.dumps(h))

    # Many changes in a row, as the extension sends them: the view must always hold the text, the caret where it is, and (in a
    # long file, drawn in blocks) no block ending inside a line.
    FUZZ = """let seed = 7; const rnd = (n) => { seed = (seed * 16807) % 2147483647; return seed % n; };
      const bits = ['x', '\\n', 'ab\\ncd', '', '  ', 'é🚀'], bad = [];
      for (let k = 0; k < 60; k++) {
        const t = editing.text, from = rnd(t.length + 1), to = Math.min(t.length, from + (rnd(3) ? rnd(3) : rnd(400)));
        const insert = bits[rnd(bits.length)], next = t.slice(0, from) + insert + t.slice(to), at = from + insert.length;
        sb.textUpdate({ seq: editing.seq, from, to, insert, selStart: at, selLen: k % 7 ? 0 : Math.min(5, next.length - at), keyTime: 0 });
        const pre = document.querySelector('#doc pre.text-editing'), code = pre.querySelector('code');
        const r = document.createRange(); r.selectNodeContents(code); r.setEndBefore(code.querySelector('.caret, .sel'));
        const blocks = [...code.querySelectorAll('.tchunk')].slice(0, -1).filter((b) => b.textContent && !b.textContent.endsWith('\\n'));
        if (code.textContent !== next || r.toString().length !== at || blocks.length) bad.push(k);
      }
      return { bad, len: editing.text.length, chunks: document.querySelectorAll('#doc .tchunk').length };"""
    for n, lines in (('fuzz-small.ts', 40), ('fuzz-long.ts', 3000)):
        open(E(n), 'w').write(''.join(f'const v{i} = "value {i}"; // line {i}\n' for i in range(lines)))
        view(E(n), root=d)
        click(page, '#doc pre.code')
        f = page.js(FUZZ)
        page.cmd('@wait:0.4')
        after = page.js("return document.querySelector('#doc pre.text-editing code').textContent === editing.text")
        check(f and f['bad'] == [] and after and (f['chunks'] > 1) == (lines > 40),
              f'60 changes in a row keep the view exact ({"in blocks" if lines > 40 else "highlighted, then highlighted again"})', json.dumps(f))
        end()

    view(E('latin.txt'), root=d)
    click(page, '#doc pre.code')
    res = typ('Café — 30 € “net”\n', 5)
    check(res == 'saved' and open(E('latin.txt'), 'rb').read() == 'Café — 30 € “net”\n'.encode('cp1252'),
          'auto-save: a Windows-1252 file is saved in Windows-1252', repr(open(E('latin.txt'), 'rb').read()))
    res = typ('Café — 30 € ☃\n', 5)
    check(res == 'unencodable' and open(E('latin.txt'), 'rb').read() == 'Café — 30 € “net”\n'.encode('cp1252'),
          'a character Windows-1252 cannot hold is not saved, and the file is not converted', res)
    end()

    view(E('data.json'), root=d)
    b = page.js("const b = document.getElementById('raw'); return [b.hidden, b.getAttribute('aria-pressed'), !!document.querySelector('#doc .json-tree'), !document.querySelector('#doc .viewer-edit')]")
    page.cmd('@nativeclick:#raw')
    raw = page.js("return [!!document.querySelector('#doc pre.code[data-file-text]'), document.getElementById('raw').getAttribute('aria-pressed'), (document.querySelector('#doc pre.code') || {}).textContent]")
    check(b == [False, 'false', True, True] and raw == [True, 'true', files['data.json']], 'JSON: Raw flips the tree to the file\'s text, which a click edits; there is no separate Edit button', json.dumps([b, raw]))
    r = click(page, '#doc pre.code')
    bad = '{"a": [1, 2], "b": {"c": tru}}\n'
    res = typ(bad, 25)
    page.cmd('@wait:0.4')
    warn = page.js("return [...document.querySelectorAll('#doc .json-warn')].map((n) => n.textContent)")
    col = bad.index('tru}') + 1
    check(asked(r, 'data.json') and res == 'saved' and open(E('data.json')).read() == bad and warn == [f'Invalid JSON at line 1, column {col}. It is saved as typed.'],
          'JSON: invalid JSON gets a quiet warning with its line and column, and is still saved', json.dumps([res, warn]))
    typ('{"a": [1, 2], "b": {"c": false}}\n', 30)
    page.cmd('@wait:0.4')
    check(page.js("return document.querySelectorAll('#doc .json-warn').length") == 0, 'JSON: the warning goes once the text is JSON again')
    r = page.cmd('@nativeclick:#raw')
    page.cmd('@wait:0.2')
    tr = page.js("return [...document.querySelectorAll('#doc .json-tree .jt-row')].map((r) => r.textContent)")
    check('editStop' in types(r) and any('false' in x for x in tr) and not page.js("return document.querySelector('#doc pre.text-editing')"),
          'JSON: Raw again ends the edit and shows the tree of the edited text', json.dumps([types(r), tr])[:300])
    r = click(page, '#doc .json-tree .jt-row')
    check(not asked(r, 'data.json'), 'JSON: the tree is not the file, and a click on it edits nothing')

    view(E('table.csv'), root=d)
    page.cmd('@nativeclick:#raw')
    csv_title = page.js("return document.getElementById('raw').title")
    r = click(page, '#doc pre.code')
    res = typ('name,qty\napple,3\npear,5\nfig,7\n', 30)
    page.cmd('@nativeclick:#raw')
    page.cmd('@wait:0.2')
    rows = page.js("return [...document.querySelectorAll('#doc table.csv tbody tr')].map((r) => [...r.cells].map((c) => c.textContent))")
    check(asked(r, 'table.csv') and res == 'saved' and rows == [['1', 'apple', '3'], ['2', 'pear', '5'], ['3', 'fig', '7']]
          and open(E('table.csv')).read().endswith('fig,7\n') and csv_title == 'Raw text', 'CSV: Raw flips the table to its text to edit, and back to the edited table', json.dumps([res, rows]))

    page.apply(inlineEditing=False)
    view(E('code.ts'), root=d)
    r = click(page, '#doc pre.code')
    off = page.js("return [!!document.querySelector('#doc pre.text-editing'), getComputedStyle(document.querySelector('#doc pre.code')).cursor]")
    view(E('data.json'), root=d)
    page.cmd('@nativeclick:#raw')
    rj = click(page, '#doc pre.code')
    page.cmd('@nativeclick:#raw')
    check(not asked(r, 'code.ts') and not asked(rj, 'data.json') and off == [False, 'auto'],
          'inline editing off: no click-to-edit, in code or in raw JSON', json.dumps(off))
    page.apply(inlineEditing=True)

    for n, why in (('huge.log', 'over 2 MB, shown cut'), ('hosts.txt', 'a link to a file of another name'), ('blob.dat', 'binary')):
        view(T(n))
        r = click(page, '#doc pre.code') if page.js("return !!document.querySelector('#doc pre.code')") else {'messages': []}
        check(not [m for m in r['messages'] if m.get('type') == 'editText'] and not page.js("return document.querySelector('#doc [data-file-text], #doc pre.text-editing')"),
              f'not editable: {n} ({why})')


def big_folder(page, check, T):
    """The tree's `many` folder, open: 5,050 files, 5,000 listed, drawn a window at a time, and reached by the keys and the filter."""
    ROWS = """const l = document.getElementById('side-list'), rows = [...l.querySelectorAll('a.row')];
      const m = rows.filter((a) => a.textContent.startsWith('m-'));
      return { dom: rows.length, height: l.scrollHeight, first: m.length ? m[0].textContent : null, last: m.length ? m[m.length - 1].textContent : null,
        set: m.length ? m[0].getAttribute('aria-setsize') : null, pos: m.length ? m[0].getAttribute('aria-posinset') : null,
        notes: [...l.querySelectorAll('.row-note')].map((n) => n.textContent), cursor: (l.querySelector('a.cursor') || {}).textContent || null,
        pads: l.querySelectorAll('.side-pad').length, top: l.scrollTop };"""
    b = page.js(ROWS)
    check(b['dom'] < 300 and b['height'] >= 5000 * 24 and b['set'] == '5000' and b['first'] == 'm-0000.txt' and b['pos'] == '1' and b['pads'] >= 1,
          'a folder of 5,050 files: 5,000 listed, only the rows in view drawn, each row numbered in its set', json.dumps(b))
    page.cmd("@eval:(() => { const l = document.getElementById('side-list'); l.scrollTop = l.scrollHeight; l.dispatchEvent(new Event('scroll')); return 0; })()")
    page.cmd('@wait:0.3')
    b = page.js(ROWS)
    check(b['last'] == 'm-4999.txt' and b['notes'] == ['50 more not listed · Filter finds them'] and b['dom'] < 300,
          'scrolled to its end: the last listed file and the "50 more not listed" note are drawn', json.dumps(b))
    click(page, '#side-list a.row[data-path$="/m-4990.txt"]')
    page.cmd('@wait:0.4')
    dispatch_key(page, 'End')
    b = page.js(ROWS)
    check(b['cursor'] == 'wide.csv' and b['dom'] < 300, 'End reaches the last row, far below the rows drawn, and draws it', json.dumps(b))
    dispatch_key(page, 'Home')
    b = page.js(ROWS)
    check(b['cursor'] == 'hostile' and b['top'] == 0, 'Home goes back to the first row', json.dumps(b))
    page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = 'm-4999'; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
    f = page.js("return [...document.querySelectorAll('#side-list a.row')].map((a) => a.textContent)")
    check(f == ['many', 'm-4999.txt'], 'the filter finds a file past the old cap of 500', json.dumps(f))
    click(page, '#side-list a.row[data-path$="/m-4999.txt"]')
    page.cmd('@wait:0.4')
    page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = ''; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
    page.cmd('@wait:0.3')
    a = page.js("return [...document.querySelectorAll('#side-list a.active')].map((a) => a.textContent)")
    check(a == ['m-4999.txt'], 'the filter cleared: the file opened from it, far down the list, is scrolled to and drawn', json.dumps(a))


def steady_list(page, check, out):
    """The list holds still, as Finder's does: a click on a row in view, a file opened from one, a folder opened under the pointer
    or rows put in above the cursor never move it; ↓ scrolls only once the cursor reaches the edge, by one row, edge-aligned."""
    d = os.path.join(out, 'steady')
    for f in ('afolder', 'zfolder'):
        os.makedirs(os.path.join(d, f))
        for i in range(30):
            open(os.path.join(d, f, f'{f[0]}{i:02d}.txt'), 'w').write(f'{i}\n')
    for i in range(80):
        open(os.path.join(d, f'f{i:02d}.txt'), 'w').write(f'{i}\n')
    P = lambda *n: os.path.join(d, *n)
    ROW = """const l = document.getElementById('side-list'), r = l.querySelector('a.row[data-path="%s"]'), b = l.getBoundingClientRect();
      return { top: l.scrollTop, y: r ? r.getBoundingClientRect().top - b.top : null, low: r ? b.top + l.clientHeight - r.getBoundingClientRect().bottom : null,
        h: l.clientHeight, cursor: (l.querySelector('a.cursor') || { dataset: {} }).dataset.path || null, current: current.path };"""
    at = lambda p: page.js(ROW % p)
    scroll = lambda t: page.cmd("@eval:(() => { const l = document.getElementById('side-list'); l.scrollTop = " + str(t)
                                + "; l.dispatchEvent(new Event('scroll')); return 0; })()")
    page.cmd('@root:' + d)
    page.cmd('@size:1000x500')
    page.render(P('f05.txt'))
    page.cmd('@wait:0.3')
    # Where a row sits in the list, and a scrollTop that puts it in the middle.
    idx = lambda p: page.js('return sideRows.findIndex((r) => r.e && r.e.path === ' + json.dumps(p) + ')')
    mid = lambda p: idx(p) * 24 - 150

    def press(path, top, wait=0.6):
        scroll(top)
        page.cmd('@wait:0.1')
        a = at(path)
        r = page.cmd('@nativeclick:#side-list a.row[data-path="' + path + '"]')
        b = at(path)
        page.cmd('@wait:' + str(wait))
        return a, b, at(path), r

    still = lambda a, *later: all(x['top'] == a['top'] and abs(x['y'] - a['y']) <= 1 for x in later)
    a, b, c, r = press(P('f20.txt'), mid(P('f20.txt')))
    fb = [m for m in r['messages'] if m.get('type') == 'filterBegin']
    check(c['current'] == P('f20.txt') and still(a, b, c), 'steady list: a click on a row in the middle of a long list opens it and moves nothing, '
          'after the render or later', json.dumps([a, b, c]))
    a, b, c, _ = press(P('f26.txt'), (idx(P('f26.txt')) + 1) * 24 - page.js("return document.getElementById('side-list').clientHeight") - 11)
    check(c['current'] == P('f26.txt') and a['low'] < 0 and still(a, b, c), 'steady list: a row cut off at the bottom opens where it is, not pulled '
          'toward the middle', json.dumps([a, b, c]))

    seq = int(fb[0]['seq']) if fb else -1
    key = lambda k: page.cmd('@eval:sb.filterKey(' + json.dumps({'seq': seq, 'key': k}) + '); 0')
    a, _, _, r = press(P('f20.txt'), mid(P('f20.txt')))
    fb = [m for m in r['messages'] if m.get('type') == 'filterBegin']
    seq = int(fb[0]['seq']) if fb else -1
    key('down')
    b = at(P('f21.txt'))
    page.cmd('@wait:0.6')
    c = at(P('f21.txt'))
    check(c['cursor'] == c['current'] == P('f21.txt') and b['top'] == c['top'] == a['top'], 'steady list: ↓ within view moves the cursor, not the list',
          json.dumps([a, b, c]))
    h = a['h']
    # f25 the last row wholly in view: ↓ to f26 scrolls one row and no more, its bottom on the list's.
    scroll((idx(P('f25.txt')) + 1) * 24 - h)
    page.cmd('@eval:cursor = ' + json.dumps(P('f25.txt')) + '; markCursor(); 0')
    a = at(P('f25.txt'))
    key('down')
    b = at(P('f26.txt'))
    page.cmd('@wait:0.6')
    c = at(P('f26.txt'))
    check(0 <= a['low'] <= 1 and b['top'] - a['top'] == 24 and 0 <= b['low'] <= 1 and c['top'] == b['top'] and c['current'] == P('f26.txt'),
          'steady list: ↓ past the bottom scrolls by one row, the cursor edge-aligned at the bottom, never centred', json.dumps([a, b, c]))

    # A folder opened under the pointer, and a file in it, hold still; so does a folder holding the file on screen opened again.
    a, b, c, _ = press(P('zfolder'), 0)
    check(c['cursor'] == P('zfolder') and still(a, b, c) and page.js('return expanded().has(' + json.dumps(P('zfolder')) + ')'),
          'steady list: a folder opened by a click stays where it was clicked', json.dumps([a, b, c]))
    a, b, c, _ = press(P('zfolder', 'z12.txt'), mid(P('zfolder', 'z12.txt')))
    check(c['current'] == P('zfolder', 'z12.txt') and still(a, b, c), 'steady list: a click on a file in an open folder moves nothing',
          json.dumps([a, b, c]))
    page.render(P('zfolder', 'z29.txt'))
    page.cmd('@wait:0.3')
    a, b, c, _ = press(P('zfolder'), 0)
    a2, b2, c2, _ = press(P('zfolder'), 0)
    check(page.js('return expanded().has(' + json.dumps(P('zfolder')) + ')') is True and still(a, b, c) and still(a2, b2, c2) and a2['top'] == 0,
          'steady list: a folder holding the file on screen, closed and opened again, never scrolls to that file', json.dumps([a, c, a2, c2]))

    # Rows put in above the cursor leave it where it is on screen.
    press(P('f40.txt'), mid(P('f40.txt')))
    a = at(P('f40.txt'))
    page.cmd('@eval:toggleFolder(' + json.dumps(P('afolder')) + '); 0')
    page.cmd('@wait:0.4')
    b = at(P('f40.txt'))
    check(abs(b['y'] - a['y']) <= 1 and b['top'] - a['top'] == 30 * 24, 'steady list: a folder of 30 opened above the cursor leaves its row still on screen',
          json.dumps([a, b]))

    # Opened afresh on a file far down, the list shows it with its top row whole, not cut under the filter field.
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    page.cmd('@root:' + P('afolder'))
    page.render(P('afolder', 'a00.txt'))
    page.cmd('@root:' + d)
    page.render(P('f60.txt'))
    page.cmd('@wait:0.4')
    a = at(P('f60.txt'))
    check(a['top'] > 0 and a['top'] % 24 == 0 and a['y'] >= 0 and a['low'] >= 0, 'steady list: opened on a file far down, it is in view and the top row '
          'is whole', json.dumps(a))
    page.cmd('@size:1100x760')
    page.cmd('@root:')


def one_selection(page, check, out):
    """After a click or Return, the arrows leave one row looking selected, the cursor: the file on screen catches up with it, a row
    left under the pointer keeps no highlight and is never redrawn under it, a row already in view never scrolls, and a cursor in
    a folder closed under it moves on from that folder."""
    d = os.path.join(out, 'one-selection')
    os.makedirs(os.path.join(d, 'folder'))
    for i in range(40):
        open(os.path.join(d, f'{i:02d}.txt'), 'w').write(f'{i}\n')
    open(os.path.join(d, 'folder', 'inner.txt'), 'w').write('inner\n')
    open(os.path.join(d, 'folder', 'other.txt'), 'w').write('other\n')
    LIT = """const l = document.getElementById('side-list'), nm = (a) => a && a.querySelector('.nm').textContent, c = l.querySelector('a.cursor');
      return { lit: [...l.querySelectorAll('a.row')].filter((a) => getComputedStyle(a).backgroundColor !== 'rgba(0, 0, 0, 0)').map(nm),
        cursor: nm(c) || null, active: nm(l.querySelector('a.active')) || null, hover: [...l.querySelectorAll('a.row:hover')].map(nm),
        top: l.scrollTop, fade: c ? getComputedStyle(c).transitionDuration : null,
        kept: [...l.querySelectorAll('a.row')].every((a) => a.__kept), keyed: l.classList.contains('keyed') };"""
    keep = lambda: page.cmd("@eval:document.querySelectorAll('#side-list a.row').forEach((a) => { a.__kept = 1; }); 0")
    page.cmd('@root:' + d)
    page.cmd('@size:1000x500')
    page.render(os.path.join(d, '03.txt'))
    page.cmd('@wait:0.3')
    r = page.cmd('@nativeclick:#side-list a.row[data-path="' + os.path.join(d, '03.txt') + '"]')
    fb = [m for m in r['messages'] if m.get('type') == 'filterBegin']
    seq = int(fb[0]['seq']) if fb else -1
    key = lambda *ks: page.cmd('@eval:' + ''.join('sb.filterKey(' + json.dumps({'seq': seq, 'key': k}) + '); ' for k in ks) + '0')
    key('return')
    page.cmd('@wait:0.3')
    keep()
    key('down')
    page.cmd('@wait:0.3')
    one = page.js(LIT)
    check(one['lit'] == ['04.txt'] and one['cursor'] == one['active'] == '04.txt' and one['hover'] == ['03.txt'] and one['fade'] == '0s' and one['kept'],
          'one selection: after a click and Return, ↓ leaves the row under the pointer unlit; nothing fades or is redrawn under it', json.dumps(one))
    ahead = page.js("sb.filterKey(" + json.dumps({'seq': seq, 'key': 'down'}) + "); sb.filterKey(" + json.dumps({'seq': seq, 'key': 'down'}) + "); " + LIT)
    page.cmd('@wait:0.5')
    caught = page.js(LIT)
    check(ahead['lit'] == ['06.txt'] and ahead['active'] == '04.txt' and caught['lit'] == ['06.txt'] and caught['cursor'] == caught['active'] == '06.txt'
          and caught['top'] == 0, 'one selection: keys ahead of the renders light the cursor alone; the file on screen catches up, nothing scrolls',
          json.dumps([ahead, caught]))
    key(*['down'] * 14)
    page.cmd('@wait:0.5')
    low = page.js("""const l = document.getElementById('side-list'), c = l.querySelector('a.cursor').getBoundingClientRect(), b = l.getBoundingClientRect();
      return [l.scrollTop, Math.round(b.bottom - c.bottom), l.querySelector('a.cursor .nm').textContent]""")
    check(low[0] > 0 and 0 <= low[1] <= 1 and low[2] == '20.txt', 'one selection: the list scrolls only once the cursor reaches its edge, and no further',
          json.dumps(low))
    key('home', 'right')
    page.cmd('@wait:0.3')
    key('down')
    page.cmd('@wait:0.3')
    inside = page.js(LIT)['cursor']
    page.cmd('@eval:toggleFolder(' + json.dumps(os.path.join(d, 'folder')) + '); 0')
    key('down')
    page.cmd('@wait:0.3')
    after = page.js(LIT)
    check(inside == 'inner.txt' and after['cursor'] == '00.txt' and after['lit'] == ['00.txt'],
          'one selection: a cursor in a folder closed under it moves on from the folder, not from the top', json.dumps([inside, after]))
    click(page, '#side-list a.row[data-path="' + os.path.join(d, '02.txt') + '"]')
    check(not page.js(LIT)['keyed'], 'one selection: a click hands the highlight back to the pointer')

    # The pointer moving over the list hands the highlight back too; a pointermove with no movement (a redraw under it) does not.
    key('down')
    page.cmd('@wait:0.3')
    move = lambda dx: page.js("document.getElementById('side-list').dispatchEvent(new PointerEvent('pointermove', { bubbles: true, movementX: " + str(dx)
                              + " })); return document.getElementById('side-list').classList.contains('keyed')")
    still, moved = move(0), move(3)
    check(still and not moved and page.js(LIT)['lit'] == ['03.txt'], 'one selection: the pointer moving over the list brings its hover back; standing still does not',
          json.dumps([still, moved]))

    # The file on screen is always lit when drawn: with the cursor filtered out, and after an open the keys did not make.
    key('down', 'down', 'home')
    page.cmd('@wait:0.4')
    typed = lambda q: page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = " + json.dumps(q)
                               + "; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
    typed('05')
    page.cmd('@wait:0.4')
    hidden = page.js(LIT)
    typed('')
    page.cmd('@wait:0.3')
    page.cmd('@eval:keyed.set(' + json.dumps(os.path.join(d, '09.txt')) + ', performance.now()); post({ type: "open", path: ' + json.dumps(os.path.join(d, '12.txt')) + ' }); 0')
    page.cmd('@wait:0.4')
    linked = page.js(LIT)
    check(hidden['cursor'] is None and hidden['lit'] == ['05.txt'] and hidden['active'] == '05.txt' and linked['lit'] == ['12.txt']
          and linked['cursor'] == linked['active'] == '12.txt', 'one selection: the file on screen stays lit with the cursor filtered out, and an open '
          'the keys did not make takes the cursor even with a key open pending', json.dumps([hidden, linked]))

    # Filtered, Return with the cursor hidden leaves the folder shown for a match alone.
    folder = os.path.join(d, 'folder')
    page.cmd('@eval:cursor = ' + json.dumps(os.path.join(folder, 'other.txt')) + '; 0')
    typed('inner')
    page.cmd('@wait:0.4')
    before = page.js('return expanded().has(' + json.dumps(folder) + ')')
    key('return')
    page.cmd('@wait:0.3')
    after = page.js('return [expanded().has(' + json.dumps(folder) + '), [...document.querySelectorAll("#side-list a.row")].map((a) => a.textContent)]')
    typed('')
    check(after[0] == before and after[1] == ['folder', 'inner.txt'], 'one selection: Return in a filter never closes a folder from a hidden cursor',
          json.dumps([before, after]))

    # Rows that share a path are each drawn.
    dup = page.js("""const l = document.createElement('div'), mk = () => { const a = document.createElement('a'); a.dataset.path = '/x'; return a; };
      l.append(mk(), mk()); patchList(l, [mk(), mk(), mk()]); return [l.children.length, new Set(l.children).size]""")
    check(dup == [3, 3], 'one selection: rows sharing a path are each kept', json.dumps(dup))

    # A root of / with the cursor nowhere in the list: the keys still return, filtered or not.
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    page.cmd('@root:/')
    page.render(os.path.join(d, '00.txt'))
    page.cmd('@wait:0.5')
    typed('zzqqxxnomatch')
    page.cmd('@wait:0.5')
    a = dispatch_key(page, 'ArrowDown')
    typed('')
    page.cmd('@wait:0.3')
    page.cmd("@eval:cursor = '/no-such-folder-zz/x'; 0")
    b = dispatch_key(page, 'ArrowDown')
    check(a['result'] is not None and b['result'] is not None and page.js(LIT)['cursor'] is not None,
          'one selection: with a root of /, a hidden cursor does not hang the keys, filtered or not', json.dumps([a['result'], b['result']]))
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    page.cmd('@size:1100x760')
    page.cmd('@root:')


def contents_search(page, check, out):
    """The filter's Contents mode: the Names / Contents toggle and its placeholder, results with a match count, a folder and a
    snippet, find in the file run for the same query when a result opens (by a click or the arrows), a new keystroke cancelling
    the search before it, the caps with the "Searched N of M files" note, binary files skipped, and hidden files by the setting."""
    d = os.path.join(out, 'contents')
    for sub in ('src/lib', '.hid', 'node_modules/x'):
        os.makedirs(os.path.join(d, sub))
    put = lambda n, data: open(os.path.join(d, n), 'wb' if isinstance(data, bytes) else 'w').write(data)
    put('README.md', '# Readme\n\nThe Quokka lives here.\n')
    put('notes.txt', 'first line\n' + 'filler\n' * 400 + 'a quokka, far down, and QUOKKA again\n')
    put('src/app.ts', 'export const quokka = 1;\n')
    put('src/lib/util.py', 'def other():\n    return "no match"\n')
    put('data.json', json.dumps({'animal': 'quokka', 'n': 1}))
    put('pic.png', open(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), 'rb').read() + b'quokka')
    put('blob.txt', b'quokka\0\1\2binary')
    put('.hidden.md', 'a hidden quokka\n')
    put('.hid/deep.md', 'a quokka in a hidden folder\n')
    put('node_modules/x/index.js', 'quokka in a dependency\n')
    D = lambda n: os.path.join(d, n)
    HITS = """const l = document.getElementById('side-list');
      return { rows: [...l.querySelectorAll('a.row')].map((a) => [a.querySelector('.nm').textContent, (a.querySelector('.hit-dir') || {}).textContent || '',
          (a.querySelector('.hit-n') || {}).textContent || '', (a.querySelector('.hit-snip') || {}).textContent || '', a.offsetHeight]),
        marks: [...l.querySelectorAll('.hit-snip mark')].map((m) => m.textContent), status: document.getElementById('side-more').hidden ? '' : document.getElementById('side-more').textContent,
        mode: document.querySelector('#side-mode [aria-checked=true]').textContent, pressed: document.querySelector('#side-mode [data-mode=contents]').getAttribute('aria-checked'),
        width: Math.round(document.getElementById('side-q').getBoundingClientRect().width),
        placeholder: document.getElementById('side-q').placeholder, cursor: (l.querySelector('a.cursor .nm') || {}).textContent || null };"""
    FIND = """const c = CSS.highlights, cur = c.get('sb-find-cur');
      return { open: !document.getElementById('find').hidden, q: document.getElementById('find-q').value, count: document.getElementById('find-count').textContent,
        text: cur && cur.size ? [...cur][0].toString() : null, top: cur && cur.size ? Math.round([...cur][0].getBoundingClientRect().top) : null,
        path: document.title, inner: innerHeight };"""
    typed = lambda q: page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = " + json.dumps(q)
                               + "; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
    types_of = lambda r: [m.get('type') for m in r['messages']]

    def settle(until_done=True):
        for _ in range(40):
            page.cmd('@wait:0.05')
            h = page.js(HITS)
            if not until_done or not h['status'].startswith('Searching'):
                return h
        return page.js(HITS)

    page.cmd('@root:' + d)
    page.render(D('README.md'))
    page.cmd('@wait:0.3')
    h = page.js(HITS)
    check(h['mode'] == 'Names' and h['pressed'] == 'false' and h['placeholder'] == 'Filter', 'contents: the filter starts on Names', json.dumps(h))
    names_width = h['width']
    r = click(page, '#side-mode [data-mode=contents]')
    h = page.js(HITS)
    check(h['mode'] == 'Contents' and h['pressed'] == 'true' and h['placeholder'] == 'Search contents' and 'search' not in types_of(r)
          and h['width'] == names_width,
          'contents: the toggle switches to Contents, says so, searches nothing while the field is empty, and the field keeps its width', json.dumps(h))
    typed('q')
    h = page.js(HITS)
    check(h['status'] == 'Type 2 or more characters' and any(x[0] == 'src' for x in h['rows']),
          'contents: one character keeps the tree and asks for more', json.dumps(h))

    # A keystroke cancels the search before it: the old one reports nothing more once the next is sent.
    r1 = typed('qu')
    r2 = typed('quo')
    typed('quokka')
    h = settle()
    seqs = page.js('return searchSeq')
    check(h['status'] == 'Found in 4 files', 'contents: the search finishes and says how many files matched', json.dumps(h))
    stale = page.js("""return (() => { const before = hits.version; sb.searchResults({ seq: searchSeq - 1, hits: [{ path: tree.root + '/notes.txt',
      name: 'stale', snippet: 'x', count: 1, line: 1 }], searched: 1, total: 1, done: true }); return hits.version === before; })()""")
    check(stale and 'search' in types_of(r1) and 'search' in types_of(r2) and seqs >= 3,
          'contents: every keystroke sends a new search, and a report from an older one is dropped', json.dumps([stale, seqs]))

    rows = {x[0]: x for x in h['rows']}
    check(set(rows) == {'README.md', 'notes.txt', 'data.json', 'app.ts'},
          'contents: the results are the text files that match (binary, the image, hidden files and dependencies skipped)', json.dumps(h['rows']))
    check(rows['notes.txt'][2] == '2' and rows['notes.txt'][3] == 'a quokka, far down, and QUOKKA again' and rows['app.ts'][1] == 'src'
          and rows['README.md'][1] == '' and all(x[4] == 40 for x in h['rows']) and 'Quokka' in h['marks'] and 'QUOKKA' in h['marks'],
          'contents: each result has its match count, its folder, and the matching line with the matches marked', json.dumps(h))
    check('blob.txt' not in rows and 'pic.png' not in rows, 'contents: binary files are skipped', json.dumps(list(rows)))
    check('.hidden.md' not in rows and 'deep.md' not in rows, 'contents: hidden files are not searched while hidden', json.dumps(list(rows)))

    # Cancellation, natively: two keystrokes at once over 2,000 files; the first search never reports once the second starts.
    bulk = os.path.join(out, 'contents-bulk')
    os.makedirs(bulk)
    for i in range(2000):
        open(os.path.join(bulk, f'f{i:04d}.txt'), 'w').write('quokka and more quokka\n' * 20)
    page.cmd('@root:' + bulk)
    page.render(os.path.join(bulk, 'f0000.txt'))
    page.cmd('@wait:0.3')
    r = page.cmd("@eval:(() => { const q = document.getElementById('side-q'); for (const t of ['qu', 'quokka']) { q.value = t; q.dispatchEvent(new Event('input', { bubbles: true })); } return searchSeq; })()")
    seq = str(r['result'])
    seen = [m for m in r['messages'] if m.get('type') == '_searchReport']
    for _ in range(60):
        seen += [m for m in page.cmd('@wait:0.05')['messages'] if m.get('type') == '_searchReport']
        if any(m.get('seq') == seq and m.get('done') == 'true' for m in seen):
            break
    h = page.js(HITS)
    n = page.js('return hits.list.length')
    check(seen and all(m.get('seq') == seq for m in seen) and h['status'] == 'Showing the first 500 files' and n == 500,
          'contents: a new keystroke cancels the search before it, which reports nothing more; results stop at 500 files',
          json.dumps([seq, [m.get('seq') for m in seen][:10], h['status'], n]))
    # Typing on: the results on screen keep the marks of the query they were found for, and the new results start at the top.
    page.cmd("@eval:document.getElementById('side-list').scrollTop = 3000; 0")
    m = page.js("""const l = document.getElementById('side-list'), before = l.querySelectorAll('.hit-snip mark').length, top = l.scrollTop;
      const q = document.getElementById('side-q'); q.value = 'quokka and'; q.dispatchEvent(new Event('input', { bubbles: true }));
      return [before, l.querySelectorAll('.hit-snip mark').length, top]""")
    settle()
    top = page.js("return document.getElementById('side-list').scrollTop")
    check(m[0] > 0 and m[1] == m[0] and m[2] > 0 and top == 0,
          'contents: while the next search runs the results keep their marks, and its results start at the top of the list', json.dumps([m, top]))
    q = page.js("""const q = document.getElementById('side-q'); q.value = 'quokka and more'; q.dispatchEvent(new Event('input', { bubbles: true }));
      const p = hits.list.find((h) => h.path !== current.path).path; openHit(p); const out = [hits.listQ, findOnOpen && findOnOpen.q]; findOnOpen = null; return out""")
    settle()
    check(q[0] == q[1] == 'quokka and', 'contents: a result opened while the next search runs finds the query it was found for', json.dumps(q))
    page.cmd('@root:' + d)
    page.render(D('README.md'))
    page.cmd('@wait:0.3')
    typed('quokka')
    settle()

    # Opening a result runs find for the same query and scrolls to its first match.
    page.cmd('@size:900x500')
    r = click(page, '#side-list a.row[data-path$="/notes.txt"]')
    page.cmd('@wait:0.5')
    f = page.js(FIND)
    check('open' in types_of(r) and f['open'] and f['q'] == 'quokka' and f['count'] == '1 of 2' and f['text'] == 'quokka'
          and f['top'] is not None and 0 < f['top'] < f['inner'] and f['path'] == 'notes.txt',
          'contents: a result opens its file with find run for the query, its first match current and scrolled into view', json.dumps(f))
    check('filterBegin' not in types_of(r) or all(not m.get('find') for m in r['messages'] if m.get('type') == 'filterBegin'),
          'contents: find opened by a result leaves the keys with the sidebar', json.dumps(types_of(r)))
    order = [x[0] for x in page.js(HITS)['rows']]
    at = order.index('notes.txt')
    dispatch_key(page, 'ArrowDown')
    page.cmd('@wait:0.4')
    f = page.js(FIND)
    h = page.js(HITS)
    want = order[at + 1] if at + 1 < len(order) else order[at]
    check(h['cursor'] == want and f['path'] == want and f['q'] == 'quokka' and f['text'] and f['text'].lower() == 'quokka',
          'contents: the arrows move through the results, and each opens with find run', json.dumps([order, h['cursor'], f]))
    page.cmd('@size:1100x760')

    # A new preview of the same folder holds none of the last one's search: the page runs it again, and its results still open.
    page.cmd('@session')
    h = settle()
    other = page.js("return document.querySelector('#side-list a.row.hit:not(.active) .nm').textContent")
    r = click(page, '#side-list a.row.hit:not(.active)')
    page.cmd('@wait:0.5')
    f = page.js(FIND)
    check(h['status'] == 'Found in 4 files' and 'open' in types_of(r) and '_openRefused' not in types_of(r) and f['path'] == other and f['q'] == 'quokka',
          'contents: after a new preview of the same folder the search runs again and its results open', json.dumps([h['status'], types_of(r), f]))

    # Hidden files: searched once they are shown.
    page.apply(showHiddenFiles=True)
    typed('quokk')
    h = settle()
    names = [x[0] for x in h['rows']]
    check('.hidden.md' in names and 'deep.md' in names and 'index.js' not in names,
          'contents: with hidden files shown, hidden files and folders are searched; dependency folders never are', json.dumps(names))
    page.apply(showHiddenFiles=False)

    # The caps: a bytes cap cuts the search short, and the note says how far it got.
    page.cmd('@searchlimits:' + json.dumps({'maxTotalBytes': 60}))
    typed('quokka')
    h = settle()
    m = h['status']
    check(' of 6 searched' in m and ' · 6 of 6' not in m, 'contents: a search cut short by a cap says "N of M searched"', m)
    page.cmd('@searchlimits:' + json.dumps({'budget': 0}))
    typed('quokk')
    h = settle()
    check(h['status'] in [f'{f} · {i} of 6 searched' for i in range(2) for f in ('No matches', 'Found in 1 file')], 'contents: the time budget ends the search with the partial note', json.dumps(h))
    page.cmd('@searchlimits:' + json.dumps({'maxFiles': 2}))
    typed('quokka')
    h = settle()
    check(h['status'].endswith(' · first 2 searched'), 'contents: the file cap says how many were searched', h['status'])
    page.cmd('@searchlimits:')

    # Esc clears the query and stops the search.
    typed('quokka')
    settle()
    esc = page.cmd("@eval:(() => { const e = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }); document.getElementById('side-q').dispatchEvent(e); return 0; })()")
    h = page.js(HITS)
    check(any(x[0] == 'src' for x in h['rows']) and h['status'] == '' and page.js("return document.getElementById('side-q').value") == ''
          and 'searchStop' in types_of(esc), 'contents: Esc clears the query, stops the search, and the tree comes back', json.dumps([h, types_of(esc)]))

    # The mode is kept for the session, across previews; back on Names, the filter matches names only.
    page.cmd('@root:')
    page.render(D('src/app.ts'))
    page.cmd('@wait:0.3')
    check(page.js(HITS)['mode'] == 'Contents', 'contents: the mode is kept for the session, in the next preview too', json.dumps(page.js(HITS)))
    typed('quokka')
    settle()
    r = click(page, '#side-mode [data-mode=names]')
    page.cmd('@wait:0.3')
    h = page.js(HITS)
    check(h['mode'] == 'Names' and h['placeholder'] == 'Filter' and 'searchStop' in types_of(r) and h['rows'] == [],
          'contents: back to Names, the search stops and the filter matches names only', json.dumps([h, types_of(r)]))
    typed('')

    # At the narrowest sidebar nothing in the search controls is cut: the field, the toggle level with it, and the longest
    # progress line, which wraps.
    FIT = """const s = document.getElementById('sidebar').getBoundingClientRect(), cut = [];
      for (const e of document.querySelectorAll('#side-q, #side-menu, #side-mode, #side-mode button, #side-more:not([hidden]), #side-list a.row.hit .hit-n')) {
        const r = e.getBoundingClientRect();
        if (r.left < s.left - 0.5 || r.right > s.right + 0.5 || e.scrollWidth > e.clientWidth + 0.5) cut.push([e.id || e.className, r.left, r.right, e.scrollWidth, e.clientWidth]);
      }
      const m = document.getElementById('side-mode').getBoundingClientRect(), b = document.getElementById('side-menu').getBoundingClientRect();
      return { width: s.width, cut, level: [m.left - document.getElementById('side-q').getBoundingClientRect().left, m.right - b.right],
        more: document.getElementById('side-more').hidden ? '' : document.getElementById('side-more').textContent };"""
    page.apply(sidebarWidth=160)
    page.cmd('@wait:0.4')
    fits = []
    for mode in ('names', 'contents'):
        click(page, f'#side-mode [data-mode={mode}]')
        typed('quokka')
        settle()
        if mode == 'contents':
            page.cmd('@eval:hits = { ...hits, done: false, total: 123456, searched: 98765, version: hits.version + 1 }; renderSidebar(); 0')
        fits.append(page.js(FIT))
    check(all(f['width'] == 160 and not f['cut'] and f['level'] == [0, 0] for f in fits) and fits[1]['more'].startswith('Searching… 98,765 of 123,456'),
          'contents: at the narrowest sidebar the field, the toggle, the counts and the progress line all fit', json.dumps(fits))
    typed('')
    click(page, '#side-mode [data-mode=names]')
    page.apply(sidebarWidth=240)

def make_viewers(out):
    """Files for the viewers: a large and a small image, CSVs with other delimiters and past the row cap, nested and large JSON, a
    notebook, and one file of each kind with an icon of its own."""
    d = os.path.join(out, 'viewers')
    os.makedirs(d)
    put = lambda n, data: open(os.path.join(d, n), 'wb' if isinstance(data, bytes) else 'w').write(data)
    put('big.png', make_png(2400, 1600, (40, 120, 200)))
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(d, 'small.png'))
    put('prices.csv', 'name;price;qty\nApfel;1,50;3\nBirne;0,99;10\nFeige;12,25;1\n')
    put('pipes.csv', 'a|b|c\n1|2|3\n4|5|6\n')
    put('sort.csv', 'item,n,when\nb,10,x\na,9,y\nc,,z\nd,100,w\ne,9,v\n')
    put('rows.csv', 'i,square,label\n' + ''.join(f'{i},{i * i},row {i}\n' for i in range(60000)))
    # Short values at the top and long ones at the bottom: widths taken from the rows drawn would change on the way down.
    put('grow.csv', 'id,name,note\n' + ''.join(f'{i},{"n" * (2 + i // 1000)},{"x" * (40 - i // 600)}\n' for i in range(20000)))
    put('ragged.csv', 'a,b\n' + ''.join('1,2\n' for _ in range(1499)) + '1,2,late\n')
    os.makedirs(os.path.join(d, 'Tool.app', 'Contents'))
    put('nested.json', json.dumps({'items': list(range(1200)), 'deep': {'a': {'b': {'c': {'d': [1, {'e': 'end'}]}}}},
                                   'text': '<img src=x onerror="window.__pwned=1">', 'flags': [True, False, None]}))
    put('large.json', '[' + ','.join(['{"k": "' + 'v' * 90 + '"}'] * 22000) + ']')
    png = base64.b64encode(make_png(40, 30, (20, 160, 90))).decode()
    put('analysis.ipynb', json.dumps({'nbformat': 4, 'nbformat_minor': 5,
        'metadata': {'kernelspec': {'language': 'python', 'name': 'python3'}},
        'cells': [
            {'cell_type': 'markdown', 'metadata': {}, 'source': ['# Notebook title\n', '\n', 'Some *text* and $x^2$.\n', '\n', '- [ ] a task\n', '\n',
                                                                  '<img src=x onerror="window.__pwned=1"> <script>window.__pwned=1</script>\n', '\n',
                                                                  '<span class="nb-bait" data-action="reveal">Next</span>\n']},
            {'cell_type': 'code', 'execution_count': 1, 'metadata': {}, 'source': ['def f(x):\n', '    return x * 2\n', 'print(f(21))'],
             'outputs': [{'output_type': 'stream', 'name': 'stdout', 'text': ['42\n']}]},
            {'cell_type': 'code', 'execution_count': 2, 'metadata': {}, 'source': ['f(1)'],
             'outputs': [{'output_type': 'execute_result', 'execution_count': 2, 'metadata': {}, 'data': {'text/plain': ['2'], 'text/html': ['<b onclick="x">2</b>']}}]},
            {'cell_type': 'code', 'execution_count': 3, 'metadata': {}, 'source': ['plot()'],
             'outputs': [{'output_type': 'display_data', 'metadata': {}, 'data': {'image/png': png, 'text/plain': ['<Figure>']}},
                         {'output_type': 'display_data', 'metadata': {}, 'data': {'image/png': 'not base64 "><script>'}}]},
            {'cell_type': 'code', 'execution_count': 4, 'metadata': {}, 'source': ['1/0'],
             'outputs': [{'output_type': 'error', 'ename': 'ZeroDivisionError', 'evalue': 'division by zero',
                          'traceback': ['\u001b[0;31mZeroDivisionError\u001b[0m: division by zero']}]},
            {'cell_type': 'code', 'execution_count': None, 'metadata': {}, 'source': ['display(HTML("x"))'],
             'outputs': [{'output_type': 'display_data', 'metadata': {}, 'data': {'text/html': ['<iframe src="https://example.com"></iframe>']}}]},
        ]}))
    for n in ('font.ttf', 'report.docx', 'budget.xlsx', 'deck.pptx', 'model.usdz', 'bundle.zip', 'clip.mkv', 'tune.ogg'):
        put(n, b'\0\1\2\3' * 64)
    return d


def viewers(page, check, out, st):
    """The upgraded viewers: image zoom and pan, the CSV table, the JSON tree, notebooks, the Aa popover per view, and the
    sidebar's tooltips, icons and menu."""
    d = make_viewers(out)
    V = lambda n: os.path.join(d, n)

    def view(name):
        page.cmd('@root:' + d)
        r = page.render(V(name))
        page.cmd('@wait:0.3')
        return r
    page.cmd('@size:1200x800')
    page.apply(sidebarCollapsed=False, width='medium')

    # ---- the sidebar: an icon for each kind, a tooltip with size and date, and the sort menu ----
    view('big.png')
    rows = {r[0]: r[3] for r in st()['rows']}
    want = {'font.ttf': 'ic-font', 'report.docx': 'ic-doc', 'budget.xlsx': 'ic-sheet', 'deck.pptx': 'ic-slides', 'model.usdz': 'ic-model',
            'bundle.zip': 'ic-archive', 'clip.mkv': 'ic-video', 'tune.ogg': 'ic-audio', 'big.png': 'ic-image', 'analysis.ipynb': 'ic-data'}
    check(all(rows.get(k) == v for k, v in want.items()), 'sidebar: archives, fonts, documents, spreadsheets, slides, 3D, video and audio have icons of their own',
          json.dumps({k: rows.get(k) for k in want}))
    tip = page.js("return document.querySelector('#side-list a.row[data-path$=\"/font.ttf\"]').title")
    check(tip.startswith('font.ttf\n256 bytes · Modified '), 'sidebar: a row\'s tooltip gives its size and when it was modified', json.dumps(tip))
    tip = page.js("return document.querySelector('#side-list a.row[data-path$=\"/Tool.app\"]').title")
    check(tip.startswith('Tool.app\nModified ') and 'byte' not in tip, 'sidebar: a package\'s tooltip gives no size', json.dumps(tip))
    click(page, '#side-menu')
    menu = page.js("""const p = document.getElementById('side-pop'); return { open: !p.hidden, items: [...p.querySelectorAll('button')].map((b) => [b.textContent, b.getAttribute('aria-checked')]),
      expanded: document.getElementById('side-menu').getAttribute('aria-expanded'), inside: p.getBoundingClientRect().right <= document.getElementById('sidebar').getBoundingClientRect().right + 1 }""")
    check(menu == {'open': True, 'items': [['Sort by Name', 'true'], ['Sort by Date Modified', 'false'], ['Show Hidden Files…', 'false']], 'expanded': 'true', 'inside': True},
          'sidebar menu: sort order checked, hidden files shown as off', json.dumps(menu))
    shoot(page, 'sidebar-menu')
    keys = dispatch_key(page, 'ArrowDown')
    check(keys['result'] == 'false', 'sidebar menu: the tree keys wait while it is open')
    r = click(page, '#side-pop [data-sort=modified]')
    written = [m.get('patch') for m in r['messages'] if m.get('type') == '_written']
    check(written == ['{"folderSort":"modified"}'] and page.js("return document.getElementById('side-pop').hidden")
          and page.js("return document.querySelector('#side-pop [data-sort=modified]').getAttribute('aria-checked')") == 'true',
          'sidebar menu: Sort by Date Modified saves folderSort through the panel gate', json.dumps(written))
    r = click(page, '#side-pop [data-sort=name]')
    click(page, '#side-menu')
    r = click(page, '#side-hidden')
    o = [m for m in r['messages'] if m.get('type') == 'openSettings']
    check(len(o) == 1 and o[0].get('tab') == 'folders' and not [m for m in r['messages'] if m.get('type') == 'setting'],
          'sidebar menu: Show Hidden Files opens Settings › Advanced; the page never changes it', json.dumps(o))
    r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({type: 'setting', key: 'showHiddenFiles', value: true}); 0")
    page.cmd('@wait:0.2')
    check('_settingRefused' in [m.get('type') for m in r['messages'] + page.cmd('@eval:0')['messages']], 'showHiddenFiles from the page is refused by the gate')

    # ---- the image viewer ----
    ZOOM = """const s = document.querySelector('#doc .img-stage'), i = s.querySelector('img'), r = i.getBoundingClientRect();
      return { zoomed: s.classList.contains('zoomed'), label: document.querySelector('#kind .img-zoom').textContent, w: Math.round(r.width),
        left: Math.round(s.scrollLeft), top: Math.round(s.scrollTop), cap: document.getElementById('kind').textContent, aa: document.getElementById('aa').hidden,
        fits: r.width <= document.getElementById('doc').clientWidth + 1 && r.height <= innerHeight,
        head: getComputedStyle(document.querySelector('#doc .viewer-head')).display, inDoc: !!document.querySelector('#doc .viewer-kind, #doc .img-zoom') };"""
    AT = """(dx, dy, detail) => { const s = document.querySelector('#doc .img-stage'), r = s.querySelector('img').getBoundingClientRect();
      const x = r.left + r.width * dx, y = r.top + r.height * dy;
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].concat(detail === 2 ? ['dblclick'] : [])) {
        const E = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        s.querySelector('img').dispatchEvent(new E(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, detail, button: 0, isPrimary: true }));
      }
      return 0; }"""
    def at(dx, dy, detail=1):
        page.cmd(f'@eval:({AT})({dx}, {dy}, {detail})')
        page.cmd('@wait:0.35')
    dbl = lambda dx, dy: (at(dx, dy, 1), at(dx, dy, 2))
    view('big.png')
    page.cmd('@wait:0.3')
    z = page.js(ZOOM)
    check(not z['zoomed'] and z['fits'] and z['label'].endswith('%') and int(z['label'][:-1]) < 100 and z['cap'].startswith('PNG image · 2400 × 1600 · ')
          and z['cap'].endswith(z['label']) and z['aa'] and z['head'] == 'none' and not z['inDoc'],
          'image: fitted to the panel; its kind, size and zoom are quiet text in the toolbar, with no caption row over it; no Aa popover', json.dumps(z))
    fit_label = z['label']
    shoot(page, 'image-fit')
    at(0.75, 0.5)
    z = page.js(ZOOM)
    check(not z['zoomed'] and z['label'] == fit_label, 'image: a single click leaves the zoom alone', json.dumps(z))
    dbl(0.75, 0.5)
    z = page.js(ZOOM)
    check(z['zoomed'] and z['label'] == '100%' and z['w'] == 2400 and z['left'] > 0, 'image: a double-click zooms to actual size about the point, once', json.dumps(z))
    shoot(page, 'image-100')
    before = z['left']
    page.cmd('@nativedrag:#doc .img-stage,-150')
    z = page.js(ZOOM)
    check(z['zoomed'] and z['left'] >= before + 100, 'image: a drag moves the zoomed image and does not zoom back out', json.dumps([before, z]))
    dbl(0.5, 0.5)
    z = page.js(ZOOM)
    check(not z['zoomed'] and z['fits'], 'image: another double-click fits it again', json.dumps(z))
    page.cmd("""@eval:(() => { const s = document.querySelector('#doc .img-stage'), r = s.getBoundingClientRect();
      s.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, ctrlKey: true, deltaY: -40, clientX: r.left + 50, clientY: r.top + 50 })); return 0; })()""")
    z = page.js(ZOOM)
    fitted = page.js("return Math.round(document.querySelector('#doc .img-stage img').naturalWidth)")
    check(z['zoomed'] and 100 > int(z['label'][:-1]) > 0 and z['w'] < fitted, 'image: a wheel with ctrl zooms by steps', json.dumps(z))
    dispatch_key(page, '=', metaKey=True)
    page.cmd('@wait:0.35')
    z2 = page.js(ZOOM)
    dispatch_key(page, '0', metaKey=True)
    page.cmd('@wait:0.35')
    z3 = page.js(ZOOM)
    check(z2['w'] > z['w'] and not z3['zoomed'], 'image: ⌘+ zooms in and ⌘0 fits', json.dumps([z['w'], z2['w'], z3['zoomed']]))
    dispatch_key(page, '=', metaKey=True)
    dispatch_key(page, '=', metaKey=True)
    page.cmd('@wait:0.35')
    z4 = page.js(ZOOM)
    want = round(int(fit_label[:-1]) * 1.5625)
    check(z4['zoomed'] and abs(int(z4['label'][:-1]) - want) <= 2, 'image: ⌘+ twice during the animation steps twice (1.25²)', json.dumps([fit_label, z4['label']]))
    dispatch_key(page, '0', metaKey=True)
    page.cmd('@wait:0.35')

    # The trackpad and the mouse as real input arrives (NSApp.sendEvent), in a window that is not key of an app that is not
    # active, as in the Space viewer.
    fit_pct = int(fit_label[:-1])
    page.cmd('@nativepinch:#doc .img-stage,0.1')
    z = page.js(ZOOM)
    pinched = int(z['label'][:-1]) if z['label'] else 0
    check(z['zoomed'] and abs(pinched - fit_pct * 1.1 ** 5) <= fit_pct * 0.12, 'image: a trackpad pinch zooms by the pinch alone (WebKit\'s ctrl wheels beside it ignored)',
          json.dumps([fit_label, z['label']]))
    top = z['top']
    page.cmd('@nativescroll:#doc .img-stage,0,-200')
    z = page.js(ZOOM)
    check(z['zoomed'] and z['top'] > top + 50, 'image: two fingers move a zoomed image', json.dumps([top, z]))
    page.cmd('@nativesmart:#doc .img-stage')
    page.cmd('@wait:0.3')
    z = page.js(ZOOM)
    check(not z['zoomed'] and z['label'] == fit_label, 'image: a two-finger double tap on a zoomed image fits it', json.dumps(z))
    page.cmd('@nativesmart:#doc .img-stage')
    page.cmd('@wait:0.3')
    z = page.js(ZOOM)
    check(z['zoomed'] and z['label'] == '100%', 'image: a two-finger double tap on a fitted image zooms to 100%', json.dumps(z))
    page.cmd('@nativedblclick:#doc .img-stage')
    page.cmd('@wait:0.3')
    z = page.js(ZOOM)
    check(not z['zoomed'] and z['label'] == fit_label, 'image: a double-click through the window fits it', json.dumps(z))

    view('small.png')
    page.cmd('@wait:0.3')
    dbl(0.5, 0.5)
    z = page.js(ZOOM)
    check(z['zoomed'] and z['label'] == '200%' and z['w'] == 320, 'image: a small image, already at 100%, zooms to 200%', json.dumps(z))
    rm = page.js("""const out = []; for (const sh of document.styleSheets) { let rules; try { rules = sh.cssRules; } catch (e) { continue; }
        const walk = (list) => { for (const r of list) { if (r.cssRules) walk(r.cssRules); if (/img-stage/.test(r.selectorText || '') && /transition|animation/.test(r.cssText)) out.push(r.cssText); } };
        walk(rules); } return out""")
    check(rm == [], 'image: no CSS transition on the image (its zoom animation is scripted, and off for reduced motion)', json.dumps(rm))

    # ---- the Aa popover per view, and the update's own button ----
    AA = """const p = document.getElementById('aa-pop'), vis = (id) => { const e = document.getElementById(id); return !!e && !e.hidden && getComputedStyle(e).display !== 'none'; };
      return { aa: vis('aa'), upd: vis('upd'), open: !p.hidden, mode: p.dataset.mode || null,
        parts: ['aa-update', 'aa-themes', 'aa-width', 'aa-font', 'aa-settings'].filter((id) => !p.hidden && vis(id) && document.getElementById(id).getBoundingClientRect().height > 0) };"""
    got = {}
    for name, v in (('sort.csv', 'csv'), ('nested.json', 'json'), ('font.ttf', 'info'), ('big.png', 'image')):
        view(name)
        a = page.js(AA)
        if a['aa']:
            click(page, '#aa')
            a = page.js(AA)
            click(page, '#aa')
        got[v] = a
    page.cmd('@root:')
    page.render(os.path.join(ROOT, 'test', 'fixtures', 'demo.md'))
    click(page, '#aa')
    got['markdown'] = page.js(AA)
    click(page, '#aa')
    check(got['markdown']['parts'] == ['aa-themes', 'aa-width', 'aa-font', 'aa-settings'] and got['csv']['parts'] == ['aa-themes', 'aa-settings']
          and got['json']['parts'] == ['aa-themes', 'aa-settings'] and not got['info']['aa'] and not got['image']['aa'],
          'Aa: every option for Markdown; text size and theme for CSV, JSON and code; none for an image or an info card', json.dumps(got))
    BAR = """const r = (id) => document.getElementById(id).getBoundingClientRect();
      return [r('toolbar').left, r('toolbar').width, r('kind').left, r('edit').left].map(Math.round)"""
    view('big.png')
    bar0 = page.js(BAR)
    page.cmd('@root:')
    page.render(os.path.join(ROOT, 'test', 'fixtures', 'demo.md'))
    page.cmd("@eval:sb.update({ state: 'available', version: '9.9.9' }); 0")
    md = page.js(AA)
    view('big.png')
    a = page.js(AA)
    bar1 = page.js(BAR)
    check(bar0 == bar1, 'an update on an image takes the empty Raw, Find and Aa slots: nothing in the toolbar moves', json.dumps([bar0, bar1]))
    click(page, '#upd')
    b = page.js(AA)
    shoot(page, 'update-button')
    click(page, '#upd')
    view('sort.csv')
    c = page.js(AA)
    check(md['aa'] and md['upd'] and a['upd'] and not a['aa'] and b['open'] and b['mode'] == 'update' and b['parts'] == ['aa-update'] and c['aa'] and c['upd'],
          'an update: always a button of its own, beside Aa or in its place, that opens the update row alone', json.dumps([md, a, b, c]))
    page.cmd('@eval:sb.updateReset(); 0')
    check(not page.js(AA)['upd'], 'no update: no update button')

    # ---- CSV ----
    CSV = """const t = document.querySelector('#doc table.csv'); return { head: [...t.querySelectorAll('thead th')].map((x) => x.textContent),
      rows: [...t.querySelectorAll('tbody tr:not(.pad)')].slice(0, 6).map((r) => [...r.cells].map((c) => c.textContent)),
      align: [...t.querySelectorAll('tbody tr:not(.pad):first-child > *')].map((c) => getComputedStyle(c).textAlign),
      sort: [...t.querySelectorAll('thead th')].map((x) => x.getAttribute('aria-sort')), kind: document.getElementById('kind').textContent,
      notes: [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent) };"""
    view('prices.csv')
    c = page.js(CSV)
    check(c['head'] == ['', 'name', 'price', 'qty'] and c['rows'][0] == ['1', 'Apfel', '1,50', '3'] and c['align'] == ['right', 'left', 'right', 'right']
          and c['kind'].startswith('CSV (semicolon) · 3 rows × 3 columns · '),
          'CSV: semicolons found, numbers (decimal commas too) right-aligned, row numbers', json.dumps(c))
    shoot(page, 'csv-semicolon')
    view('pipes.csv')
    c = page.js(CSV)
    check(c['head'] == ['', 'a', 'b', 'c'] and c['rows'] == [['1', '1', '2', '3'], ['2', '4', '5', '6']] and c['kind'].startswith('CSV (pipe) · '), 'CSV: pipes found', json.dumps(c))
    view('sort.csv')
    click(page, '#doc .csv-sort[data-col="1"]')
    asc = page.js(CSV)
    click(page, '#doc .csv-sort[data-col="1"]')
    desc = page.js(CSV)
    click(page, '#doc .csv-sort[data-col="1"]')
    orig = page.js(CSV)
    click(page, '#doc .csv-sort[data-col="0"]')
    by_name = page.js(CSV)
    shoot(page, 'csv-sorted')
    col = lambda c, i: [r[i] for r in c['rows']]
    check(col(asc, 1) == ['a', 'e', 'b', 'd', 'c'] and col(asc, 0) == ['2', '5', '1', '4', '3'] and asc['sort'][2] == 'ascending'
          and col(desc, 1) == ['d', 'b', 'a', 'e', 'c'] and desc['sort'][2] == 'descending'
          and col(orig, 1) == ['b', 'a', 'c', 'd', 'e'] and orig['sort'][2] == 'none' and col(by_name, 1) == ['a', 'b', 'c', 'd', 'e'],
          'CSV: a header click sorts ascending, then descending, then back; numbers as numbers, stable, blanks last', json.dumps([col(asc, 1), col(desc, 1), col(orig, 1), col(by_name, 1)]))
    view('rows.csv')
    page.cmd('@wait:0.3')
    v = page.js("""const s = document.querySelector('#doc .csv-scroll'), t = s.querySelector('table'); s.scrollTop = 30000 * 26; s.dispatchEvent(new Event('scroll'));
      return 0;""")
    page.cmd('@wait:0.3')
    v = page.js("""const s = document.querySelector('#doc .csv-scroll'), t = s.querySelector('table'), th = t.querySelector('thead th:nth-child(2)'), sr = s.getBoundingClientRect();
      const rows = [...t.querySelectorAll('tbody tr:not(.pad)')];
      return { drawn: rows.length, sticky: Math.abs(th.getBoundingClientRect().top - sr.top) <= 2, first: rows.length ? +rows[0].cells[0].textContent : 0,
        notes: [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent), count: t.getAttribute('aria-rowcount'), full: t.getBoundingClientRect().width >= s.clientWidth - 1,
        seen: rows.some((r) => { const b = r.getBoundingClientRect(); return b.top >= sr.top && b.bottom <= sr.bottom; }) };""")
    check(v['drawn'] < 200 and v['sticky'] and 25000 < v['first'] < 32000 and v['seen'] and v['notes'] == ['Showing the first 50,000 of 60,000 rows.'] and v['count'] == '50001' and v['full'],
          'CSV: 50,000 rows kept, drawn a window at a time; the header stays at the top while they scroll; the table is full width', json.dumps(v))
    shoot(page, 'csv-large')
    WIDTHS = """const t = document.querySelector('#doc table.csv'); return [...t.querySelectorAll('thead th')].map((x) => Math.round(x.getBoundingClientRect().width));"""
    SCROLL = """const s = document.querySelector('#doc .csv-scroll'); return [Math.round(s.scrollTop), +((s.querySelector('tbody tr:not(.pad)') || { cells: [{ textContent: 0 }] }).cells[0].textContent)];"""
    view('grow.csv')
    top_w = page.js(WIDTHS)
    page.js("const s = document.querySelector('#doc .csv-scroll'); s.scrollTop = s.scrollHeight; s.dispatchEvent(new Event('scroll')); return 0")
    page.cmd('@wait:0.3')
    bottom_w = page.js(WIDTHS)
    check(top_w == bottom_w and len(top_w) == 4, 'CSV: a windowed table keeps its column widths from top to bottom', json.dumps([top_w, bottom_w]))
    page.js("const s = document.querySelector('#doc .csv-scroll'); s.scrollTop = 5000; s.dispatchEvent(new Event('scroll')); return 0")
    page.cmd('@wait:0.3')
    at = page.js(SCROLL)
    kept = {}
    page.apply(fontSize=16)
    page.cmd('@wait:0.3')
    kept['text size'] = page.js(SCROLL)
    page.apply(fontSize=15, theme='nord')
    page.cmd('@wait:0.3')
    kept['theme'] = page.js(SCROLL)
    page.apply(theme='apple')
    page.render(V('grow.csv'))
    page.cmd('@wait:0.3')
    kept['reload'] = page.js(SCROLL)
    click(page, '#doc .csv-sort[data-col="0"]')
    page.cmd('@wait:0.3')
    kept['sort'] = page.js(SCROLL)
    click(page, '#doc .csv-sort[data-col="0"]')
    click(page, '#doc .csv-sort[data-col="0"]')
    check(at[0] == 5000 and all(abs(v[0] - 5000) <= 2 for v in kept.values()) and abs(kept['reload'][1] - at[1]) <= 1,
          'CSV: where it was scrolled to survives a text size, a theme, a reload and a sort', json.dumps([at, kept]))
    view('ragged.csv')
    rg = page.js("return [document.querySelectorAll('#doc table.csv thead th').length, document.getElementById('kind').textContent]")
    check(rg[0] == 4 and '3 columns' in rg[1], 'CSV: a longer row far down widens the table instead of losing its cell', json.dumps(rg))

    # ---- JSON ----
    TREE = """return { rows: [...document.querySelectorAll('#doc .json-tree .jt-row')].map((r) => r.textContent), more: [...document.querySelectorAll('#doc .jt-more-b')].map((b) => b.textContent),
      imgs: document.querySelectorAll('#doc img, #doc script').length, role: (document.querySelector('#doc .json-tree') || {}).getAttribute && document.querySelector('#doc .json-tree').getAttribute('role'),
      expanded: [...document.querySelectorAll('#doc .jt-row[aria-expanded]')].map((r) => r.getAttribute('aria-expanded')) };"""
    view('nested.json')
    t = page.js(TREE)
    check(t['rows'][:2] == ['▾{ 4 keys }', '▸"items": [ 1,200 items ]'] and '▸"deep": { 1 key }' in t['rows'] and '"text": "<img src=x onerror=\\"window.__pwned=1\\">"' in t['rows']
          and t['imgs'] == 0 and t['role'] == 'tree', 'JSON tree: key counts, a large array left closed, strings as text', json.dumps(t)[:400])
    click(page, '#doc .jt-tw[data-ptr="/items"]')
    t = page.js(TREE)
    check(len([r for r in t['rows'] if r[:1].isdigit()]) == 500 and t['more'] == ['Show 500 more (700 not shown)'], 'JSON tree: a large array opens 500 items at a time', json.dumps(t['more']))
    click(page, '#doc .jt-more-b')
    t = page.js(TREE)
    check(len([r for r in t['rows'] if r[:1].isdigit()]) == 1000 and t['more'] == ['Show 200 more (200 not shown)'], 'JSON tree: Show more adds the next 500', json.dumps(t['more']))
    click(page, '#doc .json-all[data-open="0"]')
    t = page.js(TREE)
    check(t['rows'] == ['▸{ 4 keys }'], 'JSON tree: Collapse All', json.dumps(t['rows']))
    click(page, '#doc .json-all[data-open="1"]')
    t = page.js(TREE)
    check('"e": "end"' in t['rows'] and 'false' not in t['expanded'][:1], 'JSON tree: Expand All opens every level', json.dumps(t['rows'][-8:]))
    ctl = page.js("return [[...document.querySelectorAll('#doc .viewer-head button:not(.viewer-open)')].map((b) => b.textContent), document.querySelectorAll('#doc .viewer-toggle, #doc .viewer-seg').length, document.getElementById('kind').textContent]")
    check(ctl[0] == ['Expand All', 'Collapse All'] and ctl[1] == 0 and ctl[2].startswith('JSON · '),
          'JSON: the tree is the one view, with only Expand All and Collapse All over it; Raw, in the toolbar, is its text', json.dumps(ctl))
    shoot(page, 'json-tree')
    view('large.json')
    lj = page.js("return [!!document.querySelector('#doc .json-tree'), !!document.querySelector('#doc pre.code'), [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
    check(lj[0] is True and not lj[1] and lj[2] == [], 'JSON over 2 MB (within 16 MB): parsed whole, shown as its tree', json.dumps(lj))
    view('analysis.ipynb')
    nb = page.js("""const d = document.getElementById('doc'); return { h1: (d.querySelector('.nb-md h1') || {}).textContent, katex: d.querySelectorAll('.nb-md .katex').length,
      task: (() => { const i = d.querySelector('.nb-md input[type=checkbox]'); return i ? [i.disabled, i.hasAttribute('data-line')] : null; })(),
      prompts: [...d.querySelectorAll('.nb-prompt')].map((p) => p.textContent), kw: d.querySelectorAll('.nb-code .hljs-keyword').length,
      outs: [...d.querySelectorAll('.nb-out')].map((o) => o.textContent), imgs: [...d.querySelectorAll('.nb-img')].map((i) => [i.src.slice(0, 22), i.naturalWidth]),
      bad: d.querySelectorAll('script, iframe, [onclick], [onerror], b').length, notes: [...d.querySelectorAll('.nb-note')].map((n) => n.textContent),
      modes: d.querySelectorAll('.viewer-toggle, .json-all').length, src: d.querySelectorAll('.nb-md [data-src]').length };""")
    check(nb['h1'] == 'Notebook title' and nb['katex'] >= 1 and nb['task'] == [True, False] and nb['prompts'] == ['[1]:', '[2]:', '[3]:', '[4]:', '[ ]:'] and nb['kw'] > 0
          and nb['outs'] == ['42\n', '2', 'ZeroDivisionError: division by zero'] and nb['imgs'] == [['data:image/png;base64,', 40]]
          and nb['bad'] == 0 and nb['notes'] == ['HTML output is not shown.'] and nb['src'] == 0
          and nb['modes'] == 0 and not page.js('return window.__pwned || null'),
          'notebook: Markdown cells rendered and sanitized, code highlighted, text and image outputs, errors without ANSI codes, no HTML output',
          json.dumps(nb)[:600])
    shoot(page, 'notebook')
    r = click(page, '#doc .nb-md h1')
    check('editBlock' not in [m.get('type') for m in r['messages']], 'notebook: a click in a Markdown cell edits nothing')
    r = page.cmd('@nativeclick:#doc .nb-bait')
    check(page.js("return !!document.querySelector('#doc .nb-bait')") and not [m for m in r['messages'] if m.get('type') in ('reveal', 'openFile', '_reveal', '_openFile')],
          "notebook: a Markdown cell's data-action markup reveals and opens nothing")
    page.cmd('@root:')


def find_typed(page, check, out):
    """Find as the query is typed a key at a time, as the writer sends it, in rendered Markdown, code, a table, a JSON tree and a
    text file large enough that the search waits for the typing to pause: only the last query's matches are highlighted, in the
    registry and as painted in the window (WebKit leaves the ranges of a Highlight the registry drops painted), whether each key
    is searched or the keys come faster than the search; after Backspace, an emptied field and closing the bar too."""
    d = os.path.join(out, 'typed')
    os.makedirs(d)
    files = {'typed.md': '# Title\n\nThe word is here.\n\nA wolf alone.\n\nWalk west.\n', 'typed.ts': 'const word = 1;\n// a wolf\n// walk west\n',
             'typed.csv': 'a,b\nword,wolf\nwalk,west\n', 'typed.json': json.dumps({'word': 'wolf', 'walk': 'west'}),
             'typed.txt': 'The word is here.\nA wolf alone.\nWalk west.\n' + 'filler line\n' * 25000}
    for n, t in files.items():
        open(os.path.join(d, n), 'w').write(t)
    MARKS = """const q = %s.toLowerCase(), c = CSS.highlights, rs = ['sb-find', 'sb-find-cur'].flatMap((k) => (c.get(k) ? [...c.get(k)] : []));
      return [rs.length, rs.map((r) => r.toString()).filter((t) => t.toLowerCase() !== q), document.getElementById('find-count').textContent];"""
    # Where the first two letters of each word's first appearance are now (a step scrolls the match into view), inset from the line box.
    SPOTS = """const out = {}, w = document.createTreeWalker(document.getElementById('doc'), NodeFilter.SHOW_TEXT);
      for (let n; (n = w.nextNode());) for (const m of n.data.matchAll(/\\b(word|wolf|walk|west)/gi)) {
        const k = m[1].toLowerCase(), r = document.createRange();
        if (out[k]) continue;
        r.setStart(n, m.index);
        r.setEnd(n, m.index + 2);
        const rs = r.getClientRects(), b = rs[rs.length - 1];
        out[k] = [b.left + 1, b.top + 2, b.width - 2, b.height - 4].map(Math.round).join(',');
      }
      return out;"""
    seq = [0]

    def send(*texts, wait=0.3):
        page.cmd('@eval:' + ' '.join('sb.filterText(' + json.dumps({'seq': seq[0], 'text': t}) + ');' for t in texts) + ' 0')
        page.cmd(f'@wait:{wait}')

    def yellow(spot):
        rgb = page.cmd('@winmean:' + spot)['result']
        return rgb[0] - rgb[2] if len(rgb) == 3 else float('nan')

    for name in files:
        page.cmd('@root:' + d)
        page.render(os.path.join(d, name))
        page.cmd('@wait:0.4')
        fb = [m for m in page.cmd('@nativeclick:#find-btn')['messages'] if m.get('type') == 'filterBegin']
        seq[0] = int(fb[0]['seq']) if fb else -1
        # The bar opens on the last file's query.
        send('')
        spots = page.js(SPOTS)
        base = {k: yellow(v) for k, v in spots.items()}
        painted = lambda: sorted(k for k, v in page.js(SPOTS).items() if not yellow(v) - base[k] <= 30)
        marks = lambda q: page.js(MARKS % json.dumps(q))
        got = []
        for q in ('w', 'wo', 'wor', 'word'):
            send(q)
        got.append([marks('word'), painted()])
        send('wor', 'wo')
        got.append([marks('wo'), painted()])
        send('')
        got.append([marks(''), painted()])
        send('w', 'wo', 'wor', 'word', wait=0.5)
        got.append([marks('word'), painted()])
        page.cmd('@eval:sb.filterEnd(' + json.dumps({'seq': seq[0], 'reason': 'escape'}) + '); 0')
        page.cmd('@wait:0.3')
        got.append([marks('')[0], page.js("return document.getElementById('find').hidden"), painted()])
        check(sorted(spots) == ['walk', 'west', 'wolf', 'word'] and got == [
            [[1, [], '1 of 1'], ['word']], [[2, [], '1 of 2'], ['wolf', 'word']], [[0, [], ''], []], [[1, [], '1 of 1'], ['word']], [0, True, []]],
              f'find typed a key at a time in {name}: only the last query is highlighted and painted, typed slowly or fast, after ⌫, emptied and closed',
              json.dumps([spots, got]))


def make_tools(out):
    """Files for the toolbar's tools: Markdown, JSON with matches deep in the tree and past a chunk, a notebook, a long table, a
    2 MB script, a property list, a minified and a plain stylesheet, TypeScript and an image."""
    d = os.path.join(out, 'tools')
    os.makedirs(d)
    put = lambda n, data: open(os.path.join(d, n), 'wb' if isinstance(data, bytes) else 'w').write(data)
    put('notes.md', '# Needle notes\n\nA needle, a NEEDLE and a haystack.\n\n```js\nconst needle = 1;\n```\n\n- [ ] find the needle\n')
    put('tree.json', json.dumps({'items': [{'k': 'x'}] * 900 + [{'k': 'needle'}], 'deep': {'a': {'b': {'c': {'needle': 1}}}}, 'flat': 'hay'}))
    put('cells.ipynb', json.dumps({'nbformat': 4, 'nbformat_minor': 5, 'metadata': {}, 'cells': [
        {'cell_type': 'markdown', 'metadata': {}, 'source': ['# Needle cell\n']},
        {'cell_type': 'code', 'execution_count': 1, 'metadata': {}, 'source': ['needle = 1'], 'outputs': []}]}))
    put('rows.csv', 'n,word\n' + ''.join(f'{i},{"needle" if i % 1000 == 7 else "hay"}\n' for i in range(20000)))
    lines = [f'function f{i}(a) {{ return a + {i}; }} // {"needle " + str(i) if i % 2000 == 999 else "hay"}\n' for i in range(60000)]
    big = ''
    for l in lines:
        if len(big) + len(l) > 2 * 1000 * 1000:
            break
        big += l
    put('big.js', big)
    put('info.plist', '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Name</key><string>a &amp; b</string>'
                      '<key>List</key><array><integer>1</integer><integer>2</integer></array><!-- note --></dict></plist>')
    put('min.css', ('.a{color:red;background:url(data:image/png;base64,AA;BB)}.b>c,d:hover{margin:0 auto;content:"x;}{y"}'
                    '@media (max-width:10px){.e{top:0}}') * 40)
    put('plain.css', '.a {\n  color: red;\n}\n')
    put('code.ts', 'export const needle = 1;\n')
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(d, 'pic.png'))
    return d, big


def steady_chrome(page, check, out):
    """The toolbar holds still while the arrows move from file to file: every button keeps its place whatever the view, Open is
    one word with the app in its tooltip, the current row does not pulse, and the tooltips give the real keys. The Copy button
    never covers the document's last line or table row, it is announced to VoiceOver, and the toolbar buttons show a focus
    ring."""
    d = os.path.join(out, 'steady')
    os.makedirs(d)
    put = lambda n, data: open(os.path.join(d, n), 'wb' if isinstance(data, bytes) else 'w').write(data)
    put('notes.md', '# Notes\n\n' + ''.join(f'Paragraph {i} ' + 'word ' * 60 + '\n\n' for i in range(40)) + 'The last line.\n')
    put('code.ts', ''.join(f'export const v{i} = "{"x" * (400 if i % 7 == 0 else 20)}";\n' for i in range(300)))
    put('rows.csv', 'a,b,c,d,e,f\n' + ''.join(','.join(f'r{i}c{j} ' + 'wide ' * 6 for j in range(6)) + '\n' for i in range(200)))
    put('data.json', json.dumps({'k': list(range(50))}))
    put('large.csv', 'a,b\n' + ''.join(f'{i},' + 'x' * 60 + '\n' for i in range(40000)))
    put('tool', b'\0' + bytes(range(1, 256)) * 8)
    os.chmod(os.path.join(d, 'tool'), 0o755)
    shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(d, 'pic.png'))
    D = lambda n: os.path.join(d, n)

    def view(name):
        page.cmd('@root:' + d)
        page.render(D(name))
        page.cmd('@wait:0.3')

    PLACES = """const x = (id) => { const e = document.getElementById(id), r = e.getBoundingClientRect(), cs = getComputedStyle(e);
        return [Math.round(r.left), Math.round(r.width), cs.display !== 'none' && cs.visibility === 'visible'] };
      return { raw: x('raw'), find: x('find-btn'), aa: x('aa'), edit: x('edit'), label: document.getElementById('edit').textContent,
        title: document.getElementById('edit').title, stats: document.getElementById('kind').textContent + '|' + document.getElementById('stats').textContent };"""
    page.cmd('@size:1100x760')
    places = {}
    for n in ('notes.md', 'code.ts', 'rows.csv', 'data.json', 'pic.png', 'tool'):
        view(n)
        places[n] = page.js(PLACES)
    slots = {k: {tuple(p[k][:2]) for p in places.values()} for k in ('raw', 'find', 'aa', 'edit')}
    check(all(len(v) == 1 for v in slots.values()) and len({p['stats'] for p in places.values()}) > 2,
          'toolbar: Raw, Find, Aa and Open keep the same place and width on every file, whatever the kind and stats say', json.dumps(places))
    check([places[n]['find'][2] for n in ('notes.md', 'pic.png')] == [True, False] and [places[n]['raw'][2] for n in ('data.json', 'code.ts')] == [True, False],
          'toolbar: a tool that does not apply keeps its slot but is not shown', json.dumps({n: [p['raw'][2], p['find'][2]] for n, p in places.items()}))
    view('pic.png')
    hit = page.js("""const r = document.getElementById('find-btn').getBoundingClientRect(); const e = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return !!e && !!e.closest('#find-btn');""")
    check(hit is False, 'toolbar: a hidden tool in its slot takes no click')
    # Floating over the page (Minimal chrome, or a panel under 480px) the slots hold too, on every frame of the switches. There
    # Open is the viewer's own button for a file that is not Markdown, so the toolbar's keeps its slot empty.
    SLOTS = """const W = window.__slots = { f: [], stop: false }; const fr = () => { if (W.stop) return;
        W.f.push(['raw', 'find-btn', 'aa', 'edit'].map((id) => { const r = document.getElementById(id).getBoundingClientRect(); return [Math.round(r.left), Math.round(r.width)]; }));
        requestAnimationFrame(fr); }; requestAnimationFrame(fr); return 1;"""
    floating = {}
    for label, minimal, size in (('minimal', True, '1100x760'), ('narrow', False, '470x700'), ('minimal narrow', True, '470x700')):
        page.apply(minimalChrome=minimal)
        page.cmd('@size:' + size)
        view('notes.md')
        page.js(SLOTS)
        ps = {}
        for n in ('code.ts', 'rows.csv', 'pic.png', 'notes.md', 'data.json', 'tool'):
            view(n)
            ps[n] = page.js(PLACES)
        frames = page.js('window.__slots.stop = true; return window.__slots.f')
        view('pic.png')
        taken = page.js("""const r = document.getElementById('find-btn').getBoundingClientRect(); const e = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return !!e && !!e.closest('#find-btn');""")
        floating[label] = {'slots': {k: sorted({tuple(p[k][:2]) for p in ps.values()}) for k in ('raw', 'find', 'aa', 'edit')},
                           'frames': sorted({json.dumps(f) for f in frames}), 'open shown': {n: p['edit'][2] for n, p in ps.items()}, 'hidden takes a click': taken}
    page.apply(minimalChrome=False)
    page.cmd('@size:1100x760')
    check(all(all(len(v) == 1 for v in m['slots'].values()) and len(m['frames']) == 1 and not m['hidden takes a click']
              and m['open shown']['notes.md'] and not m['open shown']['code.ts'] for m in floating.values()),
          'toolbar: in Minimal chrome and under 480px too, Raw, Find, Aa and Open keep their slots on every file and every frame', json.dumps(floating))
    labels = {n: [p['label'], p['title']] for n, p in places.items()}
    check(all(p['label'] == 'Open' for n, p in places.items() if n != 'tool') and places['tool']['label'] == 'Reveal'
          and places['tool']['title'] == 'Reveal in Finder' and places['notes.md']['title'] == 'Open in your editor'
          and '⌘O' not in ''.join(p['title'] for p in places.values()),
          'Open: one word on every file, "Reveal" where only Finder may show it; the tooltip says where it opens (no ⌘O in Quick Look)', json.dumps(labels))
    view('code.ts')
    page.cmd('@eval:sb.setOpener(' + json.dumps({'path': D('code.ts'), 'app': 'Visual Studio Code', 'editor': True}) + '); 0')
    named = page.js("const e = document.getElementById('edit'); return [e.textContent, e.title, Math.round(e.getBoundingClientRect().left)]")
    check(named == ['Open', 'Open in Visual Studio Code', places['code.ts']['edit'][0]],
          'Open: the app named by the writer goes in the tooltip; the button stays one word, in place', json.dumps(named))

    # ---- no pulse on the current row as the arrows move ----
    view('notes.md')
    page.render(D('rows.csv'))
    anim = page.js("""const a = document.querySelector('#side-list a.row.active'); return a ? [a.textContent, getComputedStyle(a).animationName, a.className] : null""")
    check(anim and anim[0] == 'rows.csv' and anim[1] == 'none' and 'arrive' not in anim[2], 'sidebar: the row moved to does not pulse', json.dumps(anim))

    # ---- a table too large to edit says so, as its Raw text does ----
    view('large.csv')
    notes = page.js("return [...document.querySelectorAll('#doc .viewer-csv .viewer-note')].map((n) => n.textContent)")
    view('rows.csv')
    small = page.js("return [...document.querySelectorAll('#doc .viewer-csv .viewer-note')].map((n) => n.textContent)")
    check('Too large to edit here.' in notes and 'Too large to edit here.' not in small, 'CSV: a table over 2 MB says it is too large to edit; a small one does not',
          json.dumps([notes, small]))

    # ---- tooltips with the real keys ----
    tips = page.js("return ['find-btn', 'copy', 'raw', 'side-q', 'aa'].map((id) => document.getElementById(id).title)")
    check(tips[0] == 'Find (⌘F)' and tips[1] == 'Copy text (⌘C)' and tips[3] == 'Filter (⌥⌘F)' and '⌘' not in tips[2] + tips[4],
          'tooltips: Find, Copy and the filter give their keys; Raw and Aa, which have none, give none', json.dumps(tips))

    # ---- focus rings ----
    # WebKit gives a scripted focus() no :focus-visible, so the rules themselves are read.
    ring = page.js("""const want = ['#toolbar > button:focus-visible', '#side-toggle:focus-visible', '#copy:focus-visible'], got = {};
      const walk = (rules) => { for (const r of rules) { if (r.cssRules) walk(r.cssRules);
        for (const w of want) if ((r.selectorText || '').split(',').map((s) => s.trim()).includes(w) && /outline: 2px solid/.test(r.cssText)) got[w] = true; } };
      for (const sh of document.styleSheets) { try { walk(sh.cssRules); } catch (e) {} }
      return want.map((w) => !!got[w]);""")
    check(ring == [True, True, True],
          'focus: the toolbar buttons, the sidebar button and Copy show a 2 px ring when focused from the keyboard', json.dumps(ring))

    # ---- Copy: announced, and never over the last line or row ----
    live = page.js("const s = document.getElementById('status'); return [s.getAttribute('role'), s.getAttribute('aria-live')]")
    check(live == ['status', 'polite'], 'copy: the status line ("Copied") is a polite live region, so VoiceOver announces it', json.dumps(live))
    CLEAR = """const c = document.getElementById('copy').getBoundingClientRect(), doc = document.getElementById('doc');
      const apart = (r) => r.bottom <= c.top || r.top >= c.bottom || r.right <= c.left || r.left >= c.right;
      const out = { shown: !document.getElementById('copy').hidden };
      const pre = doc.querySelector('pre.code');
      if (pre) { const cv0 = doc.querySelector('.code-view'); cv0.scrollLeft = cv0.scrollWidth;
        window.scrollTo(0, (document.scrollingElement.scrollHeight - innerHeight) / 2);
        const mid = document.createRange(); mid.selectNodeContents(pre); out.mid = [...mid.getClientRects()].every(apart);
        window.scrollTo(0, document.scrollingElement.scrollHeight); const cv = doc.querySelector('.code-view'); cv.scrollLeft = cv.scrollWidth;
        const rg = document.createRange(); rg.selectNodeContents(pre); const rs = [...rg.getClientRects()];
        const line = rs.filter((r) => r.width > 0).sort((a, b) => b.bottom - a.bottom)[0]; out.last = !!line && apart(line); }
      const box = doc.querySelector('.csv-scroll');
      if (box) { window.scrollTo(0, document.scrollingElement.scrollHeight); box.scrollTop = box.scrollHeight; box.scrollLeft = box.scrollWidth;
        const rows = [...box.querySelectorAll('tbody tr:not(.pad)')], last = rows[rows.length - 1];
        out.last = !!last && [...last.children].every((td) => apart(td.getBoundingClientRect())); out.box = apart(box.getBoundingClientRect()); }
      if (!pre && !box) { window.scrollTo(0, document.scrollingElement.scrollHeight); const ps = doc.querySelectorAll('p'); out.last = apart(ps[ps.length - 1].getBoundingClientRect()); }
      const cs = getComputedStyle(doc); out.column = doc.getBoundingClientRect().right - parseFloat(cs.paddingRight) <= c.left;
      return out;"""
    clear = {}
    for size in ('1100x760', '700x500', '520x420'):
        page.cmd('@size:' + size)
        for n in ('notes.md', 'code.ts', 'rows.csv'):
            view(n)
            page.cmd('@wait:0.2')
            clear[f'{n} {size}'] = page.js(CLEAR)
    page.cmd('@size:1100x760')
    check(all(v['shown'] and v['last'] and (v['column'] or v.get('box') is True) and v.get('mid', True) and v.get('box', True) for v in clear.values())
          and all('mid' in v for k, v in clear.items() if k.startswith('code.ts')),
          'copy: always shown on text, and clear of the last line, the last table row and the text column (a table: its box ends above it), at any panel size', json.dumps(clear))


def tools(page, check, out):
    """The toolbar's Copy, Find and Formatted/Raw: which views show them, what Copy copies (the harness records it; the clipboard
    is never touched), find's matches, count and steps in the text on screen, a windowed table, a 2 MB script and a JSON tree,
    its key sessions, and the Raw toggle per kind, remembered as a panel setting."""
    d, big = make_tools(out)
    D = lambda n: os.path.join(d, n)
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    flag = lambda m, k: str(m.get(k)).lower() in ('1', 'true')
    TOOLS = "return ['raw', 'find-btn', 'copy'].map((id) => document.getElementById(id).hidden ? '' : id).filter(Boolean)"
    STATE = """const c = CSS.highlights, n = (k) => (c.get(k) ? c.get(k).size : 0);
      return { open: !document.getElementById('find').hidden, count: document.getElementById('find-count').textContent, all: n('sb-find'), cur: n('sb-find-cur'),
        text: c.get('sb-find-cur') && c.get('sb-find-cur').size ? [...c.get('sb-find-cur')][0].toString() : null };"""

    def view(name):
        page.cmd('@root:' + d)
        r = page.render(D(name))
        page.cmd('@wait:0.3')
        return r

    def find(text):
        page.cmd("@eval:(() => { const q = document.getElementById('find-q'); q.value = " + json.dumps(text) + "; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
        page.cmd('@wait:0.2')
        return page.js(STATE)

    def cmd(c, wait=0.3):
        r = page.cmd(c)
        w = page.cmd(f'@wait:{wait}')
        return {'result': r['result'], 'messages': r['messages'] + w['messages']}

    def key(k, **mods):
        opts = dict(key=k, bubbles=True, cancelable=True, **mods)
        return cmd('@eval:(() => { const e = new KeyboardEvent("keydown", ' + json.dumps(opts) + '); document.body.dispatchEvent(e); return String(e.defaultPrevented); })()')

    def enter(shift=False):
        page.cmd("@eval:(() => { document.getElementById('find-q').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: " + ('true' if shift else 'false')
                 + ", bubbles: true, cancelable: true })); return 0; })()")
        page.cmd('@wait:0.1')
        return page.js(STATE)

    page.cmd('@size:1100x760')
    # ---- which view shows which tool ----
    shown = {}
    for n in ('notes.md', 'tree.json', 'cells.ipynb', 'rows.csv', 'info.plist', 'min.css', 'plain.css', 'code.ts', 'big.js', 'pic.png'):
        view(n)
        shown[n] = page.js(TOOLS)
    check(shown == {'notes.md': ['raw', 'find-btn', 'copy'], 'tree.json': ['raw', 'find-btn', 'copy'], 'cells.ipynb': ['raw', 'find-btn', 'copy'],
                    'rows.csv': ['raw', 'find-btn', 'copy'], 'info.plist': ['raw', 'find-btn', 'copy'], 'min.css': ['raw', 'find-btn', 'copy'],
                    'plain.css': ['find-btn', 'copy'], 'code.ts': ['find-btn', 'copy'], 'big.js': ['find-btn', 'copy'], 'pic.png': []},
          'toolbar: Copy and Find for every text view, Raw only where the view is formatted, none for an image', json.dumps(shown))

    # ---- Copy ----
    view('notes.md')
    r = click(page, '#copy')
    check(not msgs(r, 'copy'), 'copy: a synthetic click copies nothing')
    r = page.cmd('@nativeclick:#copy')
    c = msgs(r, '_copied')
    st = page.js("return [document.getElementById('status').textContent, document.getElementById('copy').classList.contains('done')]")
    check(len(msgs(r, 'copy')) == 1 and len(c) == 1 and c[0]['text'] == open(D('notes.md')).read() and st == ['Copied', True],
          'copy: the button copies the Markdown source, and says so', json.dumps([c, st])[:300])
    page.cmd("@eval:document.getElementById('copy').classList.remove('done'); 0")
    page.cmd('@wait:0.3')
    place = page.js(""" const b = document.getElementById('copy').getBoundingClientRect(), f = document.getElementById('find');
      const style = getComputedStyle(document.getElementById('copy'));
      return [!document.getElementById('copy').closest('#toolbar, #doc'), style.position, Math.round(innerWidth - b.right), Math.round(innerHeight - b.bottom),
        document.getElementById('copy').matches(':hover') || +style.opacity < 1];""")
    check(place[:2] == [True, 'fixed'] and 16 <= place[2] <= 40 and 8 <= place[3] <= 40 and place[4],
          'copy: a quiet floating button at the bottom right, outside the toolbar and the document, clear of the scrollbar', json.dumps(place))
    page.cmd("@eval:document.getElementById('find-btn').click(); 0")
    apart = page.js("""const a = document.getElementById('copy').getBoundingClientRect(), b = document.getElementById('find').getBoundingClientRect();
      return a.top >= b.bottom || a.bottom <= b.top || a.left >= b.right || a.right <= b.left;""")
    page.cmd("@eval:document.getElementById('find-close').click(); 0")
    check(apart, 'copy: never over the find bar')
    chrome = page.js("return ['toolbar', 'side-toggle', 'frame', 'toc', 'sidebar', 'copy'].map((id) => getComputedStyle(document.getElementById(id)).webkitUserSelect)")
    check(all(x == 'none' for x in chrome), 'top left: only the document is selectable, so a selection never paints the chrome or the empty page', json.dumps(chrome))
    page.cmd("@eval:document.getElementById('side-menu').click(); 0")
    menu = page.js("""const m = document.getElementById('side-pop').getBoundingClientRect(), s = document.getElementById('sidebar').getBoundingClientRect();
      const bg = getComputedStyle(document.getElementById('side-pop')).backgroundImage;
      return [Math.round(m.left - s.left), Math.round(s.right - m.right), m.top > document.getElementById('side-q').getBoundingClientRect().bottom, bg.split('gradient').length];""")
    page.cmd("@eval:document.getElementById('side-menu').click(); 0")
    check(menu[0] == 8 and menu[1] == 8 and menu[2] and menu[3] == 3, 'top left: the sort menu spans the sidebar under the filter on an opaque ground, never half over its rows', json.dumps(menu))
    view('rows.csv')
    r = page.cmd('@nativeclick:#copy')
    c = msgs(r, '_copied')
    check(len(c) == 1 and c[0]['text'] == open(D('rows.csv')).read(), 'copy: a table copies its file text, not the table', str(len(c)))
    page.cmd("@eval:getSelection().removeAllRanges(); 0")
    r = key('c', metaKey=True)
    c = msgs(r, '_copied')
    check(r['result'] == 'true' and len(c) == 1 and c[0]['text'] == open(D('rows.csv')).read(), '⌘C with nothing selected copies the whole file', json.dumps(r['result']))
    page.cmd("@eval:(() => { const td = document.querySelector('#doc table.csv tbody td'); getSelection().selectAllChildren(td); return 0; })()")
    r = key('c', metaKey=True)
    check(r['result'] == 'false' and not msgs(r, 'copy'), '⌘C with a selection is left to the ordinary copy', json.dumps(r['result']))
    page.cmd("@eval:getSelection().removeAllRanges(); 0")
    r = cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': 'copy', 'path': D('notes.md')}) + '); 0')
    check(msgs(r, '_copyRefused') and not msgs(r, '_copied'), 'copy: only the file on screen is copied')
    view('pic.png')
    r = cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': 'copy', 'path': D('pic.png')}) + '); 0')
    check(msgs(r, '_copyRefused') and not msgs(r, '_copied'), 'copy: an image has no text to copy')

    # ---- Find: the text on screen ----
    view('notes.md')
    r = page.cmd('@nativeclick:#find-btn')
    fb = msgs(r, 'filterBegin')
    seq = int(fb[0]['seq']) if fb else -1
    check(len(fb) == 1 and flag(fb[0], 'find') and not flag(fb[0], 'list') and page.js("return document.getElementById('find-q').classList.contains('held')")
          and page.js(STATE)['open'], 'find: the button opens the bar and asks for the key panel over its field', json.dumps(fb))
    page.cmd('@eval:sb.filterText(' + json.dumps({'seq': seq, 'text': 'needle'}) + '); 0')
    page.cmd('@wait:0.2')
    f1 = page.js(STATE)
    page.cmd('@eval:sb.filterKey(' + json.dumps({'seq': seq, 'key': 'next'}) + '); 0')
    f2 = page.js(STATE)
    page.cmd('@eval:sb.filterKey(' + json.dumps({'seq': seq, 'key': 'prev'}) + '); sb.filterKey(' + json.dumps({'seq': seq, 'key': 'prev'}) + '); 0')
    f3 = page.js(STATE)
    page.cmd('@eval:sb.filterKey(' + json.dumps({'seq': seq + 5, 'key': 'next'}) + '); sb.filterKey(' + json.dumps({'seq': seq, 'key': 'down'}) + '); 0')
    f4 = page.js(STATE)
    check(f1['count'] == '1 of 5' and f1['cur'] == 1 and f1['all'] == 4 and f1['text'] == 'Needle' and f2['count'] == '2 of 5'
          and f3['count'] == '5 of 5' and f4['count'] == '5 of 5' and not page.js("return document.querySelector('#doc mark')"),
          'find: case-insensitive matches in headings, text, code and tasks, counted; next, previous and around; stray keys ignored; the DOM untouched',
          json.dumps([f1, f2, f3, f4]))
    check(enter()['count'] == '1 of 5' and enter(shift=True)['count'] == '5 of 5', 'find: ↵ and ⇧↵ in the field when the page has the keys')
    steps = []
    for k in ('next', 'next', 'prev'):
        # As the writer does: the field's text again before each key.
        page.cmd('@eval:sb.filterText(' + json.dumps({'seq': seq, 'text': 'needle'}) + '); sb.filterKey(' + json.dumps({'seq': seq, 'key': k}) + '); 0')
        steps.append(page.js(STATE)['count'])
    check(steps == ['1 of 5', '2 of 5', '1 of 5'], 'find: the text sent again before each key does not start the search over', json.dumps(steps))
    check(find('haystack!')['count'] == 'No matches' and find('')['count'] == '' and page.js(STATE)['all'] == 0, 'find: no matches, and an empty field, say so')
    r = page.cmd('@eval:sb.filterEnd(' + json.dumps({'seq': seq, 'reason': 'escape'}) + '); 0')
    f = page.js(STATE)
    check(not f['open'] and f['all'] == 0 and f['cur'] == 0 and not page.js("return document.getElementById('find-q').classList.contains('held')"),
          'find: Esc in the key panel closes the bar and clears the matches', json.dumps(f))
    r = key('f', metaKey=True)
    fb = msgs(r, 'filterBegin')
    check(r['result'] == 'true' and page.js(STATE)['open'] and len(fb) == 1 and flag(fb[0], 'find'), '⌘F opens find when the page has the keys', json.dumps(fb))
    r = key('ƒ', metaKey=True, altKey=True, code='KeyF')
    fb = msgs(r, 'filterBegin')
    check(r['result'] == 'true' and len(fb) == 1 and not flag(fb[0], 'find') and page.js("return document.getElementById('side-q').classList.contains('held')"),
          "⌥⌘F takes the sidebar's filter field instead", json.dumps(fb))
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    lb = msgs(cmd('@eval:sb.listKeysWanted(' + json.dumps({'root': d}) + '); 0'), 'filterBegin')
    lseq = int(lb[0]['seq']) if lb else -1
    r = cmd('@eval:sb.filterKey(' + json.dumps({'seq': lseq, 'key': 'find'}) + '); 0')
    types_ = [m.get('type') for m in r['messages']]
    fb = msgs(r, 'filterBegin')
    check(lb and flag(lb[0], 'list') and 'filterStop' in types_ and len(fb) == 1 and flag(fb[0], 'find') and types_.index('filterStop') < types_.index('filterBegin'),
          '⌘F in a list session: the list session ends and a find session begins', json.dumps(types_))
    r = cmd("@eval:document.getElementById('find-close').click(); 0")
    check(not page.js(STATE)['open'] and msgs(r, 'filterStop'), 'find: the close button closes it and lets the key panel go')

    # ---- Find in a windowed table: the model is searched, the row scrolled to and drawn ----
    view('rows.csv')
    page.cmd('@nativeclick:#find-btn')
    f1 = find('needle')
    for _ in range(14):
        enter()
    row = page.js("""const r = [...CSS.highlights.get('sb-find-cur')][0], tr = r.startContainer.parentElement.closest('tr'), s = document.querySelector('#doc .csv-scroll');
      const a = tr.getBoundingClientRect(), b = s.getBoundingClientRect();
      return [tr.cells[0].textContent, r.toString(), a.top >= b.top && a.bottom <= b.bottom, s.scrollTop > 0, document.querySelectorAll('#doc table.csv tbody tr:not(.pad)').length < 200];""")
    f2 = page.js(STATE)
    check(f1['count'] == '1 of 20' and f2['count'] == '15 of 20' and row == ['14008', 'needle', True, True, True],
          'find in a windowed CSV: 20 matches in 20,000 rows; the 15th row is scrolled to, drawn and highlighted', json.dumps([f1, f2, row]))
    f3 = enter(shift=True)
    f4 = find('HAY')
    check(f3['count'] == '14 of 20' and f4['count'] == '1 of 10,000+' and f4['cur'] == 1, 'find in a CSV: back one; a common word stops counting at 10,000', json.dumps([f3, f4]))
    page.cmd('@nativeclick:#raw')
    f5 = find('needle')
    check(f5['count'] == '1 of 20' and page.js("return !!document.querySelector('#doc .viewer-csv-raw pre.code')"), 'find in a raw CSV: the text is searched', json.dumps(f5))
    page.cmd('@nativeclick:#raw')

    # ---- Find in 2 MB of code ----
    view('big.js')
    page.cmd('@wait:0.5')
    check(page.js(STATE)['open'], 'find: stays open on the next text file')
    key('f', metaKey=True)
    t = page.js("""finder.q = 'NEEDLE'; const t0 = performance.now(); findSearch(false); findGo(0); const t1 = performance.now(); findStep(-1); const t2 = performance.now();
      const r = [...CSS.highlights.get('sb-find-cur')][0].getBoundingClientRect();
      return [Math.round(t1 - t0), Math.round(t2 - t1), document.getElementById('find-count').textContent, r.top > 0 && r.bottom < innerHeight, window.scrollY > 0];""")
    n = big.lower().count('needle')
    check(t[2] == f'{n} of {n}' and t[3] and t[4] and t[0] < 400 and t[1] < 400,
          f'find in 2 MB of code: {n} matches, the last scrolled into view, each step well under half a second', json.dumps(t))
    f = find('function')
    check(f['count'] == '1 of 10,000+' and f['all'] <= 150, 'find in 2 MB of code: only the matches near the screen are drawn', json.dumps(f))

    # ---- Find in a JSON tree: the model is searched, and a closed branch opens to the match ----
    view('tree.json')
    key('f', metaKey=True)
    f1 = find('needle')
    rows = lambda: page.js("""const r = [...CSS.highlights.get('sb-find-cur')][0], row = r.startContainer.parentElement.closest('.jt-row');
      return [row.dataset.ptr, r.toString(), row.getBoundingClientRect().top > 0 && row.getBoundingClientRect().bottom < innerHeight];""")
    r1 = rows()
    f2 = enter()
    r2 = rows()
    check(f1['count'] == '1 of 2' and r1 == ['/items/900/k', 'needle', True] and f2['count'] == '2 of 2' and r2 == ['/deep/a/b/c/needle', 'needle', True],
          'find in a JSON tree: a match past the first 500 items and one four levels down are opened, drawn and scrolled to', json.dumps([f1, r1, r2]))
    page.cmd("@eval:document.getElementById('find-close').click(); 0")

    # ---- Formatted / Raw, per kind, while the preview stays open ----
    view('notes.md')
    r = page.cmd('@nativeclick:#raw')
    m = page.js("""const b = document.getElementById('raw'); return [b.getAttribute('aria-pressed'), b.title, (document.querySelector('#doc .viewer-source pre.code') || {}).textContent,
      document.querySelectorAll('#doc > [data-src]').length];""")
    written = [x.get('patch') for x in msgs(r, '_written')]
    check(m[:3] == ['true', 'Markdown source', open(D('notes.md')).read()] and m[3] == 0 and written == [],
          'raw: Markdown shows its source, read only, and the choice is not saved as a setting', json.dumps([m[:2], m[3], written]))
    r = click(page, '#doc .viewer-source pre.code')
    check(not msgs(r, 'editBlock'), 'raw: a click in the source edits nothing')
    view('tree.json')
    check(page.js("return [!!document.querySelector('#doc .json-tree'), document.getElementById('raw').getAttribute('aria-pressed')]") == [True, 'false'],
          'raw: remembered per kind (JSON is still a tree)')
    saved = json.load(open(os.path.join(page.support, 'settings.json')))
    view('notes.md')
    check(saved.get('rawMarkdown') is not True and saved.get('rawJSON') is not True
          and page.js("return [!!document.querySelector('#doc .viewer-source'), document.getElementById('raw').getAttribute('aria-pressed')]") == [True, 'true'],
          'raw: settings.json is left alone, and Markdown opens as source again while the preview stays open',
          json.dumps({k: v for k, v in saved.items() if k.startswith('raw')}))
    page.cmd('@nativeclick:#raw')
    check(page.js("return [document.querySelector('#doc > h1').textContent, document.getElementById('raw').title, document.getElementById('raw').getAttribute('aria-pressed')]") == ['Needle notes', 'Markdown source', 'false'],
          'raw: and back to rendered')
    page.cmd('@nativeclick:#raw')
    page.cmd("@eval:sb.previewClosed(); 0")
    view('tree.json')
    view('notes.md')
    check(page.js("return [!!document.querySelector('#doc > h1'), document.getElementById('raw').getAttribute('aria-pressed')]") == [True, 'false'],
          'raw: the next preview opens formatted again')
    view('cells.ipynb')
    page.cmd('@nativeclick:#raw')
    titles = [page.js("return document.getElementById('raw').title")]
    nb = page.js("return [(document.querySelector('#doc pre.code') || {}).textContent, document.querySelectorAll('#doc .nb-cell, #doc .viewer-toggle').length]")
    page.cmd('@nativeclick:#raw')
    check(nb == [open(D('cells.ipynb')).read(), 0] and page.js("return document.querySelectorAll('#doc .nb-cell').length") == 2,
          'raw: a notebook shows its JSON, then its cells again', json.dumps(nb)[:200])
    view('info.plist')
    pretty = page.js("return document.querySelector('#doc pre.code').textContent")
    page.cmd('@nativeclick:#raw')
    titles.append(page.js("return document.getElementById('raw').title"))
    raw = page.js("return document.querySelector('#doc pre.code').textContent")
    page.cmd('@nativeclick:#raw')
    check(pretty.startswith('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n  <dict>\n    <key>Name</key>\n    <string>a &amp; b</string>')
          and '    <array>\n      <integer>1</integer>' in pretty and raw == open(D('info.plist')).read(),
          'raw: a property list is indented, or shown as is', json.dumps(pretty[:200]))
    view('min.css')
    pretty = page.js("return document.querySelector('#doc pre.code').textContent")
    page.cmd('@nativeclick:#raw')
    titles.append(page.js("return document.getElementById('raw').title"))
    raw = page.js("return document.querySelector('#doc pre.code').textContent")
    page.cmd('@nativeclick:#raw')
    view('tree.json')
    page.cmd('@nativeclick:#raw')
    titles.append(page.js("return document.getElementById('raw').title"))
    page.cmd('@nativeclick:#raw')
    check(titles == ['Raw JSON', 'Raw XML', 'Raw CSS', 'Raw JSON'], 'raw: its tooltip names the raw view whatever its state; aria-pressed says which is on', json.dumps(titles))
    check(pretty.startswith('.a {\n  color:red;\n  background:url(data:image/png;base64,AA;BB)\n}\n\n.b>c,d:hover {\n  margin:0 auto;\n  content:"x;}{y"\n}\n\n@media (max-width:10px) {\n  .e {\n    top:0\n  }\n}')
          and raw == open(D('min.css')).read(), 'raw: minified CSS is laid out a declaration to a line (strings and url() kept whole), or shown as is', json.dumps(pretty[:160]))
    t = page.js("""const t0 = performance.now(); const a = prettyXML('<!DOCTYPE a ' + '[]'.repeat(100000)), b = prettyCSS('/* '.repeat(700000));
      const c = prettyXML('<plist><dict><string>  two spaces </string></dict></plist>');
      return [Math.round(performance.now() - t0), a, b.length > 0, c];""")
    check(t[0] < 1000 and t[1] is None and t[2] and '<string>  two spaces </string>' in t[3],
          'raw: hostile XML and CSS format in linear time; a string value keeps its spaces', json.dumps(t)[:200])
    r = cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': 'setting', 'key': 'rawJSON', 'value': 'yes'}) + '); 0')
    check(msgs(r, '_settingRefused') and not msgs(r, '_written'), 'raw: a setting that is not a boolean is refused')
    page.cmd('@root:')


def keys_and_filter(page, check, T, st, types):
    """The tree's keys and the filter, on the file browser's tree with sub/deep/deepest.txt open. Keys are dispatched as DOM
    events inside the page: the offscreen harness has no key window, and nothing is posted to any app."""
    def key(k, target='document.activeElement', **mods):
        opts = dict(key=k, bubbles=True, cancelable=True, **mods)
        r = page.cmd('@eval:(() => { const t = ' + target + ' || document.body; const e = new KeyboardEvent("keydown", '
                     + json.dumps(opts) + '); t.dispatchEvent(e); return String(e.defaultPrevented); })()')
        w = page.cmd('@wait:0.3')
        return {'taken': r['result'] == 'true', 'types': types(r) + types(w), 'msgs': r['messages'] + w['messages']}

    def opened(k):
        return [m.get('path') for m in k['msgs'] if m.get('type') == 'open']

    def typed(text):
        page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.focus(); q.value = " + json.dumps(text)
                 + "; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
        return page.js(CURSOR)

    c = page.js(CURSOR)
    check(c['cursor'] == 'deepest.txt' and c['active'] == 'deepest.txt', 'keys: the cursor starts on the file on screen', json.dumps(c))
    k = key('ArrowDown')
    c = page.js(CURSOR)
    check(k['taken'] and opened(k) == [T('sub', 'inner.md')] and c['cursor'] == 'inner.md' and c['active'] == 'inner.md',
          'keys: ↓ moves to the next row and opens it', json.dumps([k['types'], c['cursor'], c['active']]))
    r1 = page.cmd('@eval:(() => { const e = new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true }); document.body.dispatchEvent(e);'
                  ' document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true })); return 0; })()')
    page.cmd('@wait:0.4')
    c = page.js(CURSOR)
    check([m.get('path') for m in r1['messages'] if m.get('type') == 'open'] == [T('sub', 'deep', 'deepest.txt')] and c['cursor'] == 'deep'
          and c['active'] == 'deepest.txt', 'keys: ↑↑ opens the file passed and stops on the folder, which the late render does not undo', json.dumps(c))
    k = key('ArrowLeft')
    c = page.js(CURSOR)
    check(k['taken'] and 'unlist' in k['types'] and ['deep', 2, 'false'] in c['rows'] and c['cursor'] == 'deep' and not opened(k),
          'keys: ← collapses an open folder', json.dumps(k['types']))
    k = key('ArrowRight')
    c = page.js(CURSOR)
    check(k['taken'] and ['deep', 2, 'true'] in c['rows'] and ['deepest.txt', 3, None] in c['rows'], 'keys: → expands a folder', json.dumps(c['rows'][:6]))
    k = key('ArrowRight')
    c = page.js(CURSOR)
    check(k['taken'] and c['cursor'] == 'deepest.txt' and c['active'] == 'deepest.txt', 'keys: → on an open folder moves into it', json.dumps(c))
    k = key('ArrowLeft')
    c = page.js(CURSOR)
    check(c['cursor'] == 'deep' and not opened(k), 'keys: ← on a file moves to its folder', json.dumps(c))
    k = key('Enter')
    c1 = page.js(CURSOR)
    key('Enter')
    c2 = page.js(CURSOR)
    check(k['taken'] and ['deep', 2, 'false'] in c1['rows'] and ['deep', 2, 'true'] in c2['rows'], 'keys: Return on a folder toggles it')
    k = key('End')
    c = page.js(CURSOR)
    last = c['rows'][-1][0]
    check(k['taken'] and c['cursor'] == last and opened(k) == [T(last)], 'keys: End jumps to the last row and opens it', json.dumps([last, opened(k)]))
    k = key('Home')
    c = page.js(CURSOR)
    check(k['taken'] and c['cursor'] == c['rows'][0][0] == 'hostile' and not opened(k), 'keys: Home jumps to the first row (a folder: nothing opens)', json.dumps(c['cursor']))
    top = page.js("return document.getElementById('side-list').scrollTop")
    key('End')
    bottom = page.js("""const l = document.getElementById('side-list'), r = l.querySelector('a.cursor').getBoundingClientRect(), b = l.getBoundingClientRect();
      return [l.scrollTop, r.top >= b.top - 1 && r.bottom <= b.bottom + 1]""")
    check(top == 0 and bottom[1] and (bottom[0] > 0 or page.js("const l = document.getElementById('side-list'); return l.scrollHeight <= l.clientHeight")),
          'keys: the cursor row scrolls into view in the list', json.dumps([top, bottom]))

    # Not taken: Space (Quick Look closes on it), modified keys, other fields, the Aa popover, and an edit in progress.
    before = page.js(CURSOR)
    sp = key(' ')
    check(not sp['taken'] and not {'open', 'list', 'unlist'} & set(sp['types']) and page.js(CURSOR)['cursor'] == before['cursor'], 'keys: Space is never taken')
    mod = key('ArrowDown', altKey=True)
    check(not mod['taken'] and not opened(mod), 'keys: ⌥↓ is left alone')
    page.cmd("@eval:(() => { const i = document.createElement('input'); i.id = 'other-field'; document.body.append(i); i.focus(); return 0; })()")
    other = key('ArrowDown', "document.getElementById('other-field')")
    page.cmd("@eval:document.getElementById('other-field').remove(); 0")
    check(not other['taken'] and not opened(other), 'keys: not taken in another field')
    click(page, '#aa')
    popk = key('ArrowUp')
    click(page, '#aa')
    check(not popk['taken'] and not opened(popk) and page.js("return document.getElementById('aa-pop').hidden"), 'keys: not taken while the Aa popover is open')
    page.render(T('README.md'))
    page.cmd('@wait:0.3')
    click(page, '#doc > p')
    during = [key('ArrowDown'), key('End'), key('ArrowUp', "document.getElementById('side-q')")]
    ed = st()['editing']
    check(ed and not any(k['taken'] or opened(k) for k in during) and 'editStop' not in sum((k['types'] for k in during), []),
          'keys: nothing is taken while a block is being edited', json.dumps([k['types'] for k in during]))
    fk = key('f', metaKey=True)
    check(fk['taken'] and page.js(CURSOR)['focus'] != 'side-q' and not st()['editing'] and not page.js("return document.getElementById('find').hidden"),
          "keys: ⌘F finds in the file, ending the edit, and never takes the sidebar's filter")
    page.cmd("@eval:document.getElementById('find-close').click(); 0")
    page.cmd('@eval:sb.editEnd({}); 0')

    # ---- the filter, typed into the page's own field ----
    c = typed('rdme')
    check([r[0] for r in c['rows']] == ['README.md'], 'filter: fuzzy, the letters in order ("rdme" finds README.md)', json.dumps(c['rows']))
    c = typed('INNER')
    check([r[0] for r in c['rows']] == ['sub', 'inner.md'] and c['rows'][0][2] == 'true', 'filter: case-insensitive, and the folder holding a match stays, shown open',
          json.dumps(c['rows']))
    click(page, '#side-q')
    typed('')
    click(page, '#side-list a.row[data-path$="/sub"]')
    s = [x[0] for x in st()['rows'] if x[1] == 2]
    r = page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = 'deepest'; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
    w = page.cmd('@wait:0.3')
    c = page.js(CURSOR)
    check(not s and [x[0] for x in c['rows']] == ['sub', 'deep', 'deepest.txt'] and not {'list', 'unlist'} & set(types(r) + types(w)),
          'filter: finds files in listed folders that are collapsed, and lists nothing new', json.dumps([s, c['rows'], types(r) + types(w)]))
    page.cmd("@eval:document.getElementById('side-q').blur(); 0")
    home, right, left = key('Home'), key('ArrowRight'), key('ArrowLeft')
    after_right = [home, right]
    c = page.js(CURSOR)
    check(right['taken'] and left['taken'] and c['cursor'] == 'sub' and [x[0] for x in c['rows']] == ['sub', 'deep', 'deepest.txt']
          and not {'list', 'unlist'} & set(sum((k['types'] for k in after_right + [left]), [])),
          'filter: → and ← move through the matches without opening or closing a folder', json.dumps([c['cursor'], c['rows'], [k['types'] for k in after_right + [left]]]))
    c = typed('evil.pdf')
    check([x[0] for x in c['rows']] == ['hostile', 'evil.pdf'] and not c['notes'],
          'filter: a file in a folder never listed (hostile/) is found by the names search, with its folder', json.dumps(c))
    c = typed('.md')
    k = key('ArrowDown')
    c2 = page.js(CURSOR)
    check(k['taken'] and c2['focus'] == 'side-q' and opened(k) and c2['cursor'] == c2['active'] and c2['cursor'].endswith('.md'),
          'filter: ↓ from the field moves through the matches and opens them; the field keeps focus', json.dumps([c2['cursor'], opened(k)]))
    k = key('ArrowLeft')
    check(not k['taken'], 'filter: ←/→ stay in the field for editing the text')
    k = key(' ')
    check(not k['taken'], 'filter: Space is not taken in the field either')
    k = key('Escape')
    c = page.js(CURSOR)
    check(k['taken'] and c['q'] == '' and c['focus'] == 'side-q' and any(r[0] == 'README.md' for r in c['rows']) and not c['notes'][:1] == ['No matches'],
          'filter: Esc clears it and the whole tree comes back', json.dumps(c['q']))
    k = key('Escape')
    check(k['taken'] and page.js(CURSOR)['focus'] != 'side-q', 'filter: a second Esc leaves the field')
    typed('inner')
    page.cmd('@root:')
    page.render(T('README.md'))
    page.cmd('@wait:0.3')
    check(page.js(CURSOR)['q'] == 'inner', 'filter: kept while the same folder shows another file')
    typed('')
    page.cmd("@eval:document.getElementById('side-q').blur(); 0")
    filter_session(page, check, T, st, types, key, opened)
    list_session(page, check, T, types, opened)
    auto_session(page, check, T, types, opened)


def filter_session(page, check, T, st, types, key, opened):
    """The filter in Quick Look, page side: a real click asks for the writer's key panel (filterBegin), and the native side's
    sb.filterText, sb.filterKey and sb.filterEnd stand in for it here."""
    held = lambda: page.js("return document.getElementById('side-q').classList.contains('held')")
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    page.cmd('@root:' + T())
    page.render(T('README.md'))
    page.cmd('@wait:0.3')

    r = click(page, '#side-q')
    check(not msgs(r, 'filterBegin') and not held(), 'filter session: a synthetic click does not start one')
    r = page.cmd('@nativeclick:#side-q')
    fb = msgs(r, 'filterBegin')
    seq = int(fb[0]['seq']) if fb else -1
    check(len(fb) == 1 and fb[0].get('text') == '' and float(fb[0].get('width', 0)) > 100 and 0 < float(fb[0].get('height', 0)) < 40
          and 0 <= float(fb[0].get('clickX', -1)) <= float(fb[0].get('width', 0)) and held(),
          'filter session: a real click in the field asks for the key panel over it', json.dumps(fb))
    r = page.cmd('@nativeclick:#side-q')
    check(not msgs(r, 'filterBegin'), 'filter session: a second click in the field keeps the one session')

    def native(fn, arg):
        r = page.cmd('@eval:sb.' + fn + '(' + json.dumps(arg) + '); 0')
        w = page.cmd('@wait:0.3')
        return {'types': types(r) + types(w), 'msgs': r['messages'] + w['messages']}

    native('filterText', {'seq': seq, 'text': 'inner'})
    c = page.js(CURSOR)
    check([x[0] for x in c['rows']] == ['sub', 'inner.md'] and c['q'] == 'inner', 'filter session: the text the writer sends filters the tree', json.dumps(c['rows']))
    native('filterText', {'seq': seq + 1, 'text': 'zzz'})
    native('filterText', {'seq': seq, 'text': 5})
    check(page.js(CURSOR)['q'] == 'inner', 'filter session: text for another session, or not text, is ignored')
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    c = page.js(CURSOR)
    check(c['cursor'] == 'sub' and not opened(k), 'filter session: ↓ from the writer moves to the first match (a folder: nothing opens)', json.dumps(c['cursor']))
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    c = page.js(CURSOR)
    check(opened(k) == [T('sub', 'inner.md')] and c['cursor'] == 'inner.md' and c['active'] == 'inner.md' and held(),
          'filter session: ↓ again opens the match, and the session stays', json.dumps([opened(k), c['cursor']]))
    k = native('filterKey', {'seq': seq, 'key': 'home'})
    check(page.js(CURSOR)['cursor'] == 'sub', 'filter session: Home from the writer jumps to the first match')
    k = native('filterKey', {'seq': seq, 'key': 'return'})
    check(page.js(CURSOR)['cursor'] == 'sub' and not opened(k) and held(), 'filter session: Return on a folder opens no file and keeps the session')
    for bad in ('escape', 'ArrowDown', '__proto__', 'toString'):
        before = page.js(CURSOR)
        k = native('filterKey', {'seq': seq, 'key': bad})
        if page.js(CURSOR) != before or opened(k):
            check(False, f'filter session: unknown key {bad!r} ignored')
            break
    else:
        check(True, 'filter session: keys other than up, down, home, end and return are ignored')
    k = native('filterKey', {'seq': seq, 'key': ' '})
    check(not opened(k) and held(), 'filter session: Space is not a list key')

    r = click(page, '#side-list a.row[data-path$="/inner.md"]')
    check(held() and not msgs(r, 'filterStop'), 'filter session: a click in the sidebar keeps it')
    page.render(T('README.md'))
    page.cmd('@wait:0.3')
    check(held(), 'filter session: kept while the same folder shows another file')
    r = click(page, '#doc > p')
    t = types(r)
    check(not held() and msgs(r, 'filterStop') and int(msgs(r, 'filterStop')[0]['seq']) == seq and 'editBlock' in t and t.index('filterStop') < t.index('editBlock'),
          'filter session: a click outside the sidebar ends it before an edit starts', json.dumps(t))
    native('filterText', {'seq': seq, 'text': 'late'})
    check(page.js(CURSOR)['q'] == 'inner', 'filter session: text arriving after the end is ignored')

    r = page.cmd('@nativeclick:#side-q')
    t = types(r)
    fb = msgs(r, 'filterBegin')
    check('editStop' in t and fb and t.index('editStop') < t.index('filterBegin') and not st()['editing'] and int(fb[0]['seq']) > seq
          and fb[0].get('text') == 'inner', 'filter session: clicking the field ends the edit first, then asks with the text so far', json.dumps(t))
    seq = int(fb[0]['seq']) if fb else -1
    native('filterEnd', {'seq': seq + 1})
    check(held(), 'filter session: an end for another session is ignored')
    native('filterEnd', {'seq': seq})
    check(not held(), 'filter session: the native side can end it (Esc, blur, an edit, a closed preview)')

    r = page.cmd('@nativeclick:#side-q')
    seq = int(msgs(r, 'filterBegin')[0]['seq'])
    native('filterText', {'seq': seq, 'text': 'md'})
    r = page.cmd("@eval:[1, 2, 3].forEach(() => sb.filterKey({ seq: %d, key: 'down', repeat: true })); 0" % seq)
    w = page.cmd('@wait:0.4')
    held_opens = [m for m in r['messages'] if m.get('type') == 'open']
    check(not held_opens and len([m for m in w['messages'] if m.get('type') == 'open']) == 1,
          'filter session: a held ↓ (auto-repeat) opens only the file it stops on', json.dumps(types(r) + types(w)))
    r = page.cmd('@size:600x700')
    w = page.cmd('@wait:0.3')
    check(not held() and [int(m['seq']) for m in r['messages'] + w['messages'] if m.get('type') == 'filterStop'] == [seq],
          'filter session: narrowing the panel hides the sidebar and ends the session', json.dumps(types(r) + types(w)))
    page.cmd('@size:1200x800')
    r = page.cmd('@nativeclick:#side-q')
    r2 = page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    check(msgs(r, 'filterBegin') and not held() and not msgs(r2, 'filterStop'), "filter session: a new preview clears the page's session without asking the writer")
    page.cmd('@size:600x700')
    click(page, '#side-toggle')
    page.cmd('@wait:0.4')
    r = page.cmd('@nativeclick:#side-q')
    seq = int(msgs(r, 'filterBegin')[0]['seq'])
    native('filterText', {'seq': seq, 'text': 'v2'})
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    peeking = page.js("return document.documentElement.classList.contains('sb-peek')")
    check(opened(k) and not peeking and not held() and [int(m['seq']) for m in k['msgs'] if m.get('type') == 'filterStop'] == [seq],
          'filter session: in a narrow panel, opening a file hides the sidebar and ends the session with it', json.dumps(k['types']))
    page.cmd('@size:1200x800')
    native('filterText', {'seq': seq, 'text': ''})
    page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = ''; q.dispatchEvent(new Event('input')); return 0; })()")

    r = page.cmd('@nativeclick:#side-q')
    seq = int(msgs(r, 'filterBegin')[0]['seq'])
    other = os.path.join(page.out, 'lone')
    page.cmd('@root:' + other)
    r = page.render(os.path.join(other, 'only.md'))
    page.cmd('@wait:0.3')
    check(not held() and [int(m['seq']) for m in msgs(r, 'filterStop')] == [seq] and page.js(CURSOR)['q'] == '',
          'filter session: another folder ends it and clears the field', json.dumps(types(r)))

    # The installer quits Quick Look: a running update ends the session and starts no new one until it is over.
    page.render(os.path.join(other, 'only.md'))
    page.cmd('@wait:0.3')
    r = page.cmd('@nativeclick:#side-q')
    seq = int(msgs(r, 'filterBegin')[0]['seq'])
    r = page.cmd("@eval:sb.update({ state: 'started', version: '10.10.10' }); 0")
    check(not held() and [int(m['seq']) for m in msgs(r, 'filterStop')] == [seq], 'filter session: an update that starts ends it', json.dumps(types(r)))
    r = page.cmd('@nativeclick:#side-q')
    check(not msgs(r, 'filterBegin') and not held(), 'filter session: none starts while an update runs', json.dumps(types(r)))
    page.cmd("@eval:sb.update({ state: 'failed', version: '10.10.10', reason: 'x' }); 0")
    r = page.cmd('@nativeclick:#side-q')
    check(msgs(r, 'filterBegin') and held(), 'filter session: one starts again once the update is over', json.dumps(types(r)))
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    page.cmd('@root:')


def list_session(page, check, T, types, opened):
    """A real click on a sidebar row asks for the writer's key panel with no field (a list session), so the arrows move through
    the tree in Quick Look too; the native side's sb.filterKey and sb.filterEnd stand in for the writer here."""
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    islist = lambda m: str(m.get('list')).lower() in ('1', 'true')
    held = lambda: page.js("return document.getElementById('side-q').classList.contains('held')")
    page.cmd('@root:' + T())
    page.render(T('README.md'))
    page.cmd('@wait:0.3')
    row = lambda p: '#side-list a.row[data-path="' + p + '"]'

    r = click(page, row(T('notes.txt')))
    check(not msgs(r, 'filterBegin') and msgs(r, 'open'), 'list session: a synthetic click opens the file but asks for no keys')
    r = page.cmd('@nativeclick:' + row(T('notes.txt')))
    fb = msgs(r, 'filterBegin')
    seq = int(fb[0]['seq']) if fb else -1
    check(len(fb) == 1 and islist(fb[0]) and 'text' not in fb[0] and 100 < float(fb[0].get('width', 0)) and 0 < float(fb[0].get('height', 0)) < 40
          and not held(), 'list session: a real click on a row asks for the key panel over the row, with no text, the field untouched', json.dumps(fb))

    def native(fn, arg):
        r = page.cmd('@eval:sb.' + fn + '(' + json.dumps(arg) + '); 0')
        w = page.cmd('@wait:0.3')
        return {'types': types(r) + types(w), 'msgs': r['messages'] + w['messages']}
    cur = lambda: page.js(CURSOR)
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    check(opened(k) and cur()['cursor'] != 'notes.txt' and cur()['cursor'] == cur()['active'], 'list session: ↓ from the writer moves on and opens the next file',
          json.dumps([opened(k), cur()['cursor']]))
    native('filterText', {'seq': seq, 'text': 'zzz'})
    check(cur()['q'] == '' and 'No matches' not in cur()['notes'], 'list session: text for it is ignored (it has no field)')
    native('filterKey', {'seq': seq, 'key': 'home'})
    first = cur()['cursor']
    k = native('filterKey', {'seq': seq, 'key': 'right'})
    expanded = [x for x in cur()['rows'] if x[0] == first]
    check(expanded and expanded[0][2] == 'true' and 'list' in k['types'], 'list session: → opens the folder under the cursor', json.dumps([first, expanded, k['types']]))
    k = native('filterKey', {'seq': seq, 'key': 'left'})
    collapsed = [x for x in cur()['rows'] if x[0] == first]
    check(collapsed and collapsed[0][2] == 'false', 'list session: ← closes it', json.dumps(collapsed))
    k = native('filterKey', {'seq': seq + 1, 'key': 'down'})
    check(cur()['cursor'] == first and not opened(k), 'list session: a key for another session is ignored')

    r = page.cmd('@nativeclick:' + row(T('data.json')))
    stops, begins = msgs(r, 'filterStop'), msgs(r, 'filterBegin')
    t = types(r)
    check([int(m['seq']) for m in stops] == [seq] and len(begins) == 1 and islist(begins[0]) and t.index('filterStop') < t.index('filterBegin'),
          'list session: a real click on another row ends it and begins a new one over that row', json.dumps(t))
    seq = int(begins[0]['seq']) if begins else -1
    r = page.cmd('@nativeclick:#side-q')
    t = types(r)
    fb = msgs(r, 'filterBegin')
    check([int(m['seq']) for m in msgs(r, 'filterStop')] == [seq] and len(fb) == 1 and not islist(fb[0]) and held(),
          'list session: a click in the filter field ends it and starts the filter', json.dumps(t))
    fseq = int(fb[0]['seq']) if fb else -1
    r = page.cmd('@nativeclick:' + row(T('notes.txt')))
    check(not msgs(r, 'filterBegin') and not msgs(r, 'filterStop') and held(), 'list session: a row clicked while the filter holds the keys keeps the filter',
          json.dumps(types(r)))
    k = native('filterKey', {'seq': fseq, 'key': 'left'})
    check(not k['types'] or 'open' not in k['types'], 'filter session: ← and → from the writer are not list keys while typing')
    native('filterEnd', {'seq': fseq})

    r = page.cmd('@nativeclick:' + row(T('sub')))
    begins = msgs(r, 'filterBegin')
    check(begins and islist(begins[0]) and 'list' in types(r) + types(page.cmd('@wait:0.3')),
          'list session: a real click on a folder opens it and holds the keys too', json.dumps(types(r)))
    seq = int(begins[0]['seq']) if begins else -1
    r = click(page, '#doc')
    check([int(m['seq']) for m in msgs(r, 'filterStop')] == [seq], 'list session: a click in the document ends it', json.dumps(types(r)))
    r = page.cmd('@nativeclick:' + row(T('README.md')))
    seq = int(msgs(r, 'filterBegin')[0]['seq'])
    native('filterEnd', {'seq': seq})
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    check(not opened(k), 'list session: the writer ends it (Esc, Space, blur), and later keys are ignored')
    r = page.cmd('@nativeclick:' + row(T('README.md')))
    seq = int(msgs(r, 'filterBegin')[0]['seq'])
    click(page, '#side-menu')
    menu = lambda: page.js("return [!document.getElementById('side-pop').hidden, document.getElementById('side-menu').getAttribute('aria-expanded')]")
    before = menu()
    native('filterEnd', {'seq': seq})
    check(before == [True, 'true'] and menu() == [False, 'false'],
          'list session: the sort menu opened during it closes when the writer ends it (Esc there never reaches the page)', json.dumps([before, menu()]))
    page.cmd('@size:600x700')
    page.cmd('@wait:0.3')
    click(page, '#side-toggle')
    page.cmd('@wait:0.4')
    r = page.cmd('@nativeclick:' + row(T('notes.txt')))
    check(not msgs(r, 'filterBegin') and msgs(r, 'open'), 'list session: none in a narrow panel, where opening a file hides the sidebar', json.dumps(types(r)))
    page.cmd('@size:1200x800')
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    page.cmd('@root:')


def auto_session(page, check, T, types, opened):
    """Quick Look showing the preview (and Esc leaving an edit or the filter) makes the extension ask for a list session no
    click began (sb.listKeysWanted with the root): the arrows then move through the sidebar and open each file in spacebar's
    view. None starts with the sidebar collapsed, hidden by a narrow panel, turned off in the settings, or with one row."""
    msgs = lambda r, t: [m for m in r['msgs'] if m.get('type') == t]
    flag = lambda m, k: str(m.get(k)).lower() in ('1', 'true')
    held = lambda: page.js("return document.getElementById('side-q').classList.contains('held')")
    cur = lambda: page.js(CURSOR)

    def native(fn, arg, wait=0.3):
        r = page.cmd('@eval:sb.' + fn + '(' + json.dumps(arg) + '); 0')
        w = page.cmd('@wait:' + str(wait))
        return {'types': types(r) + types(w), 'msgs': r['messages'] + w['messages']}

    def want(root):
        return msgs(native('listKeysWanted', {'root': root}), 'filterBegin')

    page.cmd('@root:' + T())
    page.render(T('README.md'))
    page.cmd('@wait:0.3')
    fb = want(T())
    seq = int(fb[0]['seq']) if fb else -1
    check(len(fb) == 1 and flag(fb[0], 'list') and flag(fb[0], 'auto') and 'text' not in fb[0] and 0 < float(fb[0].get('height', 0)) <= 24
          and not held(), 'auto keys: the preview appearing with the sidebar open starts a list session', json.dumps(fb))
    check(not want(T()), 'auto keys: asked again while a session holds the keys, nothing new starts')
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    c = cur()
    check(opened(k) and c['cursor'] == c['active'] and c['active'] not in (None, 'README.md'),
          "auto keys: ↓ moves to the next file and opens it in spacebar's view", json.dumps([opened(k), c['cursor'], c['active']]))
    k = native('filterKey', {'seq': seq, 'key': 'up'})
    c = cur()
    check(opened(k) == [T('README.md')] and c['active'] == 'README.md' and c['cursor'] == 'README.md', 'auto keys: ↑ goes back and opens that file',
          json.dumps([opened(k), c['cursor'], c['active']]))
    native('filterEnd', {'seq': seq})
    k = native('filterKey', {'seq': seq, 'key': 'down'})
    check(not opened(k) and not held(), 'auto keys: once Esc or Space ended it, later keys are ignored and nothing starts again on its own')

    fb = want(T('sub'))
    check(not fb, 'auto keys: a root the page does not show yet waits', json.dumps(fb))
    page.cmd('@root:' + T('sub'))
    r = page.render(T('sub', 'inner.md'))
    w = page.cmd('@wait:0.4')
    fb = [m for m in r['messages'] + w['messages'] if m.get('type') == 'filterBegin']
    check(len(fb) == 1 and flag(fb[0], 'auto'), "auto keys: it starts once that root's tree is listed", json.dumps(types(r) + types(w)))
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    page.cmd('@root:' + T())
    page.render(T('README.md'))
    page.cmd('@wait:0.3')

    page.apply(sidebarCollapsed=True)
    page.cmd('@wait:0.3')
    check(not want(T()), 'auto keys: none with the sidebar collapsed, so the arrows stay with Finder')
    page.apply(sidebarCollapsed=False)
    page.cmd('@wait:0.3')
    page.apply(sidebarKeys=False)
    check(not want(T()), 'auto keys: none with "Arrow keys move through the sidebar" off')
    page.apply(sidebarKeys=True)
    page.cmd('@size:600x700')
    page.cmd('@wait:0.3')
    check(not want(T()), 'auto keys: none in a narrow panel, where the sidebar is hidden')
    page.cmd('@size:1200x800')
    page.cmd('@wait:0.3')
    page.render(T('README.md'))
    page.cmd('@wait:0.3')
    b = page.cmd("@eval:(() => { const b = document.querySelector('#doc > [data-src]'), r = b.getBoundingClientRect();"
                 " b.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: r.left + 20, clientY: r.top + 8 })); return 0; })()")
    page.cmd('@wait:0.3')
    check(not want(T()), 'auto keys: none while an edit holds the keys', json.dumps(types(b)))
    page.cmd('@eval:sb.editEnd({}); 0')
    check(bool(want(T())), 'auto keys: once the edit ends with Esc (the extension asks again), one starts')
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')

    lone = os.path.join(os.path.dirname(T()), 'lone-auto')
    os.makedirs(lone, exist_ok=True)
    open(os.path.join(lone, 'only.md'), 'w').write('# Only\n')
    page.cmd('@root:' + lone)
    r = page.render(os.path.join(lone, 'only.md'))
    page.cmd('@wait:0.3')
    check(not want(lone), 'auto keys: none with a single row to move through')
    status = lambda: page.js("return document.getElementById('status').textContent")
    page.cmd("@eval:sb.status(''); sb.listEnded({ reason: 'click' }); 0")
    check('Press Space' not in status(), 'Quick Look: a list session ended by a click says nothing', status())
    page.cmd("@eval:sb.listEnded({ reason: 'escape' }); 0")
    check(status() == 'Press Space again to close', 'Quick Look: one ended by Esc or Space says the next Space closes', status())
    check(page.js("return [sb.hostKey({ key: 'pagedown' }), sb.hostKey({ key: 'find' }), document.documentElement.dataset.host]") == [False, False, 'quicklook'],
          "Quick Look: the page is Quick Look's, and takes no host keys", page.js("return document.documentElement.dataset.host"))
    page.cmd('@root:')


# :hover as the page's own stylesheets have it, on `sel` and its ancestors (null clears it): WebKit takes no synthetic
# mouse-moved event in the harness's window, which is off screen.
HOVER = """(sel) => {
  const rules = [];
  const walk = (list) => { for (const r of list) {
    if (r instanceof CSSStyleRule) { if (r.selectorText.includes(':hover')) rules.push(r.cssText.replaceAll(':hover', '.sb-hover')); }
    else if (r instanceof CSSImportRule) { if (r.styleSheet) walk(r.styleSheet.cssRules); }
    else if (r.cssRules) walk(r.cssRules); } };
  for (const s of document.styleSheets) { try { walk(s.cssRules); } catch (e) {} }
  const sheet = new CSSStyleSheet();
  // A page off screen gets no rendering updates, so a transition would stay at its start.
  sheet.replaceSync('* { transition: none !important; }\\n' + rules.join('\\n'));
  document.adoptedStyleSheets = sel ? [sheet] : [];
  document.querySelectorAll('.sb-hover').forEach((e) => e.classList.remove('sb-hover'));
  for (let e = sel && document.querySelector(sel); e; e = e.parentElement) e.classList.add('sb-hover');
  return rules.length; }"""
HEADER = """const h = document.getElementById('side-head'), t = document.getElementById('side-title'), g = document.getElementById('side-toggle');
  const cs = (e) => getComputedStyle(e), hr = h.getBoundingClientRect(), tr = t.getBoundingClientRect(), gr = g.getBoundingClientRect();
  const range = document.createRange(); range.selectNodeContents(t); const txt = range.getBoundingClientRect();
  const beside = document.elementFromPoint(hr.right - 12, tr.top + tr.height / 2), above = document.elementFromPoint(hr.left + hr.width / 2, 10);
  return { fill: [cs(h).backgroundColor, cs(t).backgroundColor, cs(h).backgroundImage, cs(t).backgroundImage], shadow: [cs(h).boxShadow, cs(t).boxShadow],
    cursor: [cs(h).cursor, cs(t).cursor], color: cs(t).color, outline: cs(t).outlineStyle, text: [txt.width, txt.height], box: [tr.width, tr.height],
    beside: beside && beside.id, above: above && above.id, toggle: [gr.left, gr.top + gr.height / 2], bar: parseFloat(cs(document.documentElement).getPropertyValue('--bar-h')) };"""


def calm_header(page, check, host):
    """The sidebar's heading, as Finder's and Preview's: the folder's name a plain section title with no fill in any state,
    whose click target (the overview) is its text alone; the space around it, under the traffic lights in the panel, takes no
    click and, in the panel, drags it. The sidebar button sits in the top row, centred on it, beside the traffic lights."""
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    clear = ('rgba(0, 0, 0, 0)', 'rgba(0, 0, 0, 0)', 'none', 'none')
    arrow = lambda q: q['cursor'][0] in ('auto', 'default') and q['cursor'][1] == 'default'
    idle = page.js(HEADER)
    check(tuple(idle['fill']) == clear and idle['shadow'] == ['none', 'none'] and arrow(idle),
          f'{host}: the sidebar heading has no fill, no shadow and an arrow cursor', json.dumps(idle))
    for sel, what in (('#side-head', 'the space around the folder name'), ('#side-title', 'the folder name')):
        n = page.cmd('@eval:(' + HOVER + ')(' + json.dumps(sel) + ')')['result']
        hov = page.js(HEADER)
        ok = tuple(hov['fill']) == clear and hov['shadow'] == ['none', 'none'] and arrow(hov)
        if sel == '#side-title':
            ok = ok and hov['color'] != idle['color']
            if SHOTS:
                shoot(page, f'header-{host}-hover')
        check(n and ok, f'{host}: hovering {what} fills nothing' + (', only the text brightens' if sel == '#side-title' else ''), json.dumps([n, hov]))
    page.cmd('@eval:(' + HOVER + ')(null)')
    check(idle['box'][0] <= idle['text'][0] + 2 and idle['box'][1] <= idle['text'][1] + 4 and idle['beside'] == 'side-head' and idle['above'] != 'side-title',
          f"{host}: the folder name's click target is its text alone", json.dumps(idle))
    r = click(page, '#side-head')
    page.cmd('@wait:0.3')
    check(not msgs(r, 'overview'), f'{host}: a click beside the folder name opens nothing', json.dumps([m.get('type') for m in r['messages']]))
    r = click(page, '#side-title')
    page.cmd('@wait:0.4')
    after = page.js(HEADER)
    check(msgs(r, 'overview') and tuple(after['fill']) == clear and after['outline'] == 'none',
          f'{host}: a click on the folder name opens the overview, and leaves the heading as it was', json.dumps([[m.get('type') for m in r['messages']], after]))
    if SHOTS:
        shoot(page, f'header-{host}-clicked')
    mid = idle['bar'] / 2
    # The panel centres its traffic lights, close and zoom (12 to 46 pt from the left), on the top row: ViewerPanel.rowHeight and lightsLeft.
    clear_of_lights = idle['toggle'][0] >= 46 + 8 if host == 'panel' else True
    check(abs(idle['toggle'][1] - mid) <= 2 and clear_of_lights, f'{host}: the sidebar button sits in the top row, centred on it'
          + (", the traffic lights' line, and clear of them" if host == 'panel' else ''),
          json.dumps([idle['toggle'], mid]))
    page.cmd("@eval:document.getElementById('side-toggle').click(); 0")
    page.cmd('@wait:0.4')
    folded = page.js("const g = document.getElementById('side-toggle').getBoundingClientRect(); return [document.documentElement.dataset.sidebar, g.left, g.top + g.height / 2];")
    check(folded[0] == 'collapsed' and folded[1:] == idle['toggle'], f'{host}: with the sidebar collapsed the button stays where it was', json.dumps([folded, idle['toggle']]))
    if SHOTS:
        shoot(page, f'header-{host}-collapsed')
    page.cmd("@eval:document.getElementById('side-toggle').click(); 0")
    page.cmd('@wait:0.4')
    move = lambda sel, dx, dy: page.cmd("@eval:(() => { const r = document.querySelector(" + json.dumps(sel) + ").getBoundingClientRect(), x = r.left + " + str(dx)
                                          + ", y = r.top + " + str(dy) + "; document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: x, clientY: y })); return 0; })()")
    zones = [msgs(move(sel, dx, dy), 'dragZone') for sel, dx, dy in (('#side-head', 30, 10), ('#side-title', 4, 4), ('#side-head', idle['box'][0] + 40, 50), ('#side-toggle', 8, 8), ('#doc', 40, 200))]
    want = [[True], [False], [True], [False], []] if host == 'panel' else [[]] * 5
    got = [[m.get('on') in (True, 1, 'true', '1') for m in z] for z in zones]
    check(got == want, f'{host}: ' + ('the empty heading and top row drag the panel; the folder name, the button and the page do not' if host == 'panel'
                                     else 'nothing asks to drag the window'), json.dumps(got))
    if host == 'panel':
        move('#side-head', 30, 10)
        opened = msgs(page.cmd("@eval:document.getElementById('aa').click(); 0"), 'dragZone')
        closed = msgs(page.cmd("@eval:document.getElementById('aa').click(); 0"), 'dragZone')
        on = lambda ms: [m.get('on') in (True, 1, 'true', '1') for m in ms]
        check(on(opened) == [False] and on(closed) == [True],
              'panel: with the Aa popover open the top row takes the click that closes it, checked again with the pointer still', json.dumps([opened, closed]))
        reset = msgs(page.cmd('@eval:sb.dragReset(); 0'), 'dragZone')
        check(on(reset) == [False], 'panel: a reset (the panel closing) says the pointer is over nothing', json.dumps(reset))
        long = 'A folder with a name far too long to fit in the sidebar at its width'
        w = page.js("const t = document.getElementById('side-title'), was = t.textContent; t.textContent = " + json.dumps(long)
                    + "; const r = [t.scrollWidth > t.clientWidth, t.getBoundingClientRect().right <= document.getElementById('side-head').getBoundingClientRect().right - 15, getComputedStyle(t).textOverflow]; t.textContent = was; return r;")
        check(w == [True, True, 'ellipsis'], 'panel: a long folder name is cut with an ellipsis inside the heading', json.dumps(w))


def panel_host(check):
    """The page as the Space helper's panel shows it (host "panel" in the document-start script): the traffic lights' inset,
    the list session starting on its own and driven by keys the panel sends (no writer: the helper routes Finder's keys), no
    "Press Space again" since Space and Esc close the panel in one press, and the keys the panel sends outside a list session."""
    page = Page(host='panel')
    try:
        root = os.path.join(page.out, 'panel')
        os.makedirs(os.path.join(root, 'sub'))
        long_doc = '# Long\n\n' + ''.join(f'Paragraph {i}.\n\n' for i in range(300))
        for n, t in {'README.md': long_doc, 'b.md': '# Bee\n', 'c.txt': 'see\n', 'sub/inner.md': '# Inner\n'}.items():
            open(os.path.join(root, n), 'w').write(t)
        T = lambda *p: os.path.join(root, *p)
        msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
        status = lambda: page.js("return document.getElementById('status').textContent")
        page.cmd('@size:1100x760')
        page.cmd('@root:' + root)
        page.render(T('README.md'))
        page.cmd('@wait:0.3')
        g = page.js("""const r = document.documentElement, t = document.getElementById('side-toggle').getBoundingClientRect();
          return [r.dataset.host, getComputedStyle(r).getPropertyValue('--titlebar-inset').trim(), Math.round(t.left)];""")
        check(g[0] == 'panel' and g[1] == '56px' and g[2] >= 56, "panel: the host is set at document start, and the sidebar button clears the traffic lights", json.dumps(g))
        calm_header(page, check, 'panel')
        page.render(T('README.md'))
        page.cmd('@wait:0.3')
        r = page.cmd('@eval:sb.listKeysWanted(' + json.dumps({'root': root}) + '); 0')
        fb = msgs(r, 'filterBegin') + msgs(page.cmd('@wait:0.3'), 'filterBegin')
        flag = lambda m, k: str(m.get(k)).lower() in ('1', 'true')
        check(len(fb) == 1 and flag(fb[0], 'list') and flag(fb[0], 'auto'),
              'panel: the list session starts on its own, as in Quick Look', json.dumps(fb))
        seq = int(fb[0]['seq']) if fb else -1
        r = page.cmd('@eval:sb.filterKey(' + json.dumps({'seq': seq, 'key': 'down'}) + '); 0')
        w = page.cmd('@wait:0.4')
        opened = [m.get('path') for m in msgs(r, 'open') + msgs(w, 'open')]
        check(opened == [T('b.md')], 'panel: a routed ↓ opens the next file in the sidebar', json.dumps(opened))
        page.cmd('@eval:sb.status(\'\'); sb.filterEnd({ seq: ' + str(seq) + ' }); sb.listEnded({ reason: "escape" }); 0')
        check('Press Space' not in status(), 'panel: never "Press Space again to close"', status())
        page.render(T('README.md'))
        page.cmd('@wait:0.3')
        y0 = page.js('return window.scrollY')
        used = page.js("return sb.hostKey({ key: 'pagedown' })")
        page.cmd('@wait:0.1')
        y1 = page.js('return window.scrollY')
        page.js("return sb.hostKey({ key: 'end' })")
        y2 = page.js('return window.scrollY')
        page.js("return sb.hostKey({ key: 'home' })")
        y3 = page.js('return window.scrollY')
        check(used is True and y1 > y0 and y2 > y1 and y3 == 0, 'panel: PgDn, End and Home scroll the page outside a list session', json.dumps([used, y0, y1, y2, y3]))
        check(page.js("return [sb.hostKey({ key: 'zoomIn' }), sb.hostKey({ key: 'left' }), sb.hostKey({ key: 'bogus' }), sb.hostKey(null)]") == [False] * 4,
              'panel: zoom on a document, ← and unknown keys are left to the panel')
        r = page.cmd("@eval:sb.hostKey({ key: 'find' })")
        fb = msgs(r, 'filterBegin')
        check(r['result'] in (True, 'true', 1) and len(fb) == 1 and flag(fb[0], 'find') and 'list' not in fb[0] and not page.js("return document.getElementById('find').hidden")
              and page.js("return document.getElementById('find-q').classList.contains('held')"),
              "panel: ⌘F opens find in the file and asks for the writer's key panel over its field", json.dumps([r['result'], fb]))
        seq = int(fb[0]['seq']) if fb else -1
        page.cmd('@eval:sb.filterText(' + json.dumps({'seq': seq, 'text': 'paragraph 29'}) + '); 0')
        y0 = page.js('return window.scrollY')
        page.cmd('@eval:sb.filterKey(' + json.dumps({'seq': seq, 'key': 'next'}) + '); 0')
        f = page.js("return [document.getElementById('find-count').textContent, window.scrollY, CSS.highlights.get('sb-find-cur').size]")
        check(f[0] == '2 of 11' and f[1] > y0 and f[2] == 1, 'panel: typed into the key panel, the matches are counted; ↵ goes to the next, scrolled to', json.dumps([y0, f]))
        r = page.cmd("@eval:sb.hostKey({ key: 'filter' })")
        fb = msgs(r, 'filterBegin')
        check(r['result'] in (True, 'true', 1) and len(fb) == 1 and 'list' not in fb[0] and 'find' not in fb[0] and page.js("return document.getElementById('side-q').classList.contains('held')")
              and not page.js("return document.getElementById('find-q').classList.contains('held')") and 'filterStop' in [m.get('type') for m in r['messages']],
              "panel: ⌥⌘F moves the key panel to the sidebar's filter field", json.dumps([r['result'], fb]))
        page.cmd('@eval:sb.filterEnd({ all: true }); 0')
        page.cmd("@eval:getSelection().removeAllRanges(); 0")
        r = page.cmd("@eval:sb.hostKey({ key: 'copy' })")
        c = msgs(r, '_copied')
        check(r['result'] in (True, 'true', 1) and len(c) == 1 and c[0]['text'] == long_doc, 'panel: ⌘C with nothing selected copies the whole file', json.dumps(r['result']))
        check([str(m.get('withFile')).lower() for m in msgs(r, 'copy')] in (['true'], ['1']), 'panel: ⌘C with nothing selected asks for the file beside its text, as Finder\'s ⌘C',
              json.dumps(msgs(r, 'copy'))[:200])
        page.cmd("@eval:(() => { const p = document.querySelector('#doc p'); getSelection().selectAllChildren(p); return 0; })()")
        r = page.cmd("@eval:sb.hostKey({ key: 'copy' })")
        c = msgs(r, '_copied')
        check(len(c) == 1 and c[0]['text'] == 'Paragraph 0.' and 'withFile' not in msgs(r, 'copy')[0], 'panel: ⌘C with a selection copies the selection only', json.dumps(c)[:200])
        page.cmd("@eval:getSelection().removeAllRanges(); 0")
        r = page.cmd('@nativeclick:#copy')
        check(len(msgs(r, 'copy')) == 1 and 'withFile' not in msgs(r, 'copy')[0], 'panel: the Copy button copies the text only, as it says', json.dumps(msgs(r, 'copy'))[:200])
        tip = page.js("return document.getElementById('edit').title")
        check(tip == 'Open in your editor (⌘O)', 'panel: the Open tooltip gives ⌘O, which the panel takes', tip)
        page.cmd("@eval:getSelection().removeAllRanges(); 0")
        page.cmd("@eval:document.getElementById('find-close').click(); 0")
        panel_grid(page, check, page.out)
    finally:
        page.close()
        shutil.rmtree(page.out, ignore_errors=True)


def archive_entries(page, check, out):
    """A file inside an archive, opened in place: the harness reads it as the extension does (ArchiveEntry: the writer's
    sandboxed bsdtar streaming one member to memory) and renders ArchiveEntryView's payload. Text, Markdown and an image open,
    read only; a binary and a nested archive get their info card; Back returns to the listing; names are hostile."""
    import zipfile
    d = os.path.join(out, 'arcs')
    os.makedirs(d)
    zpath = os.path.join(d, 'docs.zip')
    beside = os.path.join(d, 'beside.png')
    open(beside, 'wb').write(make_png(12, 12))
    chunk = lambda t, b: struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    huge = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 100000, 100000, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0' * 64)) + chunk(b'IEND', b'')
    with zipfile.ZipFile(zpath, 'w') as z:
        z.writestr('docs/readme.md', '# Inside\n\nA paragraph.\n\n- [ ] a task\n\n![rel](pic.png) [next](notes.txt) ![abs](spacebar://file' + beside + ')\n')
        z.writestr('img/huge.png', huge)
        z.writestr('docs/notes.txt', 'line one\nline two\n')
        z.writestr('docs/data.json', '{"k": [1, 2]}')
        z.writestr('img/pic.png', make_png(30, 20, (10, 200, 60)))
        z.writestr('bin/tool.bin', b'\0\1\2\3' * 100)
        z.writestr('nested.zip', b'PK\5\6' + b'\0' * 18)
        z.writestr('<img src=x onerror="window.__pwned=1">.txt', 'hostile name\n')
        z.writestr('*.txt', 'only the star\n')
        z.writestr('-rf.txt', 'dash\n')
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    S = """const d = document.getElementById('doc'), c = document.getElementById('crumbs');
      return { view: document.documentElement.dataset.view, crumbs: c.hidden ? null : c.textContent, back: !!d.querySelector('.viewer-back'),
        code: (d.querySelector('pre.code') || {}).textContent || null, h1: (d.querySelector('h1') || {}).textContent || null,
        note: (d.querySelector('.viewer-note') || {}).textContent || null, edit: document.getElementById('edit').hidden,
        copy: !document.getElementById('copy').hidden, img: (d.querySelector('.img-stage img') || {}).src || null,
        w: (d.querySelector('.img-stage img') || {}).naturalWidth || 0, sel: (d.querySelector('tr.arc-sel .arc-label') || {}).textContent || null,
        rows: [...d.querySelectorAll('tbody tr')].map((r) => r.querySelector('.arc-label').textContent),
        entries: [...d.querySelectorAll('.arc-entry')].length, base: document.getElementById('base').href,
        boxes: [...d.querySelectorAll('input[type=checkbox]')].map((b) => b.disabled) };"""
    st = lambda: page.js(S)

    def entry(name, wait=0.6):
        r = page.cmd("@eval:(() => { const b = [...document.querySelectorAll('#doc .arc-entry')].find((x) => x.dataset.entry === "
                     + json.dumps(name) + "); if (b) b.click(); return !!b; })()")
        w = page.cmd('@wait:' + str(wait))
        return {'found': r['result'], 'messages': r['messages'] + w['messages']}

    def back():
        r = page.cmd('@nativeclick:#doc .viewer-back')
        page.cmd('@wait:0.4')
        return r

    page.cmd('@root:' + d)
    page.render(zpath)
    page.cmd('@wait:0.4')
    a = st()
    check(a['view'] == 'archive' and a['entries'] == 10 and 'notes.txt' in a['rows'] and not page.js('return window.__pwned || null'),
          'archive entry: every file of a real listing is a button that opens it, names only ever text', json.dumps(a))

    r = entry('docs/notes.txt')
    e = st()
    check(msgs(r, 'archiveEntry') and e['view'] == 'text' and e['code'] and 'line one' in e['code'] and e['crumbs'] == '‹ docs.zip›docs/notes.txt'
          and e['back'] and e['edit'] and e['copy'], 'archive entry: a text file opens read-only, "docs.zip › docs/notes.txt", with Back and Copy, no Open',
          json.dumps([e, [m for m in r['messages'] if m['type'] != 'log']]))
    r = page.cmd('@nativeclick:#copy')
    cp = msgs(r, '_copied')
    check(len(cp) == 1 and cp[0].get('text') == 'line one\nline two\n', 'archive entry: Copy copies the text of the file inside the archive',
          json.dumps([m for m in r['messages'] if m['type'] != 'log']))
    ed = page.cmd("@eval:(() => { const p = document.querySelector('#doc pre.code'); p.dispatchEvent(new MouseEvent('click', { bubbles: true })); return 0; })()")
    check(not msgs(ed, 'editText') and not page.js("return !!document.querySelector('#doc .text-editing')"), 'archive entry: a click on its text starts no edit')

    back()
    b = st()
    check(b['view'] == 'archive' and b['sel'] == 'notes.txt' and b['crumbs'] != None and '›' not in (b['crumbs'] or '')[:2],
          'archive entry: Back returns to the listing, the file it came from selected', json.dumps(b))

    entry('docs/readme.md')
    m = st()
    absimg = page.js("const i = [...document.querySelectorAll('#doc img')].find((x) => x.alt === 'abs'); return i ? i.naturalWidth : -1")
    probe = "window.__probe = new Image(); window.__probe.src = " + json.dumps('spacebar://file' + beside) + "; 0"
    page.cmd('@eval:' + probe)
    page.cmd('@wait:0.3')
    blocked = page.js('return window.__probe.naturalWidth')
    check(m['view'] == 'markdown' and m['h1'] == 'Inside' and m['base'] == 'spacebar://entry/' and m['boxes'] == [True] and m['edit'] and absimg in (0, -1) and blocked == 0,
          'archive entry: Markdown renders, its links and images reach no file on disk, its task box is inert', json.dumps([m, absimg, blocked]))
    r = page.cmd("@eval:(() => { const p = [...document.querySelectorAll('#doc p')].find((x) => x.textContent === 'A paragraph.'); p.click(); return 0; })()")
    page.cmd('@wait:0.2')
    check(not msgs(r, 'editBlock') and not page.js("return !!document.querySelector('#doc > .md-editing')"), 'archive entry: a click on its Markdown starts no edit')
    r = page.cmd("@eval:(() => { const a = [...document.querySelectorAll('#doc a')].find((x) => x.textContent === 'next'); a.click(); return 0; })()")
    lk = msgs(r, 'link')
    check(not lk or lk[0]['href'].startswith('spacebar://entry/'), 'archive entry: a relative link points inside the entry host, never at a file beside the archive',
          json.dumps(lk))
    crumb = page.cmd("@eval:(() => { document.querySelector('#crumbs .crumb-back').click(); return 0; })()")
    page.cmd('@wait:0.3')
    fake = st()['view']
    real = page.cmd('@nativeclick:#crumbs .crumb-back')
    page.cmd('@wait:0.4')
    check(fake == 'markdown' and not msgs(crumb, 'archiveBack') and msgs(real, 'archiveBack') and st()['view'] == 'archive',
          'archive entry: the "docs.zip" crumb goes back, on a real click only', json.dumps([fake, st()['view']]))
    page.cmd('@eval:' + probe)
    page.cmd('@wait:0.3')
    check(page.js('return window.__probe.naturalWidth') == 12, 'archive entry: back at the listing, the file host serves images again')

    page.render(zpath)
    page.cmd('@wait:0.4')
    r = entry('img/pic.png', wait=1.0)
    i = st()
    again = page.js("""const x = new XMLHttpRequest(); try { x.open('GET', 'spacebar://entry/x', false); x.send(); return x.status; } catch (e) { return 'refused'; }""")
    check(i['view'] == 'image' and (i['img'] or '').startswith('blob:') and i['w'] == 30 and again == 'refused',
          'archive entry: an image loads once from its one-time URL, into a blob; any other entry URL is refused', json.dumps([i, again]))
    page.cmd("@apply:" + json.dumps({'theme': 'github'}))
    page.cmd('@wait:0.3')
    check(st()['w'] == 30, 'archive entry: a redraw keeps the image (the blob, not a second read)', json.dumps(st()['img']))

    page.render(zpath)
    page.cmd('@wait:0.4')
    entry('img/huge.png')
    hg = st()
    check(hg['view'] == 'info' and 'can’t be shown' in (hg['note'] or ''), 'archive entry: a PNG declaring 10 gigapixels is refused before WebKit decodes it', json.dumps(hg))
    back()
    entry('bin/tool.bin')
    t = st()
    check(t['view'] == 'info' and 'Only text' in (t['note'] or '') and t['back'] and t['edit'], 'archive entry: a binary is its info card, with Back', json.dumps(t))
    back()
    entry('nested.zip')
    n = st()
    check(n['view'] == 'info' and 'inside an archive' in (n['note'] or ''), 'archive entry: an archive inside is not opened', json.dumps(n))
    back()
    entry('*.txt')
    star = st()
    check(star['view'] == 'text' and star['code'] and star['code'].startswith('only the star'), 'archive entry: a file named * reads itself, not every file', json.dumps(star))
    back()
    entry('-rf.txt')
    dash = st()
    check(dash['view'] == 'info' and 'couldn’t be read' in (dash['note'] or ''), 'archive entry: a name that is an option is never passed to bsdtar', json.dumps(dash))
    back()
    entry('<img src=x onerror="window.__pwned=1">.txt')
    h = st()
    check(h['view'] == 'text' and 'hostile name' in (h['code'] or '') and not page.js('return window.__pwned || null'), 'archive entry: a hostile name opens as text',
          json.dumps(h))
    back()
    r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'archiveEntry', path: " + json.dumps(page.js('return current.path')) + ", entry: '../../etc/passwd' }); 0")
    page.cmd('@wait:0.2')
    check(msgs(r, '_entryRefused'), 'archive entry: a name the listing did not give is refused', json.dumps(r['messages']))

    # The keys: ↓ over a file shows the next file of the listing, ← goes back.
    entry('docs/data.json')
    k = dispatch_key(page, 'ArrowDown')
    page.cmd('@wait:0.4')
    nxt = st()
    dispatch_key(page, 'ArrowLeft')
    page.cmd('@wait:0.4')
    lst = st()
    dispatch_key(page, 'ArrowDown')
    after = st()
    check(nxt['crumbs'] == '‹ docs.zip›docs/notes.txt' and lst['view'] == 'archive' and lst['sel'] == 'notes.txt' and after['sel'] == 'readme.md',
          'archive entry: ↓ shows the next file, ← goes back to the listing, ↓ there moves the selection', json.dumps([nxt['crumbs'], lst['sel'], after['sel']]))
    k = dispatch_key(page, 'Enter')
    page.cmd('@wait:0.4')
    check(st()['view'] == 'markdown', 'archive entry: ↵ opens the selected file', json.dumps(st()['view']))
    kind = page.js("return document.getElementById('kind').textContent")
    check(kind.endswith(' of ' + str(page.js('return arcFiles.length'))) and ' · ' in kind, 'archive entry: the toolbar says where the file is among the archive\'s files',
          json.dumps(kind))
    dispatch_key(page, 'Backspace')
    page.cmd('@wait:0.4')
    check(st()['view'] == 'archive', 'archive entry: ⌫ goes back to the listing too', json.dumps(st()['view']))

    # A PDF inside: drawn natively from its bytes. A link inside: named, never read.
    ppath = os.path.join(d, 'papers.zip')
    with zipfile.ZipFile(ppath, 'w') as z:
        z.writestr('paper.pdf', make_pdf('inside'))
        z.writestr('broken.pdf', b'%PDF-1.4 not really')
    page.render(ppath)
    page.cmd('@wait:0.4')
    entry('paper.pdf', wait=1.0)
    pdf = page.cmd('@pdf')['result']
    check(st()['view'] == 'pdf' and st()['back'] and pdf.get('open') and pdf.get('pages') == 1 and 'inside' in (pdf.get('text') or ''),
          'archive entry: a PDF is shown, drawn from the bytes read out of the archive, with Back', json.dumps([st()['view'], pdf])[:300])
    back()
    check(not page.cmd('@pdf')['result'].get('open'), 'archive entry: Back takes the PDF view down')
    entry('broken.pdf')
    check(st()['view'] == 'info' and 'can’t be shown' in (st()['note'] or ''), 'archive entry: a PDF that does not parse is its info card', json.dumps(st()))
    lsrc = os.path.join(out, 'lsrc')
    os.makedirs(lsrc)
    open(os.path.join(lsrc, 'target.txt'), 'w').write('target\n')
    os.symlink('target.txt', os.path.join(lsrc, 'soft.txt'))
    tpath = os.path.join(d, 'links.tar')
    subprocess.run(['/usr/bin/tar', '-cf', tpath, 'target.txt', 'soft.txt'], cwd=lsrc, check=True)
    page.render(tpath)
    page.cmd('@wait:0.4')
    entry('soft.txt')
    check(st()['view'] == 'info' and 'link to another file' in (st()['note'] or ''), 'archive entry: a link inside the archive says it is a link, not an empty file',
          json.dumps(st()))
    back()
    forged = []
    entry('target.txt')
    for m in ({'type': 'openFile', 'path': tpath}, {'type': 'openWith', 'path': tpath, 'app': 'com.apple.TextEdit'}):
        r = page.cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps(m) + '); 0')
        page.cmd('@wait:0.1')
        forged += [x.get('type') for x in r['messages'] if x.get('type') in ('_openFile', '_openText', '_openWith', '_dragOut')]
    check(not forged, 'archive entry: forged Open and Open With messages do nothing while a file of the archive is shown', json.dumps(forged))

    # A lone compressed log: its text, directly.
    log = os.path.join(d, 'server.log')
    open(log, 'w').write('GET / 200\nGET /x 404\n')
    subprocess.run(['/usr/bin/gzip', log], check=True)
    page.render(log + '.gz')
    page.cmd('@wait:0.6')
    g = st()
    check(g['view'] == 'text' and (g['code'] or '').startswith('GET / 200') and not g['back'] and g['crumbs'] == 'arcs›server.log.gz',
          'archive: a lone .gz of text shows the text, not a table of one row', json.dumps(g))
    page.cmd('@root:')


def sidebar_and_folders(page, check, out):
    """The Names filter over the whole tree (folders never opened, and past a folder's 5,000), names cut in the middle, hidden
    files dimmed, empty folders, broken links skipped by the keys, clickable breadcrumbs, the way back from a photo to the grid,
    and a lone compressed log shown as its text."""
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    d = os.path.join(out, 'fixb')
    for sub in ('src/components', 'many', 'empty-folder', 'docs'):
        os.makedirs(os.path.join(d, sub))
    put = lambda n, data: open(os.path.join(d, n), 'wb' if isinstance(data, bytes) else 'w').write(data)
    put('README.md', '# Readme\n')
    put('src/components/Button.tsx', 'export const Button = 1;\n')
    put('src/components/Modal.tsx', 'export const Modal = 1;\n')
    put('docs/api-reference-for-the-authentication-service-FINAL-reviewed.md', '# API\n')
    put('.env', 'X=1\n')
    for i in range(5010):
        open(os.path.join(d, 'many', f'log-{i:05d}.txt'), 'w').close()
    os.symlink('nowhere.md', os.path.join(d, 'dangling.md'))
    D = lambda *n: os.path.join(d, *n)
    ROWS = """return { rows: [...document.querySelectorAll('#side-list a.row')].map((a) => [a.textContent, +a.getAttribute('aria-level')]),
      notes: [...document.querySelectorAll('#side-list .row-note')].map((n) => n.textContent), cursor: (document.querySelector('#side-list a.cursor') || {}).textContent || null };"""
    rows = lambda: page.js(ROWS)

    def filt(q, wait=0.6):
        r = page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = " + json.dumps(q)
                     + "; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
        w = page.cmd('@wait:' + str(wait))
        return {'messages': r['messages'] + w['messages']}

    page.cmd('@size:1100x760')
    page.cmd('@root:' + d)
    page.render(D('README.md'))
    page.cmd('@wait:0.4')

    # Names: a file in a folder never opened, with the folders on the way.
    r = filt('button')
    f = rows()
    check([x[0] for x in f['rows']] == ['src', 'components', 'Button.tsx'] and [x[1] for x in f['rows']] == [1, 2, 3] and not f['notes']
          and any(m.get('names') in ('1', 'true', True) for m in msgs(r, 'search')),
          'names: the filter finds a file in folders never opened, with its folders, like a filter result', json.dumps([f, msgs(r, 'search')]))
    r = click(page, '#side-list a.row[data-path$="/Button.tsx"]')
    page.cmd('@wait:0.4')
    check(msgs(r, 'open') and not msgs(r, '_openRefused') and page.js('return current.path') == D('src', 'components', 'Button.tsx'),
          'names: a file it found opens', json.dumps([m.get('type') for m in r['messages']]))
    filt('components')
    f = rows()
    check([x[0] for x in f['rows']][:4] == ['src', 'components', 'Button.tsx', 'Modal.tsx'],
          'names: a folder that matches by name shows what it holds while filtered', json.dumps(f))
    filt('log-05007')
    f = rows()
    check([x[0] for x in f['rows']] == ['many', 'log-05007.txt'], 'names: a file past a folder\'s 5,000 is found', json.dumps(f))
    r = click(page, '#side-list a.row[data-path$="/log-05007.txt"]')
    page.cmd('@wait:0.4')
    check(msgs(r, 'open') and not msgs(r, '_openRefused') and page.js('return current.path') == D('many', 'log-05007.txt'),
          'names: and opens, though the sidebar never listed it', json.dumps([m.get('type') for m in r['messages']]))
    filt('zzzz-nothing')
    check(rows()['notes'] == ['No matches'], 'names: nothing anywhere says No matches', json.dumps(rows()))
    filt('')

    # The folder past its cap says how to reach the rest.
    page.cmd('@eval:(() => { if (!expanded().has(' + json.dumps(D('many')) + ')) toggleFolder(' + json.dumps(D('many')) + '); return 0; })()')
    page.cmd('@wait:0.5')
    page.cmd("@eval:(() => { const l = document.getElementById('side-list'); l.scrollTop = l.scrollHeight; l.dispatchEvent(new Event('scroll')); return 0; })()")
    page.cmd('@wait:0.3')
    check(any(n.endswith(' more not listed · Filter finds them') for n in rows()['notes']), 'names: "N more not listed" says the filter finds them',
          json.dumps(rows()['notes']))
    page.cmd('@eval:(() => { if (expanded().has(' + json.dumps(D('many')) + ')) toggleFolder(' + json.dumps(D('many')) + '); return 0; })()')
    page.cmd("@eval:(() => { const l = document.getElementById('side-list'); l.scrollTop = 0; l.dispatchEvent(new Event('scroll')); return 0; })()")

    # Long names are cut in the middle; the active row keeps its weight; an empty folder says so; hidden files are dimmed.
    page.render(D('docs', 'api-reference-for-the-authentication-service-FINAL-reviewed.md'))
    page.cmd('@wait:0.4')
    page.apply(sidebarWidth=200)
    page.cmd('@wait:0.3')
    cut = page.js("""const a = document.querySelector('#side-list a.row.active'), h = a.querySelector('.nm-h'), t = a.querySelector('.nm-t');
      return [a.textContent, t && t.textContent, t && t.getBoundingClientRect().right <= a.getBoundingClientRect().right, h.scrollWidth > h.clientWidth,
        getComputedStyle(a).fontWeight];""")
    check(cut[0] == 'api-reference-for-the-authentication-service-FINAL-reviewed.md' and cut[1] == 'eviewed.md' and cut[2] and cut[3] and cut[4] == '400',
          'names: a long name is cut in the middle, its end and extension shown; the active row is not bold', json.dumps(cut))
    page.apply(sidebarWidth=240)
    page.cmd('@eval:toggleFolder(' + json.dumps(D('empty-folder')) + '); 0')
    page.cmd('@wait:0.5')
    check('Empty' in rows()['notes'], 'an open empty folder says it is empty', json.dumps(rows()))
    page.apply(showHiddenFiles=True)
    page.cmd('@relist')
    page.cmd('@wait:0.4')
    dim = page.js("""const a = [...document.querySelectorAll('#side-list a.row')].find((x) => x.dataset.path.endsWith('/.env'));
      return a && [a.classList.contains('hidden-file'), getComputedStyle(a.querySelector('.nm')).opacity];""")
    check(dim and dim[0] and float(dim[1]) < 1, 'hidden files are dimmed when shown', json.dumps(dim))
    page.apply(showHiddenFiles=False)
    page.cmd('@relist')
    page.cmd('@wait:0.3')

    # The arrows never rest on a broken link.
    page.render(D('README.md'))
    page.cmd('@wait:0.4')
    page.cmd("@eval:document.getElementById('side-list').querySelector('a.row').click(); 0")
    seen = []
    for _ in range(8):
        dispatch_key(page, 'ArrowDown')
        seen.append(rows()['cursor'])
    check('dangling.md' not in seen and seen[-1], 'keys: the arrows skip a broken link', json.dumps(seen))

    # Breadcrumbs: the root shows the overview, a folder opens in the sidebar.
    page.render(D('src', 'components', 'Modal.tsx'))
    page.cmd('@wait:0.4')
    crumbs = page.js("return [...document.querySelectorAll('#crumbs .crumb')].map((c) => [c.tagName, c.textContent, c.title])")
    check([c[0] for c in crumbs] == ['BUTTON', 'BUTTON', 'BUTTON', 'SPAN'] and crumbs[0][2] == crumbs[0][1] + '\nShow the folder overview',
          'crumbs: every step but the file is a button', json.dumps(crumbs))
    page.cmd('@eval:(() => { if (expanded().has(' + json.dumps(D('src')) + ')) toggleFolder(' + json.dumps(D('src')) + '); return 0; })()')
    r = page.cmd("@eval:(() => { [...document.querySelectorAll('#crumbs button.crumb')][1].click(); return 0; })()")
    page.cmd('@wait:0.4')
    check(rows()['cursor'] == 'src' and page.js("return [...document.querySelectorAll('#side-list a.row.open')].some((a) => a.dataset.path.endsWith('/src'))"),
          'crumbs: a folder step opens it in the sidebar and moves the cursor to it', json.dumps(rows()['cursor']))
    r = page.cmd("@eval:(() => { document.querySelector('#crumbs button.crumb').click(); return 0; })()")
    page.cmd('@wait:0.5')
    check(msgs(r, 'overview') and page.js('return current.view') == 'overview', 'crumbs: the root step shows the folder overview',
          json.dumps([m.get('type') for m in r['messages']]))

    # Back from a photo to the grid: a button, ⌫ and ←.
    photos = os.path.join(out, 'fixb-photos')
    os.makedirs(photos)
    for i in range(8):
        open(os.path.join(photos, f'p{i}.png'), 'wb').write(make_png(30, 20))
    r = page.cmd('@folder:' + photos)
    page.cmd('@wait:0.6')
    for key in ('Backspace', 'ArrowLeft', None):
        page.cmd(f"@eval:(() => {{ gridOpen({json.dumps(os.path.join(photos, 'p2.png'))}); return 0; }})()")
        page.cmd('@wait:0.5')
        head = page.js("return [current.view, (document.querySelector('#doc .viewer-back') || {}).textContent || null]")
        if key:
            k = dispatch_key(page, key)
        else:
            k = page.cmd('@nativeclick:#doc .viewer-back')
        page.cmd('@wait:0.5')
        sel = page.js("return [gridShown(), (document.querySelector('#doc a.gt.sel') || {}).dataset?.path || null]")
        check(head == ['image', '‹ fixb-photos'] and msgs(k, 'overview') and sel == [True, os.path.join(photos, 'p2.png')],
              f'grid: from a photo, {key or "the Back button"} goes back to the grid, the photo\'s tile selected', json.dumps([head, sel, [m.get('type') for m in k['messages']]]))
    page.cmd('@root:')

def drag_openwith_diff(check):
    """0.4: a file dragged out of the panel (only a listed row, an overview row or the file on screen, and only from a press still
    under way; never in Quick Look), the toolbar's Open With menu (the apps LinkPolicy.openWithApps offers, the default first;
    nothing for a script; an app not offered refused), and diffs tinted line by line in a .diff, a .patch and a ```diff fence."""
    page = Page(host='panel')
    ql = None
    try:
        root = os.path.join(page.out, 'dragroot')
        os.makedirs(os.path.join(root, 'sub'))
        patch = ('diff --git a/x.py b/x.py\nindex 1..2 100644\n--- a/x.py\n+++ b/x.py\n@@ -1,3 +1,3 @@ def main():\n context\n'
                 '-removed line\n+added line\n@@ -9 +9 @@\n--- a removed SQL comment\n--- one\n+kept\n--- old\n+++ new\n---\n')
        files = {'a.txt': 'alpha\n', 'b.md': '# Bee\n\n```diff\n@@ -1 +1 @@\n-old\n+new\n```\n', 'run.sh': '#!/bin/sh\necho hi\n',
                 'x.diff': patch, 'y.patch': patch, '.hid.txt': 'hidden\n', 'sub/in.txt': 'in\n'}
        for n, t in files.items():
            open(os.path.join(root, n), 'w').write(t)
        os.symlink('/etc/hosts', os.path.join(root, 'out.txt'))
        T = lambda *p: os.path.join(root, *p)
        msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
        row = lambda n: f'#side-list a.row[data-path="{T(n)}"]'
        page.cmd('@size:1100x760')
        page.cmd('@root:' + root)
        page.render(T('b.md'))
        page.cmd('@wait:0.3')

        # ---- drag out ----
        r = page.cmd(f'@nativedrag:{row("a.txt")},60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        d, ok = msgs(r, 'dragOut'), msgs(r, '_dragOut')
        check([m.get('path') for m in d] == [T('a.txt')] and len(ok) == 1 and ok[0]['path'] == T('a.txt') and ok[0]['refusal'] == 'the button is up',
              'drag out: a press that moves on a file row asks the viewer to drag that file; the web view holds the press, and with no button down no drag starts', json.dumps(r['messages'])[:400])
        check(not msgs(r, 'open') and page.js("return document.querySelector('#side-list a.active').dataset.path") == T('b.md'),
              'drag out: the press a drag began with opens nothing', json.dumps([m.get('type') for m in r['messages']]))
        r = page.cmd(f'@nativedrag:{row("a.txt")},2')
        check(not msgs(r, 'dragOut'), 'drag out: a press that barely moves is a click, not a drag', json.dumps([m.get('type') for m in r['messages']]))
        r = page.cmd(f'@nativedrag:{row("sub")},60')
        check(not msgs(r, 'dragOut'), 'drag out: a folder row is not dragged', json.dumps([m.get('type') for m in r['messages']]))
        forged = [T('.hid.txt'), T('out.txt'), '/etc/hosts', T('sub', 'in.txt'), root, T('sub', '..', 'a.txt')]
        r = page.cmd('@eval:' + ';'.join(f"window.webkit.messageHandlers.sb.postMessage({{ type: 'dragOut', path: {json.dumps(p)} }})" for p in forged) + '; 0')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check([m.get('path') for m in msgs(r, '_dragRefused')] == forged and not msgs(r, '_dragOut'),
              'drag out: a path the sidebar did not list (hidden, a link out of the root, outside it, in a closed folder, the root, not plain) is refused',
              json.dumps(r['messages'])[:400])
        page.render(T('a.txt'))
        page.cmd('@wait:0.3')
        r = page.cmd('@nativedrag:#kind,60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check([m.get('path') for m in msgs(r, '_dragOut')] == [T('a.txt')], "drag out: the toolbar's kind drags the file on screen", json.dumps(r['messages'])[:300])

        # ---- Open With ----
        check(not page.js("return document.getElementById('open-with').hidden"), 'Open With: the chevron shows beside Open for a text file')
        r = page.cmd('@eval:document.getElementById("open-with").click(); 0')
        check(not msgs(r, 'openWithList'), 'Open With: a script-made click asks for nothing')
        r = page.cmd('@nativeclick:#open-with')
        listed = (msgs(r, '_openWithList') or [{}])[0].get('apps', [])
        listed = json.loads(listed) if isinstance(listed, str) else listed
        menu = page.js("""const p = document.getElementById('ow-pop');
          return [p.hidden, [...p.querySelectorAll('button[data-app]')].map((b) => b.dataset.app), (p.querySelector('button') || {}).textContent || '',
            p.querySelectorAll('.ow-sep').length, document.getElementById('open-with').getAttribute('aria-expanded')];""")
        check(listed and not menu[0] and menu[1] == listed and menu[2].endswith('(default)') and len(listed) <= 12 and menu[4] == 'true'
              and menu[3] == (1 if len(listed) > 1 else 0) and 'com.apple.Terminal' not in listed,
              'Open With: the menu lists the apps the writer offers, the default first and marked, at most 12', json.dumps([listed, menu]))
        if len(listed) > 1:
            r = page.cmd(f'@nativeclick:#ow-pop button[data-app="{listed[1]}"]')
            w = msgs(r, 'openWith')
            check(len(w) == 1 and w[0].get('app') == listed[1] and w[0].get('path') == T('a.txt') and msgs(r, '_openWith')
                  and page.js("return document.getElementById('ow-pop').hidden"),
                  'Open With: choosing an app opens the file in it, and the menu closes', json.dumps(r['messages'])[:300])
        page.cmd('@nativeclick:#open-with')
        r = page.cmd('@nativeclick:#doc')
        check(page.js("return document.getElementById('ow-pop').hidden") and not msgs(r, 'openWith'), 'Open With: a click elsewhere only closes the menu')
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'openWith', path: " + json.dumps(T('a.txt')) + ", app: 'com.apple.Terminal' }); 0")
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check(msgs(r, '_openWithRefused') and not msgs(r, '_openWith'), 'Open With: an app the menu did not offer (Terminal) is refused', json.dumps(r['messages'])[:300])
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'openWithList', path: " + json.dumps(T('run.sh')) + " }); 0")
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check(msgs(r, '_openWithRefused') and not msgs(r, '_openWithList'), 'Open With: a file not on screen is refused', json.dumps(r['messages'])[:300])
        page.render(T('run.sh'))
        page.cmd('@wait:0.3')
        r = page.cmd('@nativeclick:#open-with')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        none = page.js("return [document.getElementById('ow-pop').hidden, document.querySelectorAll('#ow-pop button[data-app]').length, document.querySelector('#ow-pop .ow-none')?.textContent]")
        check(msgs(r, '_openWithRefused') and not msgs(r, '_openWithList') and none[0] is False and none[1] == 0 and none[2],
              'Open With: a script is refused, and the menu says nothing else may open it', json.dumps([r['messages'], none])[:300])
        page.cmd('@nativeclick:#open-with')
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'openWith', path: " + json.dumps(T('run.sh')) + ", app: 'com.apple.TextEdit' }); 0")
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check(msgs(r, '_openWithRefused') and not msgs(r, '_openWith'), 'Open With: a script never opens in another app, not even an editor, this way', json.dumps(r['messages'])[:300])
        page.render(T('b.md'))
        page.cmd('@wait:0.3')
        r = page.cmd('@nativeclick:#open-with')
        check(not page.js("return document.getElementById('open-with').hidden") and msgs(r, '_openWithList'), 'Open With: offered for Markdown too')
        page.cmd('@nativeclick:#open-with')

        # ---- diffs ----
        DIFF = """const pick = (sel) => { const n = document.querySelector(sel); if (!n) return null; const cs = getComputedStyle(n);
            return [n.textContent, cs.display, cs.backgroundColor, cs.color, Math.round(n.getBoundingClientRect().width)]; };
          const box = document.querySelector('#doc pre.code, #doc pre code')?.closest('pre');
          return { add: pick('#doc .hljs-addition'), del: pick('#doc .hljs-deletion'), meta: [...document.querySelectorAll('#doc .hljs-meta')].map((n) => n.textContent),
            comment: [...document.querySelectorAll('#doc .hljs-comment')].map((n) => n.textContent), dels: [...document.querySelectorAll('#doc .hljs-deletion')].map((n) => n.textContent),
            width: box ? Math.round(box.getBoundingClientRect().width) : 0, fg: getComputedStyle(document.body).color };"""
        alpha = lambda c: c and c != 'rgba(0, 0, 0, 0)' and c != 'transparent'
        for name in ('x.diff', 'y.patch'):
            page.render(T(name))
            page.cmd('@wait:0.3')
            d = page.js(DIFF)
            check(d['add'] and d['add'][0] == '+added line' and d['add'][1] == 'inline-block' and alpha(d['add'][2]) and d['del'][0] == '-removed line'
                  and alpha(d['del'][2]) and d['add'][2] != d['del'][2] and d['add'][4] > d['width'] * 0.8,
                  f'diff: {name} tints each added and removed line across the block', json.dumps(d))
            check(d['meta'] == ['@@ -1,3 +1,3 @@ def main():', '@@ -9 +9 @@'] and d['comment'][:4] == ['diff --git a/x.py b/x.py', 'index 1..2 100644', '--- a/x.py', '+++ b/x.py']
                  and '--- a removed SQL comment' in d['dels'] and '--- one' in d['dels'] and '--- old\n+++ new' in d['comment'] and '---' in d['comment'],
                  f'diff: {name} hunk headers (with or without counts) are one dimmed token, file headers quiet, a removed "-- one" still removed', json.dumps(d))
        e = page.js("const pre = document.querySelector('#doc pre.code'); pre.classList.add('text-editing'); const d = getComputedStyle(pre.querySelector('.hljs-addition')).display; pre.classList.remove('text-editing'); return d;")
        check(e == 'inline', 'diff: while the file is edited the tint is inline, so the caret after a line is drawn at its end', e)
        page.render(T('b.md'))
        page.cmd('@wait:0.3')
        d = page.js(DIFF)
        check(d['add'] and d['add'][0] == '+new' and d['add'][1] == 'inline-block' and d['del'][0] == '-old' and d['meta'] == ['@@ -1 +1 @@'],
              'diff: a ```diff fence in Markdown is tinted the same way', json.dumps(d))
        seen = []
        for theme in THEMES:
            for look in ('light', 'dark'):
                page.cmd('@appearance:' + look)
                page.apply(theme=theme)
                page.render(T('x.diff'))
                page.cmd('@wait:0.2')
                d = page.js(DIFF)
                ok = d['add'] and alpha(d['add'][2]) and alpha(d['del'][2]) and d['add'][2] != d['del'][2] and d['add'][3] != d['del'][3] and d['add'][3] != d['fg']
                seen.append(ok)
                if not ok:
                    check(False, f'diff: {theme} {look}', json.dumps(d))
        check(all(seen) and len(seen) == 2 * len(THEMES), f'diff: added and removed lines tinted apart in all {len(THEMES)} themes, light and dark')
        page.cmd('@appearance:auto')
        page.apply(theme='apple')

        # ---- Quick Look: no drag out ----
        ql = Page()
        ql.cmd('@size:1100x760')
        ql.cmd('@root:' + root)
        ql.render(T('b.md'))
        ql.cmd('@wait:0.3')
        r = ql.cmd(f'@nativedrag:{row("a.txt")},60')
        r['messages'] += ql.cmd('@wait:0.2')['messages']
        check(not msgs(r, 'dragOut') and not msgs(r, '_navigation'), 'drag out: Quick Look drags nothing out, and a row is not dragged as a link',
              json.dumps([m.get('type') for m in r['messages']]))
    finally:
        page.close()
        shutil.rmtree(page.out, ignore_errors=True)
        if ql:
            ql.close()
            shutil.rmtree(ql.out, ignore_errors=True)


def release_interactions(check):
    """0.4's features together, in the panel: a grid tile and a Contents result drag out (the result from a folder never opened,
    as the search found it) while nothing inside an archive does; while the grid is on screen a filter session's arrows move
    through the results, not the tiles; a file inside an archive has no Open With and its diff is tinted."""
    import zipfile
    page = Page(host='panel')
    try:
        root = os.path.join(page.out, 'mix')
        photos = os.path.join(root, 'Photos')
        os.makedirs(os.path.join(photos, 'deep'))
        for i in range(8):
            open(os.path.join(photos, f'p{i}.png'), 'wb').write(make_png(30 + i, 20))
        open(os.path.join(photos, 'deep', 'note.txt'), 'w').write('a wombat lives here\n')
        zpath = os.path.join(root, 'arc.zip')
        with zipfile.ZipFile(zpath, 'w') as z:
            z.writestr('fix.diff', '--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n')
            z.writestr('notes.txt', 'plain\n')
        msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
        P = lambda n: os.path.join(photos, n)
        page.cmd('@size:1100x760')

        # ---- the grid and the search ----
        r = page.cmd('@folder:' + photos)
        page.cmd('@wait:0.6')
        check(r['result'] == 'overview' and page.js('return gridShown()'), 'together: the folder of pictures opens on its grid', r['result'])
        r = page.cmd(f'@nativedrag:#doc .ov-grid a.gt[data-path="{P("p1.png")}"],60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check([m.get('path') for m in msgs(r, '_dragOut')] == [P('p1.png')] and not msgs(r, 'open'),
              'together: a grid tile drags its picture out, and the press opens nothing', json.dumps(r['messages'])[:300])
        click(page, '#side-mode [data-mode=contents]')
        page.cmd("@eval:(() => { const q = document.getElementById('side-q'); q.value = 'wombat'; q.dispatchEvent(new Event('input', { bubbles: true })); return 0; })()")
        for _ in range(40):
            page.cmd('@wait:0.05')
            if page.js("return document.querySelectorAll('#side-list a.row.hit').length"):
                break
        hit = P(os.path.join('deep', 'note.txt'))
        check(page.js("return [...document.querySelectorAll('#side-list a.row.hit')].map((a) => a.dataset.path)") == [hit] and page.js('return gridShown()'),
              'together: a Contents search with the grid on screen finds the file in a folder under it, the grid stays')
        page.cmd('@nativeclick:#side-q')
        sel = page.js("return (document.querySelector('#doc a.gt.sel') || {}).dataset?.path || null")
        seq = page.js('return filterSession && !filterSession.list ? filterSession.seq : null')
        r = page.cmd(f"@eval:sb.filterKey({{ seq: {json.dumps(seq)}, key: 'down' }}); 0")
        r['messages'] += page.cmd('@wait:0.4')['messages']
        after = page.js("return (document.querySelector('#doc a.gt.sel') || {}).dataset?.path || null")
        check(seq is not None and after == sel and [m.get('path') for m in msgs(r, 'open')] == [hit],
              "together: with the grid on screen the filter session's ↓ moves through the results, not the tiles", json.dumps([seq, sel, after, r['messages']])[:300])
        page.cmd('@eval:sb.filterEnd({ all: true }); 0')
        r = page.cmd(f'@nativedrag:#side-list a.row.hit[data-path="{hit}"],60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check([m.get('path') for m in msgs(r, '_dragOut')] == [hit], 'together: a Contents result drags out, from a folder the sidebar never opened',
              json.dumps(r['messages'])[:300])
        click(page, '#side-mode [data-mode=names]')

        # ---- a file inside an archive ----
        page.cmd('@root:' + root)
        page.render(zpath)
        page.cmd('@wait:0.4')
        r = page.cmd('@nativedrag:#doc .arc-entry[data-entry="notes.txt"],60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check(not msgs(r, 'dragOut'), 'together: a file in an archive listing does not drag out', json.dumps([m.get('type') for m in r['messages']]))
        page.cmd("@eval:(() => { document.querySelector('#doc .arc-entry[data-entry=\"fix.diff\"]').click(); return 0; })()")
        page.cmd('@wait:0.6')
        tint = page.js("""const a = document.querySelector('#doc .hljs-addition'), d = document.querySelector('#doc .hljs-deletion');
          return [document.documentElement.dataset.view, a && a.textContent, a && getComputedStyle(a).display, d && getComputedStyle(d).backgroundColor,
            a && getComputedStyle(a).backgroundColor, !!current.entry];""")
        check(tint[0] == 'code' or tint[0] == 'text', 'together: the diff inside the archive opens', json.dumps(tint))
        check(tint[1] == '+new' and tint[2] == 'inline-block' and tint[3] != tint[4] and tint[5], 'together: a diff inside an archive is tinted line by line', json.dumps(tint))
        check(page.js("return [document.getElementById('edit').hidden, document.getElementById('open-with').hidden]") == [True, True],
              'together: a file inside an archive has no Open and no Open With')
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'openWithList', path: " + json.dumps(zpath) + " }); 0")
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check(msgs(r, '_openWithRefused') and not msgs(r, '_openWithList'), 'together: Open With is refused while a file inside the archive is shown',
              json.dumps(r['messages'])[:300])
        r = page.cmd('@nativedrag:#kind,60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check(not msgs(r, 'dragOut'), "together: the toolbar's kind drags nothing out while a file inside the archive is shown",
              json.dumps([m.get('type') for m in r['messages']]))
        page.cmd('@nativeclick:#doc .viewer-back')
        page.cmd('@wait:0.4')
        r = page.cmd('@nativedrag:#kind,60')
        r['messages'] += page.cmd('@wait:0.2')['messages']
        check([m.get('path') for m in msgs(r, '_dragOut')] == [zpath], "together: back at the listing, the kind drags the archive itself",
              json.dumps(r['messages'])[:300])

        # With the sidebar collapsed, the archive's own key session outlives the renders it causes.
        page.apply(sidebarCollapsed=True)
        page.render(zpath)
        page.cmd('@wait:0.4')
        page.cmd('@nativeclick:#doc .arc-entry[data-entry="fix.diff"]')
        page.cmd('@wait:0.5')
        seq = page.js('return filterSession && filterSession.arc ? filterSession.seq : null')
        one = page.js('return [current.entry && current.entry.name, !!(filterSession && filterSession.arc)]')
        page.cmd(f"@eval:sb.filterKey({{ seq: {json.dumps(seq)}, key: 'down' }}); 0")
        page.cmd('@wait:0.5')
        two = page.js('return [current.entry && current.entry.name, !!(filterSession && filterSession.arc)]')
        check(seq is not None and one == ['fix.diff', True] and two == ['notes.txt', True],
              "together: with the sidebar collapsed, the archive keeps its keys: a click opens a file, ↓ the next", json.dumps([seq, one, two]))
        page.apply(sidebarCollapsed=False)
        page.cmd('@root:')
    finally:
        page.close()
        shutil.rmtree(page.out, ignore_errors=True)


def missing_images(page, check, out):
    """Images that did not load: a placeholder with the alt text, the path as written and why (the extension's ImageCheck); its
    Reveal folder only for a real click on the page's own button; a remote image blocked or failing; a missing image that
    appears renders."""
    d = os.path.join(out, 'imgs')
    os.makedirs(os.path.join(d, 'media'))
    open(os.path.join(d, 'here.png'), 'wb').write(make_png(40, 30))
    open(os.path.join(d, 'bad.png'), 'w').write('not a png\n')
    open(os.path.join(d, 'notes.txt'), 'w').write('text\n')
    doc = os.path.join(d, 'doc.md')
    open(doc, 'w').write('# Images\n\n![Here](here.png)\n\n![Wispr Flow Insights](media/wispr-insights.png)\n\n![](nofolder/gone.png)\n\n'
                         '<img src="media/raw.png" alt="Raw">\n\n![Bad](bad.png)\n\n![Text](notes.txt)\n\n![Remote](https://127.0.0.1:9/r.png)\n\n'
                         '<div class="forged"><button class="img-reveal" type="button">Reveal folder</button>\n'
                         '<span class="img-missing"><button class="img-reveal" data-action="reveal">Reveal folder</button></span></div>\n')
    boxes = """return [...document.querySelectorAll('#doc .img-missing')].filter((b) => !b.closest('.forged')).map((b) => [
      (b.querySelector('.img-missing-alt') || {}).textContent || '', (b.querySelector('.img-missing-path') || {}).textContent || '',
      [...b.querySelectorAll('.img-missing-why > *')].map((n) => n.textContent), !!b.querySelector(':scope > svg.ic')]);"""
    natural = "return [...document.querySelectorAll('#doc img')].map((i) => [i.getAttribute('src'), i.naturalWidth]);"
    types = lambda r: [m.get('type') for m in r['messages']]
    page.cmd('@root:')
    r = page.render(doc)
    w = page.cmd('@wait:1')
    b = page.js(boxes)
    check(b[:3] == [['Wispr Flow Insights', 'media/wispr-insights.png', ['Not found', 'Reveal folder'], True],
                    ['', 'nofolder/gone.png', ['Not found'], True], ['Raw', 'media/raw.png', ['Not found', 'Reveal folder'], True]],
          'missing image: a placeholder with its glyph, alt text, path as written, "Not found", and Reveal folder when the folder exists (inline <img> too)',
          json.dumps(b))
    check(b[3:] == [['Bad', 'bad.png', ['Unsupported format', 'Reveal folder'], True], ['Text', 'notes.txt', ['Unsupported format', 'Reveal folder'], True]],
          'an image that is there but cannot be shown, or is not an image: "Unsupported format"', json.dumps(b[3:]))
    reveal = HELPERS + """const b = document.querySelector('#doc p .img-missing .img-reveal'), box = b.closest('.img-missing');
      return measure(root, getComputedStyle(b).color, ['var(--bg)', getComputedStyle(box).backgroundColor]);"""
    for mode in ('light', 'dark'):
        page.cmd('@appearance:' + mode)
        rv = page.js(reveal)
        check(rv['ratio'] >= 4.5, f'missing image ({mode}): Reveal folder reaches 4.5:1 on the placeholder as drawn', json.dumps(rv))
    page.cmd('@appearance:light')
    check(page.js(natural) == [['here.png', 40]] and len([t for t in types(r) + types(w) if t == 'imageStatus']) == 1,
          'an image that is there still renders, and the page asks about the failed ones once', json.dumps([page.js(natural), types(r) + types(w)]))
    check(page.js("return [...document.querySelectorAll('#doc .img-blocked')].map((n) => n.querySelector('.img-alt').textContent)") == ['Remote'],
          'remote images off: the remote image keeps its blocked placeholder and load button')
    page.js("document.querySelector('#doc .forged').scrollIntoView({ block: 'center' }); return 0")
    rs = [click(page, '#doc p .img-missing .img-reveal'), page.cmd('@nativeclick:#doc .forged > button.img-reveal'),
          page.cmd('@nativeclick:#doc .forged .img-missing .img-reveal')]
    check(all(x['result'] is True for x in rs) and not [t for x in rs for t in types(x) if 'eveal' in (t or '')],
          'Reveal folder: a synthetic click, and buttons of the document dressed as it, reveal nothing',
          json.dumps([types(x) for x in rs]))
    page.js("document.querySelector('#doc p .img-missing').scrollIntoView({ block: 'center' }); return 0")
    r = page.cmd('@nativeclick:#doc p .img-missing .img-reveal')
    got = [m for m in r['messages'] if m.get('type') in ('revealImageFolder', '_revealFolder', '_revealRefused')]
    check([m['type'] for m in got] == ['revealImageFolder', '_revealFolder'] and got[1]['path'].endswith('/imgs/media')
          and got[1]['path'] == os.path.dirname(got[0]['path']),
          'Reveal folder: a real click on the page\'s own button reveals the image\'s folder', json.dumps(got))
    r = page.cmd("@eval:post({ type: 'revealImageFolder', doc: current.path, path: '/etc/x.png' }); post({ type: 'revealImageFolder', doc: '/tmp/other.md', path: "
                 + json.dumps(os.path.join(d, 'media', 'x.png')) + " }); 0")
    check(types(r).count('_revealRefused') == 2 and '_revealFolder' not in types(r), 'Reveal folder: the extension reveals only a folder its answer found, for this document',
          json.dumps(types(r)))
    hint = page.js("""const b = [...document.querySelectorAll('#doc p .img-missing')][1];
      imageReason(b, '/x/nofolder/gone.png', { reason: 'missing', folder: false, suggest: 'Gone.PNG' });
      return [...b.querySelectorAll('.img-missing-why > *')].map((n) => n.textContent);""")
    check(hint == ['Not found', 'Did you mean Gone.PNG?'], 'a name that differs only in case: "Did you mean …?"', json.dumps(hint))

    page.apply(remoteImages=True)
    page.cmd('@wait:1.5')
    rb = page.js("""const b = [...document.querySelectorAll('#doc .img-missing')].find((n) => n.title.startsWith('https:'));
      return b && [b.querySelector('.img-missing-alt').textContent, [...b.querySelectorAll('.img-missing-why > *')].map((n) => n.textContent)];""")
    check(rb == ['Remote', ['Couldn’t load', '127.0.0.1']] and not page.js("return document.querySelectorAll('#doc .img-blocked').length"),
          'remote images on: a remote image that fails shows its host and "Couldn\'t load"', json.dumps(rb))
    page.apply(remoteImages=False)

    shutil.copy(os.path.join(d, 'here.png'), os.path.join(d, 'media', 'wispr-insights.png'))
    w = page.cmd('@wait:1.5')
    after = page.js(natural)
    check('_imagesAppeared' in types(w) and ['media/wispr-insights.png', 40] in after and page.js(boxes)[0][1] == 'nofolder/gone.png',
          'live reload: a missing image that appears in its folder replaces its placeholder', json.dumps([types(w), after]))
    os.makedirs(os.path.join(d, 'nofolder'))
    page.cmd('@wait:0.5')
    shutil.copy(os.path.join(d, 'here.png'), os.path.join(d, 'nofolder', 'gone.png'))
    w = page.cmd('@wait:1.5')
    check(['nofolder/gone.png', 40] in page.js(natural), 'live reload: an image whose folder did not exist yet, once both appear', json.dumps(types(w)))


GRID = """const g = document.querySelector('#doc .ov-grid'), tiles = [...document.querySelectorAll('#doc a.gt')];
  const box = g && g.getBoundingClientRect();
  return { view: document.documentElement.dataset.view, grid: !!g, attr: document.documentElement.hasAttribute('data-grid'),
    list: !!document.querySelector('#doc .ov-list, #doc .ov-counts'), tiles: tiles.length, loaded: document.querySelectorAll('#doc a.gt img.ld').length,
    height: g ? g.offsetHeight : 0, names: tiles.map((t) => t.querySelector('.gt-name').textContent),
    sel: (document.querySelector('#doc a.gt.sel .gt-name') || {}).textContent || null,
    lefts: [...new Set(tiles.map((t) => t.offsetLeft))].length,
    top: tiles.length ? Math.min(...tiles.map((t) => t.offsetTop)) : -1, bottom: tiles.length ? Math.max(...tiles.map((t) => t.offsetTop)) : -1,
    pressed: [...document.querySelectorAll('#doc .ov-views button')].map((b) => [b.dataset.folderView, b.getAttribute('aria-pressed')]) };"""


def folder_grid(page, check, out):
    """A folder mostly of images and video opens on a grid of thumbnails; any other folder keeps the overview. The toggle in the
    folder view's header switches grid and list, remembered for each kind of folder; the arrows move in two dimensions and
    Return or a double-click opens the image; only the tiles in view are in the page, and only their thumbnails are made, by
    the `thumb` host, which serves a file the sidebar listed and nothing else."""
    msgs = lambda r, t: [m for m in r['messages'] if m.get('type') == t]
    grid = lambda: page.js(GRID)
    fx = os.path.join(out, 'grid')
    photos, code, big = (os.path.join(fx, n) for n in ('Photos', 'code', 'many'))
    for d in (photos, code, big, os.path.join(photos, 'sub')):
        os.makedirs(d)
    for i in range(30):
        open(os.path.join(photos, f'p{i:02d}.png'), 'wb').write(make_png(60 + i, 40, (20 + i * 7, 120, 200)))
    open(os.path.join(photos, 'README.md'), 'w').write('# Photos\n')
    open(os.path.join(photos, 'notes.txt'), 'w').write('notes\n')
    open(os.path.join(photos, 'sub', 'hidden.png'), 'wb').write(make_png(10, 10))
    for i in range(8):
        open(os.path.join(code, f'm{i}.ts'), 'w').write(f'export const x{i} = {i};\n')
    for i in range(5):
        open(os.path.join(code, f'shot{i}.png'), 'wb').write(make_png(20, 20))
    one = make_png(24, 16, (90, 160, 90))
    for i in range(5000):
        open(os.path.join(big, f'img-{i:04d}.png'), 'wb').write(one)
    P = lambda n: os.path.join(photos, n)
    thumb_url = lambda p: 'spacebar://thumb/' + urllib.parse.quote(p, safe='') + '?s=256'

    # ---- which folders open on the grid ----
    r = page.cmd('@folder:' + photos)
    page.cmd('@wait:0.6')
    g = grid()
    check(r['result'] == 'overview' and g['grid'] and g['attr'] and not g['list'] and g['names'][:3] == ['README.md', 'notes.txt', 'p00.png']
          and g['pressed'] == [['grid', 'true'], ['list', 'false']],
          'grid: a folder mostly of images opens on its grid, not its README', json.dumps([r['result'], g]))
    check(g['loaded'] >= 20 and g['lefts'] >= 3, 'grid: the thumbnails in view fill in, in several columns', json.dumps([g['loaded'], g['lefts']]))
    shoot(page, 'grid')
    r = page.cmd('@folder:' + code)
    page.cmd('@wait:0.4')
    g = grid()
    check(r['result'] == 'overview' and not g['grid'] and g['list'] and not g['attr'] and g['pressed'] == [['grid', 'false'], ['list', 'true']],
          'grid: a folder of code (a third of it images) keeps the overview', json.dumps([r['result'], g]))

    # ---- the toggle, remembered per kind of folder ----
    r = click(page, '#doc .ov-views button[data-folder-view=grid]')
    page.cmd('@wait:0.4')
    g = grid()
    written = [m.get('patch') for m in msgs(r, '_written')]
    check(g['grid'] and g['tiles'] == 13 and written == ['{"folderViewOther":"grid"}'], 'grid: the toggle shows any folder as a grid, and saves it for its kind',
          json.dumps([written, g['tiles']]))
    r = click(page, '#doc .ov-views button[data-folder-view=list]')
    page.cmd('@wait:0.3')
    check(not grid()['grid'] and [m.get('patch') for m in msgs(r, '_written')] == ['{"folderViewOther":"list"}'], 'grid: and back to the list')
    page.cmd('@folder:' + photos)
    page.cmd('@wait:0.3')
    r = click(page, '#doc .ov-views button[data-folder-view=list]')
    page.cmd('@wait:0.3')
    g = grid()
    check(not g['grid'] and g['list'] and [m.get('patch') for m in msgs(r, '_written')] == ['{"folderViewMedia":"list"}'],
          'grid: a folder of images can be a list', json.dumps(g))
    page.cmd('@apply:' + json.dumps({'folderViewMedia': 'list'}))
    r = page.cmd('@folder:' + photos)
    check(r['result'] == 'file:' + P('README.md'), 'grid: with its kind set to list, a folder of images opens its README again', r['result'])
    page.cmd('@apply:' + json.dumps({'folderViewMedia': 'grid'}))
    r = page.cmd('@folder:' + photos)
    page.cmd('@wait:0.4')
    check(r['result'] == 'overview' and grid()['grid'], 'grid: and set back to grid, its grid')

    # ---- keys: 2D arrows, Home, End, Return; a double-click ----
    cols = grid()['lefts']
    files = page.js('return grid.entries.map((e) => e.name)')
    seq = []
    for k in ('ArrowRight', 'ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'End', 'ArrowUp', 'Home'):
        dispatch_key(page, k)
        seq.append(grid()['sel'])
    n = len(files)
    want = [files[0], files[1], files[1 + cols], files[cols], files[0], files[n - 1], files[n - 1 - cols], files[0]]
    check(seq == want, f'grid: the arrows move in two dimensions ({cols} columns), Home and End to the ends', json.dumps([seq, want]))
    kept = [dispatch_key(page, k, **m)['result'] for k, m in ((' ', {}), ('Escape', {}), ('ArrowRight', {'metaKey': True}))]
    check(kept == ['false'] * 3 and grid()['sel'] == files[0], 'grid: Space, Esc and ⌘-arrows are left to Quick Look and the panel', json.dumps(kept))
    r = dispatch_key(page, 'ArrowDown')
    r = page.cmd('@eval:(() => { const e = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }); document.body.dispatchEvent(e); return 0; })()')
    w = page.cmd('@wait:0.5')
    opened = [m.get('path') for m in msgs(r, 'open') + msgs(w, 'open')]
    check(opened == [P(files[cols])] and page.js("return document.documentElement.dataset.view") == 'image',
          'grid: Return opens the image in the viewer', json.dumps(opened))
    click(page, '#side-title')
    page.cmd('@wait:0.5')
    check(grid()['grid'] and grid()['sel'] == files[cols], "grid: the folder's name brings the grid back, the same tile selected", json.dumps(grid()['sel']))
    r = page.cmd("""@eval:(() => { const t = [...document.querySelectorAll('#doc a.gt')].find((a) => a.textContent === 'p03.png');
      t.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, detail: 1 }));
      t.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, detail: 2 })); return 0; })()""")
    w = page.cmd('@wait:0.5')
    check([m.get('path') for m in msgs(r, 'open') + msgs(w, 'open')] == [P('p03.png')] and page.js("return document.documentElement.dataset.view") == 'image',
          'grid: a double-click opens the image', json.dumps([m.get('type') for m in r['messages'] + w['messages']]))
    click(page, '#side-title')
    page.cmd('@wait:0.5')

    # The list session the preview starts on its own drives the grid, as the helper's and the writer's keys arrive.
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    r = page.cmd('@eval:sb.listKeysWanted(' + json.dumps({'root': photos}) + '); 0')
    fb = msgs(r, 'filterBegin') + msgs(page.cmd('@wait:0.2'), 'filterBegin')
    sq = int(fb[0]['seq']) if fb else -1
    page.cmd('@eval:sb.filterKey({ seq: ' + str(sq) + ', key: "home" }); sb.filterKey({ seq: ' + str(sq) + ', key: "down" }); sb.filterKey({ seq: ' + str(sq) + ', key: "right" }); 0')
    s1 = grid()['sel']
    r = page.cmd('@eval:sb.filterKey({ seq: ' + str(sq) + ', key: "return" }); 0')
    w = page.cmd('@wait:0.5')
    opened = [m.get('path') for m in msgs(r, 'open') + msgs(w, 'open')]
    check(len(fb) == 1 and s1 == files[cols + 1] and opened == [P(files[cols + 1])],
          'grid: the keys of the list session (↓ → ↵) drive the grid, not the sidebar', json.dumps([fb, s1, opened]))
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')

    # With the sidebar collapsed, the session the preview asks for as it opens waits for the grid to be drawn (the listing comes
    # first), and ends when the grid goes: the keys never drive a sidebar that is not on screen.
    flag = lambda m, k: str(m.get(k)).lower() in ('1', 'true')
    page.cmd('@apply:' + json.dumps({'sidebarCollapsed': True}))
    page.cmd('@folder:' + code)
    page.cmd('@wait:0.3')
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    r0 = page.cmd('@eval:sb.listKeysWanted(' + json.dumps({'root': photos}) + '); 0')
    r = page.cmd('@folder:' + photos)
    w = page.cmd('@wait:0.4')
    fb = msgs(r0, 'filterBegin') + msgs(r, 'filterBegin') + msgs(w, 'filterBegin')
    sq = int(fb[0]['seq']) if fb else -1
    page.cmd('@eval:sb.filterKey({ seq: ' + str(sq) + ', key: "home" }); sb.filterKey({ seq: ' + str(sq) + ', key: "right" }); sb.filterKey({ seq: ' + str(sq) + ', key: "right" }); 0')
    s1 = grid()['sel']
    r = page.cmd('@eval:sb.filterKey({ seq: ' + str(sq) + ', key: "return" }); 0')
    w = page.cmd('@wait:0.5')
    stops = [m.get('seq') for m in msgs(r, 'filterStop') + msgs(w, 'filterStop')]
    check(len(fb) == 1 and flag(fb[0], 'auto') and s1 == files[2] and stops == [str(sq)],
          'grid: with the sidebar collapsed the grid takes the keys once drawn, and lets them go when it goes', json.dumps([fb, s1, stops]))
    page.cmd('@apply:' + json.dumps({'sidebarCollapsed': False}))
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')

    # ---- only listed files, and only images and video ----
    page.cmd('@folder:' + photos)
    page.cmd('@wait:0.4')
    probe = """(() => { window.__probe = {}; for (const [k, u] of Object.entries(URLS)) { const i = new Image();
      i.onload = () => { window.__probe[k] = i.naturalWidth; }; i.onerror = () => { window.__probe[k] = 'error'; }; i.src = u; } return 0; })()"""
    urls = {'listed': thumb_url(P('p01.png')), 'notMedia': thumb_url(P('notes.txt')), 'notListed': thumb_url(os.path.join(photos, 'sub', 'hidden.png')),
            'outside': thumb_url('/etc/hosts'), 'otherRoot': thumb_url(os.path.join(code, 'shot0.png')),
            'dotdot': thumb_url(photos + '/sub/../p01.png'), 'relative': 'spacebar://thumb/p01.png?s=256', 'noSize': 'spacebar://thumb/' + urllib.parse.quote(P('p01.png'), safe=''),
            'huge': 'spacebar://thumb/' + urllib.parse.quote(P('p01.png'), safe='') + '?s=99999'}
    r = page.cmd('@eval:' + probe.replace('URLS', json.dumps(urls)))
    w = page.cmd('@wait:0.8')
    got = page.js('return window.__probe')
    refused = [m.get('msg', '') for m in msgs(r, '_refused') + msgs(w, '_refused')]
    check(isinstance(got, dict) and got.get('listed', 0) > 0 and all(got.get(k) == 'error' for k in urls if k != 'listed') and len(refused) == len(urls) - 1,
          'grid: the thumb host serves a listed image only: not a text file, one no listing named, one outside the root, a .. path, a bad size',
          json.dumps([got, refused]))

    # ---- 5,000 images: only the tiles in view are in the page, and only their thumbnails are made ----
    page.cmd('@thumbs:purge')
    before = page.cmd('@thumbs')['result']
    r = page.cmd('@folder:' + big)
    w = page.cmd('@wait:0.8')
    g = grid()
    after = page.cmd('@thumbs')['result']
    made = after['made'] - before['made']
    rows = -(-5000 // g['lefts'])
    check(r['result'] == 'overview' and g['grid'] and 0 < g['tiles'] <= 120 and g['height'] > rows * 100 and 0 < made <= g['tiles'],
          'grid: 5,000 images: a few rows of tiles in the page, the grid as tall as all of them, thumbnails made only for those',
          json.dumps({'tiles': g['tiles'], 'height': g['height'], 'made': made, 'cols': g['lefts']}))
    first = [m['msg'] for m in msgs(r, 'log') + msgs(w, 'log') if m.get('msg', '').startswith('grid first row')]
    ms = int(first[0].split()[3][:-2]) if first else 9999
    check(ms <= 150, 'grid: the first row fills within 150 ms, thumbnails made on demand', first[0] if first else 'no timing logged')
    page.cmd('@eval:window.scrollTo(0, document.querySelector(".ov-grid").offsetHeight / 2); 0')
    page.cmd('@wait:0.5')
    g = grid()
    mid = page.js("""const t = [...document.querySelectorAll('#doc a.gt')].map((a) => +a.textContent.slice(4, 8)); return [Math.min(...t), Math.max(...t)];""")
    check(g['tiles'] <= 120 and 2000 < mid[0] < mid[1] < 3000, 'grid: scrolled halfway, the tiles in the page are those halfway', json.dumps([g['tiles'], mid]))
    # A fast scroll through the whole grid, forty screens in one go: the tiles passed over are dropped before they load.
    s0 = page.cmd('@thumbs')['result']
    page.cmd("""@eval:(() => { const h = document.querySelector('.ov-grid').offsetHeight;
      for (let i = 1; i <= 40; i++) { window.scrollTo(0, h * i / 41); gridWindow(); } return 0; })()""")
    page.cmd('@wait:1.0')
    s1 = page.cmd('@thumbs')['result']
    made = s1['made'] - s0['made']
    # A load already under way when its tile went may finish: at most one round of loads more than the last screen.
    check(made <= grid()['tiles'] + 8 and s1['pending'] == 0, 'grid: scrolled through 5,000 images at once, only the last screen of thumbnails is made',
          json.dumps({'made': made, 'tiles': grid()['tiles']}))
    # Thumbnails slow to make (150 ms each): a scroll past tiles still loading stops their loads, and what is queued is never made.
    page.cmd('@thumbs:slow=0.15')
    page.cmd('@eval:window.scrollTo(0, 0); 0')
    page.cmd('@wait:0.1')
    s0 = page.cmd('@thumbs')['result']
    stops = 0
    for i in range(1, 16):
        rr = page.cmd(f'@eval:window.scrollTo(0, document.querySelector(".ov-grid").offsetHeight * {i / 32}); 0')
        ww = page.cmd('@wait:0.05')
        stops += len(msgs(rr, '_thumbStop') + msgs(ww, '_thumbStop'))
    ww = page.cmd('@wait:2.5')
    stops += len(msgs(ww, '_thumbStop'))
    s1 = page.cmd('@thumbs')['result']
    made, dropped = s1['made'] - s0['made'], s1['dropped'] - s0['dropped'] + s1['abandoned'] - s0['abandoned']
    check(stops > 0 and dropped > 0 and made < 15 * 8 and s1['pending'] == 0 and s1['peak'] <= 6,
          'grid: scrolling past thumbnails being made stops their loads; the dropped ones are never made, six at a time at most',
          json.dumps({'made': made, 'stops': stops, 'dropped': dropped, 'peak': s1['peak']}))
    page.cmd('@thumbs:slow=0')
    loaded = page.js("return [...document.querySelectorAll('#doc a.gt')].filter((a) => a.querySelector('img.ld')).length")
    check(loaded == grid()['tiles'], 'grid: after the scroll, every tile in view has its thumbnail', json.dumps([loaded, grid()['tiles']]))
    page.cmd('@eval:window.scrollTo(0, 0); 0')


def panel_grid(page, check, root):
    """In the Space helper's panel the arrows arrive as named keys outside a list session (sb.hostKey): they drive the grid."""
    fx = os.path.join(root, 'shots')
    os.makedirs(fx)
    for i in range(12):
        open(os.path.join(fx, f's{i:02d}.png'), 'wb').write(make_png(30, 20))
    r = page.cmd('@folder:' + fx)
    page.cmd('@wait:0.5')
    page.cmd('@eval:sb.filterEnd({ all: true }); 0')
    used = page.js("return [sb.hostKey({ key: 'right' }), sb.hostKey({ key: 'right' }), sb.hostKey({ key: 'down' })]")
    cols = page.js('return grid.cols')
    sel = page.js("return (document.querySelector('#doc a.gt.sel .gt-name') || {}).textContent")
    r2 = page.cmd("@eval:sb.hostKey({ key: 'return' })")
    w = page.cmd('@wait:0.4')
    opened = [m.get('path') for m in r2['messages'] + w['messages'] if m.get('type') == 'open']
    check(r['result'] == 'overview' and used == [True] * 3 and sel == f's{1 + cols:02d}.png' and opened == [os.path.join(fx, sel or '')],
          'panel: the arrows and Return the helper sends drive the grid', json.dumps([r['result'], used, cols, sel, opened]))


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
        folder_html = folder_html.replace(' arrive', '')
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
        tn = page.js(TASK_NAMES)
        check(tn['unique'] and tn['names'] == [['one', 'one'], ['two', 'two']], 'task checkboxes are named by their items with the sidebar open', json.dumps(tn))
        r = page.cmd("@eval:(() => { const b = document.querySelector('#doc input[type=checkbox]'); b.click(); return 0; })()")
        tg = [m for m in r['messages'] if m.get('type') == 'toggle']
        check(tg and tg[0].get('line') == '4' and tg[0].get('checked') in ('1', 'true'), 'a task toggle posts with the sidebar open', json.dumps(tg))
        r = click(page, '#sidebar')
        check(not {'editBlock', 'editStop', 'open', 'link'} & set(types(r)), 'a click on the sidebar background does nothing', json.dumps(types(r)))
        click(page, '#doc > p')
        r = click(page, '#sidebar')
        check('editStop' in types(r) and not st()['editing'], 'a click in the sidebar ends the edit', json.dumps(types(r)))
        click(page, '#doc > p')
        r = click(page, '#side-list a.row:not([data-dir])')
        t = types(r)
        check('editStop' in t and t.index('editStop') < (t.index('open') if 'open' in t else len(t)) and not st()['editing'],
              'a click on a sidebar file ends the edit before anything opens', json.dumps(t))

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
                      'data.json': 'ic-data', 'table.csv': 'ic-data', 'notes.txt': 'ic-text', 'blob.dat': 'ic-other', 'tool': 'ic-app',
                      'movie.mp4': 'ic-video', 'song.wav': 'ic-audio', 'movie.webm': 'ic-video'}
        check(all(icons.get(k) == v for k, v in want_icons.items()), 'tree: every row has its type icon',
              json.dumps({k: icons.get(k) for k in want_icons}))
        check(not {'etc', 'up', 'hosts.txt', '.secret.md', '...', '..txt'} & set(names) and 'notes..v2.txt' in names,
              'tree: links to /etc, to the parent and to /etc/hosts, hidden files and dot names are left out',
              json.dumps(names))
        dangling = page.js("""const r = [...document.querySelectorAll('#side-list a.row')].find((a) => a.dataset.path.endsWith('/dangling.md'));
          return r && [r.classList.contains('broken'), r.title, r.getAttribute('aria-disabled'), getComputedStyle(r).opacity];""")
        r = click(page, '#side-list a.row.broken')
        check(dangling and dangling[0] and dangling[1].startswith('dangling.md\nBroken link → ') and dangling[2] == 'true' and float(dangling[3]) < 1
              and not [m for m in r['messages'] if m.get('type') == 'open'],
              'tree: a dangling link is listed greyed, as a broken link, and a click opens nothing', json.dumps(dangling))
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
        keys_and_filter(page, check, T, st, types)
        view(T('sub', 'deep', 'deepest.txt'))
        click(page, '#side-list a.row[data-path$="/many"]')
        page.cmd('@wait:0.4')
        big_folder(page, check, T)
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
        im = page.js("const i = document.querySelector('#doc .viewer-image img'); return i && [i.naturalWidth, i.src.startsWith('spacebar://file/'), document.getElementById('kind').textContent]")
        check(im and im[0] > 0 and im[1] and '×' in im[2] and st()['view'] == 'image', 'image: fitted, with its dimensions and size', json.dumps(im))
        check(page.js("const i = document.querySelector('#doc .viewer-image img'); const r = i.getBoundingClientRect(); return r.height <= innerHeight && r.width <= document.getElementById('doc').clientWidth"),
              'image: never larger than the panel')
        r = view(T('code.ts'))
        c = page.js("""return { kw: document.querySelectorAll('#doc .code-view .hljs-keyword').length, gutter: document.querySelector('#doc .gutter').textContent.split('\\n').length,
          text: document.querySelector('#doc pre.code').textContent, edit: (() => { const e = document.getElementById('edit');
            return [getComputedStyle(e).display !== 'none', e.textContent, e.dataset.kind, getComputedStyle(document.querySelector('#doc .viewer-head .viewer-open')).display]; })(), stats: document.getElementById('stats').textContent,
          kind: document.getElementById('kind').textContent, button: document.querySelector('#doc button.viewer-open').textContent }""")
        check(c['kind'].startswith('TypeScript · ') and c['button'] == 'Open', '.ts is named as TypeScript; it opens as text in an editor, never as a video', json.dumps(c))
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({type:'openFile', path: " + json.dumps(T('code.ts')) + "}); 0")
        page.cmd('@wait:0.1')
        check('_openText' in [m.get('type') for m in r['messages'] + page.cmd('@eval:0')['messages']], 'openFile for a .ts file goes to the text opener, not its default app')
        check(c['kw'] > 0 and c['gutter'] == 6 and c['text'] == open(T('code.ts')).read() and c['edit'] == [True, 'Open', 'file', 'none']
              and c['stats'] == '',
              'code: highlighted, with line numbers; the toolbar offers the viewer\'s action (not "Open in editor"), the viewer\'s own button moves there', json.dumps({k: v for k, v in c.items() if k != 'text'}))
        page.apply(stats=True)
        page.cmd('@wait:0.2')
        on = page.js("return [document.getElementById('stats').textContent, getComputedStyle(document.getElementById('stats'), '::before').content]")
        page.apply(stats=False)
        check(on == ['6 lines', '"· "'], 'code: with reading stats turned on, the line count follows the kind in the toolbar', json.dumps(on))

        # ---- the Space helper's hint: one quiet line in the status area, a click opens Settings, gone on the next file ----
        HINT = "const s = document.getElementById('status'); return [s.textContent, 'hint' in s.dataset, getComputedStyle(s).cursor]"
        page.cmd("@eval:sb.helperHint({ state: 'notRunning' }); 0")
        h1 = page.js(HINT)
        r = click(page, '#status')
        o = [m for m in r['messages'] if m.get('type') == 'openSettings']
        h2 = page.js(HINT)
        page.cmd('@eval:sb.helperHint(); 0')
        view(T('README.md'))
        h3 = page.js(HINT)
        page.cmd('@eval:sb.status("Copied"); sb.helperHint(); 0')
        h4 = page.js(HINT)
        page.cmd('@eval:sb.status(""); 0')
        page.cmd("@eval:sb.helperHint({ state: 'paused', app: '<b>Terminal</b>' }); 0")
        h5 = page.js(HINT + ".concat([document.querySelector('#status b') === null])")
        page.cmd("@eval:document.getElementById('status').click(); 0")
        page.cmd("@eval:sb.helperHint({ state: 'paused', app: '' }); 0")
        h6 = page.js(HINT)
        check(h5[0] == 'Space helper paused while <b>Terminal</b> has secure input onSettings…' and h5[3] and h6[0] == 'Space helper paused: another app has secure input onSettings…',
              'Space helper hint: paused by secure input names the app, as text, or says another app', json.dumps([h5, h6]))
        check(h1 == ['Space helper isn’t runningSettings…', True, 'pointer'] and [x.get('tab') for x in o] == ['general'] and h2 == ['', False, 'auto']
              and h3 == ['', False, 'auto'] and h4[:2] == ['Copied', False],
              'Space helper hint: one line; a click opens Settings and takes it down; the next file clears it; it never covers another status',
              json.dumps([h1, o, h2, h3, h4]))
        view(T('code.ts'))
        r = click(page, '#doc pre.code')
        check('editBlock' not in [m.get('type') for m in r['messages']] and 'editText' in [m.get('type') for m in r['messages']]
              and not page.js("return document.querySelector('#doc .md-editing')"), 'code: a click edits the whole file, not a Markdown block')
        page.cmd('@eval:sb.editEnd({}); 0')
        view(T('data.json'))
        tree_rows = page.js("return [...document.querySelectorAll('#doc .json-tree .jt-row')].map((r) => r.textContent)")
        click(page, '#raw')
        raw = page.js("return [document.querySelector('#doc pre.code').textContent, document.getElementById('raw').getAttribute('aria-pressed'), document.querySelectorAll('#doc .json-all').length]")
        click(page, '#raw')
        again = page.js("return [...document.querySelectorAll('#doc .json-tree .jt-row')].map((r) => r.textContent)")
        check(tree_rows[:3] == ['▾{ 3 keys }', '"name": "spacebar"', '▾"list": [ 2 items ]']
              and raw == [open(T('data.json')).read(), 'true', 0] and again == tree_rows and page.js("return document.querySelectorAll('#doc .hljs-attr').length") > 0,
              "JSON: the tree; the toolbar's Raw shows the file as is, without the tree's buttons, and back", json.dumps([tree_rows, raw[1:]])[:300])
        for name, text in (('scalar.json', '"just a string"\n'), ('broken.json', '{"a": 1,,}\n')):
            open(T(name), 'w').write(text)
            view(T(name))
            sc = page.js("return [!!document.querySelector('#doc .json-tree'), (document.querySelector('#doc pre.code') || {}).textContent, document.getElementById('raw').hidden, document.querySelectorAll('#doc .viewer-head button:not(.viewer-open)').length]")
            check(sc == [False, text, True, 0], f'JSON: {name} is its text, with no Raw to switch and no tree buttons', json.dumps(sc))
            os.remove(T(name))
        view(T('table.csv'))
        t = page.js("return [[...document.querySelectorAll('#doc table.csv thead th')].map((x) => x.textContent), [...document.querySelectorAll('#doc table.csv tbody tr')].map((r) => [...r.cells].map((c) => c.textContent))]")
        check(t == [['', 'name', 'qty', 'note'], [['1', 'apple', '3', 'red, crisp'], ['2', 'pear', '5', 'says "hi"'], ['3', 'fig', '', 'line one\nline two']]],
              'CSV: a table, first row as header, row numbers, quotes, commas and newlines in cells', json.dumps(t))
        view(T('big.csv'))
        b = page.js("""const s = document.querySelector('#doc .csv-scroll'); return [document.querySelectorAll('#doc table.csv tbody tr:not(.pad)').length,
          [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent), document.querySelector('#doc table.csv').getAttribute('aria-rowcount'),
          s.scrollHeight > 1500 * 20]""")
        check(b[0] < 200 and b[1] == [] and b[2] == '1501' and b[3], 'CSV: 1,500 rows, all there, only those in view drawn', json.dumps(b))
        view(T('wide.csv'))
        wc = page.js("return [document.querySelectorAll('#doc table.csv thead th').length, document.querySelectorAll('#doc table.csv tbody td').length, [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
        check(wc == [201, 200, ['Showing the first 200 columns.']], 'CSV: capped at 200 columns with a note', json.dumps(wc))
        view(T('forged.md'))
        r = page.cmd('@nativeclick:#doc .viewer button')
        r2 = page.cmd('@nativeclick:#doc .viewer button + button')
        check(page.js("return !!document.querySelector('#doc .viewer button')") and not [m for m in r['messages'] + r2['messages'] if m.get('type') in ('reveal', 'openFile', '_reveal', '_openFile')],
              "a Markdown document's look-alike viewer buttons reveal and open nothing")
        page.cmd('@eval:sb.editEnd({}); 0')
        view(T('notes.txt'))
        check(page.js("return [document.querySelector('#doc pre.code').textContent, document.querySelectorAll('#doc pre.code span').length]") == [open(T('notes.txt')).read(), 0],
              'text: shown as is (wrapped by default)')
        view(T('huge.log'))
        h = page.js("return [document.querySelector('#doc pre.code').textContent.length, [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent)]")
        check(2 * 1024 * 1024 - 100 <= h[0] <= 2 * 1024 * 1024 and h[0] % 100 == 0 and h[1] == ['Showing the last 2 MB of 3.1 MB.'],
              'a log over 2 MB: its last 2 MB from a whole line, with a note', json.dumps(h))
        text_editing(page, check, page.out, view, T)
        r = view(T('blob.dat'))
        card = page.js("""const c = document.querySelector('#doc .info-card'); return c && { name: c.querySelector('.info-name').textContent,
          dt: [...c.querySelectorAll('dt')].map((x) => x.textContent), size: c.querySelector('dd').textContent, icon: !!c.querySelector('svg.ic'),
          button: c.querySelector('button').textContent, action: c.querySelector('button').dataset.action }""")
        check(card and card['name'] == 'blob.dat' and card['dt'] == ['Size', 'Modified', 'Where'] and card['size'] == '4.1 KB (4,096 bytes)'
              and card['icon'] and card['button'] == 'Reveal in Finder', 'other: an info card with icon, name, kind, size and date; unknown data only reveals',
              json.dumps(card))
        # The card's own button is Minimal chrome's; the toolbar row has Open instead.
        page.apply(minimalChrome=True)
        r = click(page, '#doc .info-card button')
        synthetic = [m for m in r['messages'] if m.get('type') in ('reveal', 'openFile')]
        r = page.cmd('@nativeclick:#doc .info-card button')
        page.apply(minimalChrome=False)
        check(not synthetic and [m.get('type') for m in r['messages'] if m.get('type', '').startswith('_')] == ['_reveal'] and
              [m for m in r['messages'] if m.get('type') == 'reveal'][0].get('path') == T('blob.dat'),
              'Reveal in Finder posts reveal for the file on screen, for a real click only', json.dumps(r['messages'])[:300])
        # A file still being read (an iCloud download): a quiet "Loading…" with no Open button, then, when it could not be
        # downloaded, the info card with Reveal in Finder, for a Markdown file too.
        stub = {'path': T('notes.md'), 'base': 'spacebar://file' + tree + '/', 'name': 'notes.md', 'root': tree, 'rootName': os.path.basename(tree), 'reason': 'open',
                'folder': '~/Projects/tree'}
        page.cmd('@eval:sb.render(' + json.dumps(dict(stub, view='loading', cloud=True)) + '); 0')
        ld = page.js("""const l = document.querySelector('#doc .viewer-loading'); const s = l && l.querySelector('.spinner');
          return l && { view: document.documentElement.dataset.view, role: l.getAttribute('role'), text: l.querySelector('.loading-text').textContent,
            note: l.querySelector('.viewer-note').textContent, anim: getComputedStyle(s).animationName, buttons: document.querySelectorAll('#doc button').length,
            edit: document.getElementById('edit').hidden }""")
        check(ld and ld['view'] == 'loading' and ld['role'] == 'status' and ld['text'] == 'Loading…' and ld['note'] == 'Downloading from iCloud'
              and 'sb-spin' in ld['anim'] and ld['buttons'] == 0 and ld['edit'], 'loading: "Loading…" with a spinner, no buttons, no Open', json.dumps(ld))
        page.cmd('@eval:sb.render(' + json.dumps(dict(stub, view='info', icon='markdown', kindName='Markdown', canOpen=False, size=1010,
                                                     note='This file is in iCloud and couldn’t be downloaded.')) + '); 0')
        card = page.js("""const c = document.querySelector('#doc .info-card'); return c && [c.querySelector('.viewer-note').textContent,
          c.querySelector('button').textContent, c.querySelector('button').dataset.action]""")
        page.apply(minimalChrome=True)
        r = page.cmd('@nativeclick:#doc .info-card button')
        page.apply(minimalChrome=False)
        check(card == ['This file is in iCloud and couldn’t be downloaded.', 'Reveal in Finder', 'reveal']
              and [m.get('path') for m in r['messages'] if m.get('type') == 'reveal'] == [T('notes.md')],
              'iCloud: the card for a file that could not be downloaded, with Reveal in Finder (a Markdown file too)', json.dumps([card, r['messages']])[:300])
        view(T('movie.webm'))
        r = page.cmd("@eval:sb.setOpener({ path: " + json.dumps(T('movie.webm')) + ", app: 'QuickTime Player' }); 0")
        b = page.js("return [document.querySelector('#doc .info-card button').textContent, document.querySelector('#doc .info-card button').dataset.action]")
        page.apply(minimalChrome=True)
        r = page.cmd('@nativeclick:#doc .info-card button')
        page.apply(minimalChrome=False)
        check(b == ['Open with QuickTime Player', 'openFile'] and '_openFile' in [m.get('type') for m in r['messages']],
              'a document the link policy allows: "Open with <default app>", through the writer', json.dumps(b))
        view(T('tool'))
        b = page.js("return document.querySelector('#doc button.viewer-open').textContent")
        check(b == 'Reveal in Finder', 'tool: a binary executable only reveals', b)
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({type:'openFile', path: " + json.dumps(T('tool')) + "}); 0")
        page.cmd('@wait:0.1')
        check('_openRefused' in [m.get('type') for m in r['messages'] + page.cmd('@eval:0')['messages']], 'openFile for a binary executable is refused')
        for f in ('run.sh',):
            view(T(f))
            b = page.js("return [document.querySelector('#doc button.viewer-open').textContent, document.getElementById('edit').textContent, document.getElementById('edit').dataset.action]")
            page.cmd('@eval:sb.setOpener(' + json.dumps({'path': T(f), 'app': 'TextEdit', 'editor': True}) + '); 0')
            named = page.js("return [document.querySelector('#doc button.viewer-open').textContent, document.getElementById('edit').textContent, document.getElementById('edit').title]")
            check(b == ['Open', 'Open', 'openFile'] and named == ['Open in TextEdit', 'Open', 'Open in TextEdit'],
                  f'{f}: an executable or a script opens as text in the editor ("Open in <editor>"), never in its default app', json.dumps([b, named]))
            r = page.cmd('@nativeclick:#edit')
            check('_openText' in [m.get('type') for m in r['messages']] and '_openFile' not in [m.get('type') for m in r['messages']],
                  f'{f}: the toolbar button posts openFile, which goes to the text opener', json.dumps(r['messages'])[:200])
        page.cmd('@eval:sb.setOpener(' + json.dumps({'path': T('run.sh'), 'app': 'Terminal'}) + '); 0')
        check(page.js("return [document.getElementById('edit').textContent, document.getElementById('edit').title]") == ['Open', 'Open with Terminal'],
              'an opener that is not an editor is named "Open with" (the writer never names Terminal for a script)')
        view(T('data.json'))
        page.cmd('@eval:sb.setOpener(' + json.dumps({'path': T('data.json'), 'app': 'Xcode', 'editor': False}) + '); 0')
        check(page.js("return [document.getElementById('edit').textContent, document.getElementById('edit').title]") == ['Open', 'Open with Xcode'],
              'JSON with no editor chosen: "Open", and "Open with <default app>" in its tooltip')
        # ---- PDF: a native PDFView over the page's PDF area; no WebKit plugin, no frame, no unlabelled buttons ----
        PDF_AREA = "const r = document.querySelector('#doc .pdf-area').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]"
        near = lambda a, b: a and b and len(a) == len(b) and all(abs(x - y) <= 1 for x, y in zip(a, b))
        r = view(T('doc.pdf'))
        page.cmd('@wait:0.5')
        pdf = page.cmd('@pdf')['result']
        area = page.js(PDF_AREA)
        check(pdf['open'] and pdf['placed'] and not pdf['hidden'] and pdf['above'] and pdf['inContainer'] and near(pdf['frame'], area)
              and area[0] >= 240 and 40 <= area[1] <= 42 and area[1] + area[3] == 800 - EDGE,
              'PDF: a native view laid exactly over the area the page reserves, right of the sidebar and under the breadcrumb',
              f"frame {pdf.get('frame')} area {area}")
        check(pdf['pages'] == 1 and pdf['text'] == 'Hello PDF' and pdf['autoScales'] and pdf['continuous'] and pdf.get('pixel')
              and pdf['pixel'][2] > 200 and pdf['pixel'][0] < 60, 'PDF: PDFKit draws it, fitted, as continuous pages', json.dumps(pdf))
        doc = page.js("""const d = document.getElementById('doc'); return { frames: document.querySelectorAll('iframe, embed, object').length,
          buttons: [...d.querySelectorAll('button')].map((b) => [b.textContent, b.dataset.action]), aa: document.getElementById('aa').hidden,
          crumbs: !document.getElementById('crumbs').hidden, side: getComputedStyle(document.getElementById('sidebar')).visibility,
          scroll: document.scrollingElement.scrollHeight <= innerHeight }""")
        check(doc == {'frames': 0, 'buttons': [['Open', 'openFile']], 'aa': True, 'crumbs': True, 'side': 'visible', 'scroll': True}
              and not [m for m in r['messages'] if m.get('type') in ('_frame', '_navigation')],
              'PDF: no frame or plugin; one labelled Open button through the writer; sidebar and breadcrumb stay', json.dumps(doc))
        r = page.cmd('@nativeclick:#edit')
        check('_openFile' in [m.get('type') for m in r['messages']] and page.js("return document.getElementById('edit').textContent") == 'Open',
              'PDF: the toolbar Open button posts openFile, checked like any viewer', json.dumps(r['messages'])[:200])
        page.cmd('@eval:sb.setOpener(' + json.dumps({'path': T('doc.pdf'), 'app': 'Preview'}) + '); 0')
        page.cmd("@eval:(() => { const q = JSON.parse(JSON.stringify(current)); delete q.app; q.reason = 'change'; sb.render(q); })(); 0")
        page.cmd('@wait:0.3')
        again = page.js("return [document.getElementById('edit').textContent, document.getElementById('edit').title, document.documentElement.dataset.view]")
        check(again == ['Open', 'Open with Preview', 'pdf'], 'PDF: rewritten on disk, the re-render keeps "Open with <app>" in the tooltip', json.dumps(again))
        light = page.cmd('@appearance:light') and page.cmd('@wait:0.4') and page.cmd('@pdf')['result']
        dark = page.cmd('@appearance:dark') and page.cmd('@wait:0.4') and page.cmd('@pdf')['result']
        check(not light['dark'] and dark['dark'] and sum(light['bg']) > 600 and sum(dark['bg']) < 200,
              "PDF: the backdrop follows the theme's light and dark background", f"{light['bg']} / {dark['bg']}")
        page.cmd('@appearance:light')
        click(page, '#side-toggle')
        page.cmd('@wait:0.6')
        collapsed, area = page.cmd('@pdf')['result'], page.js(PDF_AREA)
        click(page, '#side-toggle')
        page.cmd('@wait:0.6')
        reopened, area2 = page.cmd('@pdf')['result'], page.js(PDF_AREA)
        check(near(collapsed['frame'], area) and area[0] == EDGE and area[2] == 1200 - 2 * EDGE and near(reopened['frame'], area2) and area2[0] == 240 + 1,
              'PDF: the view follows the sidebar collapsing and opening', f"{collapsed['frame']} / {reopened['frame']}")
        page.cmd('@nativedrag:#side-resize,60')
        dragged, area = page.cmd('@pdf')['result'], page.js(PDF_AREA)
        page.cmd("@eval:document.getElementById('side-resize').dispatchEvent(new MouseEvent('dblclick', { bubbles: true })); 0")
        page.cmd('@wait:0.3')
        check(near(dragged['frame'], area) and area[0] == 300 + 1, 'PDF: the view follows a drag of the sidebar edge', f"{dragged['frame']} area {area}")
        page.cmd('@size:1000x700')
        resized, area = page.cmd('@pdf')['result'], page.js(PDF_AREA)
        check(near(resized['frame'], area) and area[1] + area[3] == 700 - EDGE, 'PDF: the view follows the panel resizing', f"{resized['frame']} area {area}")
        page.cmd('@size:600x700')
        click(page, '#side-toggle')
        page.cmd('@wait:0.3')
        peeked = page.cmd('@pdf')['result']
        side_right = page.js("return document.getElementById('sidebar').getBoundingClientRect().right")
        click(page, '#side-toggle')
        page.cmd('@wait:0.3')
        check(st()['view'] == 'pdf' and peeked['frame'][0] >= side_right - 1 and not peeked['hidden'],
              'PDF: narrow, the sidebar shown over the page is never under the native view', f"{peeked['frame']} sidebar right {side_right}")
        page.cmd('@size:1200x800')
        view(T('README.md'))
        page.cmd('@wait:0.3')
        gone = page.cmd('@pdf')['result']
        md = page.js("return [document.documentElement.dataset.view, !!document.querySelector('#doc h1'), getComputedStyle(document.body).overflow, document.getElementById('aa').hidden]")
        check(gone == {'open': False, 'docAlive': False, 'fds': 0, 'inContainer': False} and md == ['markdown', True, 'visible', False],
              'PDF -> Markdown: the native view is removed, its document freed and no descriptor left on the file; the page is back',
              f'{json.dumps(gone)} {json.dumps(md)}')
        view(T('doc.pdf'))
        page.cmd('@eval:sb.setOpener(' + json.dumps({'path': T('doc.pdf'), 'app': 'Preview'}) + '); 0')
        view(T('photo.png'))
        other = page.js("return [document.getElementById('edit').textContent, document.getElementById('edit').title]")
        check(other[0] == 'Open' and 'Preview' not in other[1], 'another file does not inherit the last one\'s app', json.dumps(other))
        gone = page.cmd('@pdf')['result']
        check(not gone['open'] and not gone['docAlive'] and gone['fds'] == 0, 'PDF -> image: the same clean teardown', json.dumps(gone))
        view(T('broken.pdf'))
        card = page.js("const c = document.querySelector('#doc .info-card'); return c && [document.documentElement.dataset.view, c.querySelector('.viewer-note').textContent]")
        check(card == ['info', 'This PDF can’t be shown here.'] and not page.cmd('@pdf')['result']['open'],
              'PDF PDFKit cannot open: the info card with a note, no native view', json.dumps(card))

        # ---- video and audio: the page reserves the area the extension's AVPlayerView is laid over, and reports where it is ----
        MEDIA = """const d = document.getElementById('doc'), a = d.querySelector('.pdf-area'), r = a && a.getBoundingClientRect();
          return { view: document.documentElement.dataset.view, area: r && [r.left, r.top, r.width, r.height], docMid: Math.round(d.getBoundingClientRect().left + d.getBoundingClientRect().width / 2),
            frames: document.querySelectorAll('iframe, embed, object, video, audio').length, aa: document.getElementById('aa').hidden,
            buttons: [...d.querySelectorAll('button')].map((b) => [b.textContent, b.dataset.action]), kind: document.getElementById('kind').textContent,
            head: d.querySelector('.viewer-head') && getComputedStyle(d.querySelector('.viewer-head')).display,
            fits: document.scrollingElement.scrollHeight <= innerHeight && document.scrollingElement.scrollWidth <= innerWidth }"""

        def media(path):
            r = page.render(path)
            w = page.cmd('@wait:0.4')
            rects = [m for m in r['messages'] + w['messages'] if m.get('type') == 'pdfRect' and 'x' in m]
            return page.js(MEDIA), (rects[-1] if rects else None)
        v, rect = media(T('movie.mp4'))
        check(v['view'] == 'video' and v['aa'] and v['frames'] == 0 and v['buttons'] == [['Open', 'openFile']] and v['kind'].startswith('MPEG-4') and v['head'] == 'none'
              and v['area'][0] >= 240 and 40 <= v['area'][1] <= 42 and v['area'][1] + v['area'][3] == 800 - EDGE and v['fits'],
              'video: the page reserves the rest of the panel under its toolbar, no caption row, a labelled Open button and no <video>', json.dumps(v))
        check(rect and rect['path'] == T('movie.mp4') and near([float(rect[k]) for k in 'xywh'], v['area']) and rect['hide'] in ('0', 'false'),
              'video: the page posts the area for the native player', json.dumps(rect))
        v, rect = media(T('song.wav'))
        check(v['view'] == 'audio' and v['area'][3] == 220 and abs(v['area'][0] + v['area'][2] / 2 - v['docMid']) <= 1 and v['area'][2] <= 560 and v['fits']
              and v['buttons'] == [['Open', 'openFile']], 'audio: a player 220 px tall, centred under the toolbar', json.dumps(v))
        check(rect and rect['path'] == T('song.wav') and near([float(rect[k]) for k in 'xywh'], v['area']) and float(rect['radius']) == 8,
              'audio: the page posts its area, corners rounded', json.dumps(rect))
        page.cmd('@size:520x320')
        page.cmd('@wait:0.4')
        small = page.js(MEDIA)
        page.cmd('@size:1200x800')
        check(small['fits'] and small['area'][3] <= 220 and small['area'][1] + small['area'][3] <= 320, 'audio: a small panel still fits, nothing overflows', json.dumps(small))
        v, rect = media(T('movie.webm'))
        check(v['view'] == 'info' and v['area'] is None, 'WebM, which AVFoundation cannot play, keeps its info card', json.dumps(v))

        # ---- images ImageIO decodes (HEIC, TIFF, RAW…): the page reserves the area the extension's image view is laid over ----
        pics = os.path.join(page.out, 'pics')
        os.makedirs(pics, exist_ok=True)
        for fmt, ext in (('heic', 'heic'), ('tiff', 'tiff')):
            subprocess.run(['sips', '-s', 'format', fmt, T('photo.png'), '--out', os.path.join(pics, 'photo.' + ext)], check=True, capture_output=True)
        open(os.path.join(pics, 'shot.dng'), 'wb').write(b'\0' * 64)
        shutil.copy(T('photo.png'), os.path.join(pics, 'plain.png'))
        page.cmd('@root:' + pics)
        for name in ('photo.heic', 'photo.tiff', 'shot.dng'):
            v, rect = media(os.path.join(pics, name))
            check(v['view'] == 'bitmap' and v['aa'] and v['frames'] == 0 and 40 <= v['area'][1] <= 42 and v['area'][1] + v['area'][3] == 800 - EDGE and v['fits']
                  and not page.js("return !!document.querySelector('#doc img')") and rect and rect['path'] == os.path.join(pics, name)
                  and near([float(rect[k]) for k in 'xywh'], v['area']) and rect['hide'] in ('0', 'false'),
                  f'{name}: view bitmap, the area reserved and posted for the native image view, no <img>, Aa hidden', json.dumps([v, rect]))
        page.cmd("@eval:sb.imageZoom({ path: '" + os.path.join(pics, 'shot.dng') + "', zoom: 37 }); sb.imageZoom({ path: '/elsewhere.dng', zoom: 99 }); 0")
        cap = page.js("return document.getElementById('kind').textContent")
        check(cap.endswith('37%') and '99' not in cap, 'bitmap: the native view\'s zoom shows in the toolbar, only for the file on screen', json.dumps(cap))
        v, rect = media(os.path.join(pics, 'plain.png'))
        check(v['view'] == 'image' and v['area'] is None and page.js("return !!document.querySelector('#doc .img-stage img')"),
              'bitmap -> PNG: back to the page\'s own <img> viewer, no native area', json.dumps(v))
        page.cmd('@root:' + tree)

        # ---- a file Apple's Quick Look previews (Office, iWork, fonts, 3D): the page reserves the area its QLPreviewView is laid over ----
        ql = os.path.join(page.out, 'ql')
        os.makedirs(ql, exist_ok=True)
        memo = os.path.join(ql, 'memo.docx')
        open(memo, 'wb').close()
        page.cmd('@root:' + ql)
        v, rect = media(memo)
        check(v['view'] == 'quicklook' and v['aa'] and v['frames'] == 0 and v['buttons'] == [['Open', 'openFile']]
              and 40 <= v['area'][1] <= 42 and v['area'][1] + v['area'][3] == 800 - EDGE and v['fits'],
              'Word document: the page reserves the rest of the panel under its toolbar for Apple\'s preview, no frame', json.dumps(v))
        check(rect and rect['path'] == memo and near([float(rect[k]) for k in 'xywh'], v['area']) and rect['hide'] in ('0', 'false'),
              'Word document: the page posts the area for the native preview', json.dumps(rect))
        # Any declared type of no kind of spacebar's own goes to Apple's generators: a certificate and a calendar event do; a vCard,
        # whose preview would read Contacts in the viewer's own process, is shown as its text.
        with open(os.path.join(ql, 'event.ics'), 'w') as f:
            f.write('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:1@spacebar.test\r\nDTSTART:20261001T150000Z\r\nSUMMARY:Review\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n')
        with open(os.path.join(ql, 'person.vcf'), 'w') as f:
            f.write('BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane Doe\r\nEND:VCARD\r\n')
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=spacebar test', '-days', '30', '-outform', 'DER',
                        '-keyout', os.path.join(ql, 'cert.key'), '-out', os.path.join(ql, 'cert.cer')], check=True, capture_output=True)
        got = {n: media(os.path.join(ql, n))[0]['view'] for n in ('cert.cer', 'event.ics', 'person.vcf')}
        check(got == {'cert.cer': 'quicklook', 'event.ics': 'quicklook', 'person.vcf': 'text'},
              'a certificate and a calendar event get Apple\'s preview; a vCard is shown as text', json.dumps(got))

        # ---- the seam between the two newest native views: RTF (AppKit's text view) and Apple's preview, and back to the page's own ----
        notes = os.path.join(ql, 'notes.rtf')
        with open(notes, 'w') as f:
            f.write('{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0 Hello rich text.}')
        with open(os.path.join(ql, 'read.md'), 'w') as f:
            f.write('# Seam\n\nBack in the page.\n')
        with open(os.path.join(ql, 'rows.csv'), 'w') as f:
            f.write('a,b\n1,2\n')
        SEAM = """const d = document.getElementById('doc'), a = d.querySelector('.pdf-area');
          return { view: document.documentElement.dataset.view, area: !!a, aa: document.getElementById('aa').hidden, overflow: getComputedStyle(document.body).overflow,
            source: d.textContent.includes('rtf1'), h1: (d.querySelector('h1') || {}).textContent || null, table: !!d.querySelector('table') }"""

        def seam(path):
            r = page.render(path)
            w = page.cmd('@wait:0.4')
            rects = [m for m in r['messages'] + w['messages'] if m.get('type') == 'pdfRect']
            return page.js(SEAM), (rects[-1] if rects else None)
        shown = lambda r: r is not None and str(r.get('hide')).lower() in ('0', 'false')
        v, rect = seam(notes)
        check(v['view'] == 'rtf' and v['area'] and v['aa'] and v['overflow'] == 'hidden' and not v['source']
              and shown(rect) and rect['path'] == notes and 'x' in rect,
              'RTF: view rtf, the page reserves the area for the native text view, Aa hidden, never the RTF source', json.dumps([v, rect]))
        v, rect = seam(memo)
        check(v['view'] == 'quicklook' and v['area'] and v['aa'] and shown(rect) and rect['path'] == memo,
              'RTF -> Word document: view quicklook, the area reserved again for Apple\'s preview, Aa hidden', json.dumps([v, rect]))
        v, rect = seam(os.path.join(ql, 'read.md'))
        check(v['view'] == 'markdown' and not v['area'] and not v['aa'] and v['overflow'] == 'visible' and v['h1'] == 'Seam'
              and (rect is None or not shown(rect)),
              'Word document -> Markdown: the area is released and nothing placed (the extension closes its view on the render), Aa back', json.dumps([v, rect]))
        v, rect = seam(os.path.join(ql, 'rows.csv'))
        check(v['view'] == 'csv' and not v['area'] and not v['aa'] and v['table'] and rect is None,
              'Markdown -> CSV: a table in the page, no native area and nothing more posted, Aa for text', json.dumps([v, rect]))
        page.cmd('@root:' + tree)

        # ---- the info card with Apple's thumbnail of the file, from the payload or sent once made ----
        png = 'data:image/png;base64,' + base64.b64encode(make_png(64, 48)).decode()
        card = dict(stub, path=T('deck.key'), name='deck.key', view='info', icon='other', kindName='Keynote Presentation', canOpen=True, size=5000)
        THUMB = """const c = document.querySelector('#doc .info-card'), i = c && c.querySelector('img.info-thumb');
          return c && { thumb: i ? [i.naturalWidth, i.naturalHeight, i.getBoundingClientRect().width <= 320, !!(i.compareDocumentPosition(c.querySelector('dl')) & 4)] : null,
            icon: !!c.querySelector('svg.ic'), button: c.querySelector('button').textContent, shown: getComputedStyle(c.querySelector('button')).display !== 'none',
            where: [...c.querySelectorAll('dt')].filter((d) => d.textContent === 'Where').map((d) => d.nextElementSibling.textContent),
            fits: document.scrollingElement.scrollWidth <= innerWidth }"""
        page.cmd('@eval:sb.render(' + json.dumps(dict(card, thumb=png)) + '); 0')
        page.cmd('@wait:0.2')
        t = page.js(THUMB)
        check(t and t['thumb'] == [64, 48, True, True] and not t['icon'] and t['button'] == 'Open' and not t['shown'] and t['where'] == ['~/Projects/tree'] and t['fits'],
              "info card: the file's thumbnail in the icon's place, above its details; Where is the folder; Open only in the toolbar", json.dumps(t))
        page.apply(minimalChrome=True)
        page.cmd('@wait:0.2')
        m = page.js(THUMB)
        page.apply(minimalChrome=False)
        check(m and m['shown'] and m['button'] == 'Open', 'info card: Minimal chrome, with no Open in the toolbar, keeps the card\'s', json.dumps(m))
        dmg = dict(stub, path=T('disk.dmg'), name='disk.dmg', view='info', icon='app', kindName='Disk Image', canOpen=False, size=7892,
                   details=[['Format', 'Compressed (zlib)'], ['Encrypted', 'No'], ['<b>x</b>', 5], 'bad'])
        page.cmd('@eval:sb.render(' + json.dumps(dmg) + '); 0')
        rows = page.js("return [...document.querySelectorAll('#doc .info-card dt')].map((d) => [d.textContent, d.nextElementSibling.textContent])")
        check([r[0] for r in rows] == ['Size', 'Format', 'Encrypted', 'Where'] and rows[1][1] == 'Compressed (zlib)'
              and not page.js("return !!document.querySelector('#doc .info-card b')"),
              'disk image: its format and encryption on the card as text, malformed rows dropped', json.dumps(rows))
        page.cmd('@eval:sb.render(' + json.dumps(card) + '); 0')
        page.cmd('@eval:sb.setThumb(' + json.dumps({'path': T('other.key'), 'thumb': png}) + '); 0')
        page.cmd('@eval:sb.setThumb(' + json.dumps({'path': T('deck.key'), 'thumb': 'data:image/svg+xml;base64,' + base64.b64encode(b'<svg xmlns="http://www.w3.org/2000/svg"/>').decode()}) + '); 0')
        before = page.js(THUMB)
        page.cmd('@eval:sb.setThumb(' + json.dumps({'path': T('deck.key'), 'thumb': png}) + '); 0')
        page.cmd('@wait:0.2')
        after = page.js(THUMB)
        check(before['icon'] and before['thumb'] is None and after['thumb'] == [64, 48, True, True] and not after['icon'],
              'info card: a thumbnail sent later replaces the icon; one for another file, or not a PNG, is ignored', json.dumps([before, after]))
        page.cmd('@size:420x300')
        page.cmd('@eval:sb.render(' + json.dumps(dict(card, thumb='data:image/png;base64,' + base64.b64encode(make_png(1024, 1024)).decode())) + '); 0')
        page.cmd('@wait:0.2')
        big = page.js(THUMB)
        page.cmd('@size:1200x800')
        check(big['thumb'] and big['thumb'][2] and big['fits'], 'info card: a large thumbnail in a small panel is scaled down, nothing overflows sideways', json.dumps(big))

        # ---- an archive: the writer's listing (fixed here) as a tree of folders and files ----
        arc = dict(stub, path=T('pack.zip'), name='pack.zip', view='archive', icon='other', kindName='ZIP archive', canOpen=True, size=9000)
        ARC = """const b = document.querySelector('#doc .viewer-archive');
          return b && { view: document.documentElement.dataset.view, loading: !!b.querySelector('.viewer-loading'),
            summary: (b.querySelector('.archive-summary') || {}).textContent || null,
            rows: [...b.querySelectorAll('tbody tr')].map((r) => [r.querySelector('.arc-label').textContent, r.className,
              +r.querySelector('.arc-name').style.paddingLeft.replace('px', ''), r.querySelector('.arc-size').textContent,
              !!r.querySelector('.arc-date').textContent, (r.querySelector('.arc-dir') || { getAttribute: () => null }).getAttribute('aria-expanded')]),
            button: (b.querySelector('.viewer-head .viewer-open') || {}).textContent, scripts: b.querySelectorAll('script, img, iframe').length,
            notes: [...b.querySelectorAll('.viewer-note')].map((n) => n.textContent), fits: document.scrollingElement.scrollWidth <= innerWidth }"""
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        a0 = page.js(ARC)
        check(a0 and a0['view'] == 'archive' and a0['loading'] and a0['rows'] == [] and a0['button'] == 'Open',
              'archive: its head and a loading state until the listing arrives', json.dumps(a0))
        entries = [{'name': 'proj/', 'size': None, 'modified': 1.7e12, 'isDir': True}, {'name': 'proj/README.md', 'size': 1200, 'modified': 1.7e12, 'isDir': False},
                   {'name': 'proj/src/b.js', 'size': 3000, 'modified': 1.7e12, 'isDir': False}, {'name': 'proj/src/a.js', 'size': 800, 'modified': None, 'isDir': False},
                   {'name': 'proj/<img src=x onerror="window.__pwned=1">.txt', 'size': 5, 'modified': 1.7e12, 'isDir': False},
                   {'name': 'top.txt', 'size': 0, 'modified': 1.7e12, 'isDir': False}, {'name': 'empty/', 'size': None, 'modified': None, 'isDir': True}]
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('other.zip'), 'entries': entries[:1]}) + '); 0')
        check(page.js(ARC)['loading'], 'archive: a listing for another file is ignored')
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'entries': entries}) + '); 0')
        page.cmd('@eval:sb.setOpener(' + json.dumps({'path': T('pack.zip'), 'app': 'Archive Utility'}) + '); 0')
        page.cmd('@wait:0.2')
        a1 = page.js(ARC)
        names = [r[0] for r in a1['rows']]
        check(names == ['empty', 'proj', 'src', 'a.js', 'b.js', '<img src=x onerror="window.__pwned=1">.txt', 'README.md', 'top.txt']
              and [r[2] for r in a1['rows']] == [8, 8, 24, 40, 40, 24, 24, 8] and a1['rows'][1][5] == 'true' and a1['rows'][0][1] == 'arc-folder'
              and a1['rows'][3][3] == '800 bytes' and not a1['rows'][3][4] and a1['rows'][4][3] == '3.0 KB' and a1['rows'][4][4] and a1['rows'][1][3] == '5.0 KB'
              and a1['rows'][0][3] == '',
              'archive: folders first, sorted, nested and indented, an implied folder added, sizes (a folder\'s summed) and dates, nothing unknown shown',
              json.dumps(a1['rows']))
        heights = page.js("return [...new Set([...document.querySelectorAll('#doc .viewer-archive tbody tr')].map((r) => Math.round(r.getBoundingClientRect().height)))]")
        check(len(heights) == 1, 'archive: folder and file rows are one height', json.dumps(heights))
        page.cmd("@eval:document.querySelector('#doc th button[data-col=size]').click(); 0")
        by_size = [r[0] for r in page.js(ARC)['rows']]
        page.cmd("@eval:document.querySelector('#doc th button[data-col=size]').click(); 0")
        by_size_up = [r[0] for r in page.js(ARC)['rows']]
        page.cmd("@eval:document.querySelector('#doc th button[data-col=name]').click(); 0")
        check(by_size == ['proj', 'src', 'b.js', 'a.js', 'README.md', '<img src=x onerror="window.__pwned=1">.txt', 'empty', 'top.txt']
              and by_size_up[:2] == ['empty', 'proj'] and by_size_up[-1] == 'top.txt' and [r[0] for r in page.js(ARC)['rows']] == names,
              'archive: a header sorts by its column, largest first, then the other way; folders stay first', json.dumps([by_size, by_size_up]))
        check(a1['summary'] == '5 files, 3 folders · 5.0 KB uncompressed' and a1['button'] == 'Open with Archive Utility' and a1['scripts'] == 0
              and not page.js('return window.__pwned || null') and a1['fits'],
              'archive: a header with the count and total size, the Open with button, names only ever text', json.dumps(a1))
        page.cmd("@eval:[...document.querySelectorAll('#doc .arc-dir')].find((b) => b.dataset.path === 'proj/src').click(); 0")
        a2 = page.js(ARC)
        page.cmd("@eval:[...document.querySelectorAll('#doc .arc-dir')].find((b) => b.dataset.path === 'proj').click(); 0")
        a3 = page.js(ARC)
        focused = page.js("return document.activeElement && document.activeElement.dataset.path")
        page.cmd("@eval:[...document.querySelectorAll('#doc .arc-dir')].find((b) => b.dataset.path === 'proj').click(); 0")
        a4 = page.js(ARC)
        check([r[0] for r in a2['rows']] == ['empty', 'proj', 'src', '<img src=x onerror="window.__pwned=1">.txt', 'README.md', 'top.txt'] and a2['rows'][2][5] == 'false'
              and [r[0] for r in a3['rows']] == ['empty', 'proj', 'top.txt'] and focused == 'proj' and [r[0] for r in a4['rows']] == [r[0] for r in a2['rows']],
              'archive: a folder row collapses and expands, keeping focus and what was collapsed inside it', json.dumps([a2['rows'], a3['rows'], focused]))
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'entries': entries}) + '); 0')
        again = page.js(ARC)
        check([r[0] for r in again['rows']] == [r[0] for r in a4['rows']] and again['rows'][2][5] == 'false' and not [n for n in again['notes'] if n.startswith('Showing')],
              'archive: listed again after a change on disk, it keeps its collapsed folders; a whole listing says nothing about a cut', json.dumps(again['rows']))
        big_entries = [{'name': f'root/d{i // 100}/f{i}.txt', 'size': 10, 'modified': 1.7e12, 'isDir': False} for i in range(5000)]
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'entries': big_entries, 'truncated': True}) + '); 0')
        a5 = page.js(ARC)
        check(len(a5['rows']) == 51 and a5['rows'][0][5] == 'true' and a5['rows'][1][5] == 'false' and 'Showing the first 5,000 entries.' in a5['notes']
              and a5['summary'].startswith('5,000+ files, 51+ folders · at least'),
              'archive: a large listing opens only its lone top folder, and says it was cut', json.dumps([len(a5['rows']), a5['notes'], a5['summary']]))
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'entries': big_entries, 'truncated': True, 'total': 6000}) + '); 0')
        check('Showing the first 5,000 of 6,000 entries.' in page.js(ARC)['notes'], 'archive: a cut listing whose length was counted says of how many',
              json.dumps(page.js(ARC)['notes']))
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        junk = [{'name': 'a/.DS_Store', 'size': 6, 'modified': None, 'isDir': False}, {'name': '__MACOSX/a/._x.txt', 'size': 1, 'modified': None, 'isDir': False},
                {'name': 'a/x.txt', 'size': 1, 'modified': None, 'isDir': False}, {'name': 'a/link.txt', 'size': 0, 'modified': None, 'isDir': False, 'isLink': True},
                {'name': 'a/report.docx', 'size': 9, 'modified': None, 'isDir': False}]
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'entries': junk}) + '); 0')
        j = page.js(ARC)
        dim = page.js("return [...document.querySelectorAll('#doc tr.arc-nopreview')].map((r) => [r.querySelector('.arc-label').textContent, r.title])")
        check([r[0] for r in j['rows']] == ['a', 'link.txt', 'report.docx', 'x.txt'] and dim == [['link.txt', 'A link to another file'],
              ['report.docx', 'Can’t be shown from inside the archive']],
              'archive: .DS_Store and __MACOSX are left out; a link and what cannot be shown are dimmed, and say why', json.dumps([j['rows'], dim]))
        # A crafted listing 20,000 folders deep (were the writer's cap ever bypassed): drawn, 64 levels at most, no stack overflow.
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        deep = '/'.join(f'd{i}' for i in range(20000))
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'entries': [{'name': deep, 'size': 1, 'modified': None, 'isDir': False}]}) + '); 0')
        a6 = page.js(ARC)
        check(a6 and len(a6['rows']) == 64 and a6['summary'].startswith('1 file, 63 folders'),
              'archive: a path thousands of folders deep is drawn 64 levels deep, the rest as one name', json.dumps([len((a6 or {}).get('rows') or []), (a6 or {}).get('summary')]))
        page.cmd('@eval:sb.render(' + json.dumps(arc) + '); 0')
        page.cmd('@wait:0.2')
        page.cmd('@eval:sb.setArchive(' + json.dumps({'path': T('pack.zip'), 'error': 'This archive’s contents can’t be listed.'}) + '); 0')
        page.cmd('@wait:0.2')
        e = page.js("const c = document.querySelector('#doc .info-card'); return c && [document.documentElement.dataset.view, c.querySelector('.viewer-note').textContent, c.querySelector('button').textContent]")
        check(e == ['info', 'This archive’s contents can’t be listed.', 'Open with Archive Utility'],
              'archive: one that cannot be listed becomes its info card, with why, keeping its Open with button', json.dumps(e))

        # ---- hostile files: nothing runs, nothing renders as a document ----
        H = lambda f: T('hostile', f)
        r = view(H('page.html'))
        page.cmd('@wait:0.5')
        # An HTML file is drawn by the extension's own web view over .pdf-area; the panel's page never takes in its markup.
        a = page.js("""const d = document.getElementById('doc'); return { view: document.documentElement.dataset.view, area: !!d.querySelector('.pdf-area'),
          els: d.querySelectorAll('script, iframe, img, base, meta, a, object, embed').length, bases: document.querySelectorAll('base').length,
          base: document.getElementById('base').href.startsWith('spacebar://file/') }""")
        check(a == {'view': 'html', 'area': True, 'els': 0, 'bases': 1, 'base': True} and not pwned(r), 'hostile .html: reserved for the native view, never rendered in the panel', json.dumps(a))
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
        page.cmd('@wait:1')
        ev = page.cmd('@pdf')['result']
        check(not pwned(r) and ev['open'] and ev['text'] == 'Evil' and not [m for m in r['messages'] if m.get('type') == '_navigation'],
              'hostile PDF: PDFKit shows it and runs none of its JavaScript')
        r = page.cmd("@eval:(() => { const f = document.createElement('iframe'); f.src = " + json.dumps('spacebar://file' + H('page.html')) + "; document.body.appendChild(f);"
                     " const g = document.createElement('iframe'); g.src = " + json.dumps('spacebar://file' + T('doc.pdf')) + "; document.body.appendChild(g); return 0; })()")
        page.cmd('@wait:0.8')
        r2 = page.cmd('@eval:0')
        msgs = r['messages'] + r2['messages']
        blocked = [m['msg'] for m in msgs if m.get('type') == 'log' and m.get('msg', '').startswith('csp blocked frame-src')]
        check(len(blocked) == 2 and not [m for m in msgs if m.get('type') in ('_navigation', '_frame')] and not pwned(r2),
              'no frame loads at all: the CSP stops an HTML file or a PDF in an injected frame before it is requested', json.dumps(blocked)[:200])
        page.logs = [l for l in page.logs if not l.startswith('csp blocked frame-src')]
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
        # The edge takes a press either side of its line, follows the pointer 1:1 to its limits, lights and selects nothing it
        # passes, and its cursor says which ways it can still go.
        EDGE_AT = """const w = document.getElementById('sidebar').getBoundingClientRect().width, at = (x) => (document.elementFromPoint(x, 300) || {}).id;
          return [at(w - 3), at(w + 3)]"""
        straddle = [page.js(EDGE_AT)]
        page.apply(minimalChrome=True)
        straddle.append(page.js(EDGE_AT))
        page.apply(minimalChrome=False)
        check(straddle == [['side-resize'] * 2] * 2, 'resize: a press just inside or just outside the edge takes it, in either chrome', json.dumps(straddle))
        page.render(os.path.join(folder, 'a.md'))
        page.cmd("""@eval:(() => { const h = document.getElementById('side-resize'), s = document.getElementById('sidebar'); window.__drag = { moves: [] };
          h.addEventListener('pointerdown', (e) => { window.__drag.x = e.clientX; window.__drag.w = s.getBoundingClientRect().width; });
          h.addEventListener('pointermove', (e) => { const t = document.elementFromPoint(e.clientX, 300);
            window.__drag.moves.push([e.clientX, s.getBoundingClientRect().width, document.querySelectorAll('#side-list :hover, #side-filter :hover, #side-mode :hover, #doc :hover').length,
              t && (t.id || t.tagName), getComputedStyle(document.body).cursor]); });
          return 0; })()""")
        page.cmd('@nativedrag:#side-resize,300')
        drag = page.js('return window.__drag')
        after = page.js("""const h = document.getElementById('side-resize');
          return [h.dataset.at, getComputedStyle(h).cursor, document.documentElement.classList.contains('sb-resizing'), String(getSelection())]""")
        want = lambda x: max(160, min(450, drag['w'] + x - drag['x']))
        moves = drag['moves']
        check(drag.get('w') == 240 and len(moves) >= 10 and all(abs(m[1] - want(m[0])) <= 0.5 for m in moves) and moves[-1][1] == 450,
              'resize: the width follows the pointer 1:1 from the grab, and stops at the limit', json.dumps(drag)[:400])
        check(all(m[2] == 0 and m[3] in ('side-resize', 'BODY', 'HTML') for m in moves) and after[3] == '' and not after[2],
              'resize: nothing under the drag hovers or takes the pointer, and no text is selected', json.dumps([moves[:3], after]))
        check([m[4] for m in moves] == ['col-resize' if want(m[0]) < 450 else 'w-resize' for m in moves] and after[:2] == ['max', 'w-resize'],
              'resize: the cursor is col-resize, and at the widest says it only goes narrower', json.dumps([[m[4] for m in moves], after]))
        stuck = page.js("""const h = document.getElementById('side-resize'), r = h.getBoundingClientRect(), on = () => document.documentElement.classList.contains('sb-resizing');
          const down = () => h.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 0, pointerId: 9, clientX: r.left + 4, clientY: 200 }));
          down(); const a = on(); window.dispatchEvent(new Event('blur')); const b = on();
          down(); const c = on(); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); return [a, b, c, on()]""")
        check(stuck == [True, False, True, False], 'resize: the window losing focus or Esc ends a drag, so no later click is swallowed', json.dumps(stuck))
        page.cmd('@nativedrag:#side-resize,-600')
        low = page.js("const h = document.getElementById('side-resize'); return [h.dataset.at, getComputedStyle(h).cursor]")
        check(low == ['min', 'e-resize'] and st()['width'] == '160px', 'resize: at the narrowest it says it only goes wider', json.dumps(low))
        page.cmd("@eval:document.getElementById('side-resize').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); 0")
        page.cmd('@wait:0.3')
        page.render(os.path.join(folder, 'b.md'))
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

        # ================= folder previews: any folder, and Obsidian vaults =================
        page.cmd('@size:1100x760')
        fx = os.path.join(page.out, 'fx')
        vault = make_vault(fx)
        V = lambda *p: os.path.join(vault, *p)
        r = page.cmd('@folder:' + vault)
        page.cmd('@wait:0.4')
        s = st()
        top = [x[0] for x in s['rows'] if x[1] == 1]
        check(r['result'] == 'overview' and s['view'] == 'overview' and '.obsidian' not in top and not s['active'] and 'Daily' in top,
              'vault with notes only in subfolders: previewed (not declined) on its overview, no note picked for it; .obsidian hidden',
              json.dumps([r['result'], top, s['active']]))
        page.render(V('Daily', '2026-09-25.md'))
        page.cmd('@wait:0.4')
        check(st()['title1'] == 'Today' and st()['active'] == [['2026-09-25.md', 'page']], 'a note of the vault opens in it', json.dumps(st()['active']))
        o = page.js("""const d = document.getElementById('doc'); return {
          links: [...d.querySelectorAll('a.wikilink')].map((a) => [a.textContent, a.dataset.wl, a.classList.contains('unresolved')]),
          tags: [...d.querySelectorAll('span.tag')].map((t) => t.textContent),
          callout: (() => { const q = d.querySelector('blockquote.callout'); return q && [q.dataset.callout, q.querySelector('.callout-title').textContent,
            q.querySelector('p').textContent.trim()]; })(),
          fold: (() => { const q = d.querySelectorAll('blockquote.callout')[1]; return q && [q.dataset.callout, q.querySelector('.callout-title').textContent]; })(),
          plain: d.querySelectorAll('blockquote:not(.callout)').length,
          img: (() => { const i = d.querySelector('img.wl-img'); return i && [i.getAttribute('src').startsWith('spacebar://file' + VAULT), i.naturalWidth > 0, i.getAttribute('width')]; })(),
          embed: (() => { const e = d.querySelector('.wl-embed'); return e && [e.querySelector('.wl-embed-head').textContent, (e.querySelector('.wl-embed-body h1') || {}).textContent,
            e.querySelectorAll('[data-src]').length, [...e.querySelectorAll('input[type=checkbox]')].map((b) => [b.disabled, b.hasAttribute('data-line')])]; })(),
          code: [...d.querySelectorAll('code')].map((c) => c.textContent), pwned: window.__pwned || null }""".replace('VAULT', json.dumps(vault)))
        check(o['links'][:4] == [['Plan', 'Projects/Plan', False], ['ideas', 'Ideas', False], ['Nowhere', 'Nowhere', True], ['Heading here', '', False]]
              and o['tags'] == ['#project', '#area/sub'] and o['plain'] == 1 and '[[not a link]]' in o['code'] and '#notatag' in ''.join(o['code']),
              'wikilinks resolve (an alias shows its text, a missing one is marked), tags are pills, code is left alone', json.dumps(o))
        check(o['callout'] == ['orange', 'Careful', 'Body line.'] and o['fold'] == ['blue', 'Info'],
              'callouts: typed and titled, the type as title when there is none', json.dumps([o['callout'], o['fold']]))
        check(o['img'] and o['img'][0] and o['img'][1] and o['img'][2] == '120', 'an embedded image loads from its resolved file, sized as asked', json.dumps(o['img']))
        check(o['embed'] and o['embed'][0] == 'Ideas.md' and o['embed'][1] == 'Ideas' and o['embed'][2] == 0 and o['embed'][3] == [[True, False]],
              'an embedded note shows its text, read only: no block to edit, its task can not be ticked', json.dumps(o['embed']))
        r = click(page, '#doc .wl-embed-body p')
        check('editBlock' not in types(r) and not st()['editing'], 'a click inside an embedded note starts no edit', json.dumps(types(r)))
        r = click(page, '#doc a.wikilink[data-wl="Projects/Plan"]')
        page.cmd('@wait:0.4')
        check(st()['title1'] == 'Plan' and st()['active'] == [['Plan.md', 'page']] and [m.get('path') for m in r['messages'] if m.get('type') == 'open'] == [V('Projects', 'Plan.md')],
              'a wikilink click opens the note in the panel, and the sidebar follows', json.dumps(types(r)))
        page.render(V('Daily', '2026-09-25.md'))
        r = click(page, '#doc a.wikilink[data-wl="Ideas"]')
        page.cmd('@wait:0.5')
        y = page.js("const h = [...document.querySelectorAll('#doc h2')].find((x) => x.textContent === 'Later'); return [window.scrollY, Math.round(h.getBoundingClientRect().top)]")
        check(st()['title1'] == 'Ideas' and y[0] > 0 and 0 <= y[1] < 120, 'a [[Note#Heading]] link opens the note at its heading', json.dumps(y))
        page.render(V('Daily', '2026-09-25.md'))
        page.cmd('@wait:0.3')
        r = click(page, '#doc a.wikilink.unresolved')
        page.cmd('@wait:0.2')
        check(not [m for m in r['messages'] if m.get('type') == 'open'] and 'Nothing named' in page.js("return document.getElementById('status').textContent"),
              'an unresolved wikilink opens nothing and says so')
        # Hostile: targets out of the root, forged link markup, and opens of files nothing offered.
        page.render(V('Inbox', 'Hostile.md'))
        page.cmd('@wait:0.3')
        h = page.js("""const d = document.getElementById('doc'); return { un: [...d.querySelectorAll('a.wikilink')].map((a) => [a.dataset.wl, a.classList.contains('unresolved')]),
          imgs: [...d.querySelectorAll('img')].map((i) => i.getAttribute('src')), embeds: d.querySelectorAll('.wl-embed-body').length, pwned: window.__pwned || null }""")
        forged = [x for x in h['un'] if x[0] in ('../outside', '/etc/hosts', '../../../../etc/hosts', 'secret', '.obsidian/app')]
        check(forged and all(u for _, u in forged) and not any(i and ('outside' in i or '/etc/' in i) for i in h['imgs']) and h['embeds'] == 0 and not h['pwned'],
              'hostile: links out of the root, through a link to the outside or into .obsidian stay unresolved; nothing outside loads', json.dumps(h))
        before = st()['title1']
        opened = []
        for a in page.js("return [...document.querySelectorAll('#doc a.wikilink')].map((a) => a.dataset.wl)"):
            r = click(page, f'#doc a.wikilink[data-wl={json.dumps(a)}]')
            page.cmd('@wait:0.15')
            opened += [m for m in r['messages'] if m.get('type') in ('_openFile', '_reveal', 'link') or (m.get('type') == 'open' and not m.get('path', '').startswith(vault + '/'))]
        bad_opens = [os.path.join(fx, 'outside', 'secret.md'), '/etc/hosts', V('..', 'outside', 'secret.md'), V('.obsidian', 'app.json'), V('Daily')]
        refused = 0
        for bp in bad_opens:
            r = page.cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': 'open', 'path': bp}) + '); 0')
            page.cmd('@wait:0.1')
            refused += '_openRefused' in types(r) + types(page.cmd('@eval:0'))
        check(not opened and refused == len(bad_opens), 'hostile: forged wikilinks open nothing outside the root; opens of paths nothing offered are refused',
              f'{opened} {refused}/{len(bad_opens)}')
        page.render(V('Inbox', 'Repeat.md'))
        rep = page.js("return [document.querySelectorAll('#doc .wl-embed-body').length, document.querySelectorAll('#doc a.wl-embed-head').length]")
        check(rep == [1, 1000], 'a note embedding another 1,000 times gets one copy and 999 links', json.dumps(rep))
        page.render(V('Daily', '2026-09-25.md'))
        check(page.js("return document.querySelectorAll('#doc .wl-embed-body').length") == 1, 'the vault renders normally again after the hostile note')

        # A single note inside a vault: the vault is the sidebar's root, so its links reach the whole vault.
        page.cmd('@root:')
        page.render(V('Projects', 'Plan.md'))
        page.cmd('@wait:0.4')
        s = st()
        check(s['head'] == 'Vault' and s['crumbs'] == 'Vault›Projects›Plan.md' and page.js("return !document.querySelector('#doc a.wikilink.unresolved')"),
              'a note previewed on its own is rooted at its vault', json.dumps([s['head'], s['crumbs']]))

        # Folders without Markdown, a repository, an empty folder, a huge one, a package.
        results_by = {}
        for name in ('images', 'pdfs', 'repo', 'empty', 'huge', 'Tool.app'):
            r = page.cmd('@folder:' + os.path.join(fx, name))
            page.cmd('@wait:0.3')
            results_by[name] = (r['result'], st()['view'], page.js("""const o = document.querySelector('#doc .overview'); return o && {
              sub: o.querySelector('.ov-sub').textContent, chips: [...o.querySelectorAll('.ov-chip')].map((c) => c.textContent),
              rows: [...o.querySelectorAll('a.ov-row')].map((a) => a.querySelector('.ov-row-name').textContent), empty: !!o.querySelector('.ov-empty'),
              note: (o.querySelector('.viewer-note') || {}).textContent || '', crumbs: document.getElementById('crumbs').textContent,
              more: (o.querySelector('.ov-files .ov-note') || {}).textContent || '',
              open: document.getElementById('edit').hidden }"""))
        img = results_by['images']
        check(img[0] == 'overview' and img[1] == 'overview' and img[2]['chips'] == ['3 images', '1 PDF'] and img[2]['rows'] == ['a.png', 'b.png', 'c.png', 'scan.pdf']
              and img[2]['sub'] == 'Folder · 4 items' and img[2]['crumbs'] == 'images' and img[2]['open'],
              'a folder of images: the overview, with counts and every file of the folder, as the sidebar lists them', json.dumps(img))
        check(results_by['pdfs'][0] == 'overview' and results_by['pdfs'][2]['chips'] == ['2 PDFs'], 'a folder of PDFs: the overview', json.dumps(results_by['pdfs']))
        check(results_by['repo'][0] == 'overview' and results_by['repo'][2]['rows'] == ['docs', 'node_modules', 'src'],
              'a repository without a README opens on its overview, not on a note found deeper down', json.dumps(results_by['repo']))
        check(results_by['empty'][0] == 'overview' and results_by['empty'][2]['empty'] and results_by['empty'][2]['sub'] == 'Folder · Empty',
              'an empty folder: an overview that says so', json.dumps(results_by['empty']))
        hg = results_by['huge']
        check(hg[0] == 'overview' and hg[2]['sub'].endswith('+ items') and 'large folder' in hg[2]['note'] and len(hg[2]['rows']) == 5000
              and hg[2]['more'] == '1,000 more not listed · Filter finds them',
              'a huge folder: the overview from a bounded scan, marked as partial; the list as far as the sidebar lists it', json.dumps(hg)[:400])
        check(results_by['Tool.app'][0].startswith('declined'), 'an app bundle is declined', results_by['Tool.app'][0])
        page.cmd('@folder:' + os.path.join(fx, 'images'))
        r = click(page, '#doc a.ov-row')
        page.cmd('@wait:0.4')
        check(st()['view'] == 'image' and st()['active'] == [['a.png', 'page']] and 'open' in types(r), 'a row of the list opens its file', json.dumps(types(r)))
        r = click(page, '#side-title')
        page.cmd('@wait:0.4')
        check('overview' in types(r) and st()['view'] == 'overview', "the sidebar's folder name brings the overview back", json.dumps(types(r)))
        calm_header(page, check, 'quicklook')
        folder_grid(page, check, page.out)
        page.cmd('@root:')
        viewers(page, check, page.out, st)
        tools(page, check, page.out)
        find_typed(page, check, page.out)
        steady_chrome(page, check, page.out)
        missing_images(page, check, page.out)
        one_selection(page, check, page.out)
        steady_list(page, check, page.out)
        contents_search(page, check, page.out)
        archive_entries(page, check, page.out)
        sidebar_and_folders(page, check, page.out)

        csp = [l for l in page.logs if 'csp blocked' in l]
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l]
        check(not csp and not errs, 'no CSP violations or page errors logged', json.dumps(csp + errs)[:300])
        page.close()
        sandboxed(tree, check)
        sandboxed(tree, check, runtime=True)
        panel_host(check)
        drag_openwith_diff(check)
        release_interactions(check)
    finally:
        if page.proc.poll() is None:
            page.close()
        shutil.rmtree(page.out, ignore_errors=True)

    print(f'\n{sum(results)}/{len(results)} sidebar checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
