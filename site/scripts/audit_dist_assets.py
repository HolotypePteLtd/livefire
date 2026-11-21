#!/usr/bin/env python3
"""Audit dist/ HTML for local asset references that would 404."""
import re, sys
from pathlib import Path
from urllib.parse import urlsplit, unquote

dist = Path(sys.argv[1] if len(sys.argv) > 1 else 'dist')
ref_re = re.compile(r'(?:href|src|srcset)\s*=\s*["\']([^"\']+)["\']', re.I)
srcset_re = re.compile(r'srcset\s*=\s*["\']([^"\']+)["\']', re.I)
missing, ok = {}, 0

def check(ref, page):
    global ok
    u = urlsplit(ref)
    if u.scheme or u.netloc or ref.startswith(('#', 'mailto:', 'tel:', 'data:')):
        return
    path = unquote(u.path)
    if not path:
        return
    if path.startswith('/'):
        target = dist / path.lstrip('/')
    else:
        target = (page.parent / path).resolve()
        try:
            target = dist / target.relative_to(dist.resolve())
        except ValueError:
            return
    if target.exists():
        ok += 1
    else:
        missing.setdefault(str(target.relative_to(dist)), set()).add(str(page))

pages = sorted(dist.rglob('*.html'))
for page in pages:
    text = page.read_text(errors='replace')
    for m in ref_re.finditer(text):
        ref = m.group(1)
        if refset := m.group(0):
            for part in ref.split(','):
                check(part.strip().split(' ')[0], page)
    for m in srcset_re.finditer(text):
        for part in m.group(1).split(','):
            check(part.strip().split(' ')[0], page)

print(f'pages scanned: {len(pages)}, refs ok: {ok}')
if missing:
    print('MISSING (referenced but absent from dist):')
    for target, refs in sorted(missing.items()):
        for r in sorted(refs)[:3]:
            print(f'  {target}   <- {r}')
else:
    print('no missing local references')
