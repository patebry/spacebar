#!/usr/bin/env python3
"""Scripted inline-edit sessions over a fixture corpus (PROBE=1 build), against qlmanage instances this script launches.

Every session edits a fresh copy of a fixture in one mktemp -d folder. Page actions are DOM events sent through the probe's
`cmd=` channel (no OS input); keys go only to the SpacebarWriter pid serving our qlmanage, and the `native` sessions post mouse
events only to its SpacebarPreview pid, each re-checked before every post. After every session the edit is ended, the file
bytes are compared exactly with the expected text, and the file is checked for stray blank lines.

corpus.py [name-substring ...]   runs only the sessions whose name contains one of the substrings
"""
import base64, json, os, re, sys, tempfile, time, urllib.parse
import Quartz
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import start_log, launch, wait_for, Helper, instances, require_idle, probe_conf, service_window

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, 'corpus')
OUT = tempfile.mkdtemp(prefix='spacebar-corpus-')
LOG = os.path.join(OUT, 'corpus.log')
CMD = os.path.join(OUT, 'cmd.json')
RET, BS, ESC = 36, 51, 53
LEFT, RIGHT = 123, 124
SHIFT = Quartz.kCGEventFlagMaskShift


def fixture(name):
    return open(os.path.join(CORPUS, name), newline='').read()


def long_doc(n):
    """A generated document of about n lines: paragraphs, lists, code fences and tables in rotation."""
    parts, i = [], 0
    while sum(p.count('\n') + 2 for p in parts) < n:
        k = i % 4
        if k == 0: parts.append(f'Paragraph {i} with some words to edit.')
        elif k == 1: parts.append(f'- item {i}a\n- item {i}b')
        elif k == 2: parts.append(f'```\ncode {i}\n\nmore {i}\n```')
        else: parts.append(f'| h{i} | v |\n|---|---|\n| {i} | x |')
        i += 1
    return '\n\n'.join(parts) + '\n'


# Page helpers: blocks are addressed by the index of their text in the rendered document; points come from text ranges so a
# click lands on a given character, and each event is sent to whatever element is under the point when it fires.
HELPERS = r"""
window.T = {
  point(root, needle, k, side) {
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let acc = '', nodes = [];
    for (let n; (n = w.nextNode());) { nodes.push([n, acc.length]); acc += n.data; }
    const at = acc.indexOf(needle);
    if (at < 0) return null;
    const j = side === 'after' ? at + k - 1 : at + k;
    const hit = nodes.find(([n, b]) => b <= j && j < b + n.data.length);
    if (!hit) return null;
    const [node, base] = hit, off = j - base;
    const wide = /[\ud800-\udbff]/.test(node.data[off]) ? 2 : 1;
    const r = document.createRange();
    r.setStart(node, off); r.setEnd(node, off + wide);
    const q = r.getClientRects()[0] || r.getBoundingClientRect();
    return [side === 'after' ? q.right - 1 : q.left + 1, q.top + q.height / 2];
  },
  fire(x, y, count) {
    const seq = [['mousedown', 1], ['mouseup', 1], ['click', 1]];
    if (count === 2) seq.push(['mousedown', 2], ['mouseup', 2], ['click', 2], ['dblclick', 2]);
    for (const [t, d] of seq) {
      const el = document.elementFromPoint(x, y) || document.body;
      el.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, detail: d, clientX: x, clientY: y, view: window }));
    }
    return true;
  },
  clickText(needle, k = 0, side = 'before', count = 1) {
    const root = document.querySelector('#doc > .md-editing') && document.querySelector('#doc > .md-editing').textContent.includes(needle)
      ? document.querySelector('#doc > .md-editing') : document.getElementById('doc');
    const p = T.point(root, needle, k, side);
    return p ? T.fire(p[0], p[1], count) : 'no text ' + needle;
  },
  clickOutside() {
    const d = document.getElementById('doc'), last = d.lastElementChild, r = d.getBoundingClientRect();
    const y = Math.min(innerHeight - 5, (last ? last.getBoundingClientRect().bottom : r.top) + 30);
    const el = document.elementFromPoint(r.left + 10, y);
    if (el && el.closest('#doc > [data-src]')) return 'no empty space';
    return T.fire(r.left + 10, y, 1);
  },
  rects() { return [...document.querySelectorAll('#doc > [data-src]')].map((b) => { const r = b.getBoundingClientRect(); return [b.tagName, r.left, r.top, r.width, r.height, b.textContent.slice(0, 20)]; }); },
  state() {
    const ed = document.querySelector('#doc > .md-editing');
    const prev = ed && ed.previousElementSibling;
    return { editing: !!ed, text: ed ? ed.textContent.replace(/​/g, '') : null, tag: ed ? ed.tagName : null,
             prev: prev ? prev.textContent : null, blocks: document.querySelectorAll('#doc > [data-src]').length };
  },
};
return true;
"""


