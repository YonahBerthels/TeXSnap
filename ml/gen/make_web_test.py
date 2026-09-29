#!/usr/bin/env python3
"""Out-of-distribution test set: held-out samples rendered by KaTeX in WebKit (the app's preview page),
like screenshots of web pages and chat answers rather than PDFs.

Usage: .venv/bin/python gen/make_web_test.py data/ds1/validation data/webtest [--n 80]
"""
import argparse
import json
import os
import random
import re
import subprocess
import tempfile

from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "..", "build", "TeXSnap.app", "Contents", "MacOS", "TeXSnap")


def parse(answer):
    kind = re.search(r"<kind>(\w+)</kind>", answer).group(1)
    latex = re.search(r"<latex>\n(.*)\n</latex>", answer, re.S).group(1)
    return kind, latex


def clipped(path):
    """True when content touches the left or right edge: the preview cut a wide formula off."""
    img = Image.open(path).convert("RGB")
    bg = Image.new("RGB", img.size, img.getpixel((0, 0)))
    box = ImageChops.difference(img, bg).convert("L").point(lambda v: 255 if v > 40 else 0).getbbox()
    return box is None or box[0] <= 3 or box[2] >= img.width - 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("out")
    ap.add_argument("--n", type=int, default=80)
    args = ap.parse_args()
    rows = [json.loads(l) for l in open(os.path.join(args.source, "metadata.jsonl"))]
    rng = random.Random(7)
    rng.shuffle(rows)
    os.makedirs(os.path.join(args.out, "images"), exist_ok=True)
    written = 0
    with open(os.path.join(args.out, "metadata.jsonl"), "w") as meta:
        for r in rows:
            if written >= args.n:
                break
            kind, latex = parse(r["answer"])
            if kind == "none":
                continue
            with tempfile.NamedTemporaryFile("w", suffix=".tex", delete=False) as f:
                f.write(latex)
            name = f"images/web-{written:04d}.png"
            cmd = [APP, "--render-preview", kind, f.name, os.path.join(args.out, name),
                   "--width", str(rng.choice([420, 560, 720, 900]) if kind == "text" else 1800)]
            if rng.random() < 0.2:
                cmd.append("--dark")
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            os.unlink(f.name)
            if res.returncode != 0:
                print("skip:", res.stderr.strip()[:200])
                continue
            if clipped(os.path.join(args.out, name)):
                print("skip: clipped", name)
                os.unlink(os.path.join(args.out, name))
                continue
            meta.write(json.dumps({"file_name": name, "question": r["question"], "answer": r["answer"],
                                   "kind": kind}) + "\n")
            written += 1
    print(f"wrote {written} to {args.out}")


if __name__ == "__main__":
    main()
