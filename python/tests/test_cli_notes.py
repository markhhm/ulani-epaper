"""ulani note add / list / remove / clear, and the board kinds in ulani pages (no Bluetooth: sync.post is faked)."""

import json

import pytest

from ulani_epaper import cli, config, notes, sync
from ulani_epaper.client import PushEvent, UploadResult

BOARD_PAGES = {1: "month", 2: "agenda", 3: "board", 4: "message"}


@pytest.fixture
def posted(monkeypatch):
    """sync.post replaced by a fake that records each call and reports like the real one."""
    calls = []

    async def fake_post(settings=None, *, show="auto", progress=None, **kw):
        pages = settings.board_pages()
        target = sync.show_target(pages, show)
        calls.append({"show": show, "address": settings.address, "notes": notes.load(), "kw": kw})
        for i, slot in enumerate(pages):
            progress(PushEvent(slot, "start", i, len(pages)))
        if target:
            progress(PushEvent(target, "switching", len(pages), len(pages)))
        return sync.SyncReport(pages=dict(pages), notes=len(notes.load()), show=target,
                               results={slot: UploadResult.OK for slot in pages})

    monkeypatch.setattr(sync, "post", fake_post)
    return calls


def boards(pages=BOARD_PAGES):
    config.save(config.Settings(pages=dict(pages)))


def test_add_saves_then_posts_and_switches(capsys, posted):
    boards()
    assert cli.main(["note", "add", "晚餐在冰箱\\n六點回來", "--color", "red"]) == 0
    (note,) = notes.load()
    assert (note.text, note.color) == ("晚餐在冰箱\n六點回來", "red")
    (call,) = posted
    assert call["show"] == "auto" and call["notes"] == [note]  # saved before the push
    assert call["kw"] == {"flush_every": 10, "chunk_delay": 0.0}
    out = capsys.readouterr().out
    assert f"saved note {note.id}: 晚餐在冰箱 / 六點回來" in out
    assert "switching the display to page 4" in out
    assert "第 3 頁 留言板：已更新；第 4 頁 大字留言：已更新（1 則留言）" in out
    assert "the device shows page 4" in out


@pytest.mark.parametrize("show, page", [("board", 3), ("message", 4), ("none", None)])
def test_add_show_option(capsys, posted, show, page):
    boards()
    assert cli.main(["note", "add", "hi", "--show", show]) == 0
    assert posted[0]["show"] == show
    out = capsys.readouterr().out
    assert (f"the device shows page {page}" in out) if page else ("the device shows" not in out)


def test_address_before_or_after_the_command(posted):
    boards()
    assert cli.main(["-a", "AA:BB", "note", "add", "a"]) == 0
    assert cli.main(["note", "add", "b", "-a", "CC:DD"]) == 0
    assert [c["address"] for c in posted] == ["AA:BB", "CC:DD"]


def test_no_push_only_saves(capsys, posted):
    boards()
    assert cli.main(["note", "add", "hello", "--no-push"]) == 0
    assert posted == [] and [n.text for n in notes.load()] == ["hello"]


def test_add_without_a_board_page_saves_and_explains(capsys, posted):
    assert cli.main(["note", "add", "hello"]) == 1  # default pages: none is a board
    assert posted == [] and [n.text for n in notes.load()] == ["hello"]
    captured = capsys.readouterr()
    assert "saved note" in captured.out
    assert "the note is saved" in captured.err and "ulani pages 4=board" in captured.err
    assert "ulani note push" in captured.err and "ulani sync" not in captured.err  # a sync never redraws the board


@pytest.mark.parametrize("text, phrase", [("   ", "留言是空的"), ("字" * 301, "最多 300 字"),
                                          ("\\n".join("abcdefghi"), "最多 8 行")])
def test_bad_text_is_refused(capsys, posted, text, phrase):
    boards()
    assert cli.main(["note", "add", text]) == 1
    assert phrase in capsys.readouterr().err
    assert posted == [] and notes.load() == []


def test_bad_colour_is_refused(capsys, posted):
    with pytest.raises(SystemExit):
        cli.main(["note", "add", "x", "--color", "purple"])
    assert notes.load() == []


