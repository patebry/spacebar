"""Shared pieces for tests that drive a qlmanage this process launched. Input is only ever posted to pids we own."""
import atexit, os, re, subprocess, tempfile, time
import Quartz
from pidpost import Target

DOC = ('Hello paragraph for editing. ' * 12).strip() + '\n\nSecond paragraph, also editable. ' + ('More words here. ' * 10).strip() + '\n\n- one\n- two\n'


def fresh_doc(text=DOC):
    folder = tempfile.mkdtemp(prefix='spacebar-test-')
    path = os.path.join(folder, 'edit.md')
    open(path, 'w').write(text)
    return path


def start_log(logf):
    p = subprocess.Popen(['/usr/bin/log', 'stream', '--level', 'info', '--style', 'compact', '--predicate', 'subsystem == "md.spacebar"'],
                         stdout=open(logf, 'w'), stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    return p


# Where another installed extension also claims markdown, Quick Look picks one by an order it does not document. Asking for
# this content type, which only spacebar claims, routes the preview to it without touching the other extension.
QLMANAGE = ['qlmanage', '-c', 'md.spacebar.qlmanage', '-p']


def launch(path):
    return Target(subprocess.Popen(QLMANAGE + [path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), 'qlmanage')


def wait_for(logf, needle, timeout=10, start=0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        txt = open(logf).read()
        if needle in txt[start:]:
            return True
        time.sleep(0.02)
    return False


class Helper(Target):
    """A launchd-spawned spacebar process (extension or writer) serving the qlmanage we launched: accepted only while it is the
    single instance of its name and that qlmanage is alive."""
    def __init__(self, name, ql):
        self.name, self.ql = name, ql
        pids = instances(name)
        if len(pids) != 1: raise SystemExit(f'ABORT: {name} instances {pids}, expected exactly one')
        self._pid = pids[0]

    @property
    def pid(self):
        return self._pid

    def check(self):
        self.ql.check()
        if instances(self.name) != [self._pid]:
            raise SystemExit(f'ABORT: {self.name} instances {instances(self.name)}, expected [{self._pid}]')


def instances(name):
    return [int(p) for p in subprocess.run(['pgrep', '-x', name], capture_output=True, text=True).stdout.split()]


def service_window(logf, start=0):
    """The extension's view-service window number and Cocoa frame, from the probe's [attached] log line."""
    m = re.findall(r'\[attached\] window=NSServiceViewControllerWindow num=(\d+) .*?frame=\{\{([\d.-]+), ([\d.-]+)\}, \{([\d.]+), ([\d.]+)\}\}', open(logf).read()[start:])
    if not m: raise SystemExit('ABORT: no [attached] line (PROBE=1 build?)')
    n, x, y, w, h = m[-1]
    return int(n), float(x), float(y), float(w), float(h)


def click(ext, win, x, y, count=1):
    """Posts a click (count=2: double-click) to the extension pid at (x, y) points from the top-left of its view (the service
    window reports flipped coordinates, so y is passed through as is).
    Returns the wall-clock time in ms just before the last mouse-up was posted."""
    from AppKit import NSEvent, NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp
    num, wx, wy, ww, wh = win
    if not (0 <= x < ww and 0 <= y < wh): raise SystemExit(f'ABORT: point {(x, y)} outside the view')
    up = None
    for n in range(1, count + 1):
        for t in (NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp):
            now = time.clock_gettime(time.CLOCK_UPTIME_RAW)
            wall = time.time() * 1000
            e = NSEvent.mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure_(
                t, (x, y), 0, now, num, None, 0, n, 1.0 if t == NSEventTypeLeftMouseDown else 0.0)
            ext.post(e.CGEvent())
            up = wall
            time.sleep(0.03)
    return up


def require_idle(timeout=3.0):
    """Waits for spacebar processes from our previous qlmanage to exit. Never kills: another spacebar process may be serving the
    user's own Quick Look (possibly mid-write), so a run aborts instead."""
    t0 = time.time()
    while instances('SpacebarPreview') or instances('SpacebarWriter'):
        if time.time() - t0 > timeout:
            raise SystemExit(f'ABORT: spacebar processes still running {instances("SpacebarPreview") + instances("SpacebarWriter")}; '
                             'close Quick Look previews that use spacebar and retry')
        time.sleep(0.1)


def support_dir():
    """The folder the extension reads, as SettingsFile.supportDir picks it: spacebar/, or the legacy spacebar.md/ while it is the
    only one."""
    base = os.path.expanduser('~/Library/Application Support')
    current, legacy = os.path.join(base, 'spacebar'), os.path.join(base, 'spacebar.md')
    return legacy if not os.path.lexists(current) and os.path.isdir(legacy) else current


def probe_conf(modes):
    """Writes the PROBE build's per-run modes; they are cleared when the test exits."""
    conf = os.path.join(support_dir(), 'probe.conf')
    os.makedirs(os.path.dirname(conf), exist_ok=True)
    open(conf, 'w').write(modes + '\n')
    atexit.register(lambda: open(conf, 'w').write(''))
