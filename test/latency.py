#!/usr/bin/env python3
"""Time qlmanage -p <file> launch -> spacebar 'rendered' log line. Needs `log stream --level info` writing to $LOG."""
import os, re, subprocess, sys, time
from qlcommon import require_idle
logf, path, runs = os.environ['LOG'], sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3
for i in range(runs):
    require_idle(timeout=10)
    start_size = os.path.getsize(logf)
    t0 = time.time()
    p = subprocess.Popen(QLMANAGE + [path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    line = None
    while time.time() - t0 < 10 and not line:
        time.sleep(0.02)
        with open(logf) as f:
            f.seek(start_size)
            m = re.search(r'painted\[open\] (.*) wall=([\d.]+)', f.read())
            if m: line = m
    if line:
        with open(logf) as f:
            f.seek(start_size); txt = f.read()
        prep = re.search(r'prepare .* processAge=([\d.]+)ms wall=([\d.]+)', txt)
        print(f"run {i}: qlmanage->prepare {(float(prep.group(2))-t0)*1000:.0f}ms (ext process age at prepare {prep.group(1)}ms), "
              f"qlmanage->painted {(float(line.group(2))-t0)*1000:.0f}ms | {line.group(1)}")
    else:
        print(f"run {i}: no render seen")
    p.terminate(); time.sleep(0.5)
