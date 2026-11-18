"""Operand positions in the Zig token stream, without evaluating types/values.

`**` is a prefix pointer type when an operand must begin, and binary array
repeat after a completed operand. Balanced frames distinguish control headers,
function parameters and type attributes from calls/groups and indexing. Names
in declarations, labels and captures do not complete operands.
"""

import zigtok


def binary_repeats(tokens):
    operand = True
    frames, repeats = [], set()
    pending, body_control, label = None, None, False
    declaration_names = {i + 1 for i in range(len(tokens)) if zigtok.declaration_at(tokens, i)}
    capture_end = -1
    for i, token in enumerate(tokens):
        if i <= capture_end:
            continue
        word = token.text
        if zigtok.payload_at(tokens, i):
            _, capture_end = zigtok.payload_names(tokens, i)
            operand = True
            continue
        if label and token.kind == "identifier":
            # The identifier of `break :name` is not its value expression.
            operand, label = True, False
            continue
        if zigtok.is_op(token, ":"):
            if i and tokens[i - 1].text in ("break", "continue"):
                label = True
            if body_control == "while" and i + 1 < len(tokens) and zigtok.is_op(tokens[i + 1], "("):
                pending = ("header", "while")  # continuation before the body
            operand = True
            continue
        if token.kind == "keyword":
            # These are grammar roles for balanced frames, not preceding-token
            # exceptions for **. Other keywords begin an operand or a prefix.
            if word in ("if", "while", "for", "switch"):
                pending = ("header", word)
            elif word == "fn":
                pending = ("signature", None)
            elif word in ("align", "addrspace", "callconv", "linksection"):
                pending = ("attribute", None)
            elif word in zigtok.CONTAINERS:
                pending = ("container", None)
            operand = word != "unreachable"
            body_control = None
            continue
        if token.kind in ("identifier", "builtin", "number", "string", "char", "mlstring"):
            # A named fn's name precedes its parameter frame; declaration names
            # likewise precede an annotation/initializer instead of a suffix.
            if i not in declaration_names and not (pending and pending[0] == "signature"):
                operand = False
            body_control = None
            continue
        if zigtok.is_op(token, "(", "[", "{"):
            if word == "(":
                role = pending or ("value", None)
            elif word == "[":
                role = ("array-type" if operand else "value", None)
            else:
                role = ("value", None)
            frames.append((word, role))
            pending, operand, body_control = None, True, None
            continue
        if zigtok.is_op(token, ")", "]", "}"):
            opening = {")": "(", "]": "[", "}": "{"}[word]
            if not frames or frames[-1][0] != opening:
                # This is a token lint, not syntax validation. The mechanical
                # 1A proxy contains a stray brace; resynchronize at the closer
                # and leave rejection of malformed Zig to the compiler.
                frames.clear()
                role, control = "value", None
                pending = None
            else:
                _, (role, control) = frames.pop()
            operand = role != "value"
            body_control = control if role == "header" else None
            continue
        if zigtok.is_op(token, "**"):
            if not operand:
                repeats.add(i)
            operand, body_control = True, None
        elif zigtok.is_op(token, ".*", ".?"):
            operand = False
        elif zigtok.is_op(token, "?") and i and zigtok.is_op(tokens[i - 1], "."):
            operand = False  # the tokenizer keeps postfix .? as two tokens
        else:
            operand = True
            if not zigtok.is_op(token, "."):
                body_control = None
    return repeats