def test_list_newest_first(capsys):
    assert cli.main(["note", "list"]) == 0
    assert "no notes yet" in capsys.readouterr().out
    first = notes.add("第一則")
    second = notes.add("第二則\n第二行", "blue")
    assert cli.main(["note", "list"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0].split()[:2] == ["1", second.id] and lines[0].endswith("blue    第二則 / 第二行")
    assert lines[1].split()[:2] == ["2", first.id] and lines[1].endswith("yellow  第一則")
    assert notes.when(second) in lines[0]


def test_remove_by_position_and_id_pushes_without_switching(capsys, posted):
    boards()
    a, b, c = (notes.add(t) for t in ("a", "b", "c"))
    assert cli.main(["note", "remove", "2"]) == 0  # 1 = newest (c), 2 = b
    assert notes.load() == [c, a]
    assert cli.main(["note", "remove", a.id]) == 0
    assert notes.load() == [c]
    assert [p["show"] for p in posted] == ["none", "none"]
    out = capsys.readouterr().out
    assert f"removed note {b.id}: b" in out and "the device shows" not in out


def test_remove_unknown_note(capsys, posted):
    boards()
    notes.add("a")
    assert cli.main(["note", "remove", "5"]) == 1
    assert "沒有這則留言" in capsys.readouterr().err and posted == []


def test_clear(capsys, posted):
    boards()
    notes.add("a")
    notes.add("b")
    assert cli.main(["note", "clear"]) == 0
    assert notes.load() == [] and [p["show"] for p in posted] == ["none"]
    assert "removed 2 note(s)" in capsys.readouterr().out


def test_remove_and_clear_without_a_board_page_only_save(capsys, posted):
    notes.add("a")
    notes.add("b")
    assert cli.main(["note", "remove", "1"]) == 0
    assert cli.main(["note", "clear"]) == 0
    assert notes.load() == [] and posted == []


def test_a_damaged_notes_file_is_reported_not_overwritten(capsys, posted):
    boards()
    notes.notes_path().parent.mkdir(parents=True, exist_ok=True)
    notes.notes_path().write_text("{broken", encoding="utf-8")
    for argv in (["note", "list"], ["note", "add", "x"], ["note", "clear"]):
        assert cli.main(argv) == 1
        assert "notes file" in capsys.readouterr().err
    assert notes.notes_path().read_text(encoding="utf-8") == "{broken" and posted == []


def test_pages_accepts_the_board_kinds(capsys):
    assert cli.main(["pages", "3=board", "4=message"]) == 0
    assert config.load().pages == {1: "month", 2: "agenda", 3: "board", 4: "message"}
    out = capsys.readouterr().out
    assert "3  board   留言板" in out and "4  message 大字留言" in out
    raw = json.loads(config.settings_path().read_text(encoding="utf-8"))
    assert raw["pages"] == {"1": "month", "2": "agenda", "3": "board", "4": "message"}


def test_sync_with_only_board_pages_needs_no_calendar_packages(monkeypatch, capsys):
    import builtins

    real_import = builtins.__import__

    def no_icalendar(name, *args, **kw):
        if name.startswith("icalendar"):
            raise ModuleNotFoundError(f"No module named '{name}'", name=name)
        return real_import(name, *args, **kw)

    async def fake_sync(settings, dry_run=False, progress=None, **kw):
        return sync.SyncReport(pages={4: "board"}, notes=2, results=None)

    boards({1: "photo", 2: "photo", 3: "photo", 4: "board"})
    monkeypatch.setattr(builtins, "__import__", no_icalendar)
    monkeypatch.setattr(sync, "sync", fake_sync)
    assert cli.main(["sync", "--dry-run"]) == 0
    assert "第 4 頁 留言板：已繪製（未推送）（2 則留言）" in capsys.readouterr().out


def test_push_resends_the_board_without_a_new_note(capsys, posted):
    boards()
    notes.add("hello")
    assert cli.main(["note", "push", "-a", "AA:BB"]) == 0
    (call,) = posted
    assert call["show"] == "none" and call["address"] == "AA:BB" and [n.text for n in call["notes"]] == ["hello"]
    assert "第 3 頁 留言板：已更新" in capsys.readouterr().out
    assert cli.main(["note", "push", "--show", "message"]) == 0 and posted[-1]["show"] == "message"


def test_push_without_a_board_page_says_how_to_make_one(capsys, posted):
    assert cli.main(["note", "push"]) == 1
    err = capsys.readouterr().err
    assert posted == [] and "ulani pages 4=board" in err and "ulani note push" in err and "ulani sync" not in err