class Run:
    """One qlmanage (and its extension and writer) that sessions are driven through."""
    def __init__(self, first_path):
        require_idle()
        if os.path.exists(CMD): os.remove(CMD)
        self.n = 0
        self.mark = os.path.getsize(LOG)
        self.ql = launch(first_path)
        self.writer = None
        try:
            if not wait_for(LOG, 'rendered[open]', 15, self.mark): raise SystemExit('ABORT: no render')
            time.sleep(0.3)
            self.js(HELPERS)
        except BaseException:
            self.close()
            raise

    def log(self):
        return open(LOG).read()[self.mark:]

    def js(self, body, timeout=5):
        self.n += 1
        tmp = CMD + '.tmp'
        json.dump({'n': self.n, 'js': body}, open(tmp, 'w'))
        os.replace(tmp, CMD)
        t0 = time.time()
        while time.time() - t0 < timeout:
            m = re.search(r'CMDRES %d (\S*)(.*)' % self.n, self.log())
            if m:
                if ' ERR ' in m.group(2): raise RuntimeError(m.group(2))
                return json.loads(base64.b64decode(m.group(1)).decode('utf-8'))
            time.sleep(0.02)
        raise RuntimeError(f'no result for command {self.n}')

    def w(self):
        if self.writer is None:
            if not wait_for(LOG, 'edit panel built', 5, self.mark): raise SystemExit('ABORT: writer never started')
            self.writer = Helper('SpacebarWriter', self.ql)
        return self.writer

    def open(self, path):
        m = os.path.getsize(LOG)
        # A link click: the page may only ask to open a file the folder sidebar lists.
        href = 'spacebar://file' + urllib.parse.quote(path)
        self.js("window.webkit.messageHandlers.sb.postMessage({ type: 'link', href: %s }); return true" % json.dumps(href))
        if not wait_for(LOG, 'rendered[open]', 10, m): raise RuntimeError('open did not render')
        time.sleep(0.15)

    def sessions(self):
        return len(re.findall(r'panel-key', self.log()))

    def click(self, needle, k=0, side='before', count=1, expect_edit=True):
        before = self.sessions()
        r = self.js('return T.clickText(%s, %d, %s, %d)' % (json.dumps(needle), k, json.dumps(side), count))
        if r is not True: raise RuntimeError(f'click {needle!r}: {r}')
        if expect_edit:
            t0 = time.time()
            while self.sessions() <= before:
                if time.time() - t0 > 4: raise RuntimeError(f'click {needle!r} started no edit')
                time.sleep(0.02)
        time.sleep(0.12)

    def outside(self):
        r = self.js('return T.clickOutside()')
        if r is not True: raise RuntimeError(f'click outside: {r}')
        time.sleep(0.2)

    def state(self):
        return self.js('return T.state()')

    def type(self, s):
        for ch in s: self.w().key(ch)

    def burst(self, s):
        self.w().burst(s)

    def key(self, code, flags=0):
        self.w().special(code, flags)

    def settle(self, path, quiet=0.35, timeout=6):
        """Waits until the file has not changed for `quiet` seconds."""
        last, since, t0 = None, time.time(), time.time()
        while time.time() - t0 < timeout:
            cur = open(path, 'rb').read()
            if cur != last: last, since = cur, time.time()
            elif time.time() - since >= quiet: return cur
            time.sleep(0.05)
        return last

    def close(self):
        try:
            if self.ql.popen.poll() is None and self.writer: self.writer.special(ESC)
        except SystemExit:
            pass
        self.ql.popen.terminate()
        time.sleep(0.6)


