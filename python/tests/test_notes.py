import json
import re
from datetime import datetime, timedelta, timezone

import pytest

from ulani_epaper import config, notes
from ulani_epaper.notes import Note
from ulani_epaper.protocol import UlaniError

TPE = timezone(timedelta(hours=8))
NOW = datetime(2026, 10, 12, 14, 3, 27, 123456, tzinfo=TPE)


def test_no_file_means_no_notes(tmp_path):
    assert notes.load(tmp_path / "notes.json") == []


def test_the_file_lives_in_the_config_folder():
    assert notes.notes_path() == config.config_dir() / "notes.json"


def test_add_saves_newest_first_and_round_trips(tmp_path):
    path = tmp_path / "sub" / "notes.json"
    first = notes.add("晚餐在冰箱", now=NOW, path=path)
    second = notes.add("  我去接小孩\r\n六點前回來  ", "red", now=NOW + timedelta(hours=2), path=path)
    assert notes.load(path) == [second, first]
    assert second.text == "我去接小孩\n六點前回來" and second.color == "red"
    assert first == Note(first.id, "晚餐在冰箱", "2026-10-12T14:03:27+08:00", "yellow")
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw == {"version": 1, "notes": [
        {"id": second.id, "text": "我去接小孩\n六點前回來", "at": "2026-10-12T16:03:27+08:00", "color": "red"},
        {"id": first.id, "text": "晚餐在冰箱", "at": "2026-10-12T14:03:27+08:00", "color": "yellow"},
    ]}
    assert "晚餐" in path.read_text(encoding="utf-8")  # readable UTF-8, not \u escapes
    assert [p.name for p in path.parent.iterdir()] == ["notes.json"]  # no temporary files left


def test_the_default_location_and_time(monkeypatch, tmp_path):
    monkeypatch.setenv("ULANI_CONFIG_DIR", str(tmp_path))
    note = notes.add("hi")
    assert (tmp_path / "notes.json").exists() and notes.load() == [note]
    assert note.written().tzinfo is not None and abs(note.written() - datetime.now(timezone.utc)) < timedelta(1)


def test_ids_are_eight_hex_characters_and_unique(tmp_path, monkeypatch):
    path = tmp_path / "notes.json"
    tokens = iter(["aaaaaaaa", "aaaaaaaa", "bbbbbbbb"])
    monkeypatch.setattr(notes.secrets, "token_hex", lambda n: next(tokens))
    assert notes.add("a", path=path).id == "aaaaaaaa"
    assert notes.add("b", path=path).id == "bbbbbbbb"  # the repeat was drawn again
    monkeypatch.undo()
    ids = [notes.add(str(i), path=path).id for i in range(20)]
    assert all(re.fullmatch(r"[0-9a-f]{8}", i) for i in ids) and len(set(ids)) == 20


def test_adding_beyond_the_limit_drops_the_oldest(tmp_path):
    path = tmp_path / "notes.json"
    for i in range(notes.MAX_NOTES + 2):
        notes.add(f"留言 {i}", now=NOW + timedelta(minutes=i), path=path)
    kept = notes.load(path)
    assert len(kept) == notes.MAX_NOTES == 50
    assert kept[0].text == "留言 51" and kept[-1].text == "留言 2"


@pytest.mark.parametrize("text, message", [
    ("", "留言是空的"),
    (" \n\t ", "留言是空的"),
    ("字" * 301, "最多 300 字"),
    ("\n".join("一二三四五六七八九"), "最多 8 行"),
])
def test_unacceptable_text_is_refused(tmp_path, text, message):
    with pytest.raises(ValueError, match=message):
        notes.add(text, path=tmp_path / "notes.json")
    assert not (tmp_path / "notes.json").exists()


def test_limits_count_after_composing_and_stripping(tmp_path):
    decomposed = "é" * 300  # 600 code points, 300 characters once composed
    note = notes.add("  " + decomposed + "  ", path=tmp_path / "n.json")
    assert note.text == "é" * 300
    assert notes.add("\n".join("一二三四五六七八"), path=tmp_path / "n.json").text.count("\n") == 7
    assert len(notes.normalize(" a\r\nb ")) == 3


def test_unknown_colours_are_refused(tmp_path):
    with pytest.raises(ValueError, match="yellow, orange, green, blue, red"):
        notes.add("x", "purple", path=tmp_path / "notes.json")
    assert notes.NOTE_COLOURS == ("yellow", "orange", "green", "blue", "red")


