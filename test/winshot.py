#!/usr/bin/env python3
"""Capture only the Quick Look panel window: winshot.py <owner-substring> <out.png>"""
import subprocess, sys
import Quartz
owner, out = sys.argv[1], sys.argv[2]
wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
cands = [w for w in wins if owner.lower() in w.get('kCGWindowOwnerName', '').lower() and w['kCGWindowBounds']['Height'] > 200]
if not cands:
    sys.exit(f"no window for {owner}: " + ", ".join(sorted({w.get('kCGWindowOwnerName','') for w in wins})))
w = max(cands, key=lambda w: w['kCGWindowBounds']['Height'] * w['kCGWindowBounds']['Width'])
subprocess.run(['screencapture', '-x', '-o', '-l', str(w['kCGWindowNumber']), out], check=True)
print(w['kCGWindowOwnerName'], w['kCGWindowNumber'], dict(w['kCGWindowBounds']))
