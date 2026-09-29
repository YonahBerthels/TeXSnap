"""Renders samples with pdflatex (one page per sample) and turns the pages into screenshot-like images."""
import io
import math
import os
import random
import re
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageOps

# Each render uses one font setup; together they cover the typical looks of papers, books and slides.
FONTS = {
    "cm": "",
    "lm": r"\usepackage{lmodern}",
    "times": r"\usepackage{newtxtext,newtxmath}",
    "palatino": r"\usepackage{newpxtext,newpxmath}",
    "libertinus": r"\usepackage{libertinus}\usepackage{libertinust1math}",
    "charter": r"\usepackage{XCharter}\usepackage[xcharter]{newtxmath}",
    "fourier": r"\usepackage{fourier}",
    "sans": r"\usepackage{sansmathfonts}\renewcommand{\familydefault}{\sfdefault}",
    "euler": r"\usepackage{eulervm}",
    "helvet": r"\usepackage[scaled]{helvet}\usepackage[helvet]{sfmath}\renewcommand{\familydefault}{\sfdefault}",
}
FONT_WEIGHTS = {"cm": 30, "lm": 10, "times": 14, "palatino": 7, "libertinus": 6, "charter": 5, "fourier": 4,
                "sans": 5, "euler": 2, "helvet": 7}

PREAMBLE = r"""\documentclass[border=3pt,multi=snip]{standalone}
\usepackage[T1]{fontenc}
\usepackage[utf8]{inputenc}
\usepackage{amsmath,amssymb,mathtools,bm,mathrsfs,booktabs,multirow,array,cancel}
%s
\newenvironment{snip}{}{}
\setlength{\parindent}{0pt}
\setlength{\parskip}{0.6em}
\begin{document}
"""

RASTER_DPI = 300


def body(sample):
    kind, latex, hints = sample["kind"], sample["latex"], sample.get("render", {})
    if kind == "math":
        if "\\tag" in latex:
            return r"\begin{minipage}{15cm}\[ %s \]\end{minipage}" % latex
        if hints.get("mode") == "inline":
            return "$%s$" % latex
        return r"$\displaystyle %s$" % latex
    if kind == "table":
        return latex
    if kind == "text":
        return r"\begin{minipage}{%dcm}%s\end{minipage}" % (hints.get("width_cm", 12), latex)
    raise ValueError(kind)


def compile_pages(samples, font, workdir):
    """Returns one grayscale page image (or None when it failed) per sample."""
    tex = [PREAMBLE % FONTS[font]]
    for i, s in enumerate(samples):
        tex.append("\\typeout{@@SNIP %d}\n\\begin{snip}%s\\end{snip}\n" % (i, body(s)))
    tex.append("\\typeout{@@SNIP end}\n\\end{document}\n")
    path = os.path.join(workdir, "b.tex")
    with open(path, "w") as f:
        f.write("".join(tex))
    try:
        subprocess.run(["pdflatex", "-interaction=nonstopmode", "b.tex"], cwd=workdir, capture_output=True,
                       timeout=300)
    except subprocess.TimeoutExpired:
        return split_retry(samples, font, workdir)
    log = open(os.path.join(workdir, "b.log"), encoding="latin-1").read()
    failed, current = set(), None
    for line in log.splitlines():
        m = re.match(r"@@SNIP (\d+)", line)
        if m:
            current = int(m.group(1))
        elif line.startswith("!") and current is not None:
            failed.add(current)
    pdf = os.path.join(workdir, "b.pdf")
    if not os.path.exists(pdf):
        return split_retry(samples, font, workdir)
    for f in os.listdir(workdir):
        if f.startswith("p-"):
            os.remove(os.path.join(workdir, f))
    subprocess.run(["gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pnggray", f"-r{RASTER_DPI}",
                    "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4", "-o", "p-%05d.png", "b.pdf"],
                   cwd=workdir, capture_output=True, timeout=600)
    pages = sorted(f for f in os.listdir(workdir) if f.startswith("p-"))
    if len(pages) != len(samples):
        # An error swallowed page boundaries; find the culprit by halving.
        return split_retry(samples, font, workdir)
    out = []
    for i, p in enumerate(pages):
        if i in failed:
            out.append(None)
            continue
        img = Image.open(os.path.join(workdir, p))
        img.load()
        out.append(img)
    return out


def split_retry(samples, font, workdir):
    if len(samples) == 1:
        return [None]
    half = len(samples) // 2
    return compile_pages(samples[:half], font, workdir) + compile_pages(samples[half:], font, workdir)


# ----------------------------------------------------------------------------- screenshot look


