// Unit tests for Resources/web/latexkit.js.  Run: node --test Tests/latexkit.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
globalThis.katex = require(path.join(ROOT, "Resources/web/katex/katex.min.js"));
require(path.join(ROOT, "Resources/web/latexkit.js"));
const K = globalThis.LatexKit;

const formatMap = (kind, latex) => Object.fromEntries(K.formats(kind, latex).map((f) => [f.id, f.value]));

// ------------------------------------------------------------------ normalize

test("normalize strips math delimiters and display environments", () => {
  assert.deepEqual(K.normalize("math", "$$x^2$$"), { kind: "math", latex: "x^2" });
  assert.deepEqual(K.normalize("math", "\\[ x^2 \\]"), { kind: "math", latex: "x^2" });
  assert.deepEqual(K.normalize("math", "\\(x\\)"), { kind: "math", latex: "x" });
  assert.deepEqual(K.normalize("math", "$x$"), { kind: "math", latex: "x" });
  assert.deepEqual(K.normalize("math", "\\begin{equation}\nE = mc^2\n\\end{equation}"), { kind: "math", latex: "E = mc^2" });
  assert.deepEqual(K.normalize("math", "```latex\nx+1\n```"), { kind: "math", latex: "x+1" });
  assert.equal(K.normalize("math", "\\begin{align*} a &= b \\\\ c &= d \\end{align*}").latex,
    "\\begin{aligned}\na &= b \\\\ c &= d\n\\end{aligned}");
  assert.equal(K.normalize("math", "\\begin{gather} a \\\\ b \\end{gather}").latex, "\\begin{gathered}\na \\\\ b\n\\end{gathered}");
  assert.equal(K.normalize("math", "x \\label{eq:1} = 1").latex, "x = 1");
});

test("normalize keeps $...$ text that is not a single formula", () => {
  assert.equal(K.normalize("math", "$a$ and $b$").latex, "$a$ and $b$");
});

test("normalize moves per-line numbering to text and hoists a single tag", () => {
  const two = "\\begin{align} a &= b \\tag{1} \\\\ c &= d \\tag{2} \\end{align}";
  assert.deepEqual(K.normalize("math", two), { kind: "text", latex: two });
  assert.equal(K.normalize("math", "\\begin{aligned} a &= b \\\\ c &= d \\tag{2.1} \\end{aligned}").latex,
    "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned} \\tag{2.1}");
  assert.equal(K.normalize("math", "E = mc^2 \\tag{3.1}").latex, "E = mc^2 \\tag{3.1}");
});

test("normalize reduces table wrappers to the tabular", () => {
  const tab = "\\begin{tabular}{cc}\na & b \\\\\n\\end{tabular}";
  assert.deepEqual(K.normalize("table", "\\begin{table}[h]\n\\centering\n" + tab + "\n\\end{table}"), { kind: "table", latex: tab });
  const captioned = "\\begin{table}\n\\caption{Results}\n" + tab + "\n\\end{table}";
  assert.equal(K.normalize("table", captioned).kind, "text");
  assert.deepEqual(K.normalize("table", "\\left[\\begin{array}{cc} 1 & 2 \\end{array}\\right]").kind, "math");
});

test("normalize handles none, empty and unknown kinds", () => {
  assert.deepEqual(K.normalize("none", ""), { kind: "none", latex: "" });
  assert.deepEqual(K.normalize("math", "  "), { kind: "none", latex: "" });
  assert.equal(K.normalize("", "\\begin{tabular}{c} a \\end{tabular}").kind, "table");
  assert.equal(K.normalize("", "Let $x$ be a real number.").kind, "text");
  assert.equal(K.normalize("", "\\frac{a}{b}").kind, "math");
  assert.equal(K.normalize("text", "\\documentclass{article}\n\\usepackage{amsmath}\n\\begin{document}\nHi $x$\n\\end{document}").latex, "Hi $x$");
});

// ------------------------------------------------------------------ tabular parsing

