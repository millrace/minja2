"""Lexer: template -> segments, and expression text -> tokens.

Two stages. `tokenize_template` splits the source into literal-text, `{{ }}`
output, and `{% %}` statement segments (comments `{# #}` are discarded), applying
Jinja whitespace control: a `-` adjacent to a delimiter strips all `\\s` on that
side. `tokenize_expr` turns the inside of a tag into expression tokens.

Matches jinja2 defaults: `trim_blocks=False`, `lstrip_blocks=False`, and
`keep_trailing_newline=False` (a single trailing newline is dropped from the
source before lexing).
"""

from std.collections import List
from json import string_to_bytes, bytes_to_string, _b

# ── Template segments ─────────────────────────────────────────────────────────
comptime SEG_TEXT: UInt8 = 0
comptime SEG_OUTPUT: UInt8 = 1
comptime SEG_STMT: UInt8 = 2


struct Segment(Copyable, Movable, ImplicitlyCopyable):
    var kind: UInt8
    var text: String  # literal text, or the inner expression/statement source
    var line: Int

    def __init__(out self, kind: UInt8, var text: String, line: Int):
        self.kind = kind
        self.text = text^
        self.line = line


# Raw scan items (pre whitespace-strip); comments retained so their strip
# flags can act on neighboring text before being dropped.
comptime _RAW_TEXT: UInt8 = 0
comptime _RAW_OUTPUT: UInt8 = 1
comptime _RAW_STMT: UInt8 = 2
comptime _RAW_COMMENT: UInt8 = 3


struct _Raw(Copyable, Movable, ImplicitlyCopyable):
    var kind: UInt8
    var text: String
    var strip_before: Bool
    var strip_after: Bool
    var line: Int

    def __init__(
        out self,
        kind: UInt8,
        var text: String,
        strip_before: Bool,
        strip_after: Bool,
        line: Int,
    ):
        self.kind = kind
        self.text = text^
        self.strip_before = strip_before
        self.strip_after = strip_after
        self.line = line


def _is_ws(c: Int) -> Bool:
    return (
        c == 0x20
        or c == 0x09
        or c == 0x0A
        or c == 0x0D
        or c == 0x0C
        or c == 0x0B
    )


def _rstrip(b: List[UInt8]) -> String:
    var end = len(b)
    while end > 0 and _is_ws(Int(b[end - 1])):
        end -= 1
    return _take(b, 0, end)


def _lstrip(b: List[UInt8]) -> String:
    var start = 0
    while start < len(b) and _is_ws(Int(b[start])):
        start += 1
    return _take(b, start, len(b))


def _take(b: List[UInt8], start: Int, end: Int) -> String:
    var out = List[UInt8]()
    for k in range(start, end):
        out.append(b[k])
    return bytes_to_string(out^)


def _match2(b: List[UInt8], p: Int, c0: UInt8, c1: UInt8) -> Bool:
    return p + 1 < len(b) and b[p] == c0 and b[p + 1] == c1


def tokenize_template(source: String) raises -> List[Segment]:
    var b = string_to_bytes(source)
    # keep_trailing_newline=False: drop one trailing '\n'.
    if len(b) > 0 and b[len(b) - 1] == UInt8(0x0A):
        _ = b.pop()

    var raws = List[_Raw]()
    var n = len(b)
    var pos = 0
    var text_start = 0
    var line = 1

    while pos < n:
        var is_open = pos + 1 < n and b[pos] == _b("{") and (
            b[pos + 1] == _b("{")
            or b[pos + 1] == _b("%")
            or b[pos + 1] == _b("#")
        )
        if not is_open:
            if b[pos] == UInt8(0x0A):
                line += 1
            pos += 1
            continue

        # Flush preceding literal text (even if empty -> strip neighbor).
        raws.append(
            _Raw(_RAW_TEXT, _take(b, text_start, pos), False, False, line)
        )

        var marker = b[pos + 1]
        var strip_before = pos + 2 < n and b[pos + 2] == _b("-")
        var inner_start = pos + 2 + (1 if strip_before else 0)
        var open_line = line

        # locate the matching close delimiter
        var close0: UInt8
        if marker == _b("%"):
            close0 = _b("%")
        elif marker == _b("#"):
            close0 = _b("#")
        else:
            close0 = _b("}")

        var is_comment = marker == _b("#")
        var p = inner_start
        var in_str = False
        var quote: UInt8 = 0
        var inner_end = -1
        var strip_after = False
        var after = inner_start
        while p < n:
            var ch = b[p]
            if ch == UInt8(0x0A):
                line += 1
            if not is_comment and in_str:
                if ch == _b("\\"):
                    p += 2
                    continue
                if ch == quote:
                    in_str = False
                p += 1
                continue
            if not is_comment and (ch == _b('"') or ch == _b("'")):
                in_str = True
                quote = ch
                p += 1
                continue
            # check close (with optional '-' for strip_after)
            if ch == _b("-") and _match2(b, p + 1, close0, _b("}")):
                inner_end = p
                strip_after = True
                after = p + 3
                break
            if _match2(b, p, close0, _b("}")):
                inner_end = p
                after = p + 2
                break
            p += 1

        if inner_end < 0:
            raise Error(
                "unclosed tag at line " + String(open_line)
            )

        var inner = _take(b, inner_start, inner_end)
        var rkind = _RAW_OUTPUT
        if marker == _b("%"):
            rkind = _RAW_STMT
        elif marker == _b("#"):
            rkind = _RAW_COMMENT
        raws.append(
            _Raw(rkind, inner^, strip_before, strip_after, open_line)
        )
        pos = after
        text_start = after

    raws.append(_Raw(_RAW_TEXT, _take(b, text_start, n), False, False, line))

    # Apply whitespace control on neighboring text items.
    for i in range(len(raws)):
        if raws[i].kind == _RAW_TEXT:
            continue
        if raws[i].strip_before and i > 0 and raws[i - 1].kind == _RAW_TEXT:
            raws[i - 1].text = _rstrip(string_to_bytes(raws[i - 1].text))
        if (
            raws[i].strip_after
            and i + 1 < len(raws)
            and raws[i + 1].kind == _RAW_TEXT
        ):
            raws[i + 1].text = _lstrip(string_to_bytes(raws[i + 1].text))

    # Emit final segments (drop comments and empty text).
    var segs = List[Segment]()
    for i in range(len(raws)):
        var r = raws[i]
        if r.kind == _RAW_TEXT:
            if r.text.byte_length() > 0:
                segs.append(Segment(SEG_TEXT, r.text, r.line))
        elif r.kind == _RAW_OUTPUT:
            segs.append(Segment(SEG_OUTPUT, r.text, r.line))
        elif r.kind == _RAW_STMT:
            segs.append(Segment(SEG_STMT, r.text, r.line))
        # comments dropped
    return segs^


