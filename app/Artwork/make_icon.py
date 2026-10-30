"""Speaka app icon: an original design (white speaker with sound waves on an indigo-violet-teal gradient).
Rendered at 2x and downsampled for anti-aliasing. iOS applies the rounded mask itself, so the art is full-bleed."""
import math, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048                                   # supersampled canvas
def lerp(a, b, t): return a + (b - a) * t
def hex_rgb(h): return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], dtype=np.float64)

# --- background: diagonal three-stop gradient plus a soft glow behind the glyph
y, x = np.mgrid[0:S, 0:S].astype(np.float64) / (S - 1)
t = np.clip((x * 0.6 + y * 0.6) - 0.1, 0, 1)
c0, c1, c2 = hex_rgb("#1B1446"), hex_rgb("#5B2BB5"), hex_rgb("#12B3A6")
lo = np.clip(t / 0.55, 0, 1)[..., None]; hi = np.clip((t - 0.55) / 0.45, 0, 1)[..., None]
rgb = np.where((t < 0.55)[..., None], c0 + (c1 - c0) * lo, c1 + (c2 - c1) * hi)
gx, gy = 0.50, 0.50                                                    # glow centre
d = np.sqrt((x - gx) ** 2 + (y - gy) ** 2)
glow = np.clip(1 - d / 0.55, 0, 1) ** 2.2
rgb = rgb + (hex_rgb("#9FE8FF") - rgb) * (glow[..., None] * 0.28)
img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

# --- glyph geometry (in supersampled pixels)
cx, cy = S * 0.315, S * 0.50
body_w, body_h = S * 0.105, S * 0.20
body = (cx - body_w, cy - body_h / 2, cx, cy + body_h / 2)
cone = [(cx - S * 0.004, cy - body_h / 2), (cx + S * 0.135, cy - S * 0.215),
        (cx + S * 0.135, cy + S * 0.215), (cx - S * 0.004, cy + body_h / 2)]
waves = [(S * 0.175, 1.00), (S * 0.258, 0.80), (S * 0.341, 0.58)]   # radius from the cone mouth, opacity
mouth = (cx + S * 0.135, cy)
stroke = int(S * 0.048)
span = 42                                                             # degrees either side of horizontal

def draw_glyph(draw, colour, alpha_scale=1.0):
    r = int(S * 0.028)
    draw.rounded_rectangle(body, radius=r, fill=colour + (int(255 * alpha_scale),))
    draw.polygon(cone, fill=colour + (int(255 * alpha_scale),))
    for radius, opacity in waves:
        a = int(255 * opacity * alpha_scale)
        bbox = (mouth[0] - radius, mouth[1] - radius, mouth[0] + radius, mouth[1] + radius)
        draw.arc(bbox, start=-span, end=span, fill=colour + (a,), width=stroke)
        for ang in (-span, span):                                    # rounded caps
            px = mouth[0] + (radius - stroke / 2) * math.cos(math.radians(ang))
            py = mouth[1] + (radius - stroke / 2) * math.sin(math.radians(ang))
            draw.ellipse((px - stroke / 2, py - stroke / 2, px + stroke / 2, py + stroke / 2), fill=colour + (a,))

# soft shadow for depth
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw_glyph(ImageDraw.Draw(shadow), (10, 6, 40), 0.55)
shadow = shadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -S * 0.012)).filter(ImageFilter.GaussianBlur(S * 0.018))
img = Image.alpha_composite(img, shadow)
# each wave is drawn on its own layer so overlapping caps do not double the alpha
glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw_glyph(ImageDraw.Draw(glyph), (255, 255, 255))
img = Image.alpha_composite(img, glyph)

final = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")
final.save(sys.argv[1])
print("wrote", sys.argv[1], final.size)
