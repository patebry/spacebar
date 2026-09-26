#!/usr/bin/env python3
"""The sidebar in the page on its own, outside Quick Look: Preview/web in the offscreen harness (test/web/main.swift), which
lists the file's folder with the extension's FolderListing, routes "open" to a listed file only, and sends "setting" through
the extension's gate (Settings.panelPatch) and the writer's update (SettingsFile.updateFromPanel) into a scratch
SPACEBAR_SUPPORT_DIR. Checks the list, the no-flash document-start state, the toggle and its persistence, the message gate,
identical markup for single-file and folder previews, and that inline editing, task toggles, the TOC, the Aa popover, themes and
narrow panels still work with the sidebar open or collapsed."""
import json, os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webthemes import Page, ROOT, THEMES, HELPERS, click

HOSTILE = 'z<img src=x onerror="window.__pwned=1">.md'
STATE = """const s = document.getElementById('sidebar'), t = document.getElementById('side-toggle'), d = document.getElementById('doc');
  const cs = getComputedStyle(s);
  return { attr: document.documentElement.dataset.sidebar, hidden: s.hidden, width: cs.width, visibility: cs.visibility,
    position: cs.position, expanded: t.getAttribute('aria-expanded'), title: t.title, toggleHidden: t.hidden,
    docLeft: Math.round(d.getBoundingClientRect().left), docWidth: Math.round(d.getBoundingClientRect().width),
    head: document.getElementById('side-head').textContent, names: [...s.querySelectorAll('#side-list a')].map((a) => a.textContent),
    active: [...s.querySelectorAll('#side-list a.active')].map((a) => [a.textContent, a.getAttribute('aria-current')]),
    more: document.getElementById('side-more').hidden ? '' : document.getElementById('side-more').textContent,
    toc: getComputedStyle(document.getElementById('toc')).display, peek: document.documentElement.classList.contains('sb-peek'),
    editing: (document.querySelector('#doc > .md-editing') || {}).textContent || null, title1: (d.querySelector('h1') || {}).textContent || null };"""


