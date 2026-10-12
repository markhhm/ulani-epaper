"""Expected results for the Swift calendar sources (Feeds/), computed with the Python reference.

Writes feed-expectations.json next to this file. Run from the repository root with a Python
that has ulani_epaper installed (python/):

    python apple/UlaniKit/Tests/PaperhueAgendaTests/Differential/make_feed_expectations.py

The iCal parser is replaced by a recorder (the Swift tests use a fake parser too): each case
lists what feeds.fetch / feeds.probe hand to ical.parse and what they make of its result.
Nothing here touches the network or the credential store.
"""

import json
import random
import urllib.error
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from ulani_epaper import feeds, ical
from ulani_epaper.agenda import Event, Task
from ulani_epaper.config import Feed, Settings

HERE = Path(__file__).resolve().parent
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
SECRET = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123456789abcdef/basic.ics"

# --- addresses -------------------------------------------------------------------

NORMALIZE = [
    "", "   ", "\n", f"  {SECRET}\n", SECRET, "\u3000" + SECRET + "\u3000", "\u2028" + SECRET + "\x85",
    "webcal://p01-caldav.icloud.com/published/2/abc", "WEBCAL://Example.COM/a.ics", "webcals://example.com/a.ics",
    "WebCals://example.com/x.ics", " webcal://a/b ", "webcal://", "webcal:/x", "webcal:x", "webcal://webcal://x/y",
    "http://nas.local:5000/cal.ics", "HTTPS://Example.com/Cal.ics", "HtTp://Example.com", "https://example.com",
    "https://example.com?x=1", "https://example.com#x", "https://example.com/?", "https://example.com/#",
    "https://example.com/a?", "https://example.com/a?b?c", "https://example.com/a#b#c", "https://example.com/a#b?c",
    "calendar.google.com/x.ics", "ftp://x/y.ics", "file:///C:/x.ics", "https://", "https:///x.ics", "https:x.ics",
    "https:", "//example.com/x", "mailto:me@example.com", "javascript://example.com/%0aalert(1)", "1https://a/b",
    "+https://a/b", "ht+tp://a/b", "https//a/b", "https:/a/b", "https:\\\\a\\b",
    "https://me:secret-pw@cloud.example/tasks", "https://me@cloud.example/tasks", "https://@cloud.example/tasks",
    "https://:@cloud.example/x", "https://:pw@cloud.example/x", "https://a@b@cloud.example/x",
    "https://user%40x:p%3Aw@host/", "https://g/private-ab cd/basic.ics", "https://g/private-abc\n/basic.ics",
    "https://g/private-abc\t/basic.ics", "https://g/private-abc\r\n", "https://g/a\x00b", "https://g/a\x1fb",
    "https://g/a\x7fb", "https://g/a\u00a0b", "https://g/a\u3000b", "https://g/a\u200bb", "https://g/a\u2028b",
    "https://g/a\x1cb", "https://g/a\x85b", "https://exa mple.com/x",
    "https://[bad/private-abc", "https://bad]/private-abc", "https://[::1]/x.ics", "https://[::1]:8443/x.ics",
    "https://[::1]x/a", "https://x[::1]/a", "https://[fe80::1%25en0]/x", "https://[FE80::1%25EN0]:1/x",
    "https://[fe80::1%]/x", "https://[127.0.0.1]/x", "https://[v1.fe]/x", "https://[vz.x]/x", "https://[v1.]/x",
    "https://[::ffff:192.168.0.1]/x", "https://[::ffff:192.168.0.01]/x", "https://[1:2:3:4:5:6:7:8]/x",
    "https://[1:2:3:4:5:6:7:8:9]/x", "https://[1::2::3]/x", "https://[:1:2:3:4:5:6:7]/x", "https://[1:2:3:4:5:6:7:]/x",
    "https://[1:2:3:4:5:6:7::]/x", "https://[::1:2:3:4:5:6:7]/x", "https://[12345::1]/x", "https://[g::1]/x",
    "https://[]/x", "https://[::]/x", "https://us[er]@host/x", "https://[::1]@host/x", "https://u@[::1]/x",
    "https://[::1]]/x", "https://[[::1]/x",
    "https://cloud.example/remote.php/dav/calendars/me/家務/?export&componentType=VTODO",
    "https://example.com/a%20b/%E5%AE%B6?x=%41&y=家#frag家", "https://example.com/a;params家/b",
    "https://example.com/a/b;p=家", "https://example.com/a;b/c;d=家?q=家", "https://example.com/;家",
    "https://example.com/a\"b<c>d{e}|f^g`h", "https://example.com/~user/_a.b-c", "https://example.com/a%zz%",
    "https://ex.com/a'b(c)d*e+f,g;h=i!j$k&l:m@n", "https://example.com/\\path\\x", "https://example.com/😀.ics",
    "https://example.com/e\u0301", "https://example.com/?q=a+b&r=c%2Bd&s=e f",
    "https://bücher.example/kalender.ics", "https://BÜCHER.example/x", "https://ex\u2100ample.com/x",
    "https://example.com\uff0fevil/x", "https://ex\uff20ample.com/x", "https://ΣΑΣ.example/x",
    "https://İ.example/x", "https://\u212aelvin.example/x", "https://ｅｘａｍｐｌｅ.com/x",
    "https://host:abc/x", "https://host:/x", "https://:80/x", "http://localhost/x",
    "https://192.168.1.10:8080/cal.ics", "https://outlook.office365.com/owa/calendar/abc@example.com/def/calendar.ics",
    "https://p01-caldav.icloud.com/published/2/MTIzNDU2Nzg5MDEyMzQ1Nq-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
]

