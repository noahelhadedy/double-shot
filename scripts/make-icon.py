"""Turns a full-bleed square artwork into a macOS app icon PNG (1024, squircle + shadow).
Usage: python3 scripts/make-icon.py artwork.png out.png"""
import sys
from PIL import Image, ImageDraw, ImageFilter

src, out = sys.argv[1], sys.argv[2]
S, BODY, OFF = 1024, 824, 100
SS = 4  # supersampling for smooth edges

art = Image.open(src).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)

# Superellipse close to Apple's continuous corner shape
mask = Image.new("L", (BODY * SS, BODY * SS), 0)
n, r = 5.0, BODY * SS / 2
pts = []
import math
for i in range(720):
    t = 2 * math.pi * i / 720
    c, s = math.cos(t), math.sin(t)
    x = r + r * (abs(c) ** (2 / n)) * (1 if c >= 0 else -1)
    y = r + r * (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)
    pts.append((x, y))
ImageDraw.Draw(mask).polygon(pts, fill=255)
mask = mask.resize((BODY, BODY), Image.LANCZOS)

body = Image.new("RGBA", (BODY, BODY))
body.paste(art, (0, 0), mask)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow_mask = Image.new("L", (S, S), 0)
shadow_mask.paste(mask, (OFF, OFF + 12))
shadow.putalpha(shadow_mask.point(lambda v: v * 0.35).filter(ImageFilter.GaussianBlur(14)))
canvas = Image.alpha_composite(canvas, shadow)
canvas.paste(body, (OFF, OFF), body)
canvas.save(out)
