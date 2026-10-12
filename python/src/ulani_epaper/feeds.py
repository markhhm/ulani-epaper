"""Calendar sources: .ics addresses, fetched straight from the calendar service.

A feed is any iCalendar address: Google Calendar's "secret address in iCal
format", an Outlook / iCloud / Proton published calendar, a Nextcloud or
other CalDAV export link (optionally with a user name and app password).
No account, API or cloud project of anyone else is involved.

An address that is not public is a password in itself, so it is kept in
the OS credential store (Windows Credential Manager / macOS Keychain via
keyring), never in the settings file or in error messages and logs. What
is fetched is parsed in memory and never written anywhere.
"""

from __future__ import annotations

import base64
import gzip
import io
import json
import urllib.error
import urllib.request
from datetime import date, datetime, time, timedelta, tzinfo
from typing import Callable
from urllib.parse import urlparse

from . import __version__
from .agenda import AgendaData
from .config import Feed
from .image import COLOURS
from .protocol import UlaniError

TIMEOUT = 30  # seconds per request
MAX_BYTES = 20 * 1024 * 1024  # a feed larger than this is refused
SERVICE = "ulani-epaper"
#: shown when no calendar is set up: Google's public Taiwan holidays calendar (public data, no login)
DEFAULT_CALENDAR_URL = "https://calendar.google.com/calendar/ical/zh-tw.taiwan%23holiday%40group.v.calendar.google.com/public/basic.ics"
DEFAULT_CALENDAR_NAME = "台灣假日"
#: colours given to feeds without one, in this order
AUTO_COLOURS = ("blue", "red", "green", "orange", "yellow", "black")


class FeedError(UlaniError):
    """A feed could not be read. The message names the feed, never its address."""


class NoFeeds(UlaniError):
    """No calendar source is set up yet."""


# --- addresses -------------------------------------------------------------------

def normalize_url(text: str) -> str:
    """A pasted address as it is fetched (webcal:// becomes https://, non-ASCII
    characters percent-encoded). Messages never repeat the address."""
    from urllib.parse import quote, urlunparse

    url = (text or "").strip()
    if url.lower().startswith(("webcal://", "webcals://")):
        url = "https://" + url.split("://", 1)[1]
    if any(c.isspace() or ord(c) < 32 for c in url):
        raise FeedError("網址中間有空白或換行，請重新複製整段網址")
    try:
        parts = urlparse(url)
        host = parts.hostname
    except ValueError:
        host = None
    if not host or parts.scheme.lower() not in ("http", "https"):
        raise FeedError("這不是有效的行事曆網址（要以 https:// 或 webcal:// 開頭）")
    if parts.username or parts.password:
        raise FeedError("網址裡不要放帳號密碼，請分開填在「帳號」「密碼」")
    safe = "/%:@!$&'()*+,;=-._~?"
    return urlunparse(parts._replace(path=quote(parts.path, safe=safe), query=quote(parts.query, safe=safe)))


def where(url: str) -> str:
    """Only the host of an address, for display (the path is the secret)."""
    return urlparse(url).hostname or "?"


def login_for(old: dict | None, new_url: str) -> tuple[str, str]:
    """The stored user name and password, but only if the new address is on the
    same host: a password must never be sent to some other server."""
    if old and old.get("url") and where(old["url"]) == where(new_url):
        return old.get("user", ""), old.get("password", "")
    return "", ""


def owner(url: str) -> str:
    """The e-mail of the person whose own Google calendar this secret address
    is, else "". Used only in memory, to leave out invitations they declined."""
    from urllib.parse import unquote

    parts = urlparse(url)
    segments = parts.path.split("/")
    if parts.hostname != "calendar.google.com" or "ical" not in segments:
        return ""
    calendar_id = unquote(segments[segments.index("ical") + 1]) if segments[-1:] != ["ical"] else ""
    if "@" not in calendar_id or calendar_id.endswith(".calendar.google.com"):
        return ""  # a secondary or shared calendar: its id is not a person
    return calendar_id.lower()


# --- the secret store ---------------------------------------------------------------

class SecretStore:
    """Feed id -> {"url", "user", "password"}."""

    def get(self, feed_id: str) -> dict | None:
        raise NotImplementedError

    def set(self, feed_id: str, url: str, user: str = "", password: str = "") -> None:
        raise NotImplementedError

    def delete(self, feed_id: str) -> None:
        raise NotImplementedError


