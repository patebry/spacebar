# Security policy

Please report security problems privately, not in a public issue: on
[github.com/patebry/spacebar](https://github.com/patebry/spacebar), open the **Security** tab and choose
**Report a vulnerability** ([direct link](https://github.com/patebry/spacebar/security/advisories/new)). This uses GitHub's
private vulnerability reporting; only the maintainer sees the report.

Include the spacebar version, the macOS version, and a Markdown file or steps that show the problem. You will get a reply
within a week. Fixes ship in the next release, and the advisory is published once that release is out.

Only the latest release is supported. [FINDINGS.md](FINDINGS.md#security-model) describes the threat model: a Markdown file,
and whatever sits beside it, is treated as hostile.

Six features reach further than a rendered page, and are in scope:

- **HTML files** open in a separate web view with no message handler, no `spacebar:` scheme and no stored data. By default
  a file without the quarantine flag runs its scripts and may load from the web, like a browser would; only files a
  browser, Mail or AirDrop marked as downloaded are held back. Files from `git clone`, `curl`, `unzip` or a USB drive are
  not marked, so their pages run too; "Scripts in HTML files: Never" (Settings, Advanced) turns scripts and web loads off
  for every HTML file. A flag that cannot be read counts as downloaded. A downloaded file is served to its view through a
  scheme handler: the file is the only document, decoded and sent as UTF-8 with every `<link>` element (any prefix or case)
  made inert and the stylesheets beside it inlined; other files in its folder load only as stylesheets, images and fonts; no
  frame of any kind loads; a CSP with no scripts, frames or anything from outside the folder; and every http(s), ws(s) and
  ftp load blocked. Resource hints such as preconnect are not governed by CSP or content rules, which is why no `<link>` is
  kept at all. A link
  leaves the view only within a second of the user's click in it, one per click, and through the link policy.
- **Archives** are listed by the unsandboxed helper with `/usr/bin/bsdtar` run under `sandbox-exec`: a deny-by-default
  profile that allows only system reads and executing bsdtar, and denies every write and metadata reads under `/Users` and
  `/Volumes`, so no writes, no network and no reads of the user's files. The archive is passed as a descriptor the helper
  opened after checking its name and type; output is capped at 2 MB and 5,000 entries, names at 4 KB and 64 folders deep,
  and the run at 5 seconds. Nothing is extracted. Only the viewer's Open button may hand an archive to its default app.
- **Apple's previews in the panel.** Office, iWork, font, 3D, certificate, calendar and other files macOS previews are shown
  by Apple's own Quick Look in a `QLPreviewView`, and Apple's generators run in Quick Look's daemons, not in spacebar. The sandboxed extensions can reach
  those daemons only through `com.apple.security.temporary-exception.mach-lookup.global-name` for `com.apple.quicklook` and
  `com.apple.quicklook.ThumbnailsAgent`, which grants lookup of those two Quick Look services only; no file or network
  entitlement is added. Apple's generators already parse these files for the info card's thumbnail (QuickLookThumbnailing),
  so the parsers reached are not new.
  The view is used only for a declared type of no kind of spacebar's own that spacebar does not claim and that conforms to
  nothing it claims (`FileTypes.appleQuickLookType`), because Quick Look hands the file to whichever extension it would
  pick. The claims are read at run time from the bundle's copy of `scripts/quicklook-types.txt`; without it nothing is
  handed over. Folders, packages other than iWork's, apps, archives, disk images, web archives, mail and contact cards are
  never shown this way (Apple's previews of web content and mail load what they link to; its contact card reads Contacts
  in spacebar's own process). A test makes a file of every claimed type and checks that none reaches the view. The type is
  checked again just before the view is given the file; a file swapped between that check and Quick Look's read is not.
- **Images and disk images parsed in the sandbox.** HEIC, AVIF, TIFF, camera RAW, PSD, OpenEXR, TGA, JPEG 2000 and icon
  files are decoded by ImageIO in the sandboxed extension or viewer, as a PDF is by PDFKit, rather than in WebKit's content
  process; the decode is bounded to 8,192 pixels a side and to files of at most 50 MB. A `.dmg`'s format and encryption are
  read from its trailer and block table in the same sandboxed process, with every offset checked against the file, the
  table at most 16 MB and 2 million entries; nothing is mounted or run.
- **The one-click update** runs the app's own copy of `scripts/install.sh`, sealed by the app's signature, detached from Quick
  Look with only `HOME`, `PATH`, `TMPDIR` and a status path in its environment. It installs only a version newer than the
  running one, only into `~/Applications/spacebar.app`, and only after the downloaded zip's SHA-256 matches the release's.
  The version check reads just the version number of GitHub's latest release, at most once a day. The uninstaller, started
  from Settings, quits the extensions' helpers before it deletes anything and does not start while an update runs.
- **The Space helper** ("Use spacebar for every file", off until you turn it on) splits the privileges between two processes.
  `spacebar Helper.app` (`md.spacebar.helper`) is a launchd agent with Accessibility and an active event tap, no sandbox and no
  entitlements, under the hardened runtime. It is built from its own few files and the settings reader, with none of the
  file-reading code and no WebKit, and it never opens a file: it reads Finder's focus and selection through Accessibility,
  within a 60 ms budget in which any error hands the key back. It takes a plain Space only when it is on its way to Finder,
  and other keys only while its panel is open and really on screen (the viewer's window, visible, at least 200×150 and on a
  display, checked when it opens and every 2 seconds); it passes every key while Finder's focus is in a text field or another
  process has the keyboard, and forwards only names from a fixed list. `spacebar Viewer.app` (`md.spacebar.viewer`) renders
  files with the preview extension's code and exactly its entitlements plus the lookup of the helper's one Mach service; it
  cannot claim the keys itself, since the helper accepts a panel only for a show it asked for. When another app comes
  forward the panel is hidden and Finder has its keys back at once; Finder coming back brings it back only as a new request,
  through the same check that its window is up and on screen, and a restore that fails it closes the panel. The helper's Mach service admits
  only the viewer and the settings app: signed by the helper's own leaf certificate, under the hardened runtime as the kernel
  holds it for the running process, and without the entitlements that allow DYLD_ variables or turn off library validation;
  the role is fixed per connection, and each call checks it. The viewer and the app require the helper's identity in turn.
  Residual risks: the helper sees every key event while it runs, so it is kept small and acts on so few; a compromised viewer
  has what the Quick Look extension has, plus a process that stays alive (it exits after 30 minutes closed); and the release
  signing key now also gates Accessibility, so it must stay in CI secrets only. The uninstaller boots the agent out, quits the viewer
  and resets both apps' privacy permissions.
