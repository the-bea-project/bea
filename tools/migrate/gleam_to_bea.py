#!/usr/bin/env python3
"""Mechanical Gleam -> Bea translation, used to migrate the compiler.

Bea's syntax is close to a superset of Gleam's expression syntax (it reads
`#(a, b)`, `[x, ..rest]`, `Ctor(..base, f: v)`, `&&`/`||`, labelled
arguments, `use`, `case`, bit arrays ... as Gleam does), so the translation
works on tokens and keeps the source text (comments, blank lines, layout)
everywhere else. Only what Bea spells differently is rewritten:

  * `fn name(` at the top level becomes `def name(`;
  * `let` and `let assert` are dropped (Bea decides which one a pattern
    needs; a refutable pattern gets `let assert` back);
  * `#{` inside a string literal is escaped as `\\#{` (Bea interpolates it);
  * a binary `-`/`-.` that starts a line outside brackets is joined to the
    previous line (in Bea such a line starts a new expression);
  * a function, variable or parameter named like a Bea keyword (`def`,
    `cond`, `return`, `and`, `or`, `not`) is an error to fix by hand, as is
    `let assert ... as "message"` (Bea has no message on assignments).

Everything else is kept as written. The output is meant to be run through
`bea format` afterwards, and then checked: compiled back to Gleam with the
trusted compiler and compared with the original (tools/migrate/check.sh).

Usage: gleam_to_bea.py IN.gleam OUT.bea
"""

import re
import sys

BEA_KEYWORDS = {"def", "cond", "return", "and", "or", "not"}

OPERATORS = sorted(
    [
        "<<", ">>", "<-", "->", "<>", "|>", "||", "&&", "==", "!=",
        "<=.", ">=.", "<.", ">.", "<=", ">=", "+.", "-.", "*.", "/.",
        "..", "=", "<", ">", "+", "-", "*", "/", "%", "!", "|", ".",
        ",", ":", "#", "(", ")", "[", "]", "{", "}", "@",
    ],
    key=len,
    reverse=True,
)

NUMBER = re.compile(
    r"0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+"
    r"|[0-9][0-9_]*(\.[0-9_]*([eE]-?[0-9_]+)?)?"
)
INT = re.compile(r"[0-9][0-9_]*")
NAME = re.compile(r"[a-z_][a-zA-Z0-9_]*")
UPNAME = re.compile(r"[A-Z][a-zA-Z0-9_]*")


class Token:
    __slots__ = ("kind", "text", "start", "line")

    def __init__(self, kind, text, start, line):
        self.kind = kind
        self.text = text
        self.start = start
        self.line = line

    def __repr__(self):
        return f"{self.kind}({self.text!r})@{self.line}"


class TranslationError(Exception):
    pass


def tokenize(src):
    tokens = []
    i = 0
    line = 1
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\n":
            tokens.append(Token("nl", c, i, line))
            line += 1
            i += 1
        elif c in " \t\r":
            j = i
            while j < n and src[j] in " \t\r":
                j += 1
            tokens.append(Token("ws", src[i:j], i, line))
            i = j
        elif src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            tokens.append(Token("comment", src[i:j], i, line))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            text = src[i : j + 1]
            tokens.append(Token("string", text, i, line))
            line += text.count("\n")
            i = j + 1
        elif c.isdigit():
            # `tuple.0.1` is two indexes, not a float.
            prev = significant_before(tokens, len(tokens))
            m = (INT if prev is not None and prev.text == "." else NUMBER).match(
                src, i
            )
            tokens.append(Token("number", m.group(0), i, line))
            i = m.end()
        elif NAME.match(src, i):
            m = NAME.match(src, i)
            tokens.append(Token("name", m.group(0), i, line))
            i = m.end()
        elif UPNAME.match(src, i):
            m = UPNAME.match(src, i)
            tokens.append(Token("upname", m.group(0), i, line))
            i = m.end()
        else:
            for op in OPERATORS:
                if src.startswith(op, i):
                    tokens.append(Token("op", op, i, line))
                    i += len(op)
                    break
            else:
                raise TranslationError(f"line {line}: unexpected character {c!r}")
    return tokens


def significant_before(tokens, index):
    """The last token before `index` that isn't whitespace or a comment."""
    for t in reversed(tokens[:index]):
        if t.kind not in ("ws", "nl", "comment"):
            return t
    return None


def next_significant(tokens, index):
    for j in range(index + 1, len(tokens)):
        if tokens[j].kind not in ("ws", "nl", "comment"):
            return j
    return None


