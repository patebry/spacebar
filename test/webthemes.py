#!/usr/bin/env python3
"""Themes and settings in the page on its own, outside Quick Look: Preview/web in the offscreen WKWebView harness
(test/web/main.swift, built with the extension's SchemeHandler and document-start settings script) against a scratch
SPACEBAR_SUPPORT_DIR. Checks every built-in theme in light and dark, the no-flash document-start script, a live settings switch
during an inline edit, the Aa popover, front matter, the table of contents, reading stats, mermaid re-theming, user themes and
custom.css, and that the `user` host serves nothing but those. Saves screenshots to docs/evidence/themes/."""
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, 'Preview', 'web')
SHOTS = os.path.join(ROOT, 'docs', 'evidence', 'themes')
THEMES = ['apple', 'github', 'paper', 'solarized', 'nord', 'contrast']


class Page:
    """The harness in stdin mode: one command in, one JSON line out."""

    def __init__(self):
        self.out = tempfile.mkdtemp(prefix='spacebar-webthemes-')
        self.support = os.path.join(self.out, 'support')
        os.makedirs(os.path.join(self.support, 'themes'))
        exe = os.path.join(self.out, 'webcheck')
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos13.0',
                        os.path.join(ROOT, 'test', 'web', 'main.swift'), os.path.join(ROOT, 'Shared', 'Settings.swift'),
                        os.path.join(ROOT, 'Shared', 'WebShell.swift'),
                        os.path.join(ROOT, 'Shared', 'FolderListing.swift'), os.path.join(ROOT, 'Shared', 'LinkPolicy.swift'), os.path.join(ROOT, 'Preview', 'PDFPane.swift'), '-o', exe], check=True)
        self.proc = subprocess.Popen([exe, WEB], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                     env=dict(os.environ, SPACEBAR_SUPPORT_DIR=self.support))
        self.logs = []

    def cmd(self, c):
        self.proc.stdin.write(json.dumps(c) + '\n')
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f'harness exited during {c[:80]}')
        r = json.loads(line)
        self.logs += [m.get('msg', '') for m in r['messages'] if m.get('type') == 'log']
        return r

    def js(self, expr):
        """Evaluates an expression; objects come back through JSON."""
        r = self.cmd('@eval:JSON.stringify((() => { ' + expr + ' })())')['result']
        return json.loads(r) if isinstance(r, str) and not r.startswith('ERR') else r

    def apply(self, **kw):
        return self.cmd('@apply:' + json.dumps(kw))

    def render(self, path):
        return self.cmd('@render:' + path)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=20)


# Resolved colours of the current page: page background and text, the accent, and code token colours.
COLOURS = """
  const probe = (css) => { const s = document.createElement('span'); s.style.color = css; document.body.append(s);
    const c = getComputedStyle(s).color; s.remove(); return c; };
  const tok = (cls) => { const n = document.querySelector('#doc .' + cls); return n ? getComputedStyle(n).color : null; };
  return { bg: getComputedStyle(document.documentElement).backgroundColor, fg: getComputedStyle(document.body).color,
    accent: probe('var(--accent)'), link: probe('var(--link)'), sysAccent: probe('-apple-system-control-accent'),
    keyword: tok('hljs-keyword'), string: tok('hljs-string'), title: tok('hljs-title'),
    pre: getComputedStyle(document.querySelector('#doc pre:not(.mermaid)')).backgroundColor,
    theme: document.documentElement.dataset.theme };
"""

