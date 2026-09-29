#!/usr/bin/env python3
"""Score the recognition prompt against the rendered fixtures.

Each fixture image is transcribed, then the result is compared with the ground truth in three ways:
  kind      - the reported kind matches
  tokens    - the LaTeX matches after normalising spacing, braces and synonyms
  render    - pdflatex renders the result pixel-identically to the ground truth
A result that differs in all but kind is shown side by side for manual review.

Usage:
  python3 Tests/eval_prompt.py [--engine claude-code|app] [--model M] [--effort E] [--jobs N] [names...]
  --engine app runs the built app's command-line mode (build/TeXSnap.app) instead of calling claude directly.
"""
import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")
PROMPT = os.path.join(ROOT, "Resources", "prompts", "system.txt")
APP_BIN = os.path.join(ROOT, "build", "TeXSnap.app", "Contents", "MacOS", "TeXSnap")

PREAMBLE = r"""\documentclass[border=10pt,varwidth=%s]{standalone}
\usepackage[T1]{fontenc}
\usepackage{amsmath,amssymb,bm,booktabs,multirow,mathrsfs}
\begin{document}
%s
\end{document}
"""

# ---------------------------------------------------------------- parsing

def parse_output(text):
    kind = None
    m = re.search(r"<kind>\s*([A-Za-z]+)\s*</kind>", text)
    if m:
        kind = m.group(1).lower()
    note = None
    mn = re.search(r"<note>(.*?)</note>", text, re.S)
    if mn:
        note = mn.group(1).strip()
    start = text.find("<latex>")
    if start >= 0:
        end = text.rfind("</latex>")
        latex = text[start + len("<latex>"): end if end > start else len(text)]
    else:
        latex = re.sub(r"<kind>.*?</kind>|<note>.*?</note>", "", text, flags=re.S)
    return kind, latex.strip(), note


# ---------------------------------------------------------------- normalisation

SYNONYMS = {
    r"\le": r"\leq", r"\ge": r"\geq", r"\ne": r"\neq", r"\to": r"\rightarrow", r"\gets": r"\leftarrow",
    r"\dfrac": r"\frac", r"\tfrac": r"\frac", r"\lvert": "|", r"\rvert": "|", r"\vert": "|", r"\mid": "|",
    r"\lVert": r"\|", r"\rVert": r"\|", r"\Vert": r"\|", r"\colon": ":", r"\lbrace": r"\{", r"\rbrace": r"\}",
    r"\dots": r"\ldots", r"\emph": r"\textit", r"\intercal": r"\top", r"\land": r"\wedge", r"\lor": r"\vee",
    r"\lnot": r"\neg", r"\hbar": r"\hbar", r"\bm": r"\boldsymbol",
}
DROP = {r"\left", r"\right", r"\bigl", r"\bigr", r"\Bigl", r"\Bigr", r"\biggl", r"\biggr", r"\big", r"\Big",
        r"\bigg", r"\Bigg", r"\,", r"\;", r"\:", r"\!", r"\ ", r"\quad", r"\qquad", "~", r"\displaystyle",
        r"\limits", r"\nolimits", r"\centering"}


def normalise(latex):
    toks = re.findall(r"\\[A-Za-z]+|\\.|\S", latex)
    toks = [SYNONYMS.get(t, t) for t in toks if t not in DROP]
    changed = True
    while changed:  # drop braces around a single token
        changed = False
        out = []
        i = 0
        while i < len(toks):
            if toks[i] == "{" and i + 2 < len(toks) and toks[i + 2] == "}" and toks[i + 1] not in "{}":
                out.append(toks[i + 1])
                i += 3
                changed = True
            else:
                out.append(toks[i])
                i += 1
        toks = out
    return toks


# ---------------------------------------------------------------- rendering

def render(kind, latex, workdir, name):
    body = r"\[ %s \]" % latex if kind == "math" else latex
    width = "12cm" if kind == "text" else "18cm"
    tex = os.path.join(workdir, name + ".tex")
    with open(tex, "w") as f:
        f.write(PREAMBLE % (width, body))
    r = subprocess.run(["pdflatex", "-interaction=nonstopmode", "-halt-on-error", "-output-directory", workdir, tex],
                       capture_output=True, text=True)
    if r.returncode != 0:
        err = [l for l in r.stdout.splitlines() if l.startswith("!")]
        return None, (err[0] if err else "pdflatex failed")
    png = os.path.join(workdir, name + ".png")
    subprocess.run(["gs", "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pnggray", "-r150",
                    f"-sOutputFile={png}", os.path.join(workdir, name + ".pdf")], check=True)
    return png, None


def same_render(a, b):
    ia, ib = np.asarray(Image.open(a).convert("L"), dtype=np.int16), np.asarray(Image.open(b).convert("L"), dtype=np.int16)
    return ia.shape == ib.shape and int(np.abs(ia - ib).max()) <= 8


