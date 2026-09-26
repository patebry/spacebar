#!/usr/bin/env python3
"""Inline-edit check against a qlmanage this script launches (needs a PROBE=1 build).

The probe's `autoedit` mode clicks the first block with a DOM event, so no OS input reaches any window. Keys are posted only to
the SpacebarWriter pid that serves this qlmanage (pid-targeted, never to a HID or session tap), after re-checking it before each key.
Reports: which app holds keyboard focus (AX, read-only), whether the Quick Look window survives, file contents, latencies.

inline_edit.py [out-dir]
"""
import os, re, statistics, subprocess, sys, tempfile, time
import Quartz, ApplicationServices as AS
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pidpost import Target
from qlcommon import require_idle, probe_conf, QLMANAGE

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp())
os.makedirs(out, exist_ok=True)
probe_conf('autoedit')

folder = tempfile.mkdtemp()
path = os.path.join(folder, 'inline.md')
open(path, 'w').write('Hello paragraph for editing.\n\n- one\n- two\n')
logf = os.path.join(out, 'inline-edit.log')
logp = subprocess.Popen(['/usr/bin/log', 'stream', '--level', 'info', '--style', 'compact', '--predicate', 'subsystem == "md.spacebar"'],
                        stdout=open(logf, 'w'), stderr=subprocess.DEVNULL)
time.sleep(1.0)
require_idle()
started = time.time()
ql = Target(subprocess.Popen(QLMANAGE + [path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), 'qlmanage')


def qlwin():
    ws = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) if w['kCGWindowOwnerPID'] == ql.pid]
    return max(ws, key=lambda w: w['kCGWindowBounds']['Height'] * w['kCGWindowBounds']['Width'], default=None)


def focused_app():
    sw = AS.AXUIElementCreateSystemWide()
    AS.AXUIElementSetMessagingTimeout(sw, 3.0)
    for _ in range(5):
        err, app = AS.AXUIElementCopyAttributeValue(sw, 'AXFocusedApplication', None)
        if not err: break
        time.sleep(0.2)
    if err: return f'AX error {err}'
    err, pid = AS.AXUIElementGetPid(app, None)
    return os.path.basename(subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip())


class Writer(Target):
    """The writer is launchd-spawned for this qlmanage's extension; accept it only if it is the single instance and newer than qlmanage."""
    def __init__(self, pid):
        self._pid = pid
        self.name = 'SpacebarWriter'

    @property
    def pid(self):
        return self._pid

    def check(self):
        ql.check()
        pids = subprocess.run(['pgrep', '-x', 'SpacebarWriter'], capture_output=True, text=True).stdout.split()
        if pids != [str(self._pid)]:
            raise SystemExit(f'ABORT: writer instances {pids}, expected [{self._pid}]')


def snap(name):
    w = qlwin()
    if w: subprocess.run(['screencapture', '-x', '-o', '-l', str(w['kCGWindowNumber']), os.path.join(out, name)])


for _ in range(80):
    time.sleep(0.1)
    if 'panel-key' in open(logf).read(): break
time.sleep(0.3)
pids = subprocess.run(['pgrep', '-x', 'SpacebarWriter'], capture_output=True, text=True).stdout.split()
if len(pids) != 1: raise SystemExit(f'ABORT: expected one writer, found {pids}')
etime = subprocess.run(['ps', '-p', pids[0], '-o', 'etime='], capture_output=True, text=True).stdout.strip()
from AppKit import NSWorkspace
print('frontmost (active) app:', NSWorkspace.sharedWorkspace().frontmostApplication().localizedName())
print('edit began (panel key):', bool(re.findall(r'lat\[\d+\] panel-key', open(logf).read())), '| writer age', etime, '| focused app:', focused_app(),
      '| QL window on screen:', bool(qlwin()))
w = Writer(int(pids[0]))

w.type('XY'); time.sleep(0.2)
snap('inline-edit-typing.png')
w.key(' '); w.key('\b')
w.key('\r'); w.type('new'); time.sleep(0.3)
w.key('\b', flags=Quartz.kCGEventFlagMaskCommand); time.sleep(0.3)  # Cmd+Delete must stay inside the editor
print('file after typing:', repr(open(path).read()))
print('qlmanage alive:', ql.popen.poll() is None, '| QL window on screen:', bool(qlwin()))

# Burst with no pauses so edits queue behind in-flight writes (line counts change mid-queue).
w.burst('\rab\rc')
time.sleep(0.6)
want = 'HellXY\n\nnew\n\nab\n\nco paragraph for editing.\n\n- one\n- two\n'
got = open(path).read()
print('burst result correct:', got == want, '' if got == want else repr(got))

open(path, 'a').write('external line\n'); time.sleep(0.3)
before = open(path).read()
try:
    w.type('Q'); time.sleep(0.3)
except SystemExit as e:
    print('post after external change:', e)
print('external change preserved:', open(path).read() == before, '| log:', re.findall(r'changed on disk[^\n]*|conflict[^\n]*', open(logf).read())[-2:])
snap('inline-edit-after.png')
if ql.popen.poll() is None:
    try: w.key('\x1b')
    except SystemExit: pass
time.sleep(0.4)
print('focused app after Esc:', focused_app())
ql.popen.terminate(); time.sleep(0.5); logp.terminate()

text = open(logf).read()
for label in ('keystroke->painted', 'keystroke->saved->rendered'):
    xs = [float(x) for x in re.findall(re.escape(label) + r' ([\d.]+)ms', text)]
    if xs: print(f'{label}: n={len(xs)} median={statistics.median(xs):.1f}ms max={max(xs):.1f}ms')
print('log:', logf)
