"""Expected results for the Swift page fonts and text rules, computed with the Python reference.

Writes text-expectations.json next to this file. Run from the repository root with a Python
that has ulani_epaper installed (python/):

    python apple/UlaniKit/Tests/PaperhuePagesTests/Differential/make_text_expectations.py

Widths are Pillow's ImageFont.getlength with the bundled fonts (fonts.load: BASIC layout, so
whole pixels); "bold" is 0 or 1. Each case is one line. Characters that do not show (spaces
other than U+0020, format and private-use characters, combining marks) are written as \\u
escapes. The output is deterministic (fixed random seed).
"""

import json
import random
import unicodedata
from pathlib import Path

import PIL
from PIL import features

from ulani_epaper import cards, fonts, layouts
from ulani_epaper.image import accent

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]  # PaperhuePagesTests, Tests, UlaniKit, apple, repository root
GOLDEN_TEXTS = sorted((REPO / "shared" / "layouts").glob("*/golden/*.txt"))
FIXTURES = sorted((REPO / "shared" / "layouts").glob("*/*.json"))
# The pages this port draws (v0.3.0); day, month grid, cards and photo backgrounds come later.
PAGES = {"month", "agenda", "todo", "board", "message"}

# Every size layouts.py draws text at.
PAGE_SIZES = sorted(
    {v for k, v in vars(layouts).items() if k.endswith("_SIZE") or k.startswith("SIZE_")}
    | set(layouts.CARD_TEXT_SIZES) | set(layouts.MESSAGE_SIZES)
    | set(layouts.TODO_ROW_LARGE[1:3]) | set(layouts.TODO_ROW_NORMAL[1:3])
    | {20, 30}  # _notes_empty
)
EXTENT_CHARS = ["0", "國"]  # what layouts.py passes to getbbox
GLYPH_CHUNK = 64

rng = random.Random(20261012)


def length(text, size, bold):
    """getlength as an int: BASIC layout adds whole-pixel advances."""
    value = fonts.load(size, bool(bold)).getlength(text)
    assert value == int(value), (text, size, bold, value)
    return int(value)


