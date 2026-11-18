"""Linear bracket indexing and compact code-line spans for the literal lints."""

from bisect import bisect_left
from dataclasses import dataclass

import zigtok


def bracket_pairs(tokens):
    # Match each bracket kind independently, as zigtok.match_paren does. This
    # preserves its recovery behavior on the approved mechanical merge proxy.
    stacks, result = {"(": [], "[": [], "{": []}, {}
    closing = {")": "(", "]": "[", "}": "{"}
    for i, token in enumerate(tokens):
        if token.kind != "op":
            continue
        if token.text in stacks:
            stacks[token.text].append(i)
        elif token.text in closing:
            stack = stacks[closing[token.text]]
            if stack:
                result[stack.pop()] = i
    return result


def ungroup(tokens):
    pairs, start, end = bracket_pairs(tokens), 0, len(tokens)
    while start < end and zigtok.is_op(tokens[start], "(") and pairs.get(start) == end - 1:
        start, end = start + 1, end - 1
    return tokens[start:end]


@dataclass(frozen=True)
class CodeSpan:
    first: int
    last: int
    code_lines: frozenset

    def touches(self, sorted_added_code_lines):
        at = bisect_left(sorted_added_code_lines, self.first)
        return at < len(sorted_added_code_lines) and sorted_added_code_lines[at] <= self.last


def expression_spans(tokens, operators, code_lines):
    """Include both operands via their enclosing delimiter-separated expression.

    Nested groups keep their own segments, so a semicolon inside a block operand
    does not truncate its enclosing expression. Spans share the file's code-line
    set; deeply nested calls never allocate overlapping token suffixes.
    """
    frames, result = [[0, []]], {}

    def finish(frame, end):
        start, pending = frame
        if start < end:
            span = CodeSpan(tokens[start].line + 1, tokens[end - 1].line + 1, code_lines)
            for index in pending:
                result[index] = span

    for i, token in enumerate(tokens):
        if zigtok.is_op(token, "(", "[", "{"):
            frames.append([i + 1, []])
        elif zigtok.is_op(token, ")", "]", "}") and len(frames) > 1:
            finish(frames.pop(), i)
        elif zigtok.is_op(token, ";", ",", "=", "=>"):
            finish(frames[-1], i)
            frames[-1] = [i + 1, []]
        elif i in operators:
            frames[-1][1].append(i)
    for frame in frames:
        finish(frame, len(tokens))
    return result
