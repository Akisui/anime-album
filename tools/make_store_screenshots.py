"""App Store 展示图：品牌渐变底 + 标题 / 副标题 + 带边框的 App 截图。
用法：python3 tools/make_store_screenshots.py <原始截图目录> <输出目录>
原始截图由模拟器截取（iPhone 17 Pro Max 1320x2868、iPad Pro 13" 2064x2752），文件名见 SHOTS。
输出：iPhone-6.9（1320x2868）、iPhone-6.5（1284x2778）、iPad-13（2064x2752），RGB PNG（App Store 不接受透明通道）
"""
import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

IPHONE_SHOTS = [
    ("lib5", "照片、视频、PDF", "收进一个只属于你的匣子"),
    ("albums", "相簿，分门别类", "长按拖动排序，双指捏合切换列数"),
    ("view12", "沉浸式浏览", "双指放大，左右滑动翻看"),
    ("video", "视频随手播放", "双击暂停，拖动进度条"),
    ("pdf", "PDF 逐页翻看", "像看照片一样读文档"),
    ("hidden", "隐藏照片与相簿", "不想被看到的，就先收起来"),
    ("lock", "面容 ID 守护隐私", "打开 App、查看隐藏内容时验证"),
]

IPAD_SHOTS = [
    ("ipad-library", "照片、视频、PDF", "收进一个只属于你的匣子"),
    ("ipad-album", "相簿，分门别类", "侧栏直达每个相簿"),
    ("ipad-viewer", "沉浸式浏览", "大屏看照片、读 PDF"),
]


def find_font():
    hits = glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc")
    if hits:
        return hits[0], 3, 11  # 苹方 简体 常规 / 中粗
    return "/System/Library/Fonts/Hiragino Sans GB.ttc", 0, 2


FONT, REGULAR, BOLD = find_font()


def background(size):
    w, h = size
    small = Image.new("RGB", (64, 64))
    px = small.load()
    top_left, bottom_right = (86, 176, 255), (110, 84, 236)
    for y in range(64):
        for x in range(64):
            t = (x * 0.35 + y) / (63 * 1.35)
            px[x, y] = tuple(int(top_left[i] + (bottom_right[i] - top_left[i]) * t) for i in range(3))
    img = small.resize(size, Image.BICUBIC)
    # 两团柔光
    glow = Image.new("RGB", size, (0, 0, 0))
    d = ImageDraw.Draw(glow)
    d.ellipse((-w * 0.3, -h * 0.1, w * 0.7, h * 0.35), fill=(255, 255, 255))
    d.ellipse((w * 0.5, h * 0.55, w * 1.4, h * 1.1), fill=(255, 150, 210))
    glow = glow.filter(ImageFilter.GaussianBlur(w * 0.18))
    return Image.blend(img, Image.composite(glow, img, glow.convert("L")), 0.28)


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    return mask


def compose(raw_path, title, subtitle, size, screen_width_ratio, top_ratio, title_size, subtitle_size):
    w, h = size
    canvas = background(size).convert("RGBA")
    d = ImageDraw.Draw(canvas)
    title_font = ImageFont.truetype(FONT, title_size, index=BOLD)
    subtitle_font = ImageFont.truetype(FONT, subtitle_size, index=REGULAR)
    ty = int(h * 0.055)
    d.text((w / 2, ty), title, font=title_font, fill=(255, 255, 255), anchor="ma")
    d.text((w / 2, ty + title_size * 1.35), subtitle, font=subtitle_font, fill=(255, 255, 255, 230), anchor="ma")

    shot = Image.open(raw_path).convert("RGB")
    sw = int(w * screen_width_ratio)
    sh = int(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    bezel = int(sw * 0.022)
    radius = int(sw * 0.105)
    frame = Image.new("RGBA", (sw + bezel * 2, sh + bezel * 2), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, frame.width - 1, frame.height - 1),
                                            radius=radius + bezel, fill=(18, 18, 24, 255))
    frame.paste(shot, (bezel, bezel), rounded(shot, radius))
    x = (w - frame.width) // 2
    y = int(h * top_ratio)
    # 投影
    shadow = Image.new("RGBA", (frame.width + 200, frame.height + 200), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((100, 120, 100 + frame.width, 120 + frame.height),
                                             radius=radius + bezel, fill=(20, 10, 60, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas.alpha_composite(shadow, (x - 100, y - 100))
    canvas.alpha_composite(frame, (x, y))
    return canvas.convert("RGB")


def main(raw_dir, out_dir):
    targets = [
        ("iPhone-6.9", (1320, 2868), IPHONE_SHOTS, 0.78, 0.165, 104, 54),
        ("iPhone-6.5", (1284, 2778), IPHONE_SHOTS, 0.78, 0.165, 100, 52),
        ("iPad-13", (2064, 2752), IPAD_SHOTS, 0.8, 0.17, 120, 62),
    ]
    for folder, size, shots, ratio, top, title_size, subtitle_size in targets:
        os.makedirs(os.path.join(out_dir, folder), exist_ok=True)
        for index, (name, title, subtitle) in enumerate(shots, start=1):
            raw = os.path.join(raw_dir, name + ".png")
            if not os.path.exists(raw):
                print("missing", raw)
                continue
            image = compose(raw, title, subtitle, size, ratio, top, title_size, subtitle_size)
            image.save(os.path.join(out_dir, folder, f"{index:02d}-{name}.png"), optimize=True)
    print("done")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
