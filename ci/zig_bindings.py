"""Literal Zig access chains and lexical const aliases shared by both lints.

This deliberately does not evaluate computed expressions or container members.
"""

from dataclasses import dataclass, replace
import posixpath

import zigtok


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
    while len(tokens) >= 2 and zigtok.is_op(tokens[0], "(") and zigtok.match_paren(tokens, 0) == len(tokens) - 1:
        tokens = tokens[1:-1]
    if not tokens or tokens[0].kind != "identifier":
        return None
    result = [identifier(tokens[0])]
    for i in range(1, len(tokens), 2):
        if i + 1 >= len(tokens) or not zigtok.is_op(tokens[i], ".") or tokens[i + 1].kind != "identifier":
            return None
        result.append(identifier(tokens[i + 1]))
    return result


@dataclass(frozen=True)
class Origin:
    kind: str
    parts: tuple = ()
    declarations: frozenset = frozenset()


class Bindings:
    def __init__(self, text, reexports=None, path=""):
        self.tokens = zigtok.code(text)
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

    def lookup(self, name, at):
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
        elif kind == "os" and parts[:1] == ("windows",):
            kind, parts = "fork", parts[1:]
        if kind == "fork" and parts and parts[0] in self.reexports:
            kind, parts = "std", ("os", "windows") + tuple(self.reexports[parts[0]]) + parts[1:]
        return replace(origin, kind=kind, parts=parts)

    def imported(self, module):
        if module == "std":
            return Origin("std")
        target = posixpath.normpath(posixpath.join(posixpath.dirname(self.path), module))
        routes = {"src/os/windows.zig": "fork", "src/os/main.zig": "os",
                  "src/os.zig": "os", "src/apprt/win32.zig": "win32"}
        if target in routes:
            return Origin(routes[target])
        if not self.path:  # Isolated token controls have no containing source path.
            for suffix, kind in (("os/windows.zig", "fork"), ("os/main.zig", "os"),
                                 ("os.zig", "os"), ("win32.zig", "win32")):
                if module.endswith(suffix):
                    return Origin(kind)
        return None

    def expression(self, tokens, at, visiting=frozenset()):
        while len(tokens) >= 2 and zigtok.is_op(tokens[0], "(") and zigtok.match_paren(tokens, 0) == len(tokens) - 1:
            tokens = tokens[1:-1]
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
            if index in visiting:
                return None
            if index not in self.resolved:
                origin = self.expression(expression, index, visiting | {index})
                self.resolved[index] = (replace(origin, declarations=origin.declarations | {index})
                                        if origin else None)
            origin = self.resolved[index]
            return self.normalize(replace(origin, parts=origin.parts + tuple(parts[1:]))) if origin else None
        kinds = {"std": "std", "win32": "win32", "internal_os": "os", "os": "os"}
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

    def span(self, start, end, origin=None):
        result = {t.line + 1 for t in self.tokens[start:end]}
        if origin:
            for index in origin.declarations:
                result.update(t.line + 1 for t in self.tokens[index:self.ends[index] + 1])
        return result


def public_names(text):
    """Top-level pub const/var/fn names, including extern and inline functions."""
    tokens = zigtok.code(text)
    owners, _ = scopes(tokens)
    result = set()
    for i, token in enumerate(tokens):
        if owners[i] != 0 or token.kind != "keyword" or token.text != "pub":
            continue
        j = i + 1
        while j < len(tokens) and (tokens[j].text in ("extern", "inline", "noinline", "export", "threadlocal")
                                  or tokens[j].kind == "string"):
            j += 1
        if j + 1 < len(tokens) and tokens[j].text in ("const", "var", "fn") and tokens[j + 1].kind == "identifier":
            result.add(identifier(tokens[j + 1]))
    return result