WHERE_EXTRA = [
    "https://[::1]:8080/x", "https://[fe80::1%25EN0]/x", "https://User@Host.Example:8080/x", "not a url", "",
    "https://[bad/x", "https://", "webcal://Example.com/x", "https://ΣΑΣ.example/x", "https://exa mple.com/x",
    "https://ex\u2100ample.com/x",
]

OWNERS = [
    SECRET,
    "https://calendar.google.com/calendar/ical/abc123%40group.calendar.google.com/private-x/basic.ics",
    "https://outlook.office365.com/owa/calendar/abc/def/calendar.ics",
    "https://calendar.google.com/calendar/ical/Me%40Gmail.com/private-x/basic.ics",
    "https://Calendar.Google.COM/calendar/ical/me%40gmail.com/private-x/basic.ics",
    "https://calendar.google.com:443/calendar/ical/me%40gmail.com/private-x/basic.ics",
    "https://me@calendar.google.com/calendar/ical/me%40gmail.com/private-x/basic.ics",
    "https://calendar.google.com/calendar/ical", "https://calendar.google.com/calendar/ical/",
    "https://calendar.google.com/ical/me@gmail.com/x", "https://calendar.google.com/calendar/ical/me%40gmail.com",
    "https://calendar.google.com/calendar/ical/x/ical", "https://calendar.google.com/calendar/ical/ical/me%40x.com",
    "https://calendar.google.com/calendar/ical/%E5%AE%B6%40gmail.com/p/basic.ics",
    "https://calendar.google.com/calendar/ical/%ff%40x.com/p", "https://calendar.google.com/calendar/ical/%e5%ae%40x.com/p",
    "https://calendar.google.com/calendar/ical/%F0%9F%98%40x.com/p", "https://calendar.google.com/calendar/ical/%C0%AF%40x.com/p",
    "https://calendar.google.com/calendar/ical/%ED%A0%80%40x.com/p", "https://calendar.google.com/calendar/ical/%zz%40x.com/p",
    "https://calendar.google.com/calendar/ical/me%2540gmail.com/p",
    "https://calendar.google.com/calendar/ical/ME%40EXAMPLE.CALENDAR.GOOGLE.COM/p",
    "https://calendar.google.com/calendar/ical/me%40example.calendar.google.com/p",
    "http://calendar.google.com/calendar/ical/me%40gmail.com/private/basic.ics",
    "https://calendar.google.com/calendar/ical/me%40gmail.com/private;x/basic.ics",
    "https://calendar.google.com/calendar/ical;x/me%40gmail.com", "https://calendar.google.com/calendar/ical/me%40gmail.com;p",
    "https://calendar.google.com/calendar/ical/İ%40x.com/p", "https://calendar.google.com/calendar/ical/ΣΑΣ%40x.com/p",
    "https://calendar.google.com/calendar/ical/A%CE%A3%40x.com/p", "https://calendar.google.com/calendar/ical/%40/p",
    "https://calendar.google.com/calendar/ical/me%40gmail.com/p?x=ical", "https://calendar.google.com/x/ical/a%40b/ical",
    "https://calendar.google.com.evil.example/calendar/ical/me%40gmail.com/p", "https://google.com/calendar/ical/me%40gmail.com/p",
    "webcal://calendar.google.com/calendar/ical/me%40gmail.com/p", "https://[bad/calendar/ical/me%40gmail.com/p", "",
]