def stray_blank_lines(text):
    """Blank-line problems outside fenced code: two blank lines in a row, a blank first line, or a blank last line."""
    lines = text.replace('\r\n', '\n').split('\n')
    if text.endswith('\n'): lines = lines[:-1]
    blank, fence = [], None
    for ln in lines:
        m = re.match(r'\s{0,3}(```|~~~)', ln)
        if fence is None and m: fence = m.group(1); blank.append(False)
        elif fence: blank.append(False); fence = None if ln.strip().startswith(fence) else fence
        else: blank.append(not ln.strip())
    problems = []
    if any(x and y for x, y in zip(blank, blank[1:])): problems.append('two blank lines in a row')
    if blank and blank[0]: problems.append('blank first line')
    if blank and blank[-1]: problems.append('blank last line')
    return problems


RESULTS = []


def session(name, fixture_text, steps, want):
    """Registers a session: `steps(run, path)` drives it; `want` is the exact file text after the edit ends (or a predicate)."""
    SESSIONS.append((name, fixture_text, steps, want))


SESSIONS = []


def run_all(selected):
    groups = {}
    for s in SESSIONS:
        if selected and not any(k in s[0] for k in selected): continue
        groups.setdefault(s[0].split(':')[0], []).append(s)
    for group, items in groups.items():
        paths = []
        for i, (name, text, *_rest) in enumerate(items):
            p = os.path.join(OUT, f'{group}-{i}.md')
            open(p, 'w', newline='').write(text)
            paths.append(p)
        run = Run(paths[0])
        try:
            for i, (name, text, steps, want) in enumerate(items):
                if i: run.open(paths[i])
                err, got = None, None
                try:
                    note = steps(run, paths[i])
                    got = run.settle(paths[i]).decode('utf-8')
                except Exception as e:
                    err = str(e)
                    run.key(ESC) if run.writer else None
                    got = run.settle(paths[i]).decode('utf-8')
                ok = err is None and (want(got) if callable(want) else got == want)
                stray = stray_blank_lines(got) if got is not None else []
                if stray and not stray_blank_lines(text): ok = False
                RESULTS.append(ok)
                print(f'{"PASS" if ok else "FAIL"} {name}' + ('' if ok else f'\n   error {err}\n   got  {got!r}\n   want {want!r}\n   stray {stray}'), flush=True)
                if ok and note: print(f'   {note}')
        finally:
            run.close()


# ---------------------------------------------------------------------------------------------------------------- sessions
TRY = fixture('try.md')


def enter_one_line(r, p):
    r.click('Hello paragraph.', 16, 'after')
    r.key(RET)
    time.sleep(0.3)
    st = r.state()
    assert st['text'] == '' and st['prev'] == 'Hello paragraph.', f'after Enter the editor shows {st}'
    r.type('New')
    time.sleep(0.2)
    st = r.state()
    assert st['text'] == 'New', f'editor shows {st["text"]!r}'
    r.key(ESC)
    return 'after Enter the editor held one empty line below the rendered paragraph'
session('try: Enter ends the block; the editor shows one new line', TRY, enter_one_line, 'Hello paragraph.\n\nNew\n\n- one\n- two\n')


def enter_then_leave(r, p):
    r.click('Hello paragraph.', 16, 'after'); r.key(RET); time.sleep(0.3); r.outside()
session('try: Enter then click outside leaves no blank lines', TRY, enter_then_leave, TRY)


def enter_backspace(r, p):
    r.click('Hello paragraph.', 16, 'after'); r.key(RET); time.sleep(0.2); r.key(BS); time.sleep(0.3); r.type('!'); r.key(ESC)
session('try: Enter then Backspace returns to the same block', TRY, enter_backspace, 'Hello paragraph.!\n\n- one\n- two\n')


