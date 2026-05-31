"""Parser: tokens -> AST.

`ExprParser` is a precedence-climbing expression parser; `TemplateParser`
consumes the lexer's segment stream and builds the statement tree, desugaring
`elif` chains into nested `if`s in the else-branch.

Operator precedence follows jinja2 (loosest to tightest): `or`, `and`, unary
`not`, comparison (`== != < > <= >= in "not in"`), `+ -`, `* / %`, unary `+ -`,
then the postfix level — attribute / subscript / slice / call / `|filter` /
`is test` — which binds tightest, exactly as jinja's `parse_unary` does.
"""

from std.collections import List
from lexer import (
    Segment,
    ExprToken,
    tokenize_expr,
    SEG_TEXT,
    SEG_OUTPUT,
    SEG_STMT,
    T_NAME,
    T_INT,
    T_STR,
    T_OP,
    T_EOF,
)
from ast import (
    ExprNode,
    StmtNode,
    e_int,
    e_str,
    e_bool,
    e_none,
    e_name,
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


# ── Expression parser ─────────────────────────────────────────────────────────
struct ExprParser(Copyable, Movable):
    var toks: List[ExprToken]
    var pos: Int
    var line: Int

    def __init__(out self, var toks: List[ExprToken], line: Int):
        self.toks = toks^
        self.pos = 0
        self.line = line

    def _cur(self) -> ExprToken:
        return self.toks[self.pos]

    def _is_op(self, s: String) -> Bool:
        return self.toks[self.pos].kind == T_OP and self.toks[self.pos].sval == s

    def _is_name(self, s: String) -> Bool:
        return (
            self.toks[self.pos].kind == T_NAME and self.toks[self.pos].sval == s
        )

    def _peek_op(self, off: Int, s: String) -> Bool:
        var p = self.pos + off
        return (
            p < len(self.toks)
            and self.toks[p].kind == T_OP
            and self.toks[p].sval == s
        )

    def _advance(mut self):
        if self.toks[self.pos].kind != T_EOF:
            self.pos += 1

    def _expect_op(mut self, s: String) raises:
        if not self._is_op(s):
            raise Error(
                "expected '"
                + s
                + "' at line "
                + String(self.line)
                + ", got '"
                + self._cur().sval
                + "'"
            )
        self._advance()

    def parse(mut self) raises -> ExprNode:
        var e = self._or()
        return e^

    def _or(mut self) raises -> ExprNode:
        var left = self._and()
        while self._is_name("or"):
            self._advance()
            var right = self._and()
            var n = ExprNode(E_BINOP)
            n.sval = "or"
            n.line = self.line
            n.add(left^)
            n.add(right^)
            left = n^
        return left^

    def _and(mut self) raises -> ExprNode:
        var left = self._not()
        while self._is_name("and"):
            self._advance()
            var right = self._not()
            var n = ExprNode(E_BINOP)
            n.sval = "and"
            n.line = self.line
            n.add(left^)
            n.add(right^)
            left = n^
        return left^

    def _not(mut self) raises -> ExprNode:
        if self._is_name("not"):
            self._advance()
            var operand = self._not()
            var n = ExprNode(E_UNARY)
            n.sval = "not"
            n.line = self.line
            n.add(operand^)
            return n^
        return self._compare()

    def _compare(mut self) raises -> ExprNode:
        var left = self._add()
        while True:
            var op: String
            if (
                self._is_op("==")
                or self._is_op("!=")
                or self._is_op("<")
                or self._is_op(">")
                or self._is_op("<=")
                or self._is_op(">=")
            ):
                op = self._cur().sval
                self._advance()
            elif self._is_name("in"):
                op = "in"
                self._advance()
            elif self._is_name("not") and (
                self.pos + 1 < len(self.toks)
                and self.toks[self.pos + 1].kind == T_NAME
                and self.toks[self.pos + 1].sval == "in"
            ):
                op = "not in"
                self._advance()
                self._advance()
            else:
                break
            var right = self._add()
            var n = ExprNode(E_BINOP)
            n.sval = op
            n.line = self.line
            n.add(left^)
            n.add(right^)
            left = n^
        return left^

    def _add(mut self) raises -> ExprNode:
        var left = self._mul()
        while self._is_op("+") or self._is_op("-"):
            var op = self._cur().sval
            self._advance()
            var right = self._mul()
            var n = ExprNode(E_BINOP)
            n.sval = op
            n.line = self.line
            n.add(left^)
            n.add(right^)
            left = n^
        return left^

    def _mul(mut self) raises -> ExprNode:
        var left = self._unary()
        while self._is_op("*") or self._is_op("/") or self._is_op("%"):
            var op = self._cur().sval
            self._advance()
            var right = self._unary()
            var n = ExprNode(E_BINOP)
            n.sval = op
            n.line = self.line
            n.add(left^)
            n.add(right^)
            left = n^
        return left^

    def _unary(mut self) raises -> ExprNode:
        if self._is_op("-") or self._is_op("+"):
            var op = self._cur().sval
            self._advance()
            var operand = self._unary()
            var n = ExprNode(E_UNARY)
            n.sval = op
            n.line = self.line
            n.add(operand^)
            return n^
        return self._postfix()

    def _postfix(mut self) raises -> ExprNode:
        var node = self._primary()
        while True:
            if self._is_op("."):
                self._advance()
                var attr = self._cur().sval
                self._advance()
                var n = ExprNode(E_ATTR)
                n.sval = attr
                n.line = self.line
                n.add(node^)
                node = n^
            elif self._is_op("["):
                node = self._subscript(node^)
            elif self._is_op("("):
                node = self._call(node^)
            elif self._is_op("|"):
                node = self._filter(node^)
            elif self._is_name("is"):
                node = self._test(node^)
            else:
                break
        return node^

    def _subscript(mut self, var obj: ExprNode) raises -> ExprNode:
        self._advance()  # [
        var has_start = not self._is_op(":")
        var start = ExprNode(E_SLICE)  # placeholder, overwritten if used
        if has_start:
            start = self.parse()
        if self._is_op(":"):
            self._advance()  # slice
            var has_end = not self._is_op("]")
            var end = ExprNode(E_SLICE)
            if has_end:
                end = self.parse()
            self._expect_op("]")
            var n = ExprNode(E_SLICE)
            n.line = self.line
            n.ival = (1 if has_start else 0) | (2 if has_end else 0)
            n.add(obj^)
            if has_start:
                n.add(start^)
            if has_end:
                n.add(end^)
            return n^
        self._expect_op("]")
        var n = ExprNode(E_SUBSCRIPT)
        n.line = self.line
        n.add(obj^)
        n.add(start^)
        return n^

    def _parse_args(mut self, mut node: ExprNode) raises -> Int:
        """Parse `( ... )` arg list into node; returns positional count."""
        self._advance()  # (
        var npos = 0
        var kwvals = List[ExprNode]()
        var kwnames = List[String]()
        while not self._is_op(")"):
            if self._cur().kind == T_NAME and self._peek_op(1, "="):
                var name = self._cur().sval
                self._advance()
                self._advance()  # =
                kwnames.append(name)
                kwvals.append(self.parse())
            else:
                node.add(self.parse())
                npos += 1
            if self._is_op(","):
                self._advance()
        self._expect_op(")")
        for k in range(len(kwvals)):
            node.add(kwvals[k])
            node.kwnames[].append(kwnames[k])
        return npos

    def _call(mut self, var callee: ExprNode) raises -> ExprNode:
        var n = ExprNode(E_CALL)
        n.line = self.line
        n.add(callee^)
        n.ival = self._parse_args(n)
        return n^

    def _filter(mut self, var value: ExprNode) raises -> ExprNode:
        self._advance()  # |
        var name = self._cur().sval
        self._advance()
        var n = ExprNode(E_FILTER)
        n.sval = name
        n.line = self.line
        n.add(value^)
        if self._is_op("("):
            n.ival = self._parse_args(n)
        return n^

    def _test(mut self, var value: ExprNode) raises -> ExprNode:
        self._advance()  # is
        var negate = 0
        if self._is_name("not"):
            negate = 1
            self._advance()
        var name = self._cur().sval
        self._advance()
        var n = ExprNode(E_TEST)
        n.sval = name
        n.ival = negate
        n.line = self.line
        n.add(value^)
        return n^

    def _primary(mut self) raises -> ExprNode:
        var t = self._cur()
        if t.kind == T_INT:
            self._advance()
            return e_int(t.ival, self.line)
        if t.kind == T_STR:
            self._advance()
            return e_str(t.sval, self.line)
        if t.kind == T_NAME:
            self._advance()
            if t.sval == "true" or t.sval == "True":
                return e_bool(True, self.line)
            if t.sval == "false" or t.sval == "False":
                return e_bool(False, self.line)
            if t.sval == "none" or t.sval == "None":
                return e_none(self.line)
            return e_name(t.sval, self.line)
        if t.kind == T_OP and t.sval == "(":
            self._advance()
            var e = self.parse()
            self._expect_op(")")
            return e^
        raise Error(
            "unexpected token '" + t.sval + "' at line " + String(self.line)
        )


def parse_expression(src: String, line: Int) raises -> ExprNode:
    var p = ExprParser(tokenize_expr(src, line), line)
    var e = p.parse()
    if p._cur().kind != T_EOF:
        raise Error(
            "trailing tokens in expression at line "
            + String(line)
            + ": '"
            + p._cur().sval
            + "'"
        )
    return e^


# ── Statement / template parser ───────────────────────────────────────────────
def _first_keyword(inner: String, line: Int) raises -> String:
    var toks = tokenize_expr(inner, line)
    if len(toks) > 0 and toks[0].kind == T_NAME:
        return toks[0].sval
    return String()


def _rest_after_keyword(inner: String) raises -> String:
    # Drop the leading keyword token from a statement's inner source.
    var b = inner.as_bytes()
    var i = 0
    var n = len(b)
    while i < n and (Int(b[i]) == 0x20 or Int(b[i]) == 0x09):
        i += 1
    while i < n and not (Int(b[i]) == 0x20 or Int(b[i]) == 0x09):
        i += 1
    var out = List[UInt8]()
    for k in range(i, n):
        out.append(b[k])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


struct TemplateParser(Copyable, Movable):
    var segs: List[Segment]
    var pos: Int

    def __init__(out self, var segs: List[Segment]):
        self.segs = segs^
        self.pos = 0

    def _kw(self) raises -> String:
        return _first_keyword(self.segs[self.pos].text, self.segs[self.pos].line)

    def parse(mut self) raises -> List[StmtNode]:
        var empty = List[String]()
        var body = self._statements(empty)
        if self.pos < len(self.segs):
            raise Error(
                "unexpected '"
                + self._kw()
                + "' at line "
                + String(self.segs[self.pos].line)
            )
        return body^

    def _statements(mut self, stop: List[String]) raises -> List[StmtNode]:
        var out = List[StmtNode]()
        while self.pos < len(self.segs):
            var seg = self.segs[self.pos]
            if seg.kind == SEG_TEXT:
                var n = StmtNode(S_TEXT)
                n.sval = seg.text
                n.line = seg.line
                out.append(n^)
                self.pos += 1
            elif seg.kind == SEG_OUTPUT:
                var n = StmtNode(S_OUTPUT)
                n.line = seg.line
                n.exprs[].append(parse_expression(seg.text, seg.line))
                out.append(n^)
                self.pos += 1
            else:  # SEG_STMT
                var kw = self._kw()
                if _contains(stop, kw):
                    return out^
                if kw == "if":
                    out.append(self._parse_if())
                elif kw == "for":
                    out.append(self._parse_for())
                elif kw == "set":
                    out.append(self._parse_set())
                else:
                    raise Error(
                        "unknown statement '"
                        + kw
                        + "' at line "
                        + String(seg.line)
                    )
        if len(stop) > 0:
            raise Error("unexpected end of template; missing end tag")
        return out^

    def _parse_if(mut self) raises -> StmtNode:
        var seg = self.segs[self.pos]
        var cond_src = _rest_after_keyword(seg.text)
        self.pos += 1  # consume if/elif
        var node = StmtNode(S_IF)
        node.line = seg.line
        node.exprs[].append(parse_expression(cond_src, seg.line))
        var stop = List[String]()
        stop.append("elif")
        stop.append("else")
        stop.append("endif")
        node.body[] = self._statements(stop)
        var kw = self._kw()
        if kw == "elif":
            node.body2[].append(self._parse_if())  # nested; consumes endif
        elif kw == "else":
            self.pos += 1
            var stop2 = List[String]()
            stop2.append("endif")
            node.body2[] = self._statements(stop2)
            self.pos += 1  # endif
        else:  # endif
            self.pos += 1
        return node^

    def _parse_for(mut self) raises -> StmtNode:
        var seg = self.segs[self.pos]
        var rest = _rest_after_keyword(seg.text)
        self.pos += 1
        var node = StmtNode(S_FOR)
        node.line = seg.line
        # rest = "TARGETS in ITER [if FILTER]"
        var toks = tokenize_expr(rest, seg.line)
        var p = ExprParser(toks^, seg.line)
        # parse targets
        node.sval = p._cur().sval
        p._advance()
        if p._is_op(","):
            p._advance()
            node.sval2 = p._cur().sval
            p._advance()
        if not p._is_name("in"):
            raise Error("expected 'in' in for-loop at line " + String(seg.line))
        p._advance()
        node.exprs[].append(p.parse())  # stops at trailing 'if' (a NAME)
        if p._is_name("if"):
            p._advance()
            node.ival = 1
            node.exprs[].append(p.parse())
        var stop = List[String]()
        stop.append("endfor")
        stop.append("else")
        node.body[] = self._statements(stop)
        var kw = self._kw()
        if kw == "else":
            self.pos += 1
            var stop2 = List[String]()
            stop2.append("endfor")
            node.body2[] = self._statements(stop2)
        self.pos += 1  # endfor
        return node^

    def _parse_set(mut self) raises -> StmtNode:
        var seg = self.segs[self.pos]
        var rest = _rest_after_keyword(seg.text)
        self.pos += 1
        var toks = tokenize_expr(rest, seg.line)
        var p = ExprParser(toks^, seg.line)
        var name = p._cur().sval
        p._advance()
        if p._is_op("."):
            p._advance()
            var attr = p._cur().sval
            p._advance()
            p._expect_op("=")
            var node = StmtNode(S_SETATTR)
            node.line = seg.line
            node.sval = name
            node.sval2 = attr
            node.exprs[].append(p.parse())
            return node^
        p._expect_op("=")
        var node = StmtNode(S_SET)
        node.line = seg.line
        node.sval = name
        node.exprs[].append(p.parse())
        return node^


def _contains(xs: List[String], v: String) -> Bool:
    for k in range(len(xs)):
        if xs[k] == v:
            return True
    return False