def main():
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    folder = os.path.join(page.out, 'notes')
    os.makedirs(os.path.join(folder, 'sub'))
    heads = open(os.path.join(ROOT, 'test', 'corpus', 'headings.md')).read()
    files = {'README.md': '# Read me\n\nStart here.\n', 'b.md': '# Bee\n\nSecond.\n', 'a.md': heads,
             'tasks.md': '# Tasks\n\nA paragraph to edit.\n\n- [ ] one\n- [x] two\n', 'c10.md': '# Ten\n', 'c9.md': '# Nine\n',
             '.hidden.md': '# hidden\n', 'notes.txt': 'not markdown\n', HOSTILE: '# Hostile name\n'}
    for n, t in files.items():
        open(os.path.join(folder, n), 'w').write(t)
    os.symlink('/etc/hosts', os.path.join(folder, 'escape.md'))
    os.symlink('b.md', os.path.join(folder, 'link.md'))
    lone = os.path.join(page.out, 'lone')
    os.makedirs(lone)
    open(os.path.join(lone, 'only.md'), 'w').write('# Only\n')
    settings_file = os.path.join(page.support, 'settings.json')

    def disk():
        try:
            return json.load(open(settings_file))
        except FileNotFoundError:
            return {}

    def st():
        return page.js(STATE)

    def types(r):
        return [m.get('type') for m in r['messages']]

    try:
        # ---- document start: the saved state is on <html> before anything paints, and the first render does not animate ----
        # The render is called synchronously in the same task as the measurement, so this is the first layout the page shows.
        first = """const s = document.getElementById('sidebar'); let started = 0; s.addEventListener('transitionstart', () => started++);
          window.__started = () => started;
          sb.render(PAYLOAD); const cs = getComputedStyle(s);
          return { width: cs.width, visibility: cs.visibility, anims: s.getAnimations().length, anim: document.documentElement.classList.contains('sb-anim') };"""
        payload = {'text': '# Read me\n', 'path': os.path.join(folder, 'README.md'), 'name': 'README.md', 'reason': 'open', 'ver': 0,
                   'base': 'spacebar://file' + folder + '/', 'dir': os.path.realpath(folder), 'dirName': 'notes'}
        for collapsed, want in ((True, '0px'), (False, '220px')):
            page.cmd('@load:' + json.dumps({'sidebarCollapsed': collapsed}))
            p = page.js('return window.__sbProbe')
            f = page.js(first.replace('PAYLOAD', json.dumps(payload)))
            page.cmd('@wait:0.6')
            later = page.js("return [window.__started(), document.documentElement.classList.contains('sb-anim')]")
            attr = 'collapsed' if collapsed else 'open'
            check(p.get('startSidebar') == attr and p.get('dclSidebar') == attr and f['width'] == want and f['anims'] == 0 and not f['anim']
                  and later == [0, True], f'document start: sidebarCollapsed={collapsed} is in place before the first paint, no transition',
                  f'probe {p} first {f} later {later}')

        # ---- the list: same rules as folder mode, hidden files and links out of the folder skipped, names as text ----
        page.cmd('@load:{}')
        page.cmd('@size:1000x760')
        page.render(os.path.join(folder, 'b.md'))
        s = st()
        want = ['README.md', 'a.md', 'b.md', 'c9.md', 'c10.md', 'link.md', 'tasks.md', HOSTILE]
        check(s['names'] == want and s['head'] == 'notes' and s['active'] == [['b.md', 'page']] and not s['hidden'] and not s['toggleHidden'],
              'single file: its folder listed, README first, names in Finder order, current file highlighted', json.dumps(s))
        check(page.js("return [document.querySelectorAll('#sidebar img').length, window.__pwned || null]") == [0, None],
              'a hostile file name is shown as text')
        page.cmd('@size:1000x760')
        page.apply(folderSort='modified')
        for i, n in enumerate(['tasks.md', 'c9.md', 'a.md']):
            os.utime(os.path.join(folder, n), (1e9 + i, 2e9 - i * 100))
        page.render(os.path.join(folder, 'b.md'))
        check(st()['names'][:4] == ['README.md', 'tasks.md', 'c9.md', 'a.md'], 'sorted by date modified with README still first', json.dumps(st()['names']))
        page.apply(folderSort='name', folderReadmeFirst=False)
        page.render(os.path.join(folder, 'b.md'))
        check(st()['names'][0] == 'a.md', 'README first off: plain name order')
        page.apply(folderReadmeFirst=True)

        # ---- the folder watch: a file added or removed shows up in the list without a re-render ----
        page.render(os.path.join(folder, 'b.md'))
        open(os.path.join(folder, 'new.md'), 'w').write('# New\n')
        page.cmd('@relist')
        added = st()['names']
        os.remove(os.path.join(folder, 'new.md'))
        page.cmd('@relist')
        check('new.md' in added and 'new.md' not in st()['names'] and st()['active'] == [['b.md', 'page']],
              'a changed listing updates the list and keeps the highlight', json.dumps(added))

        # ---- click another file: it opens in the panel, reusing in-panel navigation ----
        r = click(page, '#side-list a[data-path$="/c9.md"]')
        opens = [m for m in r['messages'] if m.get('type') == 'open']
        page.cmd('@wait:0.3')
        s = st()
        check(len(opens) == 1 and s['title1'] == 'Nine' and s['active'] == [['c9.md', 'page']] and 'editBlock' not in types(r),
              'a sidebar click opens that file in the panel and moves the highlight', json.dumps(opens))
        r = page.cmd("@eval:window.webkit.messageHandlers.sb.postMessage({ type: 'open', path: '/etc/hosts' }); 0")
        page.cmd('@wait:0.2')
        r2 = page.cmd('@eval:0')
        check('_openRefused' in types(r) + types(r2), 'an open for a file not in the list is refused')

        # ---- one component for single-file and folder previews ----
        page.render(os.path.join(folder, 'README.md'))
        folder_html = page.js("return document.getElementById('sidebar').outerHTML + document.getElementById('side-toggle').outerHTML")
        page.cmd('@renderfile:' + os.path.join(folder, 'README.md'))
        file_html = page.js("return document.getElementById('sidebar').outerHTML + document.getElementById('side-toggle').outerHTML")
        check(folder_html == file_html and 'README.md' in file_html, 'sidebar markup identical for a folder preview and a single file',
              f'{len(folder_html)} vs {len(file_html)} chars')
        page.render(os.path.join(lone, 'only.md'))
        s = st()
        check(s['names'] == ['only.md'] and s['head'] == 'lone' and s['width'] == '220px' and s['attr'] == 'open',
              'a folder with one Markdown file still shows the sidebar, in the saved state', json.dumps(s))

        # ---- the toggle: instant, animated, persisted through the writer, and the next preview starts in that state ----
        page.render(os.path.join(folder, 'b.md'))
        page.apply(width='full')
        open_left, open_w = st()['docLeft'], st()['docWidth']
        r = click(page, '#side-toggle')
        now = page.js("const s = document.getElementById('sidebar'); return [document.documentElement.dataset.sidebar, s.getAnimations().length]")
        posted = [m for m in r['messages'] if m.get('type') == 'setting']
        written = [m for m in r['messages'] if m.get('type') == '_written']
        page.cmd('@wait:0.5')
        s = st()
        check(now[0] == 'collapsed' and now[1] > 0, 'the toggle collapses at once, with a transition', json.dumps(now))
        check(len(posted) == 1 and posted[0].get('key') == 'sidebarCollapsed' and posted[0].get('value') in ('1', 'true')
              and posted[0].get('_mainFrame') in ('1', 'true') and posted[0].get('_origin') == 'spacebar://bundle',
              'the toggle posts sidebarCollapsed=true from the main frame of spacebar://bundle', json.dumps(posted))
        check(written and disk().get('sidebarCollapsed') is True, 'the writer saved it to settings.json', json.dumps(disk()))
        check(s['width'] == '0px' and s['visibility'] == 'hidden' and s['expanded'] == 'false' and s['title'] == 'Show sidebar'
              and s['docLeft'] == 0 and s['docWidth'] == 1000 and open_left == 220 and open_w == 780,
              'collapsed: the document takes the full width', f'open {open_left}/{open_w} -> {json.dumps(s)}')
        page.apply(width='medium')
        page.cmd('@loaddisk')
        p = page.js('return window.__sbProbe')
        page.render(os.path.join(folder, 'b.md'))
        check(p.get('dclSidebar') == 'collapsed' and st()['width'] == '0px', 'the next preview starts collapsed', json.dumps(p))
        r = click(page, '#side-toggle')
        page.cmd('@wait:0.5')
        check(disk().get('sidebarCollapsed') is False and st()['width'] == '220px' and st()['expanded'] == 'true',
              'toggled back open, and saved', json.dumps(disk()))

        # ---- another preview changed it: the live settings watch applies it here ----
        page.apply(sidebarCollapsed=True)
        a = st()
        page.apply(sidebarCollapsed=False)
        check(a['attr'] == 'collapsed' and a['expanded'] == 'false' and st()['attr'] == 'open', 'a change from elsewhere applies live', json.dumps(a))

        # ---- the message gate: only a boolean; only panel keys ----
        before = disk()
        bad = [('sidebarCollapsed', 1), ('sidebarCollapsed', 'true'), ('sidebarCollapsed', None), ('sidebarCollapsed', [True]),
               ('folderMode', True), ('remoteImages', True)]
        refused = 0
        for k, v in bad:
            r = page.cmd('@eval:window.webkit.messageHandlers.sb.postMessage(' + json.dumps({'type': 'setting', 'key': k, 'value': v}) + '); 0')
            page.cmd('@wait:0.1')
            refused += '_settingRefused' in types(r) + types(page.cmd('@eval:0'))
        check(refused == len(bad) and disk() == before, 'non-boolean values and non-panel keys are refused; settings.json unchanged',
              f'{refused}/{len(bad)} refused, {json.dumps(disk())}')

        # ---- inline editing and task toggles with the sidebar open, and through a collapse ----
        page.render(os.path.join(folder, 'tasks.md'))
        r = click(page, '#doc > p')
        eb = [m for m in r['messages'] if m.get('type') == 'editBlock']
        check(eb and eb[0].get('text') == 'A paragraph to edit.' and eb[0].get('path', '').endswith('/tasks.md') and st()['editing'],
              'inline edit starts with the sidebar open', json.dumps(eb)[:200])
        r = click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        s = st()
        check(s['editing'] and s['editing'].startswith('A paragraph to edit.') and s['attr'] == 'collapsed'
              and not {'editStop', 'editCancel', 'editBlock'} & set(types(r)), 'collapsing keeps the edit open', json.dumps(types(r)))
        page.cmd('@eval:sb.editEnd({}); 0')
        click(page, '#side-toggle')
        r = page.cmd("@eval:(() => { const b = document.querySelector('#doc input[type=checkbox]'); b.click(); return 0; })()")
        tg = [m for m in r['messages'] if m.get('type') == 'toggle']
        check(tg and tg[0].get('line') == '4' and tg[0].get('checked') in ('1', 'true'), 'a task toggle posts with the sidebar open', json.dumps(tg))
        r = click(page, '#sidebar')
        check(not {'editBlock', 'editStop', 'open', 'link'} & set(types(r)), 'a click on the sidebar background does nothing', json.dumps(types(r)))

        # ---- the TOC rail, the Aa popover and narrow panels ----
        page.render(os.path.join(folder, 'a.md'))
        page.cmd('@size:1200x760')
        wide = st()['toc']
        page.cmd('@size:1000x760')
        mid_open = st()['toc']
        click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        mid_closed = st()['toc']
        click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        check(wide == 'block' and mid_open == 'none' and mid_closed == 'block', 'the TOC gives way to the open sidebar below 1100 px',
              f'1200 open {wide}, 1000 open {mid_open}, 1000 collapsed {mid_closed}')
        overlap = page.js("""const a = document.getElementById('sidebar').getBoundingClientRect(), b = document.getElementById('doc').getBoundingClientRect(),
          c = document.getElementById('side-toggle').getBoundingClientRect(), t = document.getElementById('toolbar').getBoundingClientRect();
          return [a.right <= b.left + 1, c.right < t.left, document.elementFromPoint(c.left + 4, c.top + 4).closest('#side-toggle') !== null]""")
        check(overlap == [True, True, True], 'sidebar, document, toggle and toolbar do not overlap', json.dumps(overlap))
        click(page, '#aa')
        r = click(page, '#aa-pop .swatch[data-value=nord]')
        check([m.get('value') for m in r['messages'] if m.get('type') == 'setting'] == ['nord'] and disk().get('theme') == 'nord'
              and st()['width'] == '220px', 'the Aa popover still works beside the sidebar', json.dumps(disk()))
        click(page, '#doc')
        page.apply(theme='apple')
        page.cmd('@size:600x700')
        s = st()
        check(s['width'] == '0px' and s['attr'] == 'open' and s['expanded'] == 'false' and s['docLeft'] == 0 and s['toc'] == 'none',
              'narrow: collapsed on screen, saved state unchanged', json.dumps(s))
        saved = disk()
        r = click(page, '#side-toggle')
        page.cmd('@wait:0.4')
        s = st()
        check(s['peek'] and s['width'] == '220px' and s['position'] == 'fixed' and s['expanded'] == 'true' and 'setting' not in types(r)
              and disk() == saved, 'narrow: the toggle shows the sidebar over the page without saving', json.dumps(s))
        r = click(page, '#doc > p')
        check(not st()['peek'] and 'editBlock' not in types(r), 'narrow: a click outside closes it and starts no edit', json.dumps(types(r)))
        click(page, '#side-toggle')
        r = click(page, '#side-list a[data-path$="/b.md"]')
        page.cmd('@wait:0.3')
        check(not st()['peek'] and st()['title1'] == 'Bee' and 'open' in types(r), 'narrow: a file click opens it and closes the sidebar')
        page.cmd('@size:1000x760')
        check(not st()['peek'] and st()['width'] == '220px', 'widening restores the saved state')

        # ---- themes: sidebar text on its backgrounds, every theme light and dark ----
        low = []
        for mode in ('light', 'dark'):
            page.cmd('@appearance:' + mode)
            for t in THEMES:
                page.apply(theme=t)
                for p in page.js(HELPERS + """const side = document.getElementById('sidebar');
                    return [{ name: 'item', ...measure(side, 'var(--fg)', ['var(--bg)']) },
                            { name: 'active', ...measure(side, 'var(--fg)', ['var(--bg)', 'color-mix(in srgb, var(--accent) 12%, transparent)']) },
                            { name: 'hover', ...measure(side, 'var(--fg)', ['var(--bg)', 'color-mix(in srgb, var(--fg) 6%, transparent)']) },
                            { name: 'header', ...measure(side, 'var(--muted)', ['var(--bg)']) }];"""):
                    if p['ratio'] < 4.5:
                        low.append(f"{t} {mode} {p['name']} {p['ratio']}")
        check(not low, 'sidebar text reaches 4.5:1 in every theme, light and dark', '; '.join(low))
        page.cmd('@appearance:light')
        page.apply(theme='apple')

        # ---- reduced motion and the app's embedded sample ----
        rm = page.js("""const out = []; for (const sh of document.styleSheets) { let rules; try { rules = sh.cssRules; } catch (e) { continue; }
            const walk = (list) => { for (const r of list) { if (r.cssRules) walk(r.cssRules);
              if (r.media && /prefers-reduced-motion/.test(r.media.mediaText) && /#sidebar/.test(r.cssText) && /transition: none/.test(r.cssText)) out.push(r.media.mediaText); } };
            walk(rules); } return out.length""")
        check(rm >= 1, 'reduced motion turns the sidebar transition off')
        emb = page.js("""document.documentElement.classList.add('sb-embedded');
          const r = [getComputedStyle(document.getElementById('sidebar')).display, getComputedStyle(document.getElementById('side-toggle')).display];
          document.documentElement.classList.remove('sb-embedded'); return r""")
        check(emb == ['none', 'none'], "the app's embedded sample shows no sidebar or toggle", json.dumps(emb))

        csp = [l for l in page.logs if 'csp blocked' in l]
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l]
        check(not csp and not errs, 'no CSP violations or page errors logged', json.dumps(csp + errs)[:300])
    finally:
        page.close()
        shutil.rmtree(page.out, ignore_errors=True)

    print(f'\n{sum(results)}/{len(results)} sidebar checks passed')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
