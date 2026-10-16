# Dithering: Natural and Classic colours, every Paperhue app

A photo, a calendar background or a card photo becomes 800x480 palette indices in one of two ways, chosen by the
user's 「顏色」 / "Colours" setting:

- **自然 / Natural** (`natural`, the default): §2–§6. It maps colours to what the panel can really show, works in
  linear light, and lets each pixel use only black, white and the two inks either side of its hue.
- **經典 / Classic** (`classic`): Stucki on the ideal palette, exactly as in Paperhue 0.3 (§1).

The grain setting, 顆粒感 / Grain, gives a strength `s` and applies to both: 標準 1.0, 柔和 0.8, 更柔和 0.65 and
最平滑 0.5. Changing the choice to 自然 in an app sets the grain to 標準 (picking it again when it is already chosen does
nothing), and the user can change the grain afterwards. Settings saved
without a colour choice load as `natural` with grain 1.0.

Calendar pages, text and marks are not dithered: they map each pixel to the nearest ideal colour as before. The
device's colour indices are 0 black, 1 white, 2 green, 3 blue, 4 red, 5 yellow and 6 orange.

**Input to both methods:** the 800x480 RGB bytes that come out of fit and crop (`shared/CROP.md`), row-major.
**Output:** one index per pixel, row-major.

## 1. Classic

Classic is unchanged from Paperhue 0.3 and is pinned by `shared/vectors/dither-vectors.json`. In brief:
- Stucki weights are out of 42, in raster order.
- Each pixel takes the nearest ideal colour by squared RGB distance; ties go to the lowest index.
- Error is integer per channel, spread as `int(error * (weight / 42 * s))` and truncated toward zero.
- Each receiving pixel then passes the hue-keeping range rule (`_keep_in_range` in `python/src/ulani_epaper/image.py`).

## 2. Natural: number rules

These rules make Python, TypeScript and Swift produce the same bytes.

- **Doubles only.** Every non-integer value is an IEEE-754 binary64 with round-to-nearest-even: Python `float`,
  JS `number` or `Float64Array`, Swift `Double`. Never use float32.
- **Evaluation order.** Evaluate each expression exactly as written here, left to right: `a*b + c*d + e*f` means
  `((a*b) + (c*d)) + (e*f)`, and `p*q*r` means `(p*q)*r`.
  - No fused multiply-add, no fast-math, no reassociation, and no turning `x / k` into `x * (1/k)`, or back.
  - swiftc does not fuse `a*b + c` on arm64 at any optimisation level (checked with Swift 6.4); never use
    `addingProduct`.
  - In Python, the diffusion (§5) is scalar code.
- **No transcendental functions at run time.** Never call pow, cbrt, exp, log or sqrt. Every value that needs one is
  shipped data (§3).
- **No rounding to integers at run time.** The only integer conversions are a table lookup by an input byte and the
  output index itself. Nothing is rounded.
- **Comparisons.** Compare exactly as written (`<`, `<=`, `>`, `>=`). Candidates are scanned in the listed order, and
  a later one wins only if it is strictly better (`<`), so ties go to the earlier one.
- **Parse check.** Each app parses the tables from their decimal strings (shortest round-trip form; correctly
  rounded parsers give the exact doubles). Its tests check them against `shared/vectors/natural-vectors.json`
  `tables_sha256` (§6); the apps do not ship the vectors.

## 3. Natural: shipped data

All data is in `shared/dither/natural-tables.json`. Load these values; do not recompute them. The doubles are
decimal strings, and the decode table and the palette are also given as C99 hex floats.

