#!/usr/bin/env python3
"""Inline-edit UX checks against a qlmanage this script launches (PROBE=1 build), on files in fresh mktemp -d folders.

Page actions are DOM events run by the probe's `script=` mode (no OS input). Keys go only to the SpacebarWriter pid serving this
qlmanage, re-checked before every post. Checks: Backspace at a block start merges into the block above (and keys typed right
after land on the merged text), double-click in the editor selects a word, a click in the editor moves the caret, and a
click on another block while a save is in flight is taken.
"""
import json, os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import fresh_doc, start_log, launch, wait_for, Helper, instances, require_idle, probe_conf

here = os.path.dirname(os.path.abspath(__file__))
out = tempfile.mkdtemp(prefix='spacebar-ux-')
logf = os.path.join(out, 'ux.log')
logp = start_log(logf)

# Clicks block `i` of #doc (or the editor) at `dx` px from its left edge, first text line; detail 2 + dblclick when dbl.
def click_js(sel, dx, dbl=False):
    ev = "b.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, detail: d, clientX: r.left + %d, clientY: r.top + 8 }))" % dx
    seq = "[['mousedown',1],['mouseup',1],['click',1]" + (",['mousedown',2],['mouseup',2],['click',2],['dblclick',2]]" if dbl else "]")
    return "(() => { const b = document.querySelector(%s); const r = b.getBoundingClientRect(); for (const [t, d] of %s) %s; })()" % (json.dumps(sel), seq, ev)


def run(name, text, steps, keys, settle=1.2):
    script = os.path.join(out, name + '.json')
    json.dump([{'t': t, 'js': js} for t, js in steps], open(script, 'w'))
    probe_conf(f'script={script}')
    require_idle()
    path = fresh_doc(text)
    start = os.path.getsize(logf)
    ql = launch(path)
    try:
        if not wait_for(logf, 'rendered[open]', 10, start): raise SystemExit('no render')
        time.sleep(settle)
        if not wait_for(logf, 'panel-key', 5, start): raise SystemExit(f'{name}: edit never began')
        w = Helper('SpacebarWriter', ql)
        for k in keys:
            if callable(k): k(w, ql)
            else: w.type(k) if len(k) > 1 or k not in '\b\x1b\r' else w.key(k)
        time.sleep(0.4)
        w.key('\x1b'); time.sleep(0.4)
        got = open(path).read()
    finally:
        ql.popen.terminate(); time.sleep(0.4)
    return got, open(logf).read()[start:]


results = []
def check(name, got, want):
    ok = got == want
    results.append(ok)
    print(f'{"PASS" if ok else "FAIL"} {name}' + ('' if ok else f'\n   got  {got!r}\n   want {want!r}'))

# 1. Backspace at the start of the second paragraph joins it to the first; 'Z' typed at once lands at the join.
doc = 'First para.\n\nSecond para.\n'
got, _ = run('merge', doc, [(0.5, click_js('#doc > p:nth-of-type(2)', 1))], [lambda w, ql: w.burst('\bZ')])
check('backspace at block start merges into the block above', got, 'First para.ZSecond para.\n')

# 2. Backspace at the start of a paragraph below a code block does nothing.
doc = '```\ncode\n```\n\nAfter code.\n'
got, _ = run('nomerge', doc, [(0.5, click_js('#doc > p', 1))], [lambda w, ql: w.burst('\bZ')])
check('no merge into a code block; keys still land', got, '```\ncode\n```\n\nZAfter code.\n')

# 2b. Backspace at the start of a table does not join it onto the paragraph above.
doc = 'Para.\n\n| a |\n|---|\n| b |\n'
got, _ = run('nomerge-table', doc, [(0.5, click_js('#doc > table', 1)), (0.9, click_js('#doc > .md-editing', 0))], [lambda w, ql: w.burst('\bZ')])
check('a table is not merged into the paragraph above', got, 'Para.\n\nZ| a |\n|---|\n| b |\n')

# 2c. A task toggled below a block whose line count just changed flips the right item.
doc = 'Para.\n\n- [ ] a\n- [ ] b\n'
toggle_b = "document.querySelectorAll('input[type=checkbox]')[1].click()"
got, _ = run('toggle', doc, [(0.5, click_js('#doc > p', 1)), (2.2, toggle_b)], [lambda w, ql: w.burst('\r'), lambda w, ql: time.sleep(1.5)])
check('toggle after an edit that added lines hits the clicked task', got, 'Para.\n\n- [ ] a\n- [x] b\n')

# 3. Double-click in the editor selects the word; typing replaces it.
doc = 'alpha beta gamma\n'
got, _ = run('dblword', doc, [(0.5, click_js('#doc > p', 1)), (0.9, click_js('#doc > .md-editing', 60, dbl=True))], ['Q'])
check('double-click in the editor selects a word', got, 'alpha Q gamma\n')

# 4. A single click in the editor moves the caret without restarting the edit.
got, log = run('caret', doc, [(0.5, click_js('#doc > p', 1)), (0.9, click_js('#doc > .md-editing', 200))], ['Q'])
check('click in the editor moves the caret', got, 'alpha beta gammaQ\n')
print('   sessions started:', len(re.findall(r'editBlock \d+ lines', log)))

# 5. A click on another block while a save is in flight is taken, and no key is lost. The page fires the click from inside the
# first editUpdate of a key burst, so the burst's writes are streaming when the native side gets it; keys before the switch
# land in the first block and the rest in the second. A 4 MB trailing comment makes each write last a few milliseconds, and
# the check is retried until the log shows the click arrived during a write.
pad = '\n<!--\n' + ('x' * 99 + '\n') * 40000 + '-->\n'
doc = 'One.\n\nTwo.\n' + pad
hook = ("(() => { const u = sb.editUpdate; let armed = true; sb.editUpdate = function (x) { u.call(this, x);"
        " if (armed) { armed = false; %s; } }; })()") % click_js('#doc > p:nth-of-type(2)', 4)
keys = 'abcdefghijklmnop'
for attempt in range(1, 9):
    got, log = run('inflight', doc, [(0.5, click_js('#doc > p', 4)), (0.6, hook)], [lambda w, ql: [w.burst(k) for k in keys]])
    m = re.fullmatch(r'([a-p]*)One\.\n\n([a-p]*)Two\.\n', got[:-len(pad)]) if got.endswith(pad) else None
    during = bool(re.search(r'editBlock 2 .*during a write', log))
    if during or not m: break
check('click during an in-flight save is taken; no key lost', bool(m) and m.group(1) + m.group(2) == keys and m.group(2) != '', True)
print(f'   {got[:40]!r}; click landed during a write: {during} (attempt {attempt})')
logp.terminate()
print('log:', logf)
sys.exit(0 if all(results) else 1)