def enter_mid(r, p):
    r.click('Hello paragraph.', 5); r.key(RET); time.sleep(0.2); r.type('X'); r.key(ESC)
session('try: Enter mid-paragraph splits it', TRY, enter_mid, 'Hello\n\nX paragraph.\n\n- one\n- two\n')


def enter_mid_bs(r, p):
    r.click('Hello paragraph.', 5); r.key(RET); time.sleep(0.2); r.key(BS); time.sleep(0.3); r.type('X'); r.key(ESC)
session('try: Enter then Backspace mid-paragraph rejoins it', TRY, enter_mid_bs, 'HelloX paragraph.\n\n- one\n- two\n')


def enter_start(r, p):
    r.click('Hello paragraph.', 0); r.key(RET); time.sleep(0.2); r.type('Above'); r.key(ESC)
session('try: Enter at a block start opens a paragraph above', TRY, enter_start, 'Above\n\nHello paragraph.\n\n- one\n- two\n')


def enter_start_leave(r, p):
    r.click('Hello paragraph.', 0); r.key(RET); time.sleep(0.2); r.outside()
session('try: Enter at a block start then click outside', TRY, enter_start_leave, TRY)


def shift_enter(r, p):
    r.click('Hello paragraph.', 16, 'after'); r.key(RET, SHIFT); r.type('more'); time.sleep(0.2)
    st = r.state(); assert st['text'] == 'Hello paragraph.\nmore', st
    r.key(ESC)
session('try: Shift+Enter is a soft line break', TRY, shift_enter, 'Hello paragraph.\nmore\n\n- one\n- two\n')


def list_continue(r, p):
    r.click('one', 3, 'after'); r.key(RET); r.type('mid'); time.sleep(0.2)
    st = r.state(); assert st['text'] == '- one\n- mid\n- two', st
    r.key(ESC)
session('try: Enter in a list continues it', TRY, list_continue, 'Hello paragraph.\n\n- one\n- mid\n- two\n')


def list_exit(r, p):
    r.click('two', 3, 'after'); r.key(RET); time.sleep(0.1); r.key(RET); time.sleep(0.3); r.type('After'); time.sleep(0.2)
    st = r.state(); assert st['text'] == 'After' and st['tag'] == 'P', st
    r.key(ESC)
session('try: Enter on an empty item leaves the list', TRY, list_exit, 'Hello paragraph.\n\n- one\n- two\n\nAfter\n')


def second_block_first(r, p):
    r.click('two', 3, 'after'); r.type('!'); r.key(ESC)
session('try: first click on the second block edits it', TRY, second_block_first, 'Hello paragraph.\n\n- one\n- two!\n')


def switching(r, p):
    r.click('Hello paragraph.', 16, 'after'); r.type('a')
    r.click('two', 3, 'after'); r.type('b')
    r.click('Hello paragraph.', 0); r.type('c')
    r.click('one', 0); r.type('d')
    r.outside()
session('try: switching blocks directly, then click outside', TRY, switching, 'cHello paragraph.a\n\n- done\n- twob\n')


def rapid_switch(r, p):
    r.click('Hello paragraph.', 16, 'after'); r.burst('xyz')
    r.click('two', 3, 'after'); r.burst('uvw')
    r.click('Hello paragraph.xyz', 0); r.burst('q')
    r.outside()
session('try: rapid switching with key bursts loses no key', TRY, rapid_switch, 'qHello paragraph.xyz\n\n- one\n- twouvw\n')


def type_then_outside(r, p):
    r.click('Hello paragraph.', 16, 'after'); r.burst('abc'); r.outside()
session('try: keys typed right before a click outside are saved', TRY, type_then_outside, 'Hello paragraph.abc\n\n- one\n- two\n')


