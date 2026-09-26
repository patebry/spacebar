#!/usr/bin/env python3
"""Open a preview, mutate the file three ways, report edit->rendered latency from spacebar logs ($LOG)."""
import os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import QLMANAGE
logf, path = os.environ['LOG'], os.path.abspath(sys.argv[1])
orig = open(path).read()
p = subprocess.Popen(QLMANAGE + [path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(3)

def wait_render(since, t0):
    while time.time() - t0 < 3:
        time.sleep(0.01)
        with open(logf) as f:
            f.seek(since)
            m = re.search(r'live reload rendered .*wall=([\d.]+)', f.read())
        if m: return (float(m.group(1)) - t0) * 1000
    return None

def append(): open(path, 'a').write('\nappended line\n')
def atomic_rename():
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path)); os.write(fd, (orig + '\natomic save\n').encode()); os.close(fd); os.replace(tmp, path)
def backup_then_write():  # vim backupcopy=no / TextEdit-style: move original away, write a fresh file
    os.rename(path, path + '~'); open(path, 'w').write(orig + '\nrename-away save\n'); os.remove(path + '~')

for name, fn in [('append (echo >>)', append), ('atomic temp+rename', atomic_rename), ('rename-away + new file', backup_then_write), ('append after atomic', append)]:
    since = os.path.getsize(logf); t0 = time.time(); fn()
    ms = wait_render(since, t0)
    print(f"{name:26s} -> {'%.0f ms' % ms if ms is not None else 'NO RELOAD'}")
    time.sleep(0.6)
subprocess.run(['python3', os.path.join(os.path.dirname(__file__), 'winshot.py'), 'qlmanage', sys.argv[2]]) if len(sys.argv) > 2 else None
p.terminate()
open(path, 'w').write(orig)
