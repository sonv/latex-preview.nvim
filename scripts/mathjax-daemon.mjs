#!/usr/bin/env node
//
// mathjax-daemon.mjs
//
// A long-running MathJax daemon for the latex-preview.nvim plugin. Reads
// newline-delimited JSON requests from stdin and writes newline-delimited
// JSON responses to stdout. Loads MathJax and its font data once at startup
// so subsequent requests only pay for parsing and typesetting their math.
//
// Protocol (one JSON object per line, both directions):
//
//   request:   {"id": <any>, "preamble": "<tex>", "equation": "<tex>",
//               "display": false, "color": "000000"}
//   response:  {"id": <echoed>, "ok": true,  "svg": "<svg>...</svg>"}
//          or  {"id": <echoed>, "ok": false, "err": "..."}
//
// Errors during preamble parsing are swallowed block-by-block (Overleaf
// pattern) so that \RequirePackage / \DeclareOption / \makeatletter inside
// a .sty file don't kill the render. Errors on the actual equation
// propagate so the plugin can surface them.
//
// One-shot mode (for ad-hoc use and tests):
//   mathjax-daemon.mjs --in FILE --out FILE.svg [--display] [--color HEX]
//
// Requires:  npm i -g @mathjax/src@4   (or local install — auto-detected)
//

import { argv, exit, stderr, stdin, stdout } from "node:process";
import { promises as fs } from "node:fs";
import { createInterface } from "node:readline";
import { execFileSync } from "node:child_process";

function parseArgs(a) {
  const o = { display: false, color: "000000", daemon: false, listPaths: false };
  for (let i = 2; i < a.length; i++) {
    const k = a[i];
    if (k === "--in") o.input = a[++i];
    else if (k === "--out") o.output = a[++i];
    else if (k === "--display") o.display = true;
    else if (k === "--color") o.color = a[++i];
    else if (k === "--ex") o.ex = parseFloat(a[++i]);
    else if (k === "--daemon") o.daemon = true;
    else if (k === "--list-paths") o.listPaths = true;
  }
  return o;
}

