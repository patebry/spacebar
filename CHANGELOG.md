# Changelog

Each release's notes on GitHub also list its commits. This file keeps what changed for someone using spacebar.

## Unreleased (0.4)

### Search

- **Search the text of the files** from the sidebar's filter: its new **Names / Contents** button switches it to the text of
  the Markdown, code, JSON, CSV and text files the sidebar lists, in every folder under it. Each result shows its folder, its
  match count and the matching line; opening one runs Find on it for the same text. Plain, case-insensitive text; binary,
  hidden files (unless shown) and dependency folders are skipped; each file is read to 2 MB and a search to 64 MB and
  2 seconds, and one cut short says "Searched N of M files". The search runs off the main thread and each keystroke cancels
  the last.

### Files inside archives

- **Open a file inside an archive without extracting it.** In a zip, tar, tgz, 7z or any archive spacebar lists, click a
  file, or select it with the arrow keys and press Return: text, code, Markdown, JSON, CSV and images (PNG, JPEG, GIF,
  WebP, and HEIC, AVIF and TIFF drawn natively) show in place, read-only. The breadcrumb reads `archive.zip › folder/file.md`;
  Back, the archive's name in it, or ← returns to the listing, and ↑ and ↓ move to the file before or after. Other files,
  and archives inside the archive, show their info card with size and path. Copy copies a text file's text.
- Nothing is written to disk: the writer streams the one file out of bsdtar, sandboxed as the listing is, into memory, at
  most 2 MB of text or 20 MB of an image, within 5 seconds, and stops an archive that expands more than 1,024 times its
  size.

### A grid for folders of pictures

- **A folder mostly of images and video opens on a grid of thumbnails**, as Finder's gallery does: at least six files, 60% or
  more of them pictures or movies. Its README no longer opens first. Other folders keep the overview.
- A grid and list toggle in the folder view's header, remembered separately for folders of pictures and for every other folder.
- The arrow keys move through the tiles in two directions, Home and End go to the ends, and Return or a double-click opens the
  picture. Space and Esc work as before; in the Space helper's panel the arrows drive the grid too.
- The grid shows at once with placeholders, and thumbnails fill in, the ones in view first. A folder of 5,000 pictures keeps
  only the tiles on screen in the page and makes only their thumbnails; they are made in memory and never written to disk.

### Drag out, Open With, diffs

- **Drag a file out of the Space panel.** Drag a row of the sidebar, a Contents search result, a row of a folder's overview,
  a tile of its grid, or the file's kind in the toolbar into Finder, Mail, a chat or an editor: the drop gets the file, as a
  drag from Finder does, except that Finder copies it rather than moving it. Only files the sidebar lists, the search found or
  the overview offers, and the file on screen, can be dragged; a file inside an archive is not on disk and cannot.
  This is the Space panel's; Quick Look's own window does not offer it.
- **Open With.** The chevron beside Open lists the apps that open the file, its default app first, at most 12, with their
  icons. It offers exactly what Open allows: nothing for a script, an app, an executable or a file that often holds secrets
  (`.env`, `.npmrc`); beyond the default app, never a terminal or script runner, a web browser, an office suite or an app
  outside the Applications folders, and for a text file only text editors. A per-file "Open With" choice another app saved on the file is ignored.
- **Diffs.** `.diff` and `.patch` files and Markdown `diff` fences tint each added line green and each removed line red
  across the block, dim the hunk headers (`@@ -1 +1 @@` too, with its function name), and keep file headers quiet, in every
  theme, light and dark.

### The panel and its files

- **The Space panel keeps the size and place you give it**; it no longer snaps back to 900 × 700 on every file. Its traffic
  lights are drawn in colour, the minimize button it cannot use is gone, and the window is titled after the file for
  VoiceOver and window lists.
- **A file deleted while on screen says so.** A save that replaces the file is not mistaken for a deletion, and a rename in
  the same folder is followed. A file that is really gone dims, with "moved or deleted" in a banner, and Open, Open With,
  editing, task toggles and undo stay off until it comes back. Text you had not yet saved is kept in the banner to copy.
- A file missing at open offers **Show Folder**. A file that cannot be read says why: no permission, or macOS's privacy
  protection, with an **Open Privacy Settings** button.
- **A Finder selection across folders** is listed in full under the nearest folder holding it, titled "N Selected", and the
  toolbar says where the file on screen is ("2 of 5").
- **PDFs** show their page and page count ("41 / 228"); a click goes to a page. ⌘F finds in a PDF or RTF document with the
  same find bar as text, Page Up and Page Down move through it, and ⌘C copies the text selected in it.
- **⌘+ ⌘− ⌘0 zoom** a PDF, an RTF document or an HTML file.
- **A pinch and a two-finger double tap zoom an image in the Space panel**, as they already did in Quick Look.
- The kind line gives a video's size and length, an audio file's title, artist and length, and an SVG's own size.