def writer_pixels(r):
    """Largest alpha of any pixel the writer's on-screen windows draw (0: nothing visible)."""
    pid = r.w().pid
    wins = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
            if w['kCGWindowOwnerPID'] == pid]
    peak = 0
    for w in wins:
        img = Quartz.CGWindowListCreateImage(Quartz.CGRectNull, Quartz.kCGWindowListOptionIncludingWindow, w['kCGWindowNumber'],
                                             Quartz.kCGWindowImageBoundsIgnoreFraming)
        if img is None: raise RuntimeError('cannot capture the writer panel (screen recording permission?)')
        data = Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(img))
        info = Quartz.CGImageGetAlphaInfo(img)
        first = info in (Quartz.kCGImageAlphaPremultipliedFirst, Quartz.kCGImageAlphaFirst)
        buf = bytes(data)
        peak = max(peak, max(buf[0::4] if first else buf[3::4], default=0))
    return len(wins), peak


def dbl_word(r, p):
    r.click('Hello paragraph.', 7)
    r.js('return T.clickText("paragraph", 3, "before", 2)'); time.sleep(0.4)
    st = r.state(); assert st['editing'], st
    sel = r.js("const s = document.querySelector('#doc > .md-editing .sel'); return s && s.textContent")
    assert sel == 'paragraph', f'inline selection shows {sel!r}'
    n, peak = writer_pixels(r)
    assert n >= 1 and peak == 0, f'writer panel draws something: {n} windows, peak alpha {peak}'
    r.type('text'); r.key(ESC)
    return f'selection drawn inline; writer panel on screen with {n} window(s), max alpha {peak}'
session('try: double-click selects a word inline; typing replaces it', TRY, dbl_word, 'Hello text.\n\n- one\n- two\n')


def dbl_word_cold(r, p):
    r.js('return T.clickText("paragraph", 3, "before", 2)')
    t0 = time.time()
    while r.sessions() < 1 and time.time() - t0 < 4: time.sleep(0.05)
    time.sleep(0.4)
    r.type('text'); r.key(ESC)
session('try: double-click on a rendered word starts the edit with the word selected', TRY, dbl_word_cold, 'Hello text.\n\n- one\n- two\n')


def dbl_then_enter(r, p):
    r.click('Hello paragraph.', 7)
    r.js('return T.clickText("paragraph", 3, "before", 2)'); time.sleep(0.4)
    r.key(RET); time.sleep(0.2); r.type('Z'); r.key(ESC)
session('try: Enter over a selection replaces it with a line break (undoable)', TRY, dbl_then_enter, 'Hello \nZ.\n\n- one\n- two\n')


def select_all_enter_undo(r, p):
    r.click('Hello paragraph.', 16, 'after')
    r.w().key('a', Quartz.kCGEventFlagMaskCommand); r.key(RET); time.sleep(0.3)
    r.w().key('z', Quartz.kCGEventFlagMaskCommand); time.sleep(0.3)
    r.key(ESC)
session('try: Cmd+A, Enter, Cmd+Z restores the block', TRY, select_all_enter_undo, TRY)


H = fixture('headings.md')
session('headings: Enter after a heading opens a paragraph',
        H, lambda r, p: (r.click('Title', 5, 'after'), r.key(RET), r.type('x'), r.key(ESC)) and None,
        H.replace('# Title\n', '# Title\n\nx\n'))
session('headings: Enter mid-heading moves the rest into a paragraph',
        H, lambda r, p: (r.click('Section', 3), r.key(RET), r.type('y'), r.key(ESC)) and None,
        H.replace('## Section\n', '## Sec\n\nytion\n'))
session('headings: edits in two sections',
        H, lambda r, p: (r.click('Body text here.', 15, 'after'), r.type(' A'), r.click('More.', 0), r.type('B'), r.outside()) and None,
        H.replace('Body text here.', 'Body text here. A').replace('More.', 'BMore.'))

L = fixture('lists.md')
session('lists: Enter in a nested item keeps its indent',
        L, lambda r, p: (r.click('b1', 2, 'after'), r.key(RET), r.type('b15'), r.key(ESC)) and None,
        L.replace('  - b1\n', '  - b1\n  - b15\n'))
session('lists: numbered item continues with the next number',
        L, lambda r, p: (r.click('two', 3, 'after'), r.key(RET), r.type('three'), r.key(ESC)) and None,
        L.replace('2. two\n', '2. two\n3. three\n'))
