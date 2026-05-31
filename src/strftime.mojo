"""A small UTC `strftime` for `strftime_now`.

The host (conformance runner / millrace) injects a fixed epoch so renders are
deterministic; this formats that instant. Only the codes seen in chat templates
plus the common ones are implemented (corpus uses `"%d %b %Y"`).
"""

from std.collections import List
from json import _b, bytes_to_string


def _mon_abbr(m: Int) raises -> String:
    var names = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    return names[m - 1]


def _mon_full(m: Int) raises -> String:
    var names = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    return names[m - 1]


def _day_abbr(w: Int) raises -> String:
    var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return names[w]


def _day_full(w: Int) raises -> String:
    var names = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
        "Saturday",
    ]
    return names[w]


def _pad2(x: Int) -> String:
    if x < 10:
        return "0" + String(x)
    return String(x)


def _pad3(x: Int) -> String:
    if x < 10:
        return "00" + String(x)
    if x < 100:
        return "0" + String(x)
    return String(x)


def strftime_utc(epoch: Int, fmt: String) raises -> String:
    var days = epoch // 86400
    var secs = epoch % 86400
    var hour = secs // 3600
    var minute = (secs % 3600) // 60
    var sec = secs % 60

    # civil date from days since 1970-01-01 (Hinnant's algorithm)
    var z = days + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + 3 if mp < 10 else mp - 9
    if month <= 2:
        y += 1
    var weekday = (days % 7 + 4) % 7  # 0 = Sunday
    if weekday < 0:
        weekday += 7

    var b = fmt.as_bytes()
    var n = len(b)
    var out = String()
    var i = 0
    while i < n:
        if Int(b[i]) == ord("%") and i + 1 < n:
            var code = Int(b[i + 1])
            if code == ord("Y"):
                out += String(y)
            elif code == ord("y"):
                out += _pad2(y % 100)
            elif code == ord("m"):
                out += _pad2(month)
            elif code == ord("d"):
                out += _pad2(day)
            elif code == ord("e"):
                out += (" " + String(day)) if day < 10 else String(day)
            elif code == ord("H"):
                out += _pad2(hour)
            elif code == ord("M"):
                out += _pad2(minute)
            elif code == ord("S"):
                out += _pad2(sec)
            elif code == ord("b"):
                out += _mon_abbr(month)
            elif code == ord("B"):
                out += _mon_full(month)
            elif code == ord("a"):
                out += _day_abbr(weekday)
            elif code == ord("A"):
                out += _day_full(weekday)
            elif code == ord("j"):
                out += _pad3(doy + 1)
            elif code == ord("p"):
                out += "AM" if hour < 12 else "PM"
            elif code == ord("%"):
                out += "%"
            else:
                out += "%" + bytes_to_string(_one(b[i + 1]))
            i += 2
        else:
            out += bytes_to_string(_one(b[i]))
            i += 1
    return out


def _one(c: UInt8) -> List[UInt8]:
    var o = List[UInt8]()
    o.append(c)
    return o^
