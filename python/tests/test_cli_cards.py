"""ulani card list | add | push | export | import (no Bluetooth: sync.push_card is faked)."""

import pytest
from PIL import Image

from ulani_epaper import cards, cli, config, sync
from ulani_epaper.client import UploadResult


@pytest.fixture
def pushed(monkeypatch):
    calls = []

    async def fake_push_card(settings, card, *, progress=None, **kw):
        calls.append({"card": card, "address": settings.address, "kw": kw})
        return sync.SyncReport(pages={3: "card"}, show=3, results={3: UploadResult.OK})

    monkeypatch.setattr(sync, "push_card", fake_push_card)
    return calls


def test_add_a_colour_card_with_texts_then_list(capsys):
    assert cli.main(["card", "add", "yellow", "開會中", "15:00 回來"]) == 0
    (card,) = cards.load()
    assert card.background == cards.Background("yellow") and [t.text for t in card.texts] == ["開會中", "15:00 回來"]
    assert all(t.color == "black" for t in card.texts)  # readable on yellow
    assert f"saved card {card.id}" in capsys.readouterr().out
    assert cli.main(["card", "list"]) == 0
    out = capsys.readouterr().out
    assert card.id in out and "yellow" in out and "開會中 / 15:00 回來" in out


def test_add_a_photo_card_draws_white_text_with_a_black_outline(tmp_path):
    Image.new("RGB", (1000, 600), (0, 0, 255)).save(tmp_path / "meme.png")
    assert cli.main(["card", "add", str(tmp_path / "meme.png"), "上班囉"]) == 0
    (card,) = cards.load()
    assert card.background.image == f"{card.id}.jpg" and (cards.backgrounds_dir() / card.background.image).is_file()
    (text,) = card.texts
    assert (text.color, text.outline, text.outline_color) == ("white", True, "black")


def test_add_rejects_what_is_not_a_card(capsys):
    assert cli.main(["card", "add", "nowhere.png", "hi"]) == 1
    assert "nowhere.png" in capsys.readouterr().err
    assert cli.main(["card", "add", "white", "x" * 81]) == 1
    assert "80" in capsys.readouterr().err
    assert cards.load() == []


def test_push_by_id_or_number(capsys, pushed):
    config.save(config.Settings(pages={1: "month", 2: "agenda", 3: "card", 4: "photo"}))
    cli.main(["card", "add", "red", "第一張"])
    cli.main(["card", "add", "green", "第二張"])
    newest, older = cards.load()
    capsys.readouterr()
    assert cli.main(["card", "push", "2", "-a", "AA:BB"]) == 0
    assert pushed[-1]["card"] == older and pushed[-1]["address"] == "AA:BB"
    out = capsys.readouterr().out
    assert "第 3 頁 牌卡：已更新" in out and "the device shows page 3" in out
    assert cli.main(["card", "push", newest.id]) == 0 and pushed[-1]["card"] == newest


def test_push_remembers_the_card_pages(pushed, monkeypatch):
    async def remembering(settings, card, **kw):
        settings.card_pages[3] = "hash"
        return sync.SyncReport(pages={3: "card"}, show=3, results={3: UploadResult.OK})

    monkeypatch.setattr(sync, "push_card", remembering)
    config.save(config.Settings(pages={1: "month", 2: "agenda", 3: "card", 4: "photo"}))
    cli.main(["card", "add", "red", "x"])
    assert cli.main(["card", "push", "1"]) == 0
    assert config.load().card_pages == {3: "hash"}  # saved for the next push


def test_push_without_a_card_page_says_so(capsys):
    cli.main(["card", "add", "red", "x"])
    capsys.readouterr()
    assert cli.main(["card", "push", "1"]) == 1  # the default pages have no card page; sync.push_card is real
    err = capsys.readouterr().err
    assert "沒有牌卡頁" in err and "ulani pages 4=card" in err  # the page to offer: the photo page


def test_push_unknown_card(capsys, pushed):
    assert cli.main(["card", "push", "nope"]) == 1
    assert "nope" in capsys.readouterr().err and pushed == []


def test_export_and_import(tmp_path, capsys):
    cli.main(["card", "add", "blue", "晚點回"])
    (card,) = cards.load()
    file = tmp_path / "away.paperhue-card"
    assert cli.main(["card", "export", card.id, str(file)]) == 0 and file.is_file()
    assert cli.main(["card", "import", str(file)]) == 0
    imported, original = cards.load()
    assert original == card and imported.id != card.id and imported.texts == card.texts
    assert f"imported card {imported.id}" in capsys.readouterr().out


def test_import_a_file_that_is_not_a_card(tmp_path, capsys):
    (tmp_path / "x.paperhue-card").write_bytes(b"not a zip")
    assert cli.main(["card", "import", str(tmp_path / "x.paperhue-card")]) == 1
    assert "error:" in capsys.readouterr().err and cards.load() == []


def test_list_without_cards(capsys):
    assert cli.main(["card", "list"]) == 0
    assert "ulani card add" in capsys.readouterr().out


def test_push_saves_only_the_card_pages_not_a_stale_copy_of_the_settings(monkeypatch):
    async def push_while_the_gui_saves(settings, card, **kw):
        gui = config.load()  # the app changes a page while the (slow) push is running
        gui.pages[1] = "todo"
        config.save(gui)
        settings.card_pages[3] = "hash"
        return sync.SyncReport(pages={3: "card"}, show=3, results={3: UploadResult.OK})

    monkeypatch.setattr(sync, "push_card", push_while_the_gui_saves)
    config.save(config.Settings(pages={1: "month", 2: "agenda", 3: "card", 4: "photo"}))
    cli.main(["card", "add", "red", "x"])
    assert cli.main(["card", "push", "1", "-a", "AA:BB"]) == 0
    saved = config.load()
    assert saved.card_pages == {3: "hash"} and saved.pages[1] == "todo" and saved.address is None


def test_preload_puts_the_cards_on_the_card_pages_in_order(capsys, monkeypatch):
    calls = []

    async def fake_preload(settings, cards_, *, progress=None, **kw):
        calls.append((list(cards_), settings.address))
        settings.card_pages.update({2: "h2", 3: "h3"})
        return sync.SyncReport(pages={2: "card", 3: "card"}, results={2: UploadResult.OK, 3: UploadResult.OK})

    monkeypatch.setattr(sync, "preload_cards", fake_preload)
    config.save(config.Settings(pages={1: "month", 2: "card", 3: "card", 4: "photo"}))
    cli.main(["card", "add", "red", "第一張"])
    cli.main(["card", "add", "green", "第二張"])
    newest, older = cards.load()
    assert cli.main(["card", "preload", older.id, "1", "-a", "AA:BB"]) == 0
    assert calls == [([older, newest], "AA:BB")]
    assert config.load().card_pages == {2: "h2", 3: "h3"} and config.load().address is None
    assert "第 2 頁 牌卡：已更新" in capsys.readouterr().out


def test_preload_without_a_card_page_says_so(capsys):
    cli.main(["card", "add", "red", "x"])
    capsys.readouterr()
    assert cli.main(["card", "preload", "1"]) == 1
    assert "ulani pages 4=card" in capsys.readouterr().err
