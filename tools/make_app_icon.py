"""角色相册 App 图标：渐变底 + 叠放的三张圆角照片卡，最前一张照片里是动漫角色的半身像
（长发、刘海、呆毛、大眼睛 —— 一眼看出是「角色」的相册），旁边一颗星光点缀。
用法：python3 tools/make_app_icon.py AnimeAlbum/Assets.xcassets/AppIcon.appiconset  —— 生成 AppIcon.png / AppIcon-Dark.png / AppIcon-Tinted.png（1024px）
"""
import math
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4096  # 4 倍超采样，最后缩到 1024
OUT = 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def diagonal_gradient(size, top_left, bottom_right):
    """左上 → 右下的线性渐变"""
    w, h = size
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            px[x, y] = lerp(top_left, bottom_right, t)
    return small.resize(size, Image.BICUBIC)


def vertical_gradient(size, top, bottom):
    w, h = size
    small = Image.new("RGB", (1, 256))
    for y in range(256):
        small.putpixel((0, y), lerp(top, bottom, y / 255))
    return small.resize(size, Image.BICUBIC)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def sparkle(draw, cx, cy, r, fill, waist=0.30):
    """四角星光：四个尖角 + 细腰（waist 为腰宽 / 半径）"""
    pts = []
    for i in range(16):
        angle = math.pi / 2 * (i / 4) - math.pi / 2
        # 尖角处半径 r，两尖角之间的凹处半径 r*waist，用多点逼近内凹曲线
        phase = (i % 4) / 4
        radius = r if phase == 0 else r * waist / (0.35 + 0.65 * math.sin(math.pi * phase))
        pts.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    draw.polygon(pts, fill=fill)


def card_layer(card_w, card_h, radius, face, alpha=255):
    """一张照片卡（含白边相框时由调用方往里画内容）"""
    layer = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
    mask = rounded_mask((card_w, card_h), radius)
    fill = Image.new("RGBA", (card_w, card_h), face + (alpha,))
    layer.paste(fill, (0, 0), mask)
    return layer


def paste_rotated(canvas, layer, center, angle, shadow=None):
    rotated = layer.rotate(angle, resample=Image.BICUBIC, expand=True)
    x = int(center[0] - rotated.width / 2)
    y = int(center[1] - rotated.height / 2)
    if shadow:
        offset, blur, opacity = shadow
        # 四周留出 3 倍模糊半径的余量再模糊，否则阴影被小画布边缘截成生硬的矩形
        pad = int(blur * 3)
        alpha = Image.new("L", (rotated.width + pad * 2, rotated.height + pad * 2), 0)
        alpha.paste(rotated.split()[3].point(lambda a: int(a * opacity)), (pad, pad))
        alpha = alpha.filter(ImageFilter.GaussianBlur(blur))
        sh = Image.new("RGBA", alpha.size, (40, 20, 80, 0))
        sh.putalpha(alpha)
        canvas.alpha_composite(sh, (x - pad, y - pad + offset))
    canvas.alpha_composite(rotated, (x, y))


def draw_character(photo, dark, tinted=False):
    """照片里的角色半身像：后发 → 肩膀 → 脖子 → 脸 → 刘海 → 呆毛 → 眼睛 / 腮红"""
    pw, ph = photo.size
    d = ImageDraw.Draw(photo)
    X = lambda v: pw * v
    Y = lambda v: ph * v
    if tinted:
        # 染色版：系统按亮度着色，主体要亮 —— 头发用浅色，不然转灰度后是一块黑
        hair, hair_shade = (214, 206, 246), (188, 178, 232)
        skin, cloth, collar = (255, 250, 248), (255, 255, 255), (236, 230, 255)
        eye, blush = (90, 70, 160), (255, 214, 226)
    elif dark:
        hair, hair_shade = (150, 128, 236), (118, 98, 206)
        skin, cloth, collar = (255, 236, 226), (214, 204, 246), (250, 246, 255)
        eye, blush = (70, 52, 140), (255, 168, 190)
    else:
        hair, hair_shade = (126, 98, 226), (98, 74, 196)
        skin, cloth, collar = (255, 240, 232), (255, 255, 255), (232, 222, 255)
        eye, blush = (64, 44, 140), (255, 160, 186)

    # 后发：披到肩下的长发
    d.rounded_rectangle((X(0.22), Y(0.24), X(0.78), Y(0.98)), radius=X(0.22), fill=hair_shade)
    # 肩膀 / 上身（被照片下沿截掉）
    d.rounded_rectangle((X(0.12), Y(0.78), X(0.88), Y(1.40)), radius=X(0.22), fill=cloth)
    # 领口：小三角
    d.polygon([(X(0.40), Y(0.78)), (X(0.60), Y(0.78)), (X(0.50), Y(0.90))], fill=collar)
    # 脖子
    d.rectangle((X(0.445), Y(0.64), X(0.555), Y(0.80)), fill=skin)
    # 脸
    d.ellipse((X(0.30), Y(0.30), X(0.70), Y(0.72)), fill=skin)
    # 刘海：头顶发帽 + 锯齿发梢
    d.ellipse((X(0.27), Y(0.20), X(0.73), Y(0.58)), fill=hair)
    fringe = [(X(0.27), Y(0.40))]
    tips = [0.27, 0.35, 0.43, 0.51, 0.59, 0.67, 0.73]
    for i in range(len(tips) - 1):
        a, b = tips[i], tips[i + 1]
        fringe.append((X((a + b) / 2), Y(0.50 if i % 2 == 0 else 0.47)))
        fringe.append((X(b), Y(0.40)))
    fringe += [(X(0.73), Y(0.36)), (X(0.27), Y(0.36))]
    d.polygon(fringe, fill=hair)
    # 两侧垂下的鬓发
    d.rounded_rectangle((X(0.25), Y(0.36), X(0.34), Y(0.78)), radius=X(0.045), fill=hair)
    d.rounded_rectangle((X(0.66), Y(0.36), X(0.75), Y(0.78)), radius=X(0.045), fill=hair)
    # 呆毛：头顶一撮弯弯的头发（月牙形）
    ahoge = []
    for i in range(13):
        t = i / 12
        ahoge.append((X(0.50 + 0.10 * t), Y(0.215 - 0.12 * math.sin(math.pi * t * 0.9))))
    for i in range(13):
        t = 1 - i / 12
        ahoge.append((X(0.52 + 0.08 * t), Y(0.215 - 0.085 * math.sin(math.pi * t * 0.9))))
    d.polygon(ahoge, fill=hair)
    # 大眼睛 + 高光
    for ex in (0.415, 0.585):
        d.ellipse((X(ex - 0.035), Y(0.525), X(ex + 0.035), Y(0.615)), fill=eye)
        d.ellipse((X(ex - 0.012), Y(0.535), X(ex + 0.010), Y(0.565)), fill=(255, 255, 255))
    # 腮红
    for bx in (0.375, 0.625):
        d.ellipse((X(bx - 0.035), Y(0.635), X(bx + 0.035), Y(0.665)), fill=blush)


