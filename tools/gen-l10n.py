#!/usr/bin/env python3
"""Regenerate the translation template from L("en", "ko") callsites.

Usage:  python3 tools/gen-l10n.py            # rewrite template.strings
        python3 tools/gen-l10n.py --check    # exit 1 if template is stale (CI)

Static pairs become table keys; interpolated strings can't (their English is
assembled at runtime) and fall back to English for table languages.
"""
import re, glob, collections, sys

pat = re.compile(r'L\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)')
pairs = collections.OrderedDict()
for path in sorted(glob.glob('Sources/anf/**/*.swift', recursive=True)):
    for m in pat.finditer(open(path).read()):
        en, ko = m.group(1), m.group(2)
        if '\\(' in en or '\\(' in ko:
            continue
        pairs.setdefault(en, ko)

out = ['/* anf UI strings — translation template.',
       '   To add a language: copy this file to <code>.strings (e.g. ja.strings),',
       '   translate the RIGHT-hand side, and rebuild. No code changes needed.',
       '   Keys are the English strings; values below are the Korean reference.',
       '   Interpolated strings fall back to English for table languages. */', '']
out += [f'"{en}" = "{ko}";' for en, ko in pairs.items()]
content = '\n'.join(out) + '\n'

path = 'Sources/anf/Resources/l10n/template.strings'
if '--check' in sys.argv:
    if open(path).read() != content:
        print('template.strings is stale — run: python3 tools/gen-l10n.py')
        sys.exit(1)
    print(f'template in sync ({len(pairs)} strings)')
else:
    open(path, 'w').write(content)
    print(f'wrote {len(pairs)} strings to {path}')
