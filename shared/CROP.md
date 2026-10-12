> Cross-platform spec for choosing the photo crop. Python reference and shared/vectors/crop-vectors.json follow.

# Photo crop (選擇範圍) spec — Paperhue v0.3.0, all apps

Today "填滿畫面（裁切多餘部分）/ Fill" always keeps the centre of the photo.
The owner wants to choose which part of the photo fills the 800x480 (5:3)
screen.

## Model

- Applies only in Fill (cover) mode. In Fit (contain) mode the whole photo is
  shown and the crop is ignored (but kept, so switching back restores it).
- Per page, in memory for the session (not saved to disk): the crop is a
  rectangle in the photo AFTER EXIF orientation, as fractions of the photo:
  `(left, top, width, height)`, each 0..1.
  - Its pixel aspect is always exactly 5:3 (`width*W / (height*H) == 800/480`).
  - It stays inside the photo.
  - Default (and 重設 / Reset) = the largest centred 5:3 rectangle, which is
    exactly today's Fill result.
  - Smallest allowed: see "Minimum size" below.
- Choosing another photo for the page resets its crop.
- Rendering: crop box in the pixels of the image actually being resized
  (W, H of that image; the fractions refer to the original oriented photo):
  `(floor(left*W + 0.5), floor(top*H + 0.5), floor((left+width)*W + 0.5),
  floor((top+height)*H + 0.5))` — explicit round-half-up in IEEE double,
  NOT Python's round(); then resize to 800x480 (Lanczos / high-quality) and
  dither as today. A `None` crop (the default; 重設 sets None) gives
  byte-identical output to today's Fill on the same platform. Across
  platforms only the crop-box maths and the dithering are compared.
- Minimum size: crop height in ORIGINAL oriented pixels >= min(100, default
  height), and width >= default width / 8; a photo whose default rectangle is
  already under the floor allows no zoom.

## Editor (per page)

- Opened by a 「調整範圍…」/ "Adjust crop…" button under the page (enabled when
  the page has a photo and Fill is selected), or by double-clicking the
  page's preview.
- A dialog/sheet shows the whole photo scaled to fit. The area outside the
  crop is dimmed. The crop frame is drawn with a thin outline and
  rule-of-thirds guides.
- Move: drag inside the frame (or drag the photo). Resize: drag a corner
  handle (the aspect stays 5:3), the mouse wheel / trackpad pinch, or a zoom
  slider. Arrow keys nudge by 1 % (with Shift, 10 %). Everything clamps to
  the photo.
- A small live preview of what the screen will show is optional: the
  plain-colour preview is enough. The dithered preview comes after OK.
- Buttons: 重設 / Reset (centre, no zoom), 取消 / Cancel, 確定 / OK. After OK
  the page's 7-colour preview is recomputed.
- Labels in both languages, following the app's language toggle.

## Library / CLI (Python)

- `image.fit(img, mode="cover", crop=None)`, `image.encode(..., crop=None)`,
  `push.prepare(images, fit=..., dither=..., crops=None)` where `crops` maps
  page -> `(left, top, width, height)`.
- `crop` is validated: fractions in 0..1, inside the photo, with the 5:3
  pixel aspect within a 1-pixel rounding tolerance. Otherwise ValueError with
  a clear message.
- CLI: `ulani send IMAGE --crop LEFT,TOP,WIDTH,HEIGHT` and
  `ulani push ... --crop PAGE=LEFT,TOP,WIDTH,HEIGHT` (repeatable).
- Tests: the default crop equals today's cover output byte for byte; corner
  crops; clamping; rejection of a bad aspect or out-of-range values; EXIF
  rotated photos crop in the displayed orientation.

## Vectors

`shared/vectors/crop-vectors.json`: for a few synthetic photos (sizes 1200x900,
900x1600, 4000x3000, and a size chosen so some coordinates land exactly on
.5) and crops (default, top-left, bottom-right, 4x zoom centre), W and H
given explicitly, the expected integer crop box in source pixels, plus
cases for the minimum-size and validation rules. Every app's crop-box
maths must match it exactly. Resampling is not compared, because Lanczos
implementations differ.
