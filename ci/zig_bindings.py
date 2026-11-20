"""Literal Zig access chains and lexical const aliases shared by both lints.

This deliberately does not evaluate computed expressions or container members.
"""

from dataclasses import dataclass, replace
from bisect import bisect_left, bisect_right
import posixpath

import zigtok
from zig_spans import bracket_pairs, ungroup


def identifier(token):
    if token.kind == "identifier" and token.text.startswith('@"'):
        return zigtok.unescape(token.text[2:-1]).decode("utf-8")
    return token.text


def scopes(tokens):
    owners, parents, stack = [], {0: None}, [0]
    for i, token in enumerate(tokens):
        owners.append(stack[-1])
        if zigtok.is_op(token, "{"):
            parents[i + 1] = stack[-1]
            stack.append(i + 1)
        elif zigtok.is_op(token, "}") and len(stack) > 1:
            stack.pop()
    return owners, parents


def chain(tokens):
    tokens = ungroup(tokens)
    if not tokens or tokens[0].kind != "identifier":
        return None
    result = [identifier(tokens[0])]
    for i in range(1, len(tokens), 2):
        if i + 1 >= len(tokens) or not zigtok.is_op(tokens[i], ".") or tokens[i + 1].kind != "identifier":
            return None
        result.append(identifier(tokens[i + 1]))
    return result


def import_path(path):
    """Canonical relative file spelling for this Windows-only fork.

    Zig 0.15.2 accepts case variants. A single trailing directory dot works only
    in some cwd layouts; retain recognition as a conservative over-report.
    Keep filename suffixes, spaces and repeated trailing dots intact: native
    controls reject those spellings.
    """
    parts = path.replace("\\", "/").split("/")
    for i, part in enumerate(parts[:-1]):
        if part not in (".", "..") and part.endswith(".") and not part.endswith(".."):
            parts[i] = part[:-1]
    return posixpath.normpath("/".join(parts)).casefold()


@dataclass(frozen=True)
class Origin:
    kind: str
    parts: tuple = ()
    declarations: frozenset = frozenset()
    exports: frozenset = frozenset()


def parameter_ranges(tokens, brackets):
    """Indexed named-function signatures, with compact per-name scope ranges.

    Bracket jumps avoid rescanning nested parameters, return types and bodies.
    A labeled return-type block precedes the true function body. Overlapping
    scopes for the same name merge without expanding signatures token by token.
    """
    reverse = {end: start for start, end in brackets.items()}
    result, length = {}, len(tokens)
    for at, token in enumerate(tokens):
        if (token.text != "fn" or token.kind != "keyword" or at + 2 >= length
                or tokens[at + 1].kind != "identifier" or not zigtok.is_op(tokens[at + 2], "(")):
            continue
        opening = at + 2
        closing = brackets.get(opening)
        if closing is None:
            continue
        names, cursor = set(), opening + 1
        while cursor < closing:
            current = tokens[cursor]
            if zigtok.is_op(current, "(", "[", "{"):
                cursor = brackets.get(cursor, closing) + 1
                continue
            if zigtok.is_op(current, ":") and tokens[cursor - 1].kind == "identifier":
                names.add(identifier(tokens[cursor - 1]))
            cursor += 1
        if not names:
            continue
        cursor, body = closing + 1, None
        while cursor < length:
            current = tokens[cursor]
            if (current.kind == "keyword" and current.text == "fn" and cursor + 1 < length
                    and tokens[cursor + 1].kind == "identifier"):
                break  # a new declaration, not the missing body of this one
            if zigtok.is_op(current, ";", ",", "=", "}", ")", "]"):
                break
            if zigtok.is_op(current, "(", "["):
                cursor = brackets.get(cursor, length) + 1
                continue
            if zigtok.is_op(current, "{"):
                previous = tokens[cursor - 1]
                type_brace = (previous.kind == "keyword" and previous.text in ("error", *zigtok.CONTAINERS))
                type_brace |= (zigtok.is_op(previous, ":") and cursor >= 2
                               and tokens[cursor - 2].kind == "identifier")
                if zigtok.is_op(previous, ")"):
                    start = reverse.get(cursor - 1)
                    type_brace |= (start is not None and start > 0
                                   and tokens[start - 1].text in (*zigtok.CONTAINERS, "switch"))
                if type_brace:
                    cursor = brackets.get(cursor, length) + 1
                    continue
                body = cursor
                break
            cursor += 1
        if body is None:
            continue
        end = brackets.get(body, length - 1)
        for name in names:
            ranges = result.setdefault(name, [])
            if ranges and opening + 1 <= ranges[-1][1] + 1:
                ranges[-1] = ranges[-1][0], max(ranges[-1][1], end)
            else:
                ranges.append((opening + 1, end))
    return result


