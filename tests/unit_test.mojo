from json import parse_json, to_json
from value import Value, values_equal

def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)
    print("ok:", msg)

def main() raises:
    var v = parse_json('{"b":1,"a":2}')
    _check(to_json(v, 0) == '{"a": 2, "b": 1}', "tojson sorts keys")
    _check(to_json(parse_json('"h<i>"'), 0) == '"h\\u003ci\\u003e"', "tojson html-escape")
    _check(values_equal(Value.int(1), Value.bool(True)), "1 == True")
    print("ALL UNIT TESTS PASSED")
