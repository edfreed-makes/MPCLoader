#!/usr/bin/env python3
"""Build every macOS icon asset for MPCLoader from one piece of device artwork.

Usage:
    python3 icon/build_icon.py                     # rebuild from icon/source/
    python3 icon/build_icon.py --source other.png  # rebuild from new artwork

With no --source it uses icon/source/mpc-live-2-panel.png if that exists
(the lossless original), otherwise the .jpg copy next to it.

Needs: Pillow, numpy, icnsutil  (pip install pillow numpy icnsutil)

What it writes (all inside icon/):
    AppIcon.icns          every size in one file, for any macOS app bundle
    AppIcon.iconset/      the ten PNGs that make up the .icns
    AppIcon.appiconset/   the same ten PNGs plus Contents.json, for Xcode
    AppIcon.icon/         layered Icon Composer file (default, dark, mono)
    masters/              flat 1024 px squares of each appearance
    preview.png           contact sheet for a quick visual check
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
_PNG = HERE / "source" / "mpc-live-2-panel.png"
DEFAULT_SOURCE = _PNG if _PNG.exists() else _PNG.with_suffix(".jpg")

# --------------------------------------------------------------------------
# The source artwork is the device's top panel, filling a 1728 x 1024 frame
# edge to edge (the proportions of a real MPC Live II). The script mirrors a
# sliver of panel outwards for breathing room, rounds the corners and adds
# the thin edge lines that make it read as a solid object.
# --------------------------------------------------------------------------
SOURCE_SIZE = (1728, 1024)
PANEL_EXTEND = {"left": 20, "top": 20, "right": 20, "bottom": 0}  # source px
DEVICE_RADIUS = 56.0                                              # source px

# --------------------------------------------------------------------------
# macOS icon grid (the template Apple has used since macOS 11): a 1024 px
# canvas holding an 824 px rounded square, with room around it for a shadow.
# --------------------------------------------------------------------------
CANVAS = 1024
BODY = 824
BODY_RADIUS = 185.4
SHADOW_OFFSET_Y = 12.0   # px at 1024
SHADOW_SIGMA = 14.0      # px at 1024 (a 28 px blur)
SHADOW_OPACITY = 0.42

# Pixel size -> size of the rounded square inside it. Whole-pixel margins keep
# the edges crisp. The 16 px icon runs slightly larger so it stays readable.
BODY_PX = {16: 14, 32: 26, 64: 52, 128: 104, 256: 206, 512: 412, 1024: 824}

# The ten files macOS expects: (file name, pixel size)
ICONSET = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
# The same ten files as .icns entry types (what Apple's iconutil writes).
ICNS_KEYS = {
    "icon_16x16.png": "ic04", "icon_16x16@2x.png": "ic11",
    "icon_32x32.png": "ic05", "icon_32x32@2x.png": "ic12",
    "icon_128x128.png": "ic07", "icon_128x128@2x.png": "ic13",
    "icon_256x256.png": "ic08", "icon_256x256@2x.png": "ic14",
    "icon_512x512.png": "ic09", "icon_512x512@2x.png": "ic10",
}

# --------------------------------------------------------------------------
# The three appearances. Backgrounds are plain top-to-bottom gradients so the
# layered Icon Composer file can reproduce them exactly.
# --------------------------------------------------------------------------
VARIANTS = {
    "default": {"top": (0xFA, 0xFA, 0xFC), "bottom": (0xD4, 0xD6, 0xDC),
                "shadow": 0.38, "edge": (0, 0, 0, 0.10)},
    "dark":    {"top": (0x2B, 0x2C, 0x30), "bottom": (0x0F, 0x10, 0x12),
                "shadow": 0.60, "edge": (255, 255, 255, 0.10)},
    "mono":    {"top": (0x3A, 0x3A, 0x3C), "bottom": (0x1C, 0x1C, 0x1E),
                "shadow": 0.50, "edge": (255, 255, 255, 0.10)},
}
DEVICE_WIDTH = 0.84        # device width as a share of the square

_SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


# ----------------------------- small helpers ------------------------------
def save_png(im: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, format="PNG", optimize=True, icc_profile=_SRGB)


def resize_rgba(im: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Resize with premultiplied alpha so edges do not pick up a dark fringe."""
    return im.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def gradient(size: int, top, bottom) -> Image.Image:
    """Vertical gradient with a little noise so it never shows banding."""
    t = np.linspace(0.0, 1.0, size, dtype=np.float32)[:, None, None]
    top_a = np.array(top, dtype=np.float32)[None, None, :]
    bot_a = np.array(bottom, dtype=np.float32)[None, None, :]
    rows = top_a + (bot_a - top_a) * t
    img = np.repeat(rows, size, axis=1)
    rng = np.random.default_rng(7)
    img += rng.uniform(-0.5, 0.5, size=(size, size, 1)).astype(np.float32)
    rgb = np.clip(np.rint(img), 0, 255).astype(np.uint8)
    alpha = np.full((size, size, 1), 255, dtype=np.uint8)
    return Image.fromarray(np.concatenate([rgb, alpha], axis=2), "RGBA")


