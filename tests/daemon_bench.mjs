// Warm daemon round-trip benchmark (including SVG serialization and IPC).
// node tests/daemon_bench.mjs [path/to/mathjax-daemon.mjs] [iterations]
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { startDaemon, defaultDaemon } from "./daemon_client.mjs";

const iterations = Number(process.argv[3] || 100);
assert(Number.isSafeInteger(iterations) && iterations > 0, "iterations must be a positive integer");
const daemon = await startDaemon(process.argv[2] || defaultDaemon);
const preamble = String.raw`\newcommand{\R}{\mathbb{R}}
\newcommand{\norm}[1]{\left\lVert #1\right\rVert}
\DeclareMathOperator{\supp}{supp}`;
const workloads = [
  ["inline", (i) => ({ equation: `x_{${i}}^2 + y^2 = z^2` })],
  ["preamble", (i) => ({ preamble, equation: `\\norm{x}_{${i}} + \\supp f \\subseteq \\R` })],
  ["display", (i) => ({ display: true, equation: `\\sum_{i=0}^{${i}} \\frac{x^i}{i!} = \\int_0^1 e^x\\,dx` })],
];
try {
  for (const [name, request] of workloads) {
    for (let i = 0; i < 20; i++) assert((await daemon.request(request(i))).ok);
    const times = [];
    for (let i = 0; i < iterations; i++) {
      const start = performance.now();
      const result = await daemon.request(request(i + 20));
      times.push(performance.now() - start);
      assert(result.ok, result.err);
    }
    times.sort((a, b) => a - b);
    const mean = times.reduce((sum, value) => sum + value, 0) / times.length;
    console.log(`${name}: mean ${mean.toFixed(2)} ms, median ${times[Math.floor(times.length / 2)].toFixed(2)} ms, p95 ${times[Math.ceil(times.length * .95) - 1].toFixed(2)} ms (${iterations} requests)`);
  }
} finally {
  daemon.close();
}
