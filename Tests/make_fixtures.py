#!/usr/bin/env python3
"""Render the recognition test fixtures (PNG + expected JSON) with pdflatex + Ghostscript.

Usage: python3 Tests/make_fixtures.py
Writes Tests/fixtures/<name>.png and Tests/fixtures/<name>.json.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")

PREAMBLE = r"""\documentclass[border=10pt,varwidth=%(width)s]{standalone}
\usepackage[T1]{fontenc}
\usepackage{amsmath,amssymb,bm,booktabs,multirow,xcolor,tikz}
%(extra)s
\begin{document}
%(colors)s
%(body)s
\end{document}
"""

MAXWELL = (r"\begin{aligned} \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\ "
           r"\nabla \cdot \mathbf{B} &= 0 \\ "
           r"\nabla \times \mathbf{E} &= -\frac{\partial \mathbf{B}}{\partial t} \\ "
           r"\nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t} \end{aligned}")
ALIGNED = (r"\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\ &= a^2 + ab + ba + b^2 \\ "
           r"&= a^2 + 2ab + b^2 \end{aligned}")

MATH = {
    "quadratic": r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}",
    "gaussian": r"\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}",
    "aligned": ALIGNED,
    "matrix": (r"A = \begin{pmatrix} a_{11} & a_{12} & \cdots & a_{1n} \\ a_{21} & a_{22} & \cdots & a_{2n} \\ "
               r"\vdots & \vdots & \ddots & \vdots \\ a_{m1} & a_{m2} & \cdots & a_{mn} \end{pmatrix}"),
    "cases": r"|x| = \begin{cases} x & \text{if } x \geq 0, \\ -x & \text{if } x < 0. \end{cases}",
    "binomial": r"P(X = k) = \binom{n}{k} p^k (1-p)^{n-k}, \quad k = 0, 1, \ldots, n",
    "maxwell": MAXWELL,
    "series": r"\lim_{n \to \infty} \sum_{k=1}^{n} \frac{1}{k^2} = \frac{\pi^2}{6}",
    "tagged": r"E = mc^2 \tag{3.1}",
    "greek": (r"\varepsilon_{ij} = \frac{1}{2}\left(\partial_i u_j + \partial_j u_i\right), \quad "
              r"\varphi(\vartheta) = \ell \cos\vartheta"),
    "stokes": (r"\oint_{\partial \Sigma} \mathbf{F} \cdot d\mathbf{r} = "
               r"\iint_{\Sigma} (\nabla \times \mathbf{F}) \cdot d\mathbf{S}"),
    "schrodinger": (r"i\hbar \frac{\partial}{\partial t} \Psi(\mathbf{r}, t) = \left[ -\frac{\hbar^2}{2m} \nabla^2 "
                    r"+ V(\mathbf{r}, t) \right] \Psi(\mathbf{r}, t)"),
    "set_builder": r"\mathbb{Q} = \left\{ \frac{p}{q} : p \in \mathbb{Z},\ q \in \mathbb{N} \setminus \{0\} \right\}",
    "optimization": (r"\begin{aligned} \min_{x \in \mathbb{R}^n} \quad & \frac{1}{2} x^\top Q x + c^\top x \\ "
                     r"\text{s.t.} \quad & Ax \leq b, \\ & x \geq 0. \end{aligned}"),
    "navier_stokes": (r"\rho \left( \frac{\partial \mathbf{u}}{\partial t} + (\mathbf{u} \cdot \nabla) \mathbf{u} \right) "
                      r"= -\nabla p + \mu \nabla^2 \mathbf{u} + \mathbf{f}"),
    "taylor": (r"f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!} (x-a)^n = f(a) + f'(a)(x-a) "
               r"+ \frac{f''(a)}{2!} (x-a)^2 + \cdots"),
    "variance": (r"\begin{aligned} \operatorname{Var}(X) &= \mathbb{E}\left[(X - \mathbb{E}[X])^2\right] \\ "
                 r"&= \mathbb{E}\left[X^2 - 2X\,\mathbb{E}[X] + \mathbb{E}[X]^2\right] \\ "
                 r"&= \mathbb{E}[X^2] - 2\,\mathbb{E}[X]\,\mathbb{E}[X] + \mathbb{E}[X]^2 \\ "
                 r"&= \mathbb{E}[X^2] - \mathbb{E}[X]^2 \end{aligned}"),
    "augmented": (r"\left[ \begin{array}{ccc|c} 1 & -2 & 3 & 9 \\ -1 & 3 & 0 & -4 \\ 2 & -5 & 5 & 17 "
                  r"\end{array} \right]"),
    "continued_fraction": r"\phi = 1 + \cfrac{1}{1 + \cfrac{1}{1 + \cfrac{1}{1 + \cdots}}}",
    "fourier": r"\hat{f}(\xi) = \int_{-\infty}^{\infty} f(x)\, e^{-2\pi i x \xi}\,dx",
    "bold_greek": (r"\boldsymbol{\mu} = \mathbb{E}[\mathbf{x}], \quad \boldsymbol{\Sigma} = "
                   r"\mathbb{E}\left[(\mathbf{x} - \boldsymbol{\mu})(\mathbf{x} - \boldsymbol{\mu})^\top\right]"),
    "softmax_ce": (r"\mathcal{L}(\theta) = -\frac{1}{N} \sum_{i=1}^{N} \sum_{c=1}^{C} y_{i,c} \log "
                   r"\frac{\exp(z_{i,c} / \tau)}{\sum_{c'=1}^{C} \exp(z_{i,c'} / \tau)}"),
}

TABLE_GRID = r"""\begin{tabular}{|l|c|r|r|}
\hline
Country & Code & Population & Area (km$^2$) \\
\hline
France & FR & 68,042,591 & 643,801 \\
Japan & JP & 124,516,650 & 377,975 \\
Brazil & BR & 203,062,512 & 8,515,767 \\
\hline
\end{tabular}"""

TABLES = {
    "table_grid": TABLE_GRID,
    "table_booktabs": r"""\begin{tabular}{lcccc}
