#!/usr/bin/env python3
"""Generate the Push to Transcribe app icon (.icns) and web favicons.

Renders a macOS Big Sur style squircle with a microphone glyph, matching the
"mic" SF Symbol used for the menu bar item. Everything is drawn at 8x and
downsampled, so the output is clean at every size.

Usage:  python3 scripts/generate_icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"

SS = 8                      # supersample factor
CANVAS = 1024               # nominal icon canvas
SHAPE = 824                 # squircle size inside the canvas (Apple's grid)
GRADIENT_TOP = (139, 107, 255)
GRADIENT_BOTTOM = (75, 46, 212)


def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """Superellipse mask: |x|^n + |y|^n = 1, which reads as an Apple corner."""
    r = size / 2
    steps = 2048
    points = []
    for i in range(steps):
        t = 2 * 3.141592653589793 * i / steps
        import math
        c, s = math.cos(t), math.sin(t)
        x = math.copysign(abs(c) ** (2 / n), c)
        y = math.copysign(abs(s) ** (2 / n), s)
        points.append((r + x * r, r + y * r))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return grad.resize((size, size), Image.Resampling.BILINEAR)


def round_line(draw: ImageDraw.ImageDraw, p0, p1, width: int, fill):
    """A line with round caps (ImageDraw.line's joint arg doesn't cap ends)."""
    draw.line([p0, p1], fill=fill, width=width)
    r = width / 2
    for x, y in (p0, p1):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def draw_mic(img: Image.Image, s: float, ox: float, oy: float):
    """Microphone glyph, sized in fractions of the squircle edge `s`."""
    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    cx = ox + s * 0.5
    lift = s * 0.012                       # nudge up so the base doesn't sit low
    stroke = round(s * 0.052)

    # Capsule body
    cap_w, cap_h = s * 0.215, s * 0.400
    cap_top = oy + s * 0.150 - lift
    d.rounded_rectangle(
        [cx - cap_w / 2, cap_top, cx + cap_w / 2, cap_top + cap_h],
        radius=cap_w / 2,
        fill=white,
    )

    # Cradle arc under the capsule
    arc_r = s * 0.178
    arc_cy = oy + s * 0.487 - lift
    d.arc(
        [cx - arc_r, arc_cy - arc_r, cx + arc_r, arc_cy + arc_r],
        start=0, end=180, fill=white, width=stroke,
    )
    cap_r = arc_r - stroke / 2             # arc's band is inset from `arc_r`
    for sx in (-1, 1):                     # round off the arc's open ends
        x = cx + sx * cap_r
        d.ellipse(
            [x - stroke / 2, arc_cy - stroke / 2, x + stroke / 2, arc_cy + stroke / 2],
            fill=white,
        )

    # Stem and base
    stem_top = arc_cy + arc_r
    base_y = oy + s * 0.790 - lift
    round_line(d, (cx, stem_top), (cx, base_y), stroke, white)
    round_line(d, (cx - s * 0.130, base_y), (cx + s * 0.130, base_y), stroke, white)


def render_master() -> Image.Image:
    c, s = CANVAS * SS, SHAPE * SS
    off = (c - s) / 2
    icon = Image.new("RGBA", (c, c), (0, 0, 0, 0))

    mask = squircle_mask(s)

    # Drop shadow beneath the shape
    shadow = Image.new("RGBA", (c, c), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (round(off), round(off + 0.012 * s)), mask)
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(0.022 * s)))

    # Gradient body
    body = vertical_gradient(s, GRADIENT_TOP, GRADIENT_BOTTOM).convert("RGBA")
    body.putalpha(mask)

    # Soft light from the top edge
    gloss = Image.new("L", (s, s), 0)
    ImageDraw.Draw(gloss).ellipse([-s * 0.35, -s * 0.85, s * 1.35, s * 0.55], fill=54)
    gloss = gloss.filter(ImageFilter.GaussianBlur(0.06 * s))
    highlight = Image.new("RGBA", (s, s), (255, 255, 255, 0))
    highlight.putalpha(gloss)
    body.alpha_composite(highlight)
    body.putalpha(mask)

    icon.alpha_composite(body, (round(off), round(off)))
    draw_mic(icon, s, off, off)
    return icon


def resized(master: Image.Image, size: int) -> Image.Image:
    return master.resize((size, size), Image.Resampling.LANCZOS)


def main():
    ASSETS.mkdir(exist_ok=True)
    master = render_master()

    # 1024 preview / source of truth
    resized(master, 1024).save(ASSETS / "icon-1024.png")

    # .iconset -> .icns
    iconset = ASSETS / "AppIcon.iconset"
    for old in iconset.glob("*.png"):
        old.unlink()
    iconset.mkdir(exist_ok=True)
    for pt in (16, 32, 128, 256, 512):
        resized(master, pt).save(iconset / f"icon_{pt}x{pt}.png")
        resized(master, pt * 2).save(iconset / f"icon_{pt}x{pt}@2x.png")

    # Web favicons (glyph fills more of the frame; no canvas padding needed)
    web = ASSETS / "favicon"
    web.mkdir(exist_ok=True)
    trimmed = master.crop(master.getbbox())
    for size, name in ((16, "favicon-16.png"), (32, "favicon-32.png"),
                       (180, "apple-touch-icon.png"), (192, "favicon-192.png"),
                       (512, "favicon-512.png")):
        trimmed.resize((size, size), Image.Resampling.LANCZOS).save(web / name)
    trimmed.resize((256, 256), Image.Resampling.LANCZOS).save(
        web / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    )
    print(f"wrote {ASSETS}")


if __name__ == "__main__":
    main()