session('lists: Enter on an empty item mid-list splits the list',
        L, lambda r, p: (r.click('a', 1, 'after'), r.key(RET), time.sleep(0.1), r.key(RET), time.sleep(0.3), r.type('P'), r.key(ESC)) and None,
        L.replace('- a\n- b\n', '- a\n\nP\n\n- b\n'))

session('lists: Enter on a lone empty item leaves an empty paragraph, dropped on leaving',
        'Para.\n', lambda r, p: (r.click('Para.', 5, 'after'), r.key(RET), r.type('- '), time.sleep(0.3), r.key(RET), time.sleep(0.3), r.type('x'), time.sleep(0.2), r.key(ESC)) and None,
        'Para.\n\nx\n')

T_ = fixture('tasks.md')
session('tasks: Enter in a task item continues with an unchecked box',
        T_, lambda r, p: (r.click('todo', 4, 'after'), r.key(RET), r.type('next'), r.key(ESC)) and None,
        T_.replace('- [ ] todo\n', '- [ ] todo\n- [ ] next\n'))

Q = fixture('quote.md')
session('quote: Enter continues the quote; Enter on an empty quote line leaves it',
        Q, lambda r, p: (r.click('second', 6, 'after'), r.key(RET), r.type('third'), r.key(RET), time.sleep(0.1), r.key(RET), time.sleep(0.3), r.type('out'), r.key(ESC)) and None,
        '> quoted line\n> second\n> third\n\nout\n\nPara.\n')

C = fixture('code.md')
session('code: Enter inside a fence is a line break in the fence',
        C, lambda r, p: (r.click('console', 0), r.key(RET), r.type('x'), r.key(ESC)) and None,
        C.replace('\nconsole.log(a);', '\n\nxconsole.log(a);'))
session('code: Enter after the paragraph above a fence leaves the fence intact',
        C, lambda r, p: (r.click('Before.', 7, 'after'), r.key(RET), r.type('b'), r.key(ESC)) and None,
        C.replace('Before.\n', 'Before.\n\nb\n'))
session('code: Backspace at the start of the paragraph below a fence does not merge',
        C, lambda r, p: (r.click('After.', 0), r.key(BS), time.sleep(0.3), r.type('Q'), r.key(ESC)) and None,
        C.replace('After.', 'QAfter.'))
session('code: switching between a fence and paragraphs',
        C, lambda r, p: (r.click('const', 0), r.type('let '), r.click('After.', 6, 'after'), r.type('!'), r.click('Before.', 0), r.type('>'), r.outside()) and None,
        C.replace('const a', 'let const a').replace('After.', 'After.!').replace('Before.', '>Before.'))

TB = fixture('table.md')
session('table: Enter in a table opens a paragraph below it',
        TB, lambda r, p: (r.click('1', 0), r.key(RET), r.type('T'), r.key(ESC)) and None,
        TB.replace('| 1 | 2 |\n', '| 1 | 2 |\n\nT\n'))
session('table: Enter above a table leaves it intact',
        TB, lambda r, p: (r.click('Intro.', 6, 'after'), r.key(RET), r.type('i'), r.key(ESC)) and None,
        TB.replace('Intro.\n', 'Intro.\n\ni\n'))
session('table: Backspace below a table does not merge into it',
        TB, lambda r, p: (r.click('Outro.', 0), r.key(BS), time.sleep(0.3), r.type('Z'), r.key(ESC)) and None,
        TB.replace('Outro.', 'ZOutro.'))
session('table: typing in a cell',
        TB, lambda r, p: (r.click('2', 1, 'after'), r.type('0'), r.outside()) and None,
        TB.replace('| 1 | 2 |', '| 1 | 20 |'))

FM = fixture('frontmatter.md')
session('frontmatter: Enter after the body leaves front matter intact',
        FM, lambda r, p: (r.click('Text.', 5, 'after'), r.key(RET), r.type('t'), r.key(ESC)) and None,
        FM.replace('Text.\n', 'Text.\n\nt\n'))
