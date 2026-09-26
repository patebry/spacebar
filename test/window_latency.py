#!/usr/bin/env python3
"""Time qlmanage -p launch -> preview window on screen (extension-agnostic, for comparing against QLMarkdown)."""
import os, subprocess, sys, time
import Quartz
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import QLMANAGE
path, runs, kill = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for i in range(runs):
    subprocess.run(['pkill', '-f', kill]); time.sleep(0.6)
    t0 = time.time()
    p = subprocess.Popen(QLMANAGE + [path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    seen = None
    while time.time() - t0 < 10 and seen is None:
        for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
            if w.get('kCGWindowOwnerName') == 'qlmanage' and w['kCGWindowBounds']['Height'] > 200:
                seen = time.time() - t0; break
        time.sleep(0.005)
    print(f"run {i}: window after {seen*1000:.0f}ms" if seen else f"run {i}: no window")
    time.sleep(0.8); p.terminate(); time.sleep(0.3)
