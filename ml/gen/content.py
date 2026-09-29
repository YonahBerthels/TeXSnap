"""Random snip contents (the LaTeX a training image is rendered from, which is also its target).

Every sample is {"kind": math|table|text|none, "latex": ..., "render": {...}}; `render` holds hints
for the renderer (inline or display, text width). Targets follow Resources/prompts/system.txt.
"""
import json
import random
import re

# ----------------------------------------------------------------------------- sources


def load_lines(path, key=None, limit=None):
    out = []
    with open(path) as f:
        for line in f:
            v = json.loads(line)
            out.append(v[key] if key else v)
            if limit and len(out) >= limit:
                break
    return out


class Sources:
    def __init__(self, formulas_path, abstracts_path):
        self.formulas = load_lines(formulas_path, "latex")
        # Short, single-line formulas for inline use (table cells, displayed equations in text).
        self.short = [f for f in self.formulas if len(f) <= 40 and "\n" not in f and "\\begin" not in f]
        self.medium = [f for f in self.formulas if 10 <= len(f) <= 160 and "\\tag" not in f]
        self.abstracts = load_lines(abstracts_path) if abstracts_path else []
        words = set()
        for a in self.abstracts[:20000]:
            for w in re.sub(r"\$[^$]*\$", " ", a).split():
                if re.fullmatch(r"[A-Za-z][a-z]{3,11}", w):
                    words.add(w.lower())
        self.words = sorted(words) or ["value", "model", "method", "result"]


# ----------------------------------------------------------------------------- math


def math_sample(src: Sources, rng: random.Random):
    latex = rng.choice(src.formulas)
    one_line = "\n" not in latex and "\\begin" not in latex and "\\tag" not in latex
    inline = one_line and len(latex) < 70 and rng.random() < 0.12
    return {"kind": "math", "latex": latex, "render": {"mode": "inline" if inline else "display"}}


# ----------------------------------------------------------------------------- tables

HEADERS = [
    "Method", "Model", "Dataset", "Accuracy", "Acc.", "Params", "Time (s)", "F1", "Precision", "Recall",
    "Year", "Country", "Name", "Score", "Mean", "Std", "Median", "Min", "Max", "Baseline", "Size", "Loss",
    "Error", "Train", "Test", "Val", "Epochs", "Runtime", "Memory", "Speedup", "Setting", "Case", "Type",
    "Value", "Count", "Total", "Rate", "Price", "Region", "Group", "Sample", "Trial", "Step", "Iter.",
    "Naam", "Jaar", "Aantal", "Gemiddelde", "Totaal", "Prijs", "Resultaat", "Groep", "Tijd", "Waarde",
    "Acc. (\\%)", "Error (\\%)", "Time (ms)", "Latency (ms)", "Memory (GB)", "Area (km$^2$)", "Mass (kg)",
    "Speed (m/s)", "Price (\\$)", "Prijs (€)", "Temp. ($^\\circ$C)", "$n$", "$p$-value", "$R^2$", "BLEU",
    "Top-1", "Top-5", "mAP", "FLOPs", "Throughput", "Share (\\%)", "Growth (\\%)", "Score $\\uparrow$",
    "Error $\\downarrow$", "\\#Params", "\\# Layers",
]
GROUPS = [
    "CIFAR-10", "CIFAR-100", "ImageNet", "MNIST", "COCO", "SQuAD", "GLUE", "Train", "Test", "Validation",
    "Error", "Accuracy", "Time", "Men", "Women", "2023", "2024", "Before", "After", "Baseline", "Ours",
    "Small", "Large", "In-domain", "Out-of-domain", "Model A", "Model B", "Mannen", "Vrouwen", "Voor", "Na",
]
ROW_NAMES = [
    "Ours", "Baseline", "ResNet-50", "ViT-B/16", "BERT", "GPT-2", "LSTM", "CNN", "MLP", "SVM", "Random",
    "Linear", "Ridge", "Lasso", "k-NN", "Adam", "SGD", "Control", "Treatment", "Placebo", "Group A",
    "Group B", "Male", "Female", "Total", "Mean", "Overall", "France", "Japan", "Brazil", "Belgium",
    "Nederland", "Vlaanderen", "Q1", "Q2", "Q3", "Q4", "Small", "Medium", "Large", "Full", "None",
    "Ours (full)", "w/o attention", "+ augmentation", "Transformer", "XGBoost", "Logistic reg.", "Antwerpen",
    "Gent", "Leuven", "Brussel", "Amsterdam", "Utrecht", "Stage 1", "Stage 2", "Fold 1", "Fold 2",
]
NUMBER_STYLES = ["int", "float", "float", "pct", "pct_plain", "pm", "sci", "suffix"]