def normalize_cases():
    out = []
    for text in NORMALIZE:
        try:
            out.append({"input": text, "url": feeds.normalize_url(text)})
        except feeds.FeedError as e:
            out.append({"input": text, "error": str(e)})
    return out


def where_cases():
    urls = [c["url"] for c in normalize_cases() if "url" in c] + WHERE_EXTRA
    out = []
    for url in urls:
        try:
            out.append({"url": url, "host": feeds.where(url)})
        except ValueError:
            out.append({"url": url, "host": None})  # Python raises; Swift says "?"
    return out


def owner_cases():
    out = []
    for url in OWNERS:
        try:
            out.append({"url": url, "owner": feeds.owner(url)})
        except ValueError:
            out.append({"url": url, "owner": None})  # Python raises; Swift says ""
    return out


def login_cases():
    olds = [None, {}, {"url": ""}, {"url": "https://cloud.example/a", "user": "me", "password": "pw"},
            {"url": "https://Cloud.Example:8443/a", "user": "me", "password": "pw"},
            {"url": "https://cloud.example/a"}, {"url": "not a url", "user": "u", "password": "p"}]
    news = ["https://cloud.example/b", "https://evil.example/b", "https://CLOUD.example/c", "http://cloud.example:80/",
            "nonsense"]
    return [{"old": old, "new": new, "login": list(feeds.login_for(old, new))} for old in olds for new in news]


# --- settings and colours ------------------------------------------------------------

def feed_list(items):
    return [Feed(i, n, c) for i, n, c in items]


def colour_cases():
    rng = random.Random(20261012)
    choices = ["", "", "", "blue", "red", "green", "orange", "yellow", "black", "white", "#FF00aa", "#0000ff",
               "#ABC"]
    cases = [
        [("a", "a", ""), ("b", "b", ""), ("c", "c", "green"), ("d", "d", "")],
        [("p1", "個人", "blue"), ("h2", "家務", "")],
        [(f"f{i}", f"f{i}", "") for i in range(14)],
        [(c, c, c) for c in ("blue", "red", "green", "orange", "yellow", "black")] + [("x", "x", ""), ("y", "y", "")],
        [("x", "x", "#0000FF"), ("y", "y", "")],
        [],
    ]
    for _ in range(120):
        cases.append([(f"f{i}", f"f{i}", rng.choice(choices)) for i in range(rng.randint(1, 9))])
    return [{"feeds": [list(f) for f in case], "colours": feeds.colours(feed_list(case))} for case in cases]


