#!/usr/bin/env python3
"""Writes the messy real-world corpus the scenario tests open, into a fresh folder, and a manifest of what spacebar should
show for each file. Nothing here is committed as a fixture: every file is made at test time, so the repository stays small.

  corpus_real.py <out dir>

<out>/corpus     one of everything: data, encodings, code, documents, archives, images, hostile names, links and permissions
<out>/corpus/many    5,000 files
<out>/repo       a small project folder (a README and 32 files of mixed kinds), for the arrow-key walk
<out>/manifest.json  {"corpus": {name: {"view": [allowed views], "kind": kind, ...checks}}, "repo": [names], "skipped": [...]}

Tools beyond Python: sips (HEIC) and openssl (a certificate); a file whose tool is missing is left out and listed as skipped."""
import base64, json, os, plistlib, random, shutil, struct, subprocess, sys, tarfile, wave, zipfile, zlib

OUT = os.path.abspath(sys.argv[1])
C = os.path.join(OUT, 'corpus')
R = os.path.join(OUT, 'repo')
manifest = {'corpus': {}, 'repo': [], 'skipped': []}
rng = random.Random(20260929)


def put(name, data, view, folder=None, **checks):
    path = os.path.join(folder or C, name)
    with open(path, 'wb') as f:
        f.write(data if isinstance(data, bytes) else data.encode('utf-8'))
    if folder is None:
        manifest['corpus'][name] = dict(view=view if isinstance(view, list) else [view], **checks)
    return path


def expect(name, view, **checks):
    manifest['corpus'][name] = dict(view=view if isinstance(view, list) else [view], **checks)


# ---------- images and documents, by hand ----------

def png(w, h, rows=None, gray1=False):
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    if gray1:
        ihdr = struct.pack('>IIBBBBB', w, h, 1, 0, 0, 0, 0)
    else:
        ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    comp = zlib.compressobj(6)
    body = b''.join(comp.compress(r) for r in rows) + comp.flush()
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', body) + chunk(b'IEND', b'')


def solid_png(w, h, rgb):
    return png(w, h, (b'\0' + bytes(rgb) * w for _ in range(h)))


