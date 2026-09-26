# Hostile fixtures

The files in this folder are **intentionally malicious**. They are test inputs for spacebar's sanitizer and link policy, not
examples to copy, and nothing in them is meant to be opened by hand.

- `01-handlers.md` to `08-overlay.md`: Markdown with raw HTML that tries to run script (event handlers, `<script>`,
  `javascript:` links, frames, SVG, Mermaid labels, click-stealing overlays) or to open local files and apps.
  `@@PAYLOAD@@` is replaced at test time with script that tries to message the unsandboxed writer.
- `browser/`: files the sidebar's file browser previews: an HTML page and an SVG that try to run script, a script whose
  source tries to break out of the code view, and JSON and CSV cells holding markup. `test/sidebar.py` copies them into a
  folder beside a symbolic link to `/etc`, a link to the parent folder and names made of dots, and checks that nothing runs,
  HTML and SVG are never rendered as documents, and nothing outside that folder can be listed, opened or served.
- `evil.html`, `evil.js`, `evil.svg`, `go.webloc`, `run.command`, `tool`, `payload.txt`: the files those documents link to or
  load. `run.command` only writes `/tmp/spacebar-pwned`, so a test can tell whether it ran.

`test/webcheck.py` renders every fixture in an off-screen WKWebView and checks that no payload runs and that the sanitized DOM
holds no script, frame, handler or script URL. `test/hostile.py` does the same through Quick Look and also checks that the
writer never opens or writes anything. Both copy the fixtures into a temporary folder first.