\toprule
 & \multicolumn{2}{c}{CIFAR-10} & \multicolumn{2}{c}{ImageNet} \\
\cmidrule(lr){2-3} \cmidrule(lr){4-5}
Method & Acc. (\%) & Params & Acc. (\%) & Params \\
\midrule
ResNet-50 & $93.6 \pm 0.2$ & 25.6M & 76.1 & 25.6M \\
ViT-B/16 & $98.1 \pm 0.1$ & 86.6M & 81.8 & 86.6M \\
Ours & $\mathbf{98.7 \pm 0.1}$ & 22.1M & \textbf{83.2} & 22.1M \\
\bottomrule
\end{tabular}""",
    "table_multirow": r"""\begin{tabular}{|c|c|c|}
\hline
\multirow{2}{*}{Model} & \multicolumn{2}{c|}{Error} \\
\cline{2-3}
 & Train & Test \\
\hline
Linear & 0.12 & 0.15 \\
MLP & 0.05 & 0.09 \\
\hline
\end{tabular}""",
    "table_large": r"""\begin{tabular}{lrrrrr}
\hline
Year & Q1 & Q2 & Q3 & Q4 & Total \\
\hline
2018 & 1,204.5 & 1,318.2 & 1,297.9 & 1,455.0 & 5,275.6 \\
2019 & 1,387.1 & 1,402.6 & 1,511.3 & 1,623.8 & 5,924.8 \\
2020 & 1,102.4 & 874.9 & 1,236.0 & 1,498.7 & 4,712.0 \\
2021 & 1,566.3 & 1,690.1 & 1,742.5 & 1,901.2 & 6,900.1 \\
2022 & 1,834.0 & 1,912.7 & 1,988.4 & 2,105.6 & 7,840.7 \\
2023 & 2,011.9 & 2,087.3 & 2,143.8 & 2,290.4 & 8,533.4 \\
2024 & 2,198.6 & 2,254.1 & 2,337.0 & 2,461.9 & 9,251.6 \\
\hline
\end{tabular}""",
}

TEXTS = {
    "text_paragraph": r"""Let $f\colon [a,b] \to \mathbb{R}$ be continuous. Then there exists $c \in (a,b)$ such that
\[ \int_a^b f(x)\,dx = f(c)\,(b-a). \]
This is the \emph{mean value theorem for integrals}; it follows from the extreme value theorem applied to $f$ on $[a,b]$.""",
    "text_theorem": r"""\textbf{Theorem 2.1.} \textit{Let $G$ be a finite group and $H \leq G$ a subgroup. Then $|H|$ divides $|G|$, and}
