# spacebar

Press Space. See everything. Space in Finder shows folders, documents, code and data: Markdown rendered properly (headings,
tables, task lists, code highlighting, math and Mermaid diagrams, in six themes), highlighted source, JSON, logs, archives
and files with no extension. Press Space on a folder and browse it. The sidebar is a file browser for the folder: its
subfolders open in place, and a click shows any file in the panel, so you can read the Markdown, images, PDFs, rich text,
HTML, video, code, JSON, CSV and archives beside a document without leaving Quick Look. While it shows, the arrow keys
move through the tree and open each file in spacebar; type in its filter to narrow it by name. Drag its edge to resize it; its button collapses it, and every
preview remembers both. Click a block of Markdown to edit it in place, or tick a task box, and the file is saved; code, text,
JSON, CSV and config files edit in place the same way. Obsidian
vaults read as they do in Obsidian: `[[wikilinks]]`, `![[embeds]]`, callouts and tags. A button at the bottom right copies a file's text; the toolbar
finds in it (⌘F) and switches a formatted view (Markdown, JSON, a notebook, CSV, XML) to the file as it is. When a new version is out, the
preview's Aa button shows a dot and one click on Update installs it. Free and open source, for macOS 13 and later (Apple
silicon and Intel).

### What Space opens in spacebar

In Finder, Space opens spacebar for Markdown, folders, code and scripts, JSON, YAML, XML, TOML, property lists, logs,
archives, disk images (`.dmg`), and files with no extension (a `Dockerfile`, a `CHANGELOG`, a dotfile). The full list is
[`scripts/quicklook-types.txt`](scripts/quicklook-types.txt).

