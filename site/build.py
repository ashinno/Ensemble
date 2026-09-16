#!/usr/bin/env python3
"""Assembles site/ensemble.html from site/template.html, the app screenshots and the icon."""
import base64, io, math, random, os
from PIL import Image
os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/..")
def data_uri(path, maxw=None, flip=False):
    im = Image.open(path).convert("RGBA")
    if flip: im = im.transpose(Image.FLIP_TOP_BOTTOM)
    if maxw and im.width > maxw: im = im.resize((maxw, int(im.height*maxw/im.width)), Image.LANCZOS)
    buf = io.BytesIO(); im.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()
tpl = open("site/template.html").read()
tpl = tpl.replace("{{IMG_HOST}}", data_uri("design/shots/host.png", 1600, flip=True))
tpl = tpl.replace("{{IMG_RECV}}", data_uri("design/shots/receiver.png", 1600, flip=True))
tpl = tpl.replace("{{IMG_ICON}}", data_uri("design/icon-1024.png", 64))
bars = []
for i in range(30):
    x = i/29; env = 0.15 + 0.85*math.exp(-((x-0.4)**2)/0.09); wob = 0.7 + 0.3*(0.5+0.5*math.sin(i*1.7))
    h = env*wob*48; px = 5*i + 2.5
    bars.append(f'<line x1="{px:.1f}" y1="48" x2="{px:.1f}" y2="{48-h:.1f}" stroke="{"#ff4d1f" if i == 3 else "#d4d4d4"}" stroke-width="1.5"/>')
tpl = tpl.replace("{{DELAY_BARS}}", "".join(bars))
random.seed(4); pts = []
for i in range(120):
    x = i/119; env = math.exp(-((x-0.45)**2)/0.06)+0.08; a = (random.random()*2-1)*env*22
    pts.append(f"{x*140:.1f},{24+(a if i%2 else -a):.1f}")
tpl = tpl.replace("{{CAPTURE_VIZ}}", f'<polyline points="{" ".join(pts)}" stroke="#d4d4d4" stroke-width="1"/><line x1="112" y1="0" x2="112" y2="48" stroke="#ff4d1f" stroke-width="1.5"/>')
lv = [0.3,0.5,0.8,1,0.75,0.55,0.9,0.7,0.45,0.35,0.3,0.2,0.4,0.6,0.85,0.65,0.5,0.35,0.55,0.25]
tpl = tpl.replace("{{LEVELS_VIZ}}", "".join(f'<line x1="{6*i+3:.1f}" y1="40" x2="{6*i+3:.1f}" y2="{40-v*38:.1f}" stroke="{"#ff4d1f" if i==11 else "#d4d4d4"}" stroke-width="1.5"/>' for i,v in enumerate(lv)))
assert "{{" not in tpl
open("site/ensemble.html","w").write(tpl)
open("site/index.html","w").write("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"description\" content=\"Ensemble plays one Mac's audio through every Mac in the house, in sync.\"></head><body>" + tpl + "</body></html>")
print("wrote site/ensemble.html and site/index.html", len(tpl)//1024, "KB")
