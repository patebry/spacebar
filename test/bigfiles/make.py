#!/usr/bin/env python3
"""The large files test/bigfiles times: a 16 MB CSV and a 50,000-row one, 2 MB of minified JSON, a 2 MB source file, a zip of
10,000 entries and a folder of 5,000 files. The 500-page PDF and the 12k x 12k PNG are drawn by the harness (--fixtures)."""
import json
import os
import random
import sys
import zipfile

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = random.Random(3)
cities = ['Oslo', 'Lima', 'Pune', 'Cork', 'Kobe', 'Faro', 'Nice', 'Graz']


def csv_rows(n):
    return 'id,name,city,amount,date,ratio\n' + ''.join(
        f'{i},name {rng.randrange(10**6):06d},{cities[i % 8]},{rng.randrange(-50000, 500000) / 100:.2f},2026-{1 + i % 12:02d}-{1 + i % 28:02d},{rng.random():.4f}\n'
        for i in range(1, n + 1))


def put(name, text):
    with open(os.path.join(out, name), 'w', encoding='utf-8', newline='') as f:
        f.write(text)


put('rows-50k.csv', csv_rows(50_000))
# Just under the 16 MB table cap (16 << 20), so the whole file is the table.
big = csv_rows(340_000)
cap = 16 << 20
if len(big) >= cap:
    big = big[:big.rindex('\n', 0, cap - 1) + 1]
put('big-16mb.csv', big)
# The same size in words that escape and bridge: CJK and accents as UTF-8, and accents in Windows-1252 (decoded to UTF-16).
rows, n = ['id,名前,city,note\n'], 0
while n < 16_000_000:
    s = f'{len(rows)},名前{rng.randrange(10**6)},Zürich,"Café crème, naïve ""quoted"" déjà vu"\n'
    rows.append(s)
    n += len(s.encode())
put('intl-16mb.csv', ''.join(rows))
rows, n = ['id,city,note\n'], 0
while n < 16_000_000:
    s = f'{len(rows)},Zürich,Café crème naïve déjà vu {rng.randrange(10**6)}\n'
    rows.append(s)
    n += len(s)
with open(os.path.join(out, 'cp1252-16mb.csv'), 'wb') as f:
    f.write(''.join(rows).encode('cp1252'))

# Markdown past the body threshold, with what the page must keep exactly: a byte order mark, CRLF line ends, and wikilinks
# (resolved off the main thread, then rendered again).
os.makedirs(os.path.join(out, 'notes'))
para = 'A paragraph with **bold**, `code`, a [[other]] link and an [[other#Top|alias]].\r\n\r\n'
with open(os.path.join(out, 'notes', 'big.md'), 'w', encoding='utf-8', newline='') as f:
    f.write('\ufeff# Big notes\r\n\r\n' + ''.join(f'## Section {i}\r\n\r\n' + para * 20 for i in range(2_000)))
put('notes/other.md', '# Top\n\nThe other note.\n')

items, size = [], 0
while size < 2_000_000:
    it = {'id': len(items), 'sku': f'SKU-{rng.randrange(10**8):08d}', 'tags': ['a', 'b', 'c'][:1 + len(items) % 3],
          'price': round(rng.random() * 100, 2), 'ok': len(items) % 2 == 0, 'meta': {'w': len(items) % 7, 'h': None}}
    items.append(it)
    size += len(json.dumps(it, separators=(',', ':'))) + 1
put('minified-2mb.json', json.dumps({'version': 3, 'items': items}, separators=(',', ':')))

# Under the 2 MB text cap (2 << 20): the whole file, highlighted after the first paint.
fn = 'export function handler{0}(req, res) {{\n  const body = JSON.parse(req.body || "{{}}");\n  if (!body.id) return res.status(400).send("missing id {0}");\n  return res.json({{ ok: true, id: body.id, n: {0} }});\n}}\n\n'
code, i = [], 0
while sum(map(len, code)) < 2_000_000:
    code.append(fn.format(i))
    i += 1
put('bundle-2mb.js', ''.join(code))

with zipfile.ZipFile(os.path.join(out, 'many-10k.zip'), 'w', zipfile.ZIP_STORED) as z:
    for n in range(10_000):
        z.writestr(f'dir{n // 100:03d}/file-{n:05d}.txt', f'entry {n}\n')

folder = os.path.join(out, 'folder-5000')
os.makedirs(folder)
for n in range(5_000):
    with open(os.path.join(folder, f'item-{n:04d}.txt'), 'w') as f:
        f.write(f'item {n}\n')
