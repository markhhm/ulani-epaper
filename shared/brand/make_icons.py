"""Paperhue (紙彩) app-icon generator: a photo frame on a fan of coloured paper.

The single source of the app icon on every platform.

The design: a warm charcoal tile (the panel's black ink) carries a loosely fanned
hand of paper sheets in the other panel inks -- red, blue, yellow, green,
orange, in a deliberately non-spectral order -- and on top of them lies a slim
pewter picture frame with a white mat and a 5:3 window (the 800x480 panel ratio)
holding the faintest hint of a landscape.  "Photos on coloured paper."

Pillow only, no font files, no network, deterministic: the same Pillow version
writes byte-identical files (the committed icons were made with Pillow 12.3.0).

Usage:  python make_icons.py OUT_DIR

OUT_DIR is created, or replaced if it holds an earlier run's output.  Where the
results are used in this repository:
  paperhue-1024.png             -> shared/brand/ (README logo)
  windows/*                     -> python/src/ulani_epaper/assets/
  macos/AppIcon.appiconset/*.png -> apple/Paperhue/Paperhue/Assets.xcassets/AppIcon.appiconset/
                                   (its Contents.json there also keeps the app's empty iOS slots)
  web/, android/, small/        -> for apps not in this repository yet
  preview-sheet.png             -> every image at true size, for review

Optical sizes
  * <= 32 px tiles  : hand-tuned pixel-grid drawings (SMALL table) -- frame,
                      window and 3-5 crisp ink steps, 1 px light rim for dark UI.
  * 33 .. 80 px     : "mid" master (bolder steps, thicker moulding, lighter shadows).
  * > 80 px         : full master, drawn at 4096 and downscaled with LANCZOS.
"""
import argparse
import io
import json
import math
import shutil
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
SS = 4096  # supersample canvas for the masters


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# ---------------------------------------------------------------- palette
PALETTE = {
    "tile_top": "#4A463F",    # black ink: warm charcoal gradient (top)
    "tile_bot": "#2B2825",    #                                    (bottom)
    "red": "#BE4B3C",
    "blue": "#3A62A0",
    "yellow": "#E0BC50",
    "green": "#468A5F",
    "orange": "#DA843F",
    "mat_top": "#FBF8F1",     # white ink: the paper mat
    "mat_bot": "#F1ECE1",
    "mould_top": "#A39B8F",   # pewter frame moulding
    "mould_bot": "#878075",
    "sky_top": "#AFC2D3",     # the picture -- deliberately pale
    "sky_bot": "#DCE3E3",
    "hill_far": "#9CB4B0",
    "hill_near": "#6E957A",
    "shadow": "#1A120C",      # warm shadow tint
}
ORDER = ["red", "blue", "yellow", "green", "orange"]  # sheets, front -> back (behind the frame)

# Geometry in tile units (tile edge = 1.0).
MASTER = dict(
    fw=0.48, fh=0.36, fr=0.010,          # frame size and corner radius
    moulding=0.024,                      # frame border width
    win=(0.326, 0.196),                  # 5:3 window in the mat
    bevel=0.004,                         # white mat-bevel line around the window
    sr=0.022,                            # sheet corner radius
    pivot=(0.0, 0.36),                   # sheets fan about the frame's bottom-left corner
    steps=[(0.034, 0.030), (0.031, 0.029), (0.033, 0.031), (0.030, 0.029), (0.032, 0.030)],
    rots=[1.8, 4.0, 5.8, 8.0, 9.8],      # cumulative fan angles (deg, clockwise)
    offset=(0.0, 0.012),                 # optical centring nudge
    sh_blur=0.012, sh_alpha=0.30,        # sheet-on-sheet contact shadows
    frame_sh_blur=0.018, frame_sh_alpha=0.38,
    amb_blur=0.035, amb_alpha=0.35,      # one ambient shadow under the whole hand
    hi_alpha=0.09, hi_w=0.008, hi_end=0.45,  # inner top-edge highlight of the tile
    mould_hi=0.25,
)
# Optical size for 33..80 px: bigger reveals, thicker moulding, lighter shadows.
MID = dict(
    MASTER, fw=0.46, fh=0.345, moulding=0.036, win=(0.33, 0.198), pivot=(0.0, 0.345),
    steps=[(0.050, 0.046)] * 5, rots=[1.2, 2.8, 4.2, 5.8, 7.2],
    sh_blur=0.008, sh_alpha=0.18, frame_sh_alpha=0.30, amb_alpha=0.25,
)