def validate_cases():
    cases = [
        [("p1", "個人", "blue"), ("h2", "家務", "")],
        [("a", "a", ""), ("a", "b", "")],
        [("a b", "a", "")], [("", "a", "")], [("x" * 40, "a", "")], [("x" * 41, "a", "")], [("é", "a", "")],
        [("a.b", "a", "")], [("A-Z_09", "a", "")], [("１", "a", "")], [("ok", "o'k", ""), ("o'k", "x", "")],
        [("a", "  ", "")], [("a", "\u3000", "")], [("a", "", "")], [("a", " x ", "")],
        [("a", "bad colour", "purple")], [("a", "x", "#12345")], [("a", "x", "#12345g")], [("a", "x", "Blue")],
        [("a", "x", "#ABCDEF")], [("a", "x", "white")], [("a", "x", "#abcdef ")], [("a", "x", "#ａｂｃｄｅｆ")],
        [("a", "  ", "purple"), ("a", "b", "")], [("a", "x", "purple"), ("b", "", "")],
    ]
    out = []
    for case in cases:
        try:
            Settings(feeds=feed_list(case)).validate()
            error = None
        except ValueError as e:
            error = str(e)
        out.append({"feeds": [list(f) for f in case], "error": error})
    return out


def windows():
    out, d = [], date(2024, 1, 1)
    while d <= date(2028, 12, 31):
        first, last = feeds.window(d)
        out.append([d.isoformat(), first.isoformat(), last.isoformat()])
        d += timedelta(days=1)
    return out


# --- downloading ---------------------------------------------------------------------

def raising(error):
    def urlopen(request, timeout=None):
        raise error
    return urlopen


def http_cases():
    out = []
    for code in range(300, 600):
        try:
            feeds.download(SECRET, urlopen=raising(urllib.error.HTTPError(SECRET, code, "x", {}, None)))
        except feeds.FeedError as e:
            out.append({"code": code, "error": str(e)})
    return out


def auth_cases():
    out = []
    for user, password in [("me", "pw"), ("", "pw"), ("me", ""), ("", ""), ("使用者", "密碼:x"), ("a:b", "c d"),
                           ("é", "\U0001F600")]:
        seen = []

        def urlopen(request, timeout=None, seen=seen):
            seen.append((request, timeout))
            raise TimeoutError("stop")
        try:
            feeds.download(SECRET, user, password, urlopen=urlopen)
        except feeds.FeedError as e:
            message = str(e)
        request, timeout = seen[0]
        out.append({"user": user, "password": password,
                    "authorization": request.unredirected_hdrs.get("Authorization"),
                    "redirected_headers": sorted(request.headers), "timeout": timeout, "error": message})
    return out


def request_headers():
    seen = []

    def urlopen(request, timeout=None):
        seen.append(request)
        raise TimeoutError("stop")
    try:
        feeds.download(SECRET, urlopen=urlopen)
    except feeds.FeedError:
        pass
    return {k: v for k, v in seen[0].header_items()}


# --- fetching every feed, with a recording parser ------------------------------------------

def iso_micros(aware):
    delta = aware - EPOCH
    return (delta.days * 86_400 + delta.seconds) * 1_000_000 + delta.microseconds


class Recorder:
    """Stands in for ical.parse: records its arguments; the body decides the outcome.

    "ICAL" -> one event and one task named after the feed; "NOT" -> ICalError.
    """

    def __init__(self):
        self.calls = []

    def __call__(self, data, start, end, tz, name="", color="", owner=""):
        self.calls.append({"body": data.decode(), "start": iso_micros(start), "end": iso_micros(end),
                           "start_wall": start.replace(tzinfo=None).isoformat(),
                           "end_wall": end.replace(tzinfo=None).isoformat(), "name": name, "color": color,
                           "owner": owner})
        if data.startswith(b"NOT"):
            raise ical.ICalError("not an iCalendar file (no VCALENDAR)")
        title = data.decode().split(":", 1)[1] if b":" in data else data.decode()
        when = start + timedelta(days=10)
        return ical.ParsedFeed(name=name or "X-WR-CALNAME", events=[
            Event(title=title, start=when, end=when + timedelta(hours=1), calendar=name, color=color)],
            tasks=[Task(title=f"{title} task", list_name=name)])


def zone(name):
    if name[0] in "+-":
        h, m = name[1:].split(":")
        sign = -1 if name[0] == "-" else 1
        return timezone(sign * timedelta(hours=int(h), minutes=int(m)))
    return ZoneInfo(name)