test("parseTabular reads columns, rules, spans and escapes", () => {
  const t = K.parseTabular(String.raw`\begin{tabular}{|l|c|r|}
\hline
A & B \& C & 1,000 \\
\hline\hline
\multicolumn{2}{c|}{wide {x} cell} & $a \& b$ \\[2pt]
x & \multirow{2}{*}{tall} & z \\
\cline{1-1}
 &  & w \\
\hline
\end{tabular}`);
  assert.equal(t.ncols, 3);
  assert.deepEqual(t.columns.map((c) => c.align), ["l", "c", "r"]);
  assert.deepEqual(t.vrules, [1, 1, 1, 1]);
  assert.equal(t.rows.length, 4);
  assert.deepEqual(t.rows[0].rules.map((r) => r.type), ["hline"]);
  assert.deepEqual(t.rows[0].cells.map((c) => c.content), ["A", "B \\& C", "1,000"]);
  assert.deepEqual(t.rows[1].rules.map((r) => r.type), ["hline", "hline"]);
  assert.equal(t.rows[1].cells[0].colspan, 2);
  assert.equal(t.rows[1].cells[0].content, "wide {x} cell");
  assert.equal(t.rows[1].cells[1].content, "$a \\& b$");
  assert.equal(t.rows[1].cells[0].vright, 1);
  assert.equal(t.rows[2].cells[1].rowspan, 2);
  assert.equal(t.rows[2].cells[1].content, "tall");
  assert.deepEqual(t.rows[3].rules, [{ type: "cline", from: 1, to: 1 }]);
  assert.deepEqual(t.trailingRules.map((r) => r.type), ["hline"]);
});

test("parseTabular handles booktabs and column-spec shorthands", () => {
  const t = K.parseTabular(String.raw`\begin{tabular}{l*{2}{c}p{2cm}@{}}
\toprule
 & \multicolumn{2}{c}{Group} & \\
\cmidrule(lr){2-3}
a & b & c & d \\
\bottomrule
\end{tabular}`);
  assert.equal(t.ncols, 4);
  assert.deepEqual(t.columns.map((c) => c.align), ["l", "c", "c", "l"]);
  assert.deepEqual(t.rows[1].rules, [{ type: "cmidrule", from: 2, to: 3, trim: "lr" }]);
  assert.deepEqual(t.trailingRules.map((r) => r.type), ["bottomrule"]);
});

// ------------------------------------------------------------------ validation

test("validate accepts good LaTeX, including standard commands KaTeX lacks", () => {
  assert.deepEqual(K.validate("math", "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"), []);
  assert.deepEqual(K.validate("math", "\\mbox{if } x \\hdots y"), []);
  assert.deepEqual(K.validate("math", "x \\tag{2}"), []);
  assert.deepEqual(K.validate("text", "\\begin{align} a &= b \\tag{1} \\\\ c &= d \\tag{2} \\end{align}"), []);
  assert.deepEqual(K.validate("text", "Cost is \\$5 and 10\\%."), []);
  assert.deepEqual(K.validate("text", "\\begin{multline} a + b \\\\ = c \\end{multline}"), []);
  assert.deepEqual(K.validate("none", ""), []);
});

test("validate reports real errors", () => {
  const msg = (kind, latex) => K.validate(kind, latex).map((e) => e.message).join(" | ");
  assert.match(msg("math", "\\frac{1}{2"), /Missing closing brace/);
  assert.match(msg("math", "x}"), /Unmatched closing brace/);
  assert.match(msg("math", "\\foo x"), /Undefined control sequence: \\foo/);
  assert.match(msg("math", "\\begin{aligned} a \\end{gathered}"), /closed by/);
  assert.match(msg("math", "\\begin{aligned} a &= b \\tag{1} \\\\ c &= d \\tag{2} \\end{aligned}"), /only one \\tag/);
  assert.match(msg("text", "Let $x be"), /unbalanced \$/);
  assert.match(msg("text", "Then $\\frac{1}{$ holds"), /brace/);
  assert.match(msg("text", "Then $\\frac{1}{2}\\foo$ holds"), /math \$\\frac\{1\}\{2\}\\foo\$: Undefined control sequence/);
  assert.match(msg("table", "\\begin{tabular}{cc}\na & b & c \\\\\n\\end{tabular}"), /Row 1 has 3 cells/);
  assert.match(msg("table", "\\begin{tabular}{cc}\na & b \\\\\n[x] & y \\\\\n\\end{tabular}"), /optional argument/);
  assert.match(msg("table", "no table here"), /No tabular/);
  assert.match(msg("math", ""), /empty/);
});

// ------------------------------------------------------------------ formats

