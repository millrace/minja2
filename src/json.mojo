"""JSON parsing (context input) and `tojson` serialization.

`tojson` must be byte-identical to jinja2 3.1's `tojson` filter, which is
`json.dumps(sort_keys=True)` followed by jinja's HTML-safe escaping. Verified
behaviors replicated here:
  - keys sorted (codepoint order),
  - `ensure_ascii=True` (non-ASCII -> \\uXXXX, with surrogate pairs > U+FFFF),
  - HTML escaping of `< > & '` -> `\\u003c \\u003e \\u0026 \\u0027`,
  - separators `", "` / `": "` compact, or indented form when `indent` > 0.
"""

from std.collections import List, Optional
from value import (
    Value,
    VUNDEF,
    VNONE,
    VBOOL,
    VINT,
    VFLOAT,
    VSTR,
    VLIST,
    VMAP,
)


def _b(s: String) -> UInt8:
    """Single-byte literal as UInt8 (avoids implicit Int->UInt8 conversions)."""
    return UInt8(ord(s))


# ── UTF-8 helpers ─────────────────────────────────────────────────────────────
def _utf8_decode(b: List[UInt8], i: Int) -> Tuple[Int, Int]:
    """Decode one codepoint starting at byte `i`; return (codepoint, next_i)."""
    var c0 = Int(b[i])
    if c0 < 0x80:
        return (c0, i + 1)
    if c0 >> 5 == 0b110:
        var cp = (c0 & 0x1F) << 6 | (Int(b[i + 1]) & 0x3F)
        return (cp, i + 2)
    if c0 >> 4 == 0b1110:
        var cp = (c0 & 0x0F) << 12 | (Int(b[i + 1]) & 0x3F) << 6 | (
            Int(b[i + 2]) & 0x3F
        )
        return (cp, i + 3)
    var cp = (c0 & 0x07) << 18 | (Int(b[i + 1]) & 0x3F) << 12 | (
        Int(b[i + 2]) & 0x3F
    ) << 6 | (Int(b[i + 3]) & 0x3F)
    return (cp, i + 4)