# WCAG contrast of every text colour against what it is drawn on, per theme and appearance. Colours are resolved by the page
# (var(), color-mix(), system colours, relative colours) and composited on a canvas, layer by layer, as they are painted.
TOKENS = ['fg', 'keyword', 'string', 'comment', 'number', 'title', 'type', 'attr', 'builtin', 'meta', 'variable', 'addition', 'deletion']
HELPERS = """
  const cv = document.createElement('canvas'); cv.width = cv.height = 1;
  const cx = cv.getContext('2d', { willReadFrequently: true });
  const val = (ctx, css) => { const s = document.createElement('span'); s.style.color = css; ctx.append(s); const c = getComputedStyle(s).color; s.remove(); return c; };
  const paint = (layers) => { cx.globalCompositeOperation = 'copy'; cx.fillStyle = '#000'; cx.fillRect(0, 0, 1, 1);
    cx.globalCompositeOperation = 'source-over';
    // A colour the canvas cannot parse leaves the sentinel in place; that fails the check instead of painting black.
    for (const c of layers) { cx.fillStyle = '#010203'; cx.fillStyle = c; if (cx.fillStyle === '#010203') return null; cx.fillRect(0, 0, 1, 1); }
    return [...cx.getImageData(0, 0, 1, 1).data.slice(0, 3)]; };
  const lum = (p) => { const [r, g, b] = p.map((v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  const root = document.documentElement, bar = document.getElementById('toolbar');
  const measure = (ctx, fg, under) => { const bg = under.map((v) => val(ctx, v)), text = val(ctx, fg);
    const t = paint([...bg, text]), b = paint(bg);
    return { text, bg: bg.join(' + '), ratio: t && b ? Math.round(ratio(t, b) * 100) / 100 : 0 }; };
"""
CONTRAST = HELPERS + """
  const out = [];
  const pair = (name, ctx, fg, under) => out.push({ name, ...measure(ctx, fg, under) });
  const B = 'var(--bg)';
  pair('fg/bg', root, 'var(--fg)', [B]);
  pair('fg/code-bg', root, 'var(--fg)', [B, 'var(--code-bg)']);
  pair('muted/bg', root, 'var(--muted)', [B]);
  pair('muted/code-bg', root, 'var(--muted)', [B, 'var(--code-bg)']);
  pair('quote/bg', root, 'var(--quote)', [B]);
  pair('link/bg', root, 'var(--link)', [B]);
  for (const t of TOKENS) {
    pair(`hl-${t}/hl-bg`, root, `var(--hl-${t})`, [B, 'var(--hl-bg)']);
    pair(`hl-${t}/code-bg`, root, `var(--hl-${t})`, [B, 'var(--code-bg)']);
    if (t === 'addition' || t === 'deletion') pair(`hl-${t}/tinted`, root, `var(--hl-${t})`, [B, 'var(--hl-bg)', `color-mix(in srgb, var(--hl-${t}) 10%, transparent)`]);
  }
  pair('toolbar muted/bg', bar, 'var(--ui-muted)', [B]);
  pair('toolbar fg/button', bar, 'var(--ui-fg)', [B, 'var(--ui-bg)']);
  pair('popover muted/segment', bar, 'var(--ui-muted)', [B, 'var(--ui-pop)', 'var(--ui-seg)']);
  pair('popover fg/popover', bar, 'var(--ui-fg)', [B, 'var(--ui-pop)']);
  return out;
""".replace('TOKENS', json.dumps(TOKENS))

# The Apple link under other system accent colours (the macOS accent palette), through the same relative-colour clamp.
ACCENTS = ['#007aff', '#953d96', '#f74f9e', '#e0383e', '#f7821b', '#ffc600', '#62ba46', '#8c8c8c']
ACCENT_LINKS = HELPERS + """
  const out = {};
  for (const a of ACCENTS) { root.style.setProperty('--sys-accent', a); out[a] = measure(root, 'var(--link)', ['var(--bg)']).ratio; }
  root.style.removeProperty('--sys-accent');
  return out;
"""


MERMAID_FILL = """
  const n = document.querySelector('#doc pre.mermaid svg .node rect, #doc pre.mermaid svg .node polygon, #doc pre.mermaid svg .node path');
  const e = document.querySelector('#doc pre.mermaid svg .flowchart-link, #doc pre.mermaid svg path.path');
  return { svgs: document.querySelectorAll('#doc pre.mermaid svg').length, fill: n && getComputedStyle(n).fill,
           stroke: n && getComputedStyle(n).stroke, edge: e && getComputedStyle(e).stroke };
"""

# Samples every diagram at each DOM mutation (before the page can paint it) and at each animation frame, until __mm.stop.
MM_SAMPLER = """
  const hash = (t) => { let h = 0; for (let i = 0; i < t.length; i++) h = (h * 31 + t.charCodeAt(i)) | 0; return h; };
  const mm = window.__mm = { samples: [], stop: false };
  const sample = (when) => {
    const stage = document.getElementById('mm-stage');
    const strays = [...document.querySelectorAll('[id^="dsb-mermaid"], [id^="dmermaid"], [id^="isb-mermaid"]')].filter((e) => !e.closest('#mm-stage')).length;
    for (const n of document.querySelectorAll('#doc pre.mermaid')) {
      const cs = getComputedStyle(n), svg = n.querySelector(':scope > svg'), r = n.getBoundingClientRect();
      const text = [...n.childNodes].filter((c) => c.nodeType === 3).map((c) => c.textContent).join('').trim();
      mm.samples.push({ when, text: !!text && cs.visibility === 'visible' && cs.opacity !== '0' && !/, 0\\)$/.test(cs.color),
        wait: n.classList.contains('mm-wait'), svg: svg ? hash(svg.outerHTML) : null, laid: svg ? !!svg.getAttribute('viewBox') && svg.getBoundingClientRect().height > 0 : null,
        anim: svg ? getComputedStyle(svg).animationName : null, h: Math.round(r.height), strays,
        stageOff: !stage || (stage.getBoundingClientRect().right <= 0 && getComputedStyle(stage).visibility === 'hidden') });
    }
  };
  new MutationObserver(() => { if (!mm.stop) sample('mutation'); }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['class', 'style'] });
  const frame = () => { if (mm.stop) return; sample('frame'); requestAnimationFrame(frame); };
  requestAnimationFrame(frame);
  return true;
"""
MM_STOP = "window.__mm.stop = true; return window.__mm.samples"