def strings_in(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from strings_in(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from strings_in(v)


def corpus():
    """Drawn page strings, fixture strings (cleaned, as the pages measure them) and
    hand-picked mixed texts. No emoji."""
    texts = []
    for path in GOLDEN_TEXTS:
        texts += path.read_text(encoding="utf-8").splitlines()
    for path in FIXTURES:
        for s in strings_in(json.loads(path.read_text(encoding="utf-8"))):
            texts += [fonts.clean(line) for line in s.split("\n")]
    texts += [
        "讀完《原子習慣》", "繳交第三季報告，週五前", "短標題", "一二三四五六七八九十一二三四五六七八",
        "Q3 Planning 會議", "Quarterly business review with the whole team",
        "Supercalifragilisticexpialidocious", "Supercalifragilisticexpialidocious 會議",
        "https://example.com/calendar/2026/10/12?view=month", "alice@example.com",
        "產品設計審查：電子紙裝置 v2.1 (final)", "週會 / weekly sync", "Café Crème Brûlée",
        "naïve résumé façade", "Ångström Øresund Łódź", "这是简体中文的会议安排", "ひらがなカタカナ",
        "ミーティング・カレンダー", "한국어 달력 일정", "ＡＢＣ１２３（全形）", "○●✓→…·–—",
        "10:00 – 11:30·3F 大會議室", "23:00 – 隔天 01:00", "20:00 – 2027年1月1日 20:00",
        "全天·第 2 天，共 3 天", "更新於 2026/10/12", "還有 12 項", "稍早已結束 3 項",
        "1 項已逾期·1 項今天到期", "逾期 3 天", "最新 6 則，共 8 則", "在 Paperhue 輸入留言，就會顯示在這裡",
        "Hello, world! It's 9 o'clock.", "A-B-C D.E.F. #tag @user 100% & more",
        "「引號」『雙引號』〈書名〉【標記】", "句號。逗號，頓號、冒號：分號；驚嘆！問號？",
        "Mixed中English文字Text", "Model X 17 Pro 發表會", "Laptop Air 13吋 M5", "2026-10-12T09:00",
        "AVATAR To Wa Yo", "fi fl ffi", "x × y ÷ z ± 1", "¥100 €20 £5 $3", "電話 02-2345-6789",
    ]
    out, seen = [], set()
    for t in texts:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def covered():
    return sorted(c for c in fonts.codepoints() if fonts.has_glyph(chr(c)))


def random_texts(n):
    cps = covered()
    cjk = [c for c in cps if 0x4E00 <= c <= 0x9FFF]
    latin = [c for c in cps if c < 0x250 and chr(c).isalnum()]
    punct = [c for c in cps if unicodedata.category(chr(c)).startswith("P")]
    out = []
    for _ in range(n):
        chars = []
        for _ in range(rng.randint(1, 24)):
            pool = rng.choices([cjk, latin, punct, cps, [0x20]], weights=[4, 4, 2, 1, 2])[0]
            chars.append(chr(rng.choice(pool)))
        out.append(fonts.clean("".join(chars)) or "空")
    return out


def lengths(texts):
    cases = []
    for t in texts:
        for size in rng.sample(PAGE_SIZES, 3):
            bold = rng.randint(0, 1)
            cases.append([t, size, bold, length(t, size, bold)])
    # characters the font lacks are measured as its .notdef glyph (no emoji: private use, CJK Ext B)
    for t in ["", "會議", "𠀀𠀁", "A\U00020000B", "\x00\x7f", "tab\there"]:
        for size in (18, 20, 40):
            for bold in (0, 1):
                cases.append([t, size, bold, length(t, size, bold)])
    return cases


def glyph_sums():
    """For each page size and weight: lengths of the covered characters, in code point order,
    GLYPH_CHUNK at a time. Together they measure every glyph the pages can draw."""
    cps = covered()
    chunks = ["".join(chr(c) for c in cps[i:i + GLYPH_CHUNK]) for i in range(0, len(cps), GLYPH_CHUNK)]
    return [[size, bold, [length(c, size, bold) for c in chunks]] for size in PAGE_SIZES for bold in (0, 1)]


def other_sizes():
    """One character per distinct advance width (in font units: the length at 1000 px), each
    measured at every size from 8 to 140 px: [text, bold, lengths size by size]."""
    cps = covered()
    out = []
    for bold in (0, 1):
        reps = {}
        for c in cps:
            reps.setdefault(length(chr(c), 1000, bold), chr(c))
        text = "".join(reps[k] for k in sorted(reps))
        out.append([text, bold, [[length(ch, size, bold) for ch in text] for size in range(8, 141)]])
    return out


def extents():
    out = []
    for ch in EXTENT_CHARS:
        for size in PAGE_SIZES:
            for bold in (0, 1):
                out.append([ch, size, bold, list(fonts.load(size, bool(bold)).getbbox(ch, anchor="ls"))])
    # a card's text boxes are bold at any size (_card_text measures 國)
    for size in sorted(set(range(cards.MIN_SIZE, cards.MAX_SIZE + 1)) - set(PAGE_SIZES)):
        out.append(["國", size, 1, list(fonts.load(size, True).getbbox("國", anchor="ls"))])
    return out


def fit_cases(texts):
    """[text, size, bold, [[width, _fit result], ...]]."""
    cases = []
    samples = [layouts._title(t) for t in rng.sample(texts, 300)] + [
        "Quarterly planning review", "Quarterly planning 會議", "abc def ghi", "a bc", "ab",
        "Supercalifragilisticexpialidocious", "會議 Supercalifragilisticexpialidocious",
        "word1 word2 word3", "the  double  spaces", "x" * 40, "會" * 40, " leading space",
        "…", "A", "一", "Q3 Planning 會議", "Hello, world! It's 9 o'clock.",
    ]
    for t in samples:
        size = rng.choice([18, 18, 20, 20, 16, 22, 26, 28, 40])
        bold = rng.randint(0, 1)
        font = fonts.load(size, bool(bold))
        full, e = length(t, size, bold), length(layouts.ELLIPSIS, size, bold)
        widths = {0, e - 1, e, full - 1, full, full + 1, rng.uniform(0, full), rng.randint(0, full)}
        widths |= {rng.uniform(e, full) for _ in range(4)}
        results = []
        for w in sorted(round(w, 3) for w in widths if w >= 0):
            try:
                results.append([w, layouts._fit(t, font, w)])
            except IndexError:  # a cut after trailing spaces; never happens to drawn (cleaned) text
                pass
        cases.append([t, size, bold, results])
    return cases


def wrap_cases(texts):
    """[text, size, bold, width, max_lines, _wrap result]."""
    cases = [
        ["讀完《原子習慣》", 40, 1, 280, 2], ["繳交第三季報告，週五前", 40, 1, 280, 2],
        ["短標題", 40, 1, 280, 2], ["一二三四五六七八九十一二三四五六七八", 40, 1, 280, 2],
    ]
    samples = [layouts._title(t) for t in texts if len(t) > 3] + [
        "Supercalifragilisticexpialidocious and more words", "一，二。三、四：五；六！七？八）九」十』",
        "(a) b, c. d: e; f! g? h) i", "長長的標題後面跟著English words, punctuation; and more!",
        "「這是一句很長的話，」他說。", "A" * 30 + " " + "B" * 5, "會 議 中",
    ]
    for t in samples:
        size = rng.choice([18, 20, 22, 30, 36, 40, 44, 52, 64])
        bold = rng.choice([1, 1, 0])
        w = rng.randint(2, 14) * size + rng.choice([0, 0, -1, 1, size // 2, rng.uniform(0, size)])
        cases.append([t, size, bold, round(w, 3), rng.choice([1, 2, 2, 3, 4, 10 ** 6])])
    for c in cases:
        t, size, bold, w, max_lines = c
        c.append(layouts._wrap(t, fonts.load(size, bool(bold)), w, max_lines))
    return cases


def page_texts():
    """Every call of the pages' text primitive (layouts._Page.text) while the reference draws
    each page of each shared fixture, the month page in short and long months, and the extremes
    of test_layouts.py: [input, size, bold, maxw (null: none), the string drawn, the width
    returned]. Distinct calls only, in drawing order."""
    import dataclasses
    from datetime import date, datetime, timedelta

    from ulani_epaper.agenda import Event, Task

    calls, seen = [], set()
    original = layouts._Page.text

    def text(self, x, y, s, size, bold=False, fill=layouts.INK, anchor="ls", maxw=None):
        before = len(layouts._Page.record)  # drawn_texts records what the primitive draws
        width = original(self, x, y, s, size, bold, fill, anchor, maxw)
        drawn = layouts._Page.record[-1] if len(layouts._Page.record) > before else ""
        assert width == int(width), (s, size, bold, width)
        key = (s, size, bool(bold), maxw)
        if key not in seen:
            seen.add(key)
            calls.append([s, size, int(bool(bold)), maxw, drawn, int(width)])
        return width

    pages = []
    for path in FIXTURES:
        fixture = json.loads(path.read_text(encoding="utf-8"))
        if "texts" in fixture or "background" in fixture:
            continue
        renderers, args = layouts._golden_pages(fixture, str(path.parent))
        pages += [(render, args) for name, render in renderers.items() if name in PAGES]
    sample = json.loads((REPO / "shared" / "layouts" / "agenda" / "sample.json").read_text(encoding="utf-8"))
    _, (data, today, tz) = layouts._golden_pages(sample, "")
    for day in (date(2026, 2, 14), date(2026, 8, 31), date(2026, 3, 1), date(2027, 1, 1)):
        pages.append((layouts.render_month, (data, day, tz)))
    long_title = "超長標題" * 75
    at = datetime(2026, 10, 12, 8, tzinfo=tz)
    extreme = dataclasses.replace(
        data,
        events=data.events + (Event(long_title, at, at + timedelta(hours=1), color="#gggggg"),
                              Event("", at, at, calendar="", color="")),
        tasks=data.tasks + tuple(Task(f"任務 {i}") for i in range(200)) + (Task(long_title),))
    pages += [(render, (extreme, today, tz)) for name, render in layouts.RENDERERS.items() if name in PAGES]
    layouts._Page.text = text
    try:
        for render, args in pages:
            layouts.drawn_texts(render, *args)
    finally:
        layouts._Page.text = original
    return calls


CLEAN_INPUTS = [
    "", " ", "   ", "\t\n\r", "🎂 媽媽生日", "會議‍🧑‍💻 準備", "Line\nbreak\ttab", "☕️ 咖啡",
    "Café 會議", "这是简体 カレンダー 한국어 달력", "  outer  spaces  ", "a b　c d e",
    "soft­hyphen", "zero​width‌non⁠joiner﻿bom", "ctrl\x00\x01\x1f\x7f\x85chars",
    " line para", "À́", "각", "Å Ω Å", "é̂",
    "𠀀 ext B 𪜀", "private\U000f0000", "🇹🇼 flag", "👨‍👩‍👧 family", "1️⃣ keycap", "©️ ®️ ™️",
    "x᠎y", "̀leading mark", "only🎂🎉", "\x1c\x1d\x1e\x1fseparators", "tab\t\tdouble",
    "Ｆｕｌｌ　ｗｉｄｔｈ", "·‧・", "日本語の文章です。", "\U0001d400 math bold",
]

TITLE_INPUTS = ["", "   ", "🎂🎉", "🎂 生日", None, "\x00", "​", "　", "\n\t", " 標題 ", "🎂　🎉"]


def code_point_classes():
    """Runs [first, last, class] of the code points clean() does not drop: "s" becomes a space,
    "k" is kept (has_glyph). Every other code point is dropped; the surrogates (not characters
    in Swift) are dropped too, as their class."""
    runs = []
    for c in range(0x110000):
        ch = chr(c)
        if 0xD800 <= c <= 0xDFFF:
            continue
        if ch.isspace() or unicodedata.category(ch) == "Cc":
            cls = "s"
        elif fonts.has_glyph(ch):
            cls = "k"
        else:
            continue
        if runs and runs[-1][2] == cls and runs[-1][1] == c - 1:
            runs[-1][1] = c
        else:
            runs.append([c, c, cls])
    return runs


def accents():
    """Every colour on a 17-step grid plus random ones, as "rrggbb" + the panel colour's initial;
    and the missing or malformed inputs: [input, accent(input), accent(input, default="blue")]."""
    initial = {"black": "k", "red": "r", "orange": "o", "yellow": "y", "green": "g", "blue": "b"}
    colours = [(r, g, b) for r in range(0, 256, 17) for g in range(0, 256, 17) for b in range(0, 256, 17)]
    colours += [(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(6000)]
    table = "".join(f"{r:02x}{g:02x}{b:02x}" + initial[accent(f"#{r:02x}{g:02x}{b:02x}")] for r, g, b in colours)
    bad = ["", "blue", "#12345", "#gggggg", None, "#1234567", "123456", "#12345G", "#ABCDEF", "#abcdef",
           " #abcdef", "#abcdef ", "#abcdef\n", "#ａｂｃｄｅｆ", "#٠١٢٣٤٥"]
    return {"table": table, "inputs": [[c, accent(c), accent(c, default="blue")] for c in bad]}


def dumps(value):
    """Compact JSON, UTF-8 for what shows, \\u escapes for what does not."""
    out = []
    for c in json.dumps(value, ensure_ascii=False, separators=(", ", ": ")):
        if c == " " or (c.isprintable() and not unicodedata.combining(c) and unicodedata.category(c) != "Co"):
            out.append(c)
        elif ord(c) > 0xFFFF:
            v = ord(c) - 0x10000
            out.append(f"\\u{0xD800 + (v >> 10):04x}\\u{0xDC00 + (v & 0x3FF):04x}")
        else:
            out.append(f"\\u{ord(c):04x}")
    return "".join(out)


def main():
    texts = corpus() + random_texts(300)
    out = {
        "generated_by": "apple/UlaniKit/Tests/PaperhuePagesTests/Differential/make_text_expectations.py",
        "pillow": PIL.__version__,
        "freetype": features.version("freetype2"),
        "page_sizes": PAGE_SIZES,
        "glyph_chunk": GLYPH_CHUNK,
        "lengths": lengths(texts),
        "page_texts": page_texts(),
        "glyph_sums": glyph_sums(),
        "other_sizes": other_sizes(),
        "extents": extents(),
        "fit": fit_cases(texts),
        "wrap": wrap_cases(texts),
        "clean": [[t, fonts.clean(t)] for t in CLEAN_INPUTS],
        "titles": [[t, layouts._title(t)] for t in TITLE_INPUTS],
        "classes": code_point_classes(),
        "accent": accents(),
    }
    lines = ["{"]
    keys = sorted(out)
    for i, key in enumerate(keys):
        value = out[key]
        comma = "," if i < len(keys) - 1 else ""
        if isinstance(value, list) and value and isinstance(value[0], list):
            lines.append(f" {json.dumps(key)}: [")
            lines += [f"  {dumps(v)}" + ("," if j < len(value) - 1 else "") for j, v in enumerate(value)]
            lines.append(f" ]{comma}")
        else:
            lines.append(f" {json.dumps(key)}: {dumps(value)}{comma}")
    lines.append("}")
    (HERE / "text-expectations.json").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
