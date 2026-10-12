"""ulani pages / feeds / sync / schedule."""

from pathlib import Path

import pytest

from ulani_epaper import cli, config, feeds, schedule, sync, syncjob
from ulani_epaper.client import UploadResult

ICS = Path(__file__).resolve().parents[2] / "shared" / "vectors" / "ical"
SECRET = "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123abcd/basic.ics"


@pytest.fixture(autouse=True)
def config_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path))
    return tmp_path


def test_dash_dash_sync_runs_the_scheduled_job(monkeypatch):
    monkeypatch.setattr(syncjob, "main", lambda argv=None: 7)
    assert cli.main(["--sync"]) == 7


def test_pages_shows_the_defaults(capsys):
    assert cli.main(["pages"]) == 0
    out = capsys.readouterr().out
    assert "1  month" in out and "4  photo" in out


def test_pages_assigns_kinds(capsys):
    assert cli.main(["pages", "1=todo", "4=agenda"]) == 0
    assert config.load().pages == {1: "todo", 2: "agenda", 3: "todo", 4: "agenda"}


@pytest.mark.parametrize("arg", ["5=month", "1=weather", "month", "x=todo"])
def test_pages_rejects_bad_assignments(capsys, arg):
    assert cli.main(["pages", arg]) == 1
    assert capsys.readouterr().err.startswith("error: ")
    assert config.load().pages == config.DEFAULT_PAGES


@pytest.fixture
def web(monkeypatch):
    """feeds.download answers from the fixture files; records what was asked."""
    asked = []

    def download(url, user="", password="", **kw):
        asked.append((url, user, password))
        if "broken" in url:
            raise feeds.FeedError("HTTP 404（找不到：網址可能已重設或刪除）")
        return (ICS / ("todos.ics" if "tasks" in url else "google.ics")).read_bytes()

    monkeypatch.setattr(feeds, "download", download)
    return asked


@pytest.fixture
def typed(monkeypatch):
    """What the user pastes at the hidden prompts, in order."""
    answers = []
    monkeypatch.setattr(cli, "_ask_secret", lambda prompt: answers.pop(0))
    return answers


def test_add_a_feed_by_pasting_the_address(capsys, web, typed):
    typed.append(SECRET)
    assert cli.main(["feeds", "add", "個人", "--color", "blue"]) == 0
    out = capsys.readouterr().out
    assert "ok:" in out and "added 個人" in out
    assert "private-0123abcd" not in out  # the secret part of the address is never printed
    (feed,) = config.load().feeds
    assert (feed.name, feed.color) == ("個人", "blue")
    assert feeds.KeyringSecrets().get(feed.id)["url"] == SECRET
    assert SECRET not in config.settings_path().read_text(encoding="utf-8")


def test_add_with_a_login(capsys, web, typed):
    typed.append("app-password")
    assert cli.main(["feeds", "add", "家務", "https://cloud.example/tasks?export", "--user", "me"]) == 0
    assert web[-1] == ("https://cloud.example/tasks?export", "me", "app-password")
    (feed,) = config.load().feeds
    assert feeds.KeyringSecrets().get(feed.id)["password"] == "app-password"


def test_a_broken_address_is_not_saved(capsys, web, typed):
    typed.append("https://x/broken.ics")
    assert cli.main(["feeds", "add", "壞的"]) == 1
    assert "404" in capsys.readouterr().err and config.load().feeds == []


def test_list_test_edit_remove(capsys, web, typed):
    typed.append(SECRET)
    cli.main(["feeds", "add", "個人"])
    capsys.readouterr()
    assert cli.main(["feeds"]) == 0
    out = capsys.readouterr().out
    assert "個人" in out and "calendar.google.com" in out and "private-" not in out
    assert cli.main(["feeds", "test"]) == 0
    assert "個人:" in capsys.readouterr().out
    assert cli.main(["feeds", "edit", "個人", "--name", "我的", "--color", "green"]) == 0
    assert [(f.name, f.color) for f in config.load().feeds] == [("我的", "green")]
    typed.append("https://x/broken.ics")
    assert cli.main(["feeds", "edit", "我的", "--url"]) == 1  # a bad new address keeps the old one
    feed_id = config.load().feeds[0].id
    assert feeds.KeyringSecrets().get(feed_id)["url"] == SECRET
    assert cli.main(["feeds", "remove", "我的"]) == 0
    assert config.load().feeds == [] and feeds.KeyringSecrets().get(feed_id) is None