### Sidebar, folders and archives

- **The Names filter searches every folder**, expanded or not (the same caps and skipped folders as Contents), and a folder
  that matches shows what it holds. Names | Contents is a fixed-width segmented control; long names are cut in the middle;
  hidden files are dimmed; empty folders say so.
- **Space on a folder** opens its own README, index or Home, else its overview; it no longer opens a Markdown file found
  deeper down. List view is the folder's own files. Breadcrumb folders are clickable. A picture opened from the grid has
  Back, and ← or ⌫ return to it.
- **Archives:** PDFs inside are shown; links inside are named, never followed; a lone `.gz`, `.bz2` or `.xz` of text shows
  its text. Columns sort, folders show their size, `.DS_Store` and `__MACOSX` are hidden, and a long archive says
  "first 5,000 of N".

### Data, code and Markdown

- **CSV** is a table that fills the view. **JSON** is read up to 16 MB as a tree, and its long strings
  wrap. **Logs** (`.log`, `.out`, `.err`) over 2 MB show their newest 2 MB, with error and warning lines tinted.
- **Wrap Lines** in Aa, per kind: text and Markdown source wrap, code does not by default.
- Kind labels are spacebar's own ("TypeScript", "Plain text", "Log"). Dockerfile, nginx, Scala and Terraform are highlighted.
- **Markdown:** heading anchors and in-page `#links`, footnotes, `==highlight==`, folded callouts, wide tables that scroll;
  long tables keep their header in view, and a reason for a Mermaid diagram that fails. A code fence shows its language and a **Copy** button that copies the
  fence from the file itself. A fence waits out a double-click before it edits, so code can be selected; code, tables,
  math and diagrams are edited in the code font.
- **Toolbar:** the file name is the last thing cut at narrow widths; Raw keeps one label; Find tints "No matches"; Copy says
  "Copy source" on Markdown; the kind drags the file out of the panel.

### Editing

- **Editing shows:** "Editing · Esc to finish" and a Saved tick in the toolbar, a clearer hover, and a one-time tip the first
  time the pointer rests on editable text.
- **Undo across edits.** ⌘Z past an edit's own undo, or the toolbar's Undo, puts back the text before the last edit, split,
  merge or task toggle while the file stays open. Each undo is an ordinary checked save: neither undo nor anything else can
  put an old version back over a change made elsewhere.
- **Text a change on disk would have replaced is kept** behind a banner (Keep Mine for Markdown, Use Disk Version, Copy My
  Text) until you choose; leaving the file waits for that.
- Raw lasts while the preview is open instead of becoming a saved setting.

### Settings and first run

- The hint when Space reaches Quick Look says why: the Space helper is not running, or is paused while a named app holds
  secure input.
- "Space helper" everywhere; Settings has an About section with the version and Check Now, and a Quick Look status row.
- Welcome explains both macOS prompts and links SECURITY.md; the sample folder is `~/spacebar Sample Folder`, with a picture
  and a PDF.
- Focus rings and labels throughout for keyboard and VoiceOver users.

## 0.3.0 (unreleased)

Waits for the Developer ID: the first release with the Space helper is notarized.

### Use spacebar for every file

- **Space in Finder opens spacebar for any file**, not only the types Quick Look hands it: plain text, CSV, HTML (scripts
  off), PDF, images, video and audio open in spacebar's own panel with the same sidebar. Off until you turn it on in the
  welcome sheet or Settings.
- Space, Esc, ⌘W and ⌘. close the panel in one press; the arrow keys drive the sidebar, or Finder's selection with the
  panel following. Several selected files open with a sidebar of just those files.
- The panel hides while another app is in front and comes back with Finder, a PDF at its page and a video at its time,
  when Finder still has that file selected. A click on the Desktop, or Finder revealing another file, leaves it closed.
- The panel remembers its size and place on each display.
- A rename, the search field, ⌘Y, secure input and every other app keep their keys; a Space spacebar cannot answer in
  150 ms is handed back to Finder.
- Typing in the panel (an edit, the sidebar filter, Find) keeps every key: a space types a space instead of closing the
  panel. Esc ends the edit (in the filter, clears its text first); the next Esc or Space closes.
- It works through a small helper that needs Accessibility (listed as "spacebar Helper") and runs at login; it never opens a
  file, and a sandboxed viewer renders them. SECURITY.md has the threat model. Settings shows its state.
- Installing, updating and uninstalling handle the helper: an update brings it back within about 20 seconds, and the
  uninstaller removes it with its permissions.

### Edit text in place

- Click the text of a code, config, plain-text, JSON, CSV, YAML, TOML or XML file to edit it; each change is saved, in the
  file's own encoding. For JSON, CSV and XML, turn on **Raw** and click the text. Files over 2 MB, and files that run on their
  own (shell startup files, git hooks, LaunchAgents), are not editable.