# Pixel-grid drawings for tiny tiles: frame (w, h), moulding px, mat px, ink step px,
# number of ink sheets, frame origin.  Every edge sits on the pixel grid.
SMALL = {
    14: dict(frame=(9, 7), mould=1, mat=1, step=1, k=3, origin=(1, 2)),
    16: dict(frame=(9, 7), mould=1, mat=1, step=1, k=3, origin=(2, 3)),
    20: dict(frame=(12, 9), mould=1, mat=1, step=1, k=3, origin=(3, 4)),
    24: dict(frame=(14, 10), mould=1, mat=1, step=2, k=3, origin=(2, 4)),
    26: dict(frame=(14, 10), mould=1, mat=1, step=2, k=3, origin=(3, 5)),
    32: dict(frame=(16, 12), mould=1, mat=2, step=2, k=5, origin=(3, 5)),
}
SMALL_COL = dict(mould="#958D82", mat="#F7F3EA", sky="#A9BED1", hill_near="#628C70", rim=0.16)


# ---------------------------------------------------------------- geometry helpers
def tile_outline(n, R=0.30, p=2.9, seg=256, x0=0.0, y0=0.0):
    """Rounded square with continuous-curvature (superellipse) corners and straight sides."""
    r = R * n
    pts = []
    for cx, cy, a0 in ((n - r, r, -90), (n - r, n - r, 0), (r, n - r, 90), (r, r, 180)):
        for k in range(seg + 1):
            t = math.radians(a0 + 90 * k / seg)
            c, s = math.cos(t), math.sin(t)
            pts.append((x0 + cx + r * math.copysign(abs(c) ** (2 / p), c),
                        y0 + cy + r * math.copysign(abs(s) ** (2 / p), s)))
    return pts


