#!/usr/bin/env python3
"""Benchmark of local OCR models on Tests/fixtures (or a synthetic validation split).

Usage:
  .venv/bin/python bench.py <model-key> [--limit N]                    zero-shot baselines
  .venv/bin/python bench.py texsnap --adapter runs/r1/adapters.safetensors [--data data/ds1/validation] [--tag r1]
Writes results/<tag or model-key>.jsonl with each sample's output, time and edit distance; score it with score.js.
"""
import argparse
import glob
import json
import os
import re
import time

import mlx.core as mx
from mlx_vlm import generate, load
from mlx_vlm.prompt_utils import apply_chat_template

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "..", "Tests", "fixtures")
PROMPT = "Transcribe this image into LaTeX."

MODELS = {
    "granite": ("ibm-granite/granite-docling-258M-mlx",
                {"math": "Convert formula to LaTeX.", "table": "Convert table to OTSL.",
                 "text": "Convert this page to docling."}),
    "glm": ("mlx-community/GLM-OCR-8bit",
            {"math": "Formula Recognition:", "table": "Table Recognition:", "text": "Text Recognition:"}),
    "paddle": ("OpenGryd/PaddleOCR-VL-1.6-MLX-8bit",
               {"math": "Formula Recognition:", "table": "Table Recognition:", "text": "OCR:"}),
    # Fine-tuned: one prompt, the model decides the kind.
    "texsnap": ("OpenGryd/PaddleOCR-VL-1.6-MLX-16bit", None),
}


def squash(s: str) -> str:
    return re.sub(r"\s+", "", s)


def edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def parse(text):
    """<kind>K</kind><latex>L</latex> -> (K, L), as the app's ModelOutput does."""
    kind = re.search(r"<kind>\s*(\w+)\s*</kind>", text)
    latex = re.search(r"<latex>\n?(.*?)\n?(</latex>|$)", text, re.S)
    return (kind.group(1) if kind else None), (latex.group(1).strip() if latex else text)


def cases(data):
    """(name, kind, expected latex, image path) from fixtures or a dataset split."""
    if data is None:
        for path in sorted(glob.glob(os.path.join(FIXTURES, "*.json"))):
            e = json.load(open(path))
            yield os.path.basename(path)[:-5], e["kind"], e["latex"], path[:-5] + ".png"
        return
    for line in open(os.path.join(data, "metadata.jsonl")):
        r = json.loads(line)
        kind, latex = parse(r["answer"])
        yield os.path.basename(r["file_name"])[:-4], kind, latex, os.path.join(data, r["file_name"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", choices=MODELS)
    ap.add_argument("--adapter")
    ap.add_argument("--model-path", help="override the base model (e.g. a fused, quantized model)")
    ap.add_argument("--data", help="dataset split dir instead of Tests/fixtures")
    ap.add_argument("--tag")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    repo, prompts = MODELS[args.model]
    repo = args.model_path or repo

    t0 = time.time()
    adapter = args.adapter
    if adapter and os.path.isfile(adapter):  # load() wants the adapter's folder
        adapter = os.path.dirname(adapter)
    model, processor = load(repo, adapter_path=adapter, trust_remote_code=True)
    print(f"loaded {repo} in {time.time() - t0:.1f}s", flush=True)

    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    out_path = os.path.join(HERE, "results", f"{args.tag or args.model}.jsonl")
    n = 0
    with open(out_path, "w") as out:
        for name, kind, expected, image in cases(args.data):
            if prompts is not None and kind not in prompts:
                continue
            if args.limit and n >= args.limit:
                break
            n += 1
            text_prompt = PROMPT if prompts is None else prompts[kind]
            prompt = apply_chat_template(processor, model.config, text_prompt, num_images=1)
            mx.reset_peak_memory()
            t = time.time()
            result = generate(model, processor, prompt, image=[image], max_tokens=1500,
                              temperature=0.0, verbose=False)
            seconds = time.time() - t
            raw = result.text if hasattr(result, "text") else str(result)
            got_kind, text = (parse(raw) if prompts is None else (kind, raw))
            ref, hyp = squash(expected), squash(text)
            ned = edit_distance(ref, hyp) / max(len(ref), 1)
            row = {"name": name, "kind": kind, "got_kind": got_kind, "seconds": round(seconds, 2),
                   "tokens": getattr(result, "generation_tokens", None),
                   "peak_gb": round(mx.get_peak_memory() / 1e9, 2), "ned": round(ned, 3),
                   "exact": ref == hyp, "output": text, "raw": raw, "expected": expected}
            out.write(json.dumps(row) + "\n")
            out.flush()
            print(f"{name:22s} {kind:5s}->{got_kind or '?':5s} {seconds:5.2f}s ned={ned:.3f}", flush=True)


if __name__ == "__main__":
    main()