def number_cell(rng, style):
    """Returns (cell, is_math)."""
    kind = style["numbers"]
    d = style["decimals"]
    if kind == "int":
        v = rng.randint(0, 99999) if rng.random() < 0.7 else rng.randint(0, 99)
        s = f"{v:,}" if style["thousands"] and v >= 1000 else str(v)
    elif kind == "pct":
        s = f"{rng.uniform(0, 100):.{rng.choice([1, 2])}f}\\%"
    elif kind == "pct_plain":
        s = f"{rng.uniform(40, 99.9):.1f}"
    elif kind == "pm":
        return f"${rng.uniform(0, 100):.{d}f} \\pm {rng.uniform(0, 5):.{d}f}$", True
    elif kind == "sci":
        return f"${rng.uniform(1, 9.99):.2f} \\times 10^{{{rng.randint(-9, 9)}}}$", True
    elif kind == "suffix":
        s = f"{rng.uniform(0.1, 999):.1f}{rng.choice(['K', 'M', 'M', 'B', 'G', 'ms', 's', 'x'])}"
    else:
        s = f"{rng.uniform(-10 if style['negative'] else 0, 1000):.{d}f}"
    if s.startswith("-"):
        return (f"${s}$", True) if style["math_minus"] else (s, False)
    return s, False


def bold(cell, is_math):
    if is_math:
        return "$\\mathbf{" + cell[1:-1] + "}$"
    return "\\textbf{" + cell + "}"


