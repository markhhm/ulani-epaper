import gzip
import io
import urllib.error
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

from ulani_epaper import feeds
from ulani_epaper.config import Feed

FIX = Path(__file__).resolve().parents[2] / "shared" / "vectors" / "ical"
TPE = timezone(timedelta(hours=8))
SECRET = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123456789abcdef/basic.ics"


# --- addresses -------------------------------------------------------------------

@pytest.mark.parametrize("given, url", [
    (f"  {SECRET}\n", SECRET),
    ("webcal://p01-caldav.icloud.com/published/2/abc", "https://p01-caldav.icloud.com/published/2/abc"),
    ("http://nas.local:5000/cal.ics", "http://nas.local:5000/cal.ics"),
])
def test_normalize_url(given, url):
    assert feeds.normalize_url(given) == url


@pytest.mark.parametrize("bad", ["", "calendar.google.com/x.ics", "ftp://x/y.ics", "file:///C:/x.ics", "https://",
                                 "https://me:secret-pw@cloud.example/tasks", "https://g/private-ab cd/basic.ics",
                                 "https://g/private-abc\n/basic.ics", "https://[bad/private-abc"])
def test_bad_urls_are_refused_without_repeating_them(bad):
    with pytest.raises(feeds.FeedError) as e:
        feeds.normalize_url(bad)
    assert "secret-pw" not in str(e.value) and "private-" not in str(e.value)


def test_non_ascii_paths_are_percent_encoded():
    url = feeds.normalize_url("https://cloud.example/remote.php/dav/calendars/me/家務/?export&componentType=VTODO")
    assert url == ("https://cloud.example/remote.php/dav/calendars/me/%E5%AE%B6%E5%8B%99/"
                   "?export&componentType=VTODO")


def test_any_download_error_hides_the_address():
    import http.client

    def invalid(request, timeout=None):
        raise http.client.InvalidURL(f"URL can't contain control characters. {SECRET!r}")

    with pytest.raises(feeds.FeedError) as e:
        feeds.download(SECRET, urlopen=invalid)
    assert "private-" not in str(e.value) and "calendar.google.com" in str(e.value)


def test_photo_only_installs_import_without_icalendar():
    import subprocess
    import sys

    code = ("import sys; sys.modules['icalendar'] = None; sys.modules['keyring'] = None\n"
            "import ulani_epaper.cli, ulani_epaper.gui, ulani_epaper.sync, ulani_epaper.feeds\n"
            "print('ok')")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert out.stdout.strip() == "ok", out.stderr


def test_where_shows_only_the_host():
    assert feeds.where(SECRET) == "calendar.google.com"


@pytest.mark.parametrize("url, owner", [
    (SECRET, "me@gmail.com"),  # a calendar's own address: its owner, to leave out declined events
    ("https://calendar.google.com/calendar/ical/abc123%40group.calendar.google.com/private-x/basic.ics", ""),
    ("https://outlook.office365.com/owa/calendar/abc/def/calendar.ics", ""),
])
def test_owner_of_a_google_address(url, owner):
    assert feeds.owner(url) == owner


# --- the secret store --------------------------------------------------------------

def test_secrets_round_trip_in_the_credential_store():
    store = feeds.KeyringSecrets()
    store.set("a1", SECRET, user="me", password="pw")
    assert store.get("a1") == {"url": SECRET, "user": "me", "password": "pw"}
    store.delete("a1")
    assert store.get("a1") is None
    store.delete("a1")  # twice is fine


def test_secrets_stay_below_the_windows_limit():
    with pytest.raises(feeds.FeedError, match="too long"):
        feeds.KeyringSecrets().set("a1", "https://x/" + "a" * 1500)


# --- downloading ----------------------------------------------------------------

