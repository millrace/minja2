"""Tree-walking evaluator with StrictUndefined semantics.

Scoping model (matches jinja for the corpus): a `for` body gets a fresh frame
per iteration, so plain `set` inside a loop does not escape it (hence the
`namespace()` idiom); `if` is transparent (no frame). Undefined raises on any
use except as a test operand (`is X`) or the container of `in` — exactly what
StrictUndefined does. `raise_exception` is surfaced via `env.user_error` so the
caller can distinguish template-authored validation from internal errors.
"""

from std.collections import List, Optional
from value import (
    Value,
    values_equal,
    VUNDEF,
    VNONE,
    VBOOL,
    VINT,
    VFLOAT,
    VSTR,
    VLIST,
    VMAP,
    VCALL,
)
from ast import (
    ExprNode,
    StmtNode,
    E_INT,
    E_STR,
    E_BOOL,
    E_NONE,
    E_NAME,
    E_ATTR,
    E_SUBSCRIPT,
    E_SLICE,
    E_UNARY,
    E_BINOP,
    E_CALL,
    E_FILTER,
    E_TEST,
    S_TEXT,
    S_OUTPUT,
    S_IF,
    S_FOR,
    S_SET,
    S_SETATTR,
)
from json import to_json, string_to_bytes, bytes_to_string, _utf8_decode, _utf8_encode
from strftime import strftime_utc


struct Frame(Copyable, Movable):
    var names: List[String]
    var vals: List[Value]

    def __init__(out self):
        self.names = List[String]()
        self.vals = List[Value]()


struct Env(Movable):
    var scopes: List[Frame]
    var out: List[UInt8]
    var now_epoch: Int
    var user_error: Bool
    var user_msg: String

    def __init__(out self, now_epoch: Int):
        self.scopes = List[Frame]()
        self.scopes.append(Frame())
        self.out = List[UInt8]()
        self.now_epoch = now_epoch
        self.user_error = False
        self.user_msg = String()

    def push(mut self):
        self.scopes.append(Frame())

    def pop(mut self):
        _ = self.scopes.pop()

    def set_local(mut self, name: String, var val: Value):
        var idx = len(self.scopes) - 1
        for k in range(len(self.scopes[idx].names)):
            if self.scopes[idx].names[k] == name:
                self.scopes[idx].vals[k] = val^
                return
        self.scopes[idx].names.append(name)
        self.scopes[idx].vals.append(val^)

    def get(self, name: String) -> Optional[Value]:
        var s = len(self.scopes) - 1
        while s >= 0:
            for k in range(len(self.scopes[s].names)):
                if self.scopes[s].names[k] == name:
                    return Optional[Value](self.scopes[s].vals[k])
            s -= 1
        return Optional[Value]()

    def emit(mut self, s: String):
        for byte in s.as_bytes():
            self.out.append(byte)


def _is_global_callable(name: String) -> Bool:
    return (
        name == "raise_exception"
        or name == "strftime_now"
        or name == "namespace"
    )


def _req(v: Value) raises -> Value:
    if v.is_undef():
        raise Error("undefined value used in expression")
    return v


def _is_num(v: Value) -> Bool:
    return v.tag == VINT or v.tag == VFLOAT or v.tag == VBOOL


def _num_int(v: Value) raises -> Int:
    if v.tag == VINT:
        return v.i
    if v.tag == VBOOL:
        return 1 if v.b else 0
    raise Error("expected integer")


# ── Expression evaluation ─────────────────────────────────────────────────────
def eval_expr(mut env: Env, node: ExprNode) raises -> Value:
    var k = node.kind
    if k == E_INT:
        return Value.int(node.ival)
    if k == E_STR:
        return Value.string(node.sval)
    if k == E_BOOL:
        return Value.bool(node.ival == 1)
    if k == E_NONE:
        return Value.none()
    if k == E_NAME:
        var found = env.get(node.sval)
        if found:
            return found.value()
        if _is_global_callable(node.sval):
            return Value.callable(node.sval)
        return Value.undef()
    if k == E_ATTR:
        var obj = eval_expr(env, node.kids[][0])
        return _get_attr(obj, node.sval)
    if k == E_SUBSCRIPT:
        return _eval_subscript(env, node)
    if k == E_SLICE:
        return _eval_slice(env, node)
    if k == E_UNARY:
        return _eval_unary(env, node)
    if k == E_BINOP:
        return _eval_binop(env, node)
    if k == E_TEST:
        return _eval_test(env, node)
    if k == E_FILTER:
        return _eval_filter(env, node)
    if k == E_CALL:
        return _eval_call(env, node)
    raise Error("unknown expression node")