session('frontmatter: Enter after the first heading',
        FM, lambda r, p: (r.click('Doc', 3, 'after'), r.key(RET), r.type('d'), r.key(ESC)) and None,
        FM.replace('# Doc\n', '# Doc\n\nd\n'))

MM = fixture('mermaid.md')
session('mermaid: Enter above a diagram leaves the fence intact',
        MM, lambda r, p: (r.click('Top.', 4, 'after'), r.key(RET), r.type('x'), r.key(ESC)) and None,
        MM.replace('Top.\n', 'Top.\n\nx\n'))
session('mermaid: Backspace below a diagram does not merge',
        MM, lambda r, p: (r.click('Bottom.', 0), r.key(BS), time.sleep(0.3), r.type('B'), r.key(ESC)) and None,
        MM.replace('Bottom.', 'BBottom.'))

MA = fixture('math.md')
session('math: Enter below a display equation',
        MA, lambda r, p: (r.click('End.', 4, 'after'), r.key(RET), r.type('e'), r.key(ESC)) and None,
        MA.replace('End.\n', 'End.\n\ne\n'))
session('math: typing after inline math',
        MA, lambda r, p: (r.click('here.', 5, 'after'), r.type('!'), r.outside()) and None,
        MA.replace('here.', 'here.!'))

CR = fixture('crlf.md')
session('crlf: typing keeps CRLF line endings',
        CR, lambda r, p: (r.click('First line.', 11, 'after'), r.type('X'), r.key(ESC)) and None,
        CR.replace('First line.', 'First line.X'))
session('crlf: Enter writes CRLF',
        CR, lambda r, p: (r.click('First line.', 11, 'after'), r.key(RET), r.type('N'), r.key(ESC)) and None,
        CR.replace('First line.\r\n', 'First line.\r\n\r\nN\r\n'))
session('crlf: list continuation writes CRLF',
        CR, lambda r, p: (r.click('y', 1, 'after'), r.key(RET), r.type('z'), r.key(ESC)) and None,
        CR.replace('- y\r\n', '- y\r\n- z\r\n'))
session('crlf: Enter then click outside',
        CR, lambda r, p: (r.click('Second para.', 12, 'after'), r.key(RET), time.sleep(0.2), r.outside()) and None,
        CR)

U = fixture('unicode.md')
session('unicode: typing emoji after emoji',
        U, lambda r, p: (r.click('café.', 5, 'after'), r.type('🎉'), r.key(ESC)) and None,
        U.replace('café.', 'café.🎉'))
session('unicode: Enter in CJK text',
        U, lambda r, p: (r.click('日本語の段落です。', 3), r.key(RET), r.type('新'), r.key(ESC)) and None,
        U.replace('日本語の段落です。', '日本語\n\n新の段落です。'))
session('unicode: double-click a word with accents',
        U, lambda r, p: (r.click('Héllo', 0), r.js('return T.clickText("wörld", 2, "before", 2)'), time.sleep(0.4), r.type('W'), r.key(ESC)) and None,
        U.replace('wörld', 'W'))

NF = fixture('nofinal.md')
session('nofinal: typing at the end keeps no final newline',
        NF, lambda r, p: (r.click('Last line no newline', 20, 'after'), r.type('!'), r.key(ESC)) and None,
        NF + '!')
session('nofinal: Enter at the end',
        NF, lambda r, p: (r.click('Last line no newline', 20, 'after'), r.key(RET), r.type('x'), r.key(ESC)) and None,
        NF + '\n\nx')
session('nofinal: Enter at the end then click outside',
        NF, lambda r, p: (r.click('Last line no newline', 20, 'after'), r.key(RET), time.sleep(0.2), r.outside()) and None,
        NF)

