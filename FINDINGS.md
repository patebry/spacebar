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
   │  QLFallbackPane       Office, iWork, fonts, 3D, certificates and other types macOS previews, in Apple's QLPreviewView
   │  ImagePane            HEIC, AVIF, TIFF, RAW, PSD, EXR, TGA, JPEG 2000, ICNS decoded by ImageIO into an NSImageView, placed the same way
   │  RichTextPane         an RTF or RTFD document in a read-only NSTextView (AppKit's RTF reader only), placed the same way
   └─ XPCServices/md.spacebar.preview.writer.xpc   unsandboxed XPC service (SpacebarWriter)
        write      compare-and-swap writes to the previewed file: Markdown, or text EditableText allows
        open       links, "Open in editor" and the viewer's "Open with" (NSWorkspace is a no-op inside the sandboxed extension)
        reveal / defaultApp   Reveal in Finder, and the name of the app `open` would use
        openText / textOpener   the Open button for a file shown as text: the chosen text editor, else its default app
                   when LinkPolicy allows it, else the default text editor (LinkPolicy.textOpener)
        beginEdit  owns the hidden, non-activating key panel used for inline editing
        beginFilter / beginListKeys / endFilter   the same panel, over the sidebar's filter field or a clicked row
        listArchive   an archive's entries, from /usr/bin/bsdtar under sandbox-exec (Shared/ArchiveListing.swift)
        readArchiveEntry   one file of an archive, streamed by the same sandboxed bsdtar into memory (ArchiveEntry)
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
A symlinked settings.json (a dotfiles setup) is read but never written, so the migrations cannot reach it: a file there
older than version 2 reads as folder previews on, and one older than version 3 without a `stats` key reads with reading
stats on, until its target gains the current `"version"`. The writer logs the skipped
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
| Folder overview | A folder opens on its own top-level README, `index` or `Home` note, else its overview: folders and files by kind, then the folder's own files and folders as a list (or a grid) whose rows open in the panel; the counts come from one bounded scan (`FolderScan`: breadth first, 3 folders deep, 5,000 entries, 250 ms, off the main thread). A folder not listed within 1.5 s shows the overview's loading state rather than hold the panel. The sidebar's folder name shows it again | `test/sidebar.py`, `test/settings/run.sh` |
| Obsidian | `[[wikilinks]]` (alias, heading, folder path), `![[image]]` (with a width) and `![[note]]` (inline, one level, read only), `> [!type]` callouts in nine colour families, `#tags` as pills. A note inside a vault (an ancestor with `.obsidian/`, at most 8 levels up, never the home or a system folder) is rooted at the vault. Targets are resolved by the extension (`LinkIndex`: by name anywhere under the root, the note's own folder first, then the shallowest; 20,000 entries, 12 deep, 400 ms, built off the main thread and reused while it is rebuilt) | `test/settings/run.sh`, `test/sidebar.py`, `test/webthemes.py` (contrast) |
| Toolbar row and outlined page | The default look: a 40 px row (sidebar button and breadcrumb on the left, Aa and Open on the right beside the file's kind and size in quiet text, quiet buttons with hover and pressed states and tooltips, each keeping its place from file to file) and a 1 px hairline with a 10 px radius around the page, in the theme's border colour at low contrast (1.05 to 2.2:1; High Contrast keeps its strong line), on a chrome tint of the theme's background. `#frame` is a fixed overlay whose shadow is the chrome, so the window still scrolls the page and nothing about scrolling, the TOC or the PDF view changed; the edges outside the page take clicks. Below 480 px, and with **Minimal chrome** (`minimalChrome`, applied at document start), the floating buttons return. Rows highlight on hover, buttons press, the TOC scrolls smoothly; none of it under reduced motion | `test/webthemes.py` (every theme, light and dark: geometry, 4.5:1 for the row, sidebar, callouts, tags and wikilinks), `test/sidebar.py` |
| Sidebar file browser | Every preview, a single file or a folder, shows the previewed folder (the root) as a tree in Finder's order (FolderListing.Options): sorted by `folderSort`, folders among the files unless `foldersFirst` says "always" or, at "finder", Finder's own "Keep folders on top" is on (FinderPrefs reads Finder's plist from the real home, which the sandbox allows; cfprefsd refuses), a README first only when `folderReadmeFirst`, each with an inline-SVG type icon. Folders expand lazily and are re-listed by a watch while open, and when the settings or Finder's preferences change (SettingsStore watches both); expansion is remembered per root for the life of the extension process, and the current file's folders open. Hidden files are skipped unless `showHiddenFiles` or Finder shows them (AppleShowAllFiles); links out of the root, FIFOs and devices always are; packages are single items; at most 5,000 entries per folder, with an "N more" note; past 300 rows only those near the view are in the page. A click shows the file in the panel by kind (FileView): Markdown as before; images fitted with dimensions; PDF natively (below); HTML, video, audio, RTF and Apple's previews (Office, iWork, fonts, 3D) in native views; archives as a tree; code highlighted with line numbers; JSON as a tree and a notebook as its cells, each with a Raw toggle; CSV/TSV as a table capped at 50,000 rows and 200 columns; text; anything else an info card with Open with its default app, or Reveal in Finder where LinkPolicy refuses it. A breadcrumb shows the path from the root; the panel title stays the file Quick Look opened | `test/sidebar.py`, `test/settings/run.sh` (tree, types), `test/scheme/run.sh` |
| Sidebar chrome | A toolbar button collapses it (animated, off under reduced motion); `sidebarCollapsed` is saved through the writer and applied at document start. Its right edge resizes it: 160 px to 45% of the panel or 480 px, saved as `sidebarWidth` once when the drag ends, applied at document start, reset by a double-click; dragging never collapses it. Below 640 px it collapses on screen only and the button shows it over the page; below 1100 px an open sidebar hides the TOC rail | `test/sidebar.py` |
| PDF in the panel | A PDFKit `PDFView` (Preview/PDFPane.swift) laid over the page's `.pdf-area`, under the breadcrumb and beside the sidebar: fitted, continuous pages, a backdrop from the theme. The page posts the area's rect whenever it moves (the sidebar's animation, a drag of its edge, the panel resizing); between posts the view keeps its margins. The iframe it replaced showed WebKit's PDF plugin and its unlabelled HUD buttons. Links in a PDF go through LinkPolicy and the writer. Anything else on screen closes the view and frees the document. Verified off screen, and in a copy of the harness signed with the extension's sandbox entitlements | `test/pdfpane/run.sh`, `test/sidebar.py` |
| Task toggles | The checkbox sends its line and text; Swift re-locates the line and the writer saves it with compare-and-swap | 2338549; `test/corpus.py` |
| Inline editing | See the next section | 068d11d, e1396e9, a742ad8, 4bfa7d6, f2c81fb, bbc51b2 |
| Editing text files | Code, text, JSON, CSV and dotfile config, the whole file in the same key panel, saved in its own encoding; see "Editing text files" | `test/cas/run.sh`, `test/editkeys/run.sh`, `test/encoding/run.sh`, `test/sidebar.py` |
| Double-click fix | See below | a742ad8; `test/dblclick.py` |
| Themes and settings | Six built-in themes (light/dark), user themes and custom.css, live switching, Aa popover, front matter, TOC, stats | `docs/evidence/themes/`; `test/webthemes.py` (offscreen page); `test/settings_live.py` (Quick Look) |
| Contrast | Every built-in theme, light and dark, is WCAG AA: text, `--muted`, quotes and links on the page, every code token on `--hl-bg` and `--code-bg` (diff lines on their tint), toolbar and popover grey text. Apple's link clamps the system accent's lightness (relative colour), so every accent colour passes | `test/webthemes.py` measures each pair from the page's resolved colours, composited on a canvas (bf9dc93) |
| Mermaid through edits | Every redraw renders its new diagram nodes, so diagrams outside the edited block are never left as source | `test/webthemes.py` (bf9dc93) |
| Remote images | Off by default. A blocked image's placeholder has "Load images from the web": that document, this preview, not saved. The page's CSP has no `https:`; an allowed image comes through `spacebar://remote`, which asks the gate per image | `test/remoteimages.py` (da63068) |
| What Space opens | The preview extension's `QLSupportedContentTypes` and the app's `UTImportedTypeDeclarations` are generated by `build.sh` from `scripts/quicklook-types.txt`. Quick Look routes a file to a third-party extension only for its exact type: a parent type (`public.source-code`, `public.text`) never routes, and types Apple previews itself (plain text, HTML, CSV, PDF, images, movies, audio) never do, so those are not claimed. An extension the system has no type for resolves to a `dyn.*` type no extension can claim; the app imports `md.spacebar.type.<ext>` for it. `QuickLookClaims.summary` is the settings window's wording of the list | `test/claims/run.sh` (the built plists against the file), `test/settings/run.sh` |
| HTML view | An HTML file in the sidebar renders in its own `WKWebView` (Preview/HTMLPane.swift), non-persistent, with no message handler or `spacebar:` scheme. Scripts and web loads run for a file without the quarantine flag while `htmlScripts` is `local` (a clone, a `curl` or `unzip` download or a USB copy is not flagged, so it runs too); under `ask`, the default, such a file is shown with web loads but no scripts and the page's own bar asks (`test/htmlscripts.py`); a flagged file, or one whose flag cannot be read, gets no scripts and no network (served through `OfflineFiles`, below). A link leaves the pane only within a second of a real click in it (`LinkClickGate`), one per click, and must name a file the sidebar could list | `test/htmlpane/run.sh`, `test/sidebar.py` |
| Video and audio | AVKit's player over the page's area (Preview/MediaPane.swift), paused on the first frame; audio shows its artwork or icon. The player stops and lets the file go when another file shows or the preview closes. Files with no other view get Finder's large thumbnail on their info card (QuickLookThumbnailing). Besides MP4, M4V, MOV and the usual audio: M4B, 3GP, MPEG-1/2 program streams (`.mpg`, `.mpeg`), MPEG-2 video (`.m2v`) and AMR, each checked to play (`isPlayable`, and the item ready to play) on a fixture made at test time; WebM, MKV, Ogg and Opus stay info cards | `test/mediapane/run.sh`, `test/sidebar.py` |
| Images WebKit does not decode well | HEIC, AVIF and TIFF (unreliable in WebKit, above all on macOS 13), camera RAW (DNG, CR2, CR3, NEF, ARW, ORF, RAF, RW2), PSD, OpenEXR, TGA, JPEG 2000 and ICNS are decoded by ImageIO in the extension or viewer (Preview/ImagePane.swift), EXIF orientation applied, and drawn in an NSImageView in a scroll view over the page's area. The page lays out and paints first, the dimensions in the toolbar from the file's properties; the pane decodes screen-sized (2,560 px) in parallel and decodes the whole image (to 8,192 px) only once a zoom shows more pixels than that. It behaves as the page's `<img>` viewer: fitted; a double-click or a two-finger double tap toggles fit and 100% (200% when 100% is within a fifth of fit) about the point, animated unless Reduce motion is on; a pinch zooms about the pointer, a little past fit and springing back; two fingers or a drag pan a zoomed image, and two fingers over a fitted one scroll the page; ctrl with a wheel zooms; ⌘+ ⌘− ⌘0 zoom and fit (the viewer routes those keys to it before the page); zoom in the toolbar. PNG, JPEG, GIF, WebP, SVG, BMP and ICO stay `<img>`: WebKit decodes them in its content process, a sandbox further from the writer than the extension, and GIF animation and SVG need it; the 50 MB cap applies to both. A file ImageIO cannot decode gets its info card, with Apple's thumbnail when it has one | `test/imagepane/run.sh` (ImageIO-made fixtures, AVIF from ffmpeg when present, and a copy signed with the extension's sandbox), `test/sidebar.py` (sips-made HEIC and TIFF) |
| Disk images | `com.apple.disk-image-udif` routes to a third-party extension (measured in the helper's first spike), so `.dmg` is claimed. Its info card adds the format, by the codec most of its blocks use (zlib, bzip2, LZFSE, LZMA, ADC or uncompressed), and whether it is encrypted, read from the UDIF trailer and block table in the sandboxed process (Preview/DiskImage.swift); nothing is mounted or run, and an evicted iCloud file is not read. Sparse images, sparse bundles and ISOs are not claimed: whether they route can be seen only through Quick Look | `test/diskimage/run.sh` (images made by hdiutil with no file system, so nothing attaches, and hostile trailers), `test/claims/run.sh` |
| Apple's previews | Office, iWork (a single file or a package), fonts, 3D (`.usdz`, `.reality`, `.obj`, `.stl`, `.glb`, `.usd`), certificates (`.cer`, `.crt`, `.der`, `.p12`, `.pfx`), calendars (`.ics`), e-books (`.epub`) and any other declared type of no kind of spacebar's own are shown by Apple's `QLPreviewView` over the page's area (Preview/QLFallbackPane.swift), placed like the PDF view. `QLPreviewView` hands a file to whichever extension Quick Look would pick, and a `.md` in it started a nested spacebar, so `FileTypes.appleQuickLookType` admits a file only when its content type is declared (no `dyn.*`), is not claimed by spacebar and conforms to nothing spacebar claims (the bundle's copy of `scripts/quicklook-types.txt`, read at run time; without it, nothing), and is not a folder, a package other than iWork's, an app, an archive, a disk image, text (anything conforming to `public.text`, bar a calendar and a Wavefront model, which Apple draws), code, JSON, XML, HTML, an image, media, PDF, RTF, a web archive or mail. A vCard (`public.vcard`) is shown as text: Apple's preview of it is an `ABPersonView` in the caller's own process, which asks TCC for Contacts ("TCC access denied to ABPersonView" off screen). A certificate renders as a web view and a calendar event as a remote view, sandboxed too. Declared text types of no kind of spacebar's own went to Apple's generator until the rule refused all of `public.text`: `.strings`, `.pbxproj` and `.pbxuser`, `.m3u`, `.pls` and `.rmp` playlists, `.ips` and `.json_crash` crash reports, `.ndjson`, `.scc` captions, `.slk` and `.vcs` (every declared text type on the Mac is checked). A file that shows only Quick Look's generic icon (an empty `QLLayerBasedPreviewContainerView`) gets its text when it is text, else its info card: the view is looked at 1.5 s after it is placed, and every 0.5 s after that while Quick Look still shows its spinner (a damaged 2 MB document reached the icon only at 2.2 s), for up to 20 s; a change on disk looks again. Needs the mach-lookup exception below | `test/qlpane/run.sh` (a file of every claimed type, and of every declared text type, never reaches the view, the view per type, placing, real renders and the fallback, off screen; a Word document, a certificate and an event rendering in a copy signed with the extension's entitlements), `test/sidebar.py` |
| Archives | The writer lists an archive with `bsdtar -tv` under `sandbox-exec` (see the security model); the page shows it as a tree of folders and files with sizes and dates, at most 5,000 entries, 2 MB of output and 5 s; a name is cut at 4 KB and 64 folders, and the page walks the tree without recursion. `.tbz`, `.txz` and `.tzst` list too. A lone `.gz`/`.bz2`/`.xz` of text shows its text, decompressed by `/usr/bin/gzip -dc` under the same sandbox profile and limits (the first 2 MB); a lone `.zst`, or one of anything else, is shown as the one file inside it. A click on a file, or ↑ ↓ and Return in a list session over the listing, shows it in place (ArchiveEntryView): text, code, Markdown, JSON and CSV as their views, PNG, JPEG, GIF, WebP, BMP and ICO as `<img>` from a one-time `spacebar://entry/` URL kept as a blob, HEIC, AVIF and TIFF in ImagePane from memory, a PDF in the PDF view from its bytes (at most 32 MB, parsed off the main thread); a link inside is named and never read; anything else, a nested archive and a name bsdtar may not be given get the info card, which says to open the archive with Archive Utility. The payload keeps the archive as its `path`, so the sidebar, the file-on-screen checks and the body host treat it as the archive; Back (the view's button, the crumb, ←) re-renders the listing from memory | `test/archive/run.sh` (hostile names in zip, tar.gz and 7z, the caps, a bzip2 bomb, the timeout), `test/sidebar.py` (`archive_entries`) |
| Sidebar keys and filter | ↑ ↓ Home End move a cursor through the tree and open files (a held key opens only the file it stops on), → ← open and close folders (filtered, they only move), Return opens. The filter narrows the tree by a fuzzy, case-insensitive match and searches every listed folder. In Quick Look the page gets no keys, so the sidebar borrows the writer's key panel while it shows, and a click in the filter does too (see the next section) | `test/sidebar.py`, `test/filterkeys/run.sh`, `test/editkeys/run.sh` |
| Rich text | `.rtf` and `.rtfd` (a package or flattened) are read by AppKit's RTF reader only (`NSAttributedString(rtf:)`, `(rtfd:)`, `(rtfdFileWrapper:)`), never its HTML importer: a file that does not start `{\rtf` is refused. Chosen over exporting HTML into the page: no markup to sanitize, no remote load, and the document's own fonts, tables and pictures. Drawn in a read-only NSTextView over the page's area like a PDF; in a dark theme the text view maps the document's colours (`usesAdaptiveColorMappingForDarkAppearance`) while the scroll view draws the theme's background. Links go through the PDF link policy (http(s) only) | `test/richtext/run.sh` |
| Text encodings | A byte order mark (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE), then UTF-16 without one (zeros in one byte lane), then UTF-8, then Foundation's detector over a short list of legacy encodings, else Windows-1252 or Latin-1. Binary stays binary: a NUL outside UTF-16/32, or control characters in more than 2 in 100 characters of a non-UTF-8 decoding. A cut code unit or character at the 2 MB mark is dropped. The decoding keeps its encoding and byte order mark, which an edit is saved in (next section). Markdown is still read as UTF-8 only, since its edits are written back as UTF-8 | `test/encoding/run.sh` |
| Other previewers | Settings lists every other enabled Quick Look extension whose QLSupportedContentTypes share a type with spacebar's (the same identifier, a type for the same filename extension, dyn.* included, or any vendor's Markdown type; never a parent type, which Quick Look does not route by), grouped by the sections of `quicklook-types.txt`, with a confirmed Turn Off (`pluginkit -e ignore`). `install.sh` prints the same list by exact type and never turns anything off | `test/settings/run.sh`, `test/rivals/run.sh` |
| One-click update | The writer checks GitHub's latest release at most once a day (`Updates`, cached in `update.json`); a newer version shows the toolbar's Update button. Update ends any edit and filter session, waits for the edit's saves, then starts the app's sealed `install.sh --version vX --no-prompt` detached, under a log lock that keeps a second run from starting. While it waits or runs no edit, task toggle or filter session starts. The installer quits the writers before their extensions, so Quick Look shows its "failed during preview" screen for a moment; the popover says so (in the Space panel, that spacebar closes for a moment). The page asks after 10 s, 30 s, then every minute how the run ended (`update-status.json`) | `test/updates/run.sh`, `test/webthemes.py`, `test/sidebar.py` |

## Inline editing through the writer's key panel

Quick Look extensions never receive key events: Finder and qlmanage keep them, and a window the extension creates never becomes key.

The unsandboxed writer can own a real window. A click on a block asks it for an invisible, click-through `.nonactivatingPanel` NSPanel over that block. The panel takes the keyboard without activating the app, so Finder stays frontmost and the Quick Look window stays open. An NSTextView in the panel edits the block's Markdown and streams text and selection back over XPC. The page draws the source and caret in place, and every change is saved.

- **Saves:** each save names the bytes it expects on disk. A mismatch is a conflict, and the external change wins. Writes go in place through one file descriptor, so the inode stays the same. If a write fails, the writer restores the old bytes or keeps the text in a `.spacebar-unsaved-` copy (`test/cas/run.sh`).
- **Keys:** Enter ends the block like Notion. Lists and quotes continue; code, math and HTML blocks get a line break that keeps the line's indentation. Enter in a block with no text yet (the paragraph the last Enter opened) is a line break too, so a second Enter shows a blank line instead of doing nothing. Backspace at the start of a block merges it upward. Keys typed during a split or merge are held and replayed. Emptied blocks are removed. The panel has no main menu, so Command shortcuts are mapped by hand: Cmd+A/C/X/V/Z/Shift+Z, and Cmd+arrows, Cmd+Shift+arrows, Cmd+Backspace and Cmd+Delete to the standard line and document moves (`test/editkeys/run.sh`). `test/editflows/run.sh` types whole editing sessions into the real writer in-process, in both hosts, and checks each saved file byte for byte.
- **Ending an edit:** Esc, clicking outside, the panel losing key, any app activation, a change on disk, or the preview closing.
- **The sidebar filter** borrows the same panel: a click in the filter field places it over the field, the typed text streams back to filter the tree, and ↑ ↓ Home End Return are forwarded to move through the matches and open them. It never writes. Esc on an empty field (Esc first clears one with text), a click outside the sidebar, the sidebar hiding, starting an edit, another folder, the panel losing key or the preview closing ends it. Keys an input method is composing with stay with it; starting a filter ends an edit (`test/filterkeys/run.sh`, `test/sidebar.py`).
- **Sidebar keys without a click** (a list session): whenever the preview appears (viewDidAppear, and prepare once the root is known), and after Esc leaves an edit or the filter field, the extension asks the page for the same panel with no field. The page starts it only once the tree of that root is listed, with the sidebar on screen (not collapsed, not hidden by a narrow panel), more than one row, no edit, no update running and **Arrow keys move through the sidebar** on (`sidebarKeys`, default on, settings.json only). A click on a row starts one too. ↑ ↓ ← → Home End Return are forwarded, nothing is typed and no Command shortcut runs; ↑ and ↓ open each file in spacebar's view, so a CSV or an image the arrows reach opens in the sidebar's viewer, not in Apple's previewer through Finder's selection. Esc or Space ends it and hands the keyboard back, and the page says "Press Space again to close"; nothing takes it again until the next appearance, a click on a row, or Esc leaving an edit or the filter (`FilterKeys.relists`). A click elsewhere, another app, or the panel losing key ends it the same way. A click in the filter field turns it into a filter session; a click on a row while a filter session holds the keys keeps the filter (`test/filterkeys/run.sh`, `test/editkeys/run.sh`, `test/sidebar.py`).
- **Why Space and Esc take two presses while the sidebar holds the keys.** The keystroke reaches the writer's panel, not Quick Look, and nothing in reach can pass it on or close the panel. `QLPreviewingController` and `NSExtensionContext` have no dismiss call (the headers offer only `completeRequest`/`cancelRequest`, which end the extension request, not the host's panel). The extension's window is the view service's side of a remote view: a window the extension orders out or closes is not Finder's panel. Ordering the writer's panel out returns key status to the Quick Look panel, but the window server delivers each key event once, to the key window at dispatch time, so the Space that caused it is never redelivered; `NSApp.hide`, `deactivate` or activating the host app change which window gets the next key only. `NSApp.sendEvent` cannot reach another process. Re-posting the key to Finder with `CGEventPostToPid`, or an active event tap that swallows only the arrows and lets Space and Esc through (which would need no key panel at all), both need the Accessibility (post-event) permission and a system prompt; neither ships. Two presses with a visible hint, and a setting that gives the arrows back to Finder, is the least bad of what remains.

Latency, measured in qlmanage from the page's click event (`test/edit_latency.py`, a742ad8):

| | before a742ad8 | after |
|---|---|---|
| click → caret painted | 118–151 ms cold, 41–52 ms warm | about 2 ms |
| click → panel key-ready | 79–99 ms cold, 5–14 ms warm | 5–12 ms cold, 3–5 ms warm |

Typing (068d11d):
- Keystroke → painted: median 3–5 ms.
- Keystroke → saved and re-rendered: median 13–17 ms.

`test/corpus.py` runs 55 scripted sessions over `test/corpus/` and generated 1k/3k/5k-line documents, comparing file bytes exactly. All 55 passed at bbc51b2.

## Editing text files

Code, text, JSON, CSV and config files are edited with the same key panel, in plain mode (`beginTextEdit`): the panel holds the
whole file, Enter and Backspace edit it as they are (no split or merge), Enter keeps the line's indentation (one step deeper
after an opening bracket, the file's own step or four spaces, with a closing bracket right after the caret moved to a line of
its own), Tab types a tab, Shift-Tab takes one step off the lines it touches, a text past 2 MB is not sent to the writer (the
status says so and the edit goes on), and the text view is monospaced and unwrapped so ↑ and ↓ keep the column (`test/editkeys/run.sh`). The Space helper's viewer
uses the same path. Its keys reach the writer's panel, but the window server annotates them with the frontmost app's pid,
Finder's, not the panel's (a live log showed typed letters painted, then the Space closing the panel as a key to Finder), so
the viewer tells the helper when an edit, the filter or the find field holds the keys (`textSession`), and the helper passes
every key until it ends (`test/helper/run.sh`, scenario flow 10).

- **What is editable** (`EditableText` in `Shared/FolderListing.swift`): by name, Markdown, the `code`, `json`, `csv` and `text`
  kinds, and dotfile config (a dot and no extension, or `.env.<name>`), on both the named path and the resolved one, which
  unless both are Markdown must have the same extension (the same name, without one); and by content, a file whose bytes are
  at most 2 MB, not a converted binary property list, and come back byte for byte from its text (`EditableText.open`). A
  UTF-8 file with a stray byte shown as U+FFFD, a file read cut at 2 MB, and a `.txt` link to `.zshrc` or `hosts` are shown
  but not editable.
- **Encoding.** The text is saved in the encoding and byte order mark TextDecoding read it with; CRLF when every line ended in
  CRLF (edited as LF), mixed line endings as they are, and the last newline, or none, as it was. A character the encoding has
  no form for is not saved: the preview says which and keeps it on screen until it is removed; the file is never converted.
  Round trips for Windows-1252, Shift JIS, UTF-16 LE with a BOM, a UTF-8 BOM, CRLF and mixed endings are in `test/cas/run.sh`.
- **Writer refusals** (`EditableText.writeRefusal`, every write): a path not `allowed`, not a regular file, over 2 MB on disk
  or in either buffer (Markdown: 64 MB), what is on disk not text (TextDecoding's heuristic), a binary property list on either
  side. With compare-and-swap on the exact bytes, a buffer that is not the whole file cannot be saved, and the resolved path
  is opened with `O_NOFOLLOW`.
- **Only what was typed** (`TypedTexts` in `Writer/FileWrite.swift`). Code and config can run, and until this change the writer
  took any content for any `.md`: extended as it was, a compromised extension could have written a `~/.zshrc` or a LaunchAgent
  plist (found in review). Now `beginTextEdit` names the file; the writer reads it itself and starts only from its text (or a
  buffer its edits of that file sent, for a click while a save is still landing), `resetEdit` cannot replace a text file's
  buffer, and a write to anything but Markdown must equal, byte for byte, one of the last 16 buffers the panel sent for that
  file (the last 2 once its edit ends; four files at a time), in the file's encoding. Markdown is unchanged.
- **The page** sends a click's offset (`editText`) and gets each change as UTF-16 offsets (`textUpdate`, computed by
  `EditableText.change`). Files up to 24 KB stay highlighted: a change goes into the tokens around it and the file is
  highlighted again 200 ms after typing pauses. Larger files are drawn plain in blocks of 200 lines while edited, so a keystroke
  lays out only the block it touches, and are highlighted again when the edit ends. In the offscreen page harness, a
  keystroke's paint and layout took 2–5 ms for a 20 KB file, highlighted, and 1–3 ms for a 2 MB file; drawing the 2 MB file as
  one text node took about 100 ms.
- **JSON and CSV** keep their tree and table; the toolbar's **Raw** shows the file's text, and a click in it edits it, as in any
  code or text file (there is no separate Edit button: one way to the text, one way to edit it). XML and minified CSS shown
  formatted edit the same way, through Raw; Markdown source under Raw stays read only, since the rendered view edits blocks.
  ⌘F while editing ends the edit (every change is already saved) and opens find; ⌘C copies the edit's selection. While JSON
  does not parse, a note says where (line and column, found by a scan without recursion) and that it is saved as typed;
  `.jsonc` and `.json5` get no warning.
- **Live reload and conflicts** are as for Markdown: a read that finds the bytes this preview saved is dropped, one that may
  predate a write in flight is dropped (the write reads again), anything else ends the edit ("changed on disk"), and a
  conflicting save reloads the file's own text. Text a change on disk displaced stays with the preview, behind a banner,
  until the user keeps it (Markdown only: a write against the new disk text; the writer never puts a text file back over a
  change made elsewhere), takes the disk's, or copies it. Leaving the file waits for that choice.
- **Undo across edits**: the preview keeps the document's text before each edit, split, merge and task toggle while the
  file stays open; ⌘Z past the start of an edit's own undo (the writer's panel asks, `editUndo`), or the toolbar's Undo
  once it has ended, writes the previous one like any edit, against what is on disk. For code and config the writer takes
  it only because it kept that text as an edit's start or end (TypedTexts); a change on disk clears the history.
- **`.env` is editable**: the risk behind keeping it in the preview was handing it to another app, which LinkPolicy still
  refuses. `.npmrc` is not: npm runs what its config names.
- **Never editable: files that run on their own** (`EditableText.runsCode`, on the resolved path): shell startup files,
  `.gitconfig`, `.npmrc`, `.yarnrc`, `.command` and `.tool`, `LaunchAgents` and `LaunchDaemons`, git hooks. The typed binding
  stops the extension writing content of its own, but it can fill the pasteboard and open the invisible panel over another
  file, so one ⌘V could land there (found in review).
- **A writer that restarts** forgets what was typed, so unsaved text it did not see written (a refused character, a failed
  save) can no longer be saved: the preview says so, keeps the text on screen to copy, and lets the user leave the file.

Checked in `test/sidebar.py` (click-to-edit per type, Raw as the way to edit JSON, CSV and XML, the JSON warning, saving in the file's encoding through
the harness's stand-in for the extension, 60 changes in a row kept exact in both drawings, and what is never editable).

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
   - Block editing, task toggles and "Open in editor" apply only to Markdown; a whole-file edit (`editText`) only to the text
     file on screen when it was read as editable (EditableText). `openFile` and `reveal` apply only to the file on screen;
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
   - Not saved; the block returns when the preview opens another document or disappears.
   - The page's CSP has no `https:` in `img-src`, so no remote image loads straight into the page whatever the setting. An
     allowed one is rewritten to `spacebar://remote/?u=<https URL>`, and the scheme handler fetches it (`RemoteImages`:
     ephemeral session, no cookies or credentials, https only through redirects, an `image/*` 2xx answer of at most 20 MB
     within 20 s) only while the gate allows the file on screen, asked when the image is requested and again when it
     arrives.
6. **Settings:** the page may post only `setting` for `Settings.panelKeys` (theme, appearance, fontSize, width, bodyFont,
   sidebarCollapsed, which takes a JSON boolean only), sanitized in the extension (`Settings.panelPatch`) and again in the
   writer (`SettingsFile.updateFromPanel`), and `openSettings` for an allow-listed tab. CSS paths, the editor app and
   what is rendered can be set only in the app or settings.json. The `user` host serves only `custom.css` and
   `themes/<plain name>.css`, regular files, no symlinks. Click-safety CSS rules are `!important` inside cascade layers, so no
   unlayered CSS overrides them.
7. **Writer:** writes only to existing regular files of a type spacebar edits (checked on both the path and the symlink target;
   `EditableText.writeRefusal`): Markdown at most 64 MB; other text at most 2 MB on disk and in both buffers, text on disk,
   never a binary property list, and only a buffer the writer's own panel sent for that file (`TypedTexts`).
   `reveal` only selects an existing file in Finder; `defaultApp` names an app only for a file LinkPolicy allows.
8. **File views:** a file is never rendered as a document. The `file` host serves only images (by an explicit content-type
   map, `nosniff`, a `default-src 'none'` CSP, at most 50 MB); it reads the path it checked, symlinks resolved, and serves no
   PDF, text, HTML or unknown type at all. A PDF is opened by PDFKit in the extension (off the main thread), which runs no PDF
   JavaScript. This moves PDF parsing out of WebKit's WebContent process into the extension itself: a memory-safety bug in
   CoreGraphics' PDF parser would now run in the sandboxed extension, which holds the connection to the writer, rather than
   one process further away. Accepted for a native viewer without WebKit's unlabelled plugin controls; the writer's own checks
   (EditableText's types and refusals, LinkPolicy) still bound what that connection can do. The same holds for the images ImagePane decodes
   with ImageIO (HEIC, RAW and the rest, which the `file` host never serves) and for a `.dmg`'s trailer and block table read by
   DiskImage. Text, code, JSON and CSV reach the page as
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
   `com.apple.quarantine` attribute (ENOATTR; any other error counts as downloaded). Such a file may also load from the web.
   Under `ask`, the default since settings version 6 (a stored `local` from before reads as `ask`), an unflagged file
   loads as it would under `local` but with JavaScript off; when its first 8 MB hold a `<script`, an `on…=` attribute or a
   `javascript:` attribute value, the preview's page (not the file's view) shows a bar whose buttons take only a trusted
   click that went down on them, and the writer's `answerScripts` sets `local` or `off` only while the setting is still
   `ask`. A script-run page gets read access to its folder for its own images, styles and scripts, but WebKit's file origins
   keep its scripts from fetching or framing any other file: fetch, XMLHttpRequest, a frame's document and a canvas drawn
   from a sibling are all refused (`test/htmlpane`); a sibling can still be loaded as a script, stylesheet or image. Otherwise
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
   `readArchiveEntry` (0.4) takes the same path checks and the same queue, and streams one member with
   `bsdtar -x -O -q -n -f - -- <pattern>` under the same profile: the name is one argv element after `--`, refused when it
   starts with `-`, and escaped (`\ * ? [ ]`, a leading `^`) so the pattern matches it alone; the extension asks only for a name its listing
   on screen gave. The writer picks the cap from the name (2 MB text, 20 MB image, nothing for other types), stops bsdtar one
   byte past it or past 1,024 times the archive's size (a bomb), and after 5 s. See SECURITY.md.
   A binary property list is converted to XML only under a node count and an estimate of the XML's size, so a small file
   naming one large blob many times is refused before it is written out.
12. **Updates:** `installUpdate` refuses a version that is not newer than the running one or not a plain version, or when
   checks are off, and runs only from the copy install.sh would replace (`~/Applications/spacebar.app`, or
   `/Applications/spacebar.app` when that is the only one) when this account can write it. The script it runs is the app's own `install.sh`, copied
   to a private folder first so replacing the app cannot cut it off mid-read, with only `HOME`, `PATH`, `TMPDIR` and the status
   path in its environment and no inherited descriptors. The installer verifies the release's SHA-256 before it replaces
   anything.

Tests: `test/webcheck.py`, `test/linkpolicy/run.sh`, `test/remoteimages.py`, `test/htmlscripts.py`, `test/archive/run.sh`, `test/htmlpane/run.sh`, `test/sidebar.py` (with the
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

Big trees stay off the main thread and bounded: a folder's listing stats at most 10,000 names and counts the rest, the start
scan and the overview share one scan (3 deep, 5,000 entries, 250 ms), and the link index stops at 20,000 entries or 400 ms.
`test/settings/run.sh` times a 12,000-file folder through all three and prints the times of each run.

### The folder grid

A folder of pictures opens on a grid (`FolderListing.isMediaFolder`: six files or more, 60% images or video). The page draws
only the rows in view plus two above and below, from the sidebar's listing of the root, and asks for their thumbnails from
the `thumb` host, eight at a time, those in view first. ThumbnailPipeline makes them, up to six at once, in request order,
and keeps them in memory (48 MB or 4,000, least recently used first; all dropped under memory pressure).

- **WebKit does not stop an image load when the `<img>` goes.** Removing a tile's image, or its `src`, never reached
  `webView(_:stop:)` for a custom scheme: WebKit keeps loading the resource for its memory cache. A fast scroll through 5,000
  images made 582 thumbnails for a screen of 36. The page therefore names the loads it dropped (`thumbDrop`), and the handler
  cancels each (a queued one is never made, a Quick Look request is cancelled) or refuses it when its task starts later. The
  same scroll now makes 40.
- **Timings** (M2 Max, macOS 15.4.1, warm web view, `test/sidebar.py`'s harness): the first row of five 12-megapixel JPEGs (14 MB
  each, noise, the slow case) filled in 84 to 133 ms with nothing cached, 8 to 10 ms from the cache; four at once took 167 to
  178 ms, hence six. The first row is logged as `grid first row …ms`.

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

From v0.3 releases are signed with spacebar's Apple Developer ID, notarized and stapled. v0.1.1 to v0.2.2 were signed with a
self-signed certificate, "spacebar Release", and v0.1.0 ad-hoc. Local builds keep a self-signed identity (`.sign-id`).

- An ad-hoc signature's designated requirement is its cdhash, so every build has a different signer as far as macOS is
  concerned. The sandbox container finding above means each update would then stop at the `secinitd` data-sharing prompt.
- A certificate gives a designated requirement that names the certificate instead:
  `identifier "md.spacebar" and certificate leaf = H"<certificate SHA-1>"`. Two builds of different code signed with it have
  different cdhashes and the same requirement (checked with `codesign -d -r-` on two local builds). A Developer ID's names
  Apple's anchor and the Team ID (`anchor apple generic and identifier "md.spacebar" and ... certificate leaf[subject.OU] =
  <Team ID>`), so it also outlives a renewed certificate.
- "spacebar Release" was self-signed because there was no Developer ID. Gatekeeper did not trust it, and it was not meant to:
  the installer downloads with curl, which sets no quarantine flag. It kept the signer the same across releases. The move
  from it to the Developer ID changes the signer once, as the move from the ad-hoc v0.1.0 did, so the first update from 0.2
  may prompt (not seen yet: there is no Developer ID build to update to).
- Every executable is signed under the hardened runtime: the helper admits only peers that are, and notarization requires it
  of all of them. None needs an entitlement for it. WebKit runs pages in its own processes, so nothing in spacebar's needs
  JIT memory, and every library they load is Apple's, which library validation allows. `test/hardened/run.sh` signs the
  extension's code with the built extension's entitlements, the sandbox and the runtime, and shows Markdown, JSON, a zip
  (listed by the writer, also under the runtime), a PDF (in the page's PDF view; PDFKit reads it) and an image; `test/signing/run.sh` lists every Mach-O in a build
  with its flags and entitlements. Quick Look itself cannot be asked to run a local build without registering it.
- Notarization also needs a secure timestamp on every signature. `TIMESTAMP=1` asks Apple's timestamp server, and is the
  default for a Developer ID identity; a local build with a self-signed one signs offline (`--timestamp=none`).
- spacebar has no app group, keychain group, provisioning profile or launch constraint of its own, so a Team ID changes
  none: macOS 15's rule that a group ID carry the Team ID does not apply. The helper's link pins the peer's leaf certificate,
  read at run time from its own signature, so it holds for any identity that signs the whole build.
- The release workflow imports the identity from the `SPACEBAR_SIGNING_P12` and `SPACEBAR_SIGNING_PASSWORD` secrets into a
  temporary keychain and signs with the one identity it holds. From v0.3 that must be a Developer ID Application identity,
  and `SPACEBAR_NOTARY_KEY`, `SPACEBAR_NOTARY_KEY_ID` and `SPACEBAR_NOTARY_ISSUER` must be set, or the release fails before
  the tests. They are a Team API key from App Store Connect (Users and Access, Integrations): its .p8, key ID and issuer ID.
  An Individual key has no issuer ID and is not supported. It notarizes the zip, staples the app, zips it again, makes
  `spacebar.dmg` from the stapled app (`scripts/dmg.sh`: the app and a link to /Applications), and signs, notarizes and staples that.
  Before v0.3 it builds the zip alone, as before; without the secrets, as in a fork, ad-hoc with a warning. Each
  `spacebar.zip` (and `spacebar.dmg`) has a GitHub build provenance attestation
  (`gh attestation verify spacebar.zip -R patebry/spacebar`).

## Install

spacebar is installed in `~/Applications` by the install command, or in `/Applications` by dragging it there from
`spacebar.dmg`. There is one managed copy: `~/Applications/spacebar.app` when it is there, else
`/Applications/spacebar.app`; with neither, the one whose swap was cut short (its `.spacebar.app.old`). A stale `.old` in
`~/Applications` does not hide a copy in `/Applications`: install.sh updates that copy and names the `.old`. install.sh
updates the managed copy in place with the same checksum, exact paths and rollback; the Update button runs only from it;
the uninstaller removes either or both. With a copy in both, install.sh keeps to `~/Applications` and warns about the
other, as before. Both scripts refuse to run as root: `sudo` can keep the user's HOME, which would leave a root-owned copy
there, registered with root's Launch Services and pluginkit.

- **A standard account cannot change `/Applications`** (`root:admin`, `drwxrwxr-x`), and a copy an administrator dragged
  there is owned by them with folders mode 755, so even another administrator cannot delete what is inside it. install.sh
  checks the folder and every folder inside the copy before it downloads, and stops with nothing changed rather than
  install a second copy in `~/Applications`: that one and the old one would claim the same bundle IDs and file types, Quick
  Look could go on using the old one, and nobody on that account could update or remove it. The uninstaller leaves such a
  copy, names it, and exits 1; the preview does not offer Update for it, and Uninstall in Settings says why it cannot. The
  app checks the same folders the scripts do (`Updates.canChange`). A link where a copy should be is never treated as one:
  install.sh stops, and the uninstaller deletes only the link.
- **Launching an app registers its extensions, but turns them neither on nor off.** Measured on macOS 15.4.1 with a probe
  app of unique bundle IDs (self-signed, a sandboxed Quick Look preview extension) in a scratch folder: `pluginkit -mAv`
  listed nothing after the bundle was made, and listed the extension within 2 s of `open`, with a blank mark (neither `+`
  nor `-`). The probe was unregistered and deleted afterwards. A copy made by Finder from a disk image was not measured.
  So at each launch the managed copy (not a link) adds an extension pluginkit does not list at its path, and turns it on (`pluginkit
  -e use`) while no listed version of it has a mark, the folder one only while folder previews are on. `pluginkit -e`
  acts on the bundle ID, not a path, so a `+` or `-` on any copy's line counts as the user's choice and is left alone. A
  second copy does nothing. The list comes from `pluginkit -mADv`: without `-D`, a copy of the same version at another
  path is not listed (here three registered copies of 0.1.0 showed as one, each with the same mark).
- **App Management** (macOS 13) refuses changes to a notarized app's bundle by a process of another Team ID unless the user
  allows it, wherever the app is (lapcatsoftware.com/articles/AppManagement.html), so it is not new with `/Applications`:
  from v0.3 a release is notarized, and the install command run from a terminal without App Management may be refused when
  it moves the old copy aside. install.sh then stops with the old copy in place and re-registered, and says where to allow
  it; the uninstaller, refused at `rm`, names the copy, goes on to the other and exits 1. Not observed here: the terminal used for this work has App Management (and Full Disk Access) granted, and local
  builds are self-signed and not notarized, which App Management does not protect. The Update button runs install.sh from
  the writer inside the same Developer ID-signed app, which App Management should allow as the same Team ID; that is
  untested until a notarized release updates to a later one.
- **The Space helper** is registered by the app through SMAppService for its own bundle, so an update in place keeps its
  path and nothing about the helper changes. Two copies would each register the same label; that is left as before.

## Space helper

**Why a helper.** Quick Look hands an app's extension only the types it claims, and never plain text, rich text, HTML, CSV,
PDF, images, video or audio: Apple keeps those. Inside the preview, the extension gets no key events, so Space and Esc take
two presses while the sidebar holds the keys (above). Both limits are Quick Look's, so the only way past them is not to go
through it: a process that sees Space in Finder, reads the selection, and opens spacebar's own panel. That needs
Accessibility (an event tap that can swallow keys, and AX reads of Finder), which nothing that parses files should hold. So
there are two processes: `spacebar Helper.app`, unsandboxed, with Accessibility and the tap, built without any file-reading
code; and `spacebar Viewer.app`, sandboxed like the extension, which runs the same `PreviewController` in a non-activating
floating panel and never sees a key the helper did not send it. Rejected: one unsandboxed process (a renderer exploit would
get a keylogger) and hosting the Quick Look extension remotely (no public API). SECURITY.md has the privilege split.

**What the first spikes found.**
- *The viewer reaches the helper from its sandbox* through `temporary-exception.mach-lookup.global-name` for the one Mach
  name, `md.spacebar.helper`; nothing else is added to the extension's entitlements.
- *Files and Folders prompts name the outer app.* A viewer nested in an app and launched by its helper asked for Documents
  and iCloud Drive under the outer app's name, not its own, so spacebar's prompts say "spacebar".
- *Accessibility lists the helper by its bundle's file name,* "spacebar Helper", not its `CFBundleDisplayName` ("spacebar").
  A localized display name (`LSHasLocalizedDisplayName` with an `InfoPlist.strings`) did not change what Launch Services
  reports either, so the settings app and the welcome sheet name it "spacebar Helper", and the claims test holds that name
  to the bundle's.
- *Handing a Space back to Finder* (`CGEventPostToPid`, tagged so the tap lets it through) is not yet checked live. The
  helper logs whether Apple's Quick Look is open 600 ms later. It is used only when the viewer declines or does not answer
  within 150 ms, and not at all for a Space more than a second old.
- *Replacing the app in place stops the helper* (below).
- *A pinch never reached the panel.* NSApplication.sendEvent drops magnify and smart-magnify events in an app that is not
  active, key window or not; scrolls and clicks get through. The viewer is never active, so neither `<img>` nor ImagePane
  could be pinched there. `GestureRouter` (Preview/Gestures.swift) takes them in a local event monitor and hands them to their
  window, which dispatches them to the view under the pointer. Found and checked in-process: `test/imagepane/run.sh` shows the
  drop without the router, and it, `test/sidebar.py` and `test/viewerlatency/run.sh` send pinches, two-finger taps, scrolls
  and double-clicks through NSApp.sendEvent to a window that is never key.
  *That was not enough on a real trackpad:* a real pinch over the panel did nothing, while the same events sent in-process
  zoomed. In-process events cannot show where the window server sends a pinch; most likely to Finder, the active app, so
  the viewer never sees one. The helper now has a second tap, for gesture events, on only while the panel is open; a pinch or
  smart zoom begun over the panel (`GestureRoute` in Helper/Decision.swift, decided where the pinch begins and held to its
  end, one event type per pinch) is swallowed and sent to the viewer, which re-targets it at its window and hands it to the
  window (`Viewer.gesture`). `test/panel/run.sh` pinches a PNG, a HEIC and a PDF that way. The helper logs the first pinch of
  each opening, counted by event type and subtype; whether the window server marks a gesture with the window under the
  pointer (else the panel's bounds, as the viewer last reported them, decide where a pinch begins) is not yet checked live.

**Why the helper stays down after an update, and what brings it back.** The helper is signed without a Team ID (self-signed,
as every local build is; releases have one from v0.3). Background Task Management then ignores the plist's bundle
identifiers ("Bundle identifiers from launchd plist ignored because the executable doesn't have a Team ID") and pins the
agent's launch constraint (LWCR) to the helper's code, and it keeps that item across unregister and register: each
`registerLaunchItem` logs "found existing item" with the old UUID. A new build has a new code hash (every change of source or
CFBundleVersion does; an identical rebuild does not), so AMFI refuses it: "Launch Constraint Violation ... (Constraint not
matched)", OS_REASON_CODESIGNING, and launchd reports `spawn failed`, `last exit code = 78: EX_CONFIG`, `needs LWCR update`.
Meanwhile the old helper keeps running from the replaced bundle. It can still answer the settings app's status query, which made `--reregister` report "helper already answering" and leave it running with the old code; so the status carries the stamp (inode and modification time) of the executable the helper started from, and a helper whose stamp no longer matches the file in the app counts as down. The item
is rebuilt for the new binary (`invalidateLaunchItem`, a new UUID) only when an SMAppService status query arrives after launchd
has refused a launch of the current submission, about 10 s after it was registered; the next unregister and register then
launches the helper within 3 s. The old `--reregister` unregistered exactly 10 s after each register (its 10 s wait for an
answer), just before any query could rebuild the item, so it failed for minutes until something else queried at the right
moment. Measured on this Mac, each with a new build installed by build.sh, until `--helper-status` said trusted, tap and
viewer:

| Method | Result |
|---|---|
| nothing | still down after 421 s (old helper running, unreachable) |
| `launchctl kickstart -k` only | still down after 302 s |
| (a) old `--reregister`: unregister, 20 s, register, 10 s wait, 6 times | down after 400 s and 304 s; only a later run, started once the item had been rebuilt, worked (21-22 s) |
| (b) unregister before the swap, register after | still down after 90 s; the item was rebuilt at +11 s, and an unregister and register then brought it up in 3 s |
| (c) `launchctl bootout` after the swap, then register | still down after 241 s; rebuilt at +10 s by a status query, then up 3 s after an unregister and register |
| (d) a new CFBundleVersion per build | no difference: every build here had one and each was refused; the constraint follows the code hash |
| (e) `lsregister -f -R` before registering | no difference: build.sh runs it before every one of these |
| new `--reregister`: register, wait for the refusal, query status at 11 s, unregister and register | helper answering in 11-17 s over 4 runs; the viewer followed within about 20 s when an old viewer was still running (install.sh quits it first) |

A different label or path per build would start a fresh item each time, but it would leave one Login Items entry per update
and move the helper's Mach name, so it was not tried. A Developer ID build should let the item use bundle identifiers and
keep one constraint across updates; that is untested until there is one. `--reregister` needs no change for it: it returns
as soon as the helper answers, so with a Team ID it should finish at its first attempt. install.sh (and so the one-click update) starts
`--reregister` in the background whenever the agent is loaded, and it retries with backoff for up to 10 minutes. The settings
app runs it too, at launch and after three polls in a row without an answer while the helper should be running.

**Speed.** Space to decision (the AX reads of Finder and `Decision.space`), against a budget of 60 ms past which the key goes
to Finder: in the spike's recording of 14 Finder contexts (list, icon, column and gallery views, the desktop, a rename, the
search field, Quick Look open), 6.2 ms median and 10.9 ms at most; on an early build of the helper in daily use, 9 Spaces that opened the
panel, 7.5 ms median and 14.3 ms at most. The target is 8 ms p50.

The viewer's side is measured off screen by `test/viewerlatency/run.sh`: the real `Viewer` and `PreviewController`, driven
through the call the helper makes over XPC (`show`, from a background thread, then `key` and `close`), the panel parked off
every display, and a stand-in writer service that answers at once. *Frame* is show to the panel's first frame with alpha above
0 in the window server (polled with `CGWindowListCopyWindowInfo`); *painted* is show to the content drawn: the page's
`rendered` message (posted from the animation frame after it lays out), an `<img>` decoded, or a native view up with its
content. The helper's own decision (8 ms) is added to each before it is held to its target. 

Measured on this Mac (macOS 15.4.1, Apple silicon, in daily use), 20 shows of each file, warm, at the commit
that adds this paragraph:

| File | Frame p50 / p95 | Painted p50 / p95 |
|---|---|---|
| Markdown (README.md, 25 KB) | 15 / 22 ms | 44 / 48 ms |
| Log, 200 KB | 30 / 34 ms | 37 / 44 ms |
| Swift, 100 KB (highlighted after paint) | 44 / 48 ms | 63 / 76 ms |
| PNG 1.7 MB, `<img>` | 14 / 21 ms | 25 / 41 ms |
| JPEG 12 MP, `<img>` | 15 / 18 ms | 25 / 43 ms |
| HEIC 12 MP, ImagePane | 18 / 22 ms | 50 / 60 ms |
| PDF, 12 pages, PDFPane | 20 / 21 ms | 33 / 33 ms |

With the helper's 8 ms, frame p95 over every kind is 53 ms (target 60) and painted for Markdown, text, images and PDF 42 ms
p50 and 58 ms p95 (targets 120 and 200). An arrow to the next file in the sidebar paints in 21 ms p50, 51 ms p95 (a 100 KB
Swift file among Markdown, text and a PNG; target 50). The first show after the viewer starts: frame 91 ms, painted 129 ms.
Single outliers of about 500 to 700 ms, one in 140 shows, did not recur under logging or when run alone. Memory: the viewer
idles at 19 MB footprint (64 MB resident) and at 37 MB (100 MB resident, most of it shared frameworks) after every kind has been
shown; WebKit's content process is apart. Target 90 MB. Live, the installed helper had 13 MB footprint and 20 MB resident
(target 25 MB).

- **Stale frame.** The panel is revealed on the page's `painted` message, which is posted once the DOM is built, before
  WebKit has drawn it; WebKit's drawing reached the window server 2 to 3 frames after the panel's alpha, so a panel reused
  for another file showed the last one for about 30 ms (a red image, then Markdown: the first captured frames were red).
  Waiting for two animation frames before revealing fixed it but put the frame at 45 to 65 ms, and a deferred highlight
  pushed code to 180 ms. Instead, closing now empties the page (`sb.blank`) and waits a frame, at alpha 0, before ordering the
  panel out: the next file's first frame is at worst empty. A panel suspended for Finder keeps its content; one that is then
  closed, or replaced by a show of another file, is emptied the same way before it next appears. The harness checks each
  first frame for the last file's red: after a reuse, and after a suspend followed by a restore (red, as it should be), a
  close, or a show of another file.
- **Code.** highlight.js on 100 KB of Swift took about 150 ms before the first paint (frame 200 ms). Text over 24 KB is
  painted plain and highlighted after the first paint.
- **Native images.** ImagePane decoded before the page rendered (a 12-megapixel HEIC's frame at 54 ms p50); the page now
  paints first and the pane decodes in parallel.
- **Warm-up.** The viewer runs the page's renderers once on a sample at launch (`sb.warm`); the first show after launch went
  from about 100 ms to about 90 ms to its frame. Its cost otherwise is WebKit's first render and, for a document with a diagram,
  loading mermaid.
- Not changed: the page is already loaded when the viewer starts, the web view and every pane are reused across shows, and a
  folder is listed off the main thread once per show (the listing is not what the frame waits for).

**Hide and restore.** Apple's Quick Look hides when Finder goes to the background and comes back with Finder; the panel
closed instead. Now another app coming forward over an open panel suspends it (`Decision.activated`): the viewer orders it
out, keeping what it shows, and the helper gives Finder its keys at once. Finder activated again within 2 minutes restores
it only when Finder's selection is the one the panel showed (`Decision.resumes`), as Apple's panel comes back only with its
file. The first version restored on any return of Finder: a click on the Desktop brought back a panel closed by switching
away, and "Show in Finder" from Telegram brought back the old file over the new selection. The selection is read through AX,
within the Space budget, 100 ms after Finder comes forward and again 200 ms later, and both reads must match: a reveal or a
click may still be changing it, and how long Finder takes is not measured. A different or empty selection, a click on the
Desktop (Finder's focus in no window, and a mouse button down within the last second with the Desktop the first thing under
the pointer), an AX error or a spent budget drops the panel as a close does, and the next Space shows what is selected then.
What a restore must find is the selection of the last show the helper accepted on screen, not of one still on its way. A
show that replaced an open panel's file was never answered (the viewer announced only a panel it revealed), so it stayed
pending until the helper's 5 s check; the viewer now answers it too. 2 minutes covers answering a message or copying a value
and coming back; later the panel is a leftover. A restore goes through the same gate as a show: pending, acknowledged within
150 ms, and taking Finder's keys only once `panelState` reports a window the helper sees on screen (with its one retry); a
restore that fails the gate closes the panel rather than leave it up without keys. A show still on its way when another app
comes forward is closed, as before.
Native views stay while suspended (media paused), so a PDF keeps its page and a video its time. The first version of this
let the suspend go through the viewer's ordinary hide, which closed the native views: a restored HEIC came back empty and a
PDF lost its page. `test/helper/run.sh` checks the rule; `test/viewerlatency/run.sh` checks what a restored, closed or
replaced panel shows and that a PDF keeps its page; `test/helper_live.command` walks through the round trip in Finder.

**The live checklist.** `test/helper_live.command` runs in Terminal while you use Finder: Finder's four views and the
Desktop, rename and search keeping their Space, one-press Space and Esc, the sidebar's arrows, multi-select, hide and
restore, a `.dmg`, camera RAW when there is a file, ⌘Y, secure input, the helper back after an update, and after a restart.
Its step 14 turns Accessibility off and on: the helper removes its tap once the grant is gone (it re-enables a tap macOS disabled only while Accessibility is granted) and makes a new one when it is back, within its 2 s check; `--helper-status` reports whether the tap is enabled, not only whether it exists. It tails the helper's, viewer's and preview's logs (`log stream`, subsystem `md.spacebar`) and grades each step from them,
asking you only what the logs cannot show. It sends no input itself.

## Large files

The page used to get every file's text inside its render script: `render()` escaped the payload with JSONSerialization and
handed WebKit `sb.render(<json>)`, all on the main thread. `test/bigfiles/run.sh` measures that path off screen, through the
real `Viewer` and `PreviewController` driven as the helper drives them: for each file, show to the page's DOM drawn (its
`painted` message), show to the content up (a table row, a tree row, the PDF view, the listing), the longest the viewer's main
thread went without running a block posted to it every millisecond, and the viewer process's peak footprint (sampled every
0.5 ms; WebKit's content process is apart). Measured on this Mac with the screen locked, 3 shows of each from a closed panel,
median times; stall and growth are the worst of the 3. With the screen locked no animation frame runs, so `rendered` and the
PDF view's placement never come: every time here is to the DOM, not to pixels. The stall and memory numbers are unaffected.

| File | Main stall before / after | Footprint growth before / after | DOM before / after | Content before / after |
|---|---|---|---|---|
| CSV 16 MB, ASCII | 43 / 8 ms | 29 / 13 MB | 460 / 386 ms | 478 / 404 ms |
| CSV 16 MB, CJK and accents (UTF-8) | 148 / 7 ms | 51 / 31 MB | 393 / 246 ms | 411 / 263 ms |
| CSV 16 MB, Windows-1252 | 131 / 8 ms | 36 / 18 MB | 670 / 575 ms | 686 / 592 ms |
| Markdown 4 MB, BOM, CRLF, 80,000 `[[links]]` | 863 / 2 ms | 16 / 5 MB | 2,581 / 1,181 ms | 5,811 / 3,623 ms |
| CSV 50,000 rows (2.4 MB) | 6 / 3 ms | 3 / 6 MB | 77 / 67 ms | 95 / 85 ms |
| JSON 2 MB, minified | 5 / 2 ms | 3 / 4 MB | 92 / 80 ms | 95 / 85 ms |
| JavaScript 2 MB (highlighted after paint) | 6 / 2 ms | 5 / 4 MB | 158 / 162 ms | 340 / 340 ms |
| PDF, 500 pages | 8 / 9 ms | 1 / 1 MB | 12 / 13 ms | 14 / 14 ms |
| PNG 12,000 × 12,000, `<img>` | 1 / 3 ms | 0 / 0 MB | 4 / 4 ms | 8 / 10 ms |
| zip, 10,000 entries (5,000 listed) | 16 / 16 ms | 3 / 2 MB | 5 / 6 ms | 234 / 236 ms |
| Folder of 5,000 files (overview) | 19 / 18 ms | 2 / 2 MB | 127 / 127 ms | 129 / 129 ms |
| A file in that folder (sidebar of 5,000) | 17 / 18 ms | 1 / 2 MB | 7 / 6 ms | 12 / 12 ms |

Where the time went, measured in process: escaping a 16 MB payload took 33 ms for ASCII and 95 ms for accented and CJK text,
plus 10 ms for WebKit to take the script; a Windows-1252 file decodes to a bridged UTF-16 string, and getting its UTF-8 cost
40 ms more on the main thread (`makeContiguousUTF8` on the same string: 317 ms). For Markdown, the wikilink scan ran
NSRegularExpression over a native string through its bridge (400 ms for 3 MB; 20 ms over a UTF-16 copy), and the check for
unsaved text on the next show compared the document with its CRLF form (400 ms and more).

What changed:
- A text over 256 KB leaves the payload: `PageBody` holds it as UTF-8 behind a random one-time URL, `spacebar://body/<UUID>`,
  and the page reads it with a synchronous request as its render starts, so renders still run one at a time and in order. The
  handler serves only that URL, once, while its file is still on screen, and reads nothing from disk. A request for any other
  URL, a superseded render's, leaves the body for its own render: consuming it on a miss made the second of two queued renders
  never draw. The body starts with a byte order mark, because the page's decoder removes exactly one, and a document that
  starts with U+FEFF keeps it. The page's CSP gains `connect-src spacebar://body`, and `img-src` names its three hosts.
- Text is made native UTF-8 off the main thread (`TextDecoding.nativeUTF8`), so the main thread only copies bytes.
- The Markdown reader normalizes CRLF and finds link targets off the main thread; `links(in:)` scans a UTF-16 copy; the
  targets are kept for the text they came from.
- Unsaved-text checks compare with the text last known to match the disk before building the on-disk form.

Not changed: a 5,000-file listing or overview holds the main thread about 18 ms and a 10,000-entry archive about 16 ms, both
under the 50 ms line. The page itself still takes most of a second for a 16 MB table and over 3 s to lay out 4 MB of Markdown
with 80,000 links; that is WebKit's content process, not the viewer, so the panel keeps answering keys meanwhile.

Open: under the harness, the writer's archive listing sometimes comes back empty, and the page shows "This archive's contents
can't be listed" (2 of 10 shows, before this change too). `ArchiveListing.list` on the same zip never failed in 40 direct or
concurrent runs, so the loss is somewhere between the XPC call and the reply. bigfiles reports it as KNOWN.

## Open questions

Folder previews and live settings ship. Folder previews were verified by hand in Finder; live settings are covered by
`test/webthemes.py` off screen and by `test/settings_live.py` in Quick Look. Platform questions still open from the plan: V2 system
colours and ui-serif in the appex, V3 the folder watch under the read-only exception (the sidebar's live list depends on it;
off screen it is covered by `test/settings/run.sh`, in Quick Look not yet), V6 what Quick Look shows after a folder
decline, V7 the settings window coming forward over the panel.