test("math formats", () => {
  const f = formatMap("math", "E = mc^2 \\tag{1}");
  assert.equal(f.latex, "E = mc^2 \\tag{1}");
  assert.equal(f.inline_dollar, "$E = mc^2$");
  assert.equal(f.display_dollar, "$$E = mc^2 \\tag{1}$$");
  assert.equal(f.display_bracket, "\\[\nE = mc^2 \\tag{1}\n\\]");
  assert.equal(f.inline_paren, "\\(E = mc^2\\)");
  assert.equal(f.equation, "\\begin{equation}\nE = mc^2 \\tag{1}\n\\end{equation}");
  assert.match(f.mathml, /^<math xmlns="http:\/\/www.w3.org\/1998\/Math\/MathML" display="block">/);
  assert.match(f.mathml, /<\/math>$/);
  const multi = formatMap("math", "\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}");
  assert.equal(multi.inline_dollar, "$\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}$");
  assert.equal(multi.display_dollar, "$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$");
});

test("table formats", () => {
  const src = String.raw`\begin{tabular}{|l|r|}
\hline
Item & Price (\$) \\
\hline
\textbf{Tea} & $1.50$ \\
Cake, large & $-2$ \\
Pipe | x & $93.6 \pm 0.2$ \\
\hline
\end{tabular}`;
  const f = formatMap("table", src);
  assert.equal(f.markdown, [
    "| Item | Price (\\$) |",
    "| :--- | ---: |",
    "| **Tea** | $1.50$ |",
    "| Cake, large | $-2$ |",
    "| Pipe \\| x | $93.6 \\pm 0.2$ |",
  ].join("\n"));
  assert.equal(f.tsv, "Item\tPrice ($)\nTea\t1.50\nCake, large\t-2\nPipe | x\t93.6 ± 0.2");
  assert.equal(f.csv, 'Item,Price ($)\nTea,1.50\n"Cake, large",-2\nPipe | x,93.6 ± 0.2');
  assert.match(f.html, /^<table class="tx-table"><tr><td style="text-align:left;border-top:1px solid #000;border-left:1px solid #000;border-right:1px solid #000">Item<\/td>/);
  assert.match(f.latex_booktabs, /\\toprule\nItem/);
  assert.match(f.latex_booktabs, /\\midrule\n\\textbf/);
  assert.match(f.latex_booktabs, /\\bottomrule\n\\end\{tabular\}/);
  assert.match(f.latex_booktabs, /\\begin\{tabular\}\{lr\}/);
  assert.equal(f.latex_hline, undefined);
});

test("booktabs tables get an \\hline variant and merged cells flatten", () => {
  const src = String.raw`\begin{tabular}{lcc}
\toprule
 & \multicolumn{2}{c}{Error} \\
\cmidrule(lr){2-3}
Model & Train & Test \\
\midrule
MLP & 0.05 & 0.09 \\
\bottomrule
\end{tabular}`;
  const f = formatMap("table", src);
  assert.equal(f.latex_hline, src.replace("\\toprule", "\\hline").replace("\\cmidrule(lr){2-3}", "\\cline{2-3}")
    .replace("\\midrule", "\\hline").replace("\\bottomrule", "\\hline"));
  assert.equal(f.tsv, "\tError\t\nModel\tTrain\tTest\nMLP\t0.05\t0.09");
  assert.equal(f.latex_booktabs, undefined);
});

test("text formats convert to Markdown", () => {
  const src = String.raw`\section*{Result}
Let $f$ be \textbf{continuous} and \emph{bounded}; then
\[ \int_a^b f(x)\,dx = 0. \]
\begin{enumerate}
\item First with $x$.
\item Second \& last.
\end{enumerate}`;
  const md = formatMap("text", src).markdown;
  assert.equal(md, [
    "## Result",
    "",
    "Let $f$ be **continuous** and *bounded*; then",
    "",
    "$$",
    "\\int_a^b f(x)\\,dx = 0.",
    "$$",
    "",
    "1. First with $x$.",
    "2. Second & last.",
  ].join("\n"));
});

test("plain-text conversion for spreadsheets", () => {
  assert.equal(K.mathToPlain("93.6 \\pm 0.2"), "93.6 ± 0.2");
  assert.equal(K.mathToPlain("x^2 + y_1"), "x² + y₁");
  assert.equal(K.mathToPlain("90^\\circ"), "90°");
  assert.equal(K.mathToPlain("\\frac{1}{2}"), "1/2");
  assert.equal(K.mathToPlain("\\mathbf{98.7 \\pm 0.1}"), "98.7 ± 0.1");
  assert.equal(K.mathToPlain("\\alpha \\leq \\beta"), "α ≤ β");
  assert.equal(K.mathToPlain("\\int_0^1 f"), "∫₀¹ f");
  assert.equal(K.mathToPlain("\\unknowncommand x"), null);
  assert.equal(K.cellToPlain("$-3.5$"), "-3.5");
  assert.equal(K.cellToPlain("Area (km$^2$)"), "Area (km²)");
  assert.equal(K.cellToPlain("$\\sqrt[3]{x}$"), "∛x");
  assert.equal(K.cellToPlain("$\\sqrt[5]{x}$"), "$\\sqrt[5]{x}$");
  assert.equal(K.cellToPlain("\\textbf{$x$ wins}"), "x wins");
});