class Store(feeds.SecretStore):
    def __init__(self, values):
        self.values = dict(values)

    def get(self, feed_id):
        return self.values.get(feed_id)


def downloader(bodies, calls):
    """URL -> body; a body "FAIL <code>" raises the FeedError download gives for that code."""
    def download(url, user="", password="", **kw):
        calls.append([url, user, password])
        body = bodies[url]
        if body.startswith("FAIL "):
            code = int(body.split()[1])
            feeds.download(url, urlopen=raising(urllib.error.HTTPError(url, code, "x", {}, None)))
        if body == "TIMEOUT":
            feeds.download(url, urlopen=raising(TimeoutError("timed out")))
        return body.encode()
    return download


GOOGLE = "https://calendar.google.com/calendar/ical/Me%40Gmail.com/private-x/basic.ics"
STORE = {"p1": {"url": GOOGLE}, "h2": {"url": "https://n/h.ics", "user": "me", "password": "pw"},
         "s3": {"url": "https://school.example/s.ics", "user": "", "password": ""},
         "e4": {"url": ""}, "u5": {"url": "https://u/x.ics", "user": "only-user"}}
BODIES = {GOOGLE: "ICAL:晨會", "https://n/h.ics": "ICAL:社區大會", "https://school.example/s.ics": "ICAL:段考",
          "https://u/x.ics": "ICAL:u", "https://bad/404.ics": "FAIL 404", "https://bad/400.ics": "FAIL 400",
          "https://bad/html.ics": "NOT:<html>sign in</html>", "https://bad/timeout.ics": "TIMEOUT",
          "https://school.example/x.ics": "ICAL:probe"}
FETCHES = [
    ("two feeds", [("p1", "個人", "blue"), ("h2", "家務", "")], {}),
    ("three feeds, automatic colours", [("h2", "家務", ""), ("s3", "學校", ""), ("p1", "個人", "")], {}),
    ("a feed failing with 404", [("p1", "個人", "blue"), ("h2", "家務", "")], {"h2": {"url": "https://bad/404.ics"}}),
    ("a feed failing with 400", [("h2", "家務", "")], {"h2": {"url": "https://bad/400.ics"}}),
    ("a feed timing out", [("p1", "個人", ""), ("h2", "家務", "")], {"p1": {"url": "https://bad/timeout.ics"}}),
    ("a feed that is not a calendar", [("p1", "個人", "")], {"p1": {"url": "https://bad/html.ics"}}),
    ("a feed without a stored address", [("p1", "個人", ""), ("zz", "其他", "")], {}),
    ("a feed with an empty stored address", [("e4", "空的", "")], {}),
    ("a user without a password", [("u5", "U", "#ABCDEF")], {}),
    ("no feeds", [], {}),
]
DAYS = ["2026-10-12", "2026-10-31", "2026-02-01", "2026-03-08", "2026-09-06", "2026-11-01", "2028-02-29"]
ZONES = ["+08:00", "America/New_York", "America/Santiago", "Asia/Kolkata", "Pacific/Kiritimati"]


def fetch_cases():
    recorder = Recorder()
    saved = ical.parse
    ical.parse = recorder
    out = []
    try:
        for i, (name, items, overrides) in enumerate(FETCHES):
            # every day and zone for the first case; the failures at two of them
            for day, zone_name in ([(d, z) for d in DAYS for z in ZONES] if i == 0 else
                                   [("2026-10-12", "+08:00"), ("2026-11-01", "America/New_York")]):
                recorder.calls, downloads = [], []
                today, tz = date.fromisoformat(day), zone(zone_name)
                now = datetime.combine(today, datetime.min.time(), tz).replace(hour=7)
                case = {"name": name, "feeds": [list(f) for f in items], "secrets": {**STORE, **overrides},
                        "today": day, "zone": zone_name, "now": now.isoformat()}
                try:
                    data = feeds.fetch(feed_list(items), today, tz, now, secrets=Store(case["secrets"]),
                                       download=downloader(BODIES, downloads))
                    case["events"] = [[e.title, e.calendar, e.color] for e in data.events]
                    case["tasks"] = [[t.title, t.list_name] for t in data.tasks]
                    case["fetched_at"] = data.fetched_at.isoformat()
                except (feeds.FeedError, feeds.NoFeeds) as e:
                    case["error"] = str(e)
                    case["error_type"] = type(e).__name__
                case["downloads"], case["parses"] = downloads, recorder.calls
                out.append(case)
    finally:
        ical.parse = saved
    return out