def _get_attr(obj: Value, name: String) raises -> Value:
    if obj.tag == VMAP:
        var r = obj.map_get(name)
        if r:
            return r.value()
        return Value.undef()
    if obj.tag == VUNDEF:
        return Value.undef()
    return Value.undef()


def _eval_subscript(mut env: Env, node: ExprNode) raises -> Value:
    var obj = _req(eval_expr(env, node.kids[][0]))
    var idx = _req(eval_expr(env, node.kids[][1]))
    if obj.tag == VLIST:
        var i = _num_int(idx)
        var n = len(obj.c[].vals)
        if i < 0:
            i += n
        if i < 0 or i >= n:
            raise Error("list index out of range")
        return obj.c[].vals[i]
    if obj.tag == VMAP:
        var r = obj.map_get(idx.s)
        if r:
            return r.value()
        return Value.undef()
    if obj.tag == VSTR:
        var cps = _codepoints(obj.s)
        var i = _num_int(idx)
        var n = len(cps)
        if i < 0:
            i += n
        if i < 0 or i >= n:
            raise Error("string index out of range")
        return Value.string(_encode_cps(cps, i, i + 1))
    raise Error("value is not subscriptable")


def _eval_slice(mut env: Env, node: ExprNode) raises -> Value:
    var obj = _req(eval_expr(env, node.kids[][0]))
    var has_start = (node.ival & 1) != 0
    var has_end = (node.ival & 2) != 0
    var ci = 1
    var start = 0
    var end = 0
    if has_start:
        start = _num_int(_req(eval_expr(env, node.kids[][ci])))
        ci += 1
    if has_end:
        end = _num_int(_req(eval_expr(env, node.kids[][ci])))

    if obj.tag == VLIST:
        var n = len(obj.c[].vals)
        var bounds = _norm_slice(n, has_start, start, has_end, end)
        var out = List[Value]()
        for i in range(bounds[0], bounds[1]):
            out.append(obj.c[].vals[i])
        return Value.list_of(out^)
    if obj.tag == VSTR:
        var cps = _codepoints(obj.s)
        var bounds = _norm_slice(len(cps), has_start, start, has_end, end)
        return Value.string(_encode_cps(cps, bounds[0], bounds[1]))
    raise Error("value is not sliceable")


def _norm_slice(
    length: Int, has_start: Bool, start_in: Int, has_end: Bool, end_in: Int
) -> Tuple[Int, Int]:
    var start = 0
    var end = length
    if has_start:
        start = start_in
        if start < 0:
            start = max(0, length + start)
        else:
            start = min(start, length)
    if has_end:
        end = end_in
        if end < 0:
            end = max(0, length + end)
        else:
            end = min(end, length)
    if end < start:
        end = start
    return (start, end)


def _eval_unary(mut env: Env, node: ExprNode) raises -> Value:
    var op = node.sval
    if op == "not":
        var v = _req(eval_expr(env, node.kids[][0]))
        return Value.bool(not v.truthy())
    var v = _req(eval_expr(env, node.kids[][0]))
    if op == "-":
        if v.tag == VFLOAT:
            return Value.float(-v.f)
        return Value.int(-_num_int(v))
    return v  # unary +


