> Cross-platform spec for cards. The Python code in python/ (`cards.py`, `layouts.render_card`) is the reference implementation; goldens are in shared/layouts/card/.

# Cards (牌卡) spec — Paperhue v0.3.1, all apps

A card is a background plus a few short text boxes, for the desk: a status
("暫離", "開會中，15:00 回來"), a meme with a caption, a quote. It is the page
kind `card` (label 牌卡). Cards and their backgrounds live only on the device
that made them (never uploaded anywhere); apps trade them as `.paperhue-card`
files. Calendar data is not part of a card.

## Card JSON

```json
{
 "version": 1,
 "id": "a1b2c3d4",
 "background": {"color": "yellow"},
 "texts": [
  {"text": "開會中", "box": [0.05, 0.12, 0.9, 0.45], "size": 130, "color": "black",
   "outline": false, "outline_color": "white", "align": "center"}
 ]
}
```

- `id`: 8 lowercase hex characters, unique among the saved cards.
- `background` is one of
  - `{"color": C}`: a plain ink, `C` one of the 7 panel colours;
  - `{"image": "<file>", "crop": [left, top, width, height] | null}`: a photo
    and the part of it that fills the screen, exactly as in
    [CROP.md](CROP.md) (fractions of the photo after EXIF orientation, 5:3
    pixel aspect, `null` = the largest centred 5:3 rectangle). `<file>` is a
    plain file name (`[0-9A-Za-z_-]{1,40}` + `.jpg` / `.jpeg` / `.png`), never a
    path.
- `texts`: 0 to 8 boxes, drawn in list order (later ones on top). Each:
  - `text`: 1 to 80 characters after NFC normalisation and trimming; `\n` is a
    line break. Characters the font lacks (emoji) are dropped when drawing.
  - `box`: `[x, y, w, h]` as fractions of the 800 x 480 screen; `0 <= x`,
    `0 <= y`, `w > 0`, `h > 0`, `x + w <= 1`, `y + h <= 1`.
  - `size`: font size in panel pixels, an integer from 12 to 240 (bold only).
  - `color`, `outline_color`: one of `black white green blue red yellow orange`.
  - `outline`: `true` draws the text with an outline in `outline_color`
    (white text with a black outline for text on a photo); default `false`.
  - `align`: `left`, `center` or `right`; default `center`.
  - Missing optional fields mean `size` 48, `color` black, `outline` false,
    `outline_color` white, `align` center; `background.color` defaults to white.

An app refuses (does not repair) a card that breaks these rules.

## Stored files

Where the app keeps its data: `cards.json` =
`{"version": 1, "cards": [card, ...]}`, newest first, written atomically, and
`backgrounds/<id>.jpg` for each card with a photo. A background is decoded
with the usual photo rules (upright by EXIF, at most the 4K cap, 50 MP
refusal) and stored at that size, so the crop applies to the stored photo.
JPEG quality 92 is plenty; the panel has 7 colours.

## `.paperhue-card`

A zip with two entries: `card.json` (the card above) and, when the card has a
photo, `background.jpg` (`background.image` says so). Importing makes a new
card with a new id (importing twice makes two) and takes the background
through the same photo rules; it must refuse, and change nothing, when the
file is not a zip, has no valid `card.json`, names a background that is not in
the zip, or contains something bigger than 64 KiB (json) or 40 MiB (image).
Entry names are never used as paths.

## Drawing (`render_card(card) -> 800 x 480`)

Same rules as the other pages: the 7 panel colours only, no anti-aliasing
(1-bit text), deterministic, text through the page primitives.

1. Background. A colour fills the screen. A photo is resized to 800 x 480 from
   the crop box of CROP.md (from the stored, capped photo, never a preview) and
   dithered (Stucki, with the grain setting). Only text placement is compared
   across implementations; resampling and dithering may differ in detail.
2. Each text box, in order. Pixel box: `x0 = floor(x * 800 + 0.5)`,
   `x1 = floor((x + w) * 800 + 0.5)`, and likewise `y0`, `y1` with 480.
   - `r` = 0 without outline, otherwise `max(1, floor(size / 16 + 0.5))`.
     The text area is the box shrunk by `r` on every side, so the outline
     stays inside the box (a glyph may still rise a few pixels above the top).
   - Lines: the text's own line breaks, each wrapped to the area's width with
     the same wrapping as the pages (Latin words stay whole, closing
     punctuation never starts a line, a word wider than the area is split).
   - Line pitch `1.25 * size`. The first baseline is the top of the area plus
     the height above the baseline of a bold 國 at `size`; line `i` is
     `floor(i * pitch + 0.5)` lower. At most
     `max(1, floor((area height - above - below) / pitch) + 1)` lines (`below`:
     depth of that 國 below the baseline); when text is left over, the last
     line ends with `…`. A box too short for one line still gets one.
   - Alignment is within the area: `left` at its left edge, `right` at its
     right edge, `center` at `floor((left + right) / 2)`; lines are anchored
     on the baseline (`ls`, `rs`, `ms`).
   - Outline: draw the line in `outline_color` at every offset `(dx, dy)` with
     `|dx|, |dy| <= r` and `dx^2 + dy^2 <= r^2 + r`, then in `color` on top.
3. A text that is empty after dropping undrawable characters draws nothing.

Goldens: `shared/layouts/card/*.json` (cards; `background.image` is looked up
next to the fixture) for a plain-colour status, a captioned photo with
outlined text (`background.png`), and a quote with wrapping and mixed
alignment; PNG + TXT (every drawn string, one per line) in `golden/`,
regenerated with
`python -m ulani_epaper.layouts shared/layouts/card shared/layouts/card/golden`
from the repo root. Compare the strings exactly and the pixels with a
tolerance (as for the calendar pages).

## Python library

`ulani_epaper.cards`: `Card`, `Background`, `TextBox`; `load(folder=None)`,
`get(id)`, `add(card, photo=None)`, `update(card, photo=None)`, `remove(id)`,
`export_card(id, dest)`, `import_card(src)`; `folder` defaults to the config
folder. `add` gives the card a new id; a `photo` (a file) is copied in as the
background and `card.background.crop` is checked against it. `update` keeps the
card's place in the list and the background it has unless given a `photo` (or
a plain colour, which deletes the old file). `config` knows the page kind
`card`: it is never drawn by a sync (a card page changes only when a card is
pushed to it).
