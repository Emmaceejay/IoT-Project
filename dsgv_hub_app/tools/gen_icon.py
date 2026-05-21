#!/usr/bin/env python3
"""Generate the DSGV Hub app icon — 1024x1024 PNG.

Design language: dark navy (#0A0E1A) background, cyan (#00E5FF) accent.
The icon shows a six-node network hub ring above bold DSGV / HUB text.
All drawing is done at 2× (2048) and resampled to 1024 for smooth AA.
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math, os, sys

# ── Constants ──────────────────────────────────────────────────────────────────
DRAW  = 2048   # draw at 2× for LANCZOS anti-aliasing
FINAL = 1024

BG    = (10,  14,  26,  255)   # #0A0E1A
CYAN  = (0,  229, 255, 255)    # #00E5FF
WHITE = (255, 255, 255, 255)
DARK  = (10,  14,  26,  255)   # re-used for ring centres

cx = cy = DRAW // 2
hub_cx  = cx
hub_cy  = cy - 160   # hub sits in upper 60 % of icon

# ── Helper: composite one RGBA layer onto base ─────────────────────────────────
def over(base, layer):
    return Image.alpha_composite(base, layer)

# ─────────────────────────────────────────────────────────────────────────────
# 1. Background
# ─────────────────────────────────────────────────────────────────────────────
img = Image.new('RGBA', (DRAW, DRAW), BG)

# ─────────────────────────────────────────────────────────────────────────────
# 2. Soft radial glow behind hub  (draw → blur → composite)
# ─────────────────────────────────────────────────────────────────────────────
glow = Image.new('RGBA', (DRAW, DRAW), (0, 0, 0, 0))
gd   = ImageDraw.Draw(glow)
for r in range(420, 20, -6):
    a = max(0, int(110 * (1 - r / 420)))
    gd.ellipse([hub_cx - r, hub_cy - r, hub_cx + r, hub_cy + r],
               fill=(0, 229, 255, a))
glow = glow.filter(ImageFilter.GaussianBlur(50))
img  = over(img, glow)

# ─────────────────────────────────────────────────────────────────────────────
# 3. Hub geometry: hexagonal outer ring, spokes, nodes, centre ring
# ─────────────────────────────────────────────────────────────────────────────
hub = Image.new('RGBA', (DRAW, DRAW), (0, 0, 0, 0))
hd  = ImageDraw.Draw(hub)

spoke_len = 245   # centre → node distance
num_nodes = 6
node_pts  = []

for i in range(num_nodes):
    angle = math.radians(i * 60 - 90)          # start from 12-o'clock
    nx = hub_cx + int(spoke_len * math.cos(angle))
    ny = hub_cy + int(spoke_len * math.sin(angle))
    node_pts.append((nx, ny))

# Hexagonal outline connecting adjacent nodes
for i in range(num_nodes):
    p1 = node_pts[i]
    p2 = node_pts[(i + 1) % num_nodes]
    hd.line([p1, p2], fill=(0, 229, 255, 70), width=4)

# Spokes
for nx, ny in node_pts:
    hd.line([hub_cx, hub_cy, nx, ny], fill=(0, 229, 255, 150), width=6)

# Outer nodes
for nx, ny in node_pts:
    r = 26
    hd.ellipse([nx - r*2, ny - r*2, nx + r*2, ny + r*2], fill=(0, 229, 255, 50))   # halo
    hd.ellipse([nx - r,   ny - r,   nx + r,   ny + r  ], fill=(0, 229, 255, 220))  # solid
    hd.ellipse([nx - 14,  ny - 14,  nx + 14,  ny + 14 ], fill=DARK)                # inner dark dot

# Central hub ring
cr_outer, cr_inner = 88, 54
hd.ellipse([hub_cx - cr_outer, hub_cy - cr_outer,
            hub_cx + cr_outer, hub_cy + cr_outer], fill=CYAN)
hd.ellipse([hub_cx - cr_inner, hub_cy - cr_inner,
            hub_cx + cr_inner, hub_cy + cr_inner], fill=DARK)

img = over(img, hub)

# ─────────────────────────────────────────────────────────────────────────────
# 4. Text  ("DSGV"  then  "HUB")
# ─────────────────────────────────────────────────────────────────────────────
txt = Image.new('RGBA', (DRAW, DRAW), (0, 0, 0, 0))
td  = ImageDraw.Draw(txt)

# Bold system font candidates (Windows)
bold_candidates = [
    "C:/Windows/Fonts/arialbd.ttf",
    "C:/Windows/Fonts/calibrib.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/verdanab.ttf",
]
reg_candidates = [
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/calibri.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/verdana.ttf",
]

def load_font(paths, size):
    for p in paths:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            pass
    return ImageFont.load_default(size=size // 2)

font_main = load_font(bold_candidates, 248)   # "DSGV"
font_sub  = load_font(reg_candidates,  96)    # "HUB"

def draw_centred(draw, text, font, y, color):
    bb = draw.textbbox((0, 0), text, font=font)
    x  = cx - (bb[2] - bb[0]) // 2 - bb[0]
    draw.text((x, y), text, font=font, fill=color)
    return bb[3] - bb[1]   # return text height

text_top = hub_cy + 310   # start of "DSGV" text
h_main   = draw_centred(td, "DSGV", font_main, text_top, WHITE)
draw_centred(td, "HUB",  font_sub,  text_top + h_main + 14, CYAN)

img = over(img, txt)

# ─────────────────────────────────────────────────────────────────────────────
# 5. Thin horizontal separator between hub and text
# ─────────────────────────────────────────────────────────────────────────────
sep = Image.new('RGBA', (DRAW, DRAW), (0, 0, 0, 0))
sd  = ImageDraw.Draw(sep)
sep_y = hub_cy + 270
sd.line([(cx - 300, sep_y), (cx + 300, sep_y)], fill=(0, 229, 255, 80), width=3)
img = over(img, sep)

# ─────────────────────────────────────────────────────────────────────────────
# 6. Downsample  2048 → 1024  for smooth anti-aliasing, then save
# ─────────────────────────────────────────────────────────────────────────────
out_dir  = r"C:\Users\ojike\OneDrive\Documents\AI_projects\IoT-Project\dsgv_hub_app\assets\icons"
out_path = os.path.join(out_dir, "app_icon.png")

os.makedirs(out_dir, exist_ok=True)

final = img.resize((FINAL, FINAL), Image.LANCZOS).convert('RGB')
final.save(out_path, 'PNG', optimize=True)
print(f"Saved {FINAL}x{FINAL} icon → {out_path}")
