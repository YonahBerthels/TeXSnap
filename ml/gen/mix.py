#!/usr/bin/env python3
"""Merges datasets (image folders with metadata.jsonl) into one training set, e.g. synthetic data plus the
corrections TeXSnap saved from real use.

Usage:
  .venv/bin/python gen/mix.py --out data/ds3 \\
      --add data/ds1/train:4000 \\
      --add "$HOME/Library/Application Support/TeXSnap/Corrections*5"

Each --add is DIR[:LIMIT][*REPEAT]: take at most LIMIT random rows of DIR, each REPEAT times (to give a few
hundred real corrections weight next to thousands of synthetic samples). Images are hard-linked when possible.
Writes <out>/train/metadata.jsonl and <out>/train/images/.
"""
import argparse
import json
import os
import random
import re
import shutil


def parse_source(spec):
    m = re.fullmatch(r"(.+?)(?::(\d+))?(?:\*(\d+))?", spec)
    return m.group(1), int(m.group(2)) if m.group(2) else None, int(m.group(3)) if m.group(3) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--add", action="append", required=True, metavar="DIR[:LIMIT][*REPEAT]")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    split = os.path.join(args.out, "train")
    images = os.path.join(split, "images")
    if os.path.exists(split):
        shutil.rmtree(split)
    os.makedirs(images)
    rows = []
    for n, spec in enumerate(args.add):
        path, limit, repeat = parse_source(os.path.expanduser(spec))
        meta = os.path.join(path, "metadata.jsonl")
        source = [json.loads(line) for line in open(meta) if line.strip()]
        rng.shuffle(source)
        if limit:
            source = source[:limit]
        for i, row in enumerate(source):
            name = f"s{n}-{i:06d}{os.path.splitext(row['file_name'])[1]}"
            target = os.path.join(images, name)
            try:
                os.link(os.path.join(path, row["file_name"]), target)
            except OSError:
                shutil.copyfile(os.path.join(path, row["file_name"]), target)
            rows.extend([dict(row, file_name=f"images/{name}")] * repeat)
        print(f"{path}: {len(source)} rows x {repeat}")
    rng.shuffle(rows)
    with open(os.path.join(split, "metadata.jsonl"), "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    print(f"wrote {len(rows)} rows to {split}")


if __name__ == "__main__":
    main()