// ---------------------------------------------------------------------------
// Canonical @mathjax/src candidate path list. The Lua side (health.lua)
// invokes this script with --list-paths to read this list rather than
// duplicating it — keep the resolution logic in exactly one place.
// ---------------------------------------------------------------------------
async function buildCandidatePaths({ includeNpm = true } = {}) {
  const path = await import("node:path");
  const { fileURLToPath } = await import("node:url");
  const here = path.dirname(fileURLToPath(import.meta.url));
  const seen = new Set();
  const candidates = [];
  const add = (p) => {
    if (!p || seen.has(p)) return;
    seen.add(p);
    candidates.push(p);
  };

  add(process.env.LATEX_PREVIEW_MATHJAX_PATH);
  add(process.env.SNACKS_MATHJAX_PATH);
  add(path.join(here, "node_modules", "@mathjax", "src"));
  add(path.join(here, "..", "node_modules", "@mathjax", "src"));
  add(path.join(process.cwd(), "node_modules", "@mathjax", "src"));
  for (const p of [
    "/usr/lib/node_modules/@mathjax/src",
    "/usr/local/lib/node_modules/@mathjax/src",
    "/opt/homebrew/lib/node_modules/@mathjax/src",
    "/opt/local/lib/node_modules/@mathjax/src",
    path.join(process.env.HOME || "", ".npm-global/lib/node_modules/@mathjax/src"),
    path.join(process.env.HOME || "",
      ".nvm/versions/node/" + process.version + "/lib/node_modules/@mathjax/src"),
  ]) add(p);
  if (includeNpm) {
    try {
      const npmRoot = execFileSync("npm", ["root", "-g"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      add(path.join(npmRoot, "@mathjax", "src"));
    } catch (_) {
      // npm is optional; explicit env/local/hardcoded paths may still work.
    }
  }
  return candidates;
}

// ---------------------------------------------------------------------------
// MathJax bootstrap. Resolved once at startup and kept in module scope so
// the daemon loop can reuse the loaded modules across thousands of requests.
// ---------------------------------------------------------------------------
const TEX_PACKAGES = [
  "base",
  "action",
  "ams",
  "amscd",
  "bbm",
  "bbox",
  "begingroup",
  "boldsymbol",
  "braket",
  "bussproofs",
  "cancel",
  "cases",
  "centernot",
  "color",
  "colortbl",
  "configmacros",
  "dsfont",
  "empheq",
  "enclose",
  "extpfeil",
  "gensymb",
  "html",
  "mathtools",
  "mhchem",
  "newcommand",
  "setoptions",
  "tagformat",
  "texhtml",
  "textcomp",
  "textmacros",
  "unicode",
  "units",
  "upgreek",
  "verb",
];

const TEX_PACKAGE_EXCLUDES = new Set([
  // Strict rendering needs actual errors rather than red merror output.
  "noerrors",
  "noundefined",
  // These rely on MathJax's component loader. We import packages directly.
  "autoload",
  "require",
  // Keep the LaTeX-compatible color package as the default.
  "colorv2",
  // This redefines common macros like \sin and \div, so don't enable it globally.
  "physics",
  // bboldx replaces \mathbb with a variant missing from MathJax 4's default
  // font, silently rendering upright letters. Keep the built-in double-struck
  // glyphs, including when discovering packages from the installed TeX tree.
  "bboldx",
]);

function readPackageInfo(fsSync, path, dir) {
  try {
    return JSON.parse(fsSync.readFileSync(path.join(dir, "package.json"), "utf8"));
  } catch (_) {
    return null;
  }
}

function isMathJax4Source(info) {
  return info && info.name === "@mathjax/src" && /^4\./.test(String(info.version || ""));
}

async function loadTexPackages(mjPath, u, fsSync, path) {
  const packages = [];
  const add = (name) => {
    if (!name || TEX_PACKAGE_EXCLUDES.has(name) || packages.includes(name)) return;
    packages.push(name);
  };
  for (const name of TEX_PACKAGES) add(name);

  const texDir = path.join(mjPath, "mjs", "input", "tex");
  try {
    for (const entry of fsSync.readdirSync(texDir, { withFileTypes: true })) {
      if (entry.isDirectory()) add(entry.name);
    }
  } catch (_) {
    // The imports below will report a concrete failure if the package layout is invalid.
  }

  for (const name of packages) {
    const dir = path.join(texDir, name);
    const files = fsSync.existsSync(dir)
      ? fsSync.readdirSync(dir).filter((file) => /Configuration\.js$/.test(file)).sort()
      : [];
    for (const file of files) {
      await import(u(path.join("input", "tex", name, file)));
    }
  }
  return packages;
}

async function bootMathJax() {
  const path = await import("node:path");
  const fsSync = await import("node:fs");
  const { pathToFileURL } = await import("node:url");

  // First pass: try cheap candidates only. `npm root -g` adds 100+ms of
  // process spawn even when the answer is going to be a path we already
  // checked — defer it until the obvious locations have all missed.
  const findIn = (cands) => {
    for (const c of cands) {
      if (!c || !fsSync.existsSync(path.join(c, "package.json"))) continue;
      const info = readPackageInfo(fsSync, path, c);
      if (isMathJax4Source(info)) return { path: c, info };
    }
    return null;
  };
  let candidates = await buildCandidatePaths({ includeNpm: false });
  let found = findIn(candidates);
  if (!found) {
    candidates = await buildCandidatePaths({ includeNpm: true });
    found = findIn(candidates);
  }
  if (!found) {
    stderr.write(
      "latex-preview/mathjax-daemon: @mathjax/src@4 not found. Install with:\n" +
      "  npm install -g @mathjax/src@4\n" +
      "Or set LATEX_PREVIEW_MATHJAX_PATH to its install dir.\n" +
      "Checked:\n" +
      candidates.map((p) => "  " + p).join("\n") +
      "\n"
    );
    exit(1);
  }

  const mjPath = found.path;
  const u = (sub) => pathToFileURL(path.join(mjPath, "mjs", sub)).href;
  await import(u("util/asyncLoad/esm.js"));
  const { mathjax }             = await import(u("mathjax.js"));
  const { TeX }                 = await import(u("input/tex.js"));
  const { SVG }                 = await import(u("output/svg.js"));
  const { liteAdaptor }         = await import(u("adaptors/liteAdaptor.js"));
  const { RegisterHTMLHandler } = await import(u("handlers/html.js"));
  const { STATE }               = await import(u("core/MathItem.js"));
  const packages = await loadTexPackages(mjPath, u, fsSync, path);

  const adaptor = liteAdaptor();
  RegisterHTMLHandler(adaptor);
  // Font metrics and dynamically loaded glyphs are independent of TeX macro
  // state. Construct them once; rebuilding the font for every keystroke is
  // substantially more expensive than the actual typesetting of short math.
  const fontData = new SVG().font;

  return { mathjax, TeX, SVG, adaptor, fontData, packages, STATE };
}

let MJ = null; // populated by bootMathJax()

function splitPreambleBlocks(preamble) {
  const blocks = [];
  let block = [];
  let depth = 0;
  let state = null;

  // A balanced name argument is only the start of a declaration. Keep its
  // replacement text (and an environment's end code) in the same retry.
  const definitions = {
    newcommand: [2, true], renewcommand: [2, true], providecommand: [2, true],
    DeclareRobustCommand: [2, true], DeclareMathOperator: [2, true],
    NewDocumentCommand: [3, true], RenewDocumentCommand: [3, true], ProvideDocumentCommand: [3, true],
    newenvironment: [3], renewenvironment: [3], newtheorem: [2],
    def: [1], gdef: [1], edef: [1], let: [0, false, 2], newcounter: [1],
  };
  const nextDefinition = (line, from = 0) => {
    const commands = /\\([A-Za-z@]+)/g;
    commands.lastIndex = from;
    for (let match; (match = commands.exec(line));) {
      let slashes = 0;
      for (let i = match.index - 1; i >= 0 && line[i] === "\\"; i--) slashes++;
      const spec = definitions[match[1]];
      if (slashes % 2 || !Object.hasOwn(definitions, match[1])) continue;
      return { groups: spec[0], macro: spec[1], tokens: spec[2], depth: 0, optional: false,
        pos: commands.lastIndex, start: match.index };
    }
    return null;
  };

  const uncomment = (line) => {
    for (let i = 0; i < line.length; i++) {
      if (line[i] === "\\") i++;
      else if (line[i] === "%") return line.slice(0, i);
    }
    return line;
  };

  const update = (line, from = 0) => {
    let i = from;
    while (state) {
      if (state.groups === 0 && !state.tokens) {
        state = nextDefinition(line, i);
        if (!state) return;
        i = state.pos;
      }
      if (i >= line.length) return;
      const c = line[i];
      // A \let source may itself be named \def or \newcommand. Consume
      // its two tokens, then allow a declaration to follow on this line.
      if (state.tokens) {
        if (/\s/.test(c)) i++;
        else if (c === "=" && state.tokens === 1 && !state.equals) {
          state.equals = true;
          i++;
        } else {
          const control = /^\\(?:[A-Za-z@]+|.)/.exec(line.slice(i));
          i += control ? control[0].length : 1;
          state.tokens--;
        }
        continue;
      }
      if (state.macro && !/[\s*]/.test(c)) {
        state.macro = false;
        if (c === "\\") {
          const control = /^\\(?:[A-Za-z@]+|.)/.exec(line.slice(i));
          i += control ? control[0].length : 1;
          state.groups--;
          continue;
        }
      }
      if (c === "\\") i += 2;
      else {
        if (c === "{") state.depth++;
        else if (c === "}") {
          state.depth = Math.max(0, state.depth - 1);
          if (state.depth === 0 && !state.optional) state.groups--;
        } else if (state.depth === 0) {
          if (c === "[") state.optional = true;
          else if (c === "]") state.optional = false;
        }
        i++;
      }
    }
  };

  const flush = () => {
    const text = block.join("\n").trim();
    if (text) blocks.push(text);
    block = [];
    depth = 0;
    state = null;
  };

  for (const raw of preamble.split(/\r?\n/)) {
    // MathJax's argument scanner counts braces inside comments. Remove the
    // comment before replaying a block, while respecting escaped percent signs.
    const line = uncomment(raw);
    if (!line.trim()) {
      // A comment or empty line inside a macro body cannot end the definition.
      if (block.length) block.push("");
      continue;
    }
    const next = nextDefinition(line);
    // An unfinished declaration must not consume a later independent one.
    if (state && !state.tokens && state.depth === 0 && !state.optional
        && next && !line.slice(0, next.start).trim()) flush();
    const firstLine = block.length === 0;
    if (firstLine) state = next;
    block.push(line);
    if (state) {
      update(line, firstLine ? state.pos : 0);
      if (!state) flush();
    } else {
      // Unsupported control lines such as \makeatletter must not consume
      // following definitions. Retain balanced multi-line arguments for
      // other supported commands, e.g. \definecolor.
      for (let i = 0; i < line.length; i++) {
        if (line[i] === "\\") i++;
        else if (line[i] === "{") depth++;
        else if (line[i] === "}") depth--;
      }
      if (depth <= 0) flush();
    }
  }
  if (block.length) flush();
  return blocks;
}

function normalizeEquation(equation, display, displayMathStyle) {
  if (!equation) return equation;
  let math = equation.replace(/\\label\s*\{[^{}]*\}/g, "").trim();
  const style = display && displayMathStyle === "text" ? "\\textstyle " : "";
  if (!display || !math.includes("\n")) return style + math;
  if (/\\begin\s*\{(?:aligned|alignedat|align\*?|alignat\*?|split|gathered|gather\*?|multline\*?|equation\*?|eqnarray\*?|flalign\*?|matrix|pmatrix|bmatrix|cases)\}/.test(math)) {
    return style + math;
  }
  const lines = math
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !/^\\(?:notag|nonumber)\b/.test(line));
  // Keep line endings: joining a TeX comment to the next line would silently
  // comment out the rest of a multiline equation.
  return style + (lines.join("\n") || math);
}

// ---------------------------------------------------------------------------
// Render one equation. A fresh TeX input jax per request isolates definitions,
// colors, package options and labels, including definitions inside equations.
// Adaptors do not hold macro state; the shared adaptor and font are safe to
// reuse across the daemon's sequential requests.
// ---------------------------------------------------------------------------
async function renderOne({ preamble, equation, display, color, font_size, display_math_style, ex }) {
  if (!MJ) throw new Error("mathjax not booted");
  const { mathjax, TeX, SVG, adaptor, fontData, packages, STATE } = MJ;

  const makeDocument = () => mathjax.document("", {
    InputJax: new TeX({
      packages,
      macros: {
        // LaTeX's bm package defines \bm. MathJax has \boldsymbol.
        bm: ["\\boldsymbol{#1}", 1],
      },
      formatError: (jax, err) => { throw err; },
    }),
    OutputJax: new SVG({
      fontData,
      fontCache: "local",
      linebreaks: { inline: false },
    }),
  });
  let html = makeDocument();

  const em = Number(font_size) > 0 ? Number(font_size) : 11;
  const opts = { display: false, em, ex: ex || em / 2, containerWidth: 1280 };

  // Pass 1: register macros from the preamble. MathJax's `html.convert`
  // takes raw math content (no \(...\) or \[...\] delimiters) and
  // processes it in math mode; the `newcommand` package handles bare
  // \newcommand / \def / \let / \DeclareMathOperator definitions in math
  // mode with no wrapping needed. Stop after compilation: generating SVG for
  // these discarded definitions adds work and may load unnecessary glyphs.
  // Try one string first, then recover individual blocks on errors.
  if (preamble && preamble.trim()) {
    try {
      await html.convertPromise(preamble, { ...opts, end: STATE.COMPILED });
    } catch {
      // A failed parse can already have applied definitions. Replay from a
      // clean context so, for example, \let cannot copy a partially redefined
      // macro from the failed attempt.
      html = makeDocument();
      for (const block of splitPreambleBlocks(preamble)) {
        try { await html.convertPromise(block, { ...opts, end: STATE.COMPILED }); } catch { /* swallow */ }
      }
    }
  }

  // Pass 2: render the equation. The caller passes math content WITHOUT
  // delimiters (the plugin strips them upstream), and `display` says whether
  // to render inline or display style. Errors here are caller-visible —
  // the plugin surfaces ok=false as a notification; no automatic fallback.
  const math = normalizeEquation(equation, !!display, display_math_style);
  const out = await html.convertPromise(math, { ...opts, display: !!display });
  // Use MathJax's XML serializer when available: MathJax 4 stamps every node
  // with a `data-latex` attribute holding its raw TeX, so `a < b` yields
  // data-latex="<". The HTML serializer (innerHTML) leaves </>/& unescaped in
  // attribute values — valid HTML but invalid XML — and librsvg's strict XML
  // parser (used by rsvg-convert downstream) rejects the file. serializeXML
  // escapes them (data-latex="&lt;") and declares xmlns:xlink.
  let svgStr = typeof adaptor.serializeXML === "function"
    ? adaptor.serializeXML(out)
    : adaptor.innerHTML(out);
  const m = svgStr.match(/<svg[\s\S]*<\/svg>/);
  if (m) svgStr = m[0];
  const viewBox = svgStr.match(/viewBox="([^"]+)"/);
  if (viewBox) {
    const nums = viewBox[1].trim().split(/\s+/).map(Number);
    if (nums.length === 4 && nums.every(Number.isFinite)) {
      const widthPx = Math.max(1, (nums[2] / 1000) * em);
      const heightPx = Math.max(1, (nums[3] / 1000) * em);
      svgStr = svgStr
        .replace(/\swidth="[^"]*"/, ` width="${widthPx.toFixed(3)}px"`)
        .replace(/\sheight="[^"]*"/, ` height="${heightPx.toFixed(3)}px"`);
    }
  }
  if (color && color !== "currentColor") {
    svgStr = svgStr.replace(/<svg\b/, `<svg fill="#${color}" color="#${color}"`);
    svgStr = svgStr.replace(/currentColor/g, `#${color}`);
  }
  if (!svgStr.startsWith("<?xml")) {
    svgStr = '<?xml version="1.0" encoding="UTF-8"?>\n' + svgStr;
  }
  return svgStr;
}

