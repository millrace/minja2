"""minja2 value model + helpers.

`Value` is a tagged union covering the type model required by the chat-template
surface (requirements §5.3): undefined, none, bool, int, float, string, list,
mapping, and host-callable. Containers (list / mapping) are held behind an
`ArcPointer` so that copying a `Value` shares the underlying storage — this is
what makes `namespace()` mutation (`{%- set ns.x = ... %}`) visible after the
loop body it was written in.
"""

from std.collections import List, Dict, Optional
from std.memory import ArcPointer

# ── Value tags ────────────────────────────────────────────────────────────────
comptime VUNDEF: UInt8 = 0
comptime VNONE: UInt8 = 1
comptime VBOOL: UInt8 = 2
comptime VINT: UInt8 = 3
comptime VFLOAT: UInt8 = 4
comptime VSTR: UInt8 = 5
comptime VLIST: UInt8 = 6
comptime VMAP: UInt8 = 7
comptime VCALL: UInt8 = 8


struct Container(Copyable, Movable):
    """Backing storage shared by list and mapping `Value`s.

    For a list, `vals` holds the elements and `keys` is empty. For a mapping,
    `keys` and `vals` are parallel and ordered by insertion; `tojson` re-sorts
    independently.
    """

    var keys: List[String]
    var vals: List[Value]

    def __init__(out self):
        self.keys = List[String]()
        self.vals = List[Value]()


def _empty() -> ArcPointer[Container]:
    return ArcPointer[Container](Container())


struct Value(Copyable, Movable, ImplicitlyCopyable):
    var tag: UInt8
    var b: Bool
    var i: Int
    var f: Float64
    var s: String
    var c: ArcPointer[Container]
    # `safe` marks a string as jinja `Markup` (e.g. `tojson` output). Concatenating
    # a Markup with a plain string HTML-escapes the plain side — see eval `+`.
    var safe: Bool

    # Scalar constructors -------------------------------------------------------
    def __init__(out self):
        self.tag = VUNDEF
        self.b = False
        self.i = 0
        self.f = 0.0
        self.s = String()
        self.c = _empty()
        self.safe = False

    @staticmethod
    def safe_string(var x: String) -> Value:
        var v = Value()
        v.tag = VSTR
        v.s = x^
        v.safe = True
        return v

    @staticmethod
    def undef() -> Value:
        return Value()

    @staticmethod
    def none() -> Value:
        var v = Value()
        v.tag = VNONE
        return v

    @staticmethod
    def bool(x: Bool) -> Value:
        var v = Value()
        v.tag = VBOOL
        v.b = x
        return v

    @staticmethod
    def int(x: Int) -> Value:
        var v = Value()
        v.tag = VINT
        v.i = x
        return v

    @staticmethod
    def float(x: Float64) -> Value:
        var v = Value()
        v.tag = VFLOAT
        v.f = x
        return v

    @staticmethod
    def string(var x: String) -> Value:
        var v = Value()
        v.tag = VSTR
        v.s = x^
        return v

    @staticmethod
    def callable(var name: String) -> Value:
        var v = Value()
        v.tag = VCALL
        v.s = name^
        return v

    @staticmethod
    def list() -> Value:
        var v = Value()
        v.tag = VLIST
        return v

    @staticmethod
    def list_of(var items: List[Value]) -> Value:
        var v = Value()
        v.tag = VLIST
        v.c[].vals = items^
        return v

    @staticmethod
    def mapping() -> Value:
        var v = Value()
        v.tag = VMAP
        return v

    # Predicates ----------------------------------------------------------------
    def is_undef(self) -> Bool:
        return self.tag == VUNDEF

    def is_none(self) -> Bool:
        return self.tag == VNONE

    def type_name(self) -> String:
        if self.tag == VUNDEF:
            return "undefined"
        if self.tag == VNONE:
            return "none"
        if self.tag == VBOOL:
            return "bool"
        if self.tag == VINT:
            return "int"
        if self.tag == VFLOAT:
            return "float"
        if self.tag == VSTR:
            return "str"
        if self.tag == VLIST:
            return "list"
        if self.tag == VMAP:
            return "mapping"
        return "callable"

    # Python truthiness (requirements §3) ---------------------------------------
    def truthy(self) -> Bool:
        if self.tag == VUNDEF or self.tag == VNONE:
            return False
        if self.tag == VBOOL:
            return self.b
        if self.tag == VINT:
            return self.i != 0
        if self.tag == VFLOAT:
            return self.f != 0.0
        if self.tag == VSTR:
            return self.s.byte_length() != 0
        if self.tag == VLIST:
            return len(self.c[].vals) != 0
        if self.tag == VMAP:
            return len(self.c[].keys) != 0
        return True  # callable is truthy

    # Mapping helpers -----------------------------------------------------------
    def map_get(self, key: String) -> Optional[Value]:
        for idx in range(len(self.c[].keys)):
            if self.c[].keys[idx] == key:
                return Optional[Value](self.c[].vals[idx])
        return Optional[Value]()

    def map_has(self, key: String) -> Bool:
        for idx in range(len(self.c[].keys)):
            if self.c[].keys[idx] == key:
                return True
        return False

    def map_set(mut self, key: String, var val: Value):
        for idx in range(len(self.c[].keys)):
            if self.c[].keys[idx] == key:
                self.c[].vals[idx] = val^
                return
        self.c[].keys.append(key)
        self.c[].vals.append(val^)

    # Output stringification — Python str() semantics ---------------------------
    def to_output(self) raises -> String:
        if self.tag == VSTR:
            return self.s
        if self.tag == VINT:
            return String(self.i)
        if self.tag == VBOOL:
            return "True" if self.b else "False"
        if self.tag == VNONE:
            return "None"
        if self.tag == VFLOAT:
            return _format_float(self.f)
        if self.tag == VUNDEF:
            raise Error("undefined value rendered")
        return self.py_repr()

    def py_repr(self) raises -> String:
        if self.tag == VSTR:
            return "'" + self.s + "'"
        if self.tag == VINT:
            return String(self.i)
        if self.tag == VBOOL:
            return "True" if self.b else "False"
        if self.tag == VNONE:
            return "None"
        if self.tag == VFLOAT:
            return _format_float(self.f)
        if self.tag == VLIST:
            var out = String("[")
            for idx in range(len(self.c[].vals)):
                if idx > 0:
                    out += ", "
                out += self.c[].vals[idx].py_repr()
            out += "]"
            return out
        if self.tag == VMAP:
            var out = String("{")
            for idx in range(len(self.c[].keys)):
                if idx > 0:
                    out += ", "
                out += "'" + self.c[].keys[idx] + "': "
                out += self.c[].vals[idx].py_repr()
            out += "}"
            return out
        return "<callable>"