def _eval_binop(mut env: Env, node: ExprNode) raises -> Value:
    var op = node.sval
    if op == "and":
        var lv = _req(eval_expr(env, node.kids[][0]))
        if not lv.truthy():
            return lv
        return eval_expr(env, node.kids[][1])
    if op == "or":
        var lv = _req(eval_expr(env, node.kids[][0]))
        if lv.truthy():
            return lv
        return eval_expr(env, node.kids[][1])

    if op == "in" or op == "not in":
        var left = _req(eval_expr(env, node.kids[][0]))
        var right = _req(eval_expr(env, node.kids[][1]))
        var found = _membership(left, right)
        if op == "not in":
            found = not found
        return Value.bool(found)

    var l = _req(eval_expr(env, node.kids[][0]))
    var r = _req(eval_expr(env, node.kids[][1]))
    if op == "==":
        return Value.bool(values_equal(l, r))
    if op == "!=":
        return Value.bool(not values_equal(l, r))
    if op == "+":
        if l.tag == VSTR and r.tag == VSTR:
            # jinja Markup semantics: str + Markup escapes the plain operand.
            var ls = _html_escape(l.s) if (r.safe and not l.safe) else l.s
            var rs = _html_escape(r.s) if (l.safe and not r.safe) else r.s
            if l.safe or r.safe:
                return Value.safe_string(ls + rs)
            return Value.string(ls + rs)
        if l.tag == VLIST and r.tag == VLIST:
            var out = List[Value]()
            for i in range(len(l.c[].vals)):
                out.append(l.c[].vals[i])
            for i in range(len(r.c[].vals)):
                out.append(r.c[].vals[i])
            return Value.list_of(out^)
        return _arith(l, r, "+")
    if op == "-" or op == "*" or op == "/" or op == "%":
        return _arith(l, r, op)
    if op == "<" or op == ">" or op == "<=" or op == ">=":
        return Value.bool(_compare(l, r, op))
    raise Error("unknown operator '" + op + "'")