for n in (1000, 3000, 5000):
    D = long_doc(n)
    lines = D.count('\n')
    last_para = re.findall(r'Paragraph \d+ with', D)[-1]
    mid_para = re.findall(r'Paragraph \d+ with', D)[len(re.findall(r'Paragraph \d+ with', D)) // 2]

    def long_steps(r, p, last_para=last_para, mid_para=mid_para, lines=lines):
        r.js('document.scrollingElement.scrollTop = 0; return true')
        r.click('Paragraph 0 with', 0); r.type('A')
        r.js("const el = [...document.querySelectorAll('#doc > p')].find((e) => e.textContent.startsWith(%s)); el.scrollIntoView({ block: 'center' }); return true" % json.dumps(mid_para))
        time.sleep(0.2)
        r.click(mid_para, len(mid_para) - 5); r.key(RET); r.type('M')
        r.js("const el = [...document.querySelectorAll('#doc > p')].find((e) => e.textContent.startsWith(%s)); el.scrollIntoView({ block: 'center' }); return true" % json.dumps(last_para))
        time.sleep(0.2)
        r.click(last_para, 0); r.type('Z')
        r.key(ESC)
        return f'{lines} lines'
    want = D.replace('Paragraph 0 with', 'AParagraph 0 with', 1)
    want = want.replace(mid_para, mid_para[:-5] + '\n\nM' + mid_para[-5:], 1)
    want = want.replace(last_para, 'Z' + last_para, 1)
    session(f'long{n}: edits at the top, middle (Enter) and end', D, long_steps, want)


# Native mouse input posted to our extension pid: the first click on another block while an edit holds the keyboard must
# start editing it (Quick Look's view is not key then), and a click outside must end the edit.
def native_steps(r, p):
    win, ext = service_window(LOG, r.mark), Helper('SpacebarPreview', r.ql)
    from AppKit import NSEvent, NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp

    def post(x, y, count=1):
        for n in range(1, count + 1):
            for t in (NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp):
                e = NSEvent.mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure_(
                    t, (x, y), 0, time.clock_gettime(time.CLOCK_UPTIME_RAW), win[0], None, 0, n, 1.0 if t == NSEventTypeLeftMouseDown else 0.0)
                ext.post(e.CGEvent())
                time.sleep(0.03)
    r.js("window.__md = []; document.addEventListener('mousedown', (e) => window.__md.push(e.clientY), true); return true")
    marks = []
    for py in (650, 600):
        r.js('window.__md = []; return true'); post(60, py); time.sleep(0.3)
        got = r.js('return window.__md')
        if not got: raise RuntimeError('calibration click not delivered')
        marks.append((py, got[0]))
    (p1, d1), (p2, d2) = marks
    s = (d2 - d1) / (p2 - p1); c = d1 - s * p1
    to_post = lambda y: (y - c) / s
    rects = {row[5]: row for row in r.js('return T.rects()')}
    def at(prefix, dx=30):
        row = next(v for k, v in rects.items() if k.strip().startswith(prefix))
        return (row[1] + dx, to_post(row[2] + 8))
    started = []
    for label in ('Hello', 'one', 'Third', 'Hello'):
        n0 = r.sessions(); post(*at(label)); time.sleep(0.5)
        started.append(r.sessions() > n0)
        rects = {row[5]: row for row in r.js('return T.rects()')} if not r.state()['editing'] else rects
    assert all(started), f'first native click on each block started an edit: {started}'
    r.type('N')
    y_out = to_post(max(row[2] + row[4] for row in rects.values()) + 60)
    post(60, y_out); time.sleep(0.6)
    st = r.state(); assert not st['editing'], f'native click outside left the edit open: {st}'
    return 'first native click started an edit on every block; click outside ended it'
NATIVE = 'Hello paragraph.\n\n- one\n- two\n\nThird para here.\n'
# Where the native click puts the caret depends on font metrics, so only the one typed key is located.
session('native: first click edits any block; click outside ends the edit', NATIVE, native_steps,
        lambda got: got.count('N') == 1 and got.replace('N', '', 1) == NATIVE and 'N' in got.split('\n')[0])


if __name__ == '__main__':
    probe_conf(f'cmd={CMD}')
    logp = start_log(LOG)
    try:
        run_all(sys.argv[1:])
    finally:
        logp.terminate()
    print(f'\n{sum(RESULTS)}/{len(RESULTS)} sessions passed; files in {OUT}')
    sys.exit(0 if RESULTS and all(RESULTS) else 1)
