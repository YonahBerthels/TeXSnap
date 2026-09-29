"""Contact sheet of dataset samples for eyeballing. Usage: python gen/sheet.py <split-dir> <out.png> [n] [kind]"""
import json
import os
import random
import sys

from PIL import Image, ImageDraw

split, out = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 12
kind = sys.argv[4] if len(sys.argv) > 4 else None
rows = [json.loads(l) for l in open(os.path.join(split, "metadata.jsonl"))]
if kind:
    rows = [r for r in rows if r["kind"] == kind]
random.Random(0).shuffle(rows)
rows = rows[:n]
W = 1400
tiles = []
for r in rows:
    img = Image.open(os.path.join(split, r["file_name"])).convert("RGB")
    if img.width > W - 20:
        img = img.resize((W - 20, round(img.height * (W - 20) / img.width)))
    tiles.append((r, img))
H = sum(img.height + 44 for _, img in tiles)
sheet = Image.new("RGB", (W, H), (200, 200, 200))
d = ImageDraw.Draw(sheet)
y = 0
for r, img in tiles:
    label = r["file_name"] + "  " + r["answer"].split("\n", 2)[-1].replace("\n", " ")[:170]
    d.text((10, y + 4), label, fill=(0, 0, 160))
    sheet.paste(img, (10, y + 22))
    y += img.height + 44
sheet.save(out)
print(out, sheet.size)
