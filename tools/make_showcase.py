"""App Store 展示图用的示例内容（全部程序生成，不含任何真实照片）：风景 / 抽象插画、一段延时视频、一份 PDF 手账。
按相簿分文件夹（数字前缀定顺序；H- 开头的相簿导入后标为隐藏；hidden- 开头的文件标为隐藏照片），
由调试开关 SEED_SHOWCASE=<目录> 导入（见 DebugSeeder）。
用法：python3 tools/make_showcase.py <输出目录>
"""
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

def find_font():
    """苹方（简体常规 3 / 中粗 11）在系统字体资源里；找不到就用冬青黑体（常规 0 / 粗 2）"""
    import glob
    hits = glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc")
    if hits:
        return hits[0], 3, 11
    return "/System/Library/Fonts/Hiragino Sans GB.ttc", 0, 2


FONT, FONT_REGULAR, FONT_BOLD = find_font()


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient(size, stops):
    """竖向多段渐变：stops = [(位置 0~1, 颜色), …]"""
    w, h = size
    strip = Image.new("RGB", (1, 512))
    for y in range(512):
        t = y / 511
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                strip.putpixel((0, y), lerp(c0, c1, (t - p0) / max(p1 - p0, 1e-6)))
                break
    return strip.resize((w, h), Image.BICUBIC)


def ridge(rng, w, base, amp, roughness=6):
    """山脊线：几段正弦叠加 + 随机扰动"""
    phases = [rng.uniform(0, math.tau) for _ in range(roughness)]
    freqs = [rng.uniform(0.6, 1.4) * (i + 1) for i in range(roughness)]
    pts = []
    for x in range(0, w + 8, 8):
        u = x / w
        y = base
        for i in range(roughness):
            y -= amp / (i + 1) * math.sin(u * math.tau * freqs[i] / 2 + phases[i])
        pts.append((x, y))
    return pts


