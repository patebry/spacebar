# Security policy

Please report security problems privately, not in a public issue: on
[github.com/patebry/spacebar](https://github.com/patebry/spacebar), open the **Security** tab and choose
**Report a vulnerability** ([direct link](https://github.com/patebry/spacebar/security/advisories/new)). This uses GitHub's
private vulnerability reporting; only the maintainer sees the report.

Include the spacebar version, the macOS version, and a Markdown file or steps that show the problem. You will get a reply
within a week. Fixes ship in the next release, and the advisory is published once that release is out.

Only the latest release is supported. [FINDINGS.md](FINDINGS.md#security-model) describes the threat model: a Markdown file,
and whatever sits beside it, is treated as hostile.

Nine features reach further than a rendered page, and are in scope:

- **Editing files in place.** The unsandboxed writer saves what is typed. It writes only to an existing regular file whose
  name, and the name of the file it resolves to, is of a type spacebar edits: Markdown, the code, JSON, CSV and text types
  spacebar shows as text, and dotfile config (`.env`, `.env.<name>`, `.gitignore`). Unless both are Markdown, a link
  and its target must have the same extension (the same name, when there is none), so a `notes.txt` that links to `~/.zshrc`
  is not editable. Markdown is bounded at 64 MB. Any other file is refused when it or either buffer is over 2 MB (spacebar
  reads at most 2 MB of text, 16 MB for a CSV table, and edits only a file it read whole, so a buffer cut from a longer file
  is never saved), when what is on disk does not read as text
  (TextDecoding's check: a NUL, or many control characters, in its first 64 K characters), and when either side is a binary
  property list. Code and config can run, so the extension cannot write content of its own into them: when an edit of such a
  file starts, the writer reads the file itself and takes the edit's text only if it is that file's text (or one its edits of
  the file already sent), a script cannot replace the buffer, and every write must be, byte for byte, a buffer the writer's
  own panel sent, in the file's encoding. Markdown writes are as before: any content, to Markdown only. Every write names
  the bytes it expects on disk (compare-and-swap), and the resolved path is opened without following a link swapped in for
  it. The preview edits a file only when its bytes come back exactly from its text in the encoding and byte order mark they
  were read with; a character that encoding cannot hold is not saved, and a file is never converted to UTF-8. A `.env` is
  editable: an edit goes back into the same file, and LinkPolicy still never hands it to another app, which was the risk that
  rule addresses. `.npmrc` is not: npm runs what its config names (`script-shell`, `node-options`).
  Residual risk: the extension can fill the pasteboard and open the invisible panel over a file other than the one on screen,
  so a ⌘V the user meant for the preview could land there. Files that run on their own are therefore never editable, on the
  resolved path: shell startup files (`.zshrc`, `.bash_profile`, `.profile` and the rest), `.gitconfig`, `.npmrc`, `.yarnrc`,
  `.command` and `.tool` scripts, anything in a `LaunchAgents` or `LaunchDaemons` folder, and git hooks. Other code pasted
  this way would still run only when the user runs it.
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
- **Large text** (over 256 KB) reaches the preview page as a body the page reads once from `spacebar://body/<random token>`,
  not inside its render script. The body is the text already read for that render, held in memory: the handler reads
  nothing from disk, and serves it only at its exact URL, once, while its file is still the one on screen, as `text/plain`
  with `nosniff`. The page's CSP allows connections to that host alone.
- **Archives** are listed by the unsandboxed helper with `/usr/bin/bsdtar` run under `sandbox-exec`: a deny-by-default
  profile that allows only system reads and executing bsdtar, and denies every write and metadata reads under `/Users` and
  `/Volumes`, so no writes, no network and no reads of the user's files. The archive is passed as a descriptor the helper
  opened after checking its name and type; output is capped at 2 MB and 5,000 entries, names at 4 KB and 64 folders deep,
  and the run at 5 seconds. Nothing is extracted. Only the viewer's Open button may hand an archive to its default app.
  A file inside the archive is previewed by streaming that one member, never extracting it: the same helper runs
  `bsdtar -x -O -q -n -f - -- <name>` under the same profile, on a fresh descriptor after the same checks, and keeps its
  standard output in memory. The name is attacker-controlled: it must be one the listing gave (the extension checks it
  against the listing on screen), it goes to bsdtar as a single argv element after `--` with no shell, a name starting with
  `-` is refused, and `\`, `*`, `?`, `[`, `]` and a leading `^` are escaped so bsdtar's pattern matches that name alone
  (libarchive still takes a leading `./` and doubled slashes as nothing, so such a name may read its twin from the same
  archive); `-n` keeps a name from matching a folder's contents, `-q` stops at the first match, and `-O` means a `../` or
  absolute name reaches no path. The writer trusts the extension's choice of archive, as it does for listing: it reads by
  path, under the same checks, a member of any archive the extension names, which the extension, with its read-only access
  to the disk, could read the bytes of itself. The extension asks for one entry at a time; a key held down reads only the
  last file asked for.
  The helper sets the cap, not the caller: 2 MB for text, code, Markdown, JSON and CSV, 20 MB for PNG, JPEG, GIF, WebP,
  BMP, ICO, HEIC, HEIF, AVIF and TIFF, and nothing is read for any other type, or for an archive inside the archive. The cap
  is counted while streaming and bsdtar is stopped one byte past it; output past 1,024 times the archive's size (at least
  64 KB), more than DEFLATE can expand, stops it as a bomb; the run is stopped after 5 seconds. Text reaches the page as
  any text does (inline, or once from `spacebar://body/`); an image is served once from `spacebar://entry/<random token>`,
  typed by extension, while its archive is on screen, and the page keeps it as a blob; the extension first checks its
  declared size against the 80-megapixel bound, before WebKit decodes it. HEIC, HEIF, AVIF and TIFF are decoded by ImageIO
  in the sandboxed extension under the image bounds above. The view is read-only (no edit, task toggle, Open or Reveal of
  the entry), and ⌘C copies only its text. A Markdown entry reaches no file on disk: relative links and images resolve to
  `spacebar://entry/`, which serves nothing else, the `file` host serves nothing while an entry is on screen, and a link
  to a file is refused.
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
- **Copy** puts plain text on the clipboard through the writer; the sandboxed extension never touches the pasteboard. The
  Copy button, and ⌘C with nothing selected, copy the file on screen as the extension read it, never text the page supplies;
  ⌘C with a selection copies the page's selection, taken only within a second of the host handing the page that ⌘C. The
  extension takes a copy only for the path of the file on screen, and only a text view or a Markdown file has a whole-file
  copy. In the Space panel the sandboxed viewer writes the pasteboard itself for ⌘C with nothing selected, as Finder's ⌘C
  does: the file on screen's URL, with its text where it has a whole-file copy, and only within a second of a ⌘C the helper
  forwarded; the Copy button stays text only, through the writer.
- **The helper hint.** Whether the Space helper is taking Space comes from the Quick Look extension's writer, which reads
  the window server's list of event taps (each tap's owner, matched by its executable's path). Nothing connects to the
  helper, and no key is seen.
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
  text field), while a key is meant for a process other than Finder or the viewer, and while the viewer reports a text
  session. A Space passes while Apple's Quick Look is open, and Apple's Quick Look opening closes spacebar's panel.
- *The text session.* An edit, the sidebar filter and the find field type into the viewer's writer's key panel. The window
  server annotates those keys with the frontmost app's pid, Finder's, not the panel's, so the helper cannot tell them from
  Finder's keys; the viewer says when such a session starts and ends (`textSession`), and meanwhile every key passes, Space,
  Esc, the arrows and ⌘ shortcuts included. The session handles Esc itself. The claim is the viewer's word and is not checked,
  but a viewer that lies can only make the helper pass keys to where macOS would send them anyway: it fails open to normal
  macOS behaviour and can never make the helper take or read a key. Only the viewer's connection may send it
  (`Link.permits`, `test/helperlink`), only while a panel is open or on its way, and it is cleared when the panel closes or
  suspends, the viewer disconnects or reconnects, and when the helper restarts.

**No key characters leave the helper.** The tap reads a key's code and modifier flags. It reads the character only for a
key pressed with ⌘, to tell ⌘W, ⌘., ⌘O, ⌘F, ⌥⌘F, ⌘C and the zoom keys apart, and keeps it in that one event. What crosses to
the viewer is a name from a fixed list (`up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `return`, `open`,
`find`, `filter`, `copy`, `zoomIn`, `zoomOut`, `zoomReset`), and a repeat flag; the viewer drops any other name. The helper logs
decisions and timings, never a key.

**Secure input.** While a password field or another app has secure input on, macOS sends no key events to event taps, so the
helper sees nothing and Space reaches Finder's own Quick Look. Settings shows "Secure input on".

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