def gif(w, h, frames, delay=20):
    """An animated GIF89a, looping: `frames` is a list of 2-colour palettes, each frame a checkerboard in its palette. The
    LZW stream is 'uncompressed' (9-bit literals with a clear code every 254), which every decoder reads."""
    out = bytearray(b'GIF89a' + struct.pack('<HHBBB', w, h, 0x80 | 0x70 | 7, 0, 0))
    out += bytes([0, 0, 0, 255, 255, 255]) + bytes(3 * 254)
    out += b'\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00'
    for pal in frames:
        out += b'\x21\xf9\x04\x04' + struct.pack('<H', delay) + b'\x00\x00'
        out += b'\x2c' + struct.pack('<HHHHB', 0, 0, w, h, 0x80 | 0)
        out += bytes(pal[0]) + bytes(pal[1])
        pixels = [((x // 8 + y // 8) & 1) for y in range(h) for x in range(w)]
        codes, n = [256], 0
        for p in pixels:
            codes.append(p)
            n += 1
            if n == 254:
                codes.append(256)
                n = 0
        codes.append(257)
        bits, nb, data = 0, 0, bytearray()
        for c in codes:
            bits |= c << nb
            nb += 9
            while nb >= 8:
                data.append(bits & 0xff)
                bits >>= 8
                nb -= 8
        if nb:
            data.append(bits & 0xff)
        out += b'\x08'
        for i in range(0, len(data), 255):
            blk = data[i:i + 255]
            out += bytes([len(blk)]) + blk
        out += b'\x00'
    out += b'\x3b'
    return bytes(out)


def pdf(pages, label='Page'):
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    kids = []
    for i in range(pages):
        stream = f"BT /F1 28 Tf 72 700 Td ({label} {i + 1} of {pages}) Tj ET 0 0 1 RG 72 650 m 540 650 l S"
        objs.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {len(objs)} 0 R /Resources << /Font << /F1 3 0 R >> >> >>")
        kids.append(f"{len(objs)} 0 R")
    objs[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {pages} >>"
    out, offs = "%PDF-1.4\n", []
    for i, o in enumerate(objs):
        offs.append(len(out))
        out += f"{i + 1} 0 obj\n{o}\nendobj\n"
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offs)
    return (out + f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n").encode('latin-1')


def wav(path, secs=1.0, hz=440):
    import math
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(b''.join(struct.pack('<h', int(3000 * math.sin(2 * math.pi * hz * i / 22050))) for i in range(int(22050 * secs))))


def docx(text):
    import io
    b = io.BytesIO()
    with zipfile.ZipFile(b, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
                   '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr('_rels/.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        paras = ''.join(f'<w:p><w:r><w:t xml:space="preserve">{t}</w:t></w:r></w:p>' for t in text.split('\n'))
        z.writestr('word/document.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                   f'<w:body>{paras}</w:body></w:document>')
    return b.getvalue()


RTF = r"""{\rtf1\ansi\ansicpg1252\cocoartf2761
{\fonttbl\f0\fswiss\fcharset0 Helvetica-Bold;\f1\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;\red200\green30\blue40;}
\f0\b\fs36 Quarterly letter\
\f1\b0\fs24 \cf2 MARK-rtf\cf0  This is rich text with \i italics\i0 , \b bold\b0  and a\
\ul table-free\ulnone  paragraph written in 1998 and opened today.\
}"""


def rtfd(path):
    os.makedirs(path, exist_ok=True)
    open(os.path.join(path, 'pic.png'), 'wb').write(solid_png(120, 60, (40, 120, 220)))
    open(os.path.join(path, 'TXT.rtf'), 'w').write(
        r"""{\rtf1\ansi\ansicpg1252\cocoartf2761
{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
\f0\fs28 MARK-rtfd A rich text document with a picture:\
{{\NeXTGraphic pic.png \width2400 \height1200 \appleattachmentpadding0 \appleembedtype0 \appleaqc
}¬}\
Below the picture.\
}""")


# ---------- the corpus ----------

def corpus():
    os.makedirs(C)
    # CSV
    head = 'id,name,city,amount,date,ratio\n'
    cities = ['Oslo', 'Lima', 'Pune', 'Cork', 'Kobe', 'Faro', 'Nice', 'Graz']
    rows = [f'{i},name {rng.randrange(10**6):06d},{cities[i % 8]},{rng.randrange(-50000, 500000) / 100:.2f},2026-{1 + i % 12:02d}-{1 + i % 28:02d},{rng.random():.4f}\n'
            for i in range(1, 50001)]
    put('big-50k.csv', head + ''.join(rows), 'csv')
    put('semicolon-decimal.csv', 'Artikel;Preis;Menge\nÄpfel;3,50;10\nBirnen;12,25;2\nKirschen;0,99;100\nDatteln;110,00;1\n', 'csv',
        rows=4, cols=3, sep=';', sortCol=1, sortedFirst='Kirschen')
    put('multiline-quoted.csv', 'id,note,who\n1,"first line\nsecond line\nthird, with comma",ann\n2,"she said ""hi""",bob\n3,plain,cat\n', 'csv', rows=3, cols=3)
    put('ragged.csv', 'a,b,c\n1,2\n3,4,5,6,7\n\n8\n9,10,11\n', 'csv', rows=5, cols=5)
    put('bom.csv', '\ufeffname,value\nalpha,1\nbeta,2\n', 'csv', rows=2, cols=2, firstHeader='name')
    # Text around the 2 MB cap (2,097,152 bytes)
    line = 'The quick brown fox jumps over the lazy dog; log line number {:08d} MARK-text\n'
    n19 = int(1.9 * 1024 * 1024) // len(line.format(0))
    put('text-1.9mb.txt', ''.join(line.format(i) for i in range(n19)), 'text', truncated=False, lastLine=f'{n19 - 1:08d}')
    n25 = int(2.5 * 1024 * 1024) // len(line.format(0))
    put('text-2.5mb.txt', ''.join(line.format(i) for i in range(n25)), 'text', truncated=True)
    # JSON
    items = []
    size = 0
    while size < 1_990_000:
        it = {'id': len(items), 'sku': f'SKU-{rng.randrange(10**8):08d}', 'tags': ['a', 'b', 'c'][:1 + len(items) % 3],
              'price': round(rng.random() * 100, 2), 'ok': len(items) % 2 == 0, 'meta': {'w': len(items) % 7, 'h': None}}
        s = json.dumps(it, separators=(',', ':'))
        items.append(it)
        size += len(s) + 1
    put('minified-2mb.json', json.dumps({'version': 3, 'items': items}, separators=(',', ':')), 'json', mode='tree', items=len(items))
    put('comments.jsonc', '// tsconfig-style JSON with comments\n{\n  /* compiler options */\n  "compilerOptions": {\n    "strict": true, // always\n    "target": "es2022",\n  },\n  "include": ["src"]\n}\n',
        'json', mode='tree', knownBug='jsonc')
    put('broken.json', '{"name": "spacebar", "items": [1, 2, 3,, "missing": }\n', 'json', mode='raw', invalid=True)
    nested = 'x'
    for i in range(500):
        nested = {'level': 500 - i, 'child': nested} if i % 2 else [nested]
    put('nested-500.json', json.dumps(nested), 'json', mode='tree')
    put('events.ndjson', ''.join(json.dumps({'ts': 1700000000 + i, 'event': 'click', 'id': i}) + '\n' for i in range(2000)), ['text', 'code', 'json'])
    put('anchors.yaml', 'defaults: &defaults\n  adapter: postgres\n  host: localhost\n\ndevelopment:\n  <<: *defaults\n  database: dev # MARK-yaml\n\ntest:\n  <<: *defaults\n  database: test\n', 'code')
    put('config.toml', '# MARK-toml\ntitle = "spacebar"\n\n[owner]\nname = "Tom"\ndob = 1979-05-27T07:32:00-08:00\n\n[[products]]\nname = "Hammer"\nsku = 738594937\n', 'code')
    data = {'CFBundleIdentifier': 'md.spacebar.test', 'Items': list(range(20)), 'Nested': {'Flag': True, 'Blob': b'\x00\x01binary'}, 'Marker': 'MARK-plist'}
    put('binary.plist', plistlib.dumps(data, fmt=plistlib.FMT_BINARY), 'code', kindName='Binary property list, shown as XML', contains='MARK-plist')
    put('xml.plist', plistlib.dumps(data, fmt=plistlib.FMT_XML), 'code', contains='MARK-plist')
    # Encodings and line endings
    put('windows-1252.txt', 'Caf\u00e9 cr\u00e8me \u2014 \u201cquoted\u201d \u20ac5 na\u00efve r\u00e9sum\u00e9 MARK-1252\n'.encode('cp1252') * 40, 'text',
        encoding='Windows-1252', contains='Café crème')
    put('shift-jis.txt', ('日本語のテキストです。これはシフトJISで書かれています。MARK-sjis\n' * 30).encode('shift_jis'), 'text', encoding='Shift JIS', contains='日本語')
    put('utf16-le.txt', '\ufeffUTF-16 little endian: héllo wörld ✓ MARK-u16le\n'.encode('utf-16-le') * 1, 'text', encodingPrefix='UTF-16', contains='héllo wörld')
    put('utf16-be.txt', '\ufeffUTF-16 big endian: héllo wörld ✓ MARK-u16be\n'.encode('utf-16-be'), 'text', encodingPrefix='UTF-16', contains='héllo wörld')
    put('crlf.txt', 'first line\r\nsecond line\r\nthird line MARK-crlf\r\n', 'text', lines=3)
    put('crlf.md', '# CRLF heading\r\n\r\nA paragraph MARK-crlfmd.\r\n\r\n- one\r\n- two\r\n', 'markdown', contains='CRLF heading')
    # Code
    swift = ['// MARK-swift: 10,000 lines', 'import Foundation', '']
    while len(swift) < 10000:
        i = len(swift)
        swift += [f'struct Model{i} {{', f'    let id = {i}', f'    func describe() -> String {{ "model \\(id)" }}', '}', '']
    put('big.swift', '\n'.join(swift[:10000]) + '\n', 'code', lines=10000)
    js = '!function(e){"use strict";' + ''.join(f'var a{i}=function(t){{return t*{i}+e.k{i%13}}};' for i in range(12000)) + 'e.MARK="MARK-js"}(window);'
    put('bundle.min.js', js, 'code')
    put('.env', 'API_KEY=sk-test-000000000000\nDATABASE_URL=postgres://user:pass@localhost/db\n# MARK-env\n', 'text', hidden=True)
    # Notebook with image outputs
    img = base64.b64encode(solid_png(64, 32, (220, 90, 30))).decode()
    nb = {'nbformat': 4, 'nbformat_minor': 5, 'metadata': {'kernelspec': {'name': 'python3', 'display_name': 'Python 3', 'language': 'python'}},
          'cells': [{'cell_type': 'markdown', 'metadata': {}, 'source': ['# Notebook MARK-ipynb\n', 'Some *markdown*.']},
                    {'cell_type': 'code', 'execution_count': 1, 'metadata': {}, 'source': ['import matplotlib\n', 'plot()'],
                     'outputs': [{'output_type': 'display_data', 'metadata': {}, 'data': {'image/png': img, 'text/plain': ['<Figure>']}},
                                 {'output_type': 'stream', 'name': 'stdout', 'text': ['done\n']}]}]}
    put('analysis.ipynb', json.dumps(nb, indent=1), 'json', mode='notebook', images=1)
    # Markdown
    put('diagrams-math.md', '# Diagrams and math MARK-mermaid\n\n```mermaid\ngraph TD\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Ship]\n  B -->|no| D[Fix]\n```\n\n'
        'Inline $e^{i\\pi}+1=0$ and display:\n\n$$\\int_0^1 x^2\\,dx = \\tfrac13$$\n', 'markdown', mermaid=1, katex=2)
    put('shot.png', solid_png(40, 30, (30, 160, 90)), 'image')
    put('missing-images.md', '# Missing images MARK-missing\n\n![Present](shot.png)\n\n![Architecture diagram](img/architecture.png)\n\n'
        '![Screenshot 2026](../elsewhere/screen%20shot.png)\n', 'markdown', missing=2, present=1)
    table = '| # | name | city | amount | note |\n|---:|---|---|---:|---|\n' + ''.join(f'| {i} | name {i} | {cities[i % 8]} | {i * 3.5:.1f} | row {i} |\n' for i in range(3000))
    put('huge-table.md', '# Huge table MARK-table\n\n' + table, 'markdown', tableRows=3000)
    put('front-matter.md', '---\ntitle: "Launch plan"\ntags: [launch, q4]\ndraft: true\n---\n\n# Launch plan MARK-front\n\nBody text.\n', 'markdown', frontMatter=True)
    # Rich text
    put('letter.rtf', RTF, 'rtf', contains='MARK-rtf')
    rtfd(os.path.join(C, 'scrapbook.rtfd'))
    expect('scrapbook.rtfd', 'rtf', contains='MARK-rtfd', package=True)
    # Archives
    with zipfile.ZipFile(os.path.join(C, 'many-entries.zip'), 'w', zipfile.ZIP_STORED) as z:
        for i in range(10000):
            z.writestr(f'dir{i // 1000}/file-{i:05d}.txt', '')
    expect('many-entries.zip', 'archive', entriesAtMost=5000, truncated=True)
    src = os.path.join(OUT, 'tarsrc')
    os.makedirs(os.path.join(src, 'project', 'src'))
    for n in ('README.md', 'src/main.c', 'src/util.c', 'Makefile'):
        open(os.path.join(src, 'project', n), 'w').write(f'// {n}\n')
    with tarfile.open(os.path.join(C, 'release.tar.gz'), 'w:gz') as t:
        t.add(os.path.join(src, 'project'), arcname='project')
    shutil.rmtree(src)
    expect('release.tar.gz', 'archive', entries=6)
    # Images
    tmp = os.path.join(OUT, 'photo-src.png')
    open(tmp, 'wb').write(png(800, 600, (b'\0' + bytes([x * 255 // 800 for x in range(800) for _ in (0, 1, 2)]) for _ in range(600))))
    if shutil.which('sips') and subprocess.run(['sips', '-s', 'format', 'heic', tmp, '--out', os.path.join(C, 'photo.heic')],
                                               capture_output=True).returncode == 0 and os.path.exists(os.path.join(C, 'photo.heic')):
        expect('photo.heic', 'bitmap', width=800, height=600)
    else:
        manifest['skipped'].append('photo.heic (no sips)')
    os.remove(tmp)
    w = 12000
    stripe = bytes([0b11110000]) * (w // 8)
    put('huge-12k.png', png(w, w, ((b'\0' + (stripe if (y // 64) % 2 else bytes(w // 8))) for y in range(w)), gray1=True),
        ['image', 'info'], width=12000, height=12000)
    put('animated.gif', gif(64, 64, [((255, 0, 0), (255, 255, 255)), ((0, 0, 255), (255, 255, 0)), ((0, 160, 0), (0, 0, 0))]), 'image', width=64, height=64)
    put('script.svg', '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" onload="top.__pwned=\'svg-onload\'">'
        '<script>top.__pwned="svg-script";try{top.webkit.messageHandlers.sb.postMessage({type:"link",href:"https://pwned.invalid/svg"})}catch(e){}</script>'
        '<rect width="120" height="80" fill="#3a7"/><a href="javascript:top.__pwned=1"><text x="10" y="45">click</text></a></svg>', 'image', hostile=True)
    put('svg-embed.md', '# SVG embeds MARK-svgmd\n\n![as image](script.svg)\n\n<img src="script.svg">\n\n<object data="script.svg"></object><embed src="script.svg">\n',
        'markdown', hostile=True)
    put('pages-500.pdf', pdf(500), 'pdf', pages=500)
    # Office and certificates: Apple's Quick Look preview, or the info card where no generator answers.
    put('memo.docx', docx('Memo MARK-docx\nSecond paragraph.'), ['quicklook', 'info'])
    key, cer = os.path.join(OUT, 'key.pem'), os.path.join(C, 'server.cer')
    if shutil.which('openssl') and subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=spacebar-test', '-days', '30',
                                                   '-keyout', key, '-outform', 'DER', '-out', cer], capture_output=True).returncode == 0:
        os.remove(key)
        expect('server.cer', ['quicklook', 'info'])
    else:
        manifest['skipped'].append('server.cer (no openssl)')
    # Names and edge files
    put('NOTES', 'A file with no extension. MARK-noext\n', 'text')
    put('.hidden-notes', 'A dotfile. MARK-dotfile\n', 'text', hidden=True)
    put('🚀 launch notes 🎉.md', '# Emoji name MARK-emoji\n\nRocket.\n', 'markdown')
    long_name = ('a-very-long-file-name-that-goes-on-' * 8)[:245] + '.md'
    put(long_name, '# Long name MARK-long\n', 'markdown', longName=True)
    put('empty.txt', b'', 'text', empty=True)
    os.symlink('loop-b', os.path.join(C, 'loop-a'))
    os.symlink('loop-a', os.path.join(C, 'loop-b'))
    expect('loop-a', ['none', 'info'], symlinkLoop=True)
    expect('loop-b', ['none', 'info'], symlinkLoop=True)
    # A folder that contains itself, through a link: a listing or scan that follows it never ends.
    os.symlink('.', os.path.join(C, 'self-link'))
    put('unreadable.txt', 'secret MARK-unreadable\n', 'info', unreadable=True)
    os.chmod(os.path.join(C, 'unreadable.txt'), 0)
    put('unreadable.md', '# secret\n', ['none', 'info'], unreadable=True)
    os.chmod(os.path.join(C, 'unreadable.md'), 0)
    os.makedirs(os.path.join(C, 'many'))
    for i in range(5000):
        open(os.path.join(C, 'many', f'file-{i:04d}.txt'), 'w').write(f'{i}\n')


def repo():
    os.makedirs(R)
    names = []

    def add(name, data):
        put(name, data, None, folder=R)
        names.append(name)

    add('README.md', '# Project MARK-README\n\nThe readme, opened first.\n\n- [x] done\n- [ ] todo\n')
    for i in range(1, 33):
        tag = f'MARK-{i:02d}'
        k = i % 16
        if k == 0: add(f'f{i:02d}-notes.md', f'# Notes {i}\n\n{tag} paragraph.\n\n```swift\nlet x = {i}\n```\n')
        elif k == 1: add(f'f{i:02d}-main.swift', f'// {tag}\nimport Foundation\nprint({i})\n')
        elif k == 2: add(f'f{i:02d}-data.json', json.dumps({'tag': tag, 'values': list(range(i))}))
        elif k == 3: add(f'f{i:02d}-table.csv', f'col,{tag}\n' + ''.join(f'{r},{r * i}\n' for r in range(20)))
        elif k == 4: add(f'f{i:02d}-pic.png', solid_png(320, 200, ((i * 37) % 255, 90, 200)))
        elif k == 5: add(f'f{i:02d}-log.log', ''.join(f'2026-09-29 12:00:{s:02d} {tag} event {s}\n' for s in range(60)))
        elif k == 6: add(f'f{i:02d}-conf.yaml', f'# {tag}\nname: app\nport: {8000 + i}\n')
        elif k == 7: add(f'f{i:02d}-doc.pdf', pdf(3, label=tag))
        elif k == 8: add(f'f{i:02d}-icon.svg', f'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><circle cx="32" cy="32" r="{10 + i % 20}" fill="#c33"/></svg>')
        elif k == 9: add(f'f{i:02d}-anim.gif', gif(32, 32, [((255, 0, 0), (0, 0, 0)), ((0, 0, 255), (0, 0, 0))]))
        elif k == 10: add(f'f{i:02d}-script.py', f'# {tag}\ndef main():\n    return {i}\n')
        elif k == 11: add(f'f{i:02d}-readme.txt', f'Plain text {tag}\n')
        elif k == 12: add(f'f{i:02d}-page.html', f'<!doctype html><title>{tag}</title><h1>{tag}</h1><p>html page</p>')
        elif k == 13: add(f'f{i:02d}-letter.rtf', RTF.replace('MARK-rtf', tag))
        elif k == 14:
            p = os.path.join(R, f'f{i:02d}-tone.wav')
            wav(p, 1.0, 300 + i * 10)
            names.append(os.path.basename(p))
        elif k == 15: add(f'f{i:02d}-config.toml', f'# {tag}\n[server]\nport = {i}\n')
    manifest['repo'] = names


os.makedirs(OUT, exist_ok=True)
corpus()
repo()
json.dump(manifest, open(os.path.join(OUT, 'manifest.json'), 'w'), indent=1, ensure_ascii=False)
print(f"corpus: {len(manifest['corpus'])} entries, repo: {len(manifest['repo'])} files, skipped: {manifest['skipped']}")
