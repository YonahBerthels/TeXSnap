// Scores transcriptions by what they render to, not by their spelling: "a ^ { 2 }" and "a^2" are equal.
// Usage: node score.js results/<model>.jsonl [--show]   (rows need kind, output, expected)
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const WEB = path.join(__dirname, "..", "Resources", "web");
const katex = require(path.join(WEB, "katex", "katex.min.js"));
// Semantic MathML only: layout details (heights, kerning) should not count as differences.
const renderToString = katex.renderToString;
katex.renderToString = (tex, opts) => renderToString(tex, Object.assign({}, opts, { output: "mathml" }));
globalThis.katex = katex;
require(path.join(WEB, "latexkit.js"));
const K = globalThis.LatexKit;
console.warn = () => {}; // KaTeX "No character metrics" noise

/** Strips output wrappers some models add (DocTags, code fences, math delimiters are handled by normalize). */
function clean(s) {
  return String(s || "")
    .replace(/<loc_\d+>/g, "")
    .replace(/<\/?(formula|doctag|text|otsl|code|page_header|section_header_level_\d+)>/g, "")
    .trim();
}

/** Rendered form as a token list: each tag (name + class) and each text character. */
function canon(kind, latex) {
  const n = K.normalize(kind, clean(latex));
  const problems = K.validate(n.kind, n.latex);
  let html;
  try {
    html = K.preview(n.kind, n.latex);
  } catch (e) {
    html = "";
  }
  html = html.replace(/<annotation[\s\S]*?<\/annotation>/g, "");
  const tokens = [];
  const re = /<\/?([a-zA-Z0-9]+)([^>]*)>|&[a-z#0-9]+;|[^<&\s]/g;
  let m;
  while ((m = re.exec(html))) {
    if (m[1]) {
      const cls = /class="([^"]*)"/.exec(m[2] || "");
      tokens.push((m[0][1] === "/" ? "/" : "") + m[1] + (cls ? "." + cls[1] : ""));
    } else {
      tokens.push(m[0]);
    }
  }
  return { tokens, valid: problems.length === 0, kind: n.kind };
}

function distance(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)));
    }
    prev = cur;
  }
  return prev[b.length];
}

function score(kind, output, expected) {
  const ref = canon(kind, expected);
  const hyp = canon(kind, output);
  const d = distance(ref.tokens, hyp.tokens);
  return {
    similarity: Math.max(0, 1 - d / Math.max(ref.tokens.length, 1)),
    identical: d === 0,
    valid: hyp.valid,
  };
}

module.exports = { score, canon };

if (require.main === module) {
  const file = process.argv[2];
  const show = process.argv.includes("--show");
  const rows = fs.readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  const byKind = {};
  let totalSeconds = 0;
  for (const r of rows) {
    const s = score(r.kind, r.output, r.expected);
    totalSeconds += r.seconds || 0;
    const k = (byKind[r.kind] = byKind[r.kind] || { n: 0, sim: 0, identical: 0, valid: 0 });
    k.n++;
    k.sim += s.similarity;
    k.identical += s.identical ? 1 : 0;
    k.valid += s.valid ? 1 : 0;
    if (show) {
      console.log(`${r.name.padEnd(22)} ${r.kind.padEnd(5)} sim=${s.similarity.toFixed(3)} ${s.identical ? "IDENTICAL" : ""}${s.valid ? "" : " INVALID"}`);
    }
  }
  let n = 0, sim = 0, identical = 0;
  for (const [kind, k] of Object.entries(byKind)) {
    const kindOK = rows.filter((r) => r.kind === kind && r.got_kind !== undefined);
    const kindNote = kindOK.length ? `  kind-correct=${kindOK.filter((r) => r.got_kind === kind).length}/${kindOK.length}` : "";
    console.log(`${kind.padEnd(6)} n=${String(k.n).padStart(3)}  similarity=${(k.sim / k.n).toFixed(3)}  renders-identical=${k.identical}/${k.n}  valid=${k.valid}/${k.n}${kindNote}`);
    n += k.n; sim += k.sim; identical += k.identical;
  }
  console.log(`ALL    n=${n}  similarity=${(sim / n).toFixed(3)}  renders-identical=${identical}/${n}  avg ${(totalSeconds / n).toFixed(2)} s/snip`);
}