@pytest.mark.parametrize("content", [
    "{not json",
    '{"version": 2, "notes": []}',
    '{"notes": []}',
    '{"version": 1}',
    '{"version": 1, "notes": [{"id": "XYZ", "text": "a", "at": "2026-10-12T14:03:00+08:00"}]}',
    '{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "", "at": "2026-10-12T14:03:00+08:00"}]}',
    '{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "yesterday"}]}',
    '{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00"}]}',
    '{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00", "color": "pink"}]}',
    '{"version": 1, "notes": [{"id": "a1b2c3d4", "text": 5, "at": "2026-10-12T14:03:00+08:00"}]}',
    '[1, 2]',
])
def test_a_damaged_file_is_named_and_never_overwritten(tmp_path, content):
    path = tmp_path / "notes.json"
    path.write_text(content, encoding="utf-8")
    for action in (lambda: notes.load(path), lambda: notes.add("x", path=path), lambda: notes.clear(path),
                   lambda: notes.remove(1, path)):
        with pytest.raises(UlaniError, match=re.escape(str(path))):
            action()
    assert path.read_text(encoding="utf-8") == content


def test_duplicate_ids_in_the_file_are_invalid(tmp_path):
    path = tmp_path / "notes.json"
    note = {"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00", "color": "yellow"}
    path.write_text(json.dumps({"version": 1, "notes": [note, note]}), encoding="utf-8")
    with pytest.raises(UlaniError, match="invalid"):
        notes.load(path)


def test_a_missing_colour_in_the_file_means_yellow(tmp_path):
    path = tmp_path / "notes.json"
    path.write_text('{"version": 1, "notes": [{"id": "a1b2c3d4", "text": "a", "at": "2026-10-12T14:03:00+08:00"}]}',
                    encoding="utf-8")
    assert notes.load(path) == [Note("a1b2c3d4", "a", "2026-10-12T14:03:00+08:00", "yellow")]


def test_save_validates(tmp_path):
    with pytest.raises(ValueError):
        notes.save([Note("a1b2c3d4", "a", "2026-10-12T14:03:00+08:00", "pink")], tmp_path / "n.json")
    with pytest.raises(ValueError):
        notes.save([Note("a1b2c3d4", " a ", "2026-10-12T14:03:00+08:00")], tmp_path / "n.json")
    assert not (tmp_path / "n.json").exists()


def _three(path):
    return [notes.add(t, now=NOW + timedelta(minutes=i), path=path) for i, t in enumerate("abc")][::-1]


def test_remove_by_id_or_by_position(tmp_path):
    path = tmp_path / "notes.json"
    c, b, a = _three(path)
    assert notes.remove(b.id, path) == b
    assert notes.load(path) == [c, a]
    assert notes.remove(2, path) == a  # 1-based, newest first
    assert notes.remove(" 1 ", path) == c
    assert notes.load(path) == []


def test_remove_accepts_an_id_in_capitals(tmp_path):
    path = tmp_path / "notes.json"
    c, _, _ = _three(path)
    assert notes.remove(c.id.upper(), path) == c


def test_an_id_made_of_digits_wins_over_a_position(tmp_path, monkeypatch):
    path = tmp_path / "notes.json"
    ids = iter(["00000002", "00000001"])
    monkeypatch.setattr(notes.secrets, "token_hex", lambda n: next(ids))
    older, newer = notes.add("older", path=path), notes.add("newer", path=path)
    assert notes.remove("00000002", path) == older
    assert notes.load(path) == [newer]


@pytest.mark.parametrize("key", [0, 4, "-1", "zzzzzzzz", ""])
def test_removing_an_unknown_note_raises_and_keeps_the_file(tmp_path, key):
    path = tmp_path / "notes.json"
    _three(path)
    before = path.read_bytes()
    with pytest.raises(UlaniError, match="沒有這則留言"):
        notes.remove(key, path)
    assert path.read_bytes() == before


def test_removing_from_an_empty_board(tmp_path):
    with pytest.raises(UlaniError, match="目前沒有留言"):
        notes.remove(1, tmp_path / "notes.json")


def test_clear(tmp_path):
    path = tmp_path / "notes.json"
    assert notes.clear(path) == 0 and not path.exists()
    _three(path)
    assert notes.clear(path) == 3
    assert notes.load(path) == [] and json.loads(path.read_text(encoding="utf-8")) == {"version": 1, "notes": []}
