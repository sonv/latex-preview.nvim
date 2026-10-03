// Regression checks for request isolation and preamble/error recovery.
// Run: node tests/daemon_state_spec.mjs [path/to/mathjax-daemon.mjs]
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { startDaemon, defaultDaemon } from "./daemon_client.mjs";

const script = process.argv[2] || defaultDaemon;
let daemon;
before(async () => { daemon = await startDaemon(script); });
after(() => daemon?.close());

async function render(equation, options = {}) {
  const result = await daemon.request({ equation, ...options });
  assert(result.ok, result.err);
  return result.svg;
}

function drawing(svg) {
  // Ignore source annotations and per-document glyph IDs, preserving glyph
  // paths, transforms, colors and dimensions for a visual-output comparison.
  return svg.replace(/ data-latex[^=]*="[^"]*"/g, "").replace(/MJX-\d+-/g, "MJX-N-");
}

test("preamble changes and equation definitions are isolated between requests", async () => {
  const x = drawing(await render("x"));
  const y = drawing(await render("y"));
  assert.equal(drawing(await render(String.raw`\foo`, { preamble: String.raw`\newcommand{\foo}{x}` })), x);
  assert.equal(drawing(await render(String.raw`\foo`, { preamble: String.raw`\newcommand{\foo}{y}` })), y);
  assert.equal((await daemon.request({ equation: String.raw`\foo` })).ok, false);
  await render(String.raw`\def\foo{x}\foo`);
  assert.equal((await daemon.request({ equation: String.raw`\foo` })).ok, false);
  assert.equal((await daemon.request({ equation: String.raw`\def\foo{x}\unknown` })).ok, false);
  assert.equal((await daemon.request({ equation: String.raw`\foo` })).ok, false);
  assert.equal(drawing(await render("x")), x);
});

test("shared font data does not leak colors, environments or parser options", async () => {
  await render(String.raw`\textcolor{localcolor}{x}`, { preamble: String.raw`\definecolor{localcolor}{RGB}{12,34,56}` });
  const color = await render(String.raw`\textcolor{localcolor}{x}`);
  assert(!color.includes("#0c2238"), "custom color definition leaked");
  await render(String.raw`\begin{localenv}x\end{localenv}`, { preamble: String.raw`\newenvironment{localenv}{\left(}{\right)}` });
  assert.equal((await daemon.request({ equation: String.raw`\begin{localenv}x\end{localenv}` })).ok, false);
  const normal = drawing(await render(String.raw`\colorbox{red}{x}`));
  const changed = drawing(await render(String.raw`\colorbox{red}{x}`, { preamble: String.raw`\setOptions[color]{padding=20px}` }));
  assert.notEqual(changed, normal);
  assert.equal(drawing(await render(String.raw`\colorbox{red}{x}`)), normal);
});

test("font reuse keeps SVG glyphs self-contained across sizes and font extensions", async () => {
  const equation = String.raw`\mathds{1}+\mathbbm{1}+\mathcal{F}+\mathfrak{g}`;
  const original = await render(equation, { font_size: 11, color: "112233" });
  const larger = await render(equation, { font_size: 22, color: "445566" });
  const width = (svg) => Number(svg.match(/\bwidth="([\d.]+)px"/)[1]);
  assert(Math.abs(width(larger) - 2 * width(original)) < .002);
  assert(larger.includes("#445566"));
  assert(!larger.includes("#112233"));
  assert.equal(drawing(await render(equation, { font_size: 11, color: "112233" })), drawing(original));
  const ids = new Set([...original.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));
  for (const match of original.matchAll(/xlink:href="#([^"]+)"/g)) {
    assert(ids.has(match[1]), `missing local glyph ${match[1]}`);
  }
});

test("mathbb keeps the built-in double-struck glyphs", async () => {
  const glyphPaths = (svg) => [...svg.matchAll(/<path\b[^>]*\bd="([^"]+)"/g)].map((match) => match[1]);
  const mathbb = glyphPaths(await render(String.raw`\mathbb{R}`));
  assert(mathbb.length > 0, "expected a rendered glyph");
  assert.deepEqual(mathbb, glyphPaths(await render("ℝ")));
  assert.notDeepEqual(mathbb, glyphPaths(await render(String.raw`\mathrm{R}`)));
});

test("preamble fallback preserves multiline bodies across comments and blank lines", async () => {
  const preamble = String.raw`\unsupported
\newcommand{\foo}{
x+
% a comment containing a misleading }

y
}
\makeatletter
\newcommand{\barvalue}{z}`;
  assert.equal(drawing(await render(String.raw`\foo+\barvalue`, { preamble })), drawing(await render("x+y+z")));
});

test("preamble fallback starts before partially applied macro redefinitions", async () => {
  const preamble = String.raw`\let\originalsin\sin
\def\sin{x}
\unsupported`;
  assert.equal(drawing(await render(String.raw`\originalsin y`, { preamble })), drawing(await render(String.raw`\sin y`)));
});

test("multiline display comments retain their line endings", async () => {
  const commented = await render("x + % this should not hide y\ny", { display: true });
  assert.equal(drawing(commented), drawing(await render("x+y", { display: true })));
});

test("one-shot input without a split marker is evaluated exactly once", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "lpnvim-daemon-state-"));
  try {
    const input = path.join(dir, "equation.tex");
    const output = path.join(dir, "equation.svg");
    await writeFile(input, String.raw`\let\originalsin\sin\def\sin{x}\originalsin y`);
    await promisify(execFile)(process.execPath, [script, "--in", input, "--out", output, "--color", "currentColor"]);
    assert.equal(drawing(await readFile(output, "utf8")), drawing(await render(String.raw`\sin y`)));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("malformed requests return errors and leave the daemon usable", async () => {
  for (const line of ["{broken", "null", "[]", "42", '"equation"']) {
    const result = await daemon.raw(line);
    assert.equal(result.ok, false, line);
    assert.equal(typeof result.err, "string");
    await render("x");
  }
  assert.equal((await daemon.request({ equation: String.raw`\notDefined` })).ok, false);
  await render("x");
});