Unless you turn on [**Use spacebar for every file**](#use-spacebar-for-every-file), plain text, rich text, HTML, CSV, PDF,
images, video and audio keep Apple's own preview in Finder: Quick Look never hands a file of those types to another app's
extension, so spacebar cannot take them. Inside spacebar's sidebar every one of them opens, as the table below shows. Another installed app that claims one of spacebar's types (a Markdown or code previewer)
may still win it: `install.sh` lists the ones it finds and how many of spacebar's types each claims, and Settings lists each one that is on
with a Turn Off button.

What the panel shows for each file in the sidebar, and, with **Use spacebar for every file** on, for each file you press
Space on in Finder:

| File | Shown as |
|---|---|
| Markdown (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`) | rendered, with inline editing and task toggles; Raw shows its source, read only |
| Images (`.png`, `.jpg`, `.gif`, `.webp`, `.bmp`, `.ico`, `.svg`) | fitted to the panel, its dimensions and zoom in the toolbar; a double-click or a two-finger double tap toggles fitted and actual size, a pinch zooms about the pointer, two fingers or a drag move it, ⌘+ ⌘− ⌘0 zoom and fit; SVG as an image only |
| HEIC, AVIF, TIFF, camera RAW (`.dng`, `.cr2`, `.cr3`, `.nef`, `.arw`, `.orf`, `.raf`, `.rw2`), Photoshop (`.psd`), OpenEXR, TGA, JPEG 2000, icons (`.icns`) | decoded by macOS's own ImageIO and drawn natively in the panel, turned as the camera recorded it, with the same fit, zoom and pan |
| PDF | drawn natively by PDFKit in the panel, fitted to its width, pages in one scroll |
| HTML (`.html`, `.htm`) | rendered in its own web view: with its scripts and web content unless it was marked as downloaded, with neither when it was (see below) |
| Video (`.mp4`, `.m4v`, `.mov`, `.3gp`, `.mpg`, `.mpeg`, `.m2v`) | played by AVKit in the panel, paused on its first frame until you press play |
| Audio (`.mp3`, `.m4a`, `.m4b`, `.aac`, `.wav`, `.aif`, `.aiff`, `.flac`, `.caf`, `.amr`) | the same player, under the file's artwork or icon |
| Code and config (`.js`, `.ts`, `.tsx`, `.py`, `.rb`, `.go`, `.rs`, `.swift`, `.sh`, `.c`, `.java`, `.kt`, `.css`, `.xml`, `.yaml`, `.toml`, `.sql`, `.plist`, `Makefile` and more) | highlighted source with line numbers, edited in place with a click; a binary property list is shown as XML (not editable). XML and property lists are indented, and a minified stylesheet is laid out a declaration to a line, with Raw for the file as is, where a click edits it. A language with no bundled grammar (`Dockerfile`, `.ps1`, `.bat`, Dart, Scala, Elixir, Haskell, Zig and others) is plain text with line numbers |
| Archives (`.zip`, `.tar`, `.tgz`, `.tar.gz`, `.tar.bz2`, `.tbz`, `.tar.xz`, `.txz`, `.7z`, `.rar`, `.zst`, `.tzst`) | its files and folders as a tree, with sizes and dates, listed without extracting anything; Open with its default app |
| JSON (and `.jsonc`, `.json5`, comments and trailing commas allowed) | a tree, with Expand All and Collapse All; a Jupyter notebook as its cells. Raw shows the file as is, and a click edits it, with a quiet warning while it is not valid JSON |
| CSV and TSV | a table, first row as the header, up to 50,000 rows and 200 columns; Raw shows its text, and a click edits it |
| Text (`.txt`, `.log`, `.conf`, `.env`, `LICENSE`, `.env.example`, `.strings`, `.pbxproj` and any other file macOS declares as text) | as is, with line numbers; text of a kind spacebar edits (not `.strings` or `.pbxproj`) is edited in place with a click. Text need not be UTF-8: a byte order mark (UTF-8, UTF-16, UTF-32), UTF-16 without one, and legacy encodings (Windows-1252, Latin-1, Shift JIS, GB 18030, EUC-KR, Big5, Windows-1251 and others) are detected, and the kind line names the encoding |
| Rich text (`.rtf`, `.rtfd`) | drawn by AppKit's own text view, fonts, colours, tables and pictures as the document has them (mapped for a dark theme, as TextEdit does); never as RTF source |
| Office, iWork, fonts, 3D, certificates, calendars, e-books and other files macOS previews (`.docx`, `.xlsx`, `.pptx`, `.pages`, `.numbers`, `.key`, `.ttf`, `.otf`, `.usdz`, `.obj`, `.stl`, `.glb`, `.cer`, `.crt`, `.p12`, `.ics`, `.epub` and any other type macOS declares, is not text, and spacebar has no view of its own for) | Apple's own Quick Look preview, inside the panel; the file's text, or the info card, when Quick Look cannot show it. A contact card (`.vcf`) is shown as its text: Apple's preview of it would read your Contacts |
| Disk images (`.dmg`) | the info card, with the image's format and whether it is encrypted, read from the file without mounting it |
| Anything else | an info card: Finder's large thumbnail when there is one, kind, size, date modified and the folder it is in; the toolbar's Open opens it in its default app (Reveal in Finder for apps and executables) |

The Open button in the toolbar opens Markdown in your editor (Settings: **Open files in**). Code, JSON, CSV and text
open there too. The button always says just "Open" (or "Reveal" where only Finder may show the file), so it stays in place as
you move from file to file; its tooltip names the app, such as "Open in Visual Studio Code". A script (`.sh`, `.py`, a `.command`) opens in the editor as text and is never run; with
**Default App** chosen it opens in your default text editor, never in Terminal or an interpreter. Files that often hold
secrets (`.env`, `.npmrc`) are shown but never offered to another app; a `.env` can be edited in place.

Text over 2 MB shows its first 2 MB; a CSV or TSV table reads up to 16 MB, and one over 2 MB is shown but not edited. WebM,
Matroska, Ogg, Opus and AVI files, which macOS cannot play, get the info card and a note saying so. A link that loops or leads
nowhere is listed greyed in the sidebar, and Space on one says it can't be opened. An archive lists its first 5,000 entries. Images over 50 MB, and PDFs, video and audio over 512 MB, get the info card.

**Editing.** With **Edit text in the preview** on (the default; Settings, Advanced; one setting for everything), a click on the text of
Markdown, code, text, JSON, CSV or TSV, YAML, TOML, XML, an INI or `.conf` file, or dotfile config (`.env`, `.env.local`,
`.gitignore`) puts the caret there, and every change is saved as you type. Markdown is edited a block at a time;
other files as a whole, highlighted as you type (plain while you type in files over 24 KB, highlighted again when the edit
ends). A file is saved in the encoding and with the byte order mark it was read with, and keeps its CRLF or LF line endings
and its last newline; a character the encoding cannot hold is not saved (the preview says which), and nothing is ever
converted to UTF-8. Files over 2 MB, shown cut, a binary property list, text read with invalid bytes, and anything spacebar
does not show as text are never editable, and nor are files the shell, git, npm or launchd run on their own (shell profiles
such as `.zshrc`, `.gitconfig`, `.npmrc`, `.command` scripts, git hooks, LaunchAgents). A change on disk while you edit ends
the edit, and the file's own text wins.

The preview sits in a thin outlined page under a toolbar row: the sidebar button and the path on the left, Aa and Open on the
right, and beside them, in quiet text, the file's kind and size (an image's zoom too), so a PDF or an image fills the page
under the row. Word count and reading time are off unless `stats` is on in settings.json; with them on, a Markdown
file shows its words and a code file its lines there too. `minimalChrome` in settings.json goes back to floating
buttons over the page.

### Copy, Find and Raw

Copy sits at the bottom right of the page; Find and Raw are icon buttons beside Aa, each shown where it applies and keeping its
place in the toolbar where it does not. A button with a key gives it in its tooltip.

- **Copy** puts the file's text on the clipboard: a Markdown file's source, a table's CSV, JSON as it is on disk (the first
  2 MB of a larger file, as shown). Not offered for images, PDFs, media or archives. The page keeps clear of it, so it never
  covers a line, and "Copied" is announced to VoiceOver.
- **Find** searches the file on screen: Markdown, code, text, JSON and CSV, as each is shown. Matches are highlighted and
  counted; ↵ and ⇧↵ (or ⌘G and ⇧⌘G) go to the next and previous, Esc closes the bar. A long table and a JSON tree are
  searched whole, not just the rows drawn: a match in a collapsed branch opens it. At most 10,000 matches are counted.
- **Raw** switches a formatted view to the file as it is: Markdown to its source (read only), JSON and a notebook to their
  text, a table to its CSV, XML and a minified stylesheet to the file unindented. Each kind remembers its choice.
  Minified JavaScript is shown as it is: there is no formatter for it.

### Keys

Quick Look gives a preview no keys of its own. There these work while spacebar holds the keys: its sidebar list takes them as
a preview opens (`sidebarKeys` in settings.json), and the filter and find fields hold them while
you type. In the Space helper's panel (**Use spacebar for every file**, below) they always work. The buttons work in both.

| Key | Does |
|---|---|
| ⌘F | Find in the file |
| ⌥⌘F | The sidebar's filter (a click in the field works too) |
| ↵, ⇧↵, ⌘G, ⇧⌘G | In the find field: the next and previous match |
| Esc | Closes the find bar, clears the filter, or gives the keys back |
| ⌘C | Copies the selection, or with nothing selected the whole file's text. In the Space helper's panel it copies the file too, as Finder's ⌘C does: paste in Finder for the file, in an editor for the text (an image, a PDF or another file: the file) |
| ↑ ↓ ← → Home End ↵ | Move through the sidebar |
| ⌘O | Open, in the Space helper's panel |
| ⌘+ ⌘− ⌘0 | Zoom |

### Use spacebar for every file

Quick Look hands spacebar only the types above. Turn on **Use spacebar for every file in Finder** (Settings, or the
second step of the welcome sheet) and Space in Finder opens spacebar for any file you select, in the same panel with the same
sidebar:

| You press Space in Finder on | Without it | With it |
|---|---|---|
| Markdown, folders, code, JSON, YAML, XML, logs, archives, `.dmg`, files with no extension | spacebar, inside Quick Look | spacebar's own panel |
| Plain text, CSV, HTML, rich text (`.rtf`) | Apple's preview | spacebar's panel (HTML with its scripts off) |
| PDF, images (HEIC and camera RAW too), video, audio | Apple's preview | spacebar's panel |
| Office, iWork saved as a single file, fonts, 3D, certificates, calendars, e-books | Apple's preview | Apple's preview, inside spacebar's panel |
| Installers and binaries as single files (`.pkg`, `.mpkg`, `.exe`, `.dylib`) | Apple's preview | spacebar's info card |
| Apps and other packages, iWork documents saved as packages, `.rtfd` packages | Apple's preview | Apple's preview: spacebar declines them and hands the Space back to Finder |
| Several files at once | Quick Look, one at a time | spacebar's panel, with a sidebar of just those files |

With it on:

- Space, Esc, ⌘W or ⌘. close the panel in one press.
- The panel opens where you last moved or resized it on that display, fitted to the screen if the display has changed.
- While it is open the arrow keys move through spacebar's sidebar, or, with `sidebarKeys` off in
  settings.json, through Finder's selection, and the panel follows.
- Like Apple's Quick Look, it hides while another app is in front and comes back when you return to Finder, a PDF at its page
  and a video at its time.
- Space in a rename or the search field, with Apple's Quick Look already open, or in any other app is left alone. ⌘Y still
  opens Apple's Quick Look. A Space spacebar cannot answer within 150 ms is handed back to Finder.
- While a password field or another app has secure input on, macOS gives spacebar no keys, so Space opens Apple's Quick Look;
  Settings says so.

#### What it asks macOS for

It works through a small helper app inside spacebar, which macOS lists as **spacebar Helper**. Turning the setting on asks
for two things:

- **Accessibility** (System Settings, Privacy & Security, Accessibility: turn on **spacebar Helper**). This lets the helper
  notice a Space pressed in Finder and read which files are selected. It sees your key presses while it runs, but acts only
  on a plain Space in Finder and, while spacebar's panel is open, on the keys that drive it (Esc, the arrows, Home, End, Page
  Up and Down, Return, ⌘W, ⌘., ⌘O, ⌘F, ⌥⌘F, ⌘C and zoom). It never records what you type, and no character you type leaves it: it
  tells the panel only a key's name, such as "down".
- **Running in the background** (System Settings, General, Login Items & Extensions: **spacebar**, under Allow in the
  Background). macOS starts the helper at login and keeps it running.

The helper never opens a file. A separate viewer does, sandboxed like the Quick Look extension, and the first time it shows a
file in Documents, Desktop, Downloads or iCloud Drive macOS may ask whether **spacebar** may access that folder. Settings
shows whether the helper is on, waiting for Accessibility, blocked in Login Items, or paused by secure input. While
the setting is on but the helper is not taking Space (Accessibility off, or not running), the first Quick Look preview that spacebar draws says so in one quiet
line, once: "Space helper is off: open spacebar Settings" (a click opens Settings).
[SECURITY.md](SECURITY.md#the-space-helper) has how the privileges are split.

#### Turning it off

Turn off **Use spacebar for every file in Finder** in Settings. The helper stops and leaves Login Items, and Space
in Finder is Quick Look's again. Its Accessibility entry stays, unused, until you remove it in System Settings or
[uninstall](#uninstall) spacebar, which removes it for you.

### Folders and Obsidian vaults

Press Space on any folder. It opens on:

1. its README;
2. else its first Markdown file;
3. else the Markdown file a quick look through its subfolders finds: the nearest the top, then one named like `index` or
   `Home`, then the newest. It looks at most 3 folders deep and 5,000 items, for at most a quarter of a second, and never inside
   hidden folders, `node_modules` or packages;
4. else an overview of the folder: how many folders, notes, images, PDFs and other files it holds, and the files changed most
   recently, each a click away.

App bundles and other packages, the top of a volume and system folders (`/System`, `/Library`, `/usr` and the like, and
`~/Library`) keep Quick Look's usual preview. Click the folder's name at the top of the sidebar to see its overview again.
Folder previews are on by default; `"folderMode": false` in settings.json turns them off.

The sidebar lists a folder as Finder does: by name, folders among the files, unless Finder's own **Keep folders on top**
(Finder › Settings › Advanced) is on, and hidden files while Finder shows them (⇧⌘.). The sidebar's sort menu can sort by date
modified instead and keep folders first whatever Finder does; `"folderReadmeFirst": true` in settings.json puts a README
at the top.

While the sidebar shows, it takes the arrow keys as soon as the preview opens, so they move through spacebar's list rather
than Finder's selection: ↑ and ↓ move through the files and open each one in spacebar (a CSV or an image too, which Quick
Look would otherwise show in its own previewer), → and ← open and close folders, Home and End jump to the ends and Return
opens the file or folder under the cursor. Esc or Space gives the keys back to Quick Look without closing the preview (the
preview cannot close Quick Look), and the preview says so: press Space or Esc again to close it. A click in the document
gives them back too, and a click on a row takes them again. With the sidebar collapsed, or `sidebarKeys` off in
settings.json, the arrows stay with Finder and Space closes the preview at once. Click the filter field
at the top and type to narrow the tree to names that match (letters in order, so `rdme` finds `README.md`); ↑, ↓, Home, End
and Return still work while you type, and Esc clears the field, then goes back to the list.

In a vault (a folder with `.obsidian` in it), and in any other folder:

- `[[Note]]`, `[[Note|alias]]`, `[[folder/Note]]` and `[[Note#Heading]]` open that note in the panel. A name is looked for
  anywhere under the folder the sidebar shows; a link that matches nothing is greyed out.
- `![[image.png]]` (`![[image.png|300]]` for a width) shows the image; `![[Note]]` shows the note inline, read only, one level
  deep.
- `> [!note] Title` callouts (note, tip, warning, danger, example, quote and the rest) are drawn as boxes, and `#tags` as pills.
- A note you press Space on inside a vault shows the whole vault in the sidebar, so its links reach every note.
- `.obsidian` is hidden, like every hidden file, unless Finder shows hidden files or you turn them on in Settings › Advanced.

[spacebar.patebryant.com](https://spacebar.patebryant.com)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/evidence/themes/theme-github-dark.png">
  <img alt="A Markdown file in spacebar's Quick Look preview: math, highlighted code, a Mermaid diagram and a task list" src="docs/evidence/themes/theme-github-light.png" width="720">
</picture>

### Settings

Open spacebar to change its settings. The window holds only what most people change:

- **Appearance**: the theme, Automatic, Light or Dark, and the text size. The preview's Aa button changes these too, with the
  font and page width.
- **Use spacebar for every file in Finder**, and whether the helper is running.
- **Open files in**: the editor the preview's Open button uses.
- **Check for updates**, **Report a Problem…** and **Uninstall spacebar…**.

Anything wrong with the setup (spacebar turned off in Quick Look, another app's previewer claiming its types, folder previews
off in System Settings, an unreadable settings file) shows at the top while it is wrong.

**Advanced**, closed until you open it, holds scripts in HTML files, HTML in Markdown and remote images; editing in the
preview and checking off tasks; hidden files in the sidebar; a custom theme and `custom.css`; and the settings file with
**Reset to Defaults…**, which puts every key back, including the ones below, and leaves **Use spacebar for every file** as it is.

Everything else is a key in `~/Library/Application Support/spacebar/settings.json`, which takes effect as soon as it is saved.
spacebar keeps the file's `"version"` up to date; in a file you write yourself or link from elsewhere, set `"version": 5`, or
an older version's defaults are applied to it (`stats` and `folderReadmeFirst` are read as off):

| Key | Default | Values |
|---|---|---|
| `bodyFont` | `"system"` | `"serif"`, `"rounded"`, `"mono"`; also in the Aa button |
| `width` | `"medium"` | `"narrow"`, `"wide"`, `"full"`; also in the Aa button |
| `monoFont` | `"system"` | `"menlo"`, `"monaco"`, `"courier"` |
| `lineHeight` | `1.6` | 1.2 to 2.0 |
| `codeTheme` | `"auto"` (match the theme) | `"apple"`, `"github"`, `"paper"`, `"solarized"`, `"nord"`, `"contrast"` |
| `minimalChrome` | `false` | floating buttons instead of the toolbar row |
| `stats` | `false` | word count and reading time |
| `toc` | `"auto"` | `"on"`, `"off"` |
| `frontMatter` | `"table"` | `"hide"`, `"raw"` |
| `math`, `mermaid` | `true` | |
| `mdLinks` | `"preview"` | `"editor"` opens Markdown links in your editor |
| `folderMode` | `true` | folder previews |
| `foldersFirst` | `"finder"` (Finder's own setting) | `"always"`, `"never"`; also in the sidebar's sort menu |
| `folderReadmeFirst` | `false` | a README at the top of the sidebar |
| `sidebarKeys` | `true` | the sidebar takes the arrow keys as a preview opens |

## Install

```sh
curl -fsSL https://spacebar.patebryant.com/install.sh | sh
```

Then select a file or folder in Finder and press Space.

<!-- gatekeeper: the release notes copy this paragraph (.github/workflows/release.yml) -->
spacebar is **not notarized**: there is no Apple Developer ID behind it yet. Use the install command; a browser download
of the zip will be blocked by Gatekeeper. Files that curl downloads are not quarantined, so Gatekeeper does not stop the app,
but it also means you are trusting this repository's build rather than Apple's check.
<!-- /gatekeeper -->
Read [`scripts/install.sh`](scripts/install.sh) before you run it. It:

1. checks for macOS 13 or later;
2. downloads `spacebar.zip` and `spacebar.zip.sha256` from the latest release (or `SPACEBAR_VERSION=vX.Y.Z`) through
   `github.com/patebry/spacebar/releases/latest/download/`, with no GitHub API calls, and stops unless the SHA-256 matches;
3. copies the new app into `~/Applications` beside the old one (no `sudo`);
4. if `~/Applications/spacebar.app` exists, quits it and its Quick Look extensions (the helpers that save edits first, so a
   save in flight finishes), unregisters them, moves it aside, moves the new copy into its place, quits the Space helper's
   viewer the same way, and only then deletes the old one (it is put back if the move fails). Nothing else is deleted;
5. registers it with `lsregister` and `pluginkit`, turns the preview on, turns folder previews on unless you turned them off,
   and resets Quick Look (`qlmanage -r`). If the Space helper is registered, it registers it again in the background, which
   takes about 15 seconds (macOS refuses a replaced helper until then; it retries for up to 10 minutes), logged to
   `~/Library/Logs/spacebar-helper.log`. Opening spacebar's settings does the same when the helper is not answering;
6. lists other Quick Look extensions that are turned on and claim file types spacebar previews (QLMarkdown for Markdown,
   a syntax highlighter for code), with how many of spacebar's types each claims by kind, says how to turn them off, and warns
   if another copy of spacebar is in `/Applications`. It never turns off or deletes anything itself.

`install.sh --help` lists its options, including `--dry-run`, which downloads and verifies but changes nothing.

### Updates

Once a day spacebar asks GitHub for the latest release's version number, and nothing else (turn this off in Settings:
**Check for updates**). A newer version shows as a dot on the preview's Aa button; its **Update** button runs the app's own sealed copy of
`install.sh` for that version, which downloads and checks the release exactly as above. Quick Look shows an error for a moment
while the installer replaces the extension; press Space again after. An edit in progress is saved first, and no edit, task
toggle or sidebar filter starts while the update runs. The installer's output goes to `~/Library/Logs/spacebar-update.log`.

The release zip is built by [GitHub Actions](.github/workflows/release.yml) from the tagged commit. Releases after v0.1.0
are signed with a self-signed "spacebar Release" certificate, so every release has the same signer and an update does not
make macOS ask again about the extension's data ([why](FINDINGS.md#release-signing)). v0.1.0 was ad-hoc signed, so the first
update from it may show one prompt. Those releases also carry a build provenance attestation, which the
[GitHub CLI](https://cli.github.com) checks:

```sh
gh attestation verify spacebar.zip -R patebry/spacebar
```

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/patebry/spacebar/main/scripts/uninstall.sh | sh
```

This stops the Space helper (its launchd agent, then the helper, the viewer and the viewer's writer), resets the
Accessibility permission the helper had and every permission the viewer had, unregisters spacebar's Quick Look extensions and
deletes `~/Applications/spacebar.app`, which takes its Login Items entry with it. **Uninstall spacebar…** in Settings runs the same
script from inside the app (not while an update runs), after removing the helper from Login Items. Both quit spacebar's
Quick Look extensions first. To also delete your settings and themes in `~/Library/Application Support/spacebar` and the
helper's log in `~/Library/Logs`:

```sh
curl -fsSL https://raw.githubusercontent.com/patebry/spacebar/main/scripts/uninstall.sh | sh -s -- --purge
```

macOS asks before one app deletes another's sandbox container, so the uninstaller lists the containers spacebar leaves in
`~/Library/Containers` (`md.spacebar.preview`, `md.spacebar.preview.folders`, `md.spacebar.viewer`) for you to delete in
Finder.

## Build from source

Requirements: macOS 13+ and the Xcode command-line tools (`xcode-select --install`); the full Xcode app is not needed.

```sh
git clone https://github.com/patebry/spacebar.git
cd spacebar
./build.sh              # build, sign, install to ~/Applications and register
./build.sh --no-install # build into build/spacebar.app only
```

`build.sh` signs with the identity named in an untracked `.sign-id` file, else the first code-signing identity in your
keychain, else ad-hoc (`SIGN_ID=-` forces ad-hoc). A stable identity keeps macOS from asking again about the extension's
sandbox container after each rebuild. Other options are documented at the top of the script.

Tests that run off screen, without Quick Look (the test builds target Apple silicon):

```sh
for t in settings scheme linkpolicy cas dataless editkeys filterkeys pdfpane htmlpane mediapane qlpane imagepane diskimage richtext encoding archive claims rivals updates report welcome helper helperlink viewerlatency bigfiles; do test/$t/run.sh; done
python3 test/webcheck.py && python3 test/webthemes.py && python3 test/remoteimages.py && python3 test/sidebar.py
```

The other scripts in `test/` drive real Quick Look windows and synthetic input; run them on a machine you are not using.
`test/helper_live.command` is a checklist for the Space helper in Finder: you press the keys, and it grades each step from
the helper's and viewer's logs. It sends no input itself.

## How it works

```
spacebar.app                         settings window (SwiftUI)
└─ PlugIns/SpacebarPreview.appex     sandboxed Quick Look preview: WKWebView + markdown-it, KaTeX, highlight.js,
   │                                 Mermaid, DOMPurify, all bundled; no network code of its own
   └─ XPCServices/…writer.xpc        small unsandboxed helper: saves edits, opens links and files, owns the key panel for
                                     inline editing and the sidebar's keys, lists archives, checks for and starts updates
└─ PlugIns/SpacebarFolders.appex     the same preview for folders (on by default; turn off in Settings)
└─ Helpers/spacebar Helper.app       "Use spacebar for every file": a launchd agent with Accessibility and an event tap; reads
   │                                 Finder's selection, never a file; no sandbox, no entitlements
└─ Helpers/spacebar Viewer.app       the panel it opens: the same preview code, sandboxed like the extension, with its own writer
```

Quick Look extensions never receive key events, so inline editing (Markdown and text files alike) uses a click-through,
non-activating panel owned by the writer service; Finder stays in front. Saves are compare-and-swap: if the file changed on
disk, the external change wins.
[FINDINGS.md](FINDINGS.md) has the details and measurements.

## Privacy and security

- No analytics, telemetry or accounts. The one request spacebar makes on its own is the daily update check: GitHub's latest
  release, of which only the version number is read (off in Settings). **Report a Problem** (Settings)
  opens a new GitHub issue in your browser with your versions, Mac model and the end of the update log filled in; nothing is
  sent unless you submit it there. Settings are a JSON file in `~/Library/Application Support/spacebar`.
- Remote images are off by default (fetching one tells its server when you opened the document). A blocked image offers a
  one-time load for that document.
- A Markdown file is treated as hostile. The page runs under a strict Content Security Policy (bundled scripts only, no
  inline scripts, frames, forms or connections), and DOMPurify sanitizes everything before it reaches the page.
- The writer only writes to the file on screen, and only to a type spacebar edits (Markdown, code, text, JSON, CSV, dotfile
  config), never to a binary, a binary property list, text over 2 MB or a file it shows cut, and into anything but Markdown
  only what was typed in its own key panel; it only opens http(s) links or non-executable documents, and only accepts
  messages from the extension's own page. Apps and executables in the sidebar can only be revealed in Finder; a script
  shown as text opens only in a text editor (an app that declares the Editor role for text, never a terminal, browser or script
  runner), where it is not run.
- The file browser never leaves the previewed folder: links that lead out of it are not listed, a file or folder the page asks
  for must be one the sidebar listed and must still resolve inside the folder, and hidden files are left out unless you turn
  them on. A wikilink or embed resolves only to a file found inside the folder the sidebar shows; `..`, absolute paths and links
  that lead out of it resolve to nothing. Nothing in a Markdown file is ever run, and scripts are shown as source, SVG only
  as an image, a PDF by PDFKit (which runs no PDF scripts; the PDF is parsed in the sandboxed preview extension itself), and
  the page loads files only as images.
- An HTML file is shown in a web view of its own that shares nothing with the preview's page. By default its scripts run and
  it may load from the web, unless your browser, Mail or AirDrop marked it as downloaded (the quarantine flag). Files from
  `git clone`, `curl`, `unzip` or a USB drive are not marked, so their pages run their scripts and may load from the web too;
  **Settings, Advanced, Scripts in HTML files: Never** turns that off for every HTML file. A marked file always opens with
  scripts off and no network at all, resource hints included, and only files beside it load. A link in an HTML file is
  followed only when you click it, through the same policy as everywhere else.
- An archive is listed, never extracted, by `/usr/bin/bsdtar` under a `sandbox-exec` profile that lets it read only the
  archive (through a descriptor the helper opened) and system files, with no writes and no network, for at most 5 seconds.
  Only the viewer's Open button hands an archive to its default app; a link never does.
- The preview extension has a read-only sandbox exception for the whole disk, so relative images beside a document load and
  the sidebar can show the folder's files.
- The Space helper, when you turn it on, has Accessibility and sees every key event, so it is kept small: it acts only on
  Space in Finder and on the panel's own keys while the panel is open, forwards only a fixed list of key names (never a
  character), never opens a file, and talks only to the viewer and the settings app signed by the same certificate, under the
  hardened runtime. The viewer that renders files is sandboxed like the preview extension and never sees a key the helper
  did not send it.
- The preview extension has the `com.apple.security.network.client` entitlement. WKWebView's helper processes crash-loop
  in a sandboxed extension without it. spacebar has no network code of its own; the only requests the page can make are
  remote images, which are blocked unless you allow them.

Found a security problem? Please report it privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Contributing

Issues and pull requests are welcome. Please run the off-screen tests above before sending a change, and keep new
dependencies out of the extension unless they are vendored with their licence (see `Preview/web/vendor/VERSIONS.txt` and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).

## Licence

MIT, © 2026 Pate Bryant. See [LICENSE](LICENSE). Bundled third-party code and fonts keep their own licences, listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Not affiliated with Apple. Mac, macOS, Finder and Quick Look are trademarks of Apple Inc.
