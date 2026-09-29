// Keeps the formulas TeXSnap can render: normalized with LatexKit, valid in KaTeX, sensible length.
// Usage: node filter_formulas.js data/src/formulas_raw.txt data/formulas.jsonl
// Input: one JSON string per line. Output: {"latex": ...} per line, deduplicated.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const WEB = path.join(__dirname, "..", "Resources", "web");
globalThis.katex = require(path.join(WEB, "katex", "katex.min.js"));
require(path.join(WEB, "latexkit.js"));
const K = globalThis.LatexKit;

// Rewrites old or alias spellings to the form TeXSnap outputs, so each look has one target.
const ALIASES = [
  [/\{\\cal\s+([A-Za-z])\}/g, "\\mathcal{$1}"],
  [/\{\\bf\s+([^{}]+)\}/g, "\\mathbf{$1}"],
  [/\{\\rm\s+([^{}]+)\}/g, "\\mathrm{$1}"],
  [/\{\\it\s+([^{}]+)\}/g, "\\mathit{$1}"],
  [/\{\\mathbb\s+([A-Za-z])\}/g, "\\mathbb{$1}"],
  [/\\nonumber|\\notag/g, ""],
  [/\\label\{[^{}]*\}/g, ""],
  [/\\displaystyle\s*/g, ""],
  [/\\left\s+/g, "\\left"],
  [/\\right\s+/g, "\\right"],
  [/\\dfrac\b/g, "\\frac"],
];

// Things that render but that a screenshot cannot show, or that TeXSnap does not output.
const REJECT = /\\(tikz|begin\{tikzpicture|includegraphics|color|textcolor|colorbox|hspace|vspace|phantom|hphantom|vphantom|mathstrut|rule|raisebox|href|url|ref|eqref|cite|hbox|mbox|makebox|intertext|shortintertext|MoveEqLeft|newcommand|def)\b|\\\\\[|%/;

function tidy(s) {
  for (const [re, to] of ALIASES) s = s.replace(re, to);
  return s
    .replace(/\r/g, "")
    .replace(/[ \t]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{2,}/g, "\n")
    .trim();
}

async function main() {
  const [input, output] = process.argv.slice(2);
  const out = fs.createWriteStream(output);
  const seen = new Set();
  let total = 0, kept = 0;
  const reasons = {};
  const rl = readline.createInterface({ input: fs.createReadStream(input) });
  for await (const line of rl) {
    total++;
    let raw;
    try { raw = JSON.parse(line); } catch { continue; }
    const reject = (why) => { reasons[why] = (reasons[why] || 0) + 1; };
    if (REJECT.test(raw)) { reject("unsupported command"); continue; }
    const n = K.normalize("math", tidy(raw));
    if (n.kind !== "math") { reject("not a single formula"); continue; }
    const latex = tidy(n.latex);
    if (latex.length < 3 || latex.length > 500) { reject("length"); continue; }
    if (latex.split("\n").length > 8) { reject("too many lines"); continue; }
    if (K.validate("math", latex).length) { reject("katex error (custom macro etc.)"); continue; }
    const key = latex.replace(/\s+/g, "");
    if (seen.has(key)) { reject("duplicate"); continue; }
    seen.add(key);
    out.write(JSON.stringify({ latex }) + "\n");
    kept++;
  }
  out.end();
  console.log(`kept ${kept} of ${total}`);
  for (const [why, n] of Object.entries(reasons).sort((a, b) => b[1] - a[1])) console.log(`  ${why}: ${n}`);
}

main();
