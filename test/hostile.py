#!/usr/bin/env python3
"""Hostile documents (PROBE=1 build): raw HTML that tries to reach the unsandboxed writer.

Each fixture in test/hostile is copied into one mktemp -d folder with its payload filled in and previewed by a qlmanage this
script launches. The payload, wherever it could run, marks window.__pwned and posts link, open, toggle and edit messages.
Every link, SVG link and mermaid node is then clicked with a DOM event through the probe's `cmd=` channel (no OS input),
because a user clicking a hostile link must not open an app either. A fixture passes when the page never ran the payload,
the DOM holds no script, frame, handler attribute or script URL, the file is unchanged, and the logs show no open or write
by the writer and no in-panel switch to another file.
"""
import base64, json, os, re, shutil, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlcommon import start_log, launch, wait_for, require_idle, probe_conf

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hostile')
OUT = tempfile.mkdtemp(prefix='spacebar-hostile-')
LOG = os.path.join(OUT, 'hostile.log')
CMD = os.path.join(OUT, 'cmd.json')


def payload(name, file):
    post = "window.webkit.messageHandlers.sb.postMessage"
    return ("(window.__pwned=(window.__pwned||[]).concat('%s'),"
            "%s({type:'link',href:'https://pwned.invalid/%s'}),"
            "%s({type:'link',href:'spacebar://file/System/Applications/Calculator.app'}),"
            "%s({type:'open',path:'/System/Applications/Calculator.app'}),"
            "%s({type:'toggle',path:'%s',line:0,text:'-\\x20[\\x20]\\x20bait\\x20task',checked:true,ver:0}),"
            "%s({type:'edit'}))") % (name, post, name, post, post, post, file, post)


def materialize():
    for f in os.listdir(HERE):
        src = open(os.path.join(HERE, f)).read()
        name = os.path.splitext(f)[0]
        path = os.path.join(OUT, f)
        src = (src.replace('@@PAYLOAD@@', payload(name, path)).replace('@@DIRREL@@', OUT.lstrip('/')).replace('@@DIR@@', OUT))
        open(path, 'w').write(src)
    os.chmod(os.path.join(OUT, 'tool'), 0o755)
    os.makedirs(os.path.join(OUT, 'sub'), exist_ok=True)
    return sorted(f for f in os.listdir(OUT) if f.endswith('.md'))


class Preview:
    def __init__(self, path):
        require_idle()
        if os.path.exists(CMD): os.remove(CMD)
        self.n, self.mark = 0, os.path.getsize(LOG)
        self.ql = launch(path)
        if not wait_for(LOG, 'rendered[open]', 15, self.mark):
            self.close()
            raise SystemExit('ABORT: no render')

    def log(self):
        return open(LOG).read()[self.mark:]

    def js(self, body, timeout=5):
        self.n += 1
        json.dump({'n': self.n, 'js': body}, open(CMD + '.tmp', 'w'))
        os.replace(CMD + '.tmp', CMD)
        t0 = time.time()
        while time.time() - t0 < timeout:
            m = re.search(r'CMDRES %d (\S*)(.*)' % self.n, self.log())
            if m:
                if ' ERR ' in m.group(2): raise RuntimeError(m.group(2))
                return json.loads(base64.b64decode(m.group(1)).decode('utf-8'))
            time.sleep(0.02)
        raise RuntimeError(f'no result for command {self.n}')

    def close(self):
        if self.ql.popen.poll() is None:
            self.ql.popen.terminate()
            self.ql.popen.wait(5)


CLICK_ALL = r"""
return (() => { const sel = '#doc a, #doc svg a, #doc .node, #doc [onclick]'; let n = 0;
    // Re-query before every click: a click that starts an edit redraws the document and detaches earlier nodes.
    for (let i = 0; i < 200; i++) { const t = [...document.querySelectorAll(sel)][i]; if (!t) break; n++; const r = t.getBoundingClientRect();
      for (const type of ['mouseover', 'mousedown', 'mouseup', 'click'])
        t.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: r.left + 1, clientY: r.top + 1 })); }
    return n; })();
"""

AUDIT = r"""
const doc = document.getElementById('doc');
const handlers = [...doc.querySelectorAll('*')].filter((n) => [...n.attributes].some((a) => /^on/i.test(a.name))).length;
const scriptUrls = [...doc.querySelectorAll('[href], [src], [action], [data], [xlink\\:href]')]
  .filter((n) => [...n.attributes].some((a) => /^\s*(javascript|vbscript|data:text\/html)/i.test(a.value))).length;
return { pwned: window.__pwned || null, scripts: doc.querySelectorAll('script').length,
         frames: doc.querySelectorAll('iframe, frame, frameset, object, embed').length, handlers, scriptUrls,
         forms: doc.querySelectorAll('form').length, base: document.querySelectorAll('base').length,
         baseHref: document.getElementById('base').href, text: doc.textContent.length };
"""

# Lines that would mean a hostile message or click reached the writer or switched the preview.
BAD = [r'link -> helper open', r'\[md\.spacebar:writer\] open ', r'wrote \d+ bytes', r'link -> in-panel']


def run(name):
    path = os.path.join(OUT, name)
    before = open(path, 'rb').read()
    p = Preview(path)
    try:
        time.sleep(2.0)  # images fail, mermaid renders, anything that could fire does
        clicked = p.js(CLICK_ALL)
        time.sleep(1.0)
        audit = p.js(AUDIT)
        log = p.log()
    finally:
        p.close()
    bad = [l for l in log.splitlines() if any(re.search(b, l) for b in BAD)]
    changed = open(path, 'rb').read() != before
    refused = len(re.findall(r'refused (link|open|toggle|load|editBlock)', log))
    dropped = len(re.findall(r'dropped message', log))
    csp = len(re.findall(r'csp blocked', log))
    ok = (not bad and not changed and audit['pwned'] is None and audit['scripts'] == 0 and audit['frames'] == 0
          and audit['handlers'] == 0 and audit['scriptUrls'] == 0 and audit['forms'] == 0 and audit['base'] == 1
          and audit['text'] > 0)
    print(f"{'PASS' if ok else 'FAIL'} {name}: clicked {clicked}, refused {refused}, dropped {dropped}, csp-blocked {csp}, "
          f"audit {json.dumps(audit)}" + (f", file changed" if changed else ''))
    for l in bad: print('   BAD', l[:220])
    return ok


if __name__ == '__main__':
    fixtures = materialize()
    probe_conf(f'cmd={CMD}')
    logp = start_log(LOG)
    try:
        results = [run(f) for f in fixtures if not sys.argv[1:] or any(a in f for a in sys.argv[1:])]
    finally:
        logp.terminate()
    pwned = os.path.exists('/tmp/spacebar-pwned')
    if pwned: print('FAIL run.command executed (/tmp/spacebar-pwned exists)')
    print(f'\n{sum(results)}/{len(results)} hostile fixtures passed; files in {OUT}')
    sys.exit(0 if results and all(results) and not pwned else 1)
