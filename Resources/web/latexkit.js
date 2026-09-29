/*
 * LatexKit: pure functions shared by TeXSnap's preview (WKWebView) and format engine (JavaScriptCore).
 * Needs the global `katex`; never touches the DOM.
 *
 *   LatexKit.normalize(kind, latex)  -> {kind, latex}        clean up a model transcription
 *   LatexKit.validate(kind, latex)   -> [{message, repairable}]
 *   LatexKit.preview(kind, latex)    -> HTML string
 *   LatexKit.formats(kind, latex)    -> [{id, label, value}]
 *   LatexKit.packages(latex)         -> ["amsmath", ...]
 *   LatexKit.parseTabular(src)       -> table model (exposed for tests)
 */
(function (root) {
  "use strict";

  // ------------------------------------------------------------------ scanning

  function isLetter(ch) {
    return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z");
  }

  function skipSpaces(src, i) {
    while (i < src.length && /\s/.test(src[i])) i++;
    return i;
  }

  // At src[i] === "\\": returns {name, end}. Control words are letters; control symbols a single char.
  function readCommand(src, i) {
    let j = i + 1;
    if (j >= src.length) return { name: "", end: j };
    if (isLetter(src[j])) {
      while (j < src.length && isLetter(src[j])) j++;
      return { name: src.slice(i + 1, j), end: j };
    }
    return { name: src[j], end: j + 1 };
  }

  // At src[i] === open: returns {content, end} with end just past the matching close, or null.
  function readBalanced(src, i, open, close) {
    let depth = 0;
    for (let j = i; j < src.length; j++) {
      const ch = src[j];
      if (ch === "\\") { j++; continue; }
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
      if (open !== "{" && depth === 0) {
        if (ch === open && j === i) continue;
        if (ch === close) return { content: src.slice(i + 1, j), end: j + 1 };
      } else if (open === "{" && depth === 0 && ch === "}") {
        return { content: src.slice(i + 1, j), end: j + 1 };
      }
      if (depth < 0) return null;
    }
    return null;
  }

  function readGroup(src, i) {
    return src[i] === "{" ? readBalanced(src, i, "{", "}") : null;
  }

  // Reads a mandatory argument: a {group}, a control sequence, or one character.
  function readArg(src, i) {
    i = skipSpaces(src, i);
    if (i >= src.length) return null;
    if (src[i] === "{") return readGroup(src, i);
    if (src[i] === "\\") {
      const c = readCommand(src, i);
      return { content: src.slice(i, c.end), end: c.end };
    }
    return { content: src[i], end: i + 1 };
  }

  function readOptional(src, i, open, close) {
    open = open || "[";
    close = close || "]";
    const j = skipSpaces(src, i);
    if (src[j] !== open) return null;
    return readBalanced(src, j, open, close);
  }

  // Removes TeX comments (an unescaped % up to and including the newline and the next line's indent).
  function stripComments(src) {
    let out = "";
    for (let i = 0; i < src.length; i++) {
      const ch = src[i];
      if (ch === "\\") {
        out += ch + (i + 1 < src.length ? src[i + 1] : "");
        i++;
        continue;
      }
      if (ch === "%") {
        while (i < src.length && src[i] !== "\n") i++;
        while (i + 1 < src.length && (src[i + 1] === " " || src[i + 1] === "\t")) i++;
        continue;
      }
      out += ch;
    }
    return out;
  }

  // Index of the \end{name} matching a \begin{name} whose body starts at `from`; returns {start, end} or null.
  function findEnvEnd(src, from, name) {
    let depth = 1;
    let i = from;
    while (i < src.length) {
      const ch = src[i];
      if (ch === "\\") {
        const c = readCommand(src, i);
        if (c.name === "begin" || c.name === "end") {
          const g = readGroup(src, skipSpaces(src, c.end));
          if (g && g.content.trim() === name) {
            depth += c.name === "begin" ? 1 : -1;
            if (depth === 0) return { start: i, end: g.end };
          }
          i = g ? g.end : c.end;
          continue;
        }
        i = c.end;
        continue;
      }
      i++;
    }
    return null;
  }

  function escapeHTML(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // ------------------------------------------------------------------ KaTeX

  function gobble(n) {
    return function (context) {
      context.consumeArgs(n);
      return "";
    };
  }

  // Standard LaTeX that KaTeX lacks, mapped to a close rendering so it neither fails validation nor preview.
  function compatMacros() {
    return {
      "\\mbox": "\\text{#1}",
      "\\hdots": "\\ldots",
      "\\iddots": "\\mathinner{\\unicode{x22F0}}",
      "\\textsuperscript": "^{\\text{#1}}",
      "\\textsubscript": "_{\\text{#1}}",
      "\\intertext": "\\text{#1}\\\\",
      "\\shortintertext": "\\text{#1}\\\\",
      "\\eqref": "(\\text{#1})",
      "\\ref": "\\text{#1}",
      "\\label": gobble(1),
      "\\qedhere": "",
      "\\mathds": "\\mathbb{#1}",
      "\\mathbbm": "\\mathbb{#1}",
      "\\unicode": function (context) {
        const arg = context.consumeArgs(1)[0].reverse().map(function (t) { return t.text; }).join("");
        const code = /^x/i.test(arg) ? parseInt(arg.slice(1), 16) : parseInt(arg, 10);
        return "\\text{" + String.fromCodePoint(code) + "}";
      },
    };
  }

  function katexOptions(displayMode, extra) {
    const o = { displayMode: displayMode, throwOnError: true, strict: "ignore", trust: false, macros: compatMacros() };
    for (const k in extra || {}) o[k] = extra[k];
    return o;
  }

  function katexError(e) {
    return String((e && e.message) || e).replace(/^KaTeX parse error: /, "");
  }

  function renderMath(latex, displayMode) {
    const k = root.katex;
    try {
      return k.renderToString(latex, katexOptions(displayMode, { output: "html" }));
    } catch (e) {
      return '<span class="tx-error" title="' + escapeHTML(katexError(e)) + '">' + escapeHTML(latex) + "</span>";
    }
  }

  function checkMath(latex, displayMode) {
    try {
      root.katex.renderToString(latex, katexOptions(displayMode, { output: "html" }));
      return null;
    } catch (e) {
      return katexError(e);
    }
  }

  function mathML(latex, displayMode) {
    try {
      const html = root.katex.renderToString(latex, katexOptions(displayMode, { output: "mathml" }));
      const m = html.match(/<math[\s\S]*<\/math>/);
      return m ? m[0] : null;
    } catch (e) {
      return null;
    }
  }

  // Display environments KaTeX cannot parse, rewritten to ones it can.
  function katexDisplaySource(env, body) {
    switch (env) {
      case "multline": case "multline*":
        return "\\begin{gathered}" + body + "\\end{gathered}";
      case "flalign": case "flalign*":
        return "\\begin{align*}" + body + "\\end{align*}";
      case "eqnarray": case "eqnarray*":
        return "\\begin{align*}" + body.replace(/&\s*([=<>]|\\[a-zA-Z]+)\s*&/g, "&$1 ") + "\\end{align*}";
      case "displaymath": case "math":
        return body;
      default:
        return "\\begin{" + env + "}" + body + "\\end{" + env + "}";
    }
  }

  // ------------------------------------------------------------------ segmenting text-mode LaTeX

  const DISPLAY_ENVS = ["equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*",
    "flalign", "flalign*", "alignat", "alignat*", "eqnarray", "eqnarray*", "displaymath", "math"];
  const LIST_ENVS = ["itemize", "enumerate", "description"];
  const TABLE_ENVS = ["tabular", "tabular*", "tabularx", "array"];
  const WRAPPER_ENVS = ["table", "table*", "center", "flushleft", "flushright", "minipage", "figure", "figure*",
    "quote", "quotation", "abstract", "theorem", "lemma", "proposition", "corollary", "definition", "remark",
    "example", "proof", "note", "claim", "conjecture", "exercise", "solution"];

  // Splits text-mode LaTeX into inline pieces: {type: "text"|"math", value, display}.
  function splitInline(src) {
    const out = [];
    let buf = "";
    let i = 0;
    const flush = function () {
      if (buf) out.push({ type: "text", value: buf });
      buf = "";
    };
    while (i < src.length) {
      const ch = src[i];
      if (ch === "\\") {
        const next = src[i + 1];
        if (next === "(" || next === "[") {
          const close = next === "(" ? "\\)" : "\\]";
          const end = src.indexOf(close, i + 2);
          if (end >= 0) {
            flush();
            out.push({ type: "math", value: src.slice(i + 2, end), display: next === "[" });
            i = end + 2;
            continue;
          }
        }
        buf += ch + (next !== undefined ? next : "");
        i += 2;
        continue;
      }
      if (ch === "$") {
        const display = src[i + 1] === "$";
        const open = display ? 2 : 1;
        let j = i + open;
        let end = -1;
        while (j < src.length) {
          if (src[j] === "\\") { j += 2; continue; }
          if (src[j] === "$") {
            if (display) {
              if (src[j + 1] === "$") { end = j; break; }
            } else { end = j; break; }
          }
          j++;
        }
        if (end >= 0) {
          flush();
          out.push({ type: "math", value: src.slice(i + open, end), display: display });
          i = end + open;
          continue;
        }
        out.push({ type: "unbalanced", value: src.slice(i) });
        buf = "";
        i = src.length;
        continue;
      }
      buf += ch;
      i++;
    }
    flush();
    return out;
  }

  // Splits a text-mode document fragment into blocks.
  //   {type: "para", src} {type: "display", env, body} {type: "list", env, items:[{label, src}]}
  //   {type: "table", src} {type: "heading", level, src} {type: "wrapper", env, src} {type: "verbatim", src}
  function splitBlocks(src) {
    const blocks = [];
    let para = "";
    const flushPara = function () {
      const parts = para.split(/\n\s*\n/);
      for (const p of parts) if (p.trim()) blocks.push({ type: "para", src: p.trim() });
      para = "";
    };
    let i = 0;
    while (i < src.length) {
      const ch = src[i];
      if (ch === "\\") {
        const c = readCommand(src, i);
        if (c.name === "[") {
          const end = src.indexOf("\\]", c.end);
          if (end >= 0) {
            flushPara();
            blocks.push({ type: "display", env: null, body: src.slice(c.end, end) });
            i = end + 2;
            continue;
          }
        }
        if (c.name === "begin") {
          const g = readGroup(src, skipSpaces(src, c.end));
          if (g) {
            const env = g.content.trim();
            const close = findEnvEnd(src, g.end, env);
            if (close) {
              let body = src.slice(g.end, close.start);
              if (DISPLAY_ENVS.indexOf(env) >= 0) {
                flushPara();
                if (env === "alignat" || env === "alignat*") {
                  const n = readGroup(body, skipSpaces(body, 0));
                  const full = "\\begin{" + env + "}" + body + "\\end{" + env + "}";
                  blocks.push({ type: "display", env: env, body: body, katexSource: full, cols: n && n.content });
                } else {
                  blocks.push({ type: "display", env: env, body: body });
                }
                i = close.end;
                continue;
              }
              if (LIST_ENVS.indexOf(env) >= 0) {
                flushPara();
                blocks.push({ type: "list", env: env, items: splitItems(body) });
                i = close.end;
                continue;
              }
              if (TABLE_ENVS.indexOf(env) >= 0) {
                flushPara();
                blocks.push({ type: "table", src: src.slice(i, close.end) });
                i = close.end;
                continue;
              }
              if (env === "verbatim") {
                flushPara();
                blocks.push({ type: "verbatim", src: body.replace(/^\n/, "") });
                i = close.end;
                continue;
              }
              flushPara();
              blocks.push({ type: "wrapper", env: env, src: body });
              i = close.end;
              continue;
            }
          }
        }
        const heading = { part: 1, chapter: 1, section: 2, subsection: 3, subsubsection: 4, paragraph: 5, subparagraph: 5 };
        if (heading[c.name] !== undefined) {
          let j = c.end;
          if (src[j] === "*") j++;
          const opt = readOptional(src, j);
          if (opt) j = opt.end;
          const g = readGroup(src, skipSpaces(src, j));
          if (g) {
            flushPara();
            blocks.push({ type: "heading", level: heading[c.name], src: g.content });
            i = g.end;
            continue;
          }
        }
        para += src.slice(i, c.end);
        i = c.end;
        continue;
      }
      if (ch === "$" && src[i + 1] === "$") {
        const end = src.indexOf("$$", i + 2);
        if (end >= 0) {
          flushPara();
          blocks.push({ type: "display", env: null, body: src.slice(i + 2, end) });
          i = end + 2;
          continue;
        }
      }
      if (ch === "$") {
        // keep inline math intact so a "$$" search never starts inside it
        let j = i + 1;
        while (j < src.length && src[j] !== "$") j += src[j] === "\\" ? 2 : 1;
        para += src.slice(i, Math.min(j + 1, src.length));
        i = j + 1;
        continue;
      }
      para += ch;
      i++;
    }
    flushPara();
    return blocks;
  }

  // Splits a list body at top-level \item commands.
  function splitItems(body) {
    const items = [];
    let depth = 0;
    let envDepth = 0;
    let current = null;
    let i = 0;
    let start = 0;
    while (i < body.length) {
      const ch = body[i];
      if (ch === "\\") {
        const c = readCommand(body, i);
        if (c.name === "begin") envDepth++;
        else if (c.name === "end") envDepth--;
        else if (c.name === "item" && depth === 0 && envDepth === 0) {
          if (current) current.src = body.slice(start, i).trim();
          let j = c.end;
          const opt = readOptional(body, j);
          current = { label: opt ? opt.content : null, src: "" };
          if (opt) j = opt.end;
          items.push(current);
          start = j;
          i = j;
          continue;
        }
        i = c.end;
        continue;
      }
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
      i++;
    }
    if (current) current.src = body.slice(start).trim();
    return items;
  }

  // ------------------------------------------------------------------ tabular

  function parseColSpec(spec) {
    const columns = [];
    const vrules = [0];
    let i = 0;
    let guard = 0;
    while (i < spec.length && guard++ < 10000) {
      const ch = spec[i];
      if (/\s/.test(ch)) { i++; continue; }
      if (ch === "|") { vrules[vrules.length - 1]++; i++; continue; }
      if (ch === "l" || ch === "c" || ch === "r") {
        columns.push({ align: ch });
        vrules.push(0);
        i++;
        continue;
      }
      if (ch === "p" || ch === "m" || ch === "b") {
        const g = readGroup(spec, skipSpaces(spec, i + 1));
        columns.push({ align: "l" });
        vrules.push(0);
        i = g ? g.end : i + 1;
        continue;
      }
      if (ch === "X" || ch === "S" || ch === "L" || ch === "C" || ch === "R") {
        columns.push({ align: ch === "X" || ch === "L" ? "l" : ch === "R" ? "r" : "c" });
        vrules.push(0);
        const opt = readOptional(spec, i + 1);
        i = opt ? opt.end : i + 1;
        continue;
      }
      if (ch === "@" || ch === "!" || ch === ">" || ch === "<") {
        const g = readGroup(spec, skipSpaces(spec, i + 1));
        i = g ? g.end : i + 1;
        continue;
      }
      if (ch === "*") {
        const n = readGroup(spec, skipSpaces(spec, i + 1));
        const s = n && readGroup(spec, skipSpaces(spec, n.end));
        if (n && s) {
          const count = Math.max(0, Math.min(100, parseInt(n.content, 10) || 0));
          spec = spec.slice(0, i) + s.content.repeat(count) + spec.slice(s.end);
          continue;
        }
        i++;
        continue;
      }
      if (ch === "\\") {
        i = readCommand(spec, i).end;
        continue;
      }
      i++;
    }
    return { columns: columns, vrules: vrules };
  }

  // Splits a tabular body at top-level \\ (rows) and & (cells).
  function splitRows(body) {
    const rows = [];
    let cells = [];
    let cur = "";
    let depth = 0;
    let envDepth = 0;
    let i = 0;
    while (i < body.length) {
      const ch = body[i];
      if (ch === "\\") {
        const c = readCommand(body, i);
        if (depth === 0 && envDepth === 0 && (c.name === "\\" || c.name === "tabularnewline")) {
          let j = c.end;
          if (body[j] === "*") j++;
          const opt = readOptional(body, j);
          if (opt && /^\s*-?[\d.]+\s*[a-z]{2}\s*$/.test(opt.content)) j = opt.end;
          cells.push(cur);
          rows.push(cells);
          cells = [];
          cur = "";
          i = j;
          continue;
        }
        if (c.name === "begin") envDepth++;
        else if (c.name === "end") envDepth--;
        cur += body.slice(i, c.end);
        i = c.end;
        continue;
      }
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
      else if (ch === "&" && depth === 0 && envDepth === 0) {
        cells.push(cur);
        cur = "";
        i++;
        continue;
      }
      cur += ch;
      i++;
    }
    cells.push(cur);
    rows.push(cells);
    return rows;
  }

  function parseRange(s) {
    const m = /^\s*(\d+)\s*-\s*(\d+)\s*$/.exec(s || "");
    return m ? { from: parseInt(m[1], 10), to: parseInt(m[2], 10) } : null;
  }

  // Pulls rule commands off the front of a row: {rules, rest}.
  function leadingRules(text) {
    const rules = [];
    let i = 0;
    for (;;) {
      i = skipSpaces(text, i);
      if (text[i] !== "\\") break;
      const c = readCommand(text, i);
      if (c.name === "hline" || c.name === "toprule" || c.name === "midrule" || c.name === "bottomrule") {
        let j = c.end;
        if (c.name !== "hline") {
          const opt = readOptional(text, j);
          if (opt) j = opt.end;
        }
        rules.push({ type: c.name });
        i = j;
      } else if (c.name === "cline") {
        const a = readArg(text, c.end);
        const r = a && parseRange(a.content);
        rules.push({ type: "cline", from: r ? r.from : 1, to: r ? r.to : 1 });
        i = a ? a.end : c.end;
      } else if (c.name === "cmidrule") {
        let j = c.end;
        const w = readOptional(text, j);
        if (w) j = w.end;
        const trim = readOptional(text, j, "(", ")");
        if (trim) j = trim.end;
        const a = readArg(text, j);
        const r = a && parseRange(a.content);
        rules.push({ type: "cmidrule", from: r ? r.from : 1, to: r ? r.to : 1, trim: trim ? trim.content : "" });
        i = a ? a.end : j;
      } else if (c.name === "addlinespace" || c.name === "noalign" || c.name === "hhline" || c.name === "morecmidrules") {
        let j = c.end;
        const opt = readOptional(text, j);
        if (opt) j = opt.end;
        if (c.name !== "addlinespace" && c.name !== "morecmidrules") {
          const a = readArg(text, j);
          if (a) j = a.end;
        }
        i = j;
      } else if (c.name === "rowcolor") {
        let j = c.end;
        const opt = readOptional(text, j);
        if (opt) j = opt.end;
        const a = readArg(text, j);
        i = a ? a.end : j;
      } else {
        break;
      }
    }
    return { rules: rules, rest: text.slice(i) };
  }

  function parseCell(text) {
    let t = text.trim();
    const cell = { content: t, colspan: 1, rowspan: 1, align: null, vleft: null, vright: null };
    if (/^\\multicolumn(?![A-Za-z])/.test(t)) {
      const n = readArg(t, "\\multicolumn".length);
      const s = n && readArg(t, n.end);
      const c = s && readArg(t, s.end);
      if (c) {
        cell.colspan = Math.max(1, parseInt(n.content, 10) || 1);
        const spec = parseColSpec(s.content);
        cell.align = spec.columns.length ? spec.columns[0].align : "c";
        cell.vleft = spec.vrules[0];
        cell.vright = spec.vrules[spec.vrules.length - 1];
        t = (c.content + t.slice(c.end)).trim();
      }
    }
    if (/^\\multirow(?![A-Za-z])/.test(t)) {
      let j = "\\multirow".length;
      const o1 = readOptional(t, j);
      if (o1) j = o1.end;
      const n = readArg(t, j);
      if (n) {
        j = n.end;
        const o2 = readOptional(t, j);
        if (o2) j = o2.end;
        const w = readArg(t, j);
        if (w) {
          j = w.end;
          const o3 = readOptional(t, j);
          if (o3) j = o3.end;
          const c = readArg(t, j);
          if (c) {
            const rows = parseInt(n.content, 10) || 1;
            cell.rowspan = rows > 1 ? rows : 1;
            t = (c.content + t.slice(c.end)).trim();
          }
        }
      }
    }
    cell.content = t;
    return cell;
  }

  // Parses the first tabular-like environment in src.
  // Returns {env, spec, columns, vrules, rows:[{rules, cells}], trailingRules, ncols, prefix, suffix} or null.
  function parseTabular(src) {
    const clean = stripComments(src);
    const m = /\\begin\s*\{(tabular\*?|tabularx|array|longtable)\}/.exec(clean);
    if (!m) return null;
    const env = m[1];
    let i = m.index + m[0].length;
    if (env === "tabular*" || env === "tabularx") {
      const w = readArg(clean, i);
      if (w) i = w.end;
    }
    const pos = readOptional(clean, i);
    if (pos) i = pos.end;
    const specArg = readArg(clean, i);
    if (!specArg) return null;
    i = specArg.end;
    const close = findEnvEnd(clean, i, env);
    const body = clean.slice(i, close ? close.start : clean.length);
    const spec = parseColSpec(specArg.content);
    const rawRows = splitRows(body);
    const rows = [];
    let pendingRules = [];
    for (const raw of rawRows) {
      const lead = leadingRules(raw[0]);
      const rules = pendingRules.concat(lead.rules);
      const cellsText = [lead.rest].concat(raw.slice(1));
      if (cellsText.length === 1 && cellsText[0].trim() === "") {
        pendingRules = rules;
        continue;
      }
      pendingRules = [];
      rows.push({ rules: rules, cells: cellsText.map(parseCell) });
    }
    let ncols = spec.columns.length;
    for (const r of rows) {
      const width = r.cells.reduce(function (a, c) { return a + c.colspan; }, 0);
      if (width > ncols) ncols = width;
    }
    return {
      env: env, spec: specArg.content, columns: spec.columns, vrules: spec.vrules, rows: rows,
      trailingRules: pendingRules, ncols: ncols,
      prefix: clean.slice(0, m.index), suffix: close ? clean.slice(close.end) : "",
    };
  }

  // Expands a parsed table to a rectangular grid of strings (merged cells: content in the first slot).
  function tableGrid(t, convert) {
    const grid = [];
    for (const row of t.rows) {
      const line = [];
      for (const cell of row.cells) {
        line.push(convert(cell.content));
        for (let k = 1; k < cell.colspan; k++) line.push("");
      }
      while (line.length < t.ncols) line.push("");
      grid.push(line);
    }
    return grid;
  }

  // ------------------------------------------------------------------ text-mode LaTeX -> HTML / Markdown / plain

  // Text-mode symbol commands. Line breaks (\\, \newline) are handled per output mode.
  const TEXT_SYMBOLS = {
    "%": "%", "&": "&", "#": "#", "_": "_", "$": "$", "{": "{", "}": "}", " ": " ", ",": " ",
    ";": " ", ":": " ", "!": "", "/": "", "-": "", "@": "", "\n": " ",
    textbackslash: "\\", textasciitilde: "~", textasciicircum: "^", textbar: "|", textless: "<",
    textgreater: ">", textbullet: "•", textperiodcentered: "·", textdegree: "°",
    textquoteleft: "‘", textquoteright: "’", textquotedblleft: "“", textquotedblright: "”",
    textendash: "–", textemdash: "—", textellipsis: "…", ldots: "…", dots: "…",
    textregistered: "®", texttrademark: "™", textcopyright: "©", copyright: "©",
    S: "§", P: "¶", dag: "†", ddag: "‡", pounds: "£", euro: "€",
    textdollar: "$", textunderscore: "_", ss: "ß", ae: "æ", AE: "Æ", oe: "œ", OE: "Œ",
    o: "ø", O: "Ø", aa: "å", AA: "Å", l: "ł", L: "Ł", i: "ı", j: "ȷ",
    LaTeX: "LaTeX", TeX: "TeX", quad: " ", qquad: "  ", enspace: " ", thinspace: " ",
    nobreakspace: " ", textvisiblespace: "␣", checkmark: "✓", textsection: "§",
    textparagraph: "¶", textdagger: "†",
  };
  const LINE_BREAKS = ["\\", "newline", "linebreak"];
  const MD_ESCAPED = ["_", "$", "#"];
  const ACCENTS = { "'": "́", "`": "̀", "^": "̂", '"': "̈", "~": "̃", "=": "̄",
    ".": "̇", u: "̆", v: "̌", H: "̋", c: "̧", k: "̨", r: "̊", d: "̣", b: "̱" };
  // name -> [HTML open, HTML close, Markdown open, Markdown close]
  const STYLES = {
    textbf: ["<b>", "</b>", "**", "**"], textit: ["<i>", "</i>", "*", "*"], emph: ["<em>", "</em>", "*", "*"],
    textsl: ["<i>", "</i>", "*", "*"], underline: ["<u>", "</u>", "<u>", "</u>"], uline: ["<u>", "</u>", "<u>", "</u>"],
    sout: ["<s>", "</s>", "~~", "~~"], texttt: ["<code>", "</code>", "`", "`"],
    textsc: ['<span class="sc">', "</span>", "", ""], textsf: ['<span class="sf">', "</span>", "", ""],
    textsuperscript: ["<sup>", "</sup>", "<sup>", "</sup>"], textsubscript: ["<sub>", "</sub>", "<sub>", "</sub>"],
    fbox: ['<span class="fbox">', "</span>", "", ""], textrm: ["", "", "", ""], textup: ["", "", "", ""],
    textnormal: ["", "", "", ""], textmd: ["", "", "", ""], mbox: ["", "", "", ""], text: ["", "", "", ""],
    hbox: ["", "", "", ""], makebox: ["", "", "", ""],
  };
  const IGNORED = ["noindent", "indent", "centering", "raggedright", "raggedleft", "medskip", "bigskip", "smallskip",
    "par", "maketitle", "newpage", "clearpage", "normalsize", "small", "footnotesize", "scriptsize", "tiny",
    "large", "Large", "LARGE", "huge", "Huge", "itshape", "upshape", "rmfamily", "sffamily", "ttfamily", "bfseries",
    "normalfont", "protect", "relax", "hfill", "vfill", "null", "strut", "leavevmode", "nopagebreak", "pagebreak",
    "allowbreak", "sloppy", "hline", "toprule", "midrule", "bottomrule", "qed", "qedhere", "em"];
  const IGNORED_WITH_ARG = ["label", "vspace", "hspace", "addvspace", "phantom", "hphantom", "vphantom", "index",
    "pagestyle", "thispagestyle", "setlength", "addtolength", "setcounter", "addtocounter", "color", "rowcolor"];

  function convertChars(s, mode) {
    let out = "";
    for (let i = 0; i < s.length; i++) {
      const ch = s[i];
      let rep = ch;
      if (ch === "~") rep = mode === "plain" ? " " : " ";
      else if (ch === "-" && s.startsWith("---", i)) { rep = "—"; i += 2; }
      else if (ch === "-" && s.startsWith("--", i)) { rep = "–"; i += 1; }
      else if (ch === "`" && s[i + 1] === "`") { rep = "“"; i += 1; }
      else if (ch === "'" && s[i + 1] === "'") { rep = "”"; i += 1; }
      else if (ch === "`") rep = "‘";
      else if (ch === "'") rep = "’";
      else if (ch === "\n" || ch === "\t") rep = " ";
      else if (mode === "md" && ch === "*") rep = "\\*";
      out += mode === "html" ? escapeHTML(rep) : rep;
    }
    return out;
  }

  // At a math opener ($, $$, \(, \[): {value, display, end}; {unbalanced: true} for a lone $; null if \( is unclosed.
  function readMath(src, i) {
    if (src[i] === "\\") {
      const close = src[i + 1] === "(" ? "\\)" : "\\]";
      const end = src.indexOf(close, i + 2);
      return end >= 0 ? { value: src.slice(i + 2, end), display: src[i + 1] === "[", end: end + 2 } : null;
    }
    const display = src[i + 1] === "$";
    const open = display ? 2 : 1;
    let j = i + open;
    while (j < src.length) {
      if (src[j] === "\\") { j += 2; continue; }
      if (src[j] === "$" && (!display || src[j + 1] === "$")) return { value: src.slice(i + open, j), display: display, end: j + open };
      j++;
    }
    return { unbalanced: true };
  }

  function wrapMarkdown(inner, open, close) {
    if (!open) return inner;
    const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(inner);
    return m[2] ? m[1] + open + m[2] + close + m[3] : inner;
  }

  // Converts text-mode LaTeX with inline math. opts.mode is "html", "md" or "plain";
  // opts.math(value, display) renders a math segment; opts.unbalanced(rest) renders a lone $.
  function convertInline(src, opts) {
    const mode = opts.mode;
    let out = "";
    let text = "";
    const flush = function () {
      if (text) out += convertChars(text, mode);
      text = "";
    };
    const emit = function (s) {
      flush();
      out += s;
    };
    let i = 0;
    while (i < src.length) {
      const ch = src[i];
      if (ch === "$" || (ch === "\\" && (src[i + 1] === "(" || src[i + 1] === "["))) {
        const m = readMath(src, i);
        if (m && m.unbalanced) {
          emit(opts.unbalanced ? opts.unbalanced(src.slice(i)) : convertChars(src.slice(i), mode));
          i = src.length;
          break;
        }
        if (m) {
          emit(opts.math(m.value, m.display));
          i = m.end;
          continue;
        }
      }
      if (ch === "\\") {
        const c = readCommand(src, i);
        const name = c.name;
        let j = c.end;
        if (LINE_BREAKS.indexOf(name) >= 0) {
          if (name === "\\") {
            if (src[j] === "*") j++;
            const opt = readOptional(src, j);
            if (opt && /^\s*-?[\d.]+\s*[a-z]{2}\s*$/.test(opt.content)) j = opt.end;
          }
          emit(mode === "html" ? "<br>" : mode === "md" ? "  \n" : "\n");
          i = j;
          continue;
        }
        if (ACCENTS[name] !== undefined) {
          const a = readArg(src, j);
          if (a) {
            const base = a.content === "\\i" ? "ı" : a.content === "\\j" ? "ȷ" : a.content;
            text += (base + ACCENTS[name]).normalize("NFC");
            i = a.end;
            continue;
          }
        }
        if (TEXT_SYMBOLS[name] !== undefined) {
          if (isLetter(name[0])) {
            if (src[j] === "{" && src[j + 1] === "}") j += 2;
            else if (src[j] === " ") j++;
          }
          if (mode === "md" && MD_ESCAPED.indexOf(name) >= 0) emit("\\" + name);
          else text += TEXT_SYMBOLS[name];
          i = j;
          continue;
        }
        if (STYLES[name]) {
          if (name === "makebox") {
            for (let n = 0; n < 2; n++) {
              const opt = readOptional(src, j);
              if (opt) j = opt.end;
            }
          }
          const a = readArg(src, j);
          if (a) {
            const inner = convertInline(a.content, opts);
            const s = STYLES[name];
            emit(mode === "html" ? s[0] + inner + s[1] : mode === "md" ? wrapMarkdown(inner, s[2], s[3]) : inner);
            i = a.end;
            continue;
          }
        }
        if (name === "textcolor" || name === "colorbox" || name === "href") {
          const a1 = readArg(src, j);
          const a2 = a1 && readArg(src, a1.end);
          if (a2) {
            const label = convertInline(a2.content, opts);
            emit(name === "href" && mode === "md" ? "[" + label + "](" + a1.content + ")" : label);
            i = a2.end;
            continue;
          }
        }
        if (name === "url") {
          const a = readArg(src, j);
          if (a) {
            emit(mode === "html" ? "<code>" + escapeHTML(a.content) + "</code>" : mode === "md" ? "<" + a.content + ">" : a.content);
            i = a.end;
            continue;
          }
        }
        if (name === "footnote") {
          const a = readArg(src, j);
          if (a) {
            emit(mode === "html" ? '<sup class="fn" title="' + escapeHTML(a.content) + '">*</sup>' : " (" + convertInline(a.content, opts) + ")");
            i = a.end;
            continue;
          }
        }
        if (name === "cite" || name === "ref" || name === "eqref" || name === "pageref") {
          const opt = readOptional(src, j);
          if (opt) j = opt.end;
          const a = readArg(src, j);
          if (a) {
            text += name === "cite" ? "[" + a.content + "]" : name === "eqref" ? "(" + a.content + ")" : a.content;
            i = a.end;
            continue;
          }
        }
        if (IGNORED.indexOf(name) >= 0) {
          i = src[j] === " " ? j + 1 : j;
          continue;
        }
        if (IGNORED_WITH_ARG.indexOf(name) >= 0) {
          if (src[j] === "*") j++;
          const opt = readOptional(src, j);
          if (opt) j = opt.end;
          const a = readArg(src, j);
          i = a ? a.end : j;
          continue;
        }
        // unknown command: keep it visible; braces around its arguments are transparent
        emit(mode === "html" ? '<span class="tx-cmd">\\' + escapeHTML(name) + "</span>" : "\\" + name);
        i = j;
        continue;
      }
      if (ch === "{" || ch === "}") {
        i++;
        continue;
      }
      text += ch;
      i++;
    }
    flush();
    return out;
  }

  const HTML_OPTS = {
    mode: "html",
    math: function (value, display) { return renderMath(value, display); },
    unbalanced: function (rest) { return '<span class="tx-error" title="Unbalanced $">' + escapeHTML(rest) + "</span>"; },
  };
  const MD_OPTS = {
    mode: "md",
    math: function (value, display) { return display ? "\n$$\n" + value.trim() + "\n$$\n" : "$" + value.trim() + "$"; },
  };
  const PLAIN_OPTS = {
    mode: "plain",
    math: function (value) {
      const plain = mathToPlain(value);
      if (plain === null) return "$" + value.trim() + "$";
      return /^[−\d.,\s]+$/.test(plain) ? plain.replace(/−/g, "-") : plain;
    },
  };

  function inlineToHTML(src) {
    return convertInline(src, HTML_OPTS);
  }

  function inlineToMarkdown(src) {
    return convertInline(src, MD_OPTS);
  }

  // A table cell as plain text for TSV/CSV.
  function cellToPlain(src) {
    return convertInline(src, PLAIN_OPTS).replace(/\s+/g, " ").trim();
  }

  function ruleWidth(type) {
    return type === "toprule" || type === "bottomrule" ? 2 : 1;
  }

  function tableToHTML(t, cellHTML) {
    // Rows whose multirow cell covers later rows: skip those covered (empty) cells.
    const covered = {};
    t.rows.forEach(function (row, r) {
      let col = 0;
      row.cells.forEach(function (cell) {
        if (cell.rowspan > 1) {
          let ok = true;
          for (let k = 1; k < cell.rowspan; k++) {
            const below = t.rows[r + k];
            const target = below && cellAtColumn(below, col);
            if (!target || target.content.trim() !== "" || target.colspan !== cell.colspan) { ok = false; break; }
          }
          if (ok) for (let k = 1; k < cell.rowspan; k++) covered[(r + k) + ":" + col] = true;
          else cell.rowspan = 1;
        }
        col += cell.colspan;
      });
    });

    let html = '<table class="tx-table">';
    t.rows.forEach(function (row, r) {
      const full = row.rules.filter(function (x) { return x.type !== "cline" && x.type !== "cmidrule"; });
      const partial = row.rules.filter(function (x) { return x.type === "cline" || x.type === "cmidrule"; });
      html += "<tr>";
      let col = 0;
      row.cells.forEach(function (cell) {
        const start = col;
        col += cell.colspan;
        if (covered[r + ":" + start]) return;
        const style = [];
        const align = cell.align || (t.columns[start] && t.columns[start].align) || "l";
        style.push("text-align:" + (align === "c" ? "center" : align === "r" ? "right" : "left"));
        if (full.length) {
          style.push(full.length > 1 ? "border-top:3px double var(--rule)" : "border-top:" + ruleWidth(full[0].type) + "px solid var(--rule)");
        } else {
          const p = partial.filter(function (x) { return x.from <= start + 1 && x.to >= start + cell.colspan; });
          if (p.length) style.push("border-top:1px solid var(--rule)");
        }
        const bottomRows = cell.rowspan > 1 ? r + cell.rowspan - 1 : r;
        if (bottomRows === t.rows.length - 1 && t.trailingRules.length) {
          const tr = t.trailingRules.filter(function (x) { return x.type !== "cline" && x.type !== "cmidrule"; });
          if (tr.length) style.push(tr.length > 1 ? "border-bottom:3px double var(--rule)" : "border-bottom:" + ruleWidth(tr[0].type) + "px solid var(--rule)");
        }
        const left = start === 0 ? (cell.vleft !== null ? cell.vleft : t.vrules[0]) : 0;
        const right = cell.vright !== null ? cell.vright : (t.vrules[start + cell.colspan] || 0);
        if (left) style.push("border-left:" + (left > 1 ? "3px double" : "1px solid") + " var(--rule)");
        if (right) style.push("border-right:" + (right > 1 ? "3px double" : "1px solid") + " var(--rule)");
        const attrs = (cell.colspan > 1 ? ' colspan="' + cell.colspan + '"' : "") + (cell.rowspan > 1 ? ' rowspan="' + cell.rowspan + '"' : "");
        html += "<td" + attrs + ' style="' + style.join(";") + '">' + cellHTML(cell.content) + "</td>";
      });
      for (; col < t.ncols; col++) html += "<td></td>";
      html += "</tr>";
    });
    html += "</table>";
    return html;
  }

  function cellAtColumn(row, col) {
    let c = 0;
    for (const cell of row.cells) {
      if (c === col) return cell;
      c += cell.colspan;
      if (c > col) return null;
    }
    return null;
  }

  function blocksToHTML(blocks) {
    let html = "";
    for (const b of blocks) {
      switch (b.type) {
        case "para":
          html += "<p>" + inlineToHTML(b.src) + "</p>";
          break;
        case "heading": {
          const level = Math.min(6, b.level + 1);
          html += "<h" + level + ">" + inlineToHTML(b.src) + "</h" + level + ">";
          break;
        }
        case "display": {
          const source = b.env ? (b.katexSource || katexDisplaySource(b.env, b.body)) : b.body;
          html += '<div class="tx-display">' + renderMath(source, true) + "</div>";
          break;
        }
        case "list": {
          const tag = b.env === "enumerate" ? "ol" : b.env === "description" ? "dl" : "ul";
          html += "<" + tag + ">";
          for (const item of b.items) {
            if (tag === "dl") html += "<dt>" + inlineToHTML(item.label || "") + "</dt><dd>" + blocksToHTML(splitBlocks(item.src)) + "</dd>";
            else html += (item.label !== null ? '<li class="tx-labelled" data-label="' + escapeHTML(item.label) + '">' : "<li>") + blocksToHTML(splitBlocks(item.src)) + "</li>";
          }
          html += "</" + tag + ">";
          break;
        }
        case "table": {
          const t = parseTabular(b.src);
          if (!t) { html += "<pre>" + escapeHTML(b.src) + "</pre>"; break; }
          if (t.env === "array") { html += '<div class="tx-display">' + renderMath(b.src, true) + "</div>"; break; }
          html += '<div class="tx-table-wrap">' + tableToHTML(t, inlineToHTML) + "</div>";
          break;
        }
        case "verbatim":
          html += "<pre>" + escapeHTML(b.src) + "</pre>";
          break;
        case "wrapper": {
          const env = b.env;
          let body = b.src;
          let caption = "";
          const cap = /\\caption\s*(\[[^\]]*\])?\s*\{/.exec(body);
          if (cap) {
            const g = readGroup(body, cap.index + cap[0].length - 1);
            if (g) {
              caption = '<div class="tx-caption">' + inlineToHTML(g.content) + "</div>";
              body = body.slice(0, cap.index) + body.slice(g.end);
            }
          }
          const titled = ["theorem", "lemma", "proposition", "corollary", "definition", "remark", "example",
            "note", "claim", "conjecture", "exercise", "solution", "proof", "abstract"];
          let head = "";
          if (titled.indexOf(env) >= 0) {
            const opt = readOptional(body, 0);
            let label = env.charAt(0).toUpperCase() + env.slice(1);
            if (opt) { label += " (" + inlineToHTML(opt.content) + ")"; body = body.slice(opt.end); }
            head = env === "proof" ? "<i>" + label + ".</i> " : "<b>" + label + ".</b> ";
          }
          const inner = blocksToHTML(splitBlocks(body));
          const cls = env === "center" || env === "table" || env === "table*" || env === "figure" ? "tx-center" :
            env === "quote" || env === "quotation" ? "tx-quote" : "tx-env";
          html += '<div class="' + cls + '">' + (head ? head.replace(/ $/, "") + " " : "") + inner +
            (env === "proof" ? '<div class="tx-qed">\u220E</div>' : "") + caption + "</div>";
          break;
        }
      }
    }
    return html;
  }

  // ------------------------------------------------------------------ normalize

  function stripFences(s) {
    const m = /^\s*```[a-zA-Z]*\s*\n([\s\S]*?)\n\s*```\s*$/.exec(s);
    return m ? m[1] : s;
  }

  function stripOuter(s, open, close) {
    if (s.startsWith(open) && s.endsWith(close) && s.length >= open.length + close.length) {
      const inner = s.slice(open.length, s.length - close.length);
      if (open === "$" && inner.indexOf("$") >= 0) return null;
      return inner.trim();
    }
    return null;
  }

  // Environments that make a line of math that \tag may not live inside.
  const INNER_MATH_ENVS = ["aligned", "gathered", "alignedat", "split", "cases", "dcases", "rcases", "array",
    "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "subarray"];

  function countTags(s) {
    return (s.match(/\\tag\*?\s*\{/g) || []).length;
  }

  // A single \tag written inside aligned/gathered/... is invalid LaTeX; move it after the environment.
  function hoistTag(latex) {
    if (countTags(latex) !== 1) return latex;
    const m = /\\tag(\*?)\s*\{/.exec(latex);
    const g = readGroup(latex, m.index + m[0].length - 1);
    if (!g) return latex;
    const before = latex.slice(0, m.index);
    let depth = 0;
    const re = /\\(begin|end)\s*\{([^}]*)\}/g;
    let x;
    while ((x = re.exec(before))) {
      if (INNER_MATH_ENVS.indexOf(x[2].trim()) >= 0) depth += x[1] === "begin" ? 1 : -1;
    }
    if (depth <= 0) return latex;
    const without = (before.replace(/\s+$/, "") + " " + latex.slice(g.end).replace(/^\s+/, "")).trim();
    return without + " \\tag" + m[1] + "{" + g.content + "}";
  }

  // When every row has the same width but a plain l/c/r spec declares a different number of columns,
  // rewrites the spec to that width, keeping its vertical-rule pattern. A model writes the spec before it
  // has seen the rows, so an off-by-one there is common while the cells themselves are right.
  function fixColumnCount(src) {
    const t = parseTabular(src);
    if (!t || !/^[lcr|\s]+$/.test(t.spec) || !t.rows.length) return src;
    const widths = t.rows.map(function (r) { return r.cells.reduce(function (a, c) { return a + c.colspan; }, 0); });
    const w = widths[0];
    if (w < 1 || !widths.every(function (x) { return x === w; }) || w === t.columns.length) return src;
    const letters = t.columns.map(function (c) { return c.align; });
    const inner = t.vrules.slice(1, -1);
    const grid = inner.length > 1 && inner.every(function (v) { return v > 0; });
    let spec = "|".repeat(t.vrules[0]);
    for (let i = 0; i < w; i++) {
      if (i > 0) spec += "|".repeat(grid ? inner[0] : (inner[i - 1] || 0));
      spec += letters[Math.min(i, letters.length - 1)];
    }
    spec += "|".repeat(t.vrules[t.vrules.length - 1]);
    const m = /\\begin\s*\{tabular\}\s*\{[^{}]*\}/.exec(src);
    return m ? src.slice(0, m.index) + "\\begin{tabular}{" + spec + "}" + src.slice(m.index + m[0].length) : src;
  }

  function normalize(kind, latex) {
    let k = String(kind || "").trim().toLowerCase();
    let s = stripFences(String(latex || "")).trim();
    if (k === "none" || (!s && k !== "table" && k !== "text")) return { kind: s ? "text" : "none", latex: s };

    if (k === "math" || !k) {
      let changed = true;
      while (changed) {
        changed = false;
        for (const pair of [["$$", "$$"], ["\\[", "\\]"], ["\\(", "\\)"], ["$", "$"]]) {
          const inner = stripOuter(s, pair[0], pair[1]);
          if (inner !== null) { s = inner; changed = true; }
        }
        const env = /^\\begin\{(equation\*?|displaymath|align\*?|gather\*?|multline\*?|flalign\*?)\}([\s\S]*)\\end\{\1\}$/.exec(s);
        if (env) {
          const name = env[1].replace("*", "");
          const body = env[2].trim();
          const tags = countTags(body);
          if ((name === "align" || name === "gather" || name === "flalign") && tags > 1) {
            return { kind: "text", latex: s };
          }
          if (name === "equation" || name === "displaymath") s = body;
          else if (name === "align" || name === "flalign") s = "\\begin{aligned}\n" + body + "\n\\end{aligned}";
          else s = "\\begin{gathered}\n" + body + "\n\\end{gathered}";
          s = s.replace(/\\(nonumber|notag)\b\s*/g, "");
          changed = true;
        }
      }
      if (!k) {
        if (/\\begin\{tabular/.test(s)) k = "table";
        else if (/(^|[^\\])\$|\\\(|\\\[|\n\s*\n/.test(s) || /[A-Za-z]{3,}\s+[A-Za-z]{3,}\s+[A-Za-z]{3,}/.test(s.replace(/\\[A-Za-z]+/g, ""))) k = "text";
        else k = "math";
      }
      if (k === "math") {
        s = s.replace(/\\label\s*\{[^{}]*\}\s*/g, "");
        s = hoistTag(s);
        return { kind: "math", latex: s };
      }
    }

    if (k === "table") {
      const m = /\\begin\s*\{(tabular\*?|tabularx|longtable)\}/.exec(s);
      if (!m) return /\\begin\s*\{array\}/.test(s) ? normalize("math", s) : { kind: "text", latex: s };
      {
        const close = findEnvEnd(s, m.index + m[0].length, m[1]);
        if (close) {
          const outside = (s.slice(0, m.index) + s.slice(close.end))
            .replace(/\\(begin|end)\s*\{(table\*?|center)\}(\[[^\]]*\])?/g, "")
            .replace(/\\centering\b/g, "").replace(/\\label\s*\{[^}]*\}/g, "").trim();
          if (!outside) return { kind: "table", latex: fixColumnCount(s.slice(m.index, close.end).trim()) };
          return { kind: "text", latex: s };
        }
      }
      return { kind: "table", latex: s };
    }

    // text
    s = s.replace(/\\documentclass(\[[^\]]*\])?\{[^}]*\}\s*/g, "")
      .replace(/\\usepackage(\[[^\]]*\])?\{[^}]*\}\s*/g, "")
      .replace(/\\(begin|end)\{document\}\s*/g, "").trim();
    return { kind: "text", latex: s };
  }

  // ------------------------------------------------------------------ validation

  function braceProblem(src) {
    let depth = 0;
    for (let i = 0; i < src.length; i++) {
      if (src[i] === "\\") { i++; continue; }
      if (src[i] === "{") depth++;
      else if (src[i] === "}") {
        depth--;
        if (depth < 0) return "Unmatched closing brace }";
      }
    }
    return depth > 0 ? "Missing closing brace }" : null;
  }

  function envProblem(src) {
    const stack = [];
    const re = /\\(begin|end)\s*\{([^}]*)\}/g;
    let m;
    while ((m = re.exec(src))) {
      const name = m[2].trim();
      if (m[1] === "begin") stack.push(name);
      else if (!stack.length) return "\\end{" + name + "} without a matching \\begin";
      else if (stack[stack.length - 1] !== name) return "\\begin{" + stack[stack.length - 1] + "} is closed by \\end{" + name + "}";
      else stack.pop();
    }
    return stack.length ? "\\begin{" + stack[stack.length - 1] + "} is never closed" : null;
  }

  function validateInline(src, where, errors) {
    for (const seg of splitInline(src)) {
      if (seg.type === "math") {
        const err = checkMath(seg.value, seg.display);
        if (err) errors.push({ message: where + "math $" + seg.value.trim() + "$: " + err, repairable: true });
      } else if (seg.type === "unbalanced") {
        errors.push({ message: where + "unbalanced $ in: " + seg.value.trim().slice(0, 60), repairable: true });
      }
    }
  }

  function validateTable(src, errors) {
    const t = parseTabular(src);
    if (!t) {
      errors.push({ message: "No tabular environment found", repairable: true });
      return;
    }
    const expected = t.columns.length;
    if (/\\\\\s*\[(?!\s*-?[\d.]+\s*[a-z]{2}\s*\])/.test(src)) {
      errors.push({ message: "A row that starts with [ is read as the optional argument of \\\\; put {} before the [", repairable: true });
    }
    t.rows.forEach(function (row, r) {
      const width = row.cells.reduce(function (a, c) { return a + c.colspan; }, 0);
      if (expected && width !== expected) {
        errors.push({ message: "Row " + (r + 1) + " has " + width + " cells but the column specification {" + t.spec + "} has " + expected, repairable: true });
      }
      row.cells.forEach(function (cell, c) {
        validateInline(cell.content, "Row " + (r + 1) + ", cell " + (c + 1) + ": ", errors);
      });
    });
    if (!expected) errors.push({ message: "The column specification {" + t.spec + "} defines no columns", repairable: true });
  }

  function validateBlocks(blocks, errors) {
    for (const b of blocks) {
      if (b.type === "para" || b.type === "heading") validateInline(b.src, "", errors);
      else if (b.type === "display") {
        const source = b.env ? (b.katexSource || katexDisplaySource(b.env, b.body)) : b.body;
        const err = checkMath(source, true);
        if (err) errors.push({ message: "Display math: " + err, repairable: true });
      } else if (b.type === "list") {
        for (const item of b.items) validateBlocks(splitBlocks(item.src), errors);
      } else if (b.type === "table") {
        if (/\\begin\s*\{array\}/.test(b.src)) {
          const err = checkMath(b.src, true);
          if (err) errors.push({ message: "Array: " + err, repairable: true });
        } else validateTable(b.src, errors);
      } else if (b.type === "wrapper") validateBlocks(splitBlocks(b.src), errors);
    }
  }

  function validate(kind, latex) {
    const errors = [];
    const src = stripComments(String(latex || ""));
    if (kind === "none") return errors;
    if (!src.trim()) return [{ message: "The transcription is empty", repairable: true }];
    const brace = braceProblem(src);
    if (brace) errors.push({ message: brace, repairable: true });
    const env = envProblem(src);
    if (env) errors.push({ message: env, repairable: true });
    if (kind === "math") {
      if (!brace && !env) {
        const err = checkMath(src, true);
        if (err) errors.push({ message: err, repairable: true });
      }
      if (/\\begin\s*\{(equation|align|gather|multline|flalign)\*?\}/.test(src)) {
        errors.push({ message: "Display environments are not allowed in math output", repairable: true });
      }
      if (countTags(src) > 1) {
        errors.push({ message: "A single formula can carry only one \\tag; use kind text with an align environment for per-line numbers", repairable: true });
      } else if (countTags(src) === 1 && hoistTag(src) !== src) {
        errors.push({ message: "\\tag must come after the aligned/gathered environment, not inside it", repairable: true });
      }
    } else if (kind === "table") {
      if (!brace && !env) validateTable(src, errors);
    } else if (!brace && !env) {
      validateBlocks(splitBlocks(src), errors);
    }
    return errors;
  }

  // ------------------------------------------------------------------ plain-text conversion (spreadsheets)

  const MATH_SYMBOLS = {
    alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ϵ", varepsilon: "ε", zeta: "ζ", eta: "η", theta: "θ",
    vartheta: "ϑ", iota: "ι", kappa: "κ", lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", pi: "π", varpi: "ϖ", rho: "ρ",
    varrho: "ϱ", sigma: "σ", varsigma: "ς", tau: "τ", upsilon: "υ", phi: "ϕ", varphi: "φ", chi: "χ", psi: "ψ",
    omega: "ω", Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π", Sigma: "Σ", Upsilon: "Υ",
    Phi: "Φ", Psi: "Ψ", Omega: "Ω", pm: "±", mp: "∓", times: "×", cdot: "·", div: "÷", leq: "≤", le: "≤",
    geq: "≥", ge: "≥", neq: "≠", ne: "≠", approx: "≈", sim: "∼", simeq: "≃", equiv: "≡", propto: "∝",
    infty: "∞", partial: "∂", nabla: "∇", sum: "∑", prod: "∏", int: "∫", in: "∈", notin: "∉", subset: "⊂",
    subseteq: "⊆", cup: "∪", cap: "∩", emptyset: "∅", varnothing: "∅", forall: "∀", exists: "∃", neg: "¬",
    wedge: "∧", vee: "∨", to: "→", rightarrow: "→", leftarrow: "←", Rightarrow: "⇒", Leftarrow: "⇐",
    leftrightarrow: "↔", Leftrightarrow: "⇔", mapsto: "↦", circ: "∘", bullet: "•", star: "⋆", ast: "∗",
    ldots: "…", cdots: "⋯", dots: "…", degree: "°", prime: "′", ell: "ℓ", hbar: "ℏ", Re: "ℜ", Im: "ℑ",
    aleph: "ℵ", langle: "⟨", rangle: "⟩", lvert: "|", rvert: "|", vert: "|", mid: "|", lVert: "‖", rVert: "‖",
    Vert: "‖", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "{": "{", "}": "}", ",": " ", ";": " ",
    ":": " ", "!": "", " ": " ", quad: " ", qquad: "  ", lbrace: "{", rbrace: "}", lfloor: "⌊", rfloor: "⌋",
    lceil: "⌈", rceil: "⌉", perp: "⊥", parallel: "∥", angle: "∠", triangle: "△", square: "□", checkmark: "✓",
    dagger: "†", ddagger: "‡", S: "§", uparrow: "↑", downarrow: "↓", ll: "≪", gg: "≫", cong: "≅",
    setminus: "∖", sqrt: "√", left: "", right: "", big: "", Big: "", bigl: "", bigr: "", Bigl: "", Bigr: "",
    displaystyle: "", textstyle: "", colon: ":", lt: "<", gt: ">",
  };
  const SUPERSCRIPTS = { "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸",
    "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", n: "ⁿ", i: "ⁱ", "*": "*", "′": "′" };
  const SUBSCRIPTS = { "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈",
    "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎" };
  const MATH_WRAPPERS = ["mathbf", "mathrm", "mathit", "mathsf", "mathtt", "boldsymbol", "bm", "text", "textbf",
    "textit", "textrm", "mbox", "operatorname", "mathnormal", "emph", "underline"];

  // Best-effort LaTeX math -> plain Unicode; returns null when the result would still contain LaTeX.
  function mathToPlain(src) {
    let out = "";
    let i = 0;
    while (i < src.length) {
      const ch = src[i];
      if (ch === "\\") {
        const c = readCommand(src, i);
        if (MATH_WRAPPERS.indexOf(c.name) >= 0) {
          const a = readArg(src, c.end);
          if (!a) return null;
          const inner = mathToPlain(a.content);
          if (inner === null) return null;
          out += inner;
          i = a.end;
          continue;
        }
        if (c.name === "frac" || c.name === "dfrac" || c.name === "tfrac") {
          const a = readArg(src, c.end);
          const b = a && readArg(src, a.end);
          if (!b) return null;
          const n = mathToPlain(a.content);
          const d = mathToPlain(b.content);
          if (n === null || d === null) return null;
          const wrap = function (x) { return /^[\w.′]+$/.test(x) ? x : "(" + x + ")"; };
          out += wrap(n) + "/" + wrap(d);
          i = b.end;
          continue;
        }
        if (c.name === "sqrt") {
          const index = readOptional(src, c.end);
          const root = !index ? "√" : index.content.trim() === "3" ? "∛" : index.content.trim() === "4" ? "∜" : null;
          if (!root) return null;
          const a = readArg(src, index ? index.end : c.end);
          if (!a) return null;
          const inner = mathToPlain(a.content);
          if (inner === null) return null;
          out += root + (/^[\w.]+$/.test(inner) ? inner : "(" + inner + ")");
          i = a.end;
          continue;
        }
        if (MATH_SYMBOLS[c.name] !== undefined) {
          out += MATH_SYMBOLS[c.name];
          i = c.end;
          continue;
        }
        return null;
      }
      if (ch === "^" || ch === "_") {
        const a = readArg(src, i + 1);
        if (!a) return null;
        if (ch === "^" && /^\s*\\circ\s*$/.test(a.content)) {
          out += "°";
          i = a.end;
          continue;
        }
        const inner = mathToPlain(a.content);
        if (inner === null) return null;
        const table = ch === "^" ? SUPERSCRIPTS : SUBSCRIPTS;
        let mapped = "";
        for (const x of inner) {
          if (table[x] === undefined) { mapped = null; break; }
          mapped += table[x];
        }
        out += mapped !== null ? mapped : ch + (inner.length === 1 ? inner : "(" + inner + ")");
        i = a.end;
        continue;
      }
      if (ch === "{" || ch === "}") { i++; continue; }
      if (ch === "'") { out += "′"; i++; continue; }
      if (ch === "~") { out += " "; i++; continue; }
      if (ch === "-") { out += "−"; i++; continue; }
      out += ch;
      i++;
    }
    return out.replace(/\s+/g, " ").trim();
  }

  // ------------------------------------------------------------------ Markdown conversion

  function tableToMarkdown(t) {
    const grid = tableGrid(t, function (s) { return inlineToMarkdown(s).replace(/\s*\n\s*/g, " ").replace(/\|/g, "\\|").trim(); });
    if (!grid.length) return "";
    const aligns = [];
    for (let c = 0; c < t.ncols; c++) {
      const a = t.columns[c] ? t.columns[c].align : "l";
      aligns.push(a === "c" ? ":---:" : a === "r" ? "---:" : ":---");
    }
    const line = function (cells) { return "| " + cells.map(function (x) { return x || " "; }).join(" | ") + " |"; };
    const rows = [line(grid[0]), "| " + aligns.join(" | ") + " |"];
    for (let r = 1; r < grid.length; r++) rows.push(line(grid[r]));
    return rows.join("\n");
  }

  function blocksToMarkdown(blocks, indent) {
    indent = indent || "";
    const parts = [];
    for (const b of blocks) {
      switch (b.type) {
        case "para":
          parts.push(indent + inlineToMarkdown(b.src).replace(/\s*\n\s*/g, function (m) { return m.indexOf("  \n") >= 0 ? m : " "; }).trim());
          break;
        case "heading":
          parts.push("#".repeat(Math.min(6, b.level)) + " " + inlineToMarkdown(b.src).trim());
          break;
        case "display": {
          const body = b.env === null || b.env === "equation" || b.env === "equation*" || b.env === "displaymath"
            ? b.body.trim() : katexDisplaySource(b.env, b.body).trim();
          parts.push(indent + "$$\n" + indent + body.split("\n").join("\n" + indent) + "\n" + indent + "$$");
          break;
        }
        case "list": {
          const lines = [];
          b.items.forEach(function (item, n) {
            const bullet = b.env === "enumerate" ? (n + 1) + ". " : "- ";
            const label = item.label !== null ? "**" + inlineToMarkdown(item.label).trim() + "** " : "";
            const inner = blocksToMarkdown(splitBlocks(item.src), " ".repeat(bullet.length)).replace(/^\s+/, "");
            lines.push(indent + bullet + label + inner);
          });
          parts.push(lines.join("\n"));
          break;
        }
        case "table": {
          const t = parseTabular(b.src);
          parts.push(t && t.env !== "array" ? tableToMarkdown(t) : "$$\n" + b.src.trim() + "\n$$");
          break;
        }
        case "verbatim":
          parts.push("```\n" + b.src.replace(/\s+$/, "") + "\n```");
          break;
        case "wrapper": {
          let body = b.src.replace(/\\caption\s*(\[[^\]]*\])?\s*/, "");
          const inner = blocksToMarkdown(splitBlocks(body), indent);
          if (b.env === "quote" || b.env === "quotation") parts.push(inner.split("\n").map(function (l) { return "> " + l; }).join("\n"));
          else if (b.env === "proof") parts.push("*Proof.* " + inner + " ∎");
          else if (["theorem", "lemma", "proposition", "corollary", "definition", "remark", "example"].indexOf(b.env) >= 0)
            parts.push("**" + b.env.charAt(0).toUpperCase() + b.env.slice(1) + ".** " + inner);
          else parts.push(inner);
          break;
        }
      }
    }
    return parts.join("\n\n");
  }

  // ------------------------------------------------------------------ LaTeX table variants

  function hasBooktabs(src) {
    return /\\(toprule|midrule|bottomrule|cmidrule)(?![A-Za-z])/.test(src);
  }

  function toHlineRules(src) {
    return src.replace(/\\(toprule|midrule|bottomrule)(?![A-Za-z])(\s*\[[^\]]*\])?/g, "\\hline")
      .replace(/\\cmidrule(?![A-Za-z])(\s*\[[^\]]*\])?(\s*\([^)]*\))?\s*\{([^}]*)\}/g, "\\cline{$3}");
  }

  function toBooktabsRules(src) {
    // collapse runs of full-width rules, then name them top/mid/bottom
    let s = src.replace(/\\hline(\s*\\hline)+/g, "\\hline");
    const count = (s.match(/\\hline(?![A-Za-z])/g) || []).length;
    let n = 0;
    s = s.replace(/\\hline(?![A-Za-z])/g, function () {
      n++;
      return n === 1 ? "\\toprule" : n === count ? "\\bottomrule" : "\\midrule";
    });
    s = s.replace(/\\cline\s*\{([^}]*)\}/g, "\\cmidrule(lr){$1}");
    // booktabs tables have no vertical rules
    s = s.replace(/(\\begin\s*\{tabular\*?\}\s*(?:\{[^}]*\}\s*)?(?:\[[^\]]*\]\s*)?)\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}/, function (_, head, spec) {
      return head + "{" + spec.replace(/\|/g, "") + "}";
    });
    s = s.replace(/(\\multicolumn\s*\{[^}]*\}\s*)\{([^}]*)\}/g, function (_, head, spec) {
      return head + "{" + spec.replace(/\|/g, "") + "}";
    });
    return s;
  }

  // ------------------------------------------------------------------ formats

  function csvField(s) {
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  function collapseLines(s) {
    return s.replace(/\s*\n\s*/g, " ").trim();
  }

  function stripTags(s) {
    return s.replace(/\s*\\tag\*?\s*\{[^{}]*\}\s*/g, " ").trim();
  }

  function formats(kind, latex) {
    const src = String(latex || "").trim();
    const list = [];
    const add = function (id, label, value) { if (value !== null && value !== undefined && value !== "") list.push({ id: id, label: label, value: value }); };
    if (kind === "math") {
      const multi = src.indexOf("\n") >= 0;
      add("latex", "LaTeX", src);
      add("inline_dollar", "Inline  $…$", "$" + collapseLines(stripTags(src)) + "$");
      add("display_dollar", "Display  $$…$$", multi ? "$$\n" + src + "\n$$" : "$$" + src + "$$");
      add("display_bracket", "Display  \\[…\\]", "\\[\n" + src + "\n\\]");
      add("inline_paren", "Inline  \\(…\\)", "\\(" + collapseLines(stripTags(src)) + "\\)");
      add("equation", "equation environment", "\\begin{equation}\n" + src + "\n\\end{equation}");
      add("mathml", "MathML (Word)", mathML(src, true));
    } else if (kind === "table") {
      const t = parseTabular(src);
      add("latex", "LaTeX", src);
      if (t) {
        if (hasBooktabs(src)) add("latex_hline", "LaTeX  (\\hline rules, no booktabs)", toHlineRules(src));
        else if (/\\(hline|cline)(?![A-Za-z])/.test(src)) add("latex_booktabs", "LaTeX  (booktabs rules)", toBooktabsRules(src));
        add("markdown", "Markdown", tableToMarkdown(t));
        const grid = tableGrid(t, cellToPlain);
        add("tsv", "TSV (Excel, Sheets)", grid.map(function (r) { return r.map(function (x) { return x.replace(/\t/g, " "); }).join("\t"); }).join("\n"));
        add("csv", "CSV", grid.map(function (r) { return r.map(csvField).join(","); }).join("\n"));
        add("html", "HTML", tableToHTML(JSON.parse(JSON.stringify(t)), function (s) {
          return convertInline(s, { mode: "html", math: function (v, d) { return mathML(v, d) || escapeHTML("$" + v + "$"); } });
        }).replace(/ style="[^"]*"/g, function (m) {
          return m.replace(/var\(--rule\)/g, "#000");
        }));
      }
    } else if (kind === "text") {
      add("latex", "LaTeX", src);
      add("markdown", "Markdown", blocksToMarkdown(splitBlocks(stripComments(src))));
    }
    return list;
  }

  // ------------------------------------------------------------------ packages

  const PACKAGE_RULES = [
    ["amsmath", /\\(begin\{(aligned|gathered|alignedat|cases|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|matrix|smallmatrix|align\*?|gather\*?|multline\*?|flalign\*?|split|alignat\*?|equation\*|subarray)\}|text|tag|binom|dbinom|tbinom|dfrac|tfrac|cfrac|genfrac|operatorname|boldsymbol|iint|iiint|iiiint|idotsint|substack|overset|underset|xrightarrow|xleftarrow|eqref|dddot|ddddot|lvert|rvert|lVert|rVert|intertext|DeclareMathOperator|smash|notag|nonumber|numberwithin|overleftrightarrow|underleftarrow|underrightarrow|underleftrightarrow|boxed|sideset|dotsb|dotsc|dotsi|dotsm|dotso|varGamma|varDelta|varTheta|varLambda|varXi|varPi|varSigma|varUpsilon|varPhi|varPsi|varOmega)(?![A-Za-z])/],
    ["amssymb", /\\(mathbb|mathfrak|varnothing|leqslant|geqslant|therefore|because|nexists|blacksquare|square|checkmark|lesssim|gtrsim|varkappa|digamma|beth|gimel|daleth|circledast|boxplus|boxtimes|boxminus|ltimes|rtimes|subsetneq|supsetneq|nmid|nparallel|ncong|twoheadrightarrow|restriction|upharpoonright|varpropto|smallsetminus|Box|Diamond|lozenge|blacklozenge|triangleq|intercal|veebar|barwedge|curlyvee|curlywedge|lll|ggg|lessgtr|gtrless|leqq|geqq|nleq|ngeq|nless|ngtr|nsubseteq|nsupseteq|precsim|succsim|vartriangle|triangledown|blacktriangle|square|eqslantless|eqslantgreater|approxeq|thicksim|thickapprox|backsim|backepsilon|complement|Finv|Game|mho|eth|hslash|circlearrowleft|circlearrowright|curvearrowleft|curvearrowright|dashrightarrow|dashleftarrow|leftleftarrows|rightrightarrows|rightsquigarrow|leftrightsquigarrow|multimap|vDash|Vdash|Vvdash|nvdash|nvDash|nVdash|centerdot|dotplus|divideontimes|doublebarwedge|leftthreetimes|rightthreetimes|ulcorner|urcorner|llcorner|lrcorner|sphericalangle|measuredangle|bigstar|blacktriangleleft|blacktriangleright|varsubsetneq|varsupsetneq|lneq|gneq|lneqq|gneqq)(?![A-Za-z])/],
    ["mathrsfs", /\\mathscr(?![A-Za-z])/],
    ["bm", /\\bm(?![A-Za-z])/],
    ["mathtools", /\\(coloneqq|eqqcolon|Coloneqq|coloneq|mathclap|mathllap|mathrlap|prescript|smashoperator|shortintertext|xmapsto|xleftrightarrow|xLeftrightarrow|xhookrightarrow|begin\{(dcases|rcases|pmatrix\*|bmatrix\*|matrix\*)\})(?![A-Za-z])/],
    ["booktabs", /\\(toprule|midrule|bottomrule|cmidrule|addlinespace)(?![A-Za-z])/],
    ["multirow", /\\multirow(?![A-Za-z])/],
    ["cancel", /\\(cancel|bcancel|xcancel|cancelto)(?![A-Za-z])/],
    ["xcolor", /\\(textcolor|color|colorbox|rowcolor)(?![A-Za-z])/],
    ["amsthm", /\\begin\{proof\}/],
    ["ulem", /\\(sout|uline|uwave)(?![A-Za-z])/],
    ["hyperref", /\\(url|href)(?![A-Za-z])/],
    ["tabularx", /\\begin\{tabularx\}/],
    ["array", /\\begin\{tabular\*?\}\s*\{[^}]*[mb]\{/],
  ];

  function packages(latex) {
    const src = String(latex || "");
    const out = [];
    for (const rule of PACKAGE_RULES) if (rule[1].test(src)) out.push(rule[0]);
    // mathtools loads amsmath; keep both listed only when amsmath-specific commands appear
    return out;
  }

  // ------------------------------------------------------------------ preview

  function preview(kind, latex) {
    const src = String(latex || "");
    if (kind === "none" || !src.trim()) return '<div class="tx-empty">No math, text or table found.</div>';
    if (kind === "math") return '<div class="tx-display">' + renderMath(stripComments(src), true) + "</div>";
    if (kind === "table") {
      const t = parseTabular(src);
      if (!t) return '<pre class="tx-error">' + escapeHTML(src) + "</pre>";
      return '<div class="tx-table-wrap">' + tableToHTML(t, inlineToHTML) + "</div>";
    }
    return '<div class="tx-text">' + blocksToHTML(splitBlocks(stripComments(src))) + "</div>";
  }

  root.LatexKit = {
    normalize: normalize,
    validate: validate,
    preview: preview,
    formats: formats,
    packages: packages,
    parseTabular: parseTabular,
    splitBlocks: splitBlocks,
    splitInline: splitInline,
    mathToPlain: mathToPlain,
    cellToPlain: cellToPlain,
    toBooktabsRules: toBooktabsRules,
    toHlineRules: toHlineRules,
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
