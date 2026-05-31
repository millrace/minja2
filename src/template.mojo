"""Public API: compile a chat template once, render it many times.

`Template.render` raises on any error (parse-time errors surface from
`compile`). `render_result` is the non-raising variant the CLI uses to map a
template-authored `raise_exception` to a distinct exit code versus an internal
error.
"""

from std.collections import List
from value import Value
from ast import StmtNode
from lexer import tokenize_template
from parser import TemplateParser
from eval import Env, exec_stmts
from json import bytes_to_string


struct RenderResult(Copyable, Movable):
    var ok: Bool
    var user_error: Bool  # True if caused by template-authored raise_exception
    var text: String  # rendered output if ok, else the error message

    def __init__(out self, ok: Bool, user_error: Bool, var text: String):
        self.ok = ok
        self.user_error = user_error
        self.text = text^


struct Template(Copyable, Movable):
    """A compiled chat template, reusable across renders."""

    var body: List[StmtNode]
    var name: String

    def __init__(out self, var body: List[StmtNode], var name: String):
        self.body = body^
        self.name = name^

    @staticmethod
    def compile(source: String, name: String = "") raises -> Template:
        var segs = tokenize_template(source)
        var p = TemplateParser(segs^)
        var body = p.parse()
        return Template(body^, name)

    def render_result(self, var ctx: Value, now_epoch: Int) -> RenderResult:
        var env = Env(now_epoch)
        try:
            for k in range(len(ctx.c[].keys)):
                env.set_local(ctx.c[].keys[k], ctx.c[].vals[k])
            exec_stmts(env, self.body)
        except e:
            if env.user_error:
                return RenderResult(False, True, env.user_msg)
            return RenderResult(False, False, String(e))
        return RenderResult(True, False, bytes_to_string(env.out))

    def render(self, var ctx: Value, now_epoch: Int) raises -> String:
        var r = self.render_result(ctx^, now_epoch)
        if not r.ok:
            raise Error(r.text)
        return r.text
