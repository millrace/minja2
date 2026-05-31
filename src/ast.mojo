"""AST node types for the chat-template subset of Jinja2.

Two node families, each holding children behind an `ArcPointer` so the structs
can be recursive: `ExprNode` (expressions) and `StmtNode` (statements). Nodes
are built once by the parser and only read by the evaluator, so the structural
sharing that `ImplicitlyCopyable` introduces is harmless.
"""

from std.collections import List
from std.memory import ArcPointer

# ── Expression kinds ──────────────────────────────────────────────────────────
comptime E_INT: UInt8 = 0
comptime E_STR: UInt8 = 1
comptime E_BOOL: UInt8 = 2
comptime E_NONE: UInt8 = 3
comptime E_NAME: UInt8 = 4
comptime E_ATTR: UInt8 = 5  # kids[0]=obj, sval=attr
comptime E_SUBSCRIPT: UInt8 = 6  # kids[0]=obj, kids[1]=index
comptime E_SLICE: UInt8 = 7  # kids[0]=obj; ival flags bit0=has_start bit1=has_end
comptime E_UNARY: UInt8 = 8  # sval=op, kids[0]=operand
comptime E_BINOP: UInt8 = 9  # sval=op, kids[0],kids[1]
comptime E_CALL: UInt8 = 10  # kids[0]=callee, ival=#positional, kwnames for kwargs
comptime E_FILTER: UInt8 = 11  # kids[0]=input, sval=name, ival=#positional
comptime E_TEST: UInt8 = 12  # kids[0]=value, sval=name, ival=negate

# ── Statement kinds ───────────────────────────────────────────────────────────
comptime S_TEXT: UInt8 = 0  # sval=literal text
comptime S_OUTPUT: UInt8 = 1  # exprs[0]=expression to render
comptime S_IF: UInt8 = 2  # exprs[0]=cond, body=then, body2=else
comptime S_FOR: UInt8 = 3  # sval/sval2=targets, exprs[0]=iter, exprs[1]=filter
comptime S_SET: UInt8 = 4  # sval=name, exprs[0]=value
comptime S_SETATTR: UInt8 = 5  # sval=ns, sval2=attr, exprs[0]=value


struct ExprNode(Copyable, Movable, ImplicitlyCopyable):
    var kind: UInt8
    var sval: String
    var ival: Int
    var line: Int
    var kids: ArcPointer[List[ExprNode]]
    var kwnames: ArcPointer[List[String]]

    def __init__(out self, kind: UInt8):
        self.kind = kind
        self.sval = String()
        self.ival = 0
        self.line = 0
        self.kids = ArcPointer[List[ExprNode]](List[ExprNode]())
        self.kwnames = ArcPointer[List[String]](List[String]())

    def add(mut self, var child: ExprNode):
        self.kids[].append(child^)


def e_int(x: Int, line: Int) -> ExprNode:
    var n = ExprNode(E_INT)
    n.ival = x
    n.line = line
    return n


def e_str(var s: String, line: Int) -> ExprNode:
    var n = ExprNode(E_STR)
    n.sval = s^
    n.line = line
    return n


def e_bool(x: Bool, line: Int) -> ExprNode:
    var n = ExprNode(E_BOOL)
    n.ival = 1 if x else 0
    n.line = line
    return n


def e_none(line: Int) -> ExprNode:
    var n = ExprNode(E_NONE)
    n.line = line
    return n


def e_name(var s: String, line: Int) -> ExprNode:
    var n = ExprNode(E_NAME)
    n.sval = s^
    n.line = line
    return n


struct StmtNode(Copyable, Movable, ImplicitlyCopyable):
    var kind: UInt8
    var sval: String
    var sval2: String
    var ival: Int
    var line: Int
    var exprs: ArcPointer[List[ExprNode]]
    var body: ArcPointer[List[StmtNode]]
    var body2: ArcPointer[List[StmtNode]]

    def __init__(out self, kind: UInt8):
        self.kind = kind
        self.sval = String()
        self.sval2 = String()
        self.ival = 0
        self.line = 0
        self.exprs = ArcPointer[List[ExprNode]](List[ExprNode]())
        self.body = ArcPointer[List[StmtNode]](List[StmtNode]())
        self.body2 = ArcPointer[List[StmtNode]](List[StmtNode]())
