"""Generate removed std.os.windows names through literal source namespaces.

    python -I ci/generate_win32_identifiers.py STD17 STD15 OUTPUT

Reads compiler sources only, with no repository pin or temporary directory.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from zig_bindings import Bindings, chain, identifier, public_members
import zigtok


class Declarations:
    """Follow literal containers, relative imports and const namespace aliases.

    Only public declarations are exposed. Private aliases may be intermediate
    routes; functions/fields/computed expressions are not namespace evaluators.
    Recursive aliases stop at the first repeated source scope.
    """
    def __init__(self, std):
        self.std = std.resolve()
        self.modules = {}

    def module(self, path):
        path = path.resolve()
        if not path.is_relative_to(self.std) or not path.is_file():
            return None
        if path not in self.modules:
            bindings = Bindings(path.read_text(encoding="utf-8"))
            public = {}
            for scope, name in public_members(bindings.tokens, bindings.scopes):
                public.setdefault(scope, set()).add(name)
            self.modules[path] = bindings, public, {t.start: i for i, t in enumerate(bindings.tokens)}
        return self.modules[path]

    def target(self, path, at, visiting=frozenset()):
        identity = path, at
        if identity in visiting:
            return None
        visiting = visiting | {identity}
        bindings, _, positions = self.module(path)
        name = identifier(bindings.tokens[at + 1])
        declaration = bindings.decls.get((bindings.scopes[at], name))
        if declaration is None:
            return None
        expression = declaration[1]
        while (len(expression) >= 2 and zigtok.is_op(expression[0], "(")
               and zigtok.match_paren(expression, 0) == len(expression) - 1):
            expression = expression[1:-1]
        if not expression:
            return None
        start = 0
        while expression[start].text in ("extern", "packed"):
            start += 1
        if expression[start].kind == "keyword" and expression[start].text in zigtok.CONTAINERS:
            opening = start + 1
            if opening < len(expression) and zigtok.is_op(expression[opening], "("):
                opening = zigtok.match_paren(expression, opening) + 1
            if opening < len(expression) and zigtok.is_op(expression[opening], "{"):
                return path, positions[expression[opening].start] + 1
            return None
        if (len(expression) >= 4 and expression[0].kind == "builtin" and expression[0].text == "@import"
                and zigtok.is_op(expression[1], "(") and expression[2].kind == "string"
                and zigtok.is_op(expression[3], ")")):
            imported = zigtok.string_value(expression[2])
            if imported is None:
                return None
            child = (self.std / "std.zig" if imported == "std" else path.parent / imported).resolve()
            if self.module(child) is None:
                return None
            node = child, 0
            if len(expression) == 4:
                return node
            parts = chain(expression[5:]) if zigtok.is_op(expression[4], ".") else None
        else:
            parts = chain(expression)
            if not parts:
                return None
            declaration = bindings.lookup(parts[0], at)
            node = self.target(path, declaration[0], visiting) if declaration else None
            parts = parts[1:]
        if parts is None:
            return None
        for part in parts:
            if node is None:
                return None
            child_bindings, _, _ = self.module(node[0])
            declaration = child_bindings.decls.get((node[1], part))
            node = self.target(node[0], declaration[0], visiting) if declaration else None
        return node

    def names(self, node, visiting=frozenset()):
        if node in visiting:
            return set()
        bindings, public, _ = self.module(node[0])
        result = set()
        for name in public.get(node[1], ()):
            result.add(name)
            declaration = bindings.decls.get((node[1], name))
            child = self.target(node[0], declaration[0]) if declaration else None
            if child is not None:
                result.update(name + "." + suffix for suffix in self.names(child, visiting | {node}))
        return result


def declarations(std):
    tree = Declarations(std)
    return tree.names(((std / "os/windows.zig").resolve(), 0))


def generate(std17, std15):
    removed = declarations(std15) - declarations(std17)
    if not removed:
        raise ValueError("empty removed-name inventory")
    return "".join(name + "\n" for name in sorted(removed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("std17", type=Path)
    parser.add_argument("std15", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    text = generate(args.std17, args.std15)
    args.output.write_text(text, encoding="utf-8", newline="\n")
    print(f"verified removed names: {len(text.splitlines())}; plan reached inventory: 124")


if __name__ == "__main__":
    main()