def make_icon(dark=False, tinted=False):
    if dark:
        bg = diagonal_gradient((S, S), (58, 40, 84), (24, 22, 46))
        back_face, back_alpha = (255, 255, 255), 46
        frame_face = (236, 232, 248)
        sky_top, sky_bottom = (96, 120, 220), (176, 132, 236)
    else:
        bg = diagonal_gradient((S, S), (255, 154, 190), (142, 124, 255))
        back_face, back_alpha = (255, 255, 255), 90
        frame_face = (255, 255, 255)
        sky_top, sky_bottom = (120, 196, 255), (198, 168, 255)

    canvas = bg.convert("RGBA")
    cx, cy = S / 2, S * 0.53
    card_w, card_h = int(S * 0.50), int(S * 0.58)
    radius = int(S * 0.055)

    # 后面两张：左倾 / 右倾、半透明，像相册里叠着的照片
    back = card_layer(card_w, card_h, radius, back_face, back_alpha)
    paste_rotated(canvas, back, (cx - S * 0.075, cy - S * 0.02), 13, shadow=(int(S * 0.012), S * 0.02, 0.10))
    paste_rotated(canvas, back, (cx + S * 0.075, cy - S * 0.03), -10, shadow=(int(S * 0.012), S * 0.02, 0.10))

    # 最前一张：白边相框 + 天空 + 星光
    front = card_layer(card_w, card_h, radius, frame_face)
    inset = int(S * 0.028)
    photo_w, photo_h = card_w - inset * 2, int(card_h * 0.78)
    photo = vertical_gradient((photo_w, photo_h), sky_top, sky_bottom).convert("RGBA")
    draw_character(photo, dark, tinted)
    d = ImageDraw.Draw(photo)
    # 星光点缀：左上一大、右上一小
    star = (255, 255, 255) if not dark else (255, 246, 214)
    sparkle(d, photo_w * 0.15, photo_h * 0.17, photo_w * 0.085, star)
    sparkle(d, photo_w * 0.86, photo_h * 0.30, photo_w * 0.05, star)
    photo_mask = rounded_mask((photo_w, photo_h), int(radius * 0.6))
    front.paste(photo, (inset, inset), photo_mask)
    # 相框下沿留白处的一行「标题」短线（拍立得的书写区）
    fd = ImageDraw.Draw(front)
    line_y = inset + photo_h + int((card_h - inset - photo_h) * 0.42)
    line_color = (226, 214, 255) if not dark else (180, 170, 214)
    fd.rounded_rectangle(
        (inset + photo_w * 0.08, line_y, inset + photo_w * 0.46, line_y + S * 0.018),
        radius=int(S * 0.009), fill=line_color)
    paste_rotated(canvas, front, (cx, cy + S * 0.01), -3, shadow=(int(S * 0.02), S * 0.03, 0.22))

    return canvas.convert("RGB").resize((OUT, OUT), Image.LANCZOS)


def make_tinted(light_icon):
    """染色变体：灰度图，系统按用户选的色调着色"""
    gray = light_icon.convert("L")
    # 拉开对比：背景压暗、卡片与星光保持亮
    gray = gray.point(lambda v: int(max(0, min(255, (v - 110) * 1.6))))
    return Image.merge("RGB", (gray, gray, gray))


if __name__ == "__main__":
    out = sys.argv[1]
    light = make_icon(dark=False)
    light.save(f"{out}/AppIcon.png")
    make_icon(dark=True).save(f"{out}/AppIcon-Dark.png")
    make_tinted(make_icon(tinted=True)).save(f"{out}/AppIcon-Tinted.png")
    print("done")
