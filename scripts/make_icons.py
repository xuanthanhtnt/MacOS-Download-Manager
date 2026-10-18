#!/usr/bin/env python3
"""Generates the MacOS Download Manager app icon set (Resources/AppIcon.iconset) and the browser-extension icons.

Requires Pillow:  pip install pillow
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2048  # supersampled canvas


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(size, top_left, bottom_right):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = lerp(top_left, bottom_right, t) + (255,)
    return img


def draw_icon(full_bleed=False):
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    margin = 0 if full_bleed else int(S * 0.098)  # macOS icon grid: ~824/1024 body
    body = S - 2 * margin
    radius = int(body * 0.225)

    # Drop shadow
    if not full_bleed:
        shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            [margin, margin + int(S * 0.012), margin + body, margin + body + int(S * 0.012)],
            radius=radius, fill=(0, 0, 0, 110))
        shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.018))
        canvas.alpha_composite(shadow)

    # Gradient body (computed small then upscaled for speed)
    g = gradient(256, (32, 92, 255), (16, 200, 190)).resize((body, body), Image.BICUBIC)
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)
    tile = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    tile.paste(g, (0, 0), mask)

    # Soft top highlight
    hl = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse([-body * 0.3, -body * 0.8, body * 1.3, body * 0.45], fill=(255, 255, 255, 34))
    hl = hl.filter(ImageFilter.GaussianBlur(body * 0.04))
    clear = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    tile.alpha_composite(Image.composite(hl, clear, mask))

    overlay = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    white = (255, 255, 255, 255)
    cx = body * 0.56

    # Speed streaks
    for i, (y, length) in enumerate([(0.34, 0.20), (0.46, 0.26), (0.58, 0.18)]):
        x1 = body * 0.13
        d.rounded_rectangle([x1, body * y - body * 0.022, x1 + body * length, body * y + body * 0.022],
                            radius=int(body * 0.022), fill=(255, 255, 255, 170 - i * 25))

    # Arrow shaft + head
    shaft_w = body * 0.15
    d.rounded_rectangle([cx - shaft_w / 2, body * 0.18, cx + shaft_w / 2, body * 0.56],
                        radius=int(body * 0.04), fill=white)
    head_w = body * 0.42
    d.polygon([(cx - head_w / 2, body * 0.50), (cx + head_w / 2, body * 0.50), (cx, body * 0.75)], fill=white)
    # Tray
    tray_y = body * 0.80
    d.rounded_rectangle([cx - body * 0.27, tray_y, cx + body * 0.27, tray_y + body * 0.06],
                        radius=int(body * 0.03), fill=white)

    tile.alpha_composite(Image.composite(overlay, clear, mask))
    canvas.alpha_composite(tile, (margin, margin))
    return canvas


def main():
    icon = draw_icon()
    iconset = os.path.join(ROOT, "Resources", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    icon.resize((1024, 1024), Image.LANCZOS).save(os.path.join(ROOT, "Resources", "AppIcon-1024.png"))

    ext_icon = draw_icon(full_bleed=False)
    for folder in ("shared",):
        out = os.path.join(ROOT, "BrowserExtension", folder, "icons")
        os.makedirs(out, exist_ok=True)
        for size in (16, 32, 48, 128):
            ext_icon.resize((size, size), Image.LANCZOS).save(os.path.join(out, f"icon-{size}.png"))
    print("Icons written to", iconset)


if __name__ == "__main__":
    main()