class KeyringSecrets(SecretStore):
    """The OS credential store. Windows keeps at most 2560 bytes (UTF-16) per entry."""

    LIMIT = 1200  # characters of JSON, well inside Windows' limit

    def get(self, feed_id):
        import keyring

        raw = keyring.get_password(SERVICE, f"feed:{feed_id}")
        return json.loads(raw) if raw else None

    def set(self, feed_id, url, user="", password=""):
        import keyring

        payload = json.dumps({"url": url, "user": user, "password": password}, separators=(",", ":"))
        if len(payload) > self.LIMIT:
            raise FeedError("this address is too long for the credential store")
        keyring.set_password(SERVICE, f"feed:{feed_id}", payload)

    def delete(self, feed_id):
        import keyring
        from keyring.errors import PasswordDeleteError

        try:
            keyring.delete_password(SERVICE, f"feed:{feed_id}")
        except (PasswordDeleteError, KeyError):
            pass


# --- downloading ----------------------------------------------------------------------

class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    """Follow redirects, but never from https down to plain http (the path is a secret)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if req.full_url.lower().startswith("https:") and newurl.lower().startswith("http:"):
            raise urllib.error.HTTPError(newurl, code, "refusing a redirect from https to http", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str, user: str = "", password: str = "", *, urlopen=None) -> bytes:
    """GET one feed (following redirects, never to plain http), at most MAX_BYTES, gzip undone."""
    request = urllib.request.Request(url, headers={
        "User-Agent": f"Paperhue/{__version__}", "Accept": "text/calendar, */*", "Accept-Encoding": "gzip"})
    if user or password:
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        # unredirected: a redirect to another host must not receive the password
        request.add_unredirected_header("Authorization", f"Basic {token}")
    if urlopen is None:
        urlopen = urllib.request.build_opener(_SafeRedirect()).open
    try:
        with urlopen(request, timeout=TIMEOUT) as response:
            body = response.read(MAX_BYTES + 1)
            encoding = (response.headers.get("Content-Encoding") or "").lower()
    except urllib.error.HTTPError as e:
        hint = {400: "網址無效，或已被重設", 401: "需要帳號密碼，或密碼不對", 403: "沒有權限",
                404: "找不到：網址可能已重設或刪除", 410: "已刪除"}.get(e.code, "伺服器拒絕")
        raise FeedError(f"HTTP {e.code}（{hint}）") from None
    except Exception as e:  # never str(e): http.client.InvalidURL and friends repeat the address
        reason = getattr(e, "reason", e)
        raise FeedError(f"無法連線到 {where(url)}（{type(reason).__name__}）") from None
    if encoding == "gzip":
        try:
            body = gzip.GzipFile(fileobj=io.BytesIO(body)).read(MAX_BYTES + 1)
        except (OSError, EOFError):
            raise FeedError("收到損壞的壓縮資料") from None
    if len(body) > MAX_BYTES:
        raise FeedError(f"行事曆大於 {MAX_BYTES // (1024 * 1024)} MB，不處理")
    return body


# --- fetching every feed ---------------------------------------------------------------

def window(today: date) -> tuple[date, date]:
    """Days to read: the 6-week grid of today's month and at least a month ahead."""
    first = today.replace(day=1)
    next_month = (first + timedelta(days=32)).replace(day=1)
    return first - timedelta(days=7), max(next_month + timedelta(days=14), today + timedelta(days=31))


def _hex(name_or_hex: str) -> str:
    if name_or_hex.startswith("#"):
        return name_or_hex.lower()
    r, g, b = COLOURS[name_or_hex].rgb
    return f"#{r:02x}{g:02x}{b:02x}"


def colours(feeds: list[Feed]) -> dict[str, str]:
    """Feed id -> "#rrggbb": its own colour, else the next automatic colour not taken."""
    taken = {f.color for f in feeds if f.color}
    spare = [c for c in AUTO_COLOURS if c not in taken] or list(AUTO_COLOURS)
    out, i = {}, 0
    for f in feeds:
        if f.color:
            out[f.id] = _hex(f.color)
        else:
            out[f.id] = _hex(spare[i % len(spare)])
            i += 1
    return out


