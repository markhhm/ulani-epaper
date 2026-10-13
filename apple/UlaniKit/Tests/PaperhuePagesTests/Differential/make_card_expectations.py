"""Expected results for the Swift cards (牌卡), computed with the Python reference.

Writes next to this file. Run from the repository root with a Python that has ulani_epaper
installed (python/):

    python apple/UlaniKit/Tests/PaperhuePagesTests/Differential/make_card_expectations.py

card-expectations.json:
  "cases": render_card for the shared card fixtures (on white where they have a photo), the
  inputs of python/tests/test_card_layouts.py and seeded random cards. Each case is the card
  (cards.to_json) and its drawing calls, one tab-separated line each: the background "rect",
  and for each string drawn "text" (x, y as drawn, anchor, size, bold 0/1, colour, string, as
  make_page_expectations.py logs them), preceded by "outline" (radius, colour) when it has one.
  "file": cards.json as cards.save writes the four fixtures.
exported.paperhue-card: a card with a photo and a crop, as cards.export_card writes it.

meme.json's background is the agenda photo fixture's (the same file, uncropped), so the Swift golden
tests draw it on photo-background.png (make_page_expectations.py).

The output is deterministic (fixed random seed), except the exported card's id and the zip's timestamps.
"""

import json
import random
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

from ulani_epaper import cards, layouts
from ulani_epaper.cards import Background, Card, TextBox

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]  # PaperhuePagesTests, Tests, UlaniKit, apple, repository root
FIXTURES = REPO / "shared" / "layouts" / "card"
NAMES = ["lines", "meme", "quote", "status"]
NAME_OF = {rgb: name for name, rgb in layouts.RGB.items()}

rng = random.Random(20261013)