def rrect(x0, y0, x1, y1, r, seg=48):
    if r <= 0:
        return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0),
                       (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for k in range(seg + 1):
            t = math.radians(a0 + 90 * k / seg)
            pts.append((cx + r * math.cos(t), cy + r * math.sin(t)))
    return pts


def rotate(pts, deg, px, py):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [(px + (x - px) * c - (y - py) * s, py + (x - px) * s + (y - py) * c) for x, y in pts]


def poly_mask(size, pts):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def vgrad(size, top, bot, y0=0.0, y1=None):
    w, h = size
    y1 = h if y1 is None else y1
    col = Image.new("RGB", (1, h))
    px = col.load()
    for y in range(h):
        t = min(1.0, max(0.0, (y - y0) / max(1.0, y1 - y0)))
        px[0, y] = tuple(int(round(top[i] + (bot[i] - top[i]) * t)) for i in range(3))
    return col.resize((w, h), Image.NEAREST)


def soft(m, radius, scale=4):
    """Gaussian blur at 1/scale resolution (shadows are smooth; keeps 4096 renders fast)."""
    w, h = m.size
    small = m.resize((max(1, w // scale), max(1, h // scale)), Image.BOX)
    small = small.filter(ImageFilter.GaussianBlur(max(0.01, radius / scale)))
    return small.resize((w, h), Image.BILINEAR)


def kmask(m, k):
    return m.point(lambda v: int(v * k + 0.5))


def fill(img, src, m):
    """Alpha-composite a colour (tuple) or an RGB image through mask m (no dark fringes)."""
    if isinstance(src, tuple):
        layer = Image.new("RGBA", img.size, src[:3] + (255,))
    else:
        layer = src.convert("RGBA")
    layer.putalpha(m)
    img.alpha_composite(layer)


def shrink(img, size, method=Image.LANCZOS):
    """Resize RGBA with premultiplied alpha so edges never pick up dark halos."""
    if img.size == (size, size):
        return img.copy()
    return img.convert("RGBa").resize((size, size), method).convert("RGBA")


# ---------------------------------------------------------------- the artwork
def group_polys(P):
    """Frame + sheets as polygons in tile units, centred in the tile (frame first)."""
    fw, fh = P["fw"], P["fh"]
    polys = [rrect(0, 0, fw, fh, P["fr"])]
    x = y = 0.0
    for (dx, dy), a in zip(P["steps"], P["rots"]):
        x += dx
        y += dy
        polys.append(rotate(rrect(x, y, x + fw, y + fh, P["sr"]), a, *P["pivot"]))
    xs = [px for p in polys for px, _ in p]
    ys = [py for p in polys for _, py in p]
    ox = 0.5 - (min(xs) + max(xs)) / 2 + P["offset"][0]
    oy = 0.5 - (min(ys) + max(ys)) / 2 + P["offset"][1]
    return [[(px + ox, py + oy) for px, py in p] for p in polys], (ox, oy)


def art_radius(P):
    """Largest distance of the artwork from the tile centre (tile units)."""
    polys, _ = group_polys(P)
    return max(math.hypot(x - 0.5, y - 0.5) for p in polys for x, y in p)


def render(n, P, shape="tile", scale=1.0, circle=1.0, background=True):
    """shape: 'tile' (rounded square, transparent corners), 'square' (full bleed),
    'circle' (disc of diameter circle*n) or 'none' (artwork only, transparent)."""
    size = (n, n)
    C = {k: hexrgb(v) for k, v in PALETTE.items()}
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    S = lambda pts: [(n * (0.5 + (x - 0.5) * scale), n * (0.5 + (y - 0.5) * scale)) for x, y in pts]

    if shape == "tile":
        clip = poly_mask(size, tile_outline(n))
    elif shape == "square":
        clip = Image.new("L", size, 255)
    elif shape == "circle":
        clip = Image.new("L", size, 0)
        r = circle * n / 2
        ImageDraw.Draw(clip).ellipse([n / 2 - r, n / 2 - r, n / 2 + r, n / 2 + r], fill=255)
    else:
        clip = None
    if clip is not None and background:
        fill(img, vgrad(size, C["tile_top"], C["tile_bot"]), clip)
        if shape == "tile" and P["hi_alpha"]:
            w = P["hi_w"] * n
            inner = poly_mask(size, [(w + x * (n - 2 * w) / n, w + y * (n - 2 * w) / n)
                                     for x, y in tile_outline(n)])
            ring = ImageChops.multiply(ImageChops.subtract(clip, inner).filter(ImageFilter.GaussianBlur(w * 0.35)), clip)
            fade = vgrad(size, (255,) * 3, (0,) * 3, 0, P["hi_end"] * n).convert("L")
            fill(img, (255, 255, 255), kmask(ImageChops.multiply(ring, fade), P["hi_alpha"]))

    polys, (ox, oy) = group_polys(P)
    polys = [S(p) for p in polys]
    sc = scale * n

    def shadow(m, blur, alpha, dx, dy):
        sh = kmask(soft(ImageChops.offset(m, int(round(dx)), int(round(dy))), blur), alpha)
        if clip is not None:
            sh = ImageChops.multiply(sh, clip)
        fill(img, C["shadow"], sh)

    union = Image.new("L", size, 0)
    for p in polys:
        union = ImageChops.lighter(union, poly_mask(size, p))
    shadow(union, P["amb_blur"] * sc, P["amb_alpha"], 0, 0.018 * sc)

    for i in reversed(range(len(polys))):
        m = poly_mask(size, polys[i])
        if i < len(polys) - 1:
            b, a = (P["frame_sh_blur"], P["frame_sh_alpha"]) if i == 0 else (P["sh_blur"], P["sh_alpha"])
            shadow(m, b * sc, a, 0.25 * b * sc, 0.6 * b * sc)
        if i == 0:
            T = lambda pts: S([(x + ox, y + oy) for x, y in pts])
            draw_frame(img, P, C, T, polys[0], m, sc)
        else:
            fill(img, C[ORDER[i - 1]], m)
    return img


def draw_frame(img, P, C, T, outer, om, sc):
    size = img.size
    fw, fh, mw = P["fw"], P["fh"], P["moulding"]
    ys = [y for _, y in outer]
    fill(img, vgrad(size, C["mould_top"], C["mould_bot"], min(ys), max(ys)), om)
    if P["mould_hi"]:  # light catching the top edge of the moulding
        lip = ImageChops.subtract(om, ImageChops.offset(om, 0, max(1, int(0.004 * sc))))
        fill(img, (255, 255, 255), kmask(lip, P["mould_hi"]))
    # mat
    mat = T(rrect(mw, mw, fw - mw, fh - mw, 0))
    mm = poly_mask(size, mat)
    my = [y for _, y in mat]
    fill(img, vgrad(size, C["mat_top"], C["mat_bot"], min(my), max(my)), mm)
    d = 0.006 * sc  # the moulding's lip shades the mat along the top/left
    ish = soft(ImageChops.offset(ImageChops.invert(mm), int(d * 0.4), int(d)), d * 0.9)
    fill(img, (40, 28, 18), kmask(ImageChops.multiply(ish, mm), 0.22))
    # window + picture
    ww, wh = P["win"]
    wx0, wy0 = (fw - ww) / 2, (fh - wh) / 2
    b = P["bevel"]
    grown = poly_mask(size, T(rrect(wx0 - b, wy0 - b, wx0 + ww + b, wy0 + wh + b, 0)))
    fill(img, (255, 255, 255), grown)  # bevel-cut core of the mat
    win = T(rrect(wx0, wy0, wx0 + ww, wy0 + wh, 0))
    wm = poly_mask(size, win)
    X0, Y0 = win[0]
    X1, Y1 = win[2]
    W, H = X1 - X0, Y1 - Y0
    fill(img, vgrad(size, C["sky_top"], C["sky_bot"], Y0, Y1), wm)

    def hill(f):
        pts = [(X0 - 2, Y1 + 2)] + [(X0 + t / 100 * W, Y0 + H * f(t / 100)) for t in range(101)] + [(X1 + 2, Y1 + 2)]
        return ImageChops.multiply(poly_mask(size, pts), wm)
    fill(img, C["hill_far"], hill(lambda t: 0.50 - 0.20 * math.sin(math.pi * (0.85 * t + 0.08))))
    fill(img, C["hill_near"], hill(lambda t: 0.57 + 0.27 * t - 0.06 * math.sin(math.pi * t)))
    d = 0.005 * sc  # the picture sits behind the mat: soft inner shadow top/left
    ish = soft(ImageChops.offset(ImageChops.invert(wm), int(d * 0.4), int(d)), d)
    fill(img, (30, 22, 14), kmask(ImageChops.multiply(ish, wm), 0.35))


def render_small(n, rim=True):
    """Pixel-grid drawing for an n-px tile (n in SMALL)."""
    L = SMALL[n]
    K = 32
    N = n * K
    C = {k: hexrgb(v) for k, v in PALETTE.items()}
    Q = {k: (hexrgb(v) if isinstance(v, str) else v) for k, v in SMALL_COL.items()}
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tm = poly_mask((N, N), tile_outline(N))
    fill(img, vgrad((N, N), C["tile_top"], C["tile_bot"]), tm)
    if rim:  # 1 px light rim: keeps the tile's edge on dark title bars / taskbars
        inner = poly_mask((N, N), [(K + x * (N - 2 * K) / N, K + y * (N - 2 * K) / N) for x, y in tile_outline(N)])
        fill(img, (255, 255, 255), kmask(ImageChops.subtract(tm, inner), Q["rim"]))
    d = ImageDraw.Draw(img)
    box = lambda x0, y0, x1, y1: [x0 * K, y0 * K, x1 * K - 1, y1 * K - 1]
    fx, fy = L["origin"]
    fw, fh = L["frame"]
    st = L["step"]
    for i in reversed(range(1, L["k"] + 1)):
        x0, y0 = fx + i * st, fy + i * st
        d.rounded_rectangle(box(x0, y0, x0 + fw, y0 + fh), radius=0.35 * K, fill=C[ORDER[i - 1]])
    d.rectangle(box(fx, fy, fx + fw, fy + fh), fill=Q["mould"])
    m = L["mould"]
    d.rectangle(box(fx + m, fy + m, fx + fw - m, fy + fh - m), fill=Q["mat"])
    b = m + L["mat"]
    wx0, wy0, wx1, wy1 = fx + b, fy + b, fx + fw - b, fy + fh - b
    d.rectangle(box(wx0, wy0, wx1, wy1), fill=Q["sky"])
    ww, wh = wx1 - wx0, wy1 - wy0
    for c in range(ww):  # the near hill only, stepped on whole pixels (the far hill is noise here)
        t = (c + 0.5) / ww
        near = max(1, round(wh * (0.43 - 0.27 * t + 0.06 * math.sin(math.pi * t))))
        d.rectangle(box(wx0 + c, wy1 - near, wx0 + c + 1, wy1), fill=Q["hill_near"])
    return img.convert("RGBa").resize((n, n), Image.BOX).convert("RGBA")


# ---------------------------------------------------------------- size dispatch
# Artwork scale (relative to the master tile) for the tile-less / full-bleed layouts.
#   maskable: inside the central 80 % circle (radius 0.40, kept to 0.385 for the shadow)
#   fg:       Android adaptive foreground, inside the 66 dp safe circle of the 108 dp layer
#   round:    legacy round launcher icon, disc of 44/48 with the artwork inside it
LAYOUT_SCALE = {"tile": lambda P: 1.0, "square": lambda P: 1.0, "mac": lambda P: 824 / 1024,
                "maskable": lambda P: 0.385 / art_radius(P),
                "fg": lambda P: (33 / 108) / art_radius(P),
                "mono": lambda P: (33 / 108) / art_radius(P),
                "round": lambda P: 0.375 / art_radius(P)}


class Icons:
    def __init__(self):
        self._cache = {}

    def hi(self, key):
        """1024-px renders of the masters, each drawn at 4096."""
        if key not in self._cache:
            kind, P = key.split(":")
            P = MASTER if P == "master" else MID
            sc = LAYOUT_SCALE[kind](P)
            if kind == "tile":
                im = render(SS, P, "tile")
            elif kind in ("square", "maskable"):
                im = render(SS, P, "square", scale=sc)
            elif kind == "fg":
                im = render(SS, P, "none", scale=sc)
            elif kind == "round":
                im = render(SS, P, "circle", scale=sc, circle=44 / 48)
            elif kind == "mac":
                im = mac_canvas(P)
            elif kind == "mono":
                im = monochrome(SS, P)
            self._cache[key] = shrink(im, 1024)
        return self._cache[key]

    def tile(self, s):
        """The rounded-tile icon at s px, using the right optical size."""
        if s in SMALL:
            return render_small(s)
        return shrink(self.hi("tile:" + ("mid" if s <= 80 else "master")), s)

    def variant(self, kind, s):
        """Any layout at s px; the optical size follows the artwork's effective tile size."""
        eff = s * LAYOUT_SCALE.get(kind, LAYOUT_SCALE["fg"])(MASTER)
        return shrink(self.hi(f"{kind}:" + ("mid" if eff <= 80 else "master")), s)


def mac_canvas(P):
    """Apple macOS icon template: 824/1024 rounded tile, centred, soft drop shadow."""
    n = SS
    t = round(n * 824 / 1024)
    o = (n - t) // 2
    tile = render(t, P, "tile")
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    a = Image.new("L", (n, n), 0)
    a.paste(tile.getchannel("A"), (o, o))
    sh = kmask(soft(ImageChops.offset(a, 0, round(12 * n / 1024)), 14 * n / 1024), 0.30)
    fill(canvas, (0, 0, 0), sh)
    canvas.alpha_composite(tile, (o, o))
    return canvas


def mac_small(s, t):
    """macOS 16/32 px: hand-tuned t-px tile centred on an s-px canvas, with a 1 px soft shadow."""
    tile = render_small(t)
    o = (s - t) // 2
    K = 8
    a = Image.new("L", (s * K, s * K), 0)
    a.paste(tile.getchannel("A").resize((t * K, t * K), Image.NEAREST), (o * K, o * K))
    sh = soft(ImageChops.offset(a, 0, K * s // 32 + K // 2), K * 0.6, scale=1).resize((s, s), Image.BOX)
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    fill(canvas, (0, 0, 0), kmask(sh, 0.28))
    canvas.alpha_composite(tile, (o, o))
    return canvas


def monochrome(N, P=MASTER):
    """Android 13+ themed-icon layer: white silhouette, sheets separated by gaps,
    the frame's window open with a hill floating inside it."""
    scale = (33 / 108) / art_radius(P)
    polys, (ox, oy) = group_polys(P)
    S = lambda pts: [(N * (0.5 + (x - 0.5) * scale), N * (0.5 + (y - 0.5) * scale)) for x, y in pts]
    out = Image.new("L", (N, N), 0)
    gap = max(2, int(0.012 * N * scale))
    for i in reversed(range(len(polys))):
        pts = S(polys[i])
        m = poly_mask((N, N), pts)
        grown = m.copy()
        ImageDraw.Draw(grown).line(pts + [pts[0]], fill=255, width=2 * gap, joint="curve")
        out = ImageChops.subtract(out, grown)
        out = ImageChops.lighter(out, m)
    T = lambda pts: S([(x + ox, y + oy) for x, y in pts])
    ww, wh = P["win"]
    wx0, wy0 = (P["fw"] - ww) / 2, (P["fh"] - wh) / 2
    win = T(rrect(wx0, wy0, wx0 + ww, wy0 + wh, 0))
    out = ImageChops.subtract(out, poly_mask((N, N), win))
    X0, Y0 = win[0]
    X1, Y1 = win[2]
    X0, X1, Y1 = X0 + gap, X1 - gap, Y1 - gap
    W, H = X1 - X0, Y1 - Y0
    hill = [(X0, Y1)] + [(X0 + t / 100 * W, Y0 + H * (0.50 - 0.20 * math.sin(math.pi * (0.85 * t / 100 + 0.08))))
                         for t in range(101)] + [(X1, Y1)]
    out = ImageChops.lighter(out, poly_mask((N, N), hill))
    img = Image.new("RGBA", (N, N), (255, 255, 255, 0))
    img.putalpha(out)
    return img


# ---------------------------------------------------------------- export
def save(img, path, opaque=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        bg = Image.new("RGBA", img.size, hexrgb(PALETTE["tile_bot"]) + (255,))
        bg.alpha_composite(img)
        img = bg.convert("RGB")
    img.save(path, optimize=True)
    return path


def ico_bitmap(img):
    """One .ico image in the classic layout: 32-bit BGRA plus the 1-bit AND mask, rows bottom-up."""
    w, h = img.size
    xor = img.tobytes("raw", "BGRA", 0, -1)
    transparent = img.getchannel("A").point(lambda a: 255 if a == 0 else 0).convert("1")
    mask = transparent.tobytes("raw", "1", (w + 31) // 32 * 4, -1)
    header = struct.pack("<IiiHHIIiiII", 40, w, 2 * h, 1, 32, 0, len(xor) + len(mask), 0, 0, 0, 0)
    return header + xor + mask


def save_ico(path, frames):
    """A .ico with bitmaps below 256 px and a PNG at 256 px, the layout of Windows' own icons.

    Not Pillow's default (PNG at every size): Tk's .ico reader (tkinter's
    iconbitmap) cannot read PNG images and falls back to a blurry upscale.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    images = []
    for s in sorted(frames):
        if s < 256:
            images.append((s, ico_bitmap(frames[s])))
        else:
            buf = io.BytesIO()
            frames[s].save(buf, format="PNG")
            images.append((0, buf.getvalue()))  # 0 means 256 in the directory
    head = struct.pack("<HHH", 0, 1, len(images))
    offset = len(head) + 16 * len(images)
    directory = b""
    for side, data in images:
        directory += struct.pack("<BBBBHHII", side, side, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    path.write_bytes(head + directory + b"".join(data for _, data in images))
    return path


def prepare(out):
    """Create out, or empty it if it holds an earlier run's output -- never anything else."""
    out = out.resolve()
    if out == HERE or out in HERE.parents:
        sys.exit(f"refusing to replace {out}: it contains this generator; pick a new folder")
    if out.exists():
        if not out.is_dir():
            sys.exit(f"{out} is a file, not a folder")
        earlier_run = all((out / name).is_file() for name in ("paperhue-1024.png", "preview-sheet.png"))
        if any(out.iterdir()) and not earlier_run:
            sys.exit(f"refusing to replace {out}: it is not an earlier icon set; pick a new or empty folder")
        shutil.rmtree(out)
    out.mkdir(parents=True)
    return out


def build(out):
    out = prepare(out)
    ic = Icons()
    written = []

    # master
    written.append(save(ic.hi("tile:master"), out / "paperhue-1024.png"))
    written.append(save(ic.tile(512), out / "paperhue-icon-512.png"))

    # small / optical-size variants
    for s in (16, 20, 24, 32, 40, 48, 64):
        written.append(save(ic.tile(s), out / "small" / f"paperhue-{s}.png"))

    # Windows
    win_sizes = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
    written.append(save_ico(out / "windows" / "paperhue.ico", {s: ic.tile(s) for s in win_sizes}))
    written.append(save(ic.tile(256), out / "windows" / "paperhue-256.png"))
    written.append(save(ic.tile(32), out / "windows" / "paperhue-32.png"))

    # Web / PWA
    web = out / "web"
    written.append(save_ico(web / "favicon.ico", {s: ic.tile(s) for s in (16, 32, 48)}))
    written.append(save(ic.tile(32), web / "favicon-32.png"))
    written.append(save(ic.tile(16), web / "favicon-16.png"))
    written.append(save(ic.tile(192), web / "icon-192.png"))
    written.append(save(ic.tile(512), web / "icon-512.png"))
    written.append(save(ic.variant("maskable", 512), web / "icon-maskable-512.png", opaque=True))
    written.append(save(ic.variant("square", 180), web / "apple-touch-icon.png", opaque=True))

    # macOS
    mac = out / "macos" / "AppIcon.appiconset"
    entries = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            if px == 16:
                im = mac_small(16, 14)
            elif px == 32:
                im = mac_small(32, 26)
            else:
                im = ic.variant("mac", px)
            written.append(save(im, mac / name))
            entries.append({"size": f"{pt}x{pt}", "idiom": "mac", "filename": name, "scale": f"{scale}x"})
    (mac / "Contents.json").write_text(json.dumps({"images": entries, "info": {"version": 1, "author": "xcode"}},
                                                  indent=2) + "\n", encoding="utf-8")
    written.append(mac / "Contents.json")

    # Android
    and_dir = out / "android"
    dens = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}
    bg_plain = vgrad((1024, 1024), hexrgb(PALETTE["tile_top"]), hexrgb(PALETTE["tile_bot"])).convert("RGBA")
    for name, k in dens.items():
        d = and_dir / f"mipmap-{name}"
        fg = round(108 * k)
        lg = round(48 * k)
        written.append(save(ic.variant("fg", fg), d / "ic_launcher_foreground.png"))
        written.append(save(shrink(bg_plain, fg), d / "ic_launcher_background.png", opaque=True))
        written.append(save(ic.variant("mono", fg), d / "ic_launcher_monochrome.png"))
        legacy = Image.new("RGBA", (lg, lg), (0, 0, 0, 0))
        t = round(lg * 44 / 48)
        legacy.alpha_composite(ic.tile(t), ((lg - t) // 2, (lg - t) // 2))
        written.append(save(legacy, d / "ic_launcher.png"))
        written.append(save(ic.variant("round", lg), d / "ic_launcher_round.png"))
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
           '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
           '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
           '</adaptive-icon>\n')
    any_dir = and_dir / "mipmap-anydpi-v26"
    any_dir.mkdir(parents=True, exist_ok=True)
    for nm in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (any_dir / nm).write_text(xml, encoding="utf-8")
        written.append(any_dir / nm)
    vals = and_dir / "values"
    vals.mkdir(parents=True, exist_ok=True)
    (vals / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{PALETTE["tile_bot"]}</color>\n</resources>\n', encoding="utf-8")
    written.append(vals / "ic_launcher_background.xml")
    written.append(save(ic.variant("square", 512), and_dir / "play-store-512.png", opaque=True))

    preview_sheet(out, out / "preview-sheet.png")
    return written


# ---------------------------------------------------------------- preview
def preview_sheet(root, path):
    """Every exported image at true size (ICO frames individually) on a light and a dark strip."""
    try:
        font = ImageFont.load_default(size=13)
    except (TypeError, OSError, ImportError):
        font = ImageFont.load_default()
    items = []
    for p in sorted(root.rglob("*")):
        if p.suffix == ".png" and p != path:
            items.append((p.relative_to(root).as_posix(), Image.open(p).convert("RGBA")))
        elif p.suffix == ".ico":
            ico = Image.open(p)
            for sz in sorted(ico.info.get("sizes", ico.ico.sizes())):
                fr = ico.ico.getimage(sz).convert("RGBA")
                items.append((f"{p.relative_to(root).as_posix()} [{sz[0]}]", fr))
    items.sort(key=lambda it: (-it[1].height, it[0]))
    W, pad, lab = 2400, 18, 16
    rows, row, x, rh = [], [], pad, 0
    for name, im in items:
        w = max(im.width, 150)
        if x + w + pad > W and row:
            rows.append((row, rh))
            row, x, rh = [], pad, 0
        row.append((name, im, x))
        x += w + pad
        rh = max(rh, im.height)
    if row:
        rows.append((row, rh))
    strip_h = sum(rh + lab * 4 + pad for _, rh in rows) + pad
    sheet = Image.new("RGB", (W, 2 * strip_h), (255, 255, 255))
    for k, (bg, fg) in enumerate((((255, 255, 255), (60, 60, 60)), ((28, 28, 30), (200, 200, 200)))):
        y0 = k * strip_h
        sheet.paste(Image.new("RGB", (W, strip_h), bg), (0, y0))
        d = ImageDraw.Draw(sheet)
        y = y0 + pad
        for row, rh in rows:
            for name, im, x in row:
                if "monochrome" in name:  # white-only layer: show it tinted so it is visible on both strips
                    tint = Image.new("RGBA", im.size, fg + (255,))
                    tint.putalpha(im.getchannel("A"))
                    im = tint
                sheet.paste(im, (x, y + rh - im.height), im)
                parts = name.rsplit("/", 1)
                d.text((x, y + rh + 4), parts[-1][:22], fill=fg, font=font)
                if len(parts) > 1:
                    d.text((x, y + rh + 4 + lab), parts[0].replace("AppIcon.appiconset", "AppIcon")[:22],
                           fill=fg, font=font)
                d.text((x, y + rh + 4 + 2 * lab), f"{im.width}x{im.height}", fill=fg, font=font)
            y += rh + lab * 4 + pad
    sheet.save(path, optimize=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Render the Paperhue app icon for every platform.")
    parser.add_argument("out_dir", type=Path,
                        help="folder to write the icon set to (created, or replaced if it holds an earlier set)")
    target = parser.parse_args(argv).out_dir.resolve()
    for p in build(target):
        print(p.relative_to(target).as_posix())


if __name__ == "__main__":
    main()
