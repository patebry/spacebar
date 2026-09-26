# Hostile fixtures

The files in this folder are **intentionally malicious**. They are test inputs for spacebar's sanitizer and link policy, not
examples to copy, and nothing in them is meant to be opened by hand.

- `01-handlers.md` to `08-overlay.md`: Markdown with raw HTML that tries to run script (event handlers, `<script>`,
  `javascript:` links, frames, SVG, Mermaid labels, click-stealing overlays) or to open local files and apps.
  `@@PAYLOAD@@` is replaced at test time with script that tries to message the unsandboxed writer.
- `evil.html`, `evil.js`, `evil.svg`, `go.webloc`, `run.command`, `tool`, `payload.txt`: the files those documents link to or
  load. `run.command` only writes `/tmp/spacebar-pwned`, so a test can tell whether it ran.

`test/webcheck.py` renders every fixture in an off-screen WKWebView and checks that no payload runs and that the sanitized DOM
holds no script, frame, handler or script URL. `test/hostile.py` does the same through Quick Look and also checks that the
writer never opens or writes anything. Both copy the fixtures into a temporary folder first.
