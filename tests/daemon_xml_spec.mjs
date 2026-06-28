// Regression spec for the MathJax daemon's SVG serialization.
//
// MathJax 4 stamps every output node with a `data-latex` attribute holding its
// raw TeX source, so an equation like `a < b` produces literally
// data-latex="<". If the daemon serializes with the HTML serializer
// (adaptor.innerHTML), those </>/& stay unescaped in the attribute value:
// valid HTML, but invalid XML. The downstream rasterizer rsvg-convert
// (librsvg) uses a strict XML parser and rejects the file with
// "Unescaped '<' not allowed in attributes values". The daemon must serialize
// with adaptor.serializeXML so attribute values are entity-escaped.
//
// This spec renders each trigger case (and a few controls) via the daemon's
// one-shot mode, asserts no raw </>/& survives inside any attribute value, and
// — when rsvg-convert is on PATH — asserts it accepts the SVG. Run locally:
//
//   node tests/daemon_xml_spec.mjs
//
// Requires a @mathjax/src@4 install (same as the daemon). Exits non-zero on
// the first failure.

import { execFile, execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const daemon = path.join(here, "..", "scripts", "mathjax-daemon.mjs");

// Equations whose TeX contains <, > or &, which the buggy HTML serializer left
// unescaped in data-latex attributes.
const TRIGGERS = [
  "a < b",
  "\\text{if } x < y",
  "\\xrightarrow{a<b} c",
  "\\overset{<}{=}",
];
// Ordinary equations that must keep rendering.
const CONTROLS = [
  "\\frac{a}{b}",
  "E=mc^2",
  "\\sum_{i=0}^{n} i^2",
];

const hasRsvg = spawnSync("rsvg-convert", ["--version"], { stdio: "ignore" }).status === 0;

// Return the offending attribute value if any attribute holds a raw < or >, or
// an unescaped & (an & not starting a recognized entity). null if clean.
function badAttribute(svg) {
  const attrRe = /=\s*"([^"]*)"/g;
  let m;
  while ((m = attrRe.exec(svg)) !== null) {
    const val = m[1];
    if (val.includes("<") || val.includes(">")) return val;
    if (/&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/.test(val)) return val;
  }
  return null;
}

async function checkEquation(dir, idx, eq) {
  const tex = path.join(dir, `eq${idx}.tex`);
  const out = path.join(dir, `eq${idx}.svg`);
  await writeFile(tex, eq, "utf8");
  await execFileP("node", [daemon, "--in", tex, "--out", out]);
  const svg = await readFile(out, "utf8");

  const bad = badAttribute(svg);
  if (bad !== null) {
    throw new Error(`unescaped markup in an attribute value: ${JSON.stringify(bad)}`);
  }
  if (hasRsvg) {
    execFileSync("rsvg-convert", ["-o", path.join(dir, `eq${idx}.png`), out], { stdio: "pipe" });
  }
}

async function main() {
  const dir = await mkdtemp(path.join(tmpdir(), "lpnvim-daemon-xml-"));
  let failed = 0;
  try {
    const cases = [...TRIGGERS, ...CONTROLS];
    for (let i = 0; i < cases.length; i++) {
      try {
        await checkEquation(dir, i, cases[i]);
        console.log(`ok   ${cases[i]}`);
      } catch (e) {
        failed++;
        console.error(`FAIL ${cases[i]}\n     ${e.message.split("\n")[0]}`);
      }
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
  if (!hasRsvg) {
    console.warn("note: rsvg-convert not on PATH; skipped rasterization check");
  }
  if (failed > 0) {
    console.error(`\n${failed} case(s) failed`);
    process.exit(1);
  }
  console.log("\nall daemon XML cases passed");
}

main().catch((e) => {
  console.error("daemon_xml_spec fatal:", e && e.stack ? e.stack : String(e));
  process.exit(1);
});