CLICK = """(sel) => { const t = document.querySelector(sel); if (!t) return false; const r = t.getBoundingClientRect();
  for (const type of ['mouseover', 'mousedown', 'mouseup', 'click'])
    t.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: r.left + 3, clientY: r.top + 3, detail: 1 }));
  return true; }"""


def click(page, sel):
    return page.cmd('@eval:(' + CLICK + ')(' + json.dumps(sel) + ')')


def main():
    os.makedirs(SHOTS, exist_ok=True)
    results = []

    def check(ok, name, detail=''):
        results.append(bool(ok))
        print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ''))

    page = Page()
    demo = os.path.join(ROOT, 'test', 'fixtures', 'demo.md')
    corpus = os.path.join(ROOT, 'test', 'corpus')
    try:
        # ---- document start: a non-default theme is on <html> before the first DOMContentLoaded ----
        page.cmd('@load:' + json.dumps({'theme': 'solarized', 'fontSize': 18, 'width': 'wide'}))
        p = page.js('return window.__sbProbe')
        check(p.get('start') == 'solarized' and p.get('dcl') == 'solarized' and p.get('dclFontSize') == '18px' and p.get('dclWidth') == 'wide'
              and not p.get('head'), 'document-start script sets the theme before <head> exists (no flash)', json.dumps(p))
        page.cmd('@load:{}')
        page.cmd('@size:1000x760')

        # ---- every theme x light/dark ----
        page.render(demo)
        seen = {}
        for mode in ('light', 'dark'):
            page.cmd('@appearance:' + mode)
            for t in THEMES:
                page.apply(theme=t)
                page.cmd('@wait:0.8')
                c = page.js(COLOURS)
                seen[(t, mode)] = c
                low = [p for p in page.js(CONTRAST) if p['ratio'] < 4.5]
                check(not low, f'theme {t} {mode}: text, code tokens, links and toolbar text reach 4.5:1',
                      '; '.join(f"{p['name']} {p['ratio']} ({p['text']} on {p['bg']})" for p in low))
                if t == 'apple':
                    ratios = page.js(ACCENT_LINKS.replace('ACCENTS', json.dumps(ACCENTS)))
                    low = {a: r for a, r in ratios.items() if r < 4.5}
                    check(not low, f'apple {mode}: links reach 4.5:1 with every system accent colour', json.dumps(ratios))
                page.cmd('@eval:scrollTo(0, 0); 0')
                page.cmd(f'@shot:{SHOTS}/theme-{t}-{mode}.png')
        for t in THEMES:
            l, d = seen[(t, 'light')], seen[(t, 'dark')]
            ok = l['bg'] != d['bg'] and l['fg'] != d['fg'] and (l['keyword'], l['string'], l['pre']) != (d['keyword'], d['string'], d['pre']) \
                and all(c['keyword'] and c['keyword'] != c['fg'] and c['string'] != c['fg'] for c in (l, d))
            check(ok, f'theme {t}: light and dark differ, code tokens coloured',
                  f"light bg {l['bg']} fg {l['fg']} kw {l['keyword']} / dark bg {d['bg']} fg {d['fg']} kw {d['keyword']}")
        for mode in ('light', 'dark'):
            sigs = {t: (seen[(t, mode)]['bg'], seen[(t, mode)]['fg'], seen[(t, mode)]['keyword']) for t in THEMES}
            check(len(set(sigs.values())) == len(THEMES), f'all six themes distinct in {mode}', json.dumps(sigs))
        a = seen[('apple', 'light')]
        check(a['accent'] == a['sysAccent'] and seen[('apple', 'dark')]['accent'] == seen[('apple', 'dark')]['sysAccent'],
              'apple follows the system accent colour', f"accent {a['accent']} system {a['sysAccent']}")

        # code theme from another theme
        page.cmd('@appearance:light')
        page.apply(theme='github', codeTheme='nord')
        c = page.js(COLOURS)
        check(c['keyword'] == seen[('nord', 'light')]['keyword'] and c['bg'] == seen[('github', 'light')]['bg'],
              'codeTheme takes code colours from another theme', f"kw {c['keyword']} bg {c['bg']}")
        page.apply(codeTheme='auto', theme='apple')

        # ---- mermaid never flashes: no source, no half-drawn SVG, a placeholder until the finished SVG goes in ----
        page.cmd('@load:{}')
        page.cmd('@appearance:light')
        lazy = page.js("return typeof window.mermaid")
        page.js(MM_SAMPLER)
        r = page.render(demo)
        page.cmd('@wait:1.5')
        first = page.js(MM_STOP)
        final = first[-1]['svg'] if first else None
        waits = [i for i, x in enumerate(first) if x['wait']]
        svgs = [i for i, x in enumerate(first) if x['svg'] is not None]
        types = [m.get('type') for m in r['messages']]
        check(lazy == 'undefined' and first and not any(x['text'] for x in first), 'mermaid: its source is never visible, even while mermaid itself loads',
              f"lazy {lazy}, {len(first)} samples, {sum(x['text'] for x in first)} with source")
        check(waits and all(first[i]['h'] >= 120 and first[i]['svg'] is None for i in waits) and 'painted' in types and types.index('painted') < types.index('rendered'),
              'mermaid: a blank placeholder holds the space from the first paint, and the panel shows before mermaid finishes',
              f"{len(waits)} placeholder samples, heights {sorted({first[i]['h'] for i in waits})}")
        check(svgs and waits and svgs[0] > waits[-1] and all(first[i]['svg'] == final and first[i]['laid'] for i in svgs)
              and first[svgs[0]]['anim'] == 'mm-in', 'mermaid: revealed only when finished (every SVG seen is the final, laid-out one), with a fade',
              f"first svg at {svgs[:1]}, last placeholder at {waits[-1:]}, anim {first[svgs[0]]['anim'] if svgs else None}")
        check(all(x['strays'] == 0 and x['stageOff'] for x in first), "mermaid: its drawing area never reaches the page (off screen, hidden, outside the body's row)")
        motion = page.js("""const out = []; const walk = (rules) => { for (const r of rules) { if (r.cssRules) walk(r.cssRules);
            if (r.media && /prefers-reduced-motion/.test(r.media.mediaText))
              for (const x of r.cssRules) if (x.selectorText && x.selectorText.includes('mm-in')) out.push(x.style.animationName); } };
          for (const sh of document.styleSheets) { try { walk(sh.cssRules); } catch (e) {} } return out.join(' ')""")
        check(motion == 'none', 'mermaid: the fade is off under reduced motion', motion)
        before_h = first[-1]['h']
        for label, act in (('a theme switch', lambda: page.apply(theme='nord')), ('the colour scheme flipping', lambda: page.cmd('@appearance:dark')),
                           ('an inline-edit redraw', lambda: click(page, '#doc > p')), ('a live reload of the same text', lambda: page.render(demo))):
            old = page.js("const s = document.querySelector('#doc pre.mermaid > svg'); return s && s.outerHTML.length")
            page.js(MM_SAMPLER)
            act()
            page.cmd('@wait:1.5')
            got = page.js(MM_STOP)
            states = {x['svg'] for x in got}
            # The diagram on screen keeps the class of its first fade; the one swapped in must not fade again.
            swapped = [x for x in got if got and x['svg'] != got[0]['svg']]
            check(got and all(x['svg'] is not None and x['laid'] and not x['wait'] and not x['text'] and x['h'] > 0 and not x['strays'] and x['stageOff'] for x in got)
                  and len(states) <= 2 and all(x['anim'] == 'none' for x in swapped),
                  f'mermaid: {label} swaps the finished diagram in place, with no placeholder, source or fade in between',
                  f"{len(got)} samples, {len(states)} states, waits {sum(x['wait'] for x in got)}, anims {sorted({str(x['anim']) for x in got})}")
            if label == 'an inline-edit redraw':
                page.cmd('@eval:sb.editEnd({}); 0')
        page.apply(theme='apple')
        page.cmd('@appearance:light')
        page.cmd('@wait:1')
        # A changed diagram waits in a placeholder as tall as the diagram it replaces.
        text = open(demo).read().replace('C --> D[WKWebView]', 'C --> D[WKWebView]\n  D --> E[Page]')
        tall = page.js("return Math.round(document.querySelector('#doc pre.mermaid').getBoundingClientRect().height)")
        held = page.js("const p = { path: " + json.dumps(demo) + ", name: 'demo.md', base: 'spacebar://file" + os.path.dirname(demo) + "/', reason: 'change', ver: 0, root: " + json.dumps(os.path.dirname(demo)) + ", rootName: 'fixtures', text: "
                       + json.dumps(text) + " }; sb.render(p); const n = document.querySelector('#doc pre.mermaid');"
                       " return [n.classList.contains('mm-wait'), Math.round(n.getBoundingClientRect().height), n.textContent]")
        page.cmd('@wait:1.5')
        check(held[0] and abs(held[1] - tall) <= 1 and held[2] == '' and page.js("return !!document.querySelector('#doc pre.mermaid > svg')"),
              'mermaid: a changed diagram keeps the previous size while it is drawn', f'{held[:2]} vs {tall}')
        page.render(demo)
        page.cmd('@wait:1')
        # What cannot be drawn shows its source, marked: a diagram mermaid rejects, and every diagram when mermaid fails to load.
        bad = os.path.join(page.out, 'bad-mermaid.md')
        open(bad, 'w').write('# Bad\n\n```mermaid\ngraph LR\n  A -->\n```\n')
        page.render(bad)
        page.cmd('@wait:1')
        err = page.js("const n = document.querySelector('#doc pre.mermaid'); return [n.className, n.textContent.trim(), !!n.querySelector('svg')]")
        check(err == ['mermaid mm-error', 'graph LR\n  A -->', False], 'mermaid: a diagram it cannot draw shows its source, marked', json.dumps(err))
        open(bad, 'w').write('# Bad\n\n```mermaid\ngraph TD\n  Q --> R\n```\n')
        page.cmd("@eval:window.__ml = mermaidLoaded; const p = Promise.reject(new Error('load failed (test)')); p.catch(() => {}); mermaidLoaded = p; 0")
        page.render(bad)
        page.cmd('@wait:1')
        err = page.js("const n = document.querySelector('#doc pre.mermaid'); return [n.className, n.textContent.trim()]")
        page.cmd('@eval:mermaidLoaded = window.__ml; 0')
        check(err == ['mermaid mm-error', 'graph TD\n  Q --> R'], 'mermaid: if mermaid fails to load, diagrams show their source instead of staying blank', json.dumps(err))
        page.logs = [l for l in page.logs if not (l.startswith('mermaid:') and ('load failed (test)' in l or 'Parse error' in l or 'Syntax error' in l or 'Expecting' in l))]
        # Two copies of one diagram never share element ids (arrow markers resolve by id).
        twin = os.path.join(page.out, 'twin.md')
        open(twin, 'w').write('# Twins\n\n```mermaid\ngraph LR\n  A --> B\n```\n\n```mermaid\ngraph LR\n  A --> B\n```\n')
        page.render(twin)
        page.cmd('@wait:1')
        page.render(twin)
        ids = page.js("return [...document.querySelectorAll('#doc pre.mermaid [id]')].map((e) => e.id)")
        check(ids and len(ids) == len(set(ids)) and page.js("return document.querySelectorAll('#doc pre.mermaid > svg').length") == 2,
              'mermaid: identical diagrams, drawn or put back from the cache, have distinct ids', f'{len(ids)} ids, {len(set(ids))} distinct')
        page.render(demo)
        page.cmd('@wait:1')

        # ---- mermaid re-theming ----
        page.cmd('@wait:1')
        before = page.js(MERMAID_FILL)
        page.apply(theme='nord')
        page.cmd('@wait:1.5')
        after = page.js(MERMAID_FILL)
        check(before['svgs'] == 1 and after['svgs'] == 1 and before['fill'] and (before['fill'], before['stroke']) != (after['fill'], after['stroke']),
              'mermaid re-themes on a theme switch and stays drawn', f'{json.dumps(before)} -> {json.dumps(after)}')
        page.cmd('@appearance:dark')
        page.cmd('@wait:1.5')
        dark = page.js(MERMAID_FILL)
        check(dark['svgs'] == 1 and dark['fill'] != after['fill'], 'mermaid re-themes when the colour scheme flips', json.dumps(dark))
        page.cmd('@appearance:light')

        # ---- mermaid stays drawn through inline edits: every diagram outside the edited block is an SVG, never its source ----
        DIAGRAMS = "return [...document.querySelectorAll('#doc pre.mermaid')].map((n) => !!n.querySelector('svg'))"
        page.render(demo)
        page.cmd('@wait:1')
        click(page, '#doc > p')
        page.cmd('@wait:1')
        steps = [('while a paragraph is edited', page.js(DIAGRAMS))]
        click(page, '#doc > ul')
        page.cmd('@wait:1')
        steps.append(('after the edit moves to another block', page.js(DIAGRAMS)))
        page.cmd("@eval:sb.editEnd({}); 0")
        page.cmd('@wait:1')
        steps.append(('after editEnd (Esc, focus loss)', page.js(DIAGRAMS)))
        click(page, '#doc > p')
        click(page, '#doc')
        page.cmd('@wait:1')
        steps.append(('after a click outside every block', page.js(DIAGRAMS)))
        click(page, '#doc > p')
        page.cmd("@eval:sb.editReset({ seq: -1, at: 0, old: 0, repl: [], text: '', ver: 0 }); 0")
        page.cmd('@wait:1')
        steps.append(("after another session's splice redraws", page.js(DIAGRAMS)))
        page.cmd("@eval:sb.editEnd({}); 0")
        check(all(d == [True] for _, d in steps), 'mermaid is redrawn after every inline-edit redraw', json.dumps(steps))

        # ---- live switch during an inline edit ----
        page.apply(theme='apple', fontSize=15)
        page.render(demo)
        click(page, '#doc > p')
        ed = page.js("const e = document.querySelector('#doc > .md-editing'); return e && e.textContent")
        r = page.apply(theme='nord', fontSize=19, toc='on')
        ed2 = page.js("const e = document.querySelector('#doc > .md-editing'); return e && e.textContent")
        root = page.js("const r = document.documentElement; return [r.dataset.theme, r.style.getPropertyValue('--font-size'), getComputedStyle(document.body).fontSize]")
        logs = [m.get('msg') for m in r['messages'] if m.get('type') == 'log']
        check(ed and ed == ed2 and 'settings applied theme=nord' in logs and root == ['nord', '19px', '19px'],
              'applySettings during an inline edit keeps the editor and its text', f'editor {ed!r} -> {ed2!r}, root {root}, logs {logs}')
        page.apply(toc='auto', fontSize=15, theme='apple')

        # ---- settings that change what is rendered ----
        page.apply(math=False, mermaid=False, taskToggles=False)
        off = page.js("""return { katex: document.querySelectorAll('#doc .katex').length, tex: document.querySelectorAll('#doc .tex-src').length,
          mermaid: document.querySelectorAll('#doc pre.mermaid').length, code: [...document.querySelectorAll('#doc pre code')].some((c) => /graph LR/.test(c.textContent)),
          disabled: [...document.querySelectorAll('#doc input[type=checkbox]')].every((b) => b.disabled),
          editing: !!document.querySelector('#doc > .md-editing') }""")
        check(off['katex'] == 0 and off['tex'] >= 2 and off['mermaid'] == 0 and off['code'] and off['disabled'] and off['editing'],
              'math/mermaid off show source; task toggles off disable boxes; edit still open', json.dumps(off))
        page.apply(math=True, mermaid=True, taskToggles=True, inlineEditing=False)
        page.render(demo)
        click(page, '#doc > p')
        n = page.js("return [!!document.querySelector('#doc > .md-editing'), document.documentElement.dataset.editing]")
        check(n == [False, 'off'], 'inlineEditing off: a click starts no edit', json.dumps(n))
        page.apply(inlineEditing=True, rawHTML='off')
        raw = os.path.join(page.out, 'raw.md')
        open(raw, 'w').write('Some <b>bold</b> html.\n')
        page.render(raw)
        h = page.js("return [document.querySelectorAll('#doc b').length, document.querySelector('#doc p').textContent]")
        check(h[0] == 0 and '<b>bold</b>' in h[1], "rawHTML off renders the document's HTML as text", json.dumps(h))
        page.apply(rawHTML='sanitized')

        # ---- stats ----
        page.render(demo)
        page.cmd('@wait:0.3')
        s = page.js("return document.getElementById('stats').textContent")
        check(s and 'words' in s and 'min read' in s, 'reading stats shown', repr(s))
        page.apply(stats=False)
        s2 = page.js("return document.getElementById('stats').textContent")
        check(s2 == '', 'stats off hides them', repr(s2))
        page.apply(stats=True)

        # ---- Aa popover ----
        page.render(demo)
        closed = page.js("""const pop = document.getElementById('aa-pop'); const d = document.getElementById('doc').getBoundingClientRect();
          const hits = []; for (let x = innerWidth - 300; x < innerWidth - 10; x += 20) for (let y = 40; y < 420; y += 20) {
            const e = document.elementFromPoint(x, y); if (e && e.closest('#toolbar')) hits.push([x, y]); }
          return { hidden: pop.hidden, display: getComputedStyle(pop).display, hits: hits.length }""")
        check(closed['hidden'] and closed['display'] == 'none' and closed['hits'] == 0, 'closed popover covers nothing', json.dumps(closed))
        click(page, '#aa')
        opened = page.js("return !document.getElementById('aa-pop').hidden")
        page.cmd('@wait:0.3')
        page.cmd(f'@shot:{SHOTS}/popover.png')
        steps = [('#aa-pop .swatch[data-value=paper]', {'type': 'setting', 'key': 'theme', 'value': 'paper'}, "document.documentElement.dataset.theme", 'paper'),
                 ('#aa-larger', {'type': 'setting', 'key': 'fontSize', 'value': '16'}, "document.documentElement.style.getPropertyValue('--font-size')", '16px'),
                 ('#aa-smaller', {'type': 'setting', 'key': 'fontSize', 'value': '15'}, "document.documentElement.style.getPropertyValue('--font-size')", '15px'),
                 ('#aa-width [data-value=wide]', {'type': 'setting', 'key': 'width', 'value': 'wide'}, "document.documentElement.dataset.width", 'wide'),
                 ('#aa-font [data-value=serif]', {'type': 'setting', 'key': 'bodyFont', 'value': 'serif'}, "document.documentElement.dataset.font", 'serif')]
        for sel, want, attr, val in steps:
            r = click(page, sel)
            posted = [m for m in r['messages'] if m.get('type') == 'setting']
            got = page.js('return ' + attr)
            ok = len(posted) == 1 and all(posted[0].get(k) == v for k, v in want.items()) and got == val \
                and not [m for m in r['messages'] if m.get('type') in ('editBlock', 'link')]
            check(ok, f'popover {sel} posts {want["key"]}={want["value"]} and applies it', f'{posted} root={got}')
        checked = page.js("return [...document.querySelectorAll('#aa-pop [aria-checked=true]')].map((b) => b.dataset.value)")
        check(sorted(checked) == ['paper', 'serif', 'wide'], 'popover shows the current choices', json.dumps(checked))
        r = click(page, '#aa-settings')
        o = [m for m in r['messages'] if m.get('type') == 'openSettings']
        check(len(o) == 1 and o[0].get('tab') == 'appearance' and page.js("return document.getElementById('aa-pop').hidden"),
              "'Settings…' posts openSettings and closes the popover", json.dumps(o))
        click(page, '#aa')
        r = click(page, '#doc > p')
        still = page.js("return [document.getElementById('aa-pop').hidden, !!document.querySelector('#doc > .md-editing')]")
        check(opened and still == [True, False] and not [m for m in r['messages'] if m.get('type') == 'editBlock'],
              'a click outside closes the popover and starts no edit', json.dumps(still))
        page.apply(theme='apple', width='medium', bodyFont='system', fontSize=15)

        # ---- front matter ----
        fm = os.path.join(corpus, 'frontmatter.md')
        page.render(fm)
        f = page.js("""const d = document.getElementById('doc'); const first = d.querySelector(':scope > [data-src]');
          return { table: !!d.querySelector(':scope > table.frontmatter'), firstChild: d.firstElementChild.className, tableSrc: d.querySelector('.frontmatter')?.dataset.src ?? null,
            rows: [...d.querySelectorAll('.frontmatter tr')].map((r) => [r.cells[0].textContent, r.cells[1].textContent]),
            hr: d.querySelectorAll('hr').length, h2: d.querySelectorAll('h2').length, first: first && [first.tagName, first.dataset.src] }""")
        check(f['table'] and f['firstChild'] == 'frontmatter' and f['tableSrc'] is None and f['hr'] == 0 and f['h2'] == 0
              and f['first'] == ['H1', '5,6'] and ['title', 'Test'] in f['rows'],
              'front matter renders as a table, no <hr> or setext heading, true line numbers after it', json.dumps(f))
        r = click(page, '#doc .frontmatter td')
        check(not [m for m in r['messages'] if m.get('type') == 'editBlock'], 'a click on the front matter starts no edit')
        r = click(page, '#doc > p')
        eb = [m for m in r['messages'] if m.get('type') == 'editBlock']
        check(eb and eb[0].get('start') == '7' and eb[0].get('text') == 'Text.', 'inline edit after front matter maps to the right line', json.dumps(eb)[:200])
        page.apply(frontMatter='raw')
        raw = page.js("const p = document.querySelector('#doc > pre.frontmatter-raw'); return p && p.textContent")
        page.apply(frontMatter='hide')
        hid = page.js("return [document.querySelectorAll('#doc .frontmatter, #doc .frontmatter-raw').length, document.querySelectorAll('#doc hr').length]")
        check(raw and raw.startswith('---\ntitle: Test') and hid == [0, 0] and page.js("return !!document.querySelector('#doc > .md-editing')"),
              'front matter raw and hide (edit kept across both)', f'{raw!r} {hid}')
        page.apply(frontMatter='table')

        # ---- table of contents ----
        heads = os.path.join(corpus, 'headings.md')
        page.render(heads)
        t = page.js("""const n = document.getElementById('toc'); return { shown: !n.hidden, inDoc: !!document.querySelector('#doc #toc'),
          entries: [...n.querySelectorAll('a')].map((a) => a.textContent), display: getComputedStyle(n).display }""")
        check(t['shown'] and not t['inDoc'] and t['entries'] == ['Title', 'Section', 'Sub'], 'TOC for 3 headings, outside #doc', json.dumps(t))
        r = click(page, '#toc a[data-toc="2"]')
        bad = [m for m in r['messages'] if m.get('type') in ('link', 'editBlock', '_navigation')]
        check(not bad, 'a TOC click posts no link and starts no edit', json.dumps(bad))
        page.render(fm)
        check(page.js("return document.getElementById('toc').hidden"), 'no TOC under 3 headings (toc=auto)')
        page.apply(toc='on')
        check(not page.js("return document.getElementById('toc').hidden"), 'toc=on shows it for 1 heading')
        page.apply(toc='off')
        page.render(heads)
        check(page.js("return document.getElementById('toc').hidden"), 'toc=off hides it')
        page.apply(toc='auto')
        page.cmd('@size:800x760')
        check(page.js("return getComputedStyle(document.getElementById('toc')).display") == 'none', 'TOC hidden in a narrow window')
        page.cmd('@size:1100x760')
        # A stable folder name: the sidebar shows it in the screenshot.
        os.makedirs(os.path.join(page.out, 'notes'), exist_ok=True)
        long = os.path.join(page.out, 'notes', 'toc.md')
        shutil.copy(os.path.join(ROOT, 'test', 'fixtures', 'img.png'), os.path.join(page.out, 'notes'))
        open(long, 'w').write(open(fm).read() + '\n' + open(os.path.join(ROOT, 'test', 'fixtures', 'demo.md')).read().replace('# spacebar demo', '## Overview')
                              + '\n## Notes\n\nA closing paragraph with *emphasis*, `code`, and a [link](https://example.com).\n\n### Details\n\n> A quote to end on.\n')
        page.render(long)
        page.cmd('@wait:1.2')
        page.cmd(f'@shot:{SHOTS}/toc-frontmatter.png')
        page.cmd('@size:1000x760')

        # ---- user theme, custom.css, and the user host's limits ----
        open(os.path.join(page.support, 'themes', 'test.css'), 'w').write(
            '/* spacebar-theme name="Test" appearance=auto */\n:root { --bg: rgb(1, 2, 3); --fg: rgb(250, 250, 250); --link: rgb(10, 20, 30); }\n')
        page.render(demo)
        page.apply(userTheme='test.css')
        page.cmd('@wait:0.5')
        u = page.js(COLOURS)
        check(u['bg'] == 'rgb(1, 2, 3)' and u['fg'] == 'rgb(250, 250, 250)', 'a user theme overrides the built-in', f"bg {u['bg']} fg {u['fg']}")
        open(os.path.join(page.support, 'custom.css'), 'w').write(':root { --link: rgb(200, 100, 50); } #doc h1 { letter-spacing: 3px; }\n')
        page.apply(customCSS=True)
        page.apply(fontSize=16)  # a new payload: custom.css now exists, so it carries its URL
        page.cmd('@wait:0.5')
        cu = page.js("""const a = document.querySelector('#doc a'); const links = [...document.querySelectorAll('link[id^=sb-]')].map((l) => l.id);
          return { link: getComputedStyle(a).color, h1: getComputedStyle(document.querySelector('#doc h1')).letterSpacing, order: links }""")
        check(cu['link'] == 'rgb(200, 100, 50)' and cu['h1'] == '3px' and cu['order'] == ['sb-user-theme', 'sb-custom-css'],
              'custom.css loads last and wins over the user theme', json.dumps(cu))
        page.apply(customCSS=False, userTheme=None)
        gone = page.js("return [document.querySelectorAll('link[id^=sb-]').length, getComputedStyle(document.documentElement).backgroundColor]")
        check(gone[0] == 0 and gone[1] != 'rgb(1, 2, 3)', 'turning them off removes both', json.dumps(gone))
        open(os.path.join(page.support, 'settings.json'), 'w').write('{"theme": "nord"}\n')
        # Dot segments (plain or %2E-encoded) are resolved by the URL parser before any request, so these reach the handler as
        # /settings.json; an encoded slash reaches it verbatim. Each must fail to load.
        probes = ['spacebar://user/../settings.json', 'spacebar://user/themes/..%2Fsettings.json', 'spacebar://user/settings.json',
                  'spacebar://user/%2E%2E/settings.json', 'spacebar://user/themes/test.css/../../settings.json', 'spacebar://user/themes/%2E%2E%2Fcustom.css',
                  'spacebar://user//custom.css', 'spacebar://user/themes/test.css%00.css']
        r = page.cmd('@eval:window.__probe = {}; ' + ''.join(
            f"(() => {{ const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = {json.dumps(u)};"
            f" l.addEventListener('load', () => window.__probe[{i}] = 'load'); l.addEventListener('error', () => window.__probe[{i}] = 'error');"
            f" document.head.append(l); }})();" for i, u in enumerate(probes)) + ' 0')
        page.cmd('@wait:1')
        r2 = page.cmd('@eval:0')
        refused = sorted({m['msg'].replace('refused load ', '') for m in r['messages'] + r2['messages'] if m.get('type') == '_refused'})
        outcome = page.js('return window.__probe')
        check(all(outcome.get(str(i)) == 'error' for i in range(len(probes))) and refused,
              'the user host refuses anything but custom.css and themes/<file>.css',
              f"{json.dumps(outcome)}; handler refused: {'; '.join(refused)}")

        csp = [l for l in page.logs if 'csp blocked' in l]
        errs = [l for l in page.logs if l.startswith(('rejection', 'mermaid')) or ' @' in l]
        check(not csp and not errs, 'no CSP violations or page errors logged', json.dumps(csp + errs)[:300])
    finally:
        page.close()

    print(f'\n{sum(results)}/{len(results)} theme checks passed; screenshots in {SHOTS}')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
