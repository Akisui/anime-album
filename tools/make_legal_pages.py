"""从 App 源码（LegalDocuments.swift / AppInfo.swift）生成上架用的网页：隐私政策、用户协议、免责声明、技术支持页。
App Store Connect 要求填「隐私政策网址」「技术支持网址」，把输出目录托管出去（如 GitHub Pages）即可；
文本只在 Swift 里改一处，重新运行这个脚本，网页和 App 里永远一致。
用法：python3 tools/make_legal_pages.py <输出目录>
"""
import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEGAL = os.path.join(ROOT, "AnimeAlbum/Features/Settings/LegalDocuments.swift")
INFO = os.path.join(ROOT, "AnimeAlbum/App/AppInfo.swift")


def app_info():
    source = open(INFO, encoding="utf-8").read()
    name = re.search(r'static let name = "([^"]+)"', source).group(1)
    english = re.search(r'static let englishName = "([^"]+)"', source).group(1)
    date = re.search(r'static let termsEffectiveDate = "([^"]+)"', source).group(1)
    return name, english, date


def documents(name, date):
    source = open(LEGAL, encoding="utf-8").read()
    docs = {}
    for case in ("privacy", "terms", "disclaimer"):
        block = re.search(r"case \." + case + r":\s*return \[(.*?)\n\s*\]", source, re.S).group(1)
        sections = re.findall(r'\("([^"]+)",\s*"((?:[^"\\]|\\.)*)"\)', block)
        docs[case] = [(h, b.replace("\\(name)", name).replace("\\(AppInfo.termsEffectiveDate)", date))
                      for h, b in sections]
    return docs


TITLES = {"privacy": "隐私政策", "terms": "用户协议", "disclaimer": "免责声明"}

STYLE = """
:root { --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --accent: #5b5bd6; --card: #f5f5f7; }
@media (prefers-color-scheme: dark) { :root { --bg: #000; --fg: #f5f5f7; --muted: #a1a1a6; --accent: #8e8cff; --card: #1c1c1e; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
       font: 17px/1.65 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 48px 20px 64px; }
header { display: flex; align-items: center; gap: 14px; margin-bottom: 28px; }
header img { width: 56px; height: 56px; border-radius: 13px; }
header .name { font-size: 15px; color: var(--muted); }
h1 { font-size: 30px; margin: 0; }
h2 { font-size: 19px; margin: 30px 0 6px; }
p { margin: 0; color: var(--muted); }
nav { margin-top: 40px; display: flex; gap: 18px; flex-wrap: wrap; font-size: 15px; }
a { color: var(--accent); text-decoration: none; }
.card { background: var(--card); border-radius: 14px; padding: 18px 20px; margin-top: 18px; }
"""


def page(title, body, name, english):
    return f"""<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · {html.escape(name)}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
<header><img src="icon.png" alt=""><div><div class="name">{html.escape(name)} {html.escape(english)}</div><h1>{html.escape(title)}</h1></div></header>
{body}
<nav><a href="index.html">技术支持</a><a href="privacy.html">隐私政策</a><a href="terms.html">用户协议</a><a href="disclaimer.html">免责声明</a></nav>
</main>
</body>
</html>
"""


def main(out):
    name, english, date = app_info()
    os.makedirs(out, exist_ok=True)
    for key, sections in documents(name, date).items():
        body = "\n".join(f"<h2>{html.escape(h)}</h2>\n<p>{html.escape(b)}</p>" for h, b in sections)
        open(os.path.join(out, f"{key}.html"), "w", encoding="utf-8").write(page(TITLES[key], body, name, english))
    support = f"""<p>{html.escape(name)}是一款私密相册：把不想放进系统相册的照片、视频和 PDF 收在这里，可以隐藏、可以用面容 ID 上锁，所有内容只保存在你的设备和你自己的 iCloud 中。</p>
<div class="card"><h2 style="margin-top:0">常见问题</h2>
<h2>换手机后照片还在吗？</h2><p>在「设置 › iCloud 同步」中打开同步后，内容会保存在你本人的 iCloud 里，新设备登录同一 Apple 账户并打开同步即可。未开启同步时，内容只在本机，请在换机前用 iCloud 同步或系统备份迁移。</p>
<h2>隐藏的照片在哪里看？</h2><p>在图库、相簿列表或相簿里点右上角「…」，在「显示」中选择「只显示隐藏的」或「全部显示」。如开启了「查看隐藏内容时验证」，需要先通过面容 ID / 触控 ID。</p>
<h2>导入后系统相册里还有原图？</h2><p>从照片图库导入完成后会询问是否从系统相册删除原图；删除的照片会先进入系统「照片」的「最近删除」，30 天后彻底删除，也可以在那里手动立即删除。</p>
<h2>面容 ID 识别不了怎么办？</h2><p>面容 ID / 触控 ID 不可用或连续失败时，可以改用设备密码解锁。</p>
</div>
<div class="card"><h2 style="margin-top:0">联系我们</h2><p>如有问题或建议，请通过 App Store 中本 App 页面的「App 支持」联系开发者。</p></div>"""
    open(os.path.join(out, "index.html"), "w", encoding="utf-8").write(page("技术支持", support, name, english))
    icon = os.path.join(ROOT, "AnimeAlbum/Assets.xcassets/BrandIcon.imageset/BrandIcon.png")
    if os.path.exists(icon):
        import shutil
        shutil.copy(icon, os.path.join(out, "icon.png"))
    print("done", out)


if __name__ == "__main__":
    main(sys.argv[1])