\[ [G : H] = \frac{|G|}{|H|}. \]""",
    "text_list": r"""\textbf{Assumptions.} We assume the following:
\begin{enumerate}
\item The errors $\varepsilon_i$ are independent with $\mathbb{E}[\varepsilon_i] = 0$.
\item The variance $\sigma^2 = \operatorname{Var}(\varepsilon_i)$ is constant for all $i$.
\item The design matrix $X \in \mathbb{R}^{n \times p}$ has full column rank.
\end{enumerate}""",
    "text_align_tags": r"""\begin{align}
\nabla \cdot \mathbf{D} &= \rho_f \tag{1.1} \\
\nabla \times \mathbf{H} &= \mathbf{J}_f + \frac{\partial \mathbf{D}}{\partial t} \tag{1.2}
\end{align}""",
}

SANS = r"\usepackage[scaled]{helvet}\renewcommand{\familydefault}{\sfdefault}"

# (name, kind, expected latex, document body, dpi, width, dark, extra preamble)
FIXTURES = []
for name, latex in MATH.items():
    FIXTURES.append((name, "math", latex, r"\[ %s \]" % latex, 200, "16cm", False, ""))
FIXTURES.append(("maxwell_lowres", "math", MAXWELL, r"\[ %s \]" % MAXWELL, 80, "16cm", False, ""))
# Tiny renders, like a non-Retina screenshot of small print.
FIXTURES.append(("tiny_softmax", "math", MATH["softmax_ce"], r"\[ %s \]" % MATH["softmax_ce"], 60, "16cm", False, ""))
FIXTURES.append(("tiny_variance", "math", MATH["variance"], r"\[ %s \]" % MATH["variance"], 60, "16cm", False, ""))
FIXTURES.append(("dark_aligned", "math", ALIGNED, r"\[ %s \]" % ALIGNED, 150, "16cm", True, ""))
for name, latex in TABLES.items():
    FIXTURES.append((name, "table", latex, latex, 200, "18cm", False, ""))
FIXTURES.append(("table_lowres", "table", TABLE_GRID, TABLE_GRID, 80, "18cm", False, ""))
FIXTURES.append(("tiny_table", "table", TABLES["table_booktabs"], TABLES["table_booktabs"], 70, "18cm", False, ""))
for name, latex in TEXTS.items():
    FIXTURES.append((name, "text", latex, latex, 200, "12cm", False, ""))
SANS_TEXT = (r"Gradient descent updates the parameters by $\theta_{t+1} = \theta_t - \eta \nabla_\theta L(\theta_t)$, "
             r"where $\eta > 0$ is the learning rate.")
FIXTURES.append(("text_sans", "text", SANS_TEXT, SANS_TEXT, 200, "12cm", False, SANS))
FIXTURES.append(("none_drawing", "none", "",
                 r"\begin{tikzpicture}\fill[blue!40] (0,0) circle (1); \fill[orange!60] (1.6,-0.9) rectangle (3.2,0.9);"
                 r"\end{tikzpicture}", 150, "10cm", False, ""))


def render(name, body, dpi, width, dark, extra, workdir):
    colors = r"\pagecolor[HTML]{1E1E1E}\color{white}" if dark else ""
    tex = PREAMBLE % {"width": width, "colors": colors, "body": body, "extra": extra}
    tex_path = os.path.join(workdir, name + ".tex")
    with open(tex_path, "w") as f:
        f.write(tex)
    r = subprocess.run(["pdflatex", "-interaction=nonstopmode", "-halt-on-error",
                        "-output-directory", workdir, tex_path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"pdflatex failed for {name}:\n{r.stdout[-2000:]}")
    png = os.path.join(OUT, name + ".png")
    subprocess.run(["gs", "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=png16m", f"-r{dpi}",
                    "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4", f"-sOutputFile={png}",
                    os.path.join(workdir, name + ".pdf")], check=True)
    return png


def main():
    os.makedirs(OUT, exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="texsnap-fixtures-")
    try:
        for name, kind, latex, body, dpi, width, dark, extra in FIXTURES:
            render(name, body, dpi, width, dark, extra, workdir)
            with open(os.path.join(OUT, name + ".json"), "w") as f:
                json.dump({"kind": kind, "latex": latex}, f, indent=2)
            print(f"rendered {name} ({kind}, {dpi} dpi{', dark' if dark else ''})")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
