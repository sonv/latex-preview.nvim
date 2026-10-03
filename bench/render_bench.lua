-- Run from the repository root: nvim --headless -u NONE -i NONE -l bench/render_bench.lua
-- Requires MathJax 4 and rsvg-convert. Measures completed PNGs, not popup placement.
-- Optional: LATEX_PREVIEW_BENCH_RENDER=/path/to/render.lua and
-- LATEX_PREVIEW_BENCH_DAEMON=/path/to/mathjax-daemon.mjs for before/after runs.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local uv = vim.uv or vim.loop
local config = require("latex-preview.config")
local daemon_path = vim.env.LATEX_PREVIEW_BENCH_DAEMON or (vim.fn.getcwd() .. "/scripts/mathjax-daemon.mjs")
config.setup({
  cache = false,
  daemon = { cmd = { "node", daemon_path, "--daemon" } },
  render = { fg = "#d8dee9", density = 300, svg_to_png = "rsvg", pad_to_cells = true },
  snacks = { max_cache_files = 0, max_cache_bytes = 0 },
})
package.loaded["snacks"] = { image = { terminal = { size = function()
  return { cell_width = 10, cell_height = 20 }
end } } }
local render = vim.env.LATEX_PREVIEW_BENCH_RENDER and dofile(vim.env.LATEX_PREVIEW_BENCH_RENDER)
  or require("latex-preview.render")
local function once(equation, preamble, display)
  local done, err, path = false, nil, nil
  local started = uv.hrtime()
  render.render({ equation = equation, preamble = preamble or "", display = display or false, live = true }, function(e, p)
    err, path, done = e, p, true
  end)
  assert(vim.wait(15000, function() return done end, 1), "render timed out")
  assert(not err, err)
  assert(path and uv.fs_stat(path), "missing PNG")
  return (uv.hrtime() - started) / 1e6
end
local function measure(label, equation, preamble, display, count)
  local samples, total = {}, 0
  for i = 1, count do
    local elapsed = once(equation(i), preamble, display)
    samples[#samples + 1], total = elapsed, total + elapsed
  end
  table.sort(samples)
  print(("%-20s mean %7.2f ms  median %7.2f ms  p95 %7.2f ms  n=%d"):format(
    label, total / count, samples[math.ceil(count / 2)], samples[math.ceil(count * 0.95)], count))
end
print(("cold PNG             %7.2f ms"):format(once("x + 0")))
measure("warm inline PNG", function(i) return "x + " .. i end, "", false, 40)
measure("warm macro PNG", function(i) return "\\RR + " .. i end, "\\newcommand{\\RR}{\\mathbb{R}}", false, 40)
measure("warm display PNG", function(i) return "\\sum_{k=0}^{" .. i .. "} \\frac{1}{k!}" end, "", true, 40)
measure("cached PNG", function() return "x + 1" end, "", false, 100)
require("latex-preview.daemon").shutdown()
vim.cmd("qa!")