def test_an_address_given_as_the_name_is_refused(capsys, web):
    assert cli.main(["feeds", "add", SECRET]) == 1
    assert "private-" not in capsys.readouterr().err and config.load().feeds == []


def test_feeds_without_any(capsys):
    assert cli.main(["feeds"]) == 1
    assert "ulani feeds add" in capsys.readouterr().out


def test_unknown_feed(capsys):
    assert cli.main(["feeds", "remove", "nope"]) == 1
    assert capsys.readouterr().err.startswith("error: no calendar source")


def test_sync_prints_what_changed(monkeypatch, capsys):
    seen = {}

    async def fake_sync(settings, dry_run=False, progress=None, **kw):
        seen.update(settings=settings, dry_run=dry_run)
        return sync.SyncReport(pages={1: "month"}, events=3, tasks=1,
                               results=None if dry_run else {1: UploadResult.OK})

    monkeypatch.setattr(sync, "sync", fake_sync)
    assert cli.main(["sync", "-a", "AA:BB"]) == 0
    assert seen["settings"].address == "AA:BB" and seen["dry_run"] is False
    assert "第 1 頁 月曆：已更新" in capsys.readouterr().out
    assert cli.main(["sync", "--dry-run"]) == 0
    assert seen["dry_run"] is True and seen["settings"].address is None


def test_schedule_install_saves_the_times(monkeypatch, capsys):
    installed = []
    monkeypatch.setattr(schedule, "install", lambda times: installed.append(times))
    assert cli.main(["schedule", "install", "--times", "07:00", "19:30"]) == 0
    assert installed == [["07:00", "19:30"]] and config.load().times == ["07:00", "19:30"]
    assert "07:00, 19:30" in capsys.readouterr().out


def test_schedule_install_rejects_bad_times(monkeypatch, capsys):
    monkeypatch.setattr(schedule, "install", lambda times: pytest.fail("must not install"))
    assert cli.main(["schedule", "install", "--times", "7pm"]) == 1
    assert capsys.readouterr().err.startswith("error: ")


def test_schedule_status_and_remove(monkeypatch, capsys):
    monkeypatch.setattr(schedule, "status", lambda: {"times": ["06:00"], "command": "x.exe", "arguments": "--sync"})
    monkeypatch.setattr(schedule, "remove", lambda: True)
    syncjob.record(True, "第 1 頁 月曆：已更新（3 個行程、1 項待辦）")
    assert cli.main(["schedule", "status"]) == 0
    out = capsys.readouterr().out
    assert "06:00" in out and "x.exe --sync" in out and "第 1 頁 月曆：已更新" in out
    assert cli.main(["schedule", "remove"]) == 0
    monkeypatch.setattr(schedule, "status", lambda: None)
    assert cli.main(["schedule", "status"]) == 1
    assert "not scheduled" in capsys.readouterr().out


def test_selftest_draws_the_pages_and_reads_ical(capsys):
    assert cli.main(["selftest"]) == 0
    out = capsys.readouterr().out
    assert "month" in out and "agenda" in out and "todo" in out and "ical" in out and out.rstrip().endswith("ok")
    assert "board: drawn" in out and "message: drawn" in out


def test_selftest_fails_without_the_fonts(monkeypatch, capsys, tmp_path):
    from ulani_epaper import fonts

    fonts.load.cache_clear()
    monkeypatch.setattr(fonts, "_DIR", str(tmp_path))
    try:
        assert cli.main(["selftest"]) == 1
        assert "FAILED" in capsys.readouterr().out
    finally:
        fonts.load.cache_clear()


def test_missing_calendar_packages_are_explained(monkeypatch, capsys):
    import builtins

    real_import = builtins.__import__

    def no_icalendar(name, *args, **kw):
        if name.startswith("icalendar"):
            raise ModuleNotFoundError(f"No module named '{name}'", name=name)
        return real_import(name, *args, **kw)

    monkeypatch.setattr(builtins, "__import__", no_icalendar)
    assert cli.main(["feeds"]) == 1
    assert "ulani-epaper[calendar]" in capsys.readouterr().err


def test_schedule_install_needs_a_time_when_none_is_saved(monkeypatch, capsys):
    monkeypatch.setattr(schedule, "install", lambda times: pytest.fail("must not install"))
    assert cli.main(["schedule", "install"]) == 1
    assert "at least one time" in capsys.readouterr().err
