#!/usr/bin/env python3
"""Double-click and click-delivery check for Quick Look's double-click recognizer (PROBE=1 build), on qlmanage instances this
script launches over a file in a fresh mktemp -d folder.

Mouse events are built as NSEvents for the extension's view-service window and posted only to the SpacebarPreview pid serving
our qlmanage (re-checked before each post). `dblprobe` swaps QuickLook's doubleClickOnPreviewContent for a log line, so the
default app is never launched; `nofix` leaves the recognizer enabled to reproduce the original behaviour.

Reports, per mode: whether a double-click reached doubleClickOnPreviewContent, and the delay from the extension receiving\nthe native mouse-up to the page's click handler (both from log timestamps).
"""
import os, re, statistics, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import fresh_doc, start_log, launch, wait_for, Helper, service_window, click, require_idle, probe_conf

here = os.path.dirname(os.path.abspath(__file__))
out = tempfile.mkdtemp(prefix='spacebar-dbl-')
logf = os.path.join(out, 'dbl.log')
logp = start_log(logf)
PT = (300, 625)

for mode in ('nofix', 'fix'):
    probe_conf(f'dblprobe jsdebug {mode}')
    require_idle()
    start = os.path.getsize(logf)
    ql = launch(fresh_doc('Plain text only, no links.\n'))
    if not wait_for(logf, 'rendered[open]', 10, start): raise SystemExit('no render')
    time.sleep(0.5)
    win, ext = service_window(logf, start), Helper('SpacebarPreview', ql)
    click(ext, win, *PT); time.sleep(1.2)  # the first click only activates the view-service window
    delays = []
    for _ in range(3):
        mark = os.path.getsize(logf)
        click(ext, win, *PT)
        time.sleep(1.2)
        seg = open(logf).read()[mark:]
        up = re.search(r'(\d\d:\d\d:[\d.]+) .*localMonitor type=2 ', seg)
        js = re.search(r'(\d\d:\d\d:[\d.]+) .*js: click ', seg)
        secs = lambda m: sum(float(x) * f for x, f in zip(m.group(1).split(':'), (3600, 60, 1)))
        delays.append((secs(js) - secs(up)) * 1000 if up and js else None)
    mark = os.path.getsize(logf)
    click(ext, win, *PT, count=2); time.sleep(1.5)
    seg = open(logf).read()[mark:]
    opened = 'DOUBLE-CLICK-OPEN' in seg
    dbl = bool(re.search(r'js: dblclick', seg))
    ql.popen.terminate(); time.sleep(0.5)
    disabled = re.findall(r'disabled host double-click recognizer[^\n]*', open(logf).read()[start:])
    print(f'[{mode}] recognizer: {disabled[0] if disabled else "left enabled"}')
    print(f'[{mode}] double-click -> doubleClickOnPreviewContent (open in default app): {opened}; DOM dblclick seen: {dbl}')
    print(f'[{mode}] native mouse-up -> JS click: ' + ', '.join('none' if d is None else f'{d:.0f} ms' for d in delays))
logp.terminate()
print('log:', logf)
