// Normalizes samples with LatexKit (as the app does) and drops those the app would flag.
// Usage: node gen/validate.js in.jsonl out.jsonl
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const WEB = path.join(__dirname, "..", "..", "Resources", "web");
globalThis.katex = require(path.join(WEB, "katex", "katex.min.js"));
require(path.join(WEB, "latexkit.js"));
const K = globalThis.LatexKit;
console.warn = () => {}; // KaTeX's "No character metrics" noise

// pdflatex with T1 + utf8 handles Latin-1; stay inside it.
const SAFE = /^[\x09\x0a\x20-\x7e -ÿ–—‘’“”]*$/;

async function main() {
  const [input, output] = process.argv.slice(2);
  const out = fs.createWriteStream(output);
  const rl = readline.createInterface({ input: fs.createReadStream(input) });
  let kept = 0, total = 0;
  const why = {};
  const drop = (r) => { why[r] = (why[r] || 0) + 1; };
  for await (const line of rl) {
    total++;
    const s = JSON.parse(line);
    if (s.kind === "none") { out.write(line + "\n"); kept++; continue; }
    if (!SAFE.test(s.latex)) { drop("characters"); continue; }
    const n = K.normalize(s.kind, s.latex);
    if (n.kind !== s.kind) { drop(`kind ${s.kind}->${n.kind}`); continue; }
    let problems;
    try { problems = K.validate(n.kind, n.latex); } catch (e) { problems = [e.message]; }
    if (problems.length) { drop(`invalid ${s.kind}`); continue; }
    s.latex = n.latex;
    out.write(JSON.stringify(s) + "\n");
    kept++;
  }
  out.end();
  console.log(`valid ${kept}/${total}`, JSON.stringify(why));
}

main();