def crop_to_content(gray):
    inverted = ImageOps.invert(gray)
    box = inverted.point(lambda v: 255 if v > 6 else 0).getbbox()
    return gray.crop(box) if box else None


def pick_colors(rng):
    r = rng.random()
    if r < 0.70:
        return (0, 0, 0), (255, 255, 255)
    if r < 0.82:  # dark mode
        bg = rng.choice([(30, 30, 30), (18, 18, 18), (40, 42, 54), (33, 37, 43), (0, 0, 0), (45, 45, 48)])
        fg = rng.choice([(255, 255, 255), (230, 230, 230), (212, 212, 212), (200, 205, 215)])
        return fg, bg
    if r < 0.92:  # tinted paper, slides, highlighted notes
        bg = rng.choice([(250, 248, 240), (245, 245, 245), (255, 253, 231), (240, 244, 255), (236, 240, 241),
                         (253, 246, 227), (230, 230, 230)])
        return (rng.randint(0, 50),) * 3, bg
    fg = rng.choice([(0, 0, 139), (25, 25, 112), (139, 0, 0), (0, 80, 0), (60, 60, 60), (0, 51, 102)])
    return fg, (255, 255, 255)


def screenshot(gray, rng):
    """Turns a 300 dpi page crop into a plausible screenshot of it."""
    gray = crop_to_content(gray)
    if gray is None:
        return None
    # Effective resolution of the screenshot: most between 100 and 220 dpi, a tail of tiny and huge ones.
    dpi = min(330, max(55, rng.lognormvariate(math.log(150), 0.35)))
    scale = dpi / RASTER_DPI
    w, h = max(1, round(gray.width * scale)), max(1, round(gray.height * scale))
    longest = max(w, h)
    if longest > 1800:
        f = 1800 / longest
        w, h = max(1, round(w * f)), max(1, round(h * f))
    if h < 10 or w < 6:
        return None
    resample = rng.choices([Image.LANCZOS, Image.BICUBIC, Image.BILINEAR, Image.BOX], [4, 3, 2, 1])[0]
    gray = gray.resize((w, h), resample)
    fg, bg = pick_colors(rng)
    img = ImageOps.colorize(gray, black=fg, white=bg)
    if rng.random() < 0.9:
        pads = [rng.randint(0, 36) for _ in range(4)] if rng.random() < 0.5 else [rng.randint(2, 20)] * 4
        canvas = Image.new("RGB", (w + pads[0] + pads[2], h + pads[1] + pads[3]), bg)
        canvas.paste(img, (pads[0], pads[1]))
        img = canvas
    if rng.random() < 0.08:
        img = img.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 0.7)))
    if rng.random() < 0.12:
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=rng.randint(55, 92))
        img = Image.open(io.BytesIO(buf.getvalue())).convert("RGB")
    return img


def none_image(rng):
    """Something without text or math: shapes, arrows, a plot without labels, a gradient."""
    w, h = rng.randint(80, 900), rng.randint(60, 600)
    fg, bg = pick_colors(rng)
    img = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(img)
    for _ in range(rng.randint(1, 12)):
        color = tuple(rng.randint(0, 255) for _ in range(3)) if rng.random() < 0.5 else fg
        x0, y0 = rng.randint(0, w), rng.randint(0, h)
        x1, y1 = rng.randint(0, w), rng.randint(0, h)
        box = [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]
        shape = rng.choice(["line", "rect", "ellipse", "curve"])
        width = rng.randint(1, 5)
        if shape == "line":
            d.line([x0, y0, x1, y1], fill=color, width=width)
        elif shape == "rect":
            d.rectangle(box, outline=color, width=width, fill=color if rng.random() < 0.3 else None)
        elif shape == "ellipse":
            d.ellipse(box, outline=color, width=width)
        else:
            a, f, p = rng.uniform(0.1, 0.45) * h, rng.uniform(1, 12), rng.uniform(0, 6)
            pts = [(x, h / 2 + a * math.sin(f * x / w * math.pi + p)) for x in range(0, w, 3)]
            d.line(pts, fill=color, width=width)
    return img


def render_batch(args):
    """Worker entry point: (batch of samples, font, seed) -> list of (sample, image or None)."""
    samples, font, seed = args
    rng = random.Random(seed)
    workdir = tempfile.mkdtemp(prefix="texsnap-")
    try:
        results = []
        tex_samples = [s for s in samples if s["kind"] != "none"]
        pages = compile_pages(tex_samples, font, workdir) if tex_samples else []
        it = iter(pages)
        for s in samples:
            if s["kind"] == "none":
                results.append((s, none_image(rng)))
                continue
            page = next(it)
            results.append((s, screenshot(page, rng) if page is not None else None))
        return results
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
