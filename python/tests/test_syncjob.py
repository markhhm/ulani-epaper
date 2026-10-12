import json

import pytest

from ulani_epaper import config, syncjob
from ulani_epaper.client import UploadResult
from ulani_epaper.feeds import FeedError, NoFeeds
from ulani_epaper.sync import SyncReport


@pytest.fixture(autouse=True)
def config_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path))
    return tmp_path


def report():
    return SyncReport(pages={1: "month", 2: "agenda"}, events=12, tasks=5,
                      results={1: UploadResult.OK, 2: UploadResult.UNCHANGED})


def test_a_successful_run_is_logged_without_any_titles():
    assert syncjob.main([], sync_fn=lambda s: report(), sleep=None) == 0
    last = syncjob.last()
    assert last["ok"] is True and "time" in last
    assert last["message"] == "第 1 頁 本日＋月曆：已更新；第 2 頁 本日行程＋一週行程：沒有變化（12 個行程、5 項待辦）"


def test_no_feeds_is_not_retried():
    calls = []

    def fail(settings):
        calls.append(1)
        raise NoFeeds("尚未設定行事曆來源")

    assert syncjob.main([], sync_fn=fail, sleep=lambda s: pytest.fail("no retry")) == 2
    assert len(calls) == 1 and syncjob.last() == {**syncjob.last(), "ok": False, "message": "尚未設定行事曆來源"}


@pytest.mark.parametrize("damage", [
    "{\"time\": \"2026-10-12T06:00:00+08:00\", \"ok\": true, \"message\": \"第 1 頁頁".encode()[:-2] + b"\x00\x00",
    b"\n\n",
    b"not json\n",
    b"[1, 2]\n",
])
def test_a_damaged_log_never_stops_anything(config_dir, damage):
    syncjob.record(True, "earlier")
    with open(syncjob.log_path(), "ab") as f:
        f.write(damage)
    assert syncjob.last()["message"] == "earlier"  # the damaged line is skipped
    assert syncjob.main([], sync_fn=lambda s: report(), sleep=None) == 0
    assert syncjob.last()["ok"] is True  # and the next run repairs the file


def test_an_unwritable_log_does_not_fail_the_sync(monkeypatch):
    def readonly(*a, **kw):
        raise PermissionError("read-only")

    monkeypatch.setattr(syncjob.tempfile, "mkstemp", readonly)
    assert syncjob.record(True, "x") is False
    assert syncjob.main([], sync_fn=lambda s: report(), sleep=None) == 0


def test_other_failures_are_retried_then_reported():
    attempts, waits = [], []

    def flaky(settings):
        attempts.append(1)
        if len(attempts) < 3:
            raise FeedError("個人：無法連線到 calendar.google.com（gaierror）")  # Wi-Fi not back after sleep
        return report()

    assert syncjob.main([], sync_fn=flaky, sleep=waits.append, attempts=3, wait=120) == 0
    assert waits == [120, 120] and syncjob.last()["ok"] is True
    lines = syncjob.log_path().read_text(encoding="utf-8").splitlines()
    assert [json.loads(line)["ok"] for line in lines] == [False, False, True]


def test_gives_up_after_the_last_attempt():
    def down(settings):
        raise OSError("Bluetooth is off")

    assert syncjob.main([], sync_fn=down, sleep=lambda s: None, attempts=2) == 1
    assert syncjob.last() == {**syncjob.last(), "ok": False, "message": "Bluetooth is off"}


def test_a_broken_settings_file_is_reported(config_dir):
    config.settings_path().write_text("{oops", encoding="utf-8")
    assert syncjob.main([], sync_fn=lambda s: pytest.fail("must not sync"), sleep=None) == 1
    assert "settings" in syncjob.last()["message"]


def test_the_log_keeps_only_recent_runs():
    for _ in range(syncjob.KEEP + 10):
        syncjob.record(True, "x")
    assert len(syncjob.log_path().read_text(encoding="utf-8").splitlines()) == syncjob.KEEP


def test_no_log_yet():
    assert syncjob.last() is None


def test_nothing_to_sync_is_a_success():
    assert syncjob.main([], sync_fn=lambda s: SyncReport(), sleep=None) == 0
    assert syncjob.last()["message"] == "沒有設定成行事曆或待辦的頁面"


def test_board_pages_count_notes_instead_of_events():
    r = SyncReport(pages={4: "board"}, notes=3, results={4: UploadResult.OK})
    assert syncjob.describe(r) == "第 4 頁 留言板：已更新（3 則留言）"
    r = SyncReport(pages={1: "month", 2: "message"}, events=2, tasks=1, notes=1)
    assert syncjob.describe(r) == ("第 1 頁 本日＋月曆：已繪製（未推送）；第 2 頁 大字留言：已繪製（未推送）"
                                   "（2 個行程、1 項待辦、1 則留言）")


def test_dry_run_is_described():
    r = SyncReport(pages={3: "todo"}, events=0, tasks=2)
    assert syncjob.describe(r) == "第 3 頁 待辦清單：已繪製（未推送）（0 個行程、2 項待辦）"