PROBES = [
    ("webcal://school.example/x.ics", "", ""), ("https://school.example/x.ics", "me", "pw"),
    ("webcal://calendar.google.com/calendar/ical/Me%40Gmail.com/private-x/basic.ics", "", ""),
    ("https://bad/html.ics", "", ""), ("https://bad/404.ics", "u", "p"), ("ftp://bad/x.ics", "", ""),
    ("https://me:pw@bad/x.ics", "", ""), ("https://bad/timeout.ics", "", ""),
]


def probe_cases():
    recorder = Recorder()
    saved = ical.parse
    ical.parse = recorder
    bodies = {**BODIES, "https://calendar.google.com/calendar/ical/Me%40Gmail.com/private-x/basic.ics": "ICAL:g"}
    out = []
    try:
        for url, user, password in PROBES:
            for day, zone_name in [("2026-10-12", "+08:00"), ("2026-03-08", "America/New_York")]:
                recorder.calls, downloads = [], []
                case = {"url": url, "user": user, "password": password, "today": day, "zone": zone_name}
                try:
                    parsed = feeds.probe(url, user, password, today=date.fromisoformat(day), tz=zone(zone_name),
                                         download=downloader(bodies, downloads))
                    case["result"] = parsed.name
                except feeds.FeedError as e:
                    case["error"] = str(e)
                case["downloads"], case["parses"] = downloads, recorder.calls
                out.append(case)
    finally:
        ical.parse = saved
    return out


def new_feed_cases():
    out = []
    for name, url, color, user, password in [
        (" 學校 ", "webcal://school/x.ics", "green", "", ""), ("家務", "https://n/家.ics", "", "me", "pw"),
        ("bad colour", "https://x/y.ics", "purple", "", ""), ("  ", "https://x/y.ics", "", "", ""),
        ("bad url", "ftp://x/y.ics", "", "", ""), ("\u3000名\u3000", "https://x/y.ics", "#ABCDEF", "", ""),
    ]:
        settings, store = Settings(), {}

        class Memory(feeds.SecretStore):
            def set(self, feed_id, url, user="", password=""):
                store[feed_id] = {"url": url, "user": user, "password": password}

        case = {"name": name, "url": url, "color": color, "user": user, "password": password}
        try:
            feed = feeds.new_feed(settings, name, url, color, user, password, secrets=Memory())
            case["feed"] = [feed.name, feed.color]
            case["secret"] = store[feed.id]
        except feeds.FeedError as e:
            case["error"] = str(e)
            case["error_type"] = "FeedError"
        except ValueError as e:
            case["error"] = str(e)
            case["error_type"] = "ValueError"
        case["feeds"] = len(settings.feeds)
        case["stored"] = len(store)
        out.append(case)
    return out


def main():
    out = {
        "generated_by": "apple/UlaniKit/Tests/PaperhueAgendaTests/Differential/make_feed_expectations.py",
        "normalize": normalize_cases(),
        "where": where_cases(),
        "owner": owner_cases(),
        "login": login_cases(),
        "colours": colour_cases(),
        "auto_colours": list(feeds.AUTO_COLOURS),
        "validate": validate_cases(),
        "windows": windows(),
        "http": http_cases(),
        "auth": auth_cases(),
        "headers": request_headers(),
        "max_bytes": feeds.MAX_BYTES,
        "timeout": feeds.TIMEOUT,
        "fetch": fetch_cases(),
        "probe": probe_cases(),
        "new_feed": new_feed_cases(),
    }
    text = json.dumps(out, ensure_ascii=True, indent=1, sort_keys=True) + "\n"
    (HERE / "feed-expectations.json").write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
