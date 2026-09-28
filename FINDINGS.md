# spacebar: engineering notes

> Short hashes in parentheses, such as a742ad8, refer to the private development history that this public repository was squashed from.

This is a Quick Look preview extension for folders, documents, code and data on macOS 13+ (universal: arm64 and x86_64),
with Markdown rendered and editable in place, built without Xcode (`build.sh`, swiftc). Everything below was verified in this repository, by a test in `test/` or by evidence in `docs/evidence/` and the commit history. Numbers come from those sources and name the commit that measured them.

## Architecture

```
spacebar.app (md.spacebar)                        SwiftUI settings app; spacebar-md://settings/<tab>
└─ PlugIns/SpacebarPreview.appex (md.spacebar.preview)
   │  sandboxed, view-based QLPreviewingController; one WKWebView per extension process, reused across previews
   │  spacebar://bundle/…  Preview/web (index.html, app.js, vendored markdown-it, KaTeX, highlight.js, mermaid, DOMPurify)
   │  spacebar://file/…    read-only, by an explicit type map: images only (the viewer, a document's relative images)
   │  PDFPane              the PDF on screen: a PDFKit PDFView over the page's PDF area, placed by the page's pdfRect
   │  HTMLPane, MediaPane  an HTML file in a WKWebView of its own, and video or audio in an AVPlayerView, placed the same way
   │  QLFallbackPane       Office, iWork, font and 3D files in Apple's QLPreviewView, placed the same way
   │  RichTextPane         an RTF or RTFD document in a read-only NSTextView (AppKit's RTF reader only), placed the same way
   └─ XPCServices/md.spacebar.preview.writer.xpc   unsandboxed XPC service (SpacebarWriter)
        write      compare-and-swap writes to the previewed Markdown file
        open       links, "Open in editor" and the viewer's "Open with" (NSWorkspace is a no-op inside the sandboxed extension)
        reveal / defaultApp   Reveal in Finder, and the name of the app `open` would use
        openText / textOpener   the Open button for a file shown as text: the chosen text editor, else its default app
                   when LinkPolicy allows it, else the default text editor (LinkPolicy.textOpener)
        beginEdit  owns the hidden, non-activating key panel used for inline editing
        beginFilter / beginListKeys / endFilter   the same panel, over the sidebar's filter field or a clicked row
        listArchive   an archive's entries, from /usr/bin/bsdtar under sandbox-exec (Shared/ArchiveListing.swift)
        updateOffer / installUpdate   the daily version check, and the one-click update (the app's install.sh, detached)
        updateSettings / ensureSupportDir / openSettings   panel setting patches (Settings.panelKeys only)
   sidebar              FolderListing (Shared/FolderListing.swift) lists each folder of the tree off the main thread; a
                        FolderWatch per expanded folder re-lists it on change; the page gets each through sb.setFiles and asks
                        for a folder with "list"; FileView builds what the panel shows for a file that is not Markdown
└─ PlugIns/SpacebarFolders.appex (md.spacebar.preview.folders)   same binary; claims folders; own writer copy
```

Settings live in `~/Library/Application Support/spacebar/` (real home via getpwuid): `settings.json`, `custom.css`,
`themes/*.css`, served to the page as `spacebar://user/...`. The folder was `spacebar.md/` before the rename: the app or a
writer moves it once when only the old one exists (the new one wins when both do), and until then the extension reads the
old one in place. `Shared/Settings.swift` loads tolerantly and merges updates atomically under a lock; the extension
watches the folder and applies changes live (`sb.applySettings`), and a document-start script themes the first paint.
A symlinked settings.json (a dotfiles setup) is read but never written, so the version-2 migration cannot reach it: a
version-1 file there reads as folder previews on until its target gains `"version": 2`. The writer logs the skipped
migration. Left this way on purpose: writing through the link would replace it with a file.

Swift calls into the page through `window.sb`, and the page calls back through the `sb` message handler. Only the containing extension can reach the writer.

## Verified capabilities

