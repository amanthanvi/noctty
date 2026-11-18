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


def import_path(path):
    """Canonical relative file spelling for this Windows-only fork.

    Zig 0.15.2 also accepts case variants and a single trailing directory dot.
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


class Bindings:
    def __init__(self, text, reexports=None, path=""):
        self.tokens = zigtok.code(text)
        self.reexports, self.path = reexports or {}, path
        self.scopes, self.parents = scopes(self.tokens)
        self.decls, self.ends, self.resolved = {}, {}, {}
        self.previous, self.changed_exports = None, frozenset()
        self.scope_keys, self.declaration_keys, self.changed_declarations = None, None, {}
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
            origin = replace(origin, exports=origin.exports | {parts[0]})
            kind, parts = "std", tuple(self.reexports[parts[0]]) + parts[1:]
        return replace(origin, kind=kind, parts=parts)

    def imported(self, module):
        if module == "std":
            return Origin("std")
        module = import_path(module)
        target = import_path(posixpath.join(posixpath.dirname(import_path(self.path)), module))
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

    def stable_declarations(self):
        """Match declaration names within lexical owners, independent of lines.

        Named functions/containers/labels keep their names when moved. Unnamed
        sibling blocks use their token header and ordinal within the parent.
        """
        if self.declaration_keys is not None:
            return self.declaration_keys
        functions = zigtok.functions_of_tokens(self.tokens)
        named = {f["body"][0] + 1: (f["kind"], f["name"])
                 for f in functions if f["body"]}
        for container in zigtok.containers_of_tokens(self.tokens, functions):
            if container["naming"] == "declaration":
                named[container["open"] + 1] = ("container", container["name"])
        keys, siblings = {0: ()}, {}
        for scope, parent in self.parents.items():
            if parent is None:
                continue
            opening = scope - 1
            if opening >= 2 and zigtok.is_op(self.tokens[opening - 1], ":"):
                label = ("label", identifier(self.tokens[opening - 2]))
            elif scope in named:
                label = named[scope]
            else:
                start = opening - 1
                while start >= 0 and not zigtok.is_op(self.tokens[start], "{", "}", ";"):
                    start -= 1
                label = ("block", tuple((t.kind, t.text) for t in self.tokens[start + 1:opening]))
            sibling = parent, label
            ordinal = siblings.get(sibling, 0)
            siblings[sibling] = ordinal + 1
            keys[scope] = keys[parent] + ((label, ordinal),)
        self.scope_keys = keys
        self.declaration_keys = {(keys[scope], name): at
                                 for (scope, name), (at, _) in self.decls.items()}
        return self.declaration_keys

    def declaration_changed(self, index):
        if self.previous is None:
            return True
        if index not in self.changed_declarations:
            self.stable_declarations()
            key = self.scope_keys[self.scopes[index]], identifier(self.tokens[index + 1])
            prior = self.previous.stable_declarations().get(key)
            current = self.resolve([key[1]], index)
            old = self.previous.resolve([key[1]], prior) if prior is not None else None
            def binding_origin(origin):
                return (origin.kind, origin.parts) if origin else None
            self.changed_declarations[index] = binding_origin(current) != binding_origin(old)
        return self.changed_declarations[index]

    def span(self, start, end, origin=None):
        result = {t.line + 1 for t in self.tokens[start:end]}
        if origin:
            for index in origin.declarations:
                if self.declaration_changed(index):
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