def _format_float(x: Float64) -> String:
    # Best-effort match for Python repr of common floats (e.g. 1.0, 0.5).
    return String(x)


# ── Deep equality (Python ==) ───────────────────────────────────────────────
def values_equal(a: Value, b: Value) -> Bool:
    # Numeric cross-type equality (Python: 1 == 1.0, True == 1)
    if _is_number(a) and _is_number(b):
        return _as_float(a) == _as_float(b)
    if a.tag != b.tag:
        return False
    if a.tag == VUNDEF or a.tag == VNONE:
        return True
    if a.tag == VBOOL:
        return a.b == b.b
    if a.tag == VSTR:
        return a.s == b.s
    if a.tag == VCALL:
        return a.s == b.s
    if a.tag == VLIST:
        if len(a.c[].vals) != len(b.c[].vals):
            return False
        for idx in range(len(a.c[].vals)):
            if not values_equal(a.c[].vals[idx], b.c[].vals[idx]):
                return False
        return True
    if a.tag == VMAP:
        if len(a.c[].keys) != len(b.c[].keys):
            return False
        for idx in range(len(a.c[].keys)):
            var k = a.c[].keys[idx]
            var bv = b.map_get(k)
            if not bv:
                return False
            if not values_equal(a.c[].vals[idx], bv.value()):
                return False
        return True
    return False


def _is_number(v: Value) -> Bool:
    return v.tag == VINT or v.tag == VFLOAT or v.tag == VBOOL


def _as_float(v: Value) -> Float64:
    if v.tag == VINT:
        return Float64(v.i)
    if v.tag == VBOOL:
        return 1.0 if v.b else 0.0
    return v.f