| key | meaning |
|---|---|
| `palette_srgb` | Panel colours in sRGB bytes, relative to panel white: K (76,63,89) W (255,255,255) G (73,151,107) B (87,97,161) R (216,95,99) Y (254,237,116) O (236,126,103). They come from the 7.3-inch ACeP panel datasheet's L\*a\*b\*. They are also the preview colours (§7). |
| `decode[256]` | DEC: input byte → linear light, with a mild contrast curve folded in. It was made as x = i/255; x = (1−0.3)·x + 0.3·x·x·(3−2x); then the sRGB decode (x/12.92 if x ≤ 0.04045, else ((x+0.055)/1.055)^2.4). DEC[128] = 0.21613417486051276 |
| `pal_lin[7][3]` | PAL: `palette_srgb` decoded to linear light, without the contrast curve. PAL[1] = (1, 1, 1). |
| `luma` | L0, L1, L2 = 0.2126, 0.7152, 0.0722 |
| `k` | K0..K2 = PAL[0] |
| `wk` | WK0..WK2 = PAL[1] − PAL[0] |
| `yk`, `yrange` | YK = luminance of K, YR = luminance of WK (shipped, so no dot-product order question arises) |
| `facets[10]` | (nx, ny, nz, d) of the convex hull of the 7 PAL points: unit outward normal, and inside means n·x ≤ d. Use this order. |
| `e1`, `e2` | A basis across the grey axis a = WK/\|WK\|: E1 = normalise((1,−1,0) − a·(a₀−a₁)), E2 = a × E1 |
| `sectors[5]` | Ink pairs around the grey axis, in increasing angle: (3,4) (4,6) (6,5) (5,2) (2,3), i.e. B–R, R–O, O–Y, Y–G, G–B |
| `sector_xy[5]` | (ax, ay, bx, by): the E1/E2 coordinates of each sector's two inks |
| `sat`, `dead`, `knee`, `alpha` | SAT 1.3, DEAD 0.05, KNEE 0.8, ALPHA 1.0 |
| `ink_u[7]` | INK_U: each panel colour's place on the grey scale, (L0·PAL[c][0] + L1·PAL[c][1] + L2·PAL[c][2] − YK) / YR, so K is 0 and W is 1 |
| `cusp`, `cusp_span`, `cusp_ref` | CUSP 0.9, SPAN 2, CREF 3: how strongly a colour the panel cannot show at its own lightness is moved towards the lightness where its hue is most colourful (§4) |
| `stucki`, `stucki_div` | Stucki (w, dx, dy) in this order: (8,1,0) (4,2,0) (2,−2,1) (4,−1,1) (8,0,1) (4,1,1) (2,2,1) (1,−2,2) (2,−1,2) (4,0,2) (2,1,2) (1,2,2), and 42 |

The tables are made by `python/tools/natural_tables.py`, which needs numpy and is not part of the apps. It asserts
that every panel colour is a corner of the hull, that each sector is narrower than 180°, and that the hull is a
bipyramid around the grey axis to within 0.01 in linear light: no panel colour lies further than that outside a face
made of black or white and two neighbouring inks. The datasheet palette is not exactly one: orange lies 0.0005 inside
the black–red–yellow face, so `facets` has a red–yellow–orange face and no black–orange edge. A measured palette only
changes `palette_srgb`; then rerun it and re-pin the vectors.

## 4. Natural step A: target and candidates per colour

This step is a pure function of (r8, g8, b8). Apps may memoise it by 24-bit colour.

