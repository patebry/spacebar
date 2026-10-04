#!/bin/bash
# Builds the app without installing it (./build.sh --no-install: nothing registered, nothing in ~/Applications) and checks
# what the built Info.plists claim and declare: every type that routes to a third-party extension (measured on macOS 15.4),
# none Apple previews itself, and one imported declaration per extension spacebar gives a type. Then the Space helper's bundles:
# their layout, the launchd agent's plist, the viewer's entitlements (the preview extension's plus the helper's Mach name), the
# helper's hardened runtime without a sandbox or any entitlement, and the signatures the helper's link requires.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${SKIP_BUILD:-0}" = 1 ] || ARCHS=${ARCHS:-arm64} ./build.sh --no-install >/dev/null
plutil -lint -s build/spacebar.app/Contents/Info.plist build/spacebar.app/Contents/PlugIns/*.appex/Contents/Info.plist
python3 - build/spacebar.app <<'PY'
import plistlib, re, sys
app = sys.argv[1]
host = plistlib.load(open(f'{app}/Contents/Info.plist', 'rb'))
appex = plistlib.load(open(f'{app}/Contents/PlugIns/SpacebarPreview.appex/Contents/Info.plist', 'rb'))
folders = plistlib.load(open(f'{app}/Contents/PlugIns/SpacebarFolders.appex/Contents/Info.plist', 'rb'))
claims = appex['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes']
imports = host['UTImportedTypeDeclarations']
failures = 0
def check(ok, name, detail=''):
    global failures
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f' {detail}'))
    failures += not ok

ROUTES = '''net.daringfireball.markdown public.markdown md.spacebar.qlmanage
  public.swift-source public.python-script public.ruby-script public.perl-script public.php-script public.shell-script public.bash-script
  public.zsh-script public.ksh-script com.apple.terminal.shell-script public.c-source public.c-header public.c-plus-plus-source
  public.c-plus-plus-header public.objective-c-source public.objective-c-plus-plus-source com.sun.java-source com.netscape.javascript-source
  com.microsoft.typescript public.css public.make-source public.patch-file public.protobuf-source com.apple.applescript.text com.apple.rez-source
  public.json public.geojson public.yaml public.xml com.apple.property-list public.tab-separated-values-text com.apple.log org.w3.webvtt
  public.zip-archive public.tar-archive org.gnu.gnu-zip-archive org.gnu.gnu-zip-tar-archive public.bzip2-archive org.tukaani.xz-archive
  public.tar-bzip2-archive org.tukaani.tar-xz-archive org.7-zip.7-zip-archive com.apple.disk-image-udif public.data'''.split()
# Apple previews these itself (or nothing routes them); a claim would be dead weight or, for a parent, meaningless.
APPLE = '''public.plain-text public.text public.html public.xhtml public.comma-separated-values-text public.x509-certificate com.adobe.pdf
  public.image public.png public.jpeg public.movie public.mpeg-4 com.apple.quicktime-movie public.mp3 public.mpeg-4-audio com.apple.m4a-audio
  com.microsoft.waveform-audio public.avi org.xiph.flac org.xiph.ogg-vorbis public.rtf com.microsoft.word.doc org.openxmlformats.wordprocessingml.document
  public.mpeg-2-transport-stream public.avchd-mpeg-2-transport-stream public.disk-image org.matroska.mkv com.adobe.flash.video
  org.webmproject.webm public.source-code public.script public.archive public.content public.item com.apple.logic.exs'''.split()
UNDECLARED = '''adoc asciidoc bat bib cfg cjs clj cmake conf cs csr cts dart diz dockerignore editorconfig env erl err ex example fish gitattributes
  gitignore gitmodules go gql gradle graphql groovy har hcl hs ini ipynb json5 jsonc jsx kt kts less lock lua nfo nim npmrc nvmrc org
  properties ps1 pyi rar rs rst sample sass scala scss sql srt sum svelte tex toml tf vb vue wat webmanifest xsd xsl zig zst tzst dockerfile'''.split()
# Other tools own these for binary files (a.out, Go's go.mod is text but .mod is also a tracker module): never declared.
NOT_DECLARED = ['out', 'mod']
# Files that often hold secrets: shown, but data, so the viewer never offers to open them in another app.
SECRETS = {'md.spacebar.type.env', 'md.spacebar.type.npmrc', 'md.spacebar.type.csr'}
CONFORMS = {'public.source-code', 'public.script', 'public.plain-text', 'public.json', 'public.xml', 'public.archive', 'public.data'}

missing = [t for t in ROUTES if t not in claims]
check(not missing, f'appex claims every routing system type ({len(ROUTES)})', missing)
bad = [t for t in claims if t in APPLE]
check(not bad and 'public.html' not in claims, 'appex claims no Apple-owned or parent type, public.html included', bad)
check(len(claims) == len(set(claims)), 'appex claims each type once', [t for t in claims if claims.count(t) > 1])
check(all(re.fullmatch(r'[A-Za-z0-9.-]+', t) and not t.startswith('dyn.') for t in claims), 'every claim is a plain identifier, no dyn.* ID')

ids = [d.get('UTTypeIdentifier') for d in imports]
ours = [d for d in imports if d.get('UTTypeIdentifier', '').startswith('md.spacebar.type.')]
check(ids.count('net.daringfireball.markdown') == 1, 'host still declares Markdown once')
check(len(ids) == len(set(ids)), 'host declares each imported type exactly once', [i for i in ids if ids.count(i) > 1])
exts = [e for d in ours for e in d['UTTypeTagSpecification']['public.filename-extension']]
check(len(exts) == len(set(exts)), 'each extension belongs to one declaration', [e for e in exts if exts.count(e) > 1])
check(not [e for e in UNDECLARED if e not in exts], f'every undeclared extension the spike found ({len(UNDECLARED)}) is declared', [e for e in UNDECLARED if e not in exts])
badconf = [(d['UTTypeIdentifier'], d.get('UTTypeConformsTo')) for d in ours
           if not d.get('UTTypeConformsTo') or any(c not in CONFORMS for c in d['UTTypeConformsTo'])
           or (('public.data' in d['UTTypeConformsTo']) != (d['UTTypeIdentifier'] in SECRETS))]
check(not badconf, 'each declaration conforms to source code, a script, plain text, JSON, XML or an archive; only the secret-bearing ones to data', badconf)
check(not [e for e in NOT_DECLARED if e in exts], '.out and .mod are not declared', [e for e in NOT_DECLARED if e in exts])
wellformed = all(d['UTTypeIdentifier'] == 'md.spacebar.type.' + d['UTTypeTagSpecification']['public.filename-extension'][0]
                 and d.get('UTTypeDescription') and set(d) == {'UTTypeIdentifier', 'UTTypeDescription', 'UTTypeConformsTo', 'UTTypeTagSpecification'}
                 for d in ours)
check(wellformed, 'each declaration is named for its first extension, with a description and nothing else')
confs = {d['UTTypeIdentifier']: d['UTTypeConformsTo'] for d in ours}
check(confs.get('md.spacebar.type.ipynb') == ['public.json'] and confs.get('md.spacebar.type.toml') == ['public.plain-text']
      and confs.get('md.spacebar.type.rar') == ['public.archive'] and confs.get('md.spacebar.type.go') == ['public.source-code'],
      'ipynb is JSON, TOML plain text, RAR an archive, Go source code', confs)
unclaimed = [d['UTTypeIdentifier'] for d in ours if d['UTTypeIdentifier'] not in claims]
check(not unclaimed, f'appex claims every declared type ({len(ours)})', unclaimed)
check(set(claims) == set(ROUTES) | {d['UTTypeIdentifier'] for d in ours}, 'appex claims nothing else', sorted(set(claims) - set(ROUTES) - set(confs)))
check(folders['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes'] == ['public.folder', 'public.directory'], 'folders extension unchanged')
print('claims: all passed' if not failures else f'claims: {failures} failed')
sys.exit(1 if failures else 0)
PY
python3 - build/spacebar.app <<'PY'
import hashlib, os, plistlib, re, subprocess, sys
app = sys.argv[1]
H = f'{app}/Contents/Helpers'
helper, viewer = f'{H}/spacebar Helper.app', f'{H}/spacebar Viewer.app'
writer = f'{viewer}/Contents/XPCServices/md.spacebar.viewer.writer.xpc'
appex = f'{app}/Contents/PlugIns/SpacebarPreview.appex'
agent = f'{app}/Contents/Library/LaunchAgents/md.spacebar.helper.plist'
failures = 0
def check(ok, name, detail=''):
    global failures
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f' {detail}'))
    failures += not ok
def run(*a):
    r = subprocess.run(a, capture_output=True, text=False)
    return r.returncode, r.stdout, r.stderr.decode(errors='replace')
def ents(path):
    _, out, _ = run('codesign', '-d', '--entitlements', ':-', path)
    return plistlib.loads(out) if out.strip() else {}
info = lambda b: plistlib.load(open(f'{b}/Contents/Info.plist', 'rb'))

check(sorted(os.listdir(H)) == ['spacebar Helper.app', 'spacebar Viewer.app'], 'Contents/Helpers holds the helper and the viewer only', os.listdir(H))
named = re.search(r'static let accessibilityName = "([^"]+)"', open('App/Panes.swift').read())
check(named and named.group(1) + '.app' == os.path.basename(helper),
      "the app names the helper as Accessibility lists it, by its bundle's file name", named and named.group(1))
for path in [f'{helper}/Contents/MacOS/SpacebarHelper', f'{viewer}/Contents/MacOS/SpacebarViewer', f'{writer}/Contents/MacOS/SpacebarWriter',
             f'{viewer}/Contents/Resources/web/index.html', agent]:
    check(os.path.isfile(path), 'bundle has ' + path[len(app) + 1:])
types = open('scripts/quicklook-types.txt', 'rb').read()
copies = [f'{viewer}/Contents/Resources/quicklook-types.txt', f'{appex}/Contents/Resources/quicklook-types.txt']
check(all(os.path.isfile(c) and open(c, 'rb').read() == types for c in copies),
      "the viewer and the extension carry quicklook-types.txt (Apple's previews in the panel are never asked for a claimed type)")
hi, vi, wi = info(helper), info(viewer), info(writer)
check(hi['CFBundleIdentifier'] == 'md.spacebar.helper' and hi.get('LSUIElement') is True and hi.get('CFBundleDisplayName') == 'spacebar',
      'helper: md.spacebar.helper, LSUIElement, shown as "spacebar"', hi)
check(vi['CFBundleIdentifier'] == 'md.spacebar.viewer' and vi.get('LSUIElement') is True and vi.get('CFBundleDisplayName') == 'spacebar',
      'viewer: md.spacebar.viewer, LSUIElement, shown as "spacebar"', vi)
check(wi['CFBundleIdentifier'] == 'md.spacebar.viewer.writer' and wi['CFBundlePackageType'] == 'XPC!', "viewer embeds its own writer (md.spacebar.viewer.writer)")
check(run('plutil', '-lint', '-s', f'{helper}/Contents/Info.plist', f'{viewer}/Contents/Info.plist', agent)[0] == 0, 'plists lint')

a = plistlib.load(open(agent, 'rb'))
check(set(a) == {'Label', 'BundleProgram', 'MachServices', 'KeepAlive', 'RunAtLoad', 'ProcessType', 'LimitLoadToSessionType', 'AssociatedBundleIdentifiers'},
      'agent: exactly the planned keys', sorted(a))
check(a['Label'] == 'md.spacebar.helper' and a['MachServices'] == {'md.spacebar.helper': True}, 'agent: label and the one Mach service', a)
check(a['BundleProgram'] == 'Contents/Helpers/spacebar Helper.app/Contents/MacOS/SpacebarHelper' and os.path.isfile(f"{app}/{a['BundleProgram']}"),
      "agent: BundleProgram is the helper's executable", a['BundleProgram'])
check(a['KeepAlive'] == {'SuccessfulExit': False} and a['RunAtLoad'] is True, 'agent: restarted after a crash, not after exit 0; runs at load', a)
check(a['ProcessType'] == 'Interactive' and a['LimitLoadToSessionType'] == 'Aqua' and a['AssociatedBundleIdentifiers'] == ['md.spacebar'],
      'agent: interactive, GUI sessions only, listed under spacebar', a)

pe, ve = ents(appex), ents(viewer)
mach = 'com.apple.security.temporary-exception.mach-lookup.global-name'
expected = dict(pe, **{mach: pe.get(mach, []) + ['md.spacebar.helper']})
check(ve == expected, "viewer: exactly the preview extension's entitlements plus the helper's Mach name", ve)
check(pe.get('com.apple.security.app-sandbox') is True and 'md.spacebar.helper' not in pe.get(mach, []), 'the extension itself is unchanged')
check(ents(helper) == {}, 'helper: no entitlements (so no sandbox)', ents(helper))
check(ents(writer) == {}, "viewer's writer: no entitlements, like the extensions' writers", ents(writer))
INJECTABLE = ['com.apple.security.cs.allow-dyld-environment-variables', 'com.apple.security.cs.disable-library-validation']
carriers = [p for p in (viewer, writer, app, helper) for k in INJECTABLE if k in ents(p)]
check(not carriers, 'the viewer, its writer, the app and the helper carry no entitlement that lets a library in', carriers)
_, _, hd = run('codesign', '-dv', helper)
_, _, vd = run('codesign', '-dv', viewer)
check(re.search(r'flags=0x[0-9a-f]*\([^)]*runtime', hd) is not None, 'helper: hardened runtime', hd)
_, _, wd = run('codesign', '-dv', writer)
_, _, ad = run('codesign', '-dv', app)
runtime = lambda d: re.search(r'flags=0x[0-9a-f]*\([^)]*runtime', d) is not None
check(runtime(vd) and runtime(wd) and runtime(ad), "the viewer, its writer and the app: hardened runtime (the helper admits no other peer)", [vd, wd, ad])
check('Identifier=md.spacebar.helper' in hd and 'Identifier=md.spacebar.viewer' in vd, 'signed under their bundle IDs')
code, _, err = run('codesign', '--verify', '--strict', '--deep', app)
check(code == 0, 'the app verifies, helpers included', err)

_, syms, _ = run('nm', '-j', f'{helper}/Contents/MacOS/SpacebarHelper')
_, libs, _ = run('otool', '-L', f'{helper}/Contents/MacOS/SpacebarHelper')
parsers = [n for n in ('FolderListing', 'FolderScan', 'PageSettings', 'SchemeHandler', 'ArchiveListing', 'FileTypes') if n.encode() in syms]
check(not parsers and b'WebKit' not in libs and b'PDFKit' not in libs, 'helper: none of the file-reading code or WebKit is in it', parsers)

tmp = os.environ.get('TMPDIR', '/tmp')
code, _, _ = run('codesign', '-d', f'--extract-certificates={tmp}/spacebar-claims-cert', app)
cert = f'{tmp}/spacebar-claims-cert0'
if os.path.exists(cert):
    leaf = hashlib.sha1(open(cert, 'rb').read()).hexdigest().upper()
    os.remove(cert)
    req = lambda ids: ('=(' + ' or '.join(f'identifier "{i}"' for i in ids) + f') and certificate leaf = H"{leaf}"'
                       + ''.join(f' and !entitlement["{k}"] exists' for k in INJECTABLE))
    client = req(['md.spacebar.viewer', 'md.spacebar'])
    check(run('codesign', '--verify', '-R' + client, viewer)[0] == 0 and run('codesign', '--verify', '-R' + client, app)[0] == 0,
          "the viewer and the app meet the helper's client requirement")
    check(run('codesign', '--verify', '-R' + client, appex)[0] != 0 and run('codesign', '--verify', '-R' + client, helper)[0] != 0,
          'the extension and the helper itself do not')
    check(run('codesign', '--verify', '-R' + req(['md.spacebar.helper']), helper)[0] == 0, "the helper meets what the viewer requires of it")
else:
    print('SKIP ad-hoc build: no certificate, so the link refuses every client')
print('helper bundles: all passed' if not failures else f'helper bundles: {failures} failed')
sys.exit(1 if failures else 0)
PY
