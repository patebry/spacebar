# Security policy

Please report security problems privately, not in a public issue: on
[github.com/patebry/spacebar](https://github.com/patebry/spacebar), open the **Security** tab and choose
**Report a vulnerability** ([direct link](https://github.com/patebry/spacebar/security/advisories/new)). This uses GitHub's
private vulnerability reporting; only the maintainer sees the report.

Include the spacebar version, the macOS version, and a Markdown file or steps that show the problem. You will get a reply
within a week. Fixes ship in the next release, and the advisory is published once that release is out.

Only the latest release is supported. [FINDINGS.md](FINDINGS.md#security-model) describes the threat model: a Markdown file,
and whatever sits beside it, is treated as hostile.

Three features reach further than a rendered page, and are in scope:

- **HTML files** open in a separate web view with no message handler, no `spacebar:` scheme and no stored data. By default
  a file without the quarantine flag runs its scripts and may load from the web, like a browser would; only files a
  browser, Mail or AirDrop marked as downloaded are held back. Files from `git clone`, `curl`, `unzip` or a USB drive are
  not marked, so their pages run too; "Scripts in HTML files: Never" (Settings, Advanced) turns scripts and web loads off
  for every HTML file. A flag that cannot be read counts as downloaded. A downloaded file is served to its view through a
  scheme handler: only files inside its folder, `<link>` resource hints (preconnect, dns-prefetch, prefetch, preload)
  removed, a CSP with no scripts and nothing from outside the folder, and every http(s), ws(s) and ftp load blocked. A link
  leaves the view only within a second of the user's click in it, one per click, and through the link policy.
- **Archives** are listed by the unsandboxed helper with `/usr/bin/bsdtar` run under `sandbox-exec`: a deny-by-default
  profile that allows only system reads and executing bsdtar, and denies every write and metadata reads under `/Users` and
  `/Volumes`, so no writes, no network and no reads of the user's files. The archive is passed as a descriptor the helper
  opened after checking its name and type; output is capped at 2 MB and 5,000 entries, names at 4 KB and 64 folders deep,
  and the run at 5 seconds. Nothing is extracted. Only the viewer's Open button may hand an archive to its default app.
- **The one-click update** runs the app's own copy of `scripts/install.sh`, sealed by the app's signature, detached from Quick
  Look with only `HOME`, `PATH`, `TMPDIR` and a status path in its environment. It installs only a version newer than the
  running one, only into `~/Applications/spacebar.app`, and only after the downloaded zip's SHA-256 matches the release's.
  The version check reads just the version number of GitHub's latest release, at most once a day. The uninstaller, started
  from Settings, quits the extensions' helpers before it deletes anything and does not start while an update runs.
