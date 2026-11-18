"""Removed std.os.windows identifiers, resolving every binding path.

Usage: python -I win_idents3.py <repo> <rev> <std17> <std15> <fork-only-list> <rehome-out.txt>

Bindings resolved per file:
  std.os.windows                      -> std root
  win32.windows (win32.zig:528)       -> std root
  internal_os.windows / os.windows    -> the fork's src/os/windows.zig, whose
                                         `pub const N = windows.P;` re-exports map to std
  local aliases of any of the above (`const k32 = windows.kernel32;`)
plus textual `std.os.windows.X` uses. A use counts when the std identifier it
reaches exists in 0.15.2 and not in 0.17.1.
"""
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import paths, sources

repo, rev, std17, std15, fo_path, rehome_out = sys.argv[1:7]


def pubs(path):
    if not os.path.exists(path):
        return set()
    t = open(path, encoding="utf-8").read()
    return set(re.findall(r'^pub (?:const|fn|var|extern "[^"]+" fn|inline fn) ([A-Za-z_]\w*)', t, re.M))


def tree(d):
    root = pubs(os.path.join(d, "os", "windows.zig"))
    ns = {f[:-4]: pubs(os.path.join(d, "os", "windows", f)) for f in os.listdir(os.path.join(d, "os", "windows")) if f.endswith(".zig")}
    return root, ns


r17, ns17 = tree(std17)
r15, ns15 = tree(std15)
NS = set(ns15) | set(ns17)


def removed(path):
    """path: list like ['kernel32','GetLastError'] or ['HRESULT']."""
    if len(path) >= 2 and path[0] in NS:
        return path[1] in ns15.get(path[0], set()) and path[1] not in ns17.get(path[0], set()), f"{path[0]}.{path[1]}"
    if path and path[0] not in NS:
        return (path[0] in r15) and (path[0] not in r17), path[0]
    return False, ".".join(path)


files = sorted(f for f in paths(repo, rev) if f.endswith(".zig") and "uucode_tables" not in f)
file_texts = sources(repo, rev, files)


def show(f):
    return file_texts.get(f, "")


fork_only = set(l.strip() for l in open(fo_path, encoding="utf-8"))
# Fork module re-export map.
fmod = show("src/os/windows.zig")
reexp = {}
for m in re.finditer(r"^pub const ([A-Za-z_]\w*)\s*=\s*windows\.([\w.]+)\s*;", fmod, re.M):
    reexp[m.group(1)] = m.group(2).split(".")

ALIAS = re.compile(r"^\s*(?:pub\s+)?const\s+([A-Za-z_]\w*)\s*=\s*([A-Za-z_][\w.]*)\s*;", re.M)
uses = collections.Counter()
per_file = collections.Counter()
for f in files:
    t = show(f)
    if not re.search(r"std\.os\.windows|internal_os\.windows|win32\.windows|\bos\.windows\b", t):
        continue
    # binding -> (kind, prefix path) kind 'std' (prefix within std) or 'fork' (fork module)
    amap = {}
    for _ in range(4):
        for m in ALIAS.finditer(t):
            name, expr = m.group(1), m.group(2)
            parts = expr.split(".")
            if parts[:3] == ["std", "os", "windows"]:
                amap[name] = ("std", parts[3:])
            elif parts in (["win32", "windows"],):
                amap[name] = ("std", [])
            elif parts in (["internal_os", "windows"], ["os", "windows"]) and f != "src/os/windows.zig":
                amap[name] = ("fork", [])
            elif parts[0] in amap and len(parts) >= 2 and name != parts[0]:
                kind, pre = amap[parts[0]]
                amap[name] = (kind, pre + parts[1:])
    seen_spans = set()
    for m in re.finditer(r"std\.os\.windows\.([A-Za-z_]\w*)(?:\.([A-Za-z_]\w*))?", t):
        path = [m.group(1)] + ([m.group(2)] if m.group(2) else [])
        ok, key = removed(path)
        seen_spans.add(m.start(1))
        if ok:
            uses[key] += 1
            per_file[f] += 1
    for name, (kind, pre) in amap.items():
        for m in re.finditer(r"(?<![\w.])" + re.escape(name) + r"\.([A-Za-z_]\w*)(?:\.([A-Za-z_]\w*))?", t):
            rest = [m.group(1)] + ([m.group(2)] if m.group(2) else [])
            if kind == "fork":
                if not pre and rest[0] in reexp:
                    path = reexp[rest[0]] + rest[1:]
                elif pre and pre[0] in reexp:
                    path = reexp[pre[0]] + pre[1:] + rest
                else:
                    continue
            else:
                path = pre + rest
            ok, key = removed(path[:2] if path and path[0] in NS else path[:1])
            if ok:
                uses[key] += 1
                per_file[f] += 1

fo = {f: v for f, v in per_file.items() if f in fork_only}
sh = {f: v for f, v in per_file.items() if f not in fork_only}
print(f"removed identifiers reached: {len(uses)}; uses: {sum(uses.values())} in {len(per_file)} files")
print(f"  fork-only: {sum(fo.values())} uses in {len(fo)} files")
print(f"  shared:    {sum(sh.values())} uses in {len(sh)} files")
for f, v in sorted(sh.items(), key=lambda x: -x[1]):
    print(f"    shared {v:4d} {f}")
with open(rehome_out, "w", encoding="utf-8", newline="\n") as fh:
    for f, v in sorted(per_file.items()):
        fh.write(f"{v}\t{'fork-only' if f in fork_only else 'shared'}\t{f}\n")
