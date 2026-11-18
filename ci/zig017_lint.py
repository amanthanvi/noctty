"""Tokenized, occurrence-bound Zig 0.17 migration lint (PLAN 4.1)."""

import argparse
import collections
import functools
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import added_lines, emit, merge_base, sources
from zig_bindings import Bindings, identifier
from zig_context import binary_repeats
import zigtok

FAIL_FORMS = frozenset(("**", "@Type", "@cImport", "stackFallback", "errdefer-capture"))


def _matches(text):
    """(form, first line, all participating lines, error/review), once per line/form.

    Literals remain opaque tokens: removing them would join unrelated code.
    Comments alone are skipped. Multiline code is matched as one token stream.
    """
    bindings = Bindings(text)
    tokens = bindings.tokens
    repeats = binary_repeats(tokens)
    words = [identifier(t) for t in tokens]
    scopes, parents = bindings.scopes, bindings.parents
    containers = {}
    for i, token in enumerate(tokens):
        if zigtok.declaration_at(tokens, i):
            opening = i + 4 if words[i + 2:i + 5] == ["=", "struct", "{"] else None
            containers[scopes[i], words[i + 1]] = opening
    seen = set()
    for i, token in enumerate(tokens):
        form, width, level = None, 1, "error"
        word = words[i]
        if i in repeats:
            form = "**"
        elif token.kind == "builtin" and word in ("@Type", "@cImport"):
            form = word
        elif token.kind == "keyword" and words[i:i + 2] == ["errdefer", "|"]:
            form, width = "errdefer-capture", 2
        elif words[i:i + 3] in (["builtin", ".", "os"], ["builtin", ".", "cpu"],
                                ["builtin", ".", "abi"]):
            form, width, level = "builtin." + words[i + 2], 3, "review"
        elif token.kind == "builtin" and word in ("@intFromEnum", "@enumFromInt"):
            form, level = word, "review"
        elif words[i:i + 3] == ["fmt", ".", "allocPrint"]:
            form, width, level = "fmt.allocPrint", 3, "review"
        elif token.kind == "identifier" and word == "containsAtLeastScalar":
            form, level = word, "review"
        elif token.kind == "builtin" and word == "@hasDecl":
            # This is a review report, not a type checker. Only a local literal
            # container with an explicitly pub member can discharge the report.
            form, level = "@hasDecl (verify target is pub; unresolved targets need review)", "review"
            end = zigtok.match_paren(tokens, i + 1) if i + 1 < len(tokens) and words[i + 1] == "(" else i
            width = end - i + 1
            args = tokens[i + 2:end]
            if len(args) == 3 and args[1].text == "," and args[2].kind == "string":
                target = identifier(args[0])
                member = zigtok.unescape(args[2].text[1:-1]).decode("utf-8")
                scope = scopes[i]
                while scope is not None and (scope, target) not in containers:
                    scope = parents[scope]
                if scope is not None and containers[scope, target] is not None:
                    opening = containers[scope, target]
                    close = zigtok.match_paren(tokens, opening)
                    depth = 0
                    for k in range(opening + 1, close):
                        if depth == 0 and words[k:k + 3] in (["pub", "fn", member],
                                                            ["pub", "const", member],
                                                            ["pub", "var", member]):
                            form = None
                            break
                        if zigtok.is_op(tokens[k], "{", "(", "["):
                            depth += 1
                        elif zigtok.is_op(tokens[k], "}", ")", "]"):
                            depth -= 1
        if form is not None:
            line = token.line + 1
            key = form, line
            if key not in seen:
                seen.add(key)
                yield form, line, {t.line + 1 for t in tokens[i:i + width]}, level
    for start, end, origin in bindings.accesses():
        if origin.kind == "std" and origin.parts == ("heap", "stackFallback"):
            line = tokens[start].line + 1
            if ("stackFallback", line) not in seen:
                seen.add(("stackFallback", line))
                yield "stackFallback", line, bindings.span(start, end, origin), "error"


@functools.lru_cache(maxsize=64)
def matches(text):
    return tuple(_matches(text))


def occurrences(text):
    lines = text.split("\n")
    return collections.Counter(
        (form, lines[line - 1].strip())
        for form, line, _, level in matches(text) if level == "error"
    )


def read_baseline(path):
    """Legacy generator's TSV columns: path, form, allowance, stripped exact line.

    A generated nonempty baseline must also bind the fork parent in a comment.
    That is needed to calculate the *remaining*, rather than original, allowance.
    """
    parent, rows = None, {}
    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        if line.startswith("# fork-parent: "):
            if parent is not None:
                raise ValueError("duplicate baseline fork parent")
            parent = line.removeprefix("# fork-parent: ").strip()
        elif line and not line.startswith("#"):
            name, form, allowance, exact = line.split("\t", 3)
            key = name, form, exact
            if form not in FAIL_FORMS or int(allowance) <= 0 or key in rows or not exact:
                raise ValueError(f"invalid baseline row {number}")
            rows[key] = int(allowance)
    if rows and (parent is None or len(parent) != 40 or any(c not in "0123456789abcdef" for c in parent)):
        raise ValueError("nonempty baseline requires a full fork-parent SHA")
    return parent, rows


def check_file(path, before, after, added, baseline, fork="", tip=None):
    base_counts, head_counts, fork_counts = map(occurrences, (before, after, fork))
    tip_counts = occurrences(tip) if tip is not None else base_counts
    lines, findings = after.split("\n"), []
    for form, line, span, level in matches(after):
        if not span.intersection(added):
            continue
        if level == "error":
            exact = lines[line - 1].strip()
            key = form, exact
            allowance = baseline.get((path, form, exact), 0)
            consumed = max(0, tip_counts[key] - fork_counts[key])
            remaining = max(0, allowance - consumed)
            projected = tip_counts[key] + head_counts[key] - base_counts[key]
            if projected <= tip_counts[key] + remaining:
                continue
        findings.append((path, line, level, form))
    return findings


def check(repo, base, head, baseline_path):
    parent, baseline = read_baseline(baseline_path)
    comparison = merge_base(repo, base, head)
    added = added_lines(repo, comparison, head)
    from lint_common import paths
    names = set(added)
    before = sources(repo, comparison, names & paths(repo, comparison))
    after = sources(repo, head, names)
    tip = sources(repo, base, names & paths(repo, base)) if base != comparison else before
    fork = sources(repo, parent, names & paths(repo, parent)) if baseline else {}
    findings = []
    for name in sorted(names):
        findings.extend(check_file(name, before.get(name, ""), after[name], added[name],
                                   baseline, fork.get(name, ""), tip.get(name, "")))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--baseline", type=Path, default=Path(__file__).with_name("zig017-lint-baseline.txt"))
    args = parser.parse_args()
    try:
        return emit("Zig 0.17 migration lint", check(args.repo, args.base, args.head, args.baseline))
    except (ValueError, OSError, IndexError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"lint input error ({type(error).__name__}); refusing to pass", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
