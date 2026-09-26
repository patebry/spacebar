#!/usr/bin/env python3
"""The folders extension (md.spacebar.preview.folders) against qlmanage instances this script launches.

folderMode on: a folder with Markdown previews its README with a sidebar. folderMode off, or a folder without Markdown: the
extension declines, and what Quick Look shows instead is reported (V6). settings.json is backed up and restored, and the
folders extension's pluginkit election is put back as it was found. pluginkit -e is only
ever run on md.spacebar.preview.folders.
"""
import os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_live as sl
from qlcommon import start_log, wait_for, require_idle, instances

FOLDERS_ID = 'md.spacebar.preview.folders'
OUT = tempfile.mkdtemp(prefix='spacebar-folders-')
LOG = os.path.join(OUT, 'folders.log')


def preview(folder, needle, timeout=12):
    require_idle()
    mark = os.path.getsize(LOG)
    p = subprocess.Popen(['qlmanage', '-p', folder], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = wait_for(LOG, needle, timeout, mark)
    time.sleep(1.0)
    seen = open(LOG).read()[mark:]
    p.terminate(); p.wait(5)
    time.sleep(0.8)
    return ok, seen


def election():
    """'use', 'ignore' or None (not registered), from pluginkit's leading +/- marker."""
    out = subprocess.run(['pluginkit', '-m', '-i', FOLDERS_ID], capture_output=True, text=True).stdout
    if not out.strip(): return None
    return 'ignore' if out.lstrip().startswith('-') else 'use'


def main():
    found = election()
    sl.backup()
    results = []
    with_md = os.path.join(OUT, 'notes'); os.makedirs(with_md)
    open(os.path.join(with_md, 'README.md'), 'w').write('# Folder readme\n\nHello.\n')
    open(os.path.join(with_md, 'b.md'), 'w').write('# B\n')
    no_md = os.path.join(OUT, 'empty'); os.makedirs(no_md)
    open(os.path.join(no_md, 'x.txt'), 'w').write('x\n')
    try:
        sl.write_settings({'version': 1, 'folderMode': True})
        subprocess.run(['pluginkit', '-e', 'use', '-i', FOLDERS_ID], check=True)
        subprocess.run(['qlmanage', '-r'], capture_output=True)
        ok, seen = preview(with_md, 'rendered[open]')
        ok = ok and 'folder preview: ' in seen and 'README.md' in seen
        results.append(ok); print(f"{'PASS' if ok else 'FAIL'} folderMode on: folder previews its README")
        ok, seen = preview(no_md, 'declined: no markdown')
        results.append(ok); print(f"{'PASS' if ok else 'FAIL'} a folder without Markdown is declined")
        sl.write_settings({'version': 1, 'folderMode': False})
        ok, seen = preview(with_md, 'declined: folder previews are off')
        results.append(ok); print(f"{'PASS' if ok else 'FAIL'} folderMode off: declined")
        print('   V6: after a decline Quick Look shows its own folder preview; log lines:',
              [l[-120:] for l in seen.splitlines() if 'declin' in l or 'error' in l.lower()][:4])
    finally:
        sl.restore()
        if found: subprocess.run(['pluginkit', '-e', found, '-i', FOLDERS_ID])
    return results


if __name__ == '__main__':
    logp = start_log(LOG)
    try:
        r = main()
    finally:
        logp.terminate()
    print(f'\n{sum(r)}/{len(r)} folder checks passed; files in {OUT}')
    sys.exit(0 if r and all(r) else 1)