def squircle_points(x: float, y: float, w: float, h: float, r: float,
                    steps: int = 24) -> list[tuple[float, float]]:
    """Outline of Apple's continuous-corner rounded rectangle as a polygon."""
    def bez(p0, p1, p2, p3):
        out = []
        for i in range(1, steps + 1):
            t = i / steps
            mt = 1 - t
            out.append((
                mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0],
                mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1],
            ))
        return out

    # One corner (top right), described from the top edge round to the right
    # edge, in units of r measured back from the corner point.
    a, b, c, d, e, f, g = (1.52866483, 1.08849296, 0.86840694, 0.63149379,
                           0.37282383, 0.16905956, 0.07491139)
    corner = [
        ((a, 0), (b, 0), (c, 0), (d, g)),
        ((d, g), (e, f), (f, e), (g, d)),
        ((g, d), (0, c), (0, b), (0, a)),
    ]

    def place(kind, pt):
        u, v = pt[0] * r, pt[1] * r
        if kind == "tr":
            return (x + w - u, y + v)
        if kind == "br":
            return (x + w - v, y + h - u)
        if kind == "bl":
            return (x + u, y + h - v)
        return (x + v, y + u)  # tl

    pts: list[tuple[float, float]] = []
    for kind in ("tr", "br", "bl", "tl"):
        segs = corner
        start = place(kind, segs[0][0])
        pts.append(start)
        for seg in segs:
            p = [place(kind, q) for q in seg]
            pts.extend(bez(*p))
    return pts


def squircle_mask(size: int, body: int, ss: int = 8) -> Image.Image:
    """Antialiased mask of the icon's rounded square, centred in `size`."""
    big = size * ss
    m = Image.new("L", (big, big), 0)
    margin = (size - body) / 2.0
    r = BODY_RADIUS * body / BODY
    pts = squircle_points(margin * ss, margin * ss, body * ss, body * ss, r * ss)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((size, size), Image.BOX)


def blur_alpha(alpha: np.ndarray, sigma: float) -> np.ndarray:
    im = Image.fromarray(np.clip(alpha * 255.0, 0, 255).astype(np.uint8), "L")
    if sigma > 0.05:
        im = im.filter(ImageFilter.GaussianBlur(sigma))
    return np.asarray(im, dtype=np.float32) / 255.0


def shifted(alpha: np.ndarray, dy: float) -> np.ndarray:
    """Move an alpha map down by a possibly fractional number of pixels."""
    lo = int(math.floor(dy))
    frac = dy - lo

    def roll(a, n):
        out = np.zeros_like(a)
        if n == 0:
            return a.copy()
        if 0 < n < a.shape[0]:
            out[n:] = a[:-n]
        return out
    return roll(alpha, lo) * (1 - frac) + roll(alpha, lo + 1) * frac


# ------------------------------ the artwork -------------------------------
def rounded_mask(w: int, h: int, inset: float, radius: float) -> np.ndarray:
    """Antialiased rounded rectangle filling w x h, pulled in by `inset`."""
    ss = 4
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (inset * ss, inset * ss, (w - inset) * ss - 1, (h - inset) * ss - 1),
        radius=max(1.0, radius - inset) * ss, fill=255)
    return np.asarray(m.resize((w, h), Image.BOX), dtype=np.float32) / 255.0