| Capability | How | Evidence |
|---|---|---|
| Render | markdown-it + KaTeX (texmath) + highlight.js; mermaid loads lazily, and the panel shows at first paint, before mermaid (4287dc1) | `docs/evidence/0-finder-spacebar.png`, `docs/evidence/themes/`; `test/webcheck.py` |
| Mermaid without a flash | `mermaid.run` drew in the diagram's own element, so the source showed, then an empty block, then a half-laid-out SVG; a re-theme's `mermaid.render` drew into `<body>`, a flex row, beside the page. Every diagram is now drawn off screen (`#mm-stage`) and swapped in whole: its source is taken out before the first paint, a blank placeholder the height of the diagram last in its place holds the space, the first reveal fades in (not under reduced motion), a re-theme swaps finished SVGs, and finished SVGs are cached by colours and source so a redraw puts an unchanged diagram straight back | `test/webthemes.py` samples every diagram at each DOM mutation and animation frame |
| Live reload | DispatchSource watch that re-arms across atomic saves, 15 ms debounce; covers append, temp+rename and rename-away saves | `test/livereload.py` |
| Images and links | Relative images load via `<base href="spacebar://file/<dir>/">`. Markdown links inside the previewed folder open in the panel; others go through the link policy to the default app | `test/webcheck.py`, `test/linkpolicy/run.sh` |
| Folder mode (on by default since settings version 2) | The folders extension claims `public.folder`/`public.directory`; it is enabled unless `folderMode` is turned off, and declines while it is off. With it on, every ordinary folder is previewed (see [Folder previews](#folder-previews)); only packages and app bundles, the top of a volume or a mount point, and system folders are declined, decided in `preparePreviewOfFile` before anything starts (`FolderRules.declineReason`) | `test/settings/run.sh` (rules, finder, declines), `test/sidebar.py` (`@folder:`); `test/folders.py` (Quick Look) |
| Folder overview | A folder with no Markdown to open shows its overview: folders and files by kind, and the 8 most recently modified files as rows that open in the panel, from one bounded scan (`FolderScan`: breadth first, 3 folders deep, 5,000 entries, 250 ms, off the main thread). A folder not listed within 1.5 s shows the overview's loading state rather than hold the panel. The sidebar's folder name shows it again | `test/sidebar.py`, `test/settings/run.sh` |
| Obsidian | `[[wikilinks]]` (alias, heading, folder path), `![[image]]` (with a width) and `![[note]]` (inline, one level, read only), `> [!type]` callouts in nine colour families, `#tags` as pills. A note inside a vault (an ancestor with `.obsidian/`, at most 8 levels up, never the home or a system folder) is rooted at the vault. Targets are resolved by the extension (`LinkIndex`: by name anywhere under the root, the note's own folder first, then the shallowest; 20,000 entries, 12 deep, 400 ms, built off the main thread and reused while it is rebuilt) | `test/settings/run.sh`, `test/sidebar.py`, `test/webthemes.py` (contrast) |
| Toolbar row and outlined page | The default look: a 40 px row (sidebar button and breadcrumb on the left, Aa and Open on the right, quiet buttons with hover and pressed states and tooltips) and a 1 px hairline with a 10 px radius around the page, in the theme's border colour at low contrast (1.05 to 2.2:1; High Contrast keeps its strong line), on a chrome tint of the theme's background. `#frame` is a fixed overlay whose shadow is the chrome, so the window still scrolls the page and nothing about scrolling, the TOC or the PDF view changed; the edges outside the page take clicks. Below 480 px, and with **Minimal chrome** (`minimalChrome`, applied at document start), the floating buttons return. The current sidebar row settles into its highlight, rows highlight on hover, buttons press, the TOC scrolls smoothly; none of it under reduced motion | `test/webthemes.py` (every theme, light and dark: geometry, 4.5:1 for the row, sidebar, callouts, tags and wikilinks), `test/sidebar.py` |
| Sidebar file browser | Every preview, a single file or a folder, shows the previewed folder (the root) as a tree: folders first, then files, README first, sorted by `folderSort`, each with an inline-SVG type icon. Folders expand lazily and are re-listed by a watch while open; expansion is remembered per root for the life of the extension process, and the current file's folders open. Hidden files are skipped unless `showHiddenFiles`; links out of the root, FIFOs and devices always are; packages are single items; at most 500 entries per folder, with an "N more" note. A click shows the file in the panel by kind (FileView): Markdown as before; images fitted with dimensions; PDF natively (below); HTML, video and audio in native views; archives as a tree; code highlighted with line numbers; JSON pretty-printed with a Raw toggle; CSV/TSV as a table capped at 1,000 rows; text; anything else an info card with Open with its default app, or Reveal in Finder where LinkPolicy refuses it. A breadcrumb shows the path from the root; the panel title stays the file Quick Look opened | `test/sidebar.py`, `test/settings/run.sh` (tree, types), `test/scheme/run.sh` |
| Sidebar chrome | A toolbar button collapses it (animated, off under reduced motion); `sidebarCollapsed` is saved through the writer and applied at document start. Its right edge resizes it: 160 px to 45% of the panel or 480 px, saved as `sidebarWidth` once when the drag ends, applied at document start, reset by a double-click; dragging never collapses it. Below 640 px it collapses on screen only and the button shows it over the page; below 1100 px an open sidebar hides the TOC rail | `test/sidebar.py` |
| PDF in the panel | A PDFKit `PDFView` (Preview/PDFPane.swift) laid over the page's `.pdf-area`, under the breadcrumb and beside the sidebar: fitted, continuous pages, a backdrop from the theme. The page posts the area's rect whenever it moves (the sidebar's animation, a drag of its edge, the panel resizing); between posts the view keeps its margins. The iframe it replaced showed WebKit's PDF plugin and its unlabelled HUD buttons. Links in a PDF go through LinkPolicy and the writer. Anything else on screen closes the view and frees the document. Verified off screen, and in a copy of the harness signed with the extension's sandbox entitlements | `test/pdfpane/run.sh`, `test/sidebar.py` |
| Task toggles | The checkbox sends its line and text; Swift re-locates the line and the writer saves it with compare-and-swap | 2338549; `test/corpus.py` |
| Inline editing | See the next section | 068d11d, e1396e9, a742ad8, 4bfa7d6, f2c81fb, bbc51b2 |
| Double-click fix | See below | a742ad8; `test/dblclick.py` |
| Themes and settings | Six built-in themes (light/dark), user themes and custom.css, live switching, Aa popover, front matter, TOC, stats | `docs/evidence/themes/`; `test/webthemes.py` (offscreen page); `test/settings_live.py` (Quick Look) |
| Contrast | Every built-in theme, light and dark, is WCAG AA: text, `--muted`, quotes and links on the page, every code token on `--hl-bg` and `--code-bg` (diff lines on their tint), toolbar and popover grey text. Apple's link clamps the system accent's lightness (relative colour), so every accent colour passes | `test/webthemes.py` measures each pair from the page's resolved colours, composited on a canvas (bf9dc93) |
| Mermaid through edits | Every redraw renders its new diagram nodes, so diagrams outside the edited block are never left as source | `test/webthemes.py` (bf9dc93) |
| Remote images | Off by default. A blocked image's placeholder has "Load images from the web": that document, this preview, not saved | `test/remoteimages.py` (da63068) |
| What Space opens | The preview extension's `QLSupportedContentTypes` and the app's `UTImportedTypeDeclarations` are generated by `build.sh` from `scripts/quicklook-types.txt`. Quick Look routes a file to a third-party extension only for its exact type: a parent type (`public.source-code`, `public.text`) never routes, and types Apple previews itself (plain text, HTML, CSV, PDF, images, movies, audio) never do, so those are not claimed. An extension the system has no type for resolves to a `dyn.*` type no extension can claim; the app imports `md.spacebar.type.<ext>` for it. `QuickLookClaims.summary` is the settings window's wording of the list | `test/claims/run.sh` (the built plists against the file), `test/settings/run.sh` |
| HTML view | An HTML file in the sidebar renders in its own `WKWebView` (Preview/HTMLPane.swift), non-persistent, with no message handler or `spacebar:` scheme. Scripts and web loads run for a file without the quarantine flag while `htmlScripts` is `local` (the default: a clone, a `curl` or `unzip` download or a USB copy is not flagged, so it runs too); a flagged file, or one whose flag cannot be read, gets no scripts and no network (served through `OfflineFiles`, below). A link leaves the pane only within a second of a real click in it (`LinkClickGate`), one per click, and must name a file the sidebar could list | `test/htmlpane/run.sh`, `test/sidebar.py` |
| Video and audio | AVKit's player over the page's area (Preview/MediaPane.swift), paused on the first frame; audio shows its artwork or icon. The player stops and lets the file go when another file shows or the preview closes. Files with no other view get Finder's large thumbnail on their info card (QuickLookThumbnailing) | `test/mediapane/run.sh`, `test/sidebar.py` |
| Apple's previews | Office (`.docx`, `.xlsx`, `.pptx`, `.doc`, `.xls`, `.ppt`), iWork (`.pages`, `.numbers`, `.key`, a single file or a package), fonts (`.ttf`, `.otf`, `.ttc`, `.dfont`) and 3D (`.usdz`, `.reality`) in the sidebar are shown by Apple's `QLPreviewView` over the page's area (Preview/QLFallbackPane.swift), placed like the PDF view. Only for an exact list of types (`FileTypes.appleQuickLookTypes`, each checked against the file's own content type): `QLPreviewView` hands a file to whichever extension Quick Look would pick, and a `.md` in it started a nested spacebar. Nothing spacebar claims, no generic zip or package type, and not RTF. A file that shows only Quick Look's generic icon (an empty `QLLayerBasedPreviewContainerView`) gets its info card instead: the view is looked at 1.5 s after it is placed, and every 0.5 s after that while Quick Look still shows its spinner (a damaged 2 MB document reached the icon only at 2.2 s), for up to 20 s; a change on disk looks again. Needs the mach-lookup exception below | `test/qlpane/run.sh` (the list against `scripts/quicklook-types.txt`, the view per type, placing, a real render and the fallback, off screen; a render in a copy signed with the extension's entitlements), `test/sidebar.py` |
| Archives | The writer lists an archive with `bsdtar -tv` under `sandbox-exec` (see the security model); the page shows it as a tree of folders and files with sizes and dates, at most 5,000 entries, 2 MB of output and 5 s; a name is cut at 4 KB and 64 folders, and the page walks the tree without recursion. `.tbz`, `.txz` and `.tzst` list too. A lone `.gz`/`.bz2`/`.xz`/`.zst` is shown as the one file inside it | `test/archive/run.sh` (a fixture per format, the sandbox's denials) |
| Sidebar keys and filter | ↑ ↓ Home End move a cursor through the tree and open files (a held key opens only the file it stops on), → ← open and close folders (filtered, they only move), Return opens. The filter narrows the tree by a fuzzy, case-insensitive match and searches every listed folder. In Quick Look the page gets no keys, so a click on a row or in the filter borrows the writer's key panel (see the next section) | `test/sidebar.py`, `test/filterkeys/run.sh`, `test/editkeys/run.sh` |
| Rich text | `.rtf` and `.rtfd` (a package or flattened) are read by AppKit's RTF reader only (`NSAttributedString(rtf:)`, `(rtfd:)`, `(rtfdFileWrapper:)`), never its HTML importer: a file that does not start `{\rtf` is refused. Chosen over exporting HTML into the page: no markup to sanitize, no remote load, and the document's own fonts, tables and pictures. Drawn in a read-only NSTextView over the page's area like a PDF; in a dark theme the text view maps the document's colours (`usesAdaptiveColorMappingForDarkAppearance`) while the scroll view draws the theme's background. Links go through the PDF link policy (http(s) only) | `test/richtext/run.sh` |
| Text encodings | A byte order mark (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE), then UTF-16 without one (zeros in one byte lane), then UTF-8, then Foundation's detector over a short list of legacy encodings, else Windows-1252 or Latin-1. Binary stays binary: a NUL outside UTF-16/32, or control characters in more than 2 in 100 characters of a non-UTF-8 decoding. A cut code unit or character at the 2 MB mark is dropped. Markdown is still read as UTF-8 only, since edits are written back as UTF-8 | `test/encoding/run.sh` |
| Other previewers | Settings, General lists every other enabled Quick Look extension whose QLSupportedContentTypes share a type with spacebar's (the same identifier, a type for the same filename extension, dyn.* included, or any vendor's Markdown type; never a parent type, which Quick Look does not route by), grouped by the sections of `quicklook-types.txt`, with a confirmed Turn Off (`pluginkit -e ignore`). `install.sh` prints the same list by exact type and never turns anything off | `test/settings/run.sh`, `test/rivals/run.sh` |
| One-click update | The writer checks GitHub's latest release at most once a day (`Updates`, cached in `update.json`); a newer version puts a dot on Aa. Update ends any edit and filter session, waits for the edit's saves, then starts the app's sealed `install.sh --version vX --no-prompt` detached, under a log lock that keeps a second run from starting. While it waits or runs no edit, task toggle or filter session starts. The installer quits the writers before their extensions, so Quick Look shows its "failed during preview" screen for a moment; the popover says so. The page asks after 10 s, 30 s, then every minute how the run ended (`update-status.json`) | `test/updates/run.sh`, `test/webthemes.py`, `test/sidebar.py` |

## Inline editing through the writer's key panel

Quick Look extensions never receive key events: Finder and qlmanage keep them, and a window the extension creates never becomes key.

The unsandboxed writer can own a real window. A click on a block asks it for an invisible, click-through `.nonactivatingPanel` NSPanel over that block. The panel takes the keyboard without activating the app, so Finder stays frontmost and the Quick Look window stays open. An NSTextView in the panel edits the block's Markdown and streams text and selection back over XPC. The page draws the source and caret in place, and every change is saved.

- **Saves:** each save names the bytes it expects on disk. A mismatch is a conflict, and the external change wins. Writes go in place through one file descriptor, so the inode stays the same. If a write fails, the writer restores the old bytes or keeps the text in a `.spacebar-unsaved-` copy (`test/cas/run.sh`).
- **Keys:** Enter ends the block like Notion. Lists and quotes continue; code, math and HTML blocks get a line break. Backspace at the start of a block merges it upward. Keys typed during a split or merge are held and replayed. Emptied blocks are removed. The panel has no main menu, so Command shortcuts are mapped by hand: Cmd+A/C/X/V/Z/Shift+Z, and Cmd+arrows, Cmd+Shift+arrows, Cmd+Backspace and Cmd+Delete to the standard line and document moves (`test/editkeys/run.sh`).
- **Ending an edit:** Esc, clicking outside, the panel losing key, any app activation, a change on disk, or the preview closing.
- **The sidebar filter** borrows the same panel: a click in the filter field places it over the field, the typed text streams back to filter the tree, and ↑ ↓ Home End Return are forwarded to move through the matches and open them. It never writes. Esc on an empty field (Esc first clears one with text), a click outside the sidebar, the sidebar hiding, starting an edit, another folder, the panel losing key or the preview closing ends it. Keys an input method is composing with stay with it; starting a filter ends an edit (`test/filterkeys/run.sh`, `test/sidebar.py`).
- **Sidebar keys after a click on a row** use the same panel with no field (a list session): ↑ ↓ ← → Home End Return are forwarded, nothing is typed and no Command shortcut runs. Esc ends it, and so does Space: Space is Quick Look's close key, but the extension cannot close Quick Look, so the first Space only hands the keyboard back and the next one closes the preview. Swallowing Space silently, or ending the session and doing nothing visible, were the alternatives; handing the key back is the least surprising, and it is documented in the README. A click in the filter field turns it into a filter session; a click on a row while a filter session holds the keys keeps the filter (`test/filterkeys/run.sh`, `test/editkeys/run.sh`, `test/sidebar.py`).

Latency, measured in qlmanage from the page's click event (`test/edit_latency.py`, a742ad8):

| | before a742ad8 | after |
|---|---|---|
| click → caret painted | 118–151 ms cold, 41–52 ms warm | about 2 ms |
| click → panel key-ready | 79–99 ms cold, 5–14 ms warm | 5–12 ms cold, 3–5 ms warm |

Typing (068d11d):
- Keystroke → painted: median 3–5 ms.
- Keystroke → saved and re-rendered: median 13–17 ms.

`test/corpus.py` runs 55 scripted sessions over `test/corpus/` and generated 1k/3k/5k-line documents, comparing file bytes exactly. All 55 passed at bbc51b2.

## Double-click recognizer fix

Quick Look's own view controller puts a two-click `NSClickGestureRecognizer` on an ancestor of the preview. On a double-click it opens the file in its default app. Because it has `delaysPrimaryMouseButtonEvents` set, it also holds every click for one double-click interval.

The controller disables it when the view appears:
- Enabled: a double-click opens the file, and clicks reach the page about 500 ms late.
- Disabled: nothing opens, and clicks land in 1–3 ms.

## Security model

The threat is a downloaded Markdown file, and whatever sits beside it, driving the unsandboxed writer.

1. **CSP**
   - Scripts load only from the bundle.
   - No inline scripts or handlers, frames, objects, forms or connections; the shell allows no subframe at all.
   - Images only from `spacebar:`, `https:` and `data:`.
2. **DOMPurify** sanitizes the whole document before it reaches the DOM.
   - Inline styles are dropped, except table alignment.
   - KaTeX renders after sanitizing.
   - Mermaid runs in strict mode without HTML labels.
   - Link overlays can't take clicks outside their own text.
3. **Swift message gate**
   - Only messages from the main frame of `spacebar://bundle` are accepted, and every field is type- and size-checked.
   - Toggles and edits apply only to the previewed file.
   - `open` is limited to files the sidebar listed, or that the overview or a wikilink offered (each found by a bounded scan
     inside the root), `list` to the root and folders a listing named; both must be plain paths (no `.`, `..` or empty step)
     that still resolve inside the root when asked, so nothing above the root is reachable. `overview` takes no argument.
   - Editing, task toggles and "Open in editor" apply only to Markdown. `openFile` and `reveal` apply only to the file on screen;
     `openFile` only when the viewer offered it and LinkPolicy allows it (a `.ts` is not handed to QuickTime), and the page posts
     either only for a trusted click.
4. **Link policy** (`Shared/LinkPolicy.swift`, enforced in both the extension and the writer)
   - Allows only http(s) links, or existing non-executable documents of an allowed type.
   - A per-file "Open With" setting is ignored.
5. **Remote images** (off by default; `RemoteImageGate` in `Shared/WebShell.swift`)
   - A content rule list blocks every http(s) image while the setting is off; every render waits until it is in place.
   - The page replaces remote `<img>` (src or srcset) with a placeholder and drops remote `<source>`, SVG `<image>`/`<feImage>`,
     `background` and `poster`, also inside mermaid output: a second layer should the rule list ever fail to compile.
   - "Load images from the web" posts `loadRemoteImages` only for a trusted click on a button the page made (a document's
     look-alike button, a script-made click, or a click a `<label>` forwards posts nothing: labels are sanitized away, and the
     pointer must have gone down on the button itself). Swift grants it only for the file on screen and only while the
     setting is off, lifts the list for that path, and re-renders with a payload flag the document cannot set.
   - Not saved, CSP unchanged; the block returns when the preview opens another document or disappears.
6. **Settings:** the page may post only `setting` for `Settings.panelKeys` (theme, appearance, fontSize, width, bodyFont,
   sidebarCollapsed, which takes a JSON boolean only), sanitized in the extension (`Settings.panelPatch`) and again in the
   writer (`SettingsFile.updateFromPanel`), and `openSettings` for an allow-listed tab. CSS paths, the editor app and
   what is rendered can be set only in the app or settings.json. The `user` host serves only `custom.css` and
   `themes/<plain name>.css`, regular files, no symlinks. Click-safety CSS rules are `!important` inside cascade layers, so no
   unlayered CSS overrides them.
7. **Writer:** writes only to existing Markdown regular files (checked on both the path and the symlink target), at most 64 MB.
   `reveal` only selects an existing file in Finder; `defaultApp` names an app only for a file LinkPolicy allows.
8. **File views:** a file is never rendered as a document. The `file` host serves only images (by an explicit content-type
   map, `nosniff`, a `default-src 'none'` CSP, at most 50 MB); it reads the path it checked, symlinks resolved, and serves no
   PDF, text, HTML or unknown type at all. A PDF is opened by PDFKit in the extension (off the main thread), which runs no PDF
   JavaScript. This moves PDF parsing out of WebKit's WebContent process into the extension itself: a memory-safety bug in
   CoreGraphics' PDF parser would now run in the sandboxed extension, which holds the connection to the writer, rather than
   one process further away. Accepted for a native viewer without WebKit's unlabelled plugin controls; the writer's own checks
   (Markdown files only, LinkPolicy) still bound what that connection can do. Text, code, JSON and CSV reach the page as
   strings and are put in with `textContent`; highlight.js output is sanitized to `<span class>` only. SVG is shown only as
   `<img>`.
9. **Wikilinks and embeds:** the page never chooses a path. The extension resolves each target against its index of the root
   (files only; a symbolic link only when it resolves inside the root; linked folders, hidden folders, `.obsidian`, `.git` and
   `node_modules` never entered; a target with `..`, `.` or an empty step, a NUL, or over 400 bytes resolves to nothing), checks
   the result against the root again, and sends it in the render payload. An embedded image's `src` is set after DOMPurify from
   that payload (DOMPurify would drop a `spacebar:` URL, and the document's markup never supplies one); an embedded note is
   rendered through the same sanitizer, at most 16 per document and 64 KB each, one level deep, with its source lines and task
   boxes removed so a click or a tick can never edit the file on screen at another file's line numbers. Targets are looked up
   as own properties only, so `[[__proto__]]` is just an unresolved link, and each note is embedded once (a note repeating
   `![[X]]` a thousand times gets one copy and links). Resolving stats every target and reads embedded notes, which may be in
   iCloud and not downloaded, so it runs off the main thread; a render uses the file's last result until the new one lands.
   A note inside a vault is rooted at the vault, so its links reach the vault's other notes; a note carrying the quarantine
   attribute (downloaded) is not, and keeps its own folder as its root. Notes Obsidian writes itself (the Web Clipper's, say)
   carry no such attribute and are rooted at the vault like any other.
10. **HTML files:** HTMLPane's web view shares nothing with the preview's page (a non-persistent data store, no
   message handler, no `spacebar:` scheme). Scripts run only when `htmlScripts` is `local` and `getxattr` reports no
   `com.apple.quarantine` attribute (ENOATTR; any other error counts as downloaded). Such a file may also load from the web:
   the default, kept by the user's decision, with the Settings footer saying which files are not flagged. Otherwise
   JavaScript is off and the file is served through `OfflineFiles`, a `spacebar-html:` scheme handler: only regular files
   inside its folder (symlinks resolved). Content rules and CSP block loads but not the connections `<link rel=preconnect>`
   opens, and a data store proxy did not stop them either on macOS 15; matching rel values was defeated by entities, decoys
   and quoting, and frames (data:, srcdoc, an SVG, XHTML or XML file beside it with a namespaced link) carried the same hint
   past any rewrite. So: the document is the only markup served (decoded from its BOM, declared charset or Windows-1252,
   sent as UTF-8), every start tag named `link` or `<prefix>:link` becomes an inert element after the stylesheets beside it
   (at most 8, 1 MB each) are inlined, other files are served only as CSS, images (SVG as an image) and fonts, every
   subframe navigation is cancelled, and the CSP adds `frame-src`, `child-src` and `object-src 'none'`. DNS prefetching of
   hyperlinks is turned off. `test/htmlpane` has a counting server for each of 27 ways in, each at zero connections. Every navigation away from the file is
   cancelled; a link goes on only within a second of a left mouse-up in the pane (a script's `a.click()` is
   `linkActivated` too), and a file link only to a plain, regular, non-hidden (unless shown) file inside the root.
11. **Archives:** `listArchive` takes only a path whose name is an archive extension and whose type LinkPolicy allows the viewer
   to open, and runs one listing at a time. The writer opens the file itself (`O_NONBLOCK`, then `fstat`: a regular file, not
   evicted by iCloud) and hands bsdtar the descriptor as stdin under a `sandbox-exec` profile that denies by default and allows
   only `system.sb`'s system reads and executing bsdtar (`bsd.sb` allowed writes such as `~/.CFUserTextEncoding`): libarchive's parsers, fed a hostile archive, reach no file of the user's,
   write nothing and have no network; the profile also denies every write and metadata reads under `/Users` and `/Volumes`
   explicitly. Output is capped at 2 MB, the run at 5 s, and the reply comes within 9 s whatever bsdtar does; a queued
   listing whose reply has already timed out is skipped. The output is kept as bytes and escapes are undone before it is
   read as UTF-8. Only `openFileOnScreen` (the viewer's Open button) lets the writer hand an archive to an app.
   A binary property list is converted to XML only under a node count and an estimate of the XML's size, so a small file
   naming one large blob many times is refused before it is written out.
12. **Updates:** `installUpdate` refuses a version that is not newer than the running one or not a plain version, or when
   checks are off, and runs only from `~/Applications/spacebar.app`. The script it runs is the app's own `install.sh`, copied
   to a private folder first so replacing the app cannot cut it off mid-read, with only `HOME`, `PATH`, `TMPDIR` and the status
   path in its environment and no inherited descriptors. The installer verifies the release's SHA-256 before it replaces
   anything.

Tests: `test/webcheck.py`, `test/linkpolicy/run.sh`, `test/remoteimages.py`, `test/archive/run.sh`, `test/htmlpane/run.sh`, `test/sidebar.py` (with the
hostile file-browser fixtures in `test/hostile/browser`, a link to `/etc`, names made of dots, and a hostile vault note whose
wikilinks and embeds point out of the root, through a link to the outside and into `.obsidian`), `test/hostile.py` (runs the
hostile fixtures through Quick Look). The two-round adversarial review's findings are fixed in 1c207e0.

## Folder previews

A tester reported that folder previews worked for some folders and not others, Obsidian vaults among the ones that did not.
The rule was the cause, not the platform: v0.1.0 declined any folder with no Markdown file at its top level (it listed only the
folder itself), and the file browser that replaced it (9e0aeac) declined any folder with no visible file at its top level. A
vault or a repository whose notes all sit in subfolders, a folder of folders, a folder of only hidden files and an empty
folder were each handed back to Quick Look, while a mixed folder with one top-level `.md` worked. The second rule also declined
late, after the first listing came back, where every other decline happens before the preview starts.

Now every folder is previewed and the decision is made up front from cheap checks (a realpath, two stats and the URL's
resource values): packages and app bundles (by the system's package flag and a list of extensions such as `.app`, `.rtfd`,
`.xcodeproj`, `.photoslibrary`), a volume's top or a mount point (another device than its parent), and system folders (`/`,
`/System`, `/Library`, `/Applications`, `/Users`, `/Volumes`, `/usr`, `/bin`, `/sbin`, `/private` and its `etc`, `tmp` and
`var`, `/dev`, `/opt`, `/cores`, `/Network`, `~/Library`, and anything below `/System`, `/usr` (except `/usr/local`), `/bin`,
`/sbin` and `/dev`). Temporary folders under `/private/var/folders` are ordinary folders.

Big trees stay off the main thread and bounded: a folder's listing stats at most 5,000 names and counts the rest, the start
scan and the overview share one scan (3 deep, 5,000 entries, 250 ms), and the link index stops at 20,000 entries or 400 ms.
`test/settings/run.sh` times a 12,000-file folder through all three and prints the times of each run.

## Platform findings

- **Which extension wins for Markdown depends on the bundle ID.** With QLMarkdown installed, Quick Look chose `com.patebryant.mdpeek.preview` and `zz.spacebar.preview` over QLMarkdown, but chose QLMarkdown over `md.spacebar.preview`. The name, signing identity and a pluginkit `use` did not change this. Tests use `qlmanage -c md.spacebar.qlmanage -p`, a content type only this extension claims.
- **`net.daringfireball.markdown` is not a system type.** On this Mac Xcode and QLMarkdown declare it; on a clean Mac nothing
  may. The app now imports it (10ceb35). With Xcode's declaration present, Xcode's stays active and ours registers
  `inactive imported untrusted`, so here `.mkd`/`.mkdn` still resolve to dynamic types; `.md`, `.markdown` and `.mdown` resolve to
  the type. That ours becomes active on a Mac without Xcode, and whether "untrusted" clears after the app's first launch, is
  not verified. `public.markdown` is not declared by macOS 15.4 either; the extension claims it anyway, harmlessly.
- **Apple's previews need a mach-lookup exception.** In a sandboxed view-based extension, `QLPreviewView` instantiates and places, but Apple's generators are reached over `com.apple.quicklook` and `com.apple.quicklook.ThumbnailsAgent`, which the sandbox denies: Office, iWork and fonts showed only a generic icon (RTF and USDZ rendered, in process and through a remote view). With `com.apple.security.temporary-exception.mach-lookup.global-name` for those two names (build.sh, both extensions: a folder preview shows the same pane), Office and iWork render in a web view, PowerPoint as PDF, fonts in a remote view; swapping files in one view works; the extension grows from 27 MB to 45–87 MB per document. Measured in a throwaway spike extension on macOS 15.4.1 (branch `spike-qlpreview`). The denial is the extension's: a plain app signed with the same sandbox entitlements, without the exception, renders the same document, so only Quick Look itself can show the exception is needed.
- **Changing the signer of an existing sandbox container prompts.** The first launch with a real signing identity, over a container created by an ad-hoc build, blocks in `secinitd` on a data-sharing consent dialog. Later launches queue behind it until the user answers. Signing with one stable identity from the first launch avoids this.

## Release signing

Releases are signed with a self-signed certificate, "spacebar Release", rather than ad-hoc.

- An ad-hoc signature's designated requirement is its cdhash, so every build has a different signer as far as macOS is
  concerned. The sandbox container finding above means each update would then stop at the `secinitd` data-sharing prompt.
- A certificate gives a designated requirement that names the certificate instead:
  `identifier "md.spacebar" and certificate leaf = H"<certificate SHA-1>"`. Two builds of different code signed with it have
  different cdhashes and the same requirement (checked with `codesign -d -r-` on two local builds).
- It is self-signed because there is no Apple Developer ID behind the project. Gatekeeper does not trust it, and it is not
  meant to: the installer downloads with curl, which sets no quarantine flag. It only keeps the signer the same across releases.
  The move from the ad-hoc v0.1.0 to it changes the signer once, so that one update may prompt.
- The release workflow imports it from the `SPACEBAR_SIGNING_P12` and `SPACEBAR_SIGNING_PASSWORD` secrets into a temporary
  keychain. Without them, as in a fork, it builds ad-hoc and warns. Each `spacebar.zip` also has a GitHub build provenance
  attestation (`gh attestation verify spacebar.zip -R patebry/spacebar`).

## Open questions

Folder previews and live settings ship. Folder previews were verified by hand in Finder; live settings are covered by
`test/webthemes.py` off screen and by `test/settings_live.py` in Quick Look. Platform questions still open from the plan: V2 system
colours and ui-serif in the appex, V3 the folder watch under the read-only exception (the sidebar's live list depends on it;
off screen it is covered by `test/settings/run.sh`, in Quick Look not yet), V6 what Quick Look shows after a folder
decline, V7 the settings window coming forward over the panel.
