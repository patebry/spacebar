#!/usr/bin/env python3
"""Settings in the real extension (PROBE=1 build), against qlmanage instances this script launches.

The extension reads the real support folder, so settings.json and custom.css there are backed up before the run and put back
exactly (or removed, if they did not exist) when it ends, however it ends. Page actions are DOM events through the probe's
`cmd=` channel; the only OS input is Esc posted to the SpacebarWriter pid serving our qlmanage.

  - a theme in settings.json is on <html> by the first render (document-start script: no flash)
  - editing settings.json switches the page live (log 'settings applied theme=...'), also while an inline edit is open
  - appearance dark flips prefers-color-scheme (web.appearance)
  - custom.css applies live
  - the Aa popover writes settings.json through the writer
  - a scripted page cannot set keys outside the panel allow-list (userTheme, inlineEditing, editorBundleID)
  - inlineEditing false: a click starts no edit; taskToggles false: a toggle is refused
  - front matter renders as a table and the block after it still edits
"""
import atexit, json, os, shutil, signal, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus
from corpus import Run, LOG, CMD, OUT, ESC
from qlcommon import start_log, wait_for, probe_conf, support_dir

SUPPORT = support_dir()
GUARDED = ['settings.json', 'custom.css']
BACKUP = tempfile.mkdtemp(prefix='spacebar-settings-backup-')
saved = {}


def backup():
    os.makedirs(SUPPORT, exist_ok=True)
    for f in GUARDED:
        p = os.path.join(SUPPORT, f)
        if os.path.lexists(p):
            shutil.copy2(p, os.path.join(BACKUP, f), follow_symlinks=False)
            saved[f] = True
        else:
            saved[f] = False
    atexit.register(restore)
    # A terminal closing or a timeout must restore too: turn the signal into an exit, which runs finally blocks and atexit.
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, lambda *_: sys.exit(1))


def restore():
    for f, existed in saved.items():
        p = os.path.join(SUPPORT, f)
        if existed:
            tmp = p + '.restore'
            shutil.copy2(os.path.join(BACKUP, f), tmp, follow_symlinks=False)
            os.replace(tmp, p)
        elif os.path.lexists(p):
            os.remove(p)
    saved.clear()


def write_settings(obj):
    p = os.path.join(SUPPORT, 'settings.json')
    tmp = p + '.tmp'
    open(tmp, 'w').write(json.dumps(obj))
    os.replace(tmp, p)


def read_settings():
    try: return json.load(open(os.path.join(SUPPORT, 'settings.json')))
    except (OSError, ValueError): return {}


RESULTS = []


def check(name, ok, detail=''):
    RESULTS.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + ('' if ok else f'   {detail}'), flush=True)


def applied(run, theme, mark, timeout=4):
    return wait_for(LOG, f'settings applied theme={theme}', timeout, mark)


ROOT = "const r = document.documentElement, cs = getComputedStyle(r); return { theme: r.dataset.theme, size: cs.getPropertyValue('--font-size').trim(), bg: getComputedStyle(document.body).backgroundColor, dark: matchMedia('(prefers-color-scheme: dark)').matches, editing: !!document.querySelector('#doc > .md-editing'), editText: (document.querySelector('#doc > .md-editing') || {}).textContent || null };"


