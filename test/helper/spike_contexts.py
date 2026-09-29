#!/usr/bin/env python3
"""Converts the Space decisions the helper spike logged live (~/Library/Logs/SpacebarHelperSpike.log, one `space` line per Space
pressed) into test/helper/contexts.json: what the AX reads found, and what the spike decided. Paths are replaced by placeholders.
Every Finder context is kept; other apps once each. The icon and gallery rows are told apart by the order the test script ran
them in (icon, then gallery), since the spike logged both views as `icon-or-gallery`."""
import json, os, re, sys

LOG = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/Library/Logs/SpacebarHelperSpike.log')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'contexts.json')
out, seen_other, icon_like = [], set(), 0
for line in open(LOG, encoding='utf-8'):
    if ' space id=' not in line:
        continue
    f = dict(re.findall(r'(\w+)=(\S+)', line.split(' sel=')[0]))
    ctx = f['ctx']
    if ctx.startswith('other:'):
        if ctx in seen_other:
            continue
        seen_other.add(ctx)
        label = 'other app (' + ctx[6:] + ')'
    elif ctx == 'finder.icon-or-gallery':
        label = ['icon', 'gallery'][min(icon_like, 1)]
        icon_like += 1
    else:
        label = ctx.split('.', 1)[1]
    expect = 'show' if f['decision'] == 'would-swallow' else 'pass:' + f['reason']
    out.append({'label': label, 'id': int(f['id']), 'front': 'finder' if f['front'] == 'com.apple.finder' else 'other',
                'target': 'finder' if f['tgt'] == 'com.apple.finder' else 'other',
                'role': None if f['role'] == '-' else f['role'], 'subrole': None if f['sub'] == '-' else f['sub'],
                'ql': f['ql'] == '1', 'errs': [] if f['errs'] == '-' else f['errs'].split(','),
                'latencyMs': float(f['latency'].rstrip('ms')), 'selection': [f'/Users/u/sel{i}' for i in range(int(f['n']))],
                'expect': expect})
json.dump(out, open(OUT, 'w'), indent=1)
print(f'{len(out)} contexts -> {OUT}')
