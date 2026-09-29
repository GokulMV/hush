#!/usr/bin/env python3
"""Draws the Hush app icon and writes Resources/AppIcon.icns (needs Pillow: pip install pillow).

Design: an indigo→teal rounded square (macOS icon grid) with a white sound waveform
cut by a diagonal slash: "sound, silenced".
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # draw at 2x of 1024 and downsample for smooth edges


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def rounded_mask(box, radius):
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def draw_icon():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS Big Sur+ grid: 824/1024 body, centred, ~185/1024 corner radius.
    inset = S * 100 // 1024
    body = (inset, inset, S - inset, S - inset)
    radius = S * 185 // 1024

    # Soft drop shadow.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow_box = (body[0], body[1] + S // 64, body[2], body[3] + S // 64)
    shadow.putalpha(rounded_mask(shadow_box, radius).point(lambda v: v * 70 // 255))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(S // 60)))

    # Diagonal gradient body.
    top, bottom = (88, 86, 246), (20, 190, 175)
    gradient = Image.new("RGBA", (S, S))
    pixels = gradient.load()
    for y in range(S):
        for x in range(0, S, 4):
            colour = lerp(top, bottom, min(1.0, max(0.0, (0.75 * y + 0.25 * x) / S)))
            for dx in range(4):
                pixels[x + dx, y] = colour + (255,)
    body_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body_layer.paste(gradient, (0, 0), rounded_mask(body, radius))

    # Subtle top highlight.
    gloss = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    ImageDraw.Draw(gloss).ellipse((-S // 4, -S * 3 // 4, S * 5 // 4, S // 2), fill=(255, 255, 255, 26))
    gloss = gloss.filter(ImageFilter.GaussianBlur(S // 12))
    gloss_masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gloss_masked.paste(gloss, (0, 0), rounded_mask(body, radius))
    body_layer = Image.alpha_composite(body_layer, gloss_masked)
    icon = Image.alpha_composite(icon, body_layer)

    # White waveform: five rounded bars.
    glyph = Image.new("L", (S, S), 0)
    g = ImageDraw.Draw(glyph)
    cx, cy = S // 2, S // 2
    bar_w = S * 78 // 1024
    gap = S * 52 // 1024
    heights = [220, 400, 540, 400, 220]
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = cx - total // 2
    for h in heights:
        h = S * h // 1024
        g.rounded_rectangle((x, cy - h // 2, x + bar_w, cy + h // 2), radius=bar_w // 2, fill=255)
        x += bar_w + gap

    # Diagonal slash: cut a wide channel out of the bars, then draw a thinner white line in it.
    def slash(width):
        layer = Image.new("L", (S, S), 0)
        d = ImageDraw.Draw(layer)
        span = S * 245 // 1024
        start, end = (cx - span, cy - span), (cx + span, cy + span)
        d.line((start, end), fill=255, width=width)
        for px, py in (start, end):
            d.ellipse((px - width // 2, py - width // 2, px + width // 2, py + width // 2), fill=255)
        return layer

    glyph = ImageChops.subtract(glyph, slash(S * 150 // 1024))
    glyph = ImageChops.lighter(glyph, slash(S * 66 // 1024))

    white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    glyph_shadow = Image.new("RGBA", (S, S), (20, 20, 60, 0))
    glyph_shadow.putalpha(glyph.point(lambda v: v * 60 // 255).filter(ImageFilter.GaussianBlur(S // 120)))
    icon = Image.alpha_composite(icon, ImageChops.offset(glyph_shadow, 0, S // 200))
    white.putalpha(glyph)
    icon = Image.alpha_composite(icon, white)

    return icon.resize((1024, 1024), Image.LANCZOS)


def png_bytes(image, size):
    buffer = io.BytesIO()
    image.resize((size, size), Image.LANCZOS).save(buffer, "PNG")
    return buffer.getvalue()


def write_icns(image, path):
    # PNG-backed icns chunk types understood by macOS 10.7+.
    chunks = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
              ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
    body = b"".join(
        kind.encode() + struct.pack(">I", 8 + len(data)) + data
        for kind, data in ((kind, png_bytes(image, size)) for kind, size in chunks)
    )
    path.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    icon = draw_icon()
    write_icns(icon, root / "Resources" / "AppIcon.icns")
    if len(sys.argv) > 1:
        icon.save(sys.argv[1])  # optional preview PNG
    print("Wrote Resources/AppIcon.icns")
