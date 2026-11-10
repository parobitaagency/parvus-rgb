# Draws the Parvus app icon: a graphite tile, a glowing RGB underglow and a
# single white keycap. Writes icon_1024.png and ../AppIcon.icns.
import colorsys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 1024
SS = 2  # supersampling
W = S * SS

def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))

# Tile: macOS grid, 824 pt body inside 1024 with ~22% corner radius.
tile_box = [100 * SS, 100 * SS, 924 * SS, 924 * SS]
tile_radius = 185 * SS
tile = Image.new("RGBA", (W, W))
g = ImageDraw.Draw(tile)
for y in range(tile_box[1], tile_box[3]):
    t = (y - tile_box[1]) / (tile_box[3] - tile_box[1])
    c = (int(38 - 20 * t), int(40 - 21 * t), int(48 - 24 * t), 255)
    g.line([(tile_box[0], y), (tile_box[2], y)], fill=c)
tile_mask = rounded_mask((W, W), tile_box, tile_radius)

# RGB underglow: a rainbow band, blurred.
glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
x0, x1 = 230 * SS, 794 * SS
for x in range(x0, x1):
    t = (x - x0) / (x1 - x0)
    r, gg, b = colorsys.hsv_to_rgb(0.92 - 0.92 * t, 0.9, 1.0)
    gd.line([(x, 600 * SS), (x, 700 * SS)], fill=(int(r * 255), int(gg * 255), int(b * 255), 255))
glow = glow.filter(ImageFilter.GaussianBlur(70 * SS))
glow2 = glow.filter(ImageFilter.GaussianBlur(25 * SS))
tile = Image.alpha_composite(tile, glow)
tile = Image.alpha_composite(tile, glow)
tile = Image.alpha_composite(tile, glow2)

# Keycap: base (darker skirt) and top face.
key = Image.new("RGBA", (W, W), (0, 0, 0, 0))
kd = ImageDraw.Draw(key)
base = [300 * SS, 330 * SS, 724 * SS, 690 * SS]
kd.rounded_rectangle(base, radius=70 * SS, fill=(205, 208, 216, 255))
top = [342 * SS, 350 * SS, 682 * SS, 620 * SS]
# Top face with a soft vertical gradient.
face = Image.new("RGBA", (W, W), (0, 0, 0, 0))
fd = ImageDraw.Draw(face)
for y in range(top[1], top[3]):
    t = (y - top[1]) / (top[3] - top[1])
    v = int(252 - 18 * t)
    fd.line([(top[0], y), (top[2], y)], fill=(v, v, min(255, v + 3), 255))
face_mask = rounded_mask((W, W), top, 52 * SS)
key.paste(face, (0, 0), face_mask)
# Coloured rim light along the skirt's bottom edge.
rim = Image.new("RGBA", (W, W), (0, 0, 0, 0))
rd = ImageDraw.Draw(rim)
for x in range(base[0], base[2]):
    t = (x - base[0]) / (base[2] - base[0])
    r, gg, b = colorsys.hsv_to_rgb(0.92 - 0.92 * t, 0.85, 1.0)
    rd.line([(x, 640 * SS), (x, 690 * SS)], fill=(int(r * 255), int(gg * 255), int(b * 255), 150))
rim_mask = rounded_mask((W, W), base, 70 * SS)
rim_alpha = ImageChops.multiply(rim.split()[3], rim_mask)
rim.putalpha(rim_alpha)
key = Image.alpha_composite(key, rim)
# Letter P on the top face, in graphite.
ld = ImageDraw.Draw(key)
stroke = 34 * SS
px, py = 452 * SS, 405 * SS
h = 165 * SS
ld.rounded_rectangle([px, py, px + stroke, py + h], radius=stroke // 2, fill=(46, 48, 58, 255))
bowl = [px, py, px + 120 * SS, py + 100 * SS]
ld.rounded_rectangle(bowl, radius=50 * SS, outline=(46, 48, 58, 255), width=stroke)
# Accent dot: the LED.
ld.ellipse([600 * SS, 405 * SS, 630 * SS, 435 * SS], fill=(255, 70, 160, 255))

# Shadow under the keycap.
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([310 * SS, 360 * SS, 714 * SS, 715 * SS], radius=80 * SS, fill=(0, 0, 0, 140))
shadow = shadow.filter(ImageFilter.GaussianBlur(28 * SS))
tile = Image.alpha_composite(tile, shadow)
tile = Image.alpha_composite(tile, key)

# Subtle top highlight on the tile.
hl = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(hl).rounded_rectangle(tile_box, radius=tile_radius, outline=(255, 255, 255, 38), width=4 * SS)
tile = Image.alpha_composite(tile, hl)

canvas.paste(tile, (0, 0), tile_mask)
# Drop shadow for the tile, as macOS icons have.
drop = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(drop).rounded_rectangle([tile_box[0], tile_box[1] + 14 * SS, tile_box[2], tile_box[3] + 14 * SS], radius=tile_radius, fill=(0, 0, 0, 110))
drop = drop.filter(ImageFilter.GaussianBlur(18 * SS))
final = Image.alpha_composite(drop, canvas).resize((S, S), Image.LANCZOS)
final.save("icon_1024.png")
final.save("../AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("ok")