def table_sample(src: Sources, rng: random.Random):
    cols = rng.randint(2, 7)
    rows = rng.randint(1, 9)
    rules = rng.choices(["booktabs", "grid", "minimal", "none", "firstcol"], [35, 25, 25, 5, 10])[0]
    shared = {"negative": rng.random() < 0.2, "math_minus": rng.random() < 0.6, "thousands": rng.random() < 0.4}
    one_style = rng.random() < 0.5
    base = rng.choice(NUMBER_STYLES)
    styles = [dict(shared, numbers=base if one_style else rng.choice(NUMBER_STYLES),
                   decimals=rng.choice([1, 2, 2, 3])) for _ in range(cols)]
    label_col = rng.random() < 0.8
    align = [rng.choice("lcr") if (i == 0 and label_col) else rng.choice("ccrrl") for i in range(cols)]
    if rules == "grid":
        spec = "|" + "|".join(align) + "|"
    elif rules == "firstcol":
        spec = align[0] + "|" + "".join(align[1:])
    else:
        spec = "".join(align)

    def text_cell():
        r = rng.random()
        if r < 0.12 and src.short:
            return "$" + rng.choice(src.short) + "$"
        if r < 0.25:
            return rng.choice(src.words).capitalize()
        return rng.choice(ROW_NAMES)

    header = [rng.choice(HEADERS) if rng.random() < 0.88 else "$" + rng.choice(src.short) + "$" for _ in range(cols)]
    if label_col and rng.random() < 0.25:
        header[0] = ""
    body = []
    for _ in range(rows):
        row = []
        for c in range(cols):
            if c == 0 and label_col:
                row.append(text_cell())
            elif rng.random() < 0.07:
                row.append(rng.choice(["", "--", "---", "n/a", "$-$", "--"]))
            elif rng.random() < 0.1:
                row.append(text_cell())
            else:
                row.append(number_cell(rng, styles[c]))
        body.append(row)
    # Bold the "best" value of some columns, as results tables do.
    for c in range(1 if label_col else 0, cols):
        cells = [(r, body[r][c]) for r in range(rows) if isinstance(body[r][c], tuple)]
        if cells and rng.random() < 0.3:
            r, (cell, is_math) = rng.choice(cells)
            body[r][c] = (bold(cell, is_math), is_math)
    body = [[cell[0] if isinstance(cell, tuple) else cell for cell in row] for row in body]

    top, mid, bottom = {"booktabs": ("\\toprule", "\\midrule", "\\bottomrule"),
                        "grid": ("\\hline", "\\hline", "\\hline"),
                        "minimal": ("\\hline", "\\hline", "\\hline"),
                        "firstcol": ("\\hline", "\\hline", "\\hline"),
                        "none": (None, None, None)}[rules]
    if rules == "minimal" and rng.random() < 0.3:
        top = bottom = None
    lines = [f"\\begin{{tabular}}{{{spec}}}"]
    if top:
        lines.append(top)
    bar = "|" if rules == "grid" else ""

    # Group header spanning columns, optionally with the first header cell spanning both header rows.
    if cols >= 3 and rules in ("booktabs", "minimal", "grid") and rng.random() < 0.35:
        start = 1 if label_col else 0
        spans, c = [], start
        cells = [""] * start
        tall_label = label_col and header[0] and rng.random() < 0.5
        if tall_label:
            cells[0] = f"\\multirow{{2}}{{*}}{{{header[0]}}}"
            header[0] = ""
        while c < cols:
            width = min(rng.choice([2, 2, 3]), cols - c)
            name = rng.choice(GROUPS)
            cells.append(f"\\multicolumn{{{width}}}{{c{bar}}}{{{name}}}" if width > 1 else name)
            if width > 1:
                spans.append((c + 1, c + width))
            c += width
        lines.append(" & ".join(cells) + " \\\\")
        if rules == "booktabs":
            lines.extend(f"\\cmidrule(lr){{{a}-{b}}}" for a, b in spans)
        elif rules == "grid" and not tall_label:
            lines.append("\\hline")
        else:
            lines.extend(f"\\cline{{{a}-{b}}}" for a, b in spans)
    lines.append(" & ".join(header) + " \\\\")
    if mid:
        lines.append(mid)

    # Row groups: the label column spans a few rows.
    groups = []
    if label_col and rows >= 4 and rng.random() < 0.25:
        r = 0
        while r < rows:
            k = min(rng.choice([2, 2, 3]), rows - r)
            groups.append((r, k))
            r += k
    group_rule = {"booktabs": rng.choice(["\\midrule", None]), "grid": "\\hline", "minimal": rng.choice(["\\hline", None]),
                  "firstcol": "\\hline", "none": None}[rules]
    if groups:
        names = [rng.choice(GROUPS + ROW_NAMES) for _ in groups]
        for (start, k), name in zip(groups, names):
            for j in range(k):
                row = body[start + j]
                row[0] = f"\\multirow{{{k}}}{{*}}{{{name}}}" if (j == 0 and k > 1) else (name if k == 1 else "")
                lines.append(" & ".join(row) + " \\\\")
                if j < k - 1 and rules == "grid":
                    lines.append(f"\\cline{{2-{cols}}}")
            if start + k < rows and group_rule:
                lines.append(group_rule)
    else:
        for i, row in enumerate(body):
            lines.append(" & ".join(row) + " \\\\")
            if rules == "grid" and i < len(body) - 1:
                lines.append("\\hline")
    if bottom:
        lines.append(bottom)
    lines.append("\\end{tabular}")
    return {"kind": "table", "latex": "\n".join(lines), "render": {}}


# ----------------------------------------------------------------------------- text


def sentences(abstract):
    """Splits on sentence ends outside $...$."""
    parts, cur, in_math = [], "", False
    i = 0
    while i < len(abstract):
        ch = abstract[i]
        cur += ch
        if ch == "$" and (i == 0 or abstract[i - 1] != "\\"):
            in_math = not in_math
        if not in_math and ch in ".?!" and i + 1 < len(abstract) and abstract[i + 1] == " ":
            parts.append(cur.strip())
            cur = ""
        i += 1
    if cur.strip():
        parts.append(cur.strip())
    return parts