def _arith(l: Value, r: Value, op: String) raises -> Value:
    if not _is_num(l) or not _is_num(r):
        raise Error("unsupported operand types for '" + op + "'")
    if l.tag == VFLOAT or r.tag == VFLOAT:
        var lf = l.f if l.tag == VFLOAT else Float64(_num_int(l))
        var rf = r.f if r.tag == VFLOAT else Float64(_num_int(r))
        if op == "+":
            return Value.float(lf + rf)
        if op == "-":
            return Value.float(lf - rf)
        if op == "*":
            return Value.float(lf * rf)
        if op == "/":
            return Value.float(lf / rf)
        return Value.float(lf - rf * (lf // rf))
    var li = _num_int(l)
    var ri = _num_int(r)
    if op == "+":
        return Value.int(li + ri)
    if op == "-":
        return Value.int(li - ri)
    if op == "*":
        return Value.int(li * ri)
    if op == "/":
        return Value.float(Float64(li) / Float64(ri))
    # Python floor-modulo
    var m = li % ri
    if (m != 0) and ((m < 0) != (ri < 0)):
        m += ri
    return Value.int(m)


def _compare(l: Value, r: Value, op: String) raises -> Bool:
    if l.tag == VSTR and r.tag == VSTR:
        var gt = _str_greater(l.s, r.s)
        var eq = l.s == r.s
        if op == "<":
            return not gt and not eq
        if op == ">":
            return gt
        if op == "<=":
            return not gt
        return gt or eq
    if _is_num(l) and _is_num(r):
        var lf = l.f if l.tag == VFLOAT else Float64(_num_int(l))
        var rf = r.f if r.tag == VFLOAT else Float64(_num_int(r))
        if op == "<":
            return lf < rf
        if op == ">":
            return lf > rf
        if op == "<=":
            return lf <= rf
        return lf >= rf
    raise Error("unsupported comparison")


def _str_greater(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = min(len(ab), len(bb))
    for k in range(n):
        if ab[k] != bb[k]:
            return ab[k] > bb[k]
    return len(ab) > len(bb)


def _membership(left: Value, right: Value) raises -> Bool:
    if right.tag == VMAP:
        return right.map_has(left.s)
    if right.tag == VLIST:
        for i in range(len(right.c[].vals)):
            if values_equal(right.c[].vals[i], left):
                return True
        return False
    if right.tag == VSTR:
        return right.s.find(left.s) >= 0
    raise Error("argument of 'in' is not iterable")


def _eval_test(mut env: Env, node: ExprNode) raises -> Value:
    var v = eval_expr(env, node.kids[][0])  # tolerate undefined
    var name = node.sval
    var res: Bool
    if name == "defined":
        res = not v.is_undef()
    elif name == "none":
        res = v.is_none()
    elif name == "mapping":
        res = v.tag == VMAP
    elif name == "iterable":
        res = v.tag == VLIST or v.tag == VSTR or v.tag == VMAP
    elif name == "string":
        res = v.tag == VSTR
    elif name == "number":
        res = _is_num(v)
    elif name == "true":
        res = v.tag == VBOOL and v.b
    elif name == "false":
        res = v.tag == VBOOL and not v.b
    else:
        raise Error("unknown test '" + name + "'")
    if node.ival == 1:
        res = not res
    return Value.bool(res)


def _eval_filter(mut env: Env, node: ExprNode) raises -> Value:
    var name = node.sval
    var inp = _req(eval_expr(env, node.kids[][0]))
    if name == "tojson":
        var indent = 0
        for k in range(len(node.kwnames[])):
            if node.kwnames[][k] == "indent":
                # kwarg values are stored after positional args
                var vi = 1 + node.ival + k
                indent = _num_int(_req(eval_expr(env, node.kids[][vi])))
        return Value.safe_string(to_json(inp, indent))  # jinja returns Markup
    if name == "trim":
        return Value.string(_trim(inp.s))
    if name == "length":
        if inp.tag == VLIST:
            return Value.int(len(inp.c[].vals))
        if inp.tag == VMAP:
            return Value.int(len(inp.c[].keys))
        if inp.tag == VSTR:
            return Value.int(len(_codepoints(inp.s)))
        raise Error("object has no length")
    if name == "list":
        if inp.tag == VLIST:
            return inp
        if inp.tag == VSTR:
            var out = List[Value]()
            var cps = _codepoints(inp.s)
            for i in range(len(cps)):
                out.append(Value.string(_encode_cps(cps, i, i + 1)))
            return Value.list_of(out^)
        raise Error("cannot convert to list")
    if name == "string":
        return Value.string(_to_str(inp))
    if name == "selectattr":
        return _selectattr(env, node, inp)
    if name == "first":
        if inp.tag == VLIST and len(inp.c[].vals) > 0:
            return inp.c[].vals[0]
        raise Error("first: empty or non-sequence")
    if name == "last":
        if inp.tag == VLIST and len(inp.c[].vals) > 0:
            return inp.c[].vals[len(inp.c[].vals) - 1]
        raise Error("last: empty or non-sequence")
    raise Error("unknown filter '" + name + "'")


def _selectattr(mut env: Env, node: ExprNode, inp: Value) raises -> Value:
    # selectattr(attr, op, value); only "equalto"/"eq" observed
    var attr = _req(eval_expr(env, node.kids[][1])).s
    var op = _req(eval_expr(env, node.kids[][2])).s
    var target = _req(eval_expr(env, node.kids[][3]))
    var out = List[Value]()
    for i in range(len(inp.c[].vals)):
        var item = inp.c[].vals[i]
        var av = _get_attr(item, attr)
        var keep: Bool
        if op == "equalto" or op == "eq" or op == "==":
            keep = values_equal(av, target)
        elif op == "ne" or op == "!=":
            keep = not values_equal(av, target)
        else:
            raise Error("unsupported selectattr op '" + op + "'")
        if keep:
            out.append(item)
    return Value.list_of(out^)


def _eval_call(mut env: Env, node: ExprNode) raises -> Value:
    var callee = node.kids[][0]
    if callee.kind == E_NAME:
        var name = callee.sval
        if name == "raise_exception":
            var msg = _to_str(_req(eval_expr(env, node.kids[][1])))
            env.user_error = True
            env.user_msg = msg
            raise Error(msg)
        if name == "strftime_now":
            var fmt = _req(eval_expr(env, node.kids[][1])).s
            return Value.string(strftime_utc(env.now_epoch, fmt))
        if name == "namespace":
            var ns = Value.mapping()
            for k in range(len(node.kwnames[])):
                var vi = 1 + node.ival + k
                ns.map_set(node.kwnames[][k], eval_expr(env, node.kids[][vi]))
            return ns
        raise Error("'" + name + "' is not callable")
    if callee.kind == E_ATTR and callee.sval == "items":
        var obj = _req(eval_expr(env, callee.kids[][0]))
        if obj.tag != VMAP:
            raise Error("items() on non-mapping")
        var out = List[Value]()
        for k in range(len(obj.c[].keys)):
            var pair = List[Value]()
            pair.append(Value.string(obj.c[].keys[k]))
            pair.append(obj.c[].vals[k])
            out.append(Value.list_of(pair^))
        return Value.list_of(out^)
    raise Error("unsupported call")


# ── Statement execution ───────────────────────────────────────────────────────
def exec_stmts(mut env: Env, body: List[StmtNode]) raises:
    for i in range(len(body)):
        exec_stmt(env, body[i])


def exec_stmt(mut env: Env, node: StmtNode) raises:
    var k = node.kind
    if k == S_TEXT:
        env.emit(node.sval)
    elif k == S_OUTPUT:
        var v = eval_expr(env, node.exprs[][0])
        env.emit(v.to_output())
    elif k == S_IF:
        var c = _req(eval_expr(env, node.exprs[][0]))
        if c.truthy():
            exec_stmts(env, node.body[])
        else:
            exec_stmts(env, node.body2[])
    elif k == S_SET:
        var v = eval_expr(env, node.exprs[][0])
        env.set_local(node.sval, v)
    elif k == S_SETATTR:
        var holder = env.get(node.sval)
        if not holder:
            raise Error("'" + node.sval + "' is undefined")
        var obj = holder.value()
        if obj.tag != VMAP:
            raise Error("cannot set attribute on non-namespace")
        obj.map_set(node.sval2, eval_expr(env, node.exprs[][0]))
    elif k == S_FOR:
        _exec_for(env, node)


def _exec_for(mut env: Env, node: StmtNode) raises:
    var iter_v = _req(eval_expr(env, node.exprs[][0]))
    if iter_v.tag != VLIST:
        raise Error("for-loop target is not iterable")
    var has_filter = node.ival == 1

    var items = List[Value]()
    if has_filter:
        for k in range(len(iter_v.c[].vals)):
            env.push()
            _bind_targets(env, node, iter_v.c[].vals[k])
            var keep = _req(eval_expr(env, node.exprs[][1])).truthy()
            env.pop()
            if keep:
                items.append(iter_v.c[].vals[k])
    else:
        for k in range(len(iter_v.c[].vals)):
            items.append(iter_v.c[].vals[k])

    var n = len(items)
    if n == 0:
        exec_stmts(env, node.body2[])
        return
    for k in range(n):
        env.push()
        _bind_targets(env, node, items[k])
        var loop = Value.mapping()
        loop.map_set("first", Value.bool(k == 0))
        loop.map_set("last", Value.bool(k == n - 1))
        loop.map_set("index0", Value.int(k))
        loop.map_set("index", Value.int(k + 1))
        loop.map_set("length", Value.int(n))
        env.set_local("loop", loop)
        exec_stmts(env, node.body[])
        env.pop()


def _bind_targets(mut env: Env, node: StmtNode, item: Value) raises:
    if node.sval2.byte_length() == 0:
        env.set_local(node.sval, item)
    else:
        if item.tag != VLIST or len(item.c[].vals) < 2:
            raise Error("cannot unpack loop target")
        env.set_local(node.sval, item.c[].vals[0])
        env.set_local(node.sval2, item.c[].vals[1])


# ── Helpers ───────────────────────────────────────────────────────────────────
def _to_str(v: Value) raises -> String:
    return v.to_output()


def _trim(s: String) -> String:
    var b = string_to_bytes(s)
    var start = 0
    var end = len(b)
    while start < end and _ws(Int(b[start])):
        start += 1
    while end > start and _ws(Int(b[end - 1])):
        end -= 1
    var out = List[UInt8]()
    for k in range(start, end):
        out.append(b[k])
    return bytes_to_string(out^)


def _html_escape(s: String) -> String:
    # markupsafe.escape: & < > ' " -> entities (& first to avoid double-escaping).
    var b = string_to_bytes(s)
    var out = String()
    for k in range(len(b)):
        var c = Int(b[k])
        if c == ord("&"):
            out += "&amp;"
        elif c == ord("<"):
            out += "&lt;"
        elif c == ord(">"):
            out += "&gt;"
        elif c == ord("'"):
            out += "&#39;"
        elif c == ord('"'):
            out += "&#34;"
        else:
            out += bytes_to_string(_one_byte(b[k]))
    return out


def _one_byte(c: UInt8) -> List[UInt8]:
    var o = List[UInt8]()
    o.append(c)
    return o^


def _ws(c: Int) -> Bool:
    return (
        c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x0C or c == 0x0B
    )


def _codepoints(s: String) -> List[Int]:
    var b = string_to_bytes(s)
    var out = List[Int]()
    var i = 0
    while i < len(b):
        var dec = _utf8_decode(b, i)
        out.append(dec[0])
        i = dec[1]
    return out^


def _encode_cps(cps: List[Int], start: Int, end: Int) -> String:
    var out = List[UInt8]()
    for i in range(start, end):
        _utf8_encode(cps[i], out)
    return bytes_to_string(out^)