# ── Expression tokens ─────────────────────────────────────────────────────────
comptime T_NAME: UInt8 = 0
comptime T_INT: UInt8 = 1
comptime T_STR: UInt8 = 2
comptime T_OP: UInt8 = 3
comptime T_EOF: UInt8 = 4


struct ExprToken(Copyable, Movable, ImplicitlyCopyable):
    var kind: UInt8
    var sval: String
    var ival: Int
    var line: Int

    def __init__(out self, kind: UInt8, var sval: String, ival: Int, line: Int):
        self.kind = kind
        self.sval = sval^
        self.ival = ival
        self.line = line


def _is_alpha(c: Int) -> Bool:
    return (
        (c >= ord("a") and c <= ord("z"))
        or (c >= ord("A") and c <= ord("Z"))
        or c == ord("_")
    )


def _is_digit(c: Int) -> Bool:
    return c >= ord("0") and c <= ord("9")


def tokenize_expr(src: String, line: Int) raises -> List[ExprToken]:
    var b = string_to_bytes(src)
    var n = len(b)
    var p = 0
    var toks = List[ExprToken]()
    while p < n:
        var c = Int(b[p])
        if _is_ws(c):
            p += 1
            continue
        if _is_alpha(c):
            var start = p
            while p < n and (_is_alpha(Int(b[p])) or _is_digit(Int(b[p]))):
                p += 1
            toks.append(ExprToken(T_NAME, _take(b, start, p), 0, line))
            continue
        if _is_digit(c):
            var start = p
            while p < n and _is_digit(Int(b[p])):
                p += 1
            toks.append(
                ExprToken(T_INT, String(), atol(_take(b, start, p)), line)
            )
            continue
        if c == ord('"') or c == ord("'"):
            var quote = b[p]
            p += 1
            var out = List[UInt8]()
            while p < n and b[p] != quote:
                if b[p] == _b("\\"):
                    p += 1
                    var e = Int(b[p])
                    if e == ord("n"):
                        out.append(UInt8(0x0A))
                    elif e == ord("t"):
                        out.append(UInt8(0x09))
                    elif e == ord("r"):
                        out.append(UInt8(0x0D))
                    else:
                        out.append(b[p])  # \" \' \\ and any other
                    p += 1
                else:
                    out.append(b[p])
                    p += 1
            p += 1  # closing quote
            toks.append(ExprToken(T_STR, bytes_to_string(out^), 0, line))
            continue
        # operators
        if (
            _match2(b, p, _b("="), _b("="))
            or _match2(b, p, _b("!"), _b("="))
            or _match2(b, p, _b("<"), _b("="))
            or _match2(b, p, _b(">"), _b("="))
        ):
            toks.append(ExprToken(T_OP, _take(b, p, p + 2), 0, line))
            p += 2
            continue
        toks.append(ExprToken(T_OP, _take(b, p, p + 1), 0, line))
        p += 1
    toks.append(ExprToken(T_EOF, String(), 0, line))
    return toks^
