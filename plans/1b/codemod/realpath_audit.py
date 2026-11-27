# The #5889 audit (1B.6): every realPathFileAlloc whose [:0]u8 result may be coerced to a non-sentinel slice
# and freed by it. Lists, per call: bound to an untyped const and used only by a free or a read (ok), or anything
# else (review), with the uses that make it so.
import os
import re
import sys

root = sys.argv[1]
files = []
for dp, dn, fn in os.walk(os.path.join(root, 'src')):
    for f in fn:
        if f.endswith('.zig'):
            files.append(os.path.join(dp, f))

call_re = re.compile(r'realPathFileAlloc\(')
const_re = re.compile(r'(?:const|var)\s+([A-Za-z_]\w*)\s*(:\s*[^=]+)?=\s*(?:try\s+)?[\w.()\[\]]*realPathFileAlloc\(')
ok = 0
review = []
for path in sorted(files):
    text = open(path, encoding='utf-8').read()
    lines = text.split('\n')
    for i, line in enumerate(lines):
        if 'realPathFileAlloc(' not in line or line.strip().startswith('//') or 'pub fn realPathFileAlloc' in line:
            continue
        rel = os.path.relpath(path, root).replace(os.sep, '/')
        m = const_re.search(line)
        if not m or m.group(2):
            review.append((rel, i + 1, 'not an untyped const: ' + line.strip()[:150]))
            continue
        name = m.group(1)
        # Uses of the name in the next 120 lines, up to the end of the enclosing block (a line at a smaller indent
        # that closes a brace).
        indent = len(line) - len(line.lstrip())
        bad = []
        for j in range(i + 1, min(len(lines), i + 400)):
            l = lines[j]
            stripped = l.strip()
            if stripped.startswith('}') and (len(l) - len(l.lstrip())) < indent:
                break
            if not re.search(r'(?<![\w.])' + re.escape(name) + r'(?!\w)', l):
                continue
            code = re.sub(r'//.*', '', l)
            uses = [u.start() for u in re.finditer(r'(?<![\w.])' + re.escape(name) + r'(?!\w)', code)]
            for u in uses:
                after = code[u + len(name):]
                before = code[:u]
                if re.search(r'\.free\(\s*$', before) and after.lstrip().startswith(')'):
                    continue  # a free of the name itself
                if after.startswith('.len') or after.startswith('['):
                    continue  # a read in place
                # Stored or handed on: an assignment or field initializer, a return, a break, a map or list
                # insert. Everything else (an argument a callee reads) is a read.
                stored = (re.search(r'(?<![=!<>])=\s*(?:@constCast\()?$', before) or re.search(r'return\s+$', before)
                          or re.search(r'break\s+:\w+\s+$', before) or re.search(r'\.(put|append|appendAssumeCapacity|insert|putNoClobber)\([^;]*$', before))
                if not stored:
                    continue
                if re.search(r'(expect\w*|print|startsWith|endsWith|eql\w*|join|concat|dirname|basename|indexOf\w*|'
                             r'allocPrint|bufPrint|openDirAbsolute|openFileAbsolute|accessAbsolute|statFile|'
                             r'createFileAbsolute|deleteFileAbsolute|deleteTreeAbsolute|copyFileAbsolute|'
                             r'renameAbsolute|readFileAlloc|utf8ToUtf16LeAllocZ|wtf8ToWtf16LeAllocZ|'
                             r'utf8ToUtf16LeAlloc|wtf8ToWtf16LeAlloc|isAbsolute|resolve|relative|fmt)\b[^;]*$', before):
                    continue
                if re.search(r'\{s\}|\{f\}', code) and re.search(r'\.\{[^}]*$', before):
                    continue  # a format argument
                bad.append(f'{j + 1}: {stripped[:140]}')
        if bad:
            review.append((rel, i + 1, f'const {name}: ' + ' | '.join(bad[:4])))
        else:
            ok += 1
print(f'ok {ok}; review {len(review)}')
for r in review:
    print(f'{r[0]}:{r[1]}: {r[2]}')