def prev_significant(tokens, index):
    for j in range(index - 1, -1, -1):
        if tokens[j].kind not in ("ws", "nl", "comment"):
            return j
    return None


def ends_operand(t):
    return t.kind in ("name", "upname", "number", "string") or t.text in (
        ")",
        "]",
        "}",
        ">>",
    )


OPEN = {"(": ")", "[": "]", "{": "}", "<<": ">>"}
CLOSE = {v: k for k, v in OPEN.items()}


def translate(src, path="<input>"):
    tokens = tokenize(src)
    errors = []
    out = list(tokens)  # tokens are rewritten in place (text) or dropped (None)
    stack = []  # open brackets
    # Bracket depth before each token.
    depth = []
    for t in tokens:
        depth.append(list(stack))
        if t.kind == "op" and t.text in OPEN:
            stack.append(t.text)
        elif t.kind == "op" and t.text in CLOSE:
            if not stack or stack[-1] != CLOSE[t.text]:
                raise TranslationError(f"{path}:{t.line}: unbalanced {t.text!r}")
            stack.pop()

    def drop_with_space(i):
        out[i] = None
        if i + 1 < len(tokens) and tokens[i + 1].kind == "ws":
            out[i + 1] = None

    for i, t in enumerate(tokens):
        if out[i] is None:
            continue
        if t.kind == "name" and t.text == "fn" and depth[i] == []:
            j = next_significant(tokens, i)
            if j is not None and tokens[j].kind == "name":
                out[i] = Token("name", "def", t.start, t.line)
        elif t.kind == "name" and t.text == "let":
            j = next_significant(tokens, i)
            drop_with_space(i)
            if j is not None and tokens[j].text == "assert":
                drop_with_space(j)
                check_assert_message(tokens, j, depth, errors, path)
        elif t.kind == "string" and "#{" in t.text:
            out[i] = Token("string", t.text.replace("#{", "\\#{"), t.start, t.line)
        elif t.kind == "name" and t.text in BEA_KEYWORDS:
            p = prev_significant(tokens, i)
            n = next_significant(tokens, i)
            member = p is not None and tokens[p].text == "."
            label = n is not None and tokens[n].text == ":"
            if not (member or label):
                errors.append(
                    f"{path}:{t.line}: `{t.text}` is a Bea keyword; rename it"
                )
        elif t.kind == "op" and t.text in ("-", "-.") and (
            not depth[i] or depth[i][-1] == "{"
        ):
            p = prev_significant(tokens, i)
            starts_line = p is not None and any(
                tokens[k].kind == "nl" for k in range(p + 1, i)
            )
            if starts_line and ends_operand(tokens[p]):
                if any(tokens[k].kind == "comment" for k in range(p + 1, i)):
                    errors.append(
                        f"{path}:{t.line}: comment before a line-leading `{t.text}`"
                    )
                for k in range(p + 1, i):
                    out[k] = None
                out[p + 1] = Token("ws", " ", tokens[p + 1].start, tokens[p + 1].line)
    if errors:
        raise TranslationError("\n".join(errors))
    return "".join(t.text for t in out if t is not None)


CONTINUES = {
    "|>", "<>", "||", "&&", "==", "!=", "<", ">", "<=", ">=", "<.", ">.",
    "<=.", ">=.", "+", "-", "*", "/", "%", "+.", "-.", "*.", "/.", "as",
}


def check_assert_message(tokens, j, depth, errors, path):
    """`let assert P = e as "msg"` has no Bea equivalent with the same Gleam.

    `j` is the `assert` token. The statement ends at the first newline at
    its bracket depth that isn't followed by an operator continuing it; an
    `as` at that depth after the `=`, other than `panic as`/`todo as`, is a
    message.
    """
    level = depth[j]
    seen_eq = False
    for k in range(j + 1, len(tokens)):
        t = tokens[k]
        if len(depth[k]) < len(level):
            return
        if depth[k] != level:
            continue
        if t.kind == "nl":
            n = next_significant(tokens, k)
            if n is None or depth[n] != level or tokens[n].text not in CONTINUES:
                return
        elif t.text == "=":
            seen_eq = True
        elif seen_eq and t.kind == "name" and t.text == "as":
            p = prev_significant(tokens, k)
            if tokens[p].text not in ("panic", "todo"):
                errors.append(f"{path}:{t.line}: `let assert ... as` message")
            return


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = open(argv[1], encoding="utf-8").read()
    try:
        bea = translate(src, argv[1])
    except TranslationError as e:
        print(e, file=sys.stderr)
        return 1
    with open(argv[2], "w", encoding="utf-8") as f:
        f.write(bea)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