def side_by_side(paths, out):
    ims = [Image.open(p).convert("L") for p in paths if p]
    w = max(i.width for i in ims)
    h = sum(i.height for i in ims) + 12 * (len(ims) - 1)
    canvas = Image.new("L", (w, h), 255)
    y = 0
    for i in ims:
        canvas.paste(i, (0, y))
        y += i.height + 12
    canvas.save(out)


# ---------------------------------------------------------------- engines

def run_claude_code(image_path, model, effort, system_prompt):
    data = base64.b64encode(open(image_path, "rb").read()).decode()
    msg = {"type": "user", "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": data}},
        {"type": "text", "text": "Transcribe this image into LaTeX."}]}}
    args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", model, "--effort", effort, "--tools", "", "--system-prompt", system_prompt,
            "--no-session-persistence", "--safe-mode", "--strict-mcp-config"]
    p = subprocess.run(args, input=json.dumps(msg) + "\n", capture_output=True, text=True,
                       cwd=tempfile.gettempdir(), timeout=600)
    result = None
    for line in p.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "result":
            result = ev
    if not result or result.get("is_error"):
        raise RuntimeError(f"claude failed: {result and result.get('result')} {p.stderr[-500:]}")
    return result["result"]


def run_app(image_path, model, effort, extra=()):
    p = subprocess.run([APP_BIN, "--recognize", image_path, "--model", model, "--effort", effort, "--json", *extra],
                       capture_output=True, text=True, timeout=600)
    if p.returncode != 0:
        raise RuntimeError(f"app failed ({p.returncode}): {p.stderr[-800:]}")
    r = json.loads(p.stdout)
    return r


# ---------------------------------------------------------------- main

def evaluate(name, args, system_prompt, workdir):
    img = os.path.join(FIXTURES, name + ".png")
    expected = json.load(open(os.path.join(FIXTURES, name + ".json")))
    t0 = time.time()
    try:
        if args.engine == "app":
            r = run_app(img, args.model, args.effort, args.app_args.split())
            kind, latex, note, raw = r["kind"], r["latex"], r.get("note"), r.get("raw", "")
        else:
            raw = run_claude_code(img, args.model, args.effort, system_prompt)
            kind, latex, note = parse_output(raw)
    except Exception as e:  # noqa: BLE001
        return dict(name=name, error=str(e), seconds=time.time() - t0)
    seconds = time.time() - t0
    res = dict(name=name, kind=kind, latex=latex, note=note, raw=raw, seconds=seconds,
               kind_ok=kind == expected["kind"],
               tokens_ok=normalise(latex) == normalise(expected["latex"]))
    if expected["kind"] == "none":
        res.update(render_ok=res["kind_ok"] and not latex.strip(), compile_error=None)
        return res
    exp_png, _ = render(expected["kind"], expected["latex"], workdir, name + "-expected")
    got_png, err = render(kind or expected["kind"], latex, workdir, name + "-got")
    res["compile_error"] = err
    res["render_ok"] = bool(got_png and exp_png and same_render(exp_png, got_png))
    if not res["render_ok"] and got_png and exp_png:
        out = os.path.join(args.out, name + "-compare.png")
        side_by_side([os.path.join(FIXTURES, name + ".png"), exp_png, got_png], out)
        res["compare"] = out
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="claude-code", choices=["claude-code", "app"])
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--effort", default="medium")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--app-args", default="", help="extra flags for the app, e.g. '--no-upscale --engine api'")
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "texsnap-eval"))
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    names = args.names or sorted(f[:-5] for f in os.listdir(FIXTURES) if f.endswith(".json"))
    system_prompt = open(PROMPT).read()
    workdir = tempfile.mkdtemp(prefix="texsnap-eval-")
    try:
        with ThreadPoolExecutor(args.jobs) as ex:
            results = list(ex.map(lambda n: evaluate(n, args, system_prompt, workdir), names))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print(f"\n{'fixture':18} {'kind':6} {'tokens':6} {'render':6} {'secs':>5}")
    for r in results:
        if "error" in r:
            print(f"{r['name']:18} ERROR  {r['error'][:200]}")
            continue
        flag = lambda b: "ok" if b else "--"
        print(f"{r['name']:18} {flag(r['kind_ok']):6} {flag(r['tokens_ok']):6} {flag(r['render_ok']):6} {r['seconds']:5.1f}"
              + (f"  COMPILE ERROR: {r['compile_error']}" if r.get("compile_error") else "")
              + (f"  note: {r['note']}" if r.get("note") else ""))
    ok = [r for r in results if "error" not in r]
    print(f"\nkind {sum(r['kind_ok'] for r in ok)}/{len(results)}  tokens {sum(r['tokens_ok'] for r in ok)}/{len(results)}"
          f"  render {sum(r['render_ok'] for r in ok)}/{len(results)}"
          f"  mean {np.mean([r['seconds'] for r in results]):.1f}s  max {max(r['seconds'] for r in results):.1f}s")
    for r in ok:
        if not (r["tokens_ok"] or r["render_ok"]) or not r["kind_ok"]:
            print(f"\n--- {r['name']} (kind {r['kind']})\n{r['latex']}\n    compare: {r.get('compare')}")
    with open(os.path.join(args.out, "results.json"), "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
