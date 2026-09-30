# Security policy

Please report security problems privately, not in a public issue: on
[github.com/patebry/spacebar](https://github.com/patebry/spacebar), open the **Security** tab and choose
**Report a vulnerability** ([direct link](https://github.com/patebry/spacebar/security/advisories/new)). This uses GitHub's
private vulnerability reporting; only the maintainer sees the report.

Include the spacebar version, the macOS version, and a Markdown file or steps that show the problem. You will get a reply
within a week. Fixes ship in the next release, and the advisory is published once that release is out.

Only the latest release is supported. [FINDINGS.md](FINDINGS.md#security-model) describes the threat model: a Markdown file,
and whatever sits beside it, is treated as hostile.

Seven features reach further than a rendered page, and are in scope:

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
  handed over. Folders, packages other than iWork's, apps, archives, disk images, web archives, mail, contact cards and
  text (any type declared as text but a calendar and a Wavefront model, which Apple draws) are never shown this way (Apple's previews of web content and mail load what they link to; its contact card reads Contacts
  in spacebar's own process). A test makes a file of every claimed type and checks that none reaches the view. The type is
  checked again just before the view is given the file; a file swapped between that check and Quick Look's read is not.
- **Images and disk images parsed in the sandbox.** HEIC, AVIF, TIFF, camera RAW, PSD, OpenEXR, TGA, JPEG 2000 and icon
  files are decoded by ImageIO in the sandboxed extension or viewer, as a PDF is by PDFKit, rather than in WebKit's content
  process; an image declaring more than 80 megapixels is refused before any decode, the decode is bounded to 8,192 pixels a
  side and 40 megapixels, and files to at most 50 MB. A `.dmg`'s format and encryption are
  read from its trailer and block table in the same sandboxed process, with every offset checked against the file, the
  table at most 16 MB and 2 million entries; nothing is mounted or run.
- **The one-click update** runs the app's own copy of `scripts/install.sh`, sealed by the app's signature, detached from Quick
  Look with only `HOME`, `PATH`, `TMPDIR` and a status path in its environment. It installs only a version newer than the
  running one, only into `~/Applications/spacebar.app`, and only after the downloaded zip's SHA-256 matches the release's.
  The version check reads just the version number of GitHub's latest release, at most once a day. The uninstaller, started
  from Settings, quits the extensions' helpers before it deletes anything and does not start while an update runs.
- **Copy** puts plain text on the clipboard through the writer (the sandboxed extension and viewer never touch the
  pasteboard). The Copy button, and ⌘C with nothing selected, copy the file on screen as the extension read it, never text
  the page supplies; ⌘C with a selection copies the page's selection, taken only within a second of the host handing the page
  that ⌘C. The extension takes a copy only for the path of the
  file on screen, and only a text view or a Markdown file has a whole-file copy.
- **The Space helper** ("Use spacebar for every file", off until you turn it on) holds Accessibility and an event tap. Its
  threat model is below.

## The Space helper

**What it protects.** With the helper on, one process sees every key event in the session. The design goal is that nothing
which parses a file can become a keylogger, and that nothing on the Mac can use the helper to learn what was typed or to
drive Finder.

**Privilege split.** Two processes, each with only what its job needs:

| | `spacebar Helper.app` (`md.spacebar.helper`) | `spacebar Viewer.app` (`md.spacebar.viewer`) |
|---|---|---|
| Runs as | a launchd agent, started at login | a floating panel the helper keeps running while it is on: after 30 minutes closed it exits and the helper starts a fresh one, so it is recycled, never stopped |
| Holds | Accessibility and an active event tap | the preview extension's sandbox and exactly its entitlements, plus the lookup of the helper's one Mach service |
| Sandbox, entitlements | none and none, under the hardened runtime | sandboxed, under the hardened runtime, with its own unsandboxed writer as the extension has |
| Code | its own few files and the settings reader; none of the file-reading code, no WebKit (the claims test checks the binary's symbols and libraries) | the preview extension's code, reused |
| Touches files | never: it reads Finder's focus and selection through Accessibility and passes paths on | reads and renders them, as the extension does |
| Keys | sees them all | only the key names the helper sends it |

A renderer exploit in the viewer gets what a Quick Look extension exploit gets today, plus a process that is always running;
it gets no key events and no Accessibility.

**The XPC gate.** The helper's Mach service, `md.spacebar.helper`, admits only the viewer and the settings app:

- *Code-signing requirement.* The listener requires `identifier "md.spacebar.viewer" or identifier "md.spacebar"`, signed by
  the same leaf certificate as the helper itself (read at run time from the helper's own signature, so a build trusts only
  its own siblings), and carrying neither `com.apple.security.cs.allow-dyld-environment-variables` nor
  `com.apple.security.cs.disable-library-validation`: either would let a library be injected into a process the helper
  trusts. An ad-hoc or unsigned helper has no certificate to pin and refuses every connection.
- *Hardened runtime, from the kernel.* The peer must run under the hardened runtime as the kernel holds it for the running
  process (`kSecCSDynamicInformation`), not as the file on disk says, since the file can be swapped after launch.
- *One role per connection.* The helper decides once whether the peer is the viewer or the app, then pins the connection to
  that one identity (`setCodeSigningRequirement`), so every later message is checked against it by the kernel's audit token,
  not the pid, and each method checks the role: the app's connection cannot call the viewer's methods and the other way round.
- *Both ways.* The viewer and the app require the helper's identity in turn (`identifier "md.spacebar.helper"` and the same
  leaf certificate) before they send it anything.

`test/helperlink/run.sh` runs the real listener as a temporary launchd job and checks that the viewer and the app are
admitted, and that an ad-hoc client claiming the viewer's identifier, a same-certificate client under another identifier,
and the viewer's identity without the hardened runtime, with DYLD variables allowed or with library validation off are all
refused.

**The panel-state gate.** The helper takes keys other than Space only while a spacebar panel is really open on screen:

- The viewer cannot claim the keys itself. The helper accepts a panel only for a show it asked for (a pending request id),
  and only once the viewer reports a window the helper can see in the window server: its window, visible, at least 200×150
  and on a display. It checks again every 2 seconds and gives the keys back to Finder when the window is gone.
- A show the viewer does not acknowledge within 150 ms is dropped and the Space goes to Finder (a Space more than a second
  old is not re-sent).
- When another app comes forward the panel is suspended and Finder has its keys back at once. Finder coming back restores it
  only as a new request through the same gate, and a restore that fails the gate closes the panel.
- Every key passes while Finder's focus is in a text field (a rename, the search field; any Accessibility error counts as a
  text field) or another process has the keyboard. A Space passes while Apple's Quick Look is open, and Apple's Quick Look
  opening closes spacebar's panel.

**No key characters leave the helper.** The tap reads a key's code and modifier flags. It reads the character only for a
key pressed with ⌘, to tell ⌘W, ⌘., ⌘O, ⌘F, ⌥⌘F, ⌘C and the zoom keys apart, and keeps it in that one event. What crosses to
the viewer is a name from a fixed list (`up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `return`, `open`,
`find`, `filter`, `copy`, `zoomIn`, `zoomOut`, `zoomReset`), and a repeat flag; the viewer drops any other name. The helper logs
decisions and timings, never a key.

**Secure input.** While a password field or another app has secure input on, macOS sends no key events to event taps, so the
helper sees nothing and Space reaches Finder's own Quick Look. Settings, General shows "Secure input on".

**Residual risks.**

- The helper sees every key event while it runs. It is kept small and acts on few keys, but a bug in it is a bug in a
  process with Accessibility.
- A compromised viewer has what the Quick Look extension has, plus a process that runs for as long as the helper is on (a
  fresh one every 30 minutes the panel stays closed).
- The signing key now also gates Accessibility: whoever holds it can build a viewer the helper trusts, and a helper that
  inherits the Accessibility grant. It lives only in CI secrets. Until the Developer ID release, the certificate is
  self-signed, so macOS pins the helper's launch constraint to its code hash rather than to a Team ID.
- A file swapped between the viewer's type check and Quick Look's read may reach Apple's generator for a type spacebar claims.
  It is still parsed by Apple's generator, out of process, and shown in the sandboxed viewer.

**Turning it off and removing it.** Turning the setting off unregisters the agent, and the helper exits. The uninstaller
boots the agent out, quits the helper, the viewer and the viewer's writer, resets the helper's Accessibility grant and every
permission of the viewer's (`tccutil reset`), and with `--purge` deletes the helper's log and lists the viewer's container for you to delete (macOS asks before one app deletes another's); `test/report/run.sh` checks
each step of its dry run.
