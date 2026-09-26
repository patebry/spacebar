# spacebar: engineering notes

> Short hashes in parentheses, such as a742ad8, refer to the private development history that this public repository was squashed from.

This is a Quick Look preview extension for Markdown on macOS 13+ (universal: arm64 and x86_64), built without Xcode (`build.sh`, swiftc). Everything below was verified in this repository, by a test in `test/` or by evidence in `docs/evidence/` and the commit history. Numbers come from those sources and name the commit that measured them.

## Architecture

```
spacebar.app (md.spacebar)                        SwiftUI settings app; spacebar-md://settings/<tab>
└─ PlugIns/SpacebarPreview.appex (md.spacebar.preview)
   │  sandboxed, view-based QLPreviewingController; one WKWebView per extension process, reused across previews
   │  spacebar://bundle/…  Preview/web (index.html, app.js, vendored markdown-it, KaTeX, highlight.js, mermaid, DOMPurify)
   │  spacebar://file/…    images beside the document (absolute-path read-only exception)
   └─ XPCServices/md.spacebar.preview.writer.xpc   unsandboxed XPC service (SpacebarWriter)
        write      compare-and-swap writes to the previewed Markdown file
        open       links and "Open in editor" (NSWorkspace is a no-op inside the sandboxed extension)
        beginEdit  owns the hidden, non-activating key panel used for inline editing
        updateSettings / ensureSupportDir / openSettings   panel setting patches (Settings.panelKeys only)
└─ PlugIns/SpacebarFolders.appex (md.spacebar.preview.folders)   same binary; claims folders; own writer copy
```

Settings live in `~/Library/Application Support/spacebar/` (real home via getpwuid): `settings.json`, `custom.css`,
`themes/*.css`, served to the page as `spacebar://user/...`. The folder was `spacebar.md/` before the rename: the app or a
writer moves it once when only the old one exists (the new one wins when both do), and until then the extension reads the
old one in place. `Shared/Settings.swift` loads tolerantly and merges updates atomically under a lock; the extension
watches the folder and applies changes live (`sb.applySettings`), and a document-start script themes the first paint.

Swift calls into the page through `window.sb`, and the page calls back through the `sb` message handler. Only the containing extension can reach the writer.

## Verified capabilities

| Capability | How | Evidence |
|---|---|---|
| Render | markdown-it + KaTeX (texmath) + highlight.js; mermaid loads lazily, and the panel shows at first paint, before mermaid (4287dc1) | `docs/evidence/0-finder-spacebar.png`, `docs/evidence/themes/`; `test/webcheck.py` |
| Live reload | DispatchSource watch that re-arms across atomic saves, 15 ms debounce; covers append, temp+rename and rename-away saves | `test/livereload.py` |
| Images and links | Relative images load via `<base href="spacebar://file/<dir>/">`. Markdown links inside the previewed folder open in the panel; others go through the link policy to the default app | `test/webcheck.py`, `test/linkpolicy/run.sh` |
| Folder mode (opt-in) | The folders extension claims `public.folder`/`public.directory`; it is enabled only while `folderMode` is on and declines otherwise. Ships; verified by hand in Finder | `docs/evidence/themes/settings-folders.png`; `test/folders.py` (Quick Look) |
| Task toggles | The checkbox sends its line and text; Swift re-locates the line and the writer saves it with compare-and-swap | 2338549; `test/corpus.py` |
| Inline editing | See the next section | 068d11d, e1396e9, a742ad8, 4bfa7d6, f2c81fb, bbc51b2 |
| Double-click fix | See below | a742ad8; `test/dblclick.py` |
| Themes and settings | Six built-in themes (light/dark), user themes and custom.css, live switching, Aa popover, front matter, TOC, stats | `docs/evidence/themes/`; `test/webthemes.py` (offscreen page); `test/settings_live.py` (Quick Look) |
| Contrast | Every built-in theme, light and dark, is WCAG AA: text, `--muted`, quotes and links on the page, every code token on `--hl-bg` and `--code-bg` (diff lines on their tint), toolbar and popover grey text. Apple's link clamps the system accent's lightness (relative colour), so every accent colour passes | `test/webthemes.py` measures each pair from the page's resolved colours, composited on a canvas (bf9dc93) |
| Mermaid through edits | Every redraw renders its new diagram nodes, so diagrams outside the edited block are never left as source | `test/webthemes.py` (bf9dc93) |
| Remote images | Off by default. A blocked image's placeholder has "Load images from the web": that document, this preview, not saved | `test/remoteimages.py` (da63068) |