def load_device(source: Path) -> Image.Image:
    """Turn the full-frame panel artwork into a free-standing device."""
    im = Image.open(source).convert("RGB")
    if im.size != SOURCE_SIZE:
        raise SystemExit(
            f"{source} is {im.size}; this script is set up for {SOURCE_SIZE}. "
            "Update SOURCE_SIZE, PANEL_EXTEND and DEVICE_RADIUS for new artwork.")
    e = PANEL_EXTEND
    rgb = np.pad(np.asarray(im, dtype=np.float32) / 255.0,
                 ((e["top"], e["bottom"]), (e["left"], e["right"]), (0, 0)),
                 mode="reflect")
    h, w, _ = rgb.shape
    body = rounded_mask(w, h, 0.0, DEVICE_RADIUS)
    line = rounded_mask(w, h, 2.5, DEVICE_RADIUS)   # inside the dark outline
    lip = rounded_mask(w, h, 6.5, DEVICE_RADIUS)    # inside the highlight
    y = np.linspace(0.0, 1.0, h, dtype=np.float32)[:, None]
    outline = (body - line)[..., None]
    highlight = ((line - lip) * np.clip(1.0 - y / 0.55, 0.0, 1.0))[..., None]
    undercut = ((line - lip) * np.clip((y - 0.55) / 0.45, 0.0, 1.0))[..., None]
    rgb = rgb * (1.0 - 0.60 * outline)               # dark outer edge
    rgb = rgb + (1.0 - rgb) * 0.26 * highlight       # light catching the top lip
    rgb = rgb * (1.0 - 0.35 * undercut)              # shade under the front lip
    out = np.concatenate([np.clip(rgb, 0.0, 1.0), body[..., None]], axis=2)
    return Image.fromarray(np.rint(out * 255.0).astype(np.uint8), "RGBA")


def device_for(variant: str, device: Image.Image) -> Image.Image:
    """Tune the device artwork for one appearance."""
    arr = np.asarray(device, dtype=np.float32) / 255.0
    rgb, alpha = arr[..., :3], arr[..., 3:]
    if variant == "default":
        return device
    value = rgb.max(axis=2, keepdims=True)
    luma = (rgb * np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)).sum(
        axis=2, keepdims=True)
    if variant == "dark":
        # Lift only the dark, colourless casing so it separates from a dark
        # background. Lit pads and the screen keep their colour.
        sat = value - rgb.min(axis=2, keepdims=True)
        casing = np.clip(1.0 - sat * 4.0, 0.0, 1.0) * np.clip(1.0 - value * 1.6, 0.0, 1.0)
        lifted = rgb + casing * (0.085 + 0.25 * rgb)
        out = np.clip(lifted, 0.0, 1.0)
    else:  # mono: greyscale, with lit controls bright and the casing mid-grey
        m = 0.7 * value + 0.3 * luma
        tone = 0.24 + 0.76 * np.power(m, 0.85)
        out = np.repeat(np.clip(tone, 0.0, 1.0), 3, axis=2)
    res = np.concatenate([out, alpha], axis=2)
    return Image.fromarray(np.rint(res * 255.0).astype(np.uint8), "RGBA")


