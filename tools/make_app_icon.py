"""拾匣（Keepbox）App 图标：渐变底 + 一只盒子，盒里竖着露出三张卡片 —— PDF 页、视频（播放键）、照片（山与太阳），
盒子正面一个锁孔（隐藏 / 私密）。
用法：python3 tools/make_app_icon.py AnimeAlbum/Assets.xcassets/AppIcon.appiconset
     —— 生成 AppIcon.png / AppIcon-Dark.png / AppIcon-Tinted.png（1024px）
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4096  # 4 倍超采样，最后缩到 1024
OUT = 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def diagonal_gradient(size, top_left, bottom_right):
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            px[x, y] = lerp(top_left, bottom_right, (x + y) / 510)
    return small.resize(size, Image.BICUBIC)


def vertical_gradient(size, top, bottom):
    small = Image.new("RGB", (1, 256))
    for y in range(256):
        small.putpixel((0, y), lerp(top, bottom, y / 255))
    return small.resize(size, Image.BICUBIC)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def shadow_for(layer, blur, opacity, color=(20, 16, 60)):
    pad = int(blur * 3)
    alpha = Image.new("L", (layer.width + pad * 2, layer.height + pad * 2), 0)
    alpha.paste(layer.split()[3].point(lambda a: int(a * opacity)), (pad, pad))
    alpha = alpha.filter(ImageFilter.GaussianBlur(blur))
    shadow = Image.new("RGBA", alpha.size, color + (0,))
    shadow.putalpha(alpha)
    return shadow, pad


def paste_rotated(canvas, layer, center, angle, shadow=None):
    rotated = layer.rotate(angle, resample=Image.BICUBIC, expand=True)
    x = int(center[0] - rotated.width / 2)
    y = int(center[1] - rotated.height / 2)
    if shadow:
        offset, blur, opacity = shadow
        sh, pad = shadow_for(rotated, blur, opacity)
        canvas.alpha_composite(sh, (x - pad, y - pad + offset))
    canvas.alpha_composite(rotated, (x, y))


def card(w, h, radius, fill):
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    layer.paste(Image.new("RGBA", (w, h), fill + (255,)), (0, 0), rounded_mask((w, h), radius))
    return layer


def pdf_card(w, h, radius, palette):
    layer = card(w, h, radius, palette["paper"])
    d = ImageDraw.Draw(layer)
    margin = w * 0.14
    # 标题条 + 正文行
    d.rounded_rectangle((margin, h * 0.12, w * 0.62, h * 0.12 + w * 0.07), radius=w * 0.035, fill=palette["accent"])
    for i in range(6):
        y = h * 0.27 + i * h * 0.085
        right = w - margin if i % 3 != 2 else w * 0.6
        d.rounded_rectangle((margin, y, right, y + w * 0.045), radius=w * 0.022, fill=palette["line"])
    return layer


def video_card(w, h, radius, palette):
    layer = card(w, h, radius, palette["video"])
    d = ImageDraw.Draw(layer)
    cx, cy, r = w / 2, h * 0.42, w * 0.2
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 235))
    tri = r * 0.55
    d.polygon([(cx - tri * 0.55, cy - tri), (cx - tri * 0.55, cy + tri), (cx + tri * 0.95, cy)],
              fill=palette["video"])
    # 进度条
    d.rounded_rectangle((w * 0.14, h * 0.8, w * 0.86, h * 0.8 + w * 0.035), radius=w * 0.018,
                        fill=(255, 255, 255, 90))
    d.rounded_rectangle((w * 0.14, h * 0.8, w * 0.48, h * 0.8 + w * 0.035), radius=w * 0.018,
                        fill=(255, 255, 255, 230))
    return layer


def photo_card(w, h, radius, palette):
    inset = int(w * 0.06)
    layer = card(w, h, radius, palette["frame"])
    pw, ph = w - inset * 2, h - inset * 2
    photo = vertical_gradient((pw, ph), palette["sky_top"], palette["sky_bottom"]).convert("RGBA")
    d = ImageDraw.Draw(photo)
    # 太阳
    sr = pw * 0.13
    d.ellipse((pw * 0.66 - sr, ph * 0.26 - sr, pw * 0.66 + sr, ph * 0.26 + sr), fill=palette["sun"])
    # 远山、近山
    d.polygon([(0, ph * 0.78), (pw * 0.3, ph * 0.48), (pw * 0.55, ph * 0.7), (pw * 0.75, ph * 0.56),
               (pw, ph * 0.74), (pw, ph), (0, ph)], fill=palette["hill_far"])
    d.polygon([(0, ph * 0.9), (pw * 0.4, ph * 0.66), (pw * 0.8, ph * 0.92), (pw, ph * 0.84), (pw, ph), (0, ph)],
              fill=palette["hill_near"])
    layer.paste(photo, (inset, inset), rounded_mask((pw, ph), int(radius * 0.7)))
    return layer


def box_front(w, h, palette):
    """盒子正面：上沿一道高光，中间锁孔"""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    radius = int(w * 0.12)
    body = vertical_gradient((w, h), palette["box_top"], palette["box_bottom"]).convert("RGBA")
    layer.paste(body, (0, 0), rounded_mask((w, h), radius))
    d = ImageDraw.Draw(layer)
    # 盒沿
    d.rounded_rectangle((0, 0, w - 1, h * 0.16), radius=radius, fill=palette["rim"])
    # 锁孔：圆 + 下窄上宽的槽
    cx, cy, r = w / 2, h * 0.53, w * 0.07
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=palette["keyhole"])
    d.polygon([(cx - r * 0.45, cy), (cx + r * 0.45, cy), (cx + r * 0.75, cy + r * 2.3), (cx - r * 0.75, cy + r * 2.3)],
              fill=palette["keyhole"])
    return layer


PALETTES = {
    "light": {
        "bg": ((86, 190, 255), (102, 84, 236)),
        "paper": (255, 255, 255), "accent": (255, 120, 120), "line": (214, 220, 236),
        "video": (40, 44, 72),
        "frame": (255, 255, 255), "sky_top": (120, 200, 255), "sky_bottom": (255, 214, 170),
        "sun": (255, 246, 210), "hill_far": (120, 176, 140), "hill_near": (70, 140, 110),
        "box_top": (255, 255, 255), "box_bottom": (232, 236, 252), "rim": (246, 248, 255),
        "keyhole": (102, 96, 200),
    },
    "dark": {
        "bg": ((28, 52, 96), (30, 22, 70)),
        "paper": (232, 236, 246), "accent": (236, 104, 112), "line": (190, 198, 218),
        "video": (24, 26, 44),
        "frame": (236, 238, 248), "sky_top": (84, 150, 230), "sky_bottom": (230, 170, 140),
        "sun": (255, 236, 196), "hill_far": (96, 150, 122), "hill_near": (56, 116, 92),
        "box_top": (70, 78, 120), "box_bottom": (48, 52, 92), "rim": (90, 98, 146),
        "keyhole": (182, 176, 255),
    },
}


def make_icon(variant):
    p = dict(PALETTES["dark" if variant == "dark" else "light"])
    if variant == "tinted":
        # 染色版黑底：视频卡调成中灰，不然转灰度后和黑底融在一起
        p["video"] = (110, 112, 128)
    canvas = diagonal_gradient((S, S), *p["bg"]).convert("RGBA")
    if variant == "tinted":
        canvas = Image.new("RGBA", (S, S), (0, 0, 0, 255))

    card_w, card_h = int(S * 0.30), int(S * 0.40)
    radius = int(S * 0.04)
    base_y = S * 0.44
    paste_rotated(canvas, pdf_card(card_w, card_h, radius, p), (S * 0.33, base_y + S * 0.02), 14,
                  shadow=(int(S * 0.01), S * 0.02, 0.25))
    paste_rotated(canvas, video_card(card_w, card_h, radius, p), (S * 0.5, base_y - S * 0.03), 0,
                  shadow=(int(S * 0.012), S * 0.022, 0.28))
    paste_rotated(canvas, photo_card(card_w, card_h, radius, p), (S * 0.67, base_y + S * 0.02), -14,
                  shadow=(int(S * 0.012), S * 0.022, 0.28))

    box_w, box_h = int(S * 0.66), int(S * 0.3)
    front = box_front(box_w, box_h, p)
    sh, pad = shadow_for(front, S * 0.03, 0.35)
    bx, by = int((S - box_w) / 2), int(S * 0.56)
    canvas.alpha_composite(sh, (bx - pad, by - pad + int(S * 0.02)))
    canvas.alpha_composite(front, (bx, by))
    return canvas.convert("RGB").resize((OUT, OUT), Image.LANCZOS)


def make_tinted():
    """染色变体：灰度图（系统按用户选的色调着色）—— 主体亮、底色暗"""
    gray = make_icon("tinted").convert("L")
    return Image.merge("RGB", (gray, gray, gray))


if __name__ == "__main__":
    out = sys.argv[1]
    make_icon("light").save(f"{out}/AppIcon.png")
    make_icon("dark").save(f"{out}/AppIcon-Dark.png")
    make_tinted().save(f"{out}/AppIcon-Tinted.png")
    print("done")