## Inline editing through the writer's key panel

Quick Look extensions never receive key events: Finder and qlmanage keep them, and a window the extension creates never becomes key.

The unsandboxed writer can own a real window. A click on a block asks it for an invisible, click-through `.nonactivatingPanel` NSPanel over that block. The panel takes the keyboard without activating the app, so Finder stays frontmost and the Quick Look window stays open. An NSTextView in the panel edits the block's Markdown and streams text and selection back over XPC. The page draws the source and caret in place, and every change is saved.

- **Saves:** each save names the bytes it expects on disk. A mismatch is a conflict, and the external change wins. Writes go in place through one file descriptor, so the inode stays the same. If a write fails, the writer restores the old bytes or keeps the text in a `.spacebar-unsaved-` copy (`test/cas/run.sh`).
- **Keys:** Enter ends the block like Notion. Lists and quotes continue; code, math and HTML blocks get a line break. Backspace at the start of a block merges it upward. Keys typed during a split or merge are held and replayed. Emptied blocks are removed. The panel has no main menu, so Command shortcuts are mapped by hand: Cmd+A/C/X/V/Z/Shift+Z, and Cmd+arrows, Cmd+Shift+arrows, Cmd+Backspace and Cmd+Delete to the standard line and document moves (`test/editkeys/run.sh`).
- **Ending an edit:** Esc, clicking outside, the panel losing key, any app activation, a change on disk, or the preview closing.

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
   - No inline scripts or handlers, frames, objects, forms or connections.
   - Images only from `spacebar:`, `https:` and `data:`.
2. **DOMPurify** sanitizes the whole document before it reaches the DOM.
   - Inline styles are dropped, except table alignment.
   - KaTeX renders after sanitizing.
   - Mermaid runs in strict mode without HTML labels.
   - Link overlays can't take clicks outside their own text.
3. **Swift message gate**
   - Only messages from the main frame of `spacebar://bundle` are accepted, and every field is type- and size-checked.
   - Toggles and edits apply only to the previewed file.
   - `open` is limited to files in the folder sidebar.
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
6. **Settings:** the page may post only `setting` for `Settings.panelKeys` (theme, appearance, fontSize, width, bodyFont),
   sanitized in the extension and again in the writer, and `openSettings` for an allow-listed tab. CSS paths, the editor app and
   what is rendered can be set only in the app or settings.json. The `user` host serves only `custom.css` and
   `themes/<plain name>.css`, regular files, no symlinks. Click-safety CSS rules are `!important` inside cascade layers, so no
   unlayered CSS overrides them.
7. **Writer:** writes only to existing Markdown regular files (checked on both the path and the symlink target), at most 64 MB.

Tests: `test/webcheck.py` (10/10), `test/linkpolicy/run.sh` (44/44), `test/remoteimages.py` (19/19), `test/hostile.py` (runs the hostile fixtures through Quick Look). The two-round adversarial review's findings are fixed in 1c207e0.

## Platform findings

- **Which extension wins for Markdown depends on the bundle ID.** With QLMarkdown installed, Quick Look chose `com.patebryant.mdpeek.preview` and `zz.spacebar.preview` over QLMarkdown, but chose QLMarkdown over `md.spacebar.preview`. The name, signing identity and a pluginkit `use` did not change this. Tests use `qlmanage -c md.spacebar.qlmanage -p`, a content type only this extension claims.
- **`net.daringfireball.markdown` is not a system type.** On this Mac Xcode and QLMarkdown declare it; on a clean Mac nothing
  may. The app now imports it (10ceb35). With Xcode's declaration present, Xcode's stays active and ours registers
  `inactive imported untrusted`, so here `.mkd`/`.mkdn` still resolve to dynamic types; `.md`, `.markdown` and `.mdown` resolve to
  the type. That ours becomes active on a Mac without Xcode, and whether "untrusted" clears after the app's first launch, is
  not verified. `public.markdown` is not declared by macOS 15.4 either; the extension claims it anyway, harmlessly.
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
colours and ui-serif in the appex, V3 the folder watch under the read-only exception, V6 what Quick Look shows after a folder
decline, V7 the settings window coming forward over the panel.
