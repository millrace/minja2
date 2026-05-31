"""CLI bridge the conformance runner shells out to (minja2).

Reads a JSON job from `argv[1]`:
    {"template": "<source>", "context": {<vars>}, "now_epoch": <int>}
renders it, and writes the result to `argv[2]`. Exit codes let the runner tell
template-authored `raise_exception` apart from internal errors:
    0  success           (file = rendered bytes)
    3  raise_exception   (file = the message, verbatim)
    1  parse/runtime err (file = diagnostic message)
"""

from std.sys import argv, exit
from value import Value
from json import parse_json
from template import Template


def _read_file(path: String) raises -> String:
    var f = open(path, "r")
    var data = f.read()
    f.close()
    return data


def _write_file(path: String, content: String) raises:
    var f = open(path, "w")
    f.write(content)
    f.close()


def main():
    var args = argv()
    if len(args) < 3:
        print("usage: minja2 <job.json> <out>")
        exit(2)

    var job_path = String(args[1])
    var out_path = String(args[2])

    try:
        var job = parse_json(_read_file(job_path))
        var src = job.map_get("template").value().s
        var now_epoch = 0
        var ne = job.map_get("now_epoch")
        if ne and ne.value().tag == 3:  # VINT
            now_epoch = ne.value().i
        var ctx = job.map_get("context").value()

        var tmpl = Template.compile(src)
        var result = tmpl.render_result(ctx^, now_epoch)
        _write_file(out_path, result.text)
        if result.ok:
            exit(0)
        elif result.user_error:
            exit(3)
        else:
            exit(1)
    except e:
        try:
            _write_file(out_path, String(e))
        except:
            pass
        exit(1)
