#!/usr/bin/env python3
"""Click-to-caret and click-to-key latency for inline editing, against qlmanage instances this script launches (PROBE=1 build).

The probe's `latdelay=<s>` mode dispatches DOM clicks inside the preview (no OS input): the first block `s` seconds after the
view attaches (cold: fresh extension and writer processes), then four more alternating between two blocks (warm). The only
synthetic OS input is one Esc per run, posted to the SpacebarWriter pid after re-checking it is the single writer and qlmanage lives.
Works on a file in a fresh mktemp -d folder.

edit_latency.py [cold-runs] [latdelay-seconds]
  NOPREWARM=1 skips the writer pre-warm, so the first click pays the writer launch, AppKit start and panel build.
"""
import os, re, statistics, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import fresh_doc, start_log, launch, wait_for, Helper, instances, require_idle, probe_conf

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
delay = float(sys.argv[2]) if len(sys.argv) > 2 else 0.3
here = os.path.dirname(os.path.abspath(__file__))
probe_conf(f'latdelay={delay}' + (' noprewarm' if os.environ.get('NOPREWARM') == '1' else ''))
out = tempfile.mkdtemp(prefix='spacebar-lat-')
logf = os.path.join(out, 'lat.log')
logp = start_log(logf)
STAGES = ['js-click', 'js-mapped', 'caret-painted', 'xpc-call', 'writer-recv', 'panel-key', 'ack']

sessions = []
for i in range(runs):
    require_idle()
    start = os.path.getsize(logf)
    ql = launch(fresh_doc())
    if not wait_for(logf, 'rendered[open]', 10, start): raise SystemExit('no render')
    time.sleep(delay + 5.0)
    if instances('SpacebarWriter'):
        Helper('SpacebarWriter', ql).key('\x1b')
    time.sleep(0.3)
    ql.popen.terminate(); time.sleep(0.5)
    seg = open(logf).read()[start:]
    launch_t = [float(x) for x in re.findall(r'lat writer-launch ([\d.]+)', seg)][-1:]
    per = {}
    for sid, rest in re.findall(r'lat\[(\d+)\] (.*)', seg):
        for k, v in re.findall(r'([a-z-]+) ([\d.]+)', rest):
            per.setdefault(int(sid), {}).setdefault(k, float(v))
    for sid in sorted(per):
        r = per[sid]
        r['kind'] = 'cold' if sid == min(per) else 'warm'
        r['writer-launch'] = launch_t[0] if launch_t and r['kind'] == 'cold' else None
        sessions.append(r)
logp.terminate()

fmt = lambda v: '     -' if v is None else f'{v:6.1f}'
print('ms after the JS click event;', 'writer-launch is process start (cold only)')
print(f"{'kind':5} " + ' '.join(f'{s[:9]:>9}' for s in ['launch'] + STAGES[1:]))
for r in sessions:
    c = r.get('js-click')
    d = lambda k: None if c is None or r.get(k) is None else r[k] - c
    print(f"{r['kind']:5} " + ' '.join(f'{fmt(d(s)):>9}' for s in ['writer-launch'] + STAGES[1:]))
for kind in ('cold', 'warm'):
    for k, label in (('caret-painted', 'click->caret visible'), ('panel-key', 'click->typing accepted (panel key)')):
        xs = [r[k] - r['js-click'] for r in sessions if r['kind'] == kind and k in r and 'js-click' in r]
        if xs: print(f'{kind} {label}: median {statistics.median(xs):.1f} ms, max {max(xs):.1f} ms (n={len(xs)})')
print('log:', logf)