def _utf8_encode(cp: Int, mut out: List[UInt8]):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def bytes_to_string(b: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def string_to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


# ── JSON parser ───────────────────────────────────────────────────────────────
struct _JsonParser(Copyable, Movable):
    var b: List[UInt8]
    var i: Int

    def __init__(out self, var b: List[UInt8]):
        self.b = b^
        self.i = 0

    def _skip_ws(mut self):
        while self.i < len(self.b):
            var ch = Int(self.b[self.i])
            if ch == 0x20 or ch == 0x09 or ch == 0x0A or ch == 0x0D:
                self.i += 1
            else:
                break

    def parse(mut self) raises -> Value:
        self._skip_ws()
        var v = self._value()
        self._skip_ws()
        return v

    def _value(mut self) raises -> Value:
        self._skip_ws()
        if self.i >= len(self.b):
            raise Error("unexpected end of JSON")
        var ch = Int(self.b[self.i])
        if ch == ord('"'):
            return Value.string(self._string())
        if ch == ord("{"):
            return self._object()
        if ch == ord("["):
            return self._array()
        if ch == ord("t"):
            self.i += 4
            return Value.bool(True)
        if ch == ord("f"):
            self.i += 5
            return Value.bool(False)
        if ch == ord("n"):
            self.i += 4
            return Value.none()
        return self._number()

    def _string(mut self) raises -> String:
        self.i += 1  # opening quote
        var out = List[UInt8]()
        while self.i < len(self.b):
            var ch = Int(self.b[self.i])
            if ch == ord('"'):
                self.i += 1
                return bytes_to_string(out)
            if ch == ord("\\"):
                self.i += 1
                var esc = Int(self.b[self.i])
                if esc == ord('"'):
                    out.append(_b('"'))
                elif esc == ord("\\"):
                    out.append(_b("\\"))
                elif esc == ord("/"):
                    out.append(_b("/"))
                elif esc == ord("n"):
                    out.append(UInt8(0x0A))
                elif esc == ord("t"):
                    out.append(UInt8(0x09))
                elif esc == ord("r"):
                    out.append(UInt8(0x0D))
                elif esc == ord("b"):
                    out.append(UInt8(0x08))
                elif esc == ord("f"):
                    out.append(UInt8(0x0C))
                elif esc == ord("u"):
                    var cp = self._hex4(self.i + 1)
                    self.i += 4
                    if cp >= 0xD800 and cp <= 0xDBFF:
                        var lo = self._hex4(self.i + 3)
                        self.i += 6
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    _utf8_encode(cp, out)
                self.i += 1
            else:
                out.append(self.b[self.i])
                self.i += 1
        raise Error("unterminated JSON string")

    def _hex4(self, at: Int) raises -> Int:
        var v = 0
        for k in range(at, at + 4):
            var ch = Int(self.b[k])
            v = v << 4
            if ch >= ord("0") and ch <= ord("9"):
                v += ch - ord("0")
            elif ch >= ord("a") and ch <= ord("f"):
                v += ch - ord("a") + 10
            elif ch >= ord("A") and ch <= ord("F"):
                v += ch - ord("A") + 10
        return v

    def _number(mut self) raises -> Value:
        var start = self.i
        var is_float = False
        while self.i < len(self.b):
            var ch = Int(self.b[self.i])
            if ch == ord("-") or ch == ord("+") or (
                ch >= ord("0") and ch <= ord("9")
            ):
                self.i += 1
            elif ch == ord(".") or ch == ord("e") or ch == ord("E"):
                is_float = True
                self.i += 1
            else:
                break
        var txt = bytes_to_string(_slice(self.b, start, self.i))
        if is_float:
            return Value.float(atof(txt))
        return Value.int(atol(txt))

    def _array(mut self) raises -> Value:
        self.i += 1  # [
        var v = Value.list()
        self._skip_ws()
        if self.i < len(self.b) and Int(self.b[self.i]) == ord("]"):
            self.i += 1
            return v
        while True:
            var elem = self._value()
            v.c[].vals.append(elem)
            self._skip_ws()
            var ch = Int(self.b[self.i])
            self.i += 1
            if ch == ord("]"):
                break
        return v

    def _object(mut self) raises -> Value:
        self.i += 1  # {
        var v = Value.mapping()
        self._skip_ws()
        if self.i < len(self.b) and Int(self.b[self.i]) == ord("}"):
            self.i += 1
            return v
        while True:
            self._skip_ws()
            var key = self._string()
            self._skip_ws()
            self.i += 1  # ':'
            var val = self._value()
            v.c[].keys.append(key)
            v.c[].vals.append(val)
            self._skip_ws()
            var ch = Int(self.b[self.i])
            self.i += 1
            if ch == ord("}"):
                break
        return v


def _slice(b: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(start, end):
        out.append(b[k])
    return out^


def parse_json(s: String) raises -> Value:
    var p = _JsonParser(string_to_bytes(s))
    return p.parse()


# ── tojson serializer ─────────────────────────────────────────────────────────
def _hex_digit(x: Int) -> UInt8:
    if x < 10:
        return UInt8(ord("0") + x)
    return UInt8(ord("a") + x - 10)


def _emit_u(cp: Int, mut out: List[UInt8]):
    out.append(_b("\\"))
    out.append(_b("u"))
    out.append(_hex_digit((cp >> 12) & 0xF))
    out.append(_hex_digit((cp >> 8) & 0xF))
    out.append(_hex_digit((cp >> 4) & 0xF))
    out.append(_hex_digit(cp & 0xF))


def _append_str(s: String, mut out: List[UInt8]):
    for byte in s.as_bytes():
        out.append(byte)


def _json_string(s: String, mut out: List[UInt8]):
    out.append(_b('"'))
    var bytes = string_to_bytes(s)
    var i = 0
    while i < len(bytes):
        var dec = _utf8_decode(bytes, i)
        var cp = dec[0]
        i = dec[1]
        if cp == ord('"'):
            out.append(_b("\\"))
            out.append(_b('"'))
        elif cp == ord("\\"):
            out.append(_b("\\"))
            out.append(_b("\\"))
        elif cp == 0x08:
            out.append(_b("\\"))
            out.append(_b("b"))
        elif cp == 0x09:
            out.append(_b("\\"))
            out.append(_b("t"))
        elif cp == 0x0A:
            out.append(_b("\\"))
            out.append(_b("n"))
        elif cp == 0x0C:
            out.append(_b("\\"))
            out.append(_b("f"))
        elif cp == 0x0D:
            out.append(_b("\\"))
            out.append(_b("r"))
        elif cp < 0x20:
            _emit_u(cp, out)
        elif cp == ord("<") or cp == ord(">") or cp == ord("&") or cp == ord(
            "'"
        ):
            _emit_u(cp, out)  # jinja HTML-safe escaping
        elif cp < 0x80:
            out.append(UInt8(cp))
        elif cp <= 0xFFFF:
            _emit_u(cp, out)  # ensure_ascii
        else:
            var v = cp - 0x10000
            _emit_u(0xD800 + (v >> 10), out)  # surrogate pair
            _emit_u(0xDC00 + (v & 0x3FF), out)
    out.append(_b('"'))


def _sorted_indices(keys: List[String]) -> List[Int]:
    var idx = List[Int]()
    for k in range(len(keys)):
        idx.append(k)
    # insertion sort by codepoint order (== UTF-8 byte order)
    for a in range(1, len(idx)):
        var cur = idx[a]
        var j = a - 1
        while j >= 0 and _str_gt(keys[idx[j]], keys[cur]):
            idx[j + 1] = idx[j]
            j -= 1
        idx[j + 1] = cur
    return idx^


def _str_gt(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = min(len(ab), len(bb))
    for k in range(n):
        if ab[k] != bb[k]:
            return ab[k] > bb[k]
    return len(ab) > len(bb)


def _indent_newline(indent: Int, level: Int, mut out: List[UInt8]):
    out.append(UInt8(0x0A))
    for _ in range(indent * level):
        out.append(UInt8(0x20))


def _to_json(v: Value, indent: Int, level: Int, mut out: List[UInt8]) raises:
    if v.tag == VSTR:
        _json_string(v.s, out)
    elif v.tag == VINT:
        _append_str(String(v.i), out)
    elif v.tag == VBOOL:
        _append_str("true" if v.b else "false", out)
    elif v.tag == VNONE or v.tag == VUNDEF:
        _append_str("null", out)
    elif v.tag == VFLOAT:
        _append_str(String(v.f), out)
    elif v.tag == VLIST:
        var n = len(v.c[].vals)
        if n == 0:
            out.append(_b("["))
            out.append(_b("]"))
            return
        out.append(_b("["))
        for k in range(n):
            if k > 0:
                out.append(_b(","))
                if indent == 0:
                    out.append(UInt8(0x20))
            if indent > 0:
                _indent_newline(indent, level + 1, out)
            _to_json(v.c[].vals[k], indent, level + 1, out)
        if indent > 0:
            _indent_newline(indent, level, out)
        out.append(_b("]"))
    elif v.tag == VMAP:
        var n = len(v.c[].keys)
        if n == 0:
            out.append(_b("{"))
            out.append(_b("}"))
            return
        var order = _sorted_indices(v.c[].keys)
        out.append(_b("{"))
        for k in range(n):
            if k > 0:
                out.append(_b(","))
                if indent == 0:
                    out.append(UInt8(0x20))
            if indent > 0:
                _indent_newline(indent, level + 1, out)
            _json_string(v.c[].keys[order[k]], out)
            out.append(_b(":"))
            out.append(UInt8(0x20))
            _to_json(v.c[].vals[order[k]], indent, level + 1, out)
        if indent > 0:
            _indent_newline(indent, level, out)
        out.append(_b("}"))


def to_json(v: Value, indent: Int) raises -> String:
    var out = List[UInt8]()
    _to_json(v, indent, 0, out)
    return bytes_to_string(out)