def fixture(name):
    return cards.parse(json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8")))


def logged(card):
    """The drawing calls of render_card(card), drawn on white if it has a photo."""
    ops, calls = [], []

    def line(*fields):
        ops.append("\t".join(str(f) for f in fields))

    original_draw, original_text, original_rect = ImageDraw.ImageDraw.text, layouts._Page.text, layouts._Page.rect

    def draw(self, xy, s, fill=None, font=None, anchor=None, *a, **k):
        calls.append(("text", xy[0], xy[1], anchor, font.size, 1 if "Bold" in font.path else 0, NAME_OF[fill], s))
        return original_draw(self, xy, s, fill, font, anchor, *a, **k)

    def text(self, x, y, s, size, bold=False, fill=layouts.INK, anchor="ls", maxw=None, outline=0, outline_fill=None):
        calls.clear()
        width = original_text(self, x, y, s, size, bold, fill, anchor, maxw, outline, outline_fill)
        if calls:  # the outline's offsets first, then the text itself
            if outline:
                line("outline", outline, NAME_OF[outline_fill])
            line(*calls[-1])
        return width

    def rect(self, x0, y0, x1, y1, fill=layouts.INK):
        line("rect", x0, y0, x1, y1, NAME_OF[fill])
        return original_rect(self, x0, y0, x1, y1, fill)

    ImageDraw.ImageDraw.text, layouts._Page.text, layouts._Page.rect = draw, text, rect
    try:
        white = Image.new("RGB", (layouts.W, layouts.H), layouts.PAPER) if card.background.image else None
        layouts.render_card(card, background=white)
    finally:
        ImageDraw.ImageDraw.text, layouts._Page.text, layouts._Page.rect = original_draw, original_text, original_rect
    return ops


def case(name, card):
    card = cards.check(card)
    return {"name": name, "card": cards.to_json(card), "ops": logged(card)}


def one(text="好", box=(0.25, 0.25, 0.5, 0.5), background=Background("white"), **kw):
    return Card("a1b2c3d4", background, (TextBox(text, box, **kw),))


TEXTS = ["暫離", "開會中，15:00 回來", "🎂🎉", "Wi-Fi 密碼已更換", "讀完《原子習慣》，再寫心得。", "上\n\n下",
         "Supercalifragilisticexpialidocious", "The plumber may call around 5 pm", "a\tb\nc", "\n\n上\n\n",
         "好", "字" * 80]
POOL = "我們今天晚上七點在家吃飯記得買菜，。！abc Paperhue 123 🎉\n"


def random_text():
    if rng.random() < 0.3:
        return rng.choice(TEXTS)
    text = cards.normalize("".join(rng.choice(POOL) for _ in range(rng.randint(1, 80))))
    return text or "空"


def random_box():
    x, y = round(rng.uniform(0, 0.8), 4), round(rng.uniform(0, 0.8), 4)
    return x, y, round(rng.uniform(0.02, 1 - x), 4), round(rng.uniform(0.02, 1 - y), 4)


def random_card():
    texts = tuple(TextBox(random_text(), random_box(), rng.randint(12, 240), rng.choice(cards.INKS),
                          rng.random() < 0.5, rng.choice(cards.INKS), rng.choice(cards.ALIGNS))
                  for _ in range(rng.randint(0, 8)))
    return Card("a1b2c3d4", Background(rng.choice(cards.INKS)), texts)


def cases():
    out = [case(f"fixture {name}", fixture(name)) for name in NAMES]
    # test_card_layouts.py
    out += [case(f"background {c}", Card("a1b2c3d4", Background(c))) for c in ("white", "orange", "blue")]
    out += [case(f"align {a}", one(align=a, size=40)) for a in cards.ALIGNS]
    out.append(case("wraps", one("字" * 60, box=(0.2, 0.1, 0.3, 0.8), size=30)))
    out.append(case("cut", one("字" * 80, box=(0.2, 0.1, 0.3, 0.2), size=30)))
    out.append(case("line break", one("上\n下", size=40)))
    out.append(case("blank line", one("上\n\n上", size=40)))
    out.append(case("blank ends", one("\u200b\n上\n\u200b", (0.25, 0.25, 0.5, 0.1), size=40)))
    for align in ("left", "right"):
        out.append(case(f"outline {align}", one("字字", background=Background("yellow"), color="white", size=64,
                                                outline=True, outline_color="black", align=align)))
    # the edges: the biggest outline, a box too narrow for its outline, nothing drawable, a tiny box
    out.append(case("size 240 outlined", one("國", box=(0, 0, 1, 1), size=240, outline=True)))
    out.append(case("narrow outlined", one("字", box=(0.5, 0.5, 0.01, 0.5), size=240, outline=True)))
    out.append(case("emoji only", one("🎂🎉")))
    out.append(case("tiny box", one("開會中", box=(0.9, 0.95, 0.1, 0.05), size=12, align="right")))
    out += [case(f"random {i}", random_card()) for i in range(40)]
    return out


def write_export(folder: Path) -> None:
    """A card with a crop and a small photo, exported by the reference."""
    folder.mkdir()
    photo = folder / "photo.png"
    with Image.open(FIXTURES / "background.png") as img:
        img.convert("RGB").resize((400, 240)).save(photo)
    card = cards.add(Card(background=Background(crop=(0.25, 0.25, 0.5, 0.5)),
                          texts=(TextBox("我選擇繼續裝忙", (0.04, 0.72, 0.92, 0.24), 52, "white", True, "black"),)),
                     photo=photo, folder=folder)
    cards.export_card(card.id, HERE / "exported.paperhue-card", folder)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        cards.save([fixture(name) for name in NAMES], tmp)
        file = cards.cards_path(tmp).read_text(encoding="utf-8")
        write_export(Path(tmp) / "export")
    items = cases()
    lines = ["{", ' "cases": [']
    lines += [f"  {json.dumps(c, ensure_ascii=False)}" + ("," if i < len(items) - 1 else "") for i, c in enumerate(items)]
    lines += [" ],", f' "file": {json.dumps(file, ensure_ascii=False)}', "}"]
    (HERE / "card-expectations.json").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
