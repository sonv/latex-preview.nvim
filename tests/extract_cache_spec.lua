-- Run with: nvim --headless -u NONE -l tests/extract_cache_spec.lua
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local config = require('latex-preview.config')
config.setup({ extract = { scan_sty = true, sty_search_depth = 4 } })
local extract = require('latex-preview.extract')
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/chapters', 'p')
local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end
local function contains(text, expected)
  assert(text:find(expected, 1, true), 'Expected ' .. expected .. ' in:\n' .. text)
end
local function buffer(path, lines)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if lines then vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
  return buf
end
write(root .. '/macros.sty', [[\newcommand{\stylemacro}{OLD}]])
write(root .. '/paper.tex', [[\documentclass{article}
\usepackage{macros}
\providecommand{\rootmacro}{R}
\begin{document}
\input{chapters/body}
\end{document}
]])
write(root .. '/chapters/body.tex', '$x$\n')
local chapter = buffer(root .. '/chapters/body.tex')
contains(extract.get_preamble(chapter), [[\newcommand{\rootmacro}{R}]])

-- Cache hits should inspect signatures without reading the root or inputs.
local original_open, reads = io.open, 0
io.open = function(...)
  reads = reads + 1
  return original_open(...)
end
local cached = extract.get_preamble(chapter)
io.open = original_open
assert(reads == 0, 'A warm preamble lookup reread ' .. reads .. ' files')
contains(cached, [[\stylemacro}{OLD}]])

vim.api.nvim_buf_set_lines(chapter, 0, -1, false, { [[\newcommand{\chaptermacro}{C}]], '$y$' })
reads = 0
io.open = function(...)
  reads = reads + 1
  return original_open(...)
end
local edited = extract.get_preamble(chapter)
io.open = original_open
assert(reads == 0, 'Editing a chapter reread unchanged root or style sources')
contains(edited, [[\chaptermacro}{C}]])

-- Dependency signatures include loaded buffers; extraction must use them too.
local style = buffer(root .. '/macros.sty', { [[\newcommand{\stylemacro}{NEW}]] })
contains(extract.get_preamble(chapter), [[\stylemacro}{NEW}]])
vim.api.nvim_buf_set_lines(style, 0, -1, false, { [[\newcommand{\stylemacro}{NEWER}]] })
contains(extract.get_preamble(chapter), [[\stylemacro}{NEWER}]])

config.options.extract.rewrite_providecommand = false
contains(extract.get_preamble(chapter), [[\providecommand{\rootmacro}{R}]])
config.options.extract.scan_sty = false
assert(not extract.get_preamble(chapter):find('stylemacro', 1, true), 'Changed extraction options left a stale cache')
config.options.extract.scan_sty = true

-- Unfinished braced commands occur during typing. Bound Lua instructions so
-- the regression fails promptly instead of hanging the editor/test runner.
local unfinished = buffer(root .. '/unfinished.tex', {
  [[\usepackage{]], [[\input{]], [[\newcommand{\survives}{S}]], [[\begin{document}]],
})
local instructions = 0
debug.sethook(function()
  instructions = instructions + 1
  if instructions > 500 then error('Unfinished argument did not terminate') end
end, '', 1000)
local ok, value = pcall(extract.get_preamble, unfinished)
debug.sethook()
assert(ok, value)
contains(value, [[\survives}{S}]])

-- Cached parent resolution must respond to unsaved inclusion-graph edits.
local paper = buffer(root .. '/paper.tex', {
  [[\newcommand{\rootmacro}{R}]], [[\begin{document}]], [[\end{document}]],
})
assert(not extract.get_preamble(chapter):find('rootmacro', 1, true), 'Root resolution ignored an unsaved include removal')
vim.api.nvim_buf_set_lines(paper, 2, 2, false, { [[\input{chapters/body}]] })
contains(extract.get_preamble(chapter), [[\rootmacro}{R}]])

vim.fn.delete(root, 'rf')
print('extract cache regressions passed')
vim.cmd('qa!')
