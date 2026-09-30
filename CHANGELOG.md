# Changelog

Each release's notes on GitHub also list its commits. This file keeps what changed for someone using spacebar.

## 0.3.0 (unreleased)

Waits for the Developer ID: the first release with the Space helper is notarized.

### Use spacebar for every file

- **Space in Finder opens spacebar for any file**, not only the types Quick Look hands it: plain text, CSV, HTML (scripts
  off), PDF, images, video and audio open in spacebar's own panel with the same sidebar. Off until you turn it on in the
  welcome sheet or Settings, General.
- Space, Esc, ⌘W and ⌘. close the panel in one press; the arrow keys drive the sidebar, or Finder's selection with the
  panel following. Several selected files open with a sidebar of just those files.
- The panel hides while another app is in front and comes back with Finder, a PDF at its page and a video at its time.
- The panel remembers its size and place on each display.
- A rename, the search field, ⌘Y, secure input and every other app keep their keys; a Space spacebar cannot answer in
  150 ms is handed back to Finder.
- It works through a small helper that needs Accessibility (listed as "spacebar Helper") and runs at login; it never opens a
  file, and a sandboxed viewer renders them. SECURITY.md has the threat model. Settings, General shows its state.
- Installing, updating and uninstalling handle the helper: an update brings it back within about 20 seconds, and the
  uninstaller removes it with its permissions.

### Edit text in place

- Click the text of a code, config, plain-text, JSON, CSV, YAML, TOML or XML file to edit it; each change is saved, in the
  file's own encoding. For JSON, CSV and XML, turn on **Raw** and click the text. Files over 2 MB, and files that run on their
  own (shell startup files, git hooks, LaunchAgents), are not editable.

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

- Big folders stay fast (the sidebar draws only the rows in view), and it takes the arrow keys as soon as the preview opens.
- The toolbar holds still while the arrows move from file to file: its buttons keep their places, Open is one word with the
  app in its tooltip, and a button with a key gives it in its tooltip.
- The file's kind and size move from a caption row over the file into the toolbar, as quiet text; an image's zoom goes with
  them. A PDF, a video or an image gains the row's height.
- JSON has one view, the tree, with Expand All and Collapse All, in place of 0.2's pretty-printed text; Raw shows its text.
  A notebook shows as its cells (Raw for its JSON).
- The info card's Where names the folder the file is in, with `~` for your home, and its Open button gives way to the
  toolbar's (Minimal chrome keeps it).
- Word count and reading time are off by default. A settings file that had them on keeps them on.
- With **Use spacebar for every file** on but the helper not taking Space (Accessibility off, or not running),
  the first Quick Look preview spacebar draws says so in one quiet line, once, and a click opens Settings.
- Settings, General lists other Quick Look extensions that claim spacebar's types, with a Turn Off button.
- A welcome window on first launch, and a new app icon.