```
r = DEC[r8]; g = DEC[g8]; b = DEC[b8]
y = L0*r + L1*g + L2*b                                    # saturation x1.3 around the pixel's luminance
r = y + SAT*(r - y); g = y + SAT*(g - y); b = y + SAT*(b - y)
r = K0 + WK0*r; g = K1 + WK1*g; b = K2 + WK2*b            # black-point compensation
u = (L0*r + L1*g + L2*b - YK) / YR
u = 0 if u < 0 else (1 if u > 1 else u)
g0 = K0 + WK0*u; g1 = K1 + WK1*u; g2 = K2 + WK2*u         # panel grey of the same luminance
d0 = r - g0; d1 = g - g1; d2 = b - g2
s = +inf
for (nx, ny, nz, dd) in FACETS:                           # where the hull boundary lies along d
    nd = nx*d0 + ny*d1 + nz*d2
    if nd > 1e-12:
        v = (dd - (nx*g0 + ny*g1 + nz*g2)) / nd
        if v < s: s = v
ratio = 0 if s == +inf else (+inf if s <= 0 else 1 / s)   # 1 = on the hull boundary
if ratio <= DEAD or ratio == +inf:                        # near-grey: exact panel grey
    target = (g0, g1, g2); set = -1                       # candidates 0, 1
else:
    x = E1[0]*d0 + E1[1]*d1 + E1[2]*d2
    y = E2[0]*d0 + E2[1]*d1 + E2[2]*d2
    set = the first k in 0..4 with  ax*y - ay*x >= 0  and  x*by - y*bx > 0   (SXY[k]); 0 if none
    # candidates 0, 1, SECTORS[set][0], SECTORS[set][1]
    if ratio > 1 and a k was found:                       # cusp move (below)
        (ax, ay, bx, by) = SXY[set]; (i, j) = SECTORS[set]
        p = ax*y - ay*x                                   # >= 0
        q = x*by - y*bx                                   # > 0
        t = p / (p + q)                                   # where the hue meets the ink edge: 0 at ink i, 1 at ink j
        uc = INK_U[i] + t*(INK_U[j] - INK_U[i])           # the lightness where this hue is most colourful
        cx = ax + t*(bx - ax); cy = ay + t*(by - ay)      # that colour's place across the grey axis
        c = (x*cx + y*cy) / (cx*cx + cy*cy) / CREF        # how colourful the pixel is, against it
        if c > 1: c = 1
        e = (ratio - 1) / SPAN                            # how far outside the hull, 0 on the boundary
        if e > 1: e = 1
        w = CUSP*c*c*e
        ua = u + w*(uc - u)
        h0 = K0 + WK0*ua; h1 = K1 + WK1*ua; h2 = K2 + WK2*ua      # the anchor: a darker (or lighter) panel grey
        m0 = r - h0; m1 = g - h1; m2 = b - h2
        s = +inf
        for (nx, ny, nz, dd) in FACETS:
            nd = nx*m0 + ny*m1 + nz*m2
            if nd > 1e-12:
                v = (dd - (nx*h0 + ny*h1 + nz*h2)) / nd
                if v < s: s = v
        if s > 0 and s != +inf:                           # else keep g, d and ratio as they are
            g0 = h0; g1 = h1; g2 = h2; d0 = m0; d1 = m1; d2 = m2
            ratio = 1 / s
    r1 = (ratio - DEAD) / (1 - DEAD)
    if r1 > KNEE:                                         # soft knee into the hull
        x = (r1 - KNEE) / (1 - KNEE)
        r1 = KNEE + (1 - KNEE) * x / (1 + x)              # ((1 - KNEE) * x) / (1 + x)
    f = r1 / ratio
    target = (g0 + f*d0, g1 + f*d1, g2 + f*d2)
```

- `1e-12` is the double nearest to 10⁻¹².
- `ratio`, `r1`, `x`, `y`, `p`, `q`, `t`, `c`, `e`, `w`, `v` and `s` are fresh names in this step; `y` here is not the
  pixel row, and `x` is reused by the soft knee after the cusp move is done with it. `r`, `g` and `b` are the
  black-point-compensated values from above.
- `(1 - DEAD)` and `(1 - KNEE)` are computed at run time as written. They are not shipped.
- `CUSP*c*c*e` is `((CUSP*c)*c)*e`.

**The cusp move** (Paperhue 0.4.2). Keeping the lightness, as the plain mapping does, makes a bright, colourful
colour nearly grey when the panel's inks for its hue are dark: a light blue sky came out grey-white, because at that
lightness the panel can only add a few blue dots to white. So a colour outside the hull at its own lightness
(`ratio > 1`) is aimed from a grey `ua` that lies between its own lightness `u` and the lightness `uc` of its hue's
most colourful panel colour, on the edge between the two inks. The move grows from nothing at the hull boundary to
full at `SPAN` beyond it, and with the square of the pixel's colourfulness against that most colourful panel colour,
reaching full at `CREF` times it. The owner chose the strength `CUSP` on the device: between 0.75 and 1.0, nearer
1.0 (2026-10-16). Faint tints near white hardly move, a vivid sky moves most, and colours the panel can show
(`ratio <= 1`) are untouched. Because `p >= 0` and `q > 0` when a sector is found, `t` lies in [0, 1) and needs no
guard. The cusp move never changes `set`: the anchor lies on the grey axis, so the hue across it is the same.

## 5. Natural step B: serpentine error diffusion in linear light