def _downloader(given: Callable[..., bytes] | None) -> Callable[..., bytes]:
    # Looked up at call time (not as a default argument), so tests and apps can replace it.
    return given if given is not None else globals()["download"]


def probe(url: str, user: str = "", password: str = "", today: date | None = None, tz: tzinfo | None = None,
          download: Callable[..., bytes] | None = None) -> ical.ParsedFeed:
    """Download and read one address now, e.g. to check it before saving it."""
    from . import ical  # needs the [calendar] extra; photo-only installs never get here
    from .agenda import LOCAL

    tz = tz or LOCAL
    today = today or datetime.now(tz).date()
    first, last = window(today)
    url = normalize_url(url)
    try:
        body = _downloader(download)(url, user, password)
        return ical.parse(body, datetime.combine(first, time(), tz), datetime.combine(last, time(), tz), tz,
                          owner=owner(url))  # count what a sync would show
    except ical.ICalError:
        raise FeedError("收到的不是 iCalendar 資料（網址可能不對，或需要登入）") from None


def new_feed(settings, name: str, url: str, color: str = "", user: str = "", password: str = "",
             secrets: SecretStore | None = None) -> Feed:
    """Keep the address in the credential store and add the feed to ``settings`` (the caller saves them)."""
    import secrets as random

    url = normalize_url(url)
    feed = Feed(id=random.token_hex(4), name=name.strip(), color=color)
    settings.feeds.append(feed)
    try:
        settings.validate()
    except ValueError:
        settings.feeds.remove(feed)
        raise
    (secrets or KeyringSecrets()).set(feed.id, url, user, password)
    return feed


def remove_feed(settings, feed: Feed, secrets: SecretStore | None = None) -> None:
    """Forget a feed and its address (the caller saves the settings)."""
    (secrets or KeyringSecrets()).delete(feed.id)
    settings.feeds = [f for f in settings.feeds if f.id != feed.id]


def _fetch_default(today: date, tz: tzinfo, now: datetime, download: Callable[..., bytes] | None) -> AgendaData:
    from . import ical

    first, last = window(today)
    try:
        body = _downloader(download)(DEFAULT_CALENDAR_URL, "", "")
        parsed = ical.parse(body, datetime.combine(first, time(), tz), datetime.combine(last, time(), tz), tz,
                            name=DEFAULT_CALENDAR_NAME)
    except ical.ICalError:
        raise FeedError(f"{DEFAULT_CALENDAR_NAME}：收到的不是 iCalendar 資料") from None
    except FeedError as e:
        raise FeedError(f"{DEFAULT_CALENDAR_NAME}：{e}") from None
    return AgendaData(events=tuple(parsed.events), tasks=tuple(parsed.tasks), fetched_at=now)


def fetch(feeds: list[Feed], today: date, tz: tzinfo, now: datetime, secrets: SecretStore | None = None,
          download: Callable[..., bytes] | None = None) -> AgendaData:
    """Events around ``today`` and all open to-dos of every feed, in memory.

    One feed failing fails the whole fetch (FeedError naming that feed), so
    the device never shows a page with one calendar silently missing. With
    no feeds at all, the public Taiwan holidays calendar is read instead
    (parsed like any feed; it has no secret address, so nothing is looked up).
    """
    if not feeds:
        return _fetch_default(today, tz, now, download)
    from . import ical  # needs the [calendar] extra

    secrets = secrets or KeyringSecrets()
    download = _downloader(download)
    first, last = window(today)
    start, end = datetime.combine(first, time(), tz), datetime.combine(last, time(), tz)
    events, tasks = [], []
    hexes = colours(feeds)
    for feed in feeds:
        info = secrets.get(feed.id)
        if not info or not info.get("url"):
            raise FeedError(f"{feed.name}：找不到這個來源的網址，請重新加入")
        try:
            body = download(info["url"], info.get("user", ""), info.get("password", ""))
            parsed = ical.parse(body, start, end, tz, name=feed.name, color=hexes[feed.id],
                                owner=owner(info["url"]))
        except ical.ICalError:
            raise FeedError(f"{feed.name}：收到的不是 iCalendar 資料（網址可能不對，或需要登入）") from None
        except FeedError as e:
            raise FeedError(f"{feed.name}：{e}") from None
        events += parsed.events
        tasks += parsed.tasks
    return AgendaData(events=tuple(events), tasks=tuple(tasks), fetched_at=now)
