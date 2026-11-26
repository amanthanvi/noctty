"""B1 (1B.5): re-point the callers of the declarations 1B.1 moved out of src/os/windows.zig (now exactly v1.4.0's)
into the fork's src/os/windows_ext.zig, from the exact map 1B.1 recorded (one line per file:
`<file>: <name>-><target> ...`, target `ext`, `top` or `exp.kernel32`).

For each file, a use of the map's name through a binding of the fork's os/windows module (`@import(".../os/windows.zig")`,
`internal_os.windows`, `os.windows`, `@import(".../os/main.zig").windows`) is rewritten:
  ext           `W.<name path>` -> `E.<last name>`, E the file's windows_ext binding (added beside the windows import
                when the file has none);
  top           `W.exp.<name>` -> `W.<name>` (v1.4.0 has it at its top level);
  exp.kernel32  `W.<name>` -> `W.exp.kernel32.<name>`.
The map is read against the merged content: a use 0b already re-homed is simply not found. Idempotent.

Usage: python plans/1b/codemod/b1_sweep.py <map> [--check] [--report out.tsv]
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codemod  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]


def parse_map(path):
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        f, _, rest = line.partition(": ")
        out[f.strip()] = [tuple(item.split("->")) for item in rest.split()]
    return out


def windows_bindings(toks, rel):
    """Names bound to the fork's os/windows module, the file's windows_ext binding name (or None), the index of
    the token that ends the first windows binding's declaration (for an added binding), and that binding's
    import path (for `@import(".../windows.zig")`) or else None, and its initializer's text."""
    names, ext, decl_end, import_path, init = set(), None, None, None, None
    is_os = rel.startswith("src/os/")
    for i, t in enumerate(toks):
        if not (t.kind == "keyword" and t.text == "const" and codemod.is_tok(codemod.at(toks, i + 1), "identifier")
                and codemod.is_tok(codemod.at(toks, i + 2), "op", "=")):
            continue
        name = toks[i + 1].text
        k = i + 3
        semi = k
        while semi < len(toks) and not (toks[semi].kind == "op" and toks[semi].text == ";"):
            semi += 1
        value = "".join(x.text for x in toks[k:semi])
        m = re.fullmatch(r'@import\("((?:\.\./)*(?:os/)?)windows\.zig"\)', value)
        if m and (m.group(1).endswith("os/") or (is_os and m.group(1) == "")):
            names.add(name)
            if decl_end is None:
                decl_end, import_path, init = semi, m.group(1), value
        elif re.fullmatch(r"(internal_os|os)\.windows", value) or re.fullmatch(
                r'@import\("(?:\.\./)*(?:os/)?main\.zig"\)\.windows', value):
            names.add(name)
            if decl_end is None:
                decl_end, import_path, init = semi, None, value
        m = re.fullmatch(r'@import\("((?:\.\./)*(?:os/)?)windows_ext\.zig"\)', value)
        if (m and (m.group(1).endswith("os/") or (is_os and m.group(1) == ""))) or re.fullmatch(
                r"(internal_os|os)\.windows_ext", value) or re.fullmatch(
                r'@import\("(?:\.\./)*(?:os/)?main\.zig"\)\.windows_ext', value):
            ext = name
    return names, ext, decl_end, import_path, init


def sweep(text, rel, entries):
    toks = codemod.code_tokens(text)
    names, ext, decl_end, import_path, init = windows_bindings(toks, rel)
    edits, hits = [], []
    need_ext = False
    ext_name = ext or "windows_ext"
    for name_path, target in entries:
        parts = name_path.split(".")
        for i, t in enumerate(toks):
            # W . p0 . p1 ...  (W a binding; also internal_os.windows.p0 and os.windows.p0)
            if t.kind != "identifier":
                continue
            k = i
            qualified = None
            if t.text in names and not codemod.is_tok(codemod.at(toks, i - 1), "op", "."):
                k = i + 1
            elif (t.text in ("internal_os", "os") and codemod.is_tok(codemod.at(toks, i + 1), "op", ".")
                  and codemod.is_tok(codemod.at(toks, i + 2), "identifier", "windows")
                  and not codemod.is_tok(codemod.at(toks, i - 1), "op", ".")):
                k = i + 3
                qualified = t.text
            else:
                continue
            ok = True
            for n, p in enumerate(parts):
                if not (codemod.is_tok(codemod.at(toks, k + 2 * n), "op", ".")
                        and codemod.is_tok(codemod.at(toks, k + 2 * n + 1), "identifier", p)):
                    ok = False
                    break
            if not ok:
                continue
            last = toks[k + 2 * len(parts) - 1]
            if codemod.is_tok(codemod.at(toks, k + 2 * len(parts)), "op", ".") and target == "exp.kernel32":
                pass
            span_start, span_end = t.start, last.start + len(last.text)
            if target == "ext":
                if qualified:
                    new = f"{qualified}.windows_ext.{parts[-1]}"
                else:
                    new = f"{ext_name}.{parts[-1]}"
                    need_ext = ext is None
            elif target == "top":
                new = f"{toks[i].text if not qualified else qualified + '.windows'}.{parts[-1]}"
            elif target == "exp.kernel32":
                base = t.text if not qualified else qualified + ".windows"
                new = f"{base}.exp.kernel32.{'.'.join(parts)}"
            else:
                raise ValueError(f"unknown target {target} in {rel}")
            if text[span_start:span_end] == new:
                continue
            edits.append(codemod.Edit(span_start, span_end, new))
            hits.append((name_path, target, t.line + 1))
    if need_ext and edits:
        if decl_end is None:
            raise ValueError(f"{rel}: no windows binding to add windows_ext beside")
        semi = toks[decl_end]
        if import_path is None:
            # The matched binding's own initializer names the module windows_ext sits beside (`os.windows` ->
            # `os.windows_ext`), never a name taken from elsewhere in the text, such as a comment.
            decl = f"\nconst windows_ext = {init[:-len('windows')]}windows_ext;"
        else:
            decl = f'\nconst windows_ext = @import("{import_path}windows_ext.zig");'
        edits.append(codemod.Edit(semi.start + 1, semi.start + 1, decl))
    if not edits:
        return text, hits
    return codemod.apply_edits(text, edits), hits


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report")
    args = ap.parse_args(argv)
    mapping = parse_map(args.map)
    report, changed = [], 0
    for rel, entries in mapping.items():
        path = ROOT / rel
        text = path.read_bytes().decode("utf-8")
        new, hits = sweep(text, rel, entries)
        report.extend(f"{rel}\t{n}\t{t}\t{line}" for n, t, line in hits)
        if new != text:
            changed += 1
            if not args.check:
                path.write_bytes(new.encode("utf-8"))
    print(f"uses re-pointed\t{len(report)}\nfiles {'to change' if args.check else 'changed'}\t{changed}")
    if args.report:
        Path(args.report).write_text("".join(r + "\n" for r in report), encoding="utf-8", newline="\n")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    sys.exit(main())