```
TAPS = [(w / 42 * s, dx, dy) for (w, dx, dy) in STUCKI]    # (w / 42) * s, once per frame; s = grain strength
err = 3 rows x W x 3 doubles, all 0                         # err[0] = the current row
for y in 0 .. H-1:
    odd = (y % 2 == 1); sgn = -1 if odd else +1
    for n in 0 .. W-1:
        x = W-1-n if odd else n                             # even rows left to right, odd rows right to left
        v0 = t0 + err[0][x][0]; v1 = t1 + err[0][x][1]; v2 = t2 + err[0][x][2]   # t = target of pixel (x, y)
        best = first candidate; bd = +inf
        for c in candidates (in the order of §4):
            q0 = PAL[c][0] - v0; q1 = PAL[c][1] - v1; q2 = PAL[c][2] - v2
            dy = L0*q0 + L1*q1 + L2*q2
            dist = ALPHA*dy*dy + (q0 - dy)*(q0 - dy) + (q1 - dy)*(q1 - dy) + (q2 - dy)*(q2 - dy)
            if dist < bd: best = c; bd = dist
        out[y*W + x] = best
        e0 = v0 - PAL[best][0]; e1 = v1 - PAL[best][1]; e2 = v2 - PAL[best][2]
        for (f, dx, ddy) in TAPS:
            xx = x + dx*sgn
            if 0 <= xx < W and y + ddy < H:
                err[ddy][xx][0] += e0 * f; err[ddy][xx][1] += e1 * f; err[ddy][xx][2] += e2 * f
    err = [err[1], err[2], zeros]
```

- `ALPHA*dy*dy` means `(ALPHA*dy)*dy`.
- `a += b` means `a = a + b`.
- At s = 1, f is exactly w / 42.
- There is no clamp on `v` or on the error. The largest accumulated error seen is 0.78 per channel. A guard, if ever
  added, goes into every app and the vectors together.
- W and H are parameters: the vectors use small images too. Nothing else depends on 800x480.

**Strength below 1** spreads less error: there is less grain, but flat areas band into the dominant ink. At
最平滑, a smooth hue gradient becomes visible steps. The owner accepted this as the user's choice.

## 6. Vectors

`shared/vectors/natural-vectors.json` pins Natural. Every app's tests must pass all of it:

- **`tables_sha256`:** for each numeric key of the tables, the SHA-256 of its values packed as little-endian binary64
  in JSON order (nested lists flattened row by row). Integers such as `sectors` and `stucki` are excluded, because
  they are checked directly.
- **`colours`:** step-A cases. Each gives the bytes in and the expected `target` (three doubles as hex floats) and
  `set` (−1 for grey, else 0–4). They cover greys, black, white, the panel inks, ideal inks, hull-boundary colours,
  sector edges, and colours the cusp move changes a little, fully or not at all (skies, pastels, near-white tints,
  colours just outside the hull).
- **`images`:** small whole images. Each gives the RGB as hex and the indices as one hex digit per pixel, at each
  strength 1, 0.8, 0.65 and 0.5.
- **`frames`:** full 800x480 inputs as base64 raw DEFLATE (RFC 1951, no zlib header) of the RGB bytes, with the
  SHA-256 of the 384,000 output indices, one byte each, at each strength. Use Python `zlib` with `wbits=-15`, Node
  `zlib.inflateRawSync`, or Swift `NSData.decompressed(using: .zlib)`.

Error diffusion spreads one flipped decision to its neighbours, so the frames are the real gate.

## 7. Previews

Previews show what the device shows. This is display only and is not pinned by vectors.

- **Colours:** every preview of every frame draws index i with `palette_srgb[i]`, the panel colours. This covers
  photos in both modes, calendar pages and cards. Never use the ideal colours.
- **Smaller than 800x480:** average in linear light. Decode the panel colours to linear, take the box average of the
  frame pixels each preview pixel covers, then encode back to sRGB. Never average sRGB numbers and never sample
  nearest neighbour when shrinking: either makes the grain look worse than the panel.
- **800x480 or larger,** for example 1:1 or zoom: nearest neighbour, so each dot stays one ink.
- **Classic frames** use the same preview rules, so Classic's lighter look shows honestly.
