-- Run from the plugin checkout:
--   nvim --headless -u NONE -l bench/parse_extract_bench.lua
-- Optionally compare another checkout with the same fixtures and process:
--   LATEX_PREVIEW_BENCH_BASELINE=/path/to/old/checkout nvim --headless -u NONE -l bench/parse_extract_bench.lua
-- These timings measure Lua parsing and preamble preparation, not MathJax,
-- rasterization, or terminal image display.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local uv = vim.uv or vim.loop
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/chapters', 'p')
local function write(path, text)
  local f = assert(io.open(path, 'w')); f:write(text); f:close()
end
write(root .. '/macros.sty', [[\newcommand{\stylemacro}{S}]])
write(root .. '/paper.tex', [[\usepackage{macros}
\newcommand{\rootmacro}{R}
\begin{document}
\input{chapters/body}
\end{document}
]])
write(root .. '/chapters/body.tex', '$x$\n')
require('latex-preview.config').setup({ extract = { scan_sty = true } })
local chapter = vim.fn.bufadd(root .. '/chapters/body.tex')
vim.fn.bufload(chapter)
local baseline = vim.env.LATEX_PREVIEW_BENCH_BASELINE
local original = baseline and dofile(baseline .. '/lua/latex-preview/extract.lua')
local current = dofile('./lua/latex-preview/extract.lua')
local function bench_preamble(label, extract)
  extract.get_preamble(chapter)
  local old, reads = io.open, 0
  io.open = function(...) reads = reads + 1; return old(...) end
  local start = uv.hrtime()
  for _ = 1, 500 do extract.get_preamble(chapter) end
  local elapsed = (uv.hrtime() - start) / 1e6
  io.open = old
  print(string.format('%s cached chapter preamble: %.4f ms/call, %d file reads per 500 calls', label, elapsed/500, reads))
end
if original then bench_preamble('Baseline', original) end
bench_preamble('Current', current)
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = 'text'
local lines = {}
for i = 1, 4000 do
  if i % 5 == 0 then lines[i] = '$$x_' .. i .. '+y$$ prose $a+b$ more prose'
  elseif i % 3 == 0 then lines[i] = 'Some mathematical prose and equations $a_' .. i .. '+b$ more text here.'
  else lines[i] = string.rep('Document prose with no math. ', 3) end
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local original_parse = baseline and dofile(baseline .. '/lua/latex-preview/parse.lua')
local current_parse = dofile('./lua/latex-preview/parse.lua')
local function bench_parse(label, parse)
  local start = uv.hrtime()
  local eqs
  for i = 1, 30 do
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'Changed prose ' .. i })
    eqs = parse.find_equations(buf)
  end
  print(string.format('%s uncached parse: %.3f ms/call (%d equations, %d bytes)', label, (uv.hrtime()-start)/1e6/30, #eqs, #table.concat(lines, '\n')))
  return eqs
end
local original_eqs = original_parse and bench_parse('Baseline', original_parse)
local current_eqs = bench_parse('Current', current_parse)
if original_eqs then
  assert(vim.deep_equal(original_eqs, current_eqs), 'Parsing results differ from baseline')
end
vim.fn.delete(root, 'rf')
vim.cmd('qa!')