def escape_outside_math(s):
    """Escapes % & # in prose; unescaped, % would start a comment and hide the rest of the line."""
    parts = re.split(r"(\$[^$]*\$)", s)
    for i in range(0, len(parts), 2):
        parts[i] = re.sub(r"(?<!\\)([%&#])", r"\\\1", parts[i])
    return "".join(parts)


def clean_text(s):
    s = s.replace("~", " ")
    s = re.sub(r"\\(cite|ref|eqref|label|footnote)\{[^{}]*\}", "", s)
    s = re.sub(r"\s+([.,;:])", r"\1", s)
    return escape_outside_math(re.sub(r"\s+", " ", s).strip())


def text_sample(src: Sources, rng: random.Random):
    ab = sentences(clean_text(rng.choice(src.abstracts)))
    if not ab:
        return None
    start = rng.randrange(len(ab))
    take = ab[start:start + rng.randint(1, 4)]
    r = rng.random()
    if r < 0.4:
        # One or two paragraphs.
        if len(take) >= 3 and rng.random() < 0.3:
            cut = rng.randint(1, len(take) - 1)
            latex = " ".join(take[:cut]) + "\n\n" + " ".join(take[cut:])
        else:
            latex = " ".join(take)
    elif r < 0.65:
        eq = rng.choice(src.medium)
        before = " ".join(take[:max(1, len(take) // 2)])
        after = " ".join(take[max(1, len(take) // 2):])
        latex = before + "\n\\[\n" + eq + "\n\\]\n" + after if after else before + "\n\\[\n" + eq + "\n\\]"
    elif r < 0.75:
        label = rng.choice(["Theorem", "Lemma", "Proposition", "Definition", "Corollary", "Remark", "Example",
                            "Stelling", "Definitie", "Opmerking"])
        num = rng.choice(["", f" {rng.randint(1, 9)}", f" {rng.randint(1, 9)}.{rng.randint(1, 20)}"])
        body = " ".join(take)
        if rng.random() < 0.5 and label not in ("Remark", "Example", "Opmerking"):
            body = "\\textit{" + body + "}"
        latex = f"\\textbf{{{label}{num}.}} " + body
    elif r < 0.9:
        items = ab[start:start + rng.randint(2, 5)]
        if len(items) < 2:
            items = ab[:2] if len(ab) >= 2 else items + items
        env = rng.choice(["itemize", "enumerate"])
        lead = (rng.choice(ab) + "\n") if rng.random() < 0.4 else ""
        latex = lead + f"\\begin{{{env}}}\n" + "\n".join("\\item " + s for s in items) + f"\n\\end{{{env}}}"
    elif r < 0.95:
        title = " ".join(rng.choice(src.words) for _ in range(rng.randint(1, 4))).capitalize()
        cmd = rng.choice(["section*", "subsection*"])
        latex = f"\\{cmd}{{{title}}}\n" + " ".join(take)
    else:
        eq = rng.choice(src.medium)
        latex = " ".join(take) + "\n\\begin{equation}\n" + eq + f" \\tag{{{rng.randint(1, 30)}}}\n\\end{{equation}}"
    width = rng.choice([7, 9, 11, 13, 15, 17])
    return {"kind": "text", "latex": latex, "render": {"width_cm": width}}


def none_sample(rng: random.Random):
    return {"kind": "none", "latex": "", "render": {"seed": rng.randrange(1 << 30)}}


def make(src: Sources, rng: random.Random, mix):
    kind = rng.choices(list(mix), list(mix.values()))[0]
    while True:
        if kind == "math":
            s = math_sample(src, rng)
        elif kind == "table":
            s = table_sample(src, rng)
        elif kind == "text":
            s = text_sample(src, rng)
        else:
            s = none_sample(rng)
        if s:
            return s