test("packages", () => {
  assert.deepEqual(K.packages("\\mathbb{R} \\text{ and } \\mathscr{L}"), ["amsmath", "amssymb", "mathrsfs"]);
  assert.deepEqual(K.packages("\\begin{tabular}{c}\\toprule\\multirow{2}{*}{a}\\end{tabular}"), ["booktabs", "multirow"]);
  assert.deepEqual(K.packages("x^2"), []);
});

// ------------------------------------------------------------------ preview

test("preview renders math, tables and text", () => {
  assert.match(K.preview("math", "\\frac{a}{b}"), /class="katex-display"/);
  assert.match(K.preview("math", "\\frac{a}{b"), /tx-error/);
  const table = K.preview("table", String.raw`\begin{tabular}{|c|c|}
\hline
\multirow{2}{*}{A} & \multicolumn{1}{c|}{B} \\
 & $x^2$ \\
\hline
\end{tabular}`);
  assert.match(table, /rowspan="2"/);
  assert.match(table, /class="katex"/);
  assert.doesNotMatch(table, /tx-error/);
  const text = K.preview("text", "Caf\\'e costs \\$3 -- see ``quotes''.\n\n\\begin{itemize}\\item $a$\\end{itemize}");
  assert.match(text, /Café costs \$3 – see “quotes”\./);
  assert.match(text, /<ul><li>/);
  assert.match(K.preview("none", ""), /No math/);
});

// ------------------------------------------------------------------ real data: no false positives

test("every fixture's ground truth normalizes to itself and validates cleanly", () => {
  const dir = path.join(__dirname, "fixtures");
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".json"))) {
    const { kind, latex } = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    const n = K.normalize(kind, latex);
    assert.equal(n.kind, kind, file);
    assert.equal(n.latex, latex, file);
    assert.deepEqual(K.validate(kind, latex), [], file);
    const html = K.preview(kind, latex);
    assert.doesNotMatch(html, /tx-error|tx-cmd/, file);
    assert.ok(K.formats(kind, latex).length >= (kind === "none" ? 0 : 2), file);
  }
});

test("recorded model outputs validate cleanly", { skip: !process.env.TEXSNAP_RESULTS }, () => {
  for (const r of JSON.parse(fs.readFileSync(process.env.TEXSNAP_RESULTS, "utf8"))) {
    if (r.error) continue;
    const n = K.normalize(r.kind, r.latex);
    assert.deepEqual(K.validate(n.kind, n.latex), [], r.name);
    assert.doesNotMatch(K.preview(n.kind, n.latex), /tx-error|tx-cmd/, r.name);
  }
});

// ------------------------------------------------------------------ column count

test("normalize fixes a column specification that disagrees with every row", () => {
  const norm = (s) => K.normalize("table", s).latex;
  assert.equal(norm("\\begin{tabular}{rrrrr}\na & b & c & d \\\\\ne & f & g & h \\\\\n\\end{tabular}"),
    "\\begin{tabular}{rrrr}\na & b & c & d \\\\\ne & f & g & h \\\\\n\\end{tabular}");
  // Grids stay grids; a lone rule after the first column stays there.
  assert.match(norm("\\begin{tabular}{|c|c|c|}\na & b \\\\\n\\end{tabular}"), /\{\|c\|c\|\}/);
  assert.match(norm("\\begin{tabular}{l|c}\na & b & c \\\\\n\\end{tabular}"), /\{l\|cc\}/);
  // Multicolumn spans count; mixed widths and complex specs are left for the validator to report.
  assert.match(norm("\\begin{tabular}{ccc}\n\\multicolumn{2}{c}{x} \\\\\na & b \\\\\n\\end{tabular}"), /\{cc\}/);
  const ragged = "\\begin{tabular}{ccc}\na & b \\\\\na & b & c \\\\\n\\end{tabular}";
  assert.equal(norm(ragged), ragged);
  const para = "\\begin{tabular}{p{2cm}c}\na \\\\\n\\end{tabular}";
  assert.equal(norm(para), para);
  assert.deepEqual(K.validate("table", norm("\\begin{tabular}{rrrrr}\na & b & c & d \\\\\n\\end{tabular}")), []);
});
