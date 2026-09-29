#!/usr/bin/env python3
"""Builds a training set of synthetic screenshots.

Usage: .venv/bin/python gen/build.py --out data/ds --train 10000 --val 300 [--workers 10] [--seed 1]
Writes <out>/<split>/images/*.png and <out>/<split>/metadata.jsonl (file_name, question, answer), which
mlx_vlm.lora loads as an image-folder dataset.
"""
import argparse
import json
import os
import random
import subprocess
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import content  # noqa: E402
import render  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ML = os.path.dirname(HERE)
PROMPT = "Transcribe this image into LaTeX."  # Prompts.transcribe in the app
MIX = {"math": 0.5, "table": 0.2, "text": 0.28, "none": 0.02}
BATCH = 150


def target(kind, latex):
    return f"<kind>{kind}</kind>\n<latex>\n{latex}\n</latex>"


def build_split(name, count, src, args, seed):
    rng = random.Random(seed)
    split_dir = os.path.join(args.out, name)
    os.makedirs(os.path.join(split_dir, "images"), exist_ok=True)
    # Over-generate: validation and compilation drop some.
    raw_path = os.path.join(split_dir, "raw.jsonl")
    valid_path = os.path.join(split_dir, "valid.jsonl")
    with open(raw_path, "w") as f:
        for _ in range(int(count * 1.35) + 50):
            f.write(json.dumps(content.make(src, rng, args.mix)) + "\n")
    subprocess.run(["node", os.path.join(HERE, "validate.js"), raw_path, valid_path], check=True)
    samples = [json.loads(l) for l in open(valid_path)]
    rng.shuffle(samples)
    samples = samples[: int(count * 1.15) + 20]

    fonts = list(render.FONT_WEIGHTS)
    weights = list(render.FONT_WEIGHTS.values())
    jobs = [(samples[i:i + BATCH], rng.choices(fonts, weights)[0], rng.randrange(1 << 30))
            for i in range(0, len(samples), BATCH)]
    written, dropped = 0, 0
    with open(os.path.join(split_dir, "metadata.jsonl"), "w") as meta, Pool(args.workers) as pool:
        for results in pool.imap_unordered(render.render_batch, jobs):
            for s, img in results:
                if written >= count:
                    break
                if img is None:
                    dropped += 1
                    continue
                file_name = f"images/{name}-{written:06d}.png"
                img.save(os.path.join(split_dir, file_name), optimize=False)
                meta.write(json.dumps({"file_name": file_name, "question": PROMPT,
                                       "answer": target(s["kind"], s["latex"]), "kind": s["kind"]}) + "\n")
                written += 1
            print(f"{name}: {written}/{count} written, {dropped} dropped", flush=True)
    os.remove(raw_path)
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ML, "data", "ds"))
    ap.add_argument("--train", type=int, default=10000)
    ap.add_argument("--val", type=int, default=300)
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 4) - 2))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--mix", type=json.loads, default=MIX, help='e.g. \'{"math": 0.3, "table": 0.4, ...}\'')
    args = ap.parse_args()
    src = content.Sources(os.path.join(ML, "data", "formulas.jsonl"),
                          os.path.join(ML, "data", "src", "abstracts_math.txt"))
    print(f"{len(src.formulas)} formulas, {len(src.abstracts)} abstracts", flush=True)
    if args.val:
        build_split("validation", args.val, src, args, args.seed + 1000)
    if args.train:
        build_split("train", args.train, src, args, args.seed)


if __name__ == "__main__":
    main()