class FakeResponse(io.BytesIO):
    def __init__(self, body, headers=None):
        super().__init__(body)
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def opener(body=b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", headers=None, error=None, seen=None):
    def urlopen(request, timeout=None):
        if seen is not None:
            seen.append((request, timeout))
        if error:
            raise error
        return FakeResponse(body, headers)
    return urlopen


def test_download_sends_a_plain_get_with_basic_auth_when_given():
    seen = []
    assert feeds.download(SECRET, "me", "pw", urlopen=opener(seen=seen)).startswith(b"BEGIN:VCALENDAR")
    request, timeout = seen[0]
    assert request.full_url == SECRET and timeout
    assert request.unredirected_hdrs.get("Authorization") == "Basic bWU6cHc="
    assert request.get_header("User-agent").startswith("Paperhue/")


def test_credentials_are_not_sent_on_to_a_redirect():
    seen = []
    feeds.download(SECRET, "me", "pw", urlopen=opener(seen=seen))
    request = seen[0][0]
    assert "Authorization" not in request.headers  # headers there are copied onto a redirect
    assert request.unredirected_hdrs["Authorization"] == "Basic bWU6cHc="


def test_a_redirect_from_https_to_http_is_refused():
    import urllib.request

    handler = feeds._SafeRedirect()
    req = urllib.request.Request("https://example.com/a.ics")
    with pytest.raises(urllib.error.HTTPError):
        handler.redirect_request(req, None, 302, "Found", {}, "http://example.com/a.ics")
    assert handler.redirect_request(req, None, 301, "Moved", {}, "https://example.org/a.ics") is not None


def test_download_without_credentials_sends_no_authorization():
    seen = []
    feeds.download(SECRET, urlopen=opener(seen=seen))
    assert seen[0][0].get_header("Authorization") is None


def test_download_unzips_gzip():
    body = gzip.compress(b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
    assert feeds.download(SECRET, urlopen=opener(body, {"Content-Encoding": "gzip"})).startswith(b"BEGIN")


def test_download_refuses_huge_feeds():
    with pytest.raises(feeds.FeedError, match="MB"):
        feeds.download(SECRET, urlopen=opener(b"x" * (feeds.MAX_BYTES + 1)))


@pytest.mark.parametrize("error, phrase", [
    (urllib.error.HTTPError(SECRET, 404, "Not Found", {}, None), "404"),
    (urllib.error.HTTPError(SECRET, 400, "Bad Request", {}, None), "重設"),  # Google: a reset secret address
    (urllib.error.HTTPError(SECRET, 401, "Unauthorized", {}, None), "401"),
    (urllib.error.URLError(OSError(11001, "getaddrinfo failed")), "連線"),
    (TimeoutError("timed out"), "連線"),
])
def test_download_errors_never_show_the_secret_address(error, phrase):
    with pytest.raises(feeds.FeedError) as e:
        feeds.download(SECRET, urlopen=opener(error=error))
    assert phrase in str(e.value)
    assert "private-" not in str(e.value) and "me%40gmail" not in str(e.value)


# --- fetching every feed ---------------------------------------------------------

class MemorySecrets(feeds.SecretStore):
    def __init__(self, values=None):
        self.values = dict(values or {})

    def get(self, feed_id):
        return self.values.get(feed_id)

    def set(self, feed_id, url, user="", password=""):
        self.values[feed_id] = {"url": url, "user": user, "password": password}

    def delete(self, feed_id):
        self.values.pop(feed_id, None)


NOW = datetime(2026, 10, 12, 7, 0, tzinfo=TPE)
FEEDS = [Feed("p1", "個人", "blue"), Feed("h2", "家務", "")]
STORE = MemorySecrets({"p1": {"url": "https://g/p.ics"}, "h2": {"url": "https://n/h.ics", "user": "me",
                                                                 "password": "pw"}})
FILES = {"https://g/p.ics": "google.ics", "https://n/h.ics": "todos.ics"}


def fake_download(calls=None):
    def download(url, user="", password="", **kw):
        if calls is not None:
            calls.append((url, user, password))
        return (FIX / FILES[url]).read_bytes()
    return download


def test_fetch_reads_every_feed_with_its_name_and_colour():
    calls = []
    data = feeds.fetch(FEEDS, today=date(2026, 10, 12), tz=TPE, now=NOW, secrets=STORE,
                       download=fake_download(calls))
    assert calls == [("https://g/p.ics", "", ""), ("https://n/h.ics", "me", "pw")]
    by_title = {e.title: e for e in data.events}
    assert by_title["晨會"].calendar == "個人" and by_title["晨會"].color == "#0000ff"
    assert by_title["社區大會"].calendar == "家務" and by_title["社區大會"].color  # automatic colour
    assert {t.title for t in data.tasks} >= {"繳電費", "買牛奶、雞蛋、吐司"}
    assert all(t.list_name == "家務" for t in data.tasks)
    assert data.fetched_at == NOW


def test_automatic_colours_differ_between_feeds():
    colours = feeds.colours([Feed("a", "a"), Feed("b", "b"), Feed("c", "c", "green"), Feed("d", "d")])
    assert colours["c"] == "#00ff00" and len(set(colours.values())) == 4


def test_fetch_window_covers_the_month_grid_and_the_weeks_ahead():
    start, end = feeds.window(date(2026, 10, 31))
    assert start <= date(2026, 9, 27) and end >= date(2026, 11, 30)


def test_one_failing_feed_fails_the_fetch_and_names_the_feed():
    def failing(url, user="", password="", **kw):
        if url == "https://n/h.ics":
            raise feeds.FeedError("HTTP 404（網址可能已重設）")
        return (FIX / FILES[url]).read_bytes()

    with pytest.raises(feeds.FeedError, match="家務.*404"):
        feeds.fetch(FEEDS, today=date(2026, 10, 12), tz=TPE, now=NOW, secrets=STORE, download=failing)


def test_a_feed_without_a_stored_address_is_reported():
    with pytest.raises(feeds.FeedError, match="個人"):
        feeds.fetch(FEEDS[:1], today=date(2026, 10, 12), tz=TPE, now=NOW, secrets=MemorySecrets(),
                    download=fake_download())


def test_a_feed_that_is_not_a_calendar_is_reported():
    def html(url, user="", password="", **kw):
        return b"<html>sign in</html>"

    with pytest.raises(feeds.FeedError, match="個人.*iCalendar"):
        feeds.fetch(FEEDS[:1], today=date(2026, 10, 12), tz=TPE, now=NOW, secrets=STORE, download=html)


def test_probe_reads_an_address_now():
    parsed = feeds.probe("webcal://g/p.ics", today=date(2026, 10, 12), tz=TPE,
                         download=lambda url, u="", p="": (FIX / FILES[url.replace("webcal", "https")]).read_bytes())
    assert parsed.name == "個人" and any(e.title == "晨會" for e in parsed.events)


def test_probe_counts_like_the_sync_without_declined_invitations():
    from tests.test_ical import DECLINED

    url = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-x/basic.ics"
    parsed = feeds.probe(url, today=date(2026, 10, 12), tz=TPE, download=lambda u, user="", pw="": DECLINED)
    assert len(parsed.events) == 3  # 5 in the feed, 2 declined by the owner


@pytest.mark.parametrize("old, new, kept", [
    ({"url": "https://cloud.example/a", "user": "me", "password": "pw"}, "https://cloud.example/b", True),
    ({"url": "https://cloud.example/a", "user": "me", "password": "pw"}, "https://evil.example/b", False),
    (None, "https://cloud.example/b", False),
])
def test_a_login_is_kept_only_for_the_same_host(old, new, kept):
    assert feeds.login_for(old, new) == (("me", "pw") if kept else ("", ""))


def test_new_and_removed_feeds():
    from ulani_epaper.config import Settings

    settings, store = Settings(), MemorySecrets()
    feed = feeds.new_feed(settings, " 學校 ", "webcal://school/x.ics", "green", secrets=store)
    assert settings.feeds == [feed] and feed.name == "學校" and feed.color == "green"
    assert store.get(feed.id) == {"url": "https://school/x.ics", "user": "", "password": ""}
    with pytest.raises(ValueError):
        feeds.new_feed(settings, "bad colour", "https://x/y.ics", "purple", secrets=store)
    assert settings.feeds == [feed] and len(store.values) == 1  # nothing half-added
    feeds.remove_feed(settings, feed, secrets=store)
    assert settings.feeds == [] and store.values == {}


def test_no_feeds_at_all():
    with pytest.raises(feeds.NoFeeds):
        feeds.fetch([], today=date(2026, 10, 12), tz=TPE, now=NOW, secrets=STORE, download=fake_download())