class Bindings:
    def __init__(self, text, reexports=None, path=""):
        self.tokens = zigtok.code(text)
        self.brackets = bracket_pairs(self.tokens)
        self.reexports, self.path = reexports or {}, path
        self.scopes, self.parents = scopes(self.tokens)
        self.decls, self.ends, self.resolved = {}, {}, {}
        for i, token in enumerate(self.tokens):
            if not zigtok.declaration_at(self.tokens, i):
                continue
            end, depth, equals = i + 2, 0, None
            while end < len(self.tokens):
                current = self.tokens[end]
                if depth == 0 and zigtok.is_op(current, ";"):
                    break
                if depth == 0 and zigtok.is_op(current, "="):
                    equals = end
                if zigtok.is_op(current, "(", "[", "{"):
                    depth += 1
                elif zigtok.is_op(current, ")", "]", "}"):
                    if depth == 0:
                        break
                    depth -= 1
                end += 1
            if equals is not None:
                self.decls[self.scopes[i], identifier(self.tokens[i + 1])] = (i, self.tokens[equals + 1:end])
                self.ends[i] = end
        self.parameter_ranges = parameter_ranges(self.tokens, self.brackets)
        self.declaration_names = {name for _, name in self.decls}

    def lookup(self, name, at):
        ranges = self.parameter_ranges.get(name, ())
        position = bisect_right(ranges, (at, len(self.tokens))) - 1
        if position >= 0 and at <= ranges[position][1]:
            return None, ()
        if name not in self.declaration_names:
            return None
        scope = self.scopes[at]
        while scope is not None:
            if (scope, name) in self.decls:
                return self.decls[scope, name]
            scope = self.parents[scope]
        return None

    def normalize(self, origin):
        kind, parts = origin.kind, origin.parts
        if kind == "win32" and parts[:1] == ("windows",):
            kind, parts = "std", ("os", "windows") + parts[1:]
        elif kind == "win32" and parts[:1] == ("sys",):
            kind, parts = "native", parts[1:]
        elif kind == "os" and parts[:1] == ("windows",):
            kind, parts = "fork", parts[1:]
        if kind == "fork" and parts and parts[0] in self.reexports:
            origin = replace(origin, exports=origin.exports | {parts[0]})
            kind, parts = "std", tuple(self.reexports[parts[0]]) + parts[1:]
        return replace(origin, kind=kind, parts=parts)

    def imported(self, module):
        if module == "std":
            return Origin("std")
        module = import_path(module)
        target = import_path(posixpath.join(posixpath.dirname(import_path(self.path)), module))
        routes = {"src/os/windows.zig": "fork", "src/os/main.zig": "os",
                  "src/os.zig": "os", "src/apprt/win32.zig": "win32",
                  "src/apprt/win32/sys.zig": "native", "src/apprt/win32_types.zig": "native"}
        if target in routes:
            return Origin(routes[target])
        if not self.path:  # Isolated token controls have no containing source path.
            for suffix, kind in (("win32/sys.zig", "native"), ("win32_types.zig", "native"),
                                 ("os/windows.zig", "fork"), ("os/main.zig", "os"),
                                 ("os.zig", "os"), ("win32.zig", "win32")):
                if module.endswith(suffix):
                    return Origin(kind)
        return None

    def expression(self, tokens, at, visiting=frozenset()):
        tokens = ungroup(tokens)
        if not tokens:
            return None
        if (len(tokens) >= 4 and tokens[0].kind == "builtin" and tokens[0].text == "@import"
                and zigtok.is_op(tokens[1], "(") and tokens[2].kind == "string"
                and zigtok.is_op(tokens[3], ")")):
            origin = self.imported(zigtok.unescape(tokens[2].text[1:-1]).decode("utf-8"))
            if origin is None:
                return None
            if len(tokens) == 4:
                return origin
            tail = chain(tokens[5:]) if zigtok.is_op(tokens[4], ".") else None
            return self.normalize(replace(origin, parts=tuple(tail))) if tail else None
        parts = chain(tokens)
        return self.resolve(parts, at, visiting) if parts else None

    def resolve(self, parts, at, visiting=frozenset()):
        decl = self.lookup(parts[0], at)
        if decl:
            index, expression = decl
            if index is None:
                return None
            if index in visiting:
                return None
            if index not in self.resolved:
                origin = self.expression(expression, index, visiting | {index})
                self.resolved[index] = (replace(origin, declarations=origin.declarations | {index})
                                        if origin else None)
            origin = self.resolved[index]
            return self.normalize(replace(origin, parts=origin.parts + tuple(parts[1:]))) if origin else None
        kinds = {"std": "std", "win32": "win32", "internal_os": "os", "os": "os"}
        if parts[0] == "windows" and self.path == "src/os/windows.zig":
            return Origin("std", ("os", "windows") + tuple(parts[1:]))
        kind = kinds.get(parts[0])
        return self.normalize(Origin(kind, tuple(parts[1:]))) if kind else None

    def accesses(self):
        for i, token in enumerate(self.tokens):
            if i and zigtok.is_op(self.tokens[i - 1], "."):
                continue
            if i and (zigtok.declaration_at(self.tokens, i - 1) or self.tokens[i - 1].text == "fn"):
                continue
            if token.kind == "identifier":
                end = i + 1
            elif (token.kind == "builtin" and token.text == "@import" and i + 3 < len(self.tokens)
                  and zigtok.is_op(self.tokens[i + 1], "(") and self.tokens[i + 2].kind == "string"
                  and zigtok.is_op(self.tokens[i + 3], ")")):
                end = i + 4
            else:
                continue
            while end + 1 < len(self.tokens) and zigtok.is_op(self.tokens[end], ".") and self.tokens[end + 1].kind == "identifier":
                end += 2
            origin = self.expression(self.tokens[i:end], i)
            if origin:
                yield i, end, origin

    def definition_lines(self, index):
        start = index
        while start:
            token = self.tokens[start - 1]
            if token.kind == "keyword" and token.text in ("pub", "export", "extern", "threadlocal", "comptime"):
                start -= 1
            elif (token.kind == "string" and start >= 2
                    and self.tokens[start - 2].text == "extern"):
                start -= 2
            else:
                break
        return (self.tokens[start].line + 1,
                self.tokens[min(self.ends[index], len(self.tokens) - 1)].line + 1)

    def changed_aliases(self, added, deleted):
        """Head definitions touched by added lines or interior deletion gaps.

        Gap p lies after head line p and before p+1. A definition on lines
        first..last contains gaps first..last-1 between its own lines.
        """
        added, deleted = sorted(added), sorted(deleted)
        changed = set()
        for index in self.ends:
            first, last = self.definition_lines(index)
            at = bisect_left(added, first)
            gap = bisect_left(deleted, first)
            if ((at < len(added) and added[at] <= last)
                    or (gap < len(deleted) and deleted[gap] <= last - 1)):
                changed.add(index)
        return frozenset(changed)

    def span(self, start, end, origin=None):
        result = {t.line + 1 for t in self.tokens[start:end]}
        if origin:
            for index in origin.declarations:
                result.update(t.line + 1 for t in self.tokens[index:self.ends[index] + 1])
        return result


def public_members(tokens, owners):
    """Public declaration names and their lexical scopes (not enum fields)."""
    for i, token in enumerate(tokens):
        if token.kind != "keyword" or token.text != "pub":
            continue
        j = i + 1
        while j < len(tokens) and (tokens[j].text in ("extern", "inline", "noinline", "export", "threadlocal")
                                  or tokens[j].kind == "string"):
            j += 1
        if j + 1 < len(tokens) and tokens[j].text in ("const", "var", "fn") and tokens[j + 1].kind == "identifier":
            yield owners[i], identifier(tokens[j + 1])


def public_names(text):
    """Top-level pub const/var/fn names, including extern and inline functions."""
    tokens = zigtok.code(text)
    owners, _ = scopes(tokens)
    return {name for scope, name in public_members(tokens, owners) if scope == 0}