def main():
    backup()
    probe_conf(f'cmd={CMD}')
    doc = os.path.join(OUT, 'settings.md')
    text = 'Hello paragraph.\n\n- [ ] a task\n\nThird para here.\n'
    open(doc, 'w').write(text)
    fm = os.path.join(OUT, 'fm.md')
    shutil.copy(os.path.join(corpus.CORPUS, 'frontmatter.md'), fm)

    write_settings({'version': 1, 'theme': 'nord'})
    run = Run(doc)
    try:
        s = run.js(ROOT)
        check('no flash: theme from settings.json is on <html> at first render', s['theme'] == 'nord', s)

        m = os.path.getsize(LOG)
        write_settings({'version': 1, 'theme': 'github', 'fontSize': 19})
        ok = applied(run, 'github', m)
        s = run.js(ROOT)
        check('settings.json edit applies live', ok and s['theme'] == 'github' and s['size'].startswith('19'), s)

        m = os.path.getsize(LOG)
        write_settings({'version': 1, 'theme': 'github', 'appearance': 'dark'})
        applied(run, 'github', m)
        time.sleep(0.3)
        s = run.js(ROOT)
        check('appearance dark flips prefers-color-scheme', s['dark'] is True, s)
        write_settings({'version': 1, 'theme': 'github', 'appearance': 'light'})
        time.sleep(0.5)
        check('appearance light', run.js(ROOT)['dark'] is False)

        m = os.path.getsize(LOG)
        open(os.path.join(SUPPORT, 'custom.css'), 'w').write('body { background-color: rgb(1, 2, 3) !important; }\n')
        time.sleep(0.8)
        s = run.js(ROOT)
        check('custom.css applies live', s['bg'] == 'rgb(1, 2, 3)', s)
        os.remove(os.path.join(SUPPORT, 'custom.css'))
        time.sleep(0.5)

        # Live switch during an inline edit.
        run.click('Hello paragraph.', 5)
        m = os.path.getsize(LOG)
        write_settings({'version': 1, 'theme': 'solarized', 'fontSize': 17})
        ok = applied(run, 'solarized', m)
        s = run.js(ROOT)
        check('live switch keeps an inline edit open', ok and s['editing'] and 'Hello paragraph.' in (s['editText'] or '') and s['theme'] == 'solarized', s)
        run.type('X')
        run.key(ESC)
        got = run.settle(doc).decode()
        check('the edit still saves after the switch', got == text.replace('Hello', 'HelXlo', 1) or got.count('X') == 1, repr(got))
        open(doc, 'w').write(text)
        time.sleep(0.5)

        # Aa popover -> writer -> settings.json
        run.js("document.getElementById('aa').click(); return true")
        run.js("document.querySelector('#aa-pop [data-key=theme][data-value=nord], #aa-themes [data-value=nord]').click(); return true")
        t0 = time.time()
        while time.time() - t0 < 4 and read_settings().get('theme') != 'nord': time.sleep(0.05)
        check('popover theme swatch writes settings.json', read_settings().get('theme') == 'nord', read_settings())
        run.js("document.getElementById('aa-larger').click(); return true")
        t0 = time.time()
        while time.time() - t0 < 4 and read_settings().get('fontSize') != 18: time.sleep(0.05)
        check('popover A+ writes fontSize', read_settings().get('fontSize') == 18, read_settings())

        # Allow-list: a page that could script itself still cannot reach other keys.
        before = read_settings()
        m = os.path.getsize(LOG)
        for k, v in [('userTheme', 'evil.css'), ('inlineEditing', False), ('editorBundleID', 'com.apple.Terminal'), ('customCSS', False), ('rawHTML', 'off')]:
            run.js("window.webkit.messageHandlers.sb.postMessage({type:'setting', key:%s, value:%s}); return true" % (json.dumps(k), json.dumps(v)))
        run.js("window.webkit.messageHandlers.sb.postMessage({type:'setting', key:'fontSize', value:'<script>'}); return true")
        run.js("window.webkit.messageHandlers.sb.postMessage({type:'openSettings', tab:'../../etc'}); return true")
        time.sleep(1.0)
        refused = run.log()[m - run.mark:].count('refused setting')
        check('non-panel keys refused and settings.json unchanged', read_settings() == before and refused >= 6, f'refused={refused} {read_settings()}')
        check('bad openSettings tab refused', 'refused openSettings' in run.log()[m - run.mark:])

        # Gating
        write_settings({'version': 1, 'inlineEditing': False, 'taskToggles': False})
        time.sleep(0.8)
        m = os.path.getsize(LOG)
        run.js("return T.clickText('Third para here.', 3)")
        time.sleep(1.0)
        check('inlineEditing off: a click starts no edit', 'editBlock' not in run.log()[m - run.mark:] and not run.js(ROOT)['editing'])
        run.js("window.webkit.messageHandlers.sb.postMessage({type:'toggle', path:%s, line:2, text:'- [ ] a task', checked:true, ver:0}); return true" % json.dumps(doc))
        time.sleep(0.8)
        check('taskToggles off: a toggle is refused', open(doc).read() == text and 'task toggles are off' in run.log()[m - run.mark:])
        write_settings({'version': 1})
        time.sleep(0.8)

        # Front matter
        run.open(fm)
        r = run.js("return { fm: !!document.querySelector('#doc .frontmatter'), hr: document.querySelectorAll('#doc hr').length, first: (document.querySelector('#doc > [data-src]') || {}).dataset?.src || null }")
        check('front matter renders as a table, no rule, true line numbers', r['fm'] and r['hr'] == 0 and r['first'] == '5,6', r)
        run.click('Text.', 4, 'after')
        run.type('!')
        run.key(ESC)
        got = run.settle(fm).decode()
        check('a block after front matter still edits', got.startswith('---\ntitle: Test') and 'Text.!' in got, repr(got))
    finally:
        run.close()


if __name__ == '__main__':
    logp = start_log(LOG)
    try:
        main()
    finally:
        logp.terminate()
        restore()
    print(f'\n{sum(RESULTS)}/{len(RESULTS)} settings checks passed; files in {OUT}')
    sys.exit(0 if RESULTS and all(RESULTS) else 1)