def device_layer(size: int, device: Image.Image, width_share: float) -> Image.Image:
    """The device alone, centred on a transparent square of `size` px."""
    dw = max(1, round(size * width_share))
    if (size - dw) % 2:          # equal whole-pixel margins left and right
        dw += 1
    dh = max(1, round(device.height * dw / device.width))
    if (size - dh) % 2 and dh > 1:
        dh -= 1
    small = resize_rgba(device, (dw, dh))
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.alpha_composite(small, ((size - dw) // 2, (size - dh) // 2))
    return layer


def compose_square(variant: str, size: int, device: Image.Image,
                   width_share: float = DEVICE_WIDTH) -> Image.Image:
    """Full-bleed square: gradient background, soft shadow, device."""
    v = VARIANTS[variant]
    art = gradient(size, v["top"], v["bottom"])
    layer = device_layer(size, device_for(variant, device), width_share)
    alpha = np.asarray(layer, dtype=np.float32)[..., 3] / 255.0
    k = size / 1024.0
    # Two shadows: a tight contact shadow and a wide soft one.
    contact = blur_alpha(shifted(alpha, 6 * k), 5 * k) * 0.55
    ambient = blur_alpha(shifted(alpha, 26 * k), 30 * k) * 0.75
    sh = np.clip((contact + ambient) * v["shadow"], 0.0, 1.0)
    shadow = np.zeros((size, size, 4), dtype=np.uint8)
    shadow[..., 3] = np.rint(sh * 255.0).astype(np.uint8)
    art.alpha_composite(Image.fromarray(shadow, "RGBA"))
    art.alpha_composite(layer)
    return art


def render_icon(variant: str, size: int, device: Image.Image) -> Image.Image:
    """One finished icon file: rounded square, margin and drop shadow."""
    body = BODY_PX[size]
    art = compose_square(variant, body, device)
    if size <= 64:
        art = art.filter(ImageFilter.UnsharpMask(radius=0.6, percent=70, threshold=0))
    mask_full = squircle_mask(size, body)
    m = np.asarray(mask_full, dtype=np.float32) / 255.0
    k = size / 1024.0

    canvas = np.zeros((size, size, 4), dtype=np.float32)
    # drop shadow under the rounded square
    sh = blur_alpha(shifted(m, SHADOW_OFFSET_Y * k), SHADOW_SIGMA * k) * SHADOW_OPACITY
    canvas[..., 3] = sh

    plate = np.zeros((size, size, 4), dtype=np.float32)
    off = (size - body) // 2
    plate[off:off + body, off:off + body, :3] = (
        np.asarray(art, dtype=np.float32)[..., :3] / 255.0)
    # hairline along the edge so the square stays defined on any backdrop
    er, eg, eb, ea = VARIANTS[variant]["edge"]
    inner = blur_alpha(m, max(0.6, 1.2 * k))
    rim = np.clip((m - inner) * 3.0, 0.0, 1.0)[..., None] * ea
    edge_rgb = np.array([er, eg, eb], dtype=np.float32) / 255.0
    plate[..., :3] = plate[..., :3] * (1 - rim) + edge_rgb * rim
    plate[..., 3] = m

    a_src = plate[..., 3:4]
    a_dst = canvas[..., 3:4]
    out_a = a_src + a_dst * (1 - a_src)
    out_rgb = np.where(out_a > 0, plate[..., :3] * a_src / np.maximum(out_a, 1e-6), 0.0)
    out = np.concatenate([out_rgb, out_a], axis=2)
    return Image.fromarray(np.rint(np.clip(out, 0, 1) * 255.0).astype(np.uint8), "RGBA")


# ------------------------------- the outputs ------------------------------
def write_iconset(device: Image.Image) -> None:
    iconset = HERE / "AppIcon.iconset"
    appiconset = HERE / "AppIcon.appiconset"
    for folder in (iconset, appiconset):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
    cache: dict[int, Image.Image] = {}
    images = []
    for name, px in ICONSET:
        if px not in cache:
            cache[px] = render_icon("default", px, device)
        save_png(cache[px], iconset / name)
        save_png(cache[px], appiconset / name)
        points = px // 2 if "@2x" in name else px
        images.append({"filename": name, "idiom": "mac",
                       "scale": "2x" if "@2x" in name else "1x",
                       "size": f"{points}x{points}"})
    (appiconset / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def write_icns() -> None:
    import icnsutil
    icns = icnsutil.IcnsFile()
    for name, _px in ICONSET:
        path = str(HERE / "AppIcon.iconset" / name)
        key = ICNS_KEYS[name]
        if key in ("ic04", "ic05"):
            # The two smallest sizes are stored as packed ARGB, as iconutil does.
            icns.add_media(key, data=icnsutil.ArgbImage(file=path).argb_data())
        else:
            icns.add_media(key, file=path)
    icns.write(str(HERE / "AppIcon.icns"), toc=True)


def colour(rgb) -> str:
    return "srgb:" + ",".join(f"{c / 255:.5f}" for c in rgb) + ",1.00000"


def write_icon_composer(device: Image.Image) -> None:
    bundle = HERE / "AppIcon.icon"
    shutil.rmtree(bundle, ignore_errors=True)
    assets = bundle / "Assets"
    names = {"default": "device.png", "dark": "device-dark.png", "mono": "device-mono.png"}
    for variant, name in names.items():
        save_png(device_layer(CANVAS, device_for(variant, device), DEVICE_WIDTH),
                 assets / name)

    def fill(variant):
        v = VARIANTS[variant]
        return {"linear-gradient": [colour(v["top"]), colour(v["bottom"])],
                "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}

    doc = {
        "fill-specializations": [
            {"value": fill("default")},
            {"appearance": "dark", "value": fill("dark")},
        ],
        "groups": [{
            "name": "Device",
            "layers": [{
                "name": "MPC Live II",
                "glass": False,
                "image-name-specializations": [
                    {"value": names["default"]},
                    {"appearance": "dark", "value": names["dark"]},
                    {"appearance": "tinted", "value": names["mono"]},
                ],
            }],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    (bundle / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


def write_masters(device: Image.Image) -> None:
    for variant in VARIANTS:
        save_png(compose_square(variant, CANVAS, device).convert("RGB"),
                 HERE / "masters" / f"AppIcon-{variant}-1024.png")


def write_preview(device: Image.Image) -> None:
    """Contact sheet: three appearances large, then every real size."""
    from PIL import ImageFont
    font = ImageFont.load_default(size=20)
    small = ImageFont.load_default(size=15)
    pad, big = 40, 400
    w = pad + 3 * (big + pad)
    top_h = pad + big + 50
    strip_h = 210
    sheet = Image.new("RGBA", (w, top_h + 2 * strip_h), (236, 236, 240, 255))
    sheet.alpha_composite(Image.new("RGBA", (w, strip_h), (30, 30, 34, 255)),
                          (0, top_h + strip_h))
    draw = ImageDraw.Draw(sheet)
    labels = {"default": "Default", "dark": "Dark",
              "mono": "Mono (basis for clear and tinted)"}
    for i, variant in enumerate(VARIANTS):
        x = pad + i * (big + pad)
        icon = render_icon(variant, 1024, device).resize((big, big), Image.LANCZOS)
        sheet.alpha_composite(icon, (x, pad))
        draw.text((x + big / 2, pad + big + 8), labels[variant], font=font,
                  fill=(60, 60, 67), anchor="ma")
    for row in (0, 1):
        y = top_h + row * strip_h + 24
        ink = (60, 60, 67) if row == 0 else (200, 200, 206)
        x = pad
        for px in (256, 128, 64, 32, 16):
            icon = render_icon("default", px, device)
            shown = icon if px <= 128 else icon.resize((128, 128), Image.LANCZOS)
            sheet.alpha_composite(shown, (x, y + 128 - shown.height))
            draw.text((x + shown.width / 2, y + 136), f"{px} px", font=small,
                      fill=ink, anchor="ma")
            x += shown.width + 34
        x += 30
        for px, zoom in ((32, 4), (16, 8)):
            icon = render_icon("default", px, device).resize(
                (px * zoom, px * zoom), Image.NEAREST)
            sheet.alpha_composite(icon, (x, y))
            draw.text((x + 64, y + 136), f"{px} px, enlarged {zoom}x", font=small,
                      fill=ink, anchor="ma")
            x += 128 + 60
    save_png(sheet.convert("RGB"), HERE / "preview.png")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                    help="panel artwork, 1728 x 1024 (default: icon/source/)")
    args = ap.parse_args()
    device = load_device(args.source)
    write_masters(device)
    write_iconset(device)
    write_icns()
    write_icon_composer(device)
    write_preview(device)
    print(f"Built icon assets in {HERE} from {args.source.name}")


if __name__ == "__main__":
    main()