// ---------------------------------------------------------------------------
// Daemon mode. Newline-delimited JSON in / out.
// ---------------------------------------------------------------------------
async function runDaemon() {
  // Pre-warm so the first real request is fast.
  MJ = await bootMathJax();
  // Signal readiness to the parent. Snacks waits for this line before
  // dispatching queued requests.
  stdout.write(JSON.stringify({ ready: true }) + "\n");

  const rl = createInterface({ input: stdin, terminal: false });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let req;
    try {
      req = JSON.parse(trimmed);
    } catch (e) {
      stdout.write(JSON.stringify({ ok: false, err: "bad json: " + e.message }) + "\n");
      continue;
    }
    if (!req || typeof req !== "object" || Array.isArray(req)) {
      stdout.write(JSON.stringify({ ok: false, err: "request must be a JSON object" }) + "\n");
      continue;
    }
    if (req.quit) { exit(0); }
    try {
      const svg = await renderOne(req);
      stdout.write(JSON.stringify({ id: req.id, ok: true, svg }) + "\n");
    } catch (e) {
      stdout.write(JSON.stringify({
        id: req.id,
        ok: false,
        err: (e && e.message) ? e.message : String(e),
      }) + "\n");
    }
  }
}

// ---------------------------------------------------------------------------
// One-shot mode. Useful for tests and as an emergency fallback if the daemon
// pipe is wedged on the plugin side.
// ---------------------------------------------------------------------------
async function runOneShot(opts) {
  if (!opts.input || !opts.output) {
    stderr.write("usage: mathjax-daemon.mjs --in FILE --out FILE.svg [--display] [--color HEX]\n");
    stderr.write("  or:  mathjax-daemon.mjs --daemon  (stdin/stdout JSON protocol)\n");
    exit(2);
  }
  MJ = await bootMathJax();
  const raw = await fs.readFile(opts.input, "utf8");
  const SPLIT = /^%%% SNACKS-MATHJAX-SPLIT %%%\s*$/m;
  // Strip the leading "%% latex-preview: ..." (or "%% snacks-mathjax: ...")
  // metadata header if present. The plugin doesn't use one-shot mode, but
  // we accept either prefix so users who installed manually with old
  // intermediate files still get correct behavior.
  const noMeta = raw.replace(/^%%\s*(latex-preview|snacks-mathjax):[^\n]*\n/, "");
  const m = noMeta.split(SPLIT);
  const preamble = m.length > 1 ? m[0].trim() : "";
  const equation = (m.length > 1 ? m[1] : m[0]).trim();
  const svg = await renderOne({
    preamble, equation,
    display: opts.display, color: opts.color, ex: opts.ex,
  });
  await fs.writeFile(opts.output, svg, "utf8");
}

// ---------------------------------------------------------------------------
// Path-listing mode. Used by health.lua to read the canonical candidate
// list without having to mirror the resolution logic in Lua.
// ---------------------------------------------------------------------------
async function listPaths() {
  const candidates = await buildCandidatePaths({ includeNpm: true });
  for (const c of candidates) stdout.write(c + "\n");
}

async function main() {
  const opts = parseArgs(argv);
  if (opts.listPaths) return listPaths();
  if (opts.daemon) return runDaemon();
  return runOneShot(opts);
}

main().catch((e) => {
  stderr.write("mathjax-daemon fatal: " + (e && e.stack ? e.stack : String(e)) + "\n");
  exit(1);
});