def glow(img, center, radius, color, strength=0.7):
    layer = Image.new("RGB", img.size, (0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse((center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius), fill=color)
    layer = layer.filter(ImageFilter.GaussianBlur(radius * 0.9))
    return Image.blend(img, Image.composite(layer, img, layer.convert("L")), strength)


def mountains(rng, size, sky, sun, layers, sun_pos=(0.68, 0.38)):
    w, h = size
    img = gradient(size, sky)
    sx, sy = w * sun_pos[0], h * sun_pos[1]
    img = glow(img, (sx, sy), w * 0.22, sun[1], 0.55)
    d = ImageDraw.Draw(img)
    r = w * 0.06
    d.ellipse((sx - r, sy - r, sx + r, sy + r), fill=sun[0])
    for i, color in enumerate(layers):
        base = h * (0.5 + i * 0.11)
        pts = ridge(rng, w, base, h * (0.12 - i * 0.015))
        d.polygon(pts + [(w, h), (0, h)], fill=color)
    return img


def ocean(rng, size, sky, sea, sun):
    w, h = size
    img = gradient(size, sky)
    horizon = h * 0.55
    d = ImageDraw.Draw(img)
    sea_img = gradient((w, int(h - horizon)), sea)
    img.paste(sea_img, (0, int(horizon)))
    img = glow(img, (w * 0.5, horizon - h * 0.04), w * 0.25, sun, 0.5)
    d = ImageDraw.Draw(img)
    r = w * 0.07
    d.ellipse((w * 0.5 - r, horizon - h * 0.04 - r, w * 0.5 + r, horizon - h * 0.04 + r), fill=sun)
    d.rectangle((0, horizon, w, h), fill=None)
    img.paste(sea_img.crop((0, 0, w, 6)), (0, int(horizon)))
    # 太阳在海面上的倒影条纹
    for i in range(40):
        y = horizon + 8 + i * (h - horizon) / 42
        half = w * 0.12 * (1 - i / 50) * rng.uniform(0.5, 1.1)
        d.rounded_rectangle((w * 0.5 - half, y, w * 0.5 + half, y + 5), radius=3, fill=lerp(sun, sea[0][1], i / 45))
    # 浪线
    for i in range(18):
        y = horizon + (h - horizon) * (i + 1) / 19
        x0 = rng.uniform(0, w * 0.7)
        d.line((x0, y, x0 + rng.uniform(w * 0.1, w * 0.3), y), fill=lerp(sea[-1][1], (255, 255, 255), 0.25), width=3)
    return img


def night(rng, size):
    w, h = size
    img = gradient(size, [(0, (8, 12, 40)), (0.6, (30, 40, 100)), (1, (60, 50, 120))])
    d = ImageDraw.Draw(img)
    for _ in range(420):
        x, y, s = rng.uniform(0, w), rng.uniform(0, h * 0.7), rng.choice([1, 1, 1, 2, 2, 3])
        b = rng.randint(160, 255)
        d.ellipse((x, y, x + s, y + s), fill=(b, b, min(255, b + 20)))
    # 极光
    aurora = Image.new("RGB", size, (0, 0, 0))
    ad = ImageDraw.Draw(aurora)
    for i in range(3):
        pts = [(x, h * (0.25 + i * 0.07) + math.sin(x / w * math.tau * 1.3 + i) * h * 0.06) for x in range(0, w + 10, 10)]
        ad.line(pts, fill=[(60, 255, 170), (80, 200, 255), (170, 120, 255)][i], width=int(h * 0.05))
    aurora = aurora.filter(ImageFilter.GaussianBlur(h * 0.035))
    img = Image.blend(img, Image.composite(aurora, img, aurora.convert("L")), 0.65)
    d = ImageDraw.Draw(img)
    # 月亮
    mx, my, mr = w * 0.78, h * 0.15, w * 0.05
    d.ellipse((mx - mr, my - mr, mx + mr, my + mr), fill=(250, 246, 225))
    pts = ridge(rng, w, h * 0.78, h * 0.08)
    d.polygon(pts + [(w, h), (0, h)], fill=(12, 14, 30))
    return img


def forest(rng, size, palette):
    w, h = size
    img = gradient(size, palette["sky"])
    d = ImageDraw.Draw(img)
    for layer, color in enumerate(palette["trees"]):
        base = h * (0.55 + layer * 0.13)
        x = -40
        while x < w + 40:
            th = h * rng.uniform(0.18, 0.3) * (1 + layer * 0.25)
            tw = th * 0.38
            d.polygon([(x, base - th), (x - tw / 2, base), (x + tw / 2, base)], fill=color)
            x += tw * rng.uniform(0.45, 0.8)
        d.rectangle((0, base, w, h), fill=color)
        # 雾
        fog = Image.new("RGB", size, palette["fog"])
        mask = Image.new("L", size, 0)
        ImageDraw.Draw(mask).rectangle((0, base - h * 0.05, w, base + h * 0.04), fill=70)
        img = Image.composite(fog, img, mask.filter(ImageFilter.GaussianBlur(h * 0.03)))
        d = ImageDraw.Draw(img)
    return img


def dunes(rng, size, palette):
    w, h = size
    img = gradient(size, palette["sky"])
    img = glow(img, (w * 0.3, h * 0.3), w * 0.2, palette["sun"], 0.6)
    d = ImageDraw.Draw(img)
    for i, color in enumerate(palette["sand"]):
        base = h * (0.55 + i * 0.12)
        pts = [(x, base - math.sin(x / w * math.pi * (1.2 + i * 0.4) + i) * h * 0.07) for x in range(0, w + 10, 10)]
        d.polygon(pts + [(w, h), (0, h)], fill=color)
    return img


def lake(rng, size, palette):
    w, h = size
    top = mountains(rng, (w, h // 2), palette["sky"], palette["sun"], palette["hills"], sun_pos=(0.3, 0.55))
    img = Image.new("RGB", size)
    img.paste(top, (0, 0))
    reflection = top.transpose(Image.FLIP_TOP_BOTTOM).filter(ImageFilter.GaussianBlur(4))
    reflection = Image.blend(reflection, Image.new("RGB", reflection.size, palette["water"]), 0.35)
    img.paste(reflection, (0, h // 2))
    d = ImageDraw.Draw(img)
    for i in range(30):
        y = h // 2 + rng.uniform(10, h / 2)
        x0 = rng.uniform(0, w * 0.8)
        d.line((x0, y, x0 + rng.uniform(40, 200), y), fill=lerp(palette["water"], (255, 255, 255), 0.3), width=2)
    return img


def city(rng, size):
    w, h = size
    img = gradient(size, [(0, (40, 30, 90)), (0.5, (220, 110, 120)), (1, (255, 190, 140))])
    d = ImageDraw.Draw(img)
    for layer, color in enumerate([(70, 50, 100), (40, 28, 70), (20, 16, 40)]):
        x = 0
        while x < w:
            bw = rng.uniform(w * 0.06, w * 0.14)
            bh = h * rng.uniform(0.18, 0.45) * (1 + layer * 0.15)
            top = h - bh
            d.rectangle((x, top, x + bw, h), fill=color)
            if layer == 2:
                for wy in range(int(top + 20), h - 20, 28):
                    for wx in range(int(x + 10), int(x + bw - 10), 22):
                        if rng.random() < 0.45:
                            d.rectangle((wx, wy, wx + 10, wy + 14), fill=(255, 214, 140))
            x += bw + rng.uniform(4, 20)
    return img


def abstract(rng, size, colors):
    w, h = size
    img = Image.new("RGB", size, colors[0])
    blobs = Image.new("RGB", size, colors[0])
    d = ImageDraw.Draw(blobs)
    for i in range(7):
        r = rng.uniform(w * 0.2, w * 0.45)
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        d.ellipse((x - r, y - r, x + r, y + r), fill=colors[1 + i % (len(colors) - 1)])
    img = blobs.filter(ImageFilter.GaussianBlur(w * 0.12))
    d = ImageDraw.Draw(img)
    # 一点几何线条
    for i in range(3):
        r = rng.uniform(w * 0.1, w * 0.3)
        x, y = rng.uniform(w * 0.2, w * 0.8), rng.uniform(h * 0.2, h * 0.8)
        d.ellipse((x - r, y - r, x + r, y + r), outline=(255, 255, 255), width=max(3, w // 300))
    # 颗粒
    noise = Image.effect_noise(size, 18).convert("RGB")
    return Image.blend(img, noise, 0.06)


PORTRAIT, LANDSCAPE, SQUARE = (1500, 2000), (2000, 1500), (1700, 1700)

SUNSET = dict(sky=[(0, (60, 40, 120)), (0.45, (240, 120, 110)), (1, (255, 200, 140))], sun=((255, 236, 200), (255, 170, 110)),
              layers=[(170, 90, 120), (120, 60, 110), (70, 40, 90)])
DAWN = dict(sky=[(0, (120, 170, 230)), (0.6, (250, 200, 190)), (1, (255, 230, 200))], sun=((255, 250, 230), (255, 220, 180)),
            layers=[(150, 160, 200), (100, 120, 170), (60, 80, 130)])
ALPINE = dict(sky=[(0, (90, 160, 230)), (1, (200, 230, 250))], sun=((255, 255, 240), (255, 250, 220)),
              layers=[(170, 190, 210), (100, 140, 120), (50, 100, 80)])


def scenes(rng):
    return {
        "1-旅行": [
            ("sunset-ridge.jpg", lambda: mountains(rng, PORTRAIT, SUNSET["sky"], SUNSET["sun"], SUNSET["layers"])),
            ("seaside.jpg", lambda: ocean(rng, LANDSCAPE, [(0, (90, 120, 200)), (1, (250, 190, 160))],
                                          [(0, (60, 90, 150)), (1, (20, 40, 80))], (255, 220, 170))),
            ("city-dusk.jpg", lambda: city(rng, PORTRAIT)),
            ("lake.jpg", lambda: lake(rng, PORTRAIT, dict(sky=DAWN["sky"], sun=DAWN["sun"], hills=DAWN["layers"],
                                                         water=(120, 150, 200)))),
            ("dunes.jpg", lambda: dunes(rng, LANDSCAPE, dict(sky=[(0, (120, 170, 230)), (1, (255, 220, 180))],
                                                            sun=(255, 240, 200),
                                                            sand=[(230, 170, 110), (210, 140, 90), (180, 110, 70)]))),
            ("alpine.jpg", lambda: mountains(rng, SQUARE, ALPINE["sky"], ALPINE["sun"], ALPINE["layers"], (0.25, 0.25))),
        ],
        "2-风景": [
            ("aurora.jpg", lambda: night(rng, PORTRAIT)),
            ("forest-mist.jpg", lambda: forest(rng, PORTRAIT, dict(sky=[(0, (200, 220, 230)), (1, (240, 240, 235))],
                                                                  trees=[(120, 150, 140), (70, 110, 95), (30, 70, 60)],
                                                                  fog=(230, 235, 235)))),
            ("dawn-hills.jpg", lambda: mountains(rng, LANDSCAPE, DAWN["sky"], DAWN["sun"], DAWN["layers"], (0.5, 0.42))),
            ("hidden-evening-sea.jpg", lambda: ocean(rng, SQUARE, [(0, (40, 40, 100)), (1, (240, 130, 120))],
                                                     [(0, (50, 50, 110)), (1, (20, 20, 60))], (255, 190, 150))),
            ("autumn-forest.jpg", lambda: forest(rng, LANDSCAPE, dict(sky=[(0, (250, 210, 160)), (1, (255, 240, 210))],
                                                                     trees=[(220, 140, 90), (180, 90, 60), (110, 50, 40)],
                                                                     fog=(255, 235, 210)))),
            ("night-ridge.jpg", lambda: night(rng, SQUARE)),
            ("violet-peaks.jpg", lambda: mountains(rng, PORTRAIT, [(0, (40, 30, 80)), (1, (200, 120, 200))],
                                                   ((255, 230, 250), (240, 160, 230)),
                                                   [(150, 90, 170), (100, 60, 140), (60, 40, 100)], (0.35, 0.3))),
            ("calm-lake.jpg", lambda: lake(rng, LANDSCAPE, dict(sky=ALPINE["sky"], sun=ALPINE["sun"],
                                                                 hills=ALPINE["layers"], water=(90, 140, 170)))),
        ],
        "3-插画": [
            (f"art-{i + 1}.jpg", (lambda c=c, s=s: lambda: abstract(rng, s, c))())
            for i, (c, s) in enumerate([
                ([(255, 240, 230), (255, 140, 120), (255, 200, 90), (140, 120, 255)], SQUARE),
                ([(20, 24, 60), (80, 120, 255), (200, 90, 255), (60, 220, 200)], PORTRAIT),
                ([(240, 250, 240), (120, 220, 170), (80, 170, 240), (250, 220, 120)], SQUARE),
                ([(30, 20, 40), (255, 90, 120), (255, 170, 60), (120, 60, 200)], LANDSCAPE),
                ([(250, 244, 255), (190, 160, 255), (255, 170, 210), (130, 210, 255)], PORTRAIT),
                ([(10, 30, 40), (40, 200, 180), (240, 240, 120), (40, 120, 240)], SQUARE),
            ])
        ],
        "H-私密": [
            ("diary-1.jpg", lambda: abstract(rng, PORTRAIT, [(250, 236, 230), (240, 150, 160), (250, 210, 170), (200, 170, 240)])),
            ("diary-2.jpg", lambda: abstract(rng, SQUARE, [(236, 240, 255), (150, 180, 255), (200, 160, 255), (160, 230, 240)])),
            ("diary-3.jpg", lambda: mountains(rng, PORTRAIT, SUNSET["sky"], SUNSET["sun"], SUNSET["layers"], (0.3, 0.3))),
        ],
    }


def timelapse(rng, path):
    """日出延时：太阳从山后升起、天色由暗转亮（6s，30fps，1920x1080）"""
    frames_dir = tempfile.mkdtemp()
    w, h = 1280, 720
    fixed = random.Random(7)
    layers = [(150, 160, 200), (100, 120, 170), (60, 80, 130)]
    ridges = [ridge(fixed, w, h * (0.55 + i * 0.12), h * (0.12 - i * 0.02)) for i in range(3)]
    for f in range(150):
        t = f / 149
        sky = [(0, lerp((20, 30, 80), (110, 170, 235), t)), (0.6, lerp((120, 70, 120), (250, 205, 185), t)),
               (1, lerp((200, 120, 110), (255, 232, 205), t))]
        img = gradient((w, h), sky)
        sx, sy = w * 0.55, h * (0.75 - 0.45 * t)
        img = glow(img, (sx, sy), w * 0.2, (255, 200, 150), 0.55)
        d = ImageDraw.Draw(img)
        r = w * 0.045
        d.ellipse((sx - r, sy - r, sx + r, sy + r), fill=(255, 245, 220))
        for pts, color in zip(ridges, layers):
            d.polygon(pts + [(w, h), (0, h)], fill=lerp((20, 20, 50), color, min(1, t * 1.3)))
        img.save(os.path.join(frames_dir, f"{f:04d}.jpg"), quality=92)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "25", "-i", os.path.join(frames_dir, "%04d.jpg"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", path], check=True)
    shutil.rmtree(frames_dir)


def journal_pdf(rng, path, cover):
    """三页旅行手账（整页图片 PDF）"""
    W, H = 1240, 1754
    title_font = ImageFont.truetype(FONT, 72, index=FONT_BOLD)
    head_font = ImageFont.truetype(FONT, 44, index=FONT_BOLD)
    body_font = ImageFont.truetype(FONT, 32, index=FONT_REGULAR)
    pages = []
    texts = [
        ("海边的三天", "第一天", "清晨出发，沿着海岸线一路向南。中午在小镇的面馆吃了一碗鱼丸面，傍晚到达民宿，"
                            "推开窗就是海。日落的时候天空从橘色慢慢变成紫色，海面上有一条金色的路。"),
        ("", "第二天", "去了灯塔和旧码头，拍了很多照片。下午下了一场雨，躲在咖啡店里写明信片。"
                     "雨停后空气特别清新，远处的山被雾笼罩着，像一幅水墨画。"),
        ("", "第三天", "最后一天起得很早，在沙滩上等日出。回程的路上把这几天的照片整理进了相簿，"
                     "挑了几张最喜欢的设成封面。下次想在秋天再来一次。"),
    ]
    for i, (title, head, body) in enumerate(texts):
        page = Image.new("RGB", (W, H), (252, 250, 245))
        d = ImageDraw.Draw(page)
        y = 140
        if title:
            d.text((110, y), title, font=title_font, fill=(40, 40, 50))
            y += 120
            d.line((110, y, 400, y), fill=(240, 130, 110), width=6)
            y += 60
        photo = cover[i].copy()
        photo.thumbnail((W - 220, 760))
        page.paste(photo, ((W - photo.width) // 2, y))
        y += photo.height + 70
        d.text((110, y), head, font=head_font, fill=(240, 120, 100))
        y += 80
        line = ""
        for ch in body:
            if d.textlength(line + ch, font=body_font) > W - 220:
                d.text((110, y), line, font=body_font, fill=(80, 80, 90))
                y += 56
                line = ""
            line += ch
        d.text((110, y), line, font=body_font, fill=(80, 80, 90))
        d.text((W - 200, H - 120), f"— {i + 1} —", font=body_font, fill=(170, 170, 170))
        pages.append(page)
    pages[0].save(path, save_all=True, append_images=pages[1:], resolution=150)


def random_palette(rng):
    """随机一套天色 / 山色"""
    hue = rng.random()
    import colorsys
    def c(h, s, v):
        r, g, b = colorsys.hsv_to_rgb(h % 1, s, v)
        return (int(r * 255), int(g * 255), int(b * 255))
    sky = [(0, c(hue, 0.55, 0.55)), (0.55, c(hue + 0.08, 0.45, 0.95)), (1, c(hue + 0.15, 0.3, 1))]
    sun = (c(hue + 0.12, 0.15, 1), c(hue + 0.1, 0.45, 1))
    layers = [c(hue - 0.05, 0.35, 0.7), c(hue - 0.08, 0.45, 0.5), c(hue - 0.1, 0.55, 0.32)]
    return sky, sun, layers


def extras(rng, count):
    """iPad 展示图要铺满大屏：再来一批随机配色的风景 / 插画"""
    sizes = [PORTRAIT, LANDSCAPE, SQUARE]
    for i in range(count):
        size = sizes[i % 3]
        kind = i % 4
        if kind == 0:
            sky, sun, layers = random_palette(rng)
            yield f"extra-{i + 1:02d}.jpg", mountains(rng, size, sky, sun, layers, (rng.uniform(0.2, 0.8), rng.uniform(0.25, 0.45)))
        elif kind == 1:
            sky, sun, layers = random_palette(rng)
            yield f"extra-{i + 1:02d}.jpg", lake(rng, size, dict(sky=sky, sun=sun, hills=layers, water=layers[0]))
        elif kind == 2:
            import colorsys
            hue = rng.random()
            cols = [tuple(int(v * 255) for v in colorsys.hsv_to_rgb((hue + k * 0.17) % 1, 0.45 if k == 0 else 0.6,
                                                                       0.98 if k == 0 else 0.95)) for k in range(4)]
            yield f"extra-{i + 1:02d}.jpg", abstract(rng, size, cols)
        else:
            yield f"extra-{i + 1:02d}.jpg", night(rng, size) if rng.random() < 0.5 else city(rng, size)


def main(out, extra=0):
    rng = random.Random(42)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    made = {}
    for album, items in scenes(rng).items():
        folder = os.path.join(out, album)
        os.makedirs(folder)
        for name, render in items:
            img = render()
            img.save(os.path.join(folder, name), quality=90)
            made[name] = img
    timelapse(rng, os.path.join(out, "1-旅行", "sunrise.mp4"))
    docs = os.path.join(out, "4-文档")
    os.makedirs(docs)
    journal_pdf(rng, os.path.join(docs, "旅行手账.pdf"), [made["seaside.jpg"], made["lake.jpg"], made["dunes.jpg"]])
    # 「收藏」：除隐藏的那张外全部照片（导入时按内容去重，只是同时加进这个相簿），截相簿里拖动排序用
    favorites = os.path.join(out, "0-收藏")
    os.makedirs(favorites)
    for album in ("1-旅行", "2-风景", "3-插画"):
        for name in sorted(os.listdir(os.path.join(out, album))):
            if not name.startswith("hidden-"):
                shutil.copy(os.path.join(out, album, name), os.path.join(favorites, name))
    if extra:
        folder = os.path.join(out, "5-随拍")
        os.makedirs(folder)
        for name, img in extras(rng, extra):
            img.save(os.path.join(folder, name), quality=88)
    print("done", out)


if __name__ == "__main__":
    # 第二个参数：额外生成多少张（iPad 展示图要铺满大屏）
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 0)
