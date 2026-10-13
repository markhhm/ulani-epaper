"""Expected drawing calls of the message board pages, computed with the Python reference.

Writes board-expectations.json next to this file. Run from the repository root with a Python
that has ulani_epaper installed (python/):

    python apple/UlaniKit/Tests/PaperhuePagesTests/Differential/make_board_expectations.py

"cases": render_board and render_message for the shared board fixtures, the inputs of
python/tests/test_board_layouts.py, a few malformed notes and seeded random boards. Each case
is its notes ([id, text, at, color], newest first), its zone ("+HH:MM" or an IANA name) and
the drawing calls of each page, logged as make_page_expectations.py logs them.

The output is deterministic (fixed random seed).
"""

import json
import random
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in the test target
from make_page_expectations import logged, zone_of  # noqa: E402

from ulani_epaper import layouts  # noqa: E402
from ulani_epaper.notes import Note  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]  # PaperhuePagesTests, Tests, UlaniKit, apple, repository root
FIXTURES = REPO / "shared" / "layouts" / "board"
AT = "2026-10-12T14:03:00+08:00"

rng = random.Random(20261012)

TEXTS = ["記得澆花", "晚餐在冰箱，微波 3 分鐘就好", "我去接小孩，\n六點前回來", "垃圾車 19:30", "🎂🎉", "Wi-Fi 密碼已更換",
         "The plumber may call around 5 pm about the kitchen sink", "Supercalifragilisticexpialidocious" * 2,
         "讀完《原子習慣》，再寫心得。", "買牛奶\n\n🎂\n繳電費", "好", "出門了", "  前後有空白  ", "a\tb\r\nc"]
COLOURS = ["yellow", "orange", "green", "blue", "red"]


def case(name, notes, zone="+08:00"):
    notes = [Note(*n) for n in notes]
    return {"name": name, "zone": zone, "notes": [[n.id, n.text, n.at, n.color] for n in notes],
            "board": logged(layouts.render_board, notes, zone_of(zone)),
            "message": logged(layouts.render_message, notes, zone_of(zone))}


def note(text, color="yellow", at=AT, id="a1b2c3d4"):
    return [id, text, at, color]


def random_text():
    if rng.random() < 0.3:
        return rng.choice(TEXTS)
    pool = "我們今天晚上七點在家吃飯記得買菜，。！abc Paperhue 123 🎉"
    lines = ["".join(rng.choice(pool) for _ in range(rng.randint(0, 60))) for _ in range(rng.randint(1, 4))]
    return "\n".join(lines)


def cases():
    out = []
    for path in sorted(FIXTURES.glob("*.json")):
        obj = json.loads(path.read_text(encoding="utf-8"))
        notes = [[n["id"], n["text"], n["at"], n.get("color", "yellow")] for n in obj["notes"]]
        out.append(case(f"fixture {path.stem}", notes, obj["utc_offset"]))
    # test_board_layouts.py
    for n in range(1, 7):
        out.append(case(f"grid {n}", [note("記得澆花", COLOURS[i % 5], id=f"0000000{i}") for i in range(n)]))
    out.append(case("eight", [note(f"第{i}則", id=f"0000000{i}") for i in range(8)]))
    for colour in COLOURS:
        out.append(case(f"colour {colour}", [note("記得澆花", colour)]))
    out.append(case("short", [note("短")]))
    out.append(case("never fits", [note("字" * 300, id=f"0000000{i}") for i in range(6)]))
    out.append(case("line breaks", [note("買牛奶\n繳電費")]))
    out.append(case("empty lines", [note("買牛奶\n\n🎂\n繳電費")]))
    for text in ("🎂🎉", "‍", "（無法顯示的留言）", "好", "晚餐在冰箱，微波 3 分鐘就好", "字" * 60, "字" * 300):
        out.append(case(f"text {text!r}", [note(text)]))
    for zone in ("+08:00", "+00:00"):
        out.append(case(f"utc note in {zone}", [note("x", at="2026-10-11T17:05:00+00:00")], zone))
    out.append(case("newest only", [note("新的", id="00000001", at="2026-10-12T18:00:00+08:00"),
                                    note("舊的", id="00000002")]))
    # malformed notes are drawn, never refused
    out.append(case("bad time and colour", [note("時間壞了", "purple", at="not a time"), note("沒有時區", at="2026-10-12T14:03:00")]))
    zones = ["+08:00", "+00:00", "-07:00", "America/New_York", "+05:45"]
    for i in range(30):
        n = rng.randint(1, 8)
        notes = [note(random_text(), rng.choice(COLOURS), id=f"{i:04d}{j:04d}",
                      at=f"2026-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}T{rng.randint(0, 23):02d}:"
                         f"{rng.randint(0, 59):02d}:00{rng.choice(['+08:00', '+00:00', '-05:00'])}")
                 for j in range(n)]
        out.append(case(f"random {i}", notes, rng.choice(zones)))
    return out


def main():
    items = cases()
    lines = ["{", ' "cases": [']
    lines += [f"  {json.dumps(c, ensure_ascii=False)}" + ("," if i < len(items) - 1 else "") for i, c in enumerate(items)]
    lines += [" ]", "}"]
    (HERE / "board-expectations.json").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
