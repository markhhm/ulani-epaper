> Cross-platform spec for choosing the photo crop and for the size every photo is opened at. Python reference,
> shared/vectors/crop-vectors.json and shared/vectors/photo-cap-vectors.json follow.

# Photo crop (選擇範圍) spec — Paperhue v0.3.0, all apps

Today "填滿畫面（裁切多餘部分）/ Fill" always keeps the centre of the photo.
The owner wants to choose which part of the photo fills the 800x480 (5:3)
screen.

## Model

- Applies only in Fill (cover) mode. In Fit (contain) mode the whole photo is
  shown and the crop is ignored (but kept, so switching back restores it).
- Per page, in memory for the session (not saved to disk): the crop is a
  rectangle in the photo AFTER EXIF orientation, as fractions of the photo:
  `(left, top, width, height)`, each 0..1. The fractions do not depend on the
  4K cap below, but every pixel rule is measured on the capped photo.
  - Its pixel aspect is always exactly 5:3 (`width*W / (height*H) == 800/480`).
  - It stays inside the photo.
  - Default (and 重設 / Reset) = the largest centred 5:3 rectangle, which is
    exactly today's Fill result.
  - Smallest allowed: see "Minimum size" below.
- Choosing another photo for the page resets its crop.
- Rendering: crop box in the pixels of the image actually being resized (W, H
  of that image: the photo after the 4K cap, see "Photo size"):
  `(floor(left*W + 0.5), floor(top*H + 0.5), floor((left+width)*W + 0.5),
  floor((top+height)*H + 0.5))` — explicit round-half-up in IEEE double,
  NOT Python's round(); then resize to 800x480 (Lanczos / high-quality) and
  dither as today. A `None` crop (the default; 重設 sets None) gives
  byte-identical output to today's Fill on the same platform. Across
  platforms only the crop-box maths and the dithering are compared.
- Minimum size: crop height in pixels of the CAPPED photo (see "Photo size";
  not the file's original pixels) >= min(100, default height), and width >=
  default width / 8; a photo whose default rectangle is already under the
  floor allows no zoom. "Default height" is also measured in the capped photo.

## Photo size: refuse over 50 MP, cap the rest at 4K

Every photo an app opens (previews, the crop editor, sending) goes through one
load step, so the crop box and the 100 px floor are measured on the same photo
everywhere. The step has three parts, in this order.

1. **Refuse photos over 50 megapixels.** Width x height are read from the file
   header before any pixel is decoded (the EXIF orientation does not change the
   product). More than 50,000,000 pixels (`PHOTO_PIXEL_LIMIT`): the photo is
   refused, not shrunk, and the user is asked to shrink it and choose it
   again. Exactly 50,000,000 is accepted. The message names the limit, not
   the photo's size.
   - Windows tile (zh-TW): 照片超過 5000 萬像素的上限，請先縮小再選。
   - English: "This photo is over the 50-megapixel limit. Shrink it, then
     choose it again."
   - Command line: `error: the photo is over the 50 megapixel limit; shrink
     it first`, exit status 1.
2. **Orient** the photo by its EXIF orientation.
3. **Cap at 4K.** `MAX_PHOTO_SIZE` = 3840 x 2160, in the photo's own
   orientation: a landscape photo (width >= height, so a square counts as
   landscape) must fit 3840 x 2160, a portrait photo 2160 x 3840. A photo that
   already fits is left exactly as it is (never enlarged, not resampled).
   Otherwise it is shrunk keeping its shape, in integers (width W, height H,
   box (BW, BH)):
   - if `BW * H <= BH * W` the width binds: size = (BW, max(1, (2 * H * BW +
     W) div (2 * W)));
   - otherwise the height binds: size = (max(1, (2 * W * BH + H) div (2 * H)),
     BH).

   The binding side is exactly the box edge. The other side is floor(x + 0.5)
   (halves up, not to even) and never less than 1, so a 38400 x 4 strip becomes
   3840 x 1, not 3840 x 0. Resampling is Lanczos / high quality (not compared
   across platforms), but the size must match to the pixel. An app may decode a
   JPEG at a reduced scale to be quick if the final size is still the one
   computed from the full size.

Reference sizes (all in `shared/vectors/photo-cap-vectors.json`): 6000 x 4000
-> 3240 x 2160; 4000 x 6000 -> 2160 x 3240; 12000 x 1000 -> 3840 x 320;
7000 x 7000 -> 2160 x 2160; 5001 x 4320 -> 2501 x 2160 (2500.5 rounds up);
38400 x 4 -> 3840 x 1.

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

- `image.open_image(path)` is the load step above (raises `PhotoTooLarge`, an
  `UlaniError`, for a photo over 50 MP); `image.limit_photo(img)` orients and
  caps an image already in memory.
- `image.fit(img, mode="cover", crop=None)`, `image.encode(..., crop=None)`,
  `push.prepare(images, fit=..., dither=..., crops=None, colours="natural")` where
  `crops` maps page -> `(left, top, width, height)`.
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
implementations differ. In these vectors "photo" is just the W x H the maths
runs on (in an app, the photo after the 4K cap): 4000 x 3000 is above the cap
and is used here as a plain number.

`shared/vectors/photo-cap-vectors.json`: the 4K cap sizes (including the .5
rounding and the minimum of 1 pixel), and which header sizes are
refused. Written by hand, not generated.
Every app's cap and refusal rules must match it exactly.