- Enter in code keeps the line's indentation and goes one step deeper after `{`, `[` or `(`; Enter between `{}` puts the
  closing brace on a line of its own. Shift-Tab takes one step of indentation off. Typing past 2 MB says the text is not
  saved and keeps the edit open.
- In Markdown, pressing Enter again in the empty paragraph the last Enter opened adds a blank line instead of doing nothing,
  and Enter in a code block keeps the line's indentation.

### Copy, Find and Raw

- **Copy**, a button at the bottom right of the content, puts a text file's contents on the clipboard (a Markdown file's source); ⌘C copies the selection,
  or the whole file when nothing is selected. In the Space panel, ⌘C with nothing selected copies the file as well, as
  Finder's does: paste in Finder for the file, in an editor for the text. The page keeps clear of the button, and "Copied" is
  announced to VoiceOver.
- **Find** (⌘F) searches Markdown, code, text, JSON and CSV, with highlighted matches, a count, ↵ and ⇧↵ for the next and
  previous, and Esc to close. Long tables and JSON trees are searched whole. The sidebar's filter moves to ⌥⌘F.
- **Raw** shows a formatted view's file as it is: Markdown source, JSON, notebooks, CSV, XML and property lists (now indented)
  and minified stylesheets (now laid out). The choice is remembered per kind.

### Viewers

- HEIC, AVIF, TIFF, camera RAW, PSD, OpenEXR, TGA, JPEG 2000 and icons are decoded natively, with fit, zoom and pan.
- Images zoom as in Preview, in Quick Look and in the Space panel: pinch about the pointer, two fingers to pan, double-click
  or a two-finger double tap for fit and actual size, ⌘+ ⌘− ⌘0. A single click no longer zooms.
- Office, iWork, fonts, 3D, certificates, calendars and e-books show Apple's own preview inside the panel; files declared as
  text (`.strings`, `.pbxproj`, playlists, crash reports) stay in spacebar's text view.
- `.dmg` files are claimed; their card shows the format and whether the image is encrypted, without mounting it.
- Rich text is drawn natively; text in any common encoding is detected and named.
- CSV and TSV show as a sortable table of up to 50,000 rows; JSON as a tree; notebooks render.
- The native player also plays M4B, 3GP, MPEG-1/2 and AMR.
- A Markdown image that does not load shows a placeholder.

### Sidebar and settings

- **The sidebar lists a folder as Finder does**: by name, folders among the files unless Finder's own Keep folders on top
  is on, and hidden files while Finder shows them (⇧⌘.); a change in Finder shows in an open preview. The sort menu gains
  Folders First for either way whatever Finder does (`foldersFirst` in settings.json). README first is off by default and a
  settings file from before is read with it off; `"folderReadmeFirst": true` brings it back.
- Big folders stay fast (the sidebar draws only the rows in view), and it takes the arrow keys as soon as the preview opens.
- The toolbar holds still while the arrows move from file to file: its buttons keep their places, Open is one word with the
  app in its tooltip, and a button with a key gives it in its tooltip.
- The file's kind and size move from a caption row over the file into the toolbar, as quiet text; an image's zoom goes with
  them. A PDF, a video or an image gains the row's height.
- JSON has one view, the tree, with Expand All and Collapse All, in place of 0.2's pretty-printed text; Raw shows its text.
  A notebook shows as its cells (Raw for its JSON).
- The info card's Where names the folder the file is in, with `~` for your home, and its Open button gives way to the
  toolbar's (Minimal chrome keeps it).
- Word count and reading time are off by default, and a settings file from an earlier version is read with them off.
- With **Use spacebar for every file** on but the helper not taking Space (Accessibility off, or not running),
  the first Quick Look preview spacebar draws says so in one quiet line, once, and a click opens Settings.
- **Settings is one short page**: theme, Automatic, Light or Dark, text size, Use spacebar for every file with its
  status, the editor, updates, Report a Problem and Uninstall. Everything else is under **Advanced**, closed until you
  open it: scripts in HTML files, HTML in Markdown, remote images, editing in the preview, checking off tasks, hidden
  files, a custom theme and custom.css, and the settings file with Reset to Defaults.
- Body font and page width (both still in the Aa button), code font, line height, code highlighting, Minimal chrome,
  table of contents, front matter, word count, math, Mermaid, Markdown links, README first, folder previews and the
  sidebar's arrow keys left the window. Each keeps its saved value (word count and README first excepted, above) and is still a key in settings.json (the README lists
  them); Reset to Defaults puts them back too, and turns folder previews back on in System Settings.
- The Quick Look extension's state and other apps' Quick Look extensions that claim spacebar's types show at the top of
  Settings only while something is wrong, with Open Quick Look Extensions or a Turn Off button.
- A welcome window on first launch, and a new app icon.
