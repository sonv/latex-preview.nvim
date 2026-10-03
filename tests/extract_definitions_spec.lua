-- Run with: nvim --headless -u NONE -l tests/extract_definitions_spec.lua
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local config = require('latex-preview.config')
config.setup({ extract = { scan_sty = true, sty_search_depth = 4 } })
local extract = require('latex-preview.extract')
local function contains(text, expected)
  assert(text:find(expected, 1, true), 'Expected ' .. expected .. ' in:\n' .. text)
end

-- Balanced command-name braces do not finish a definition: the replacement
-- text, xparse argument specification, and environment end code can follow.
local definitions = {
  { [[\newcommand{\split}]], '  [1][{default}]', [[  {#1 + 1}]] },
  { [[\renewcommand*\split]], '  [1]', [[  {#1 + 2}]] },
  { [[\providecommand]], [[  {\provided}]], [[  {P}]] },
  { [=[\newenvironment{splitenv}[1]]=], [[  {\left(#1}]], [[  {\right)}]] },
  { [[\NewDocumentCommand{\documented}]], [[  {m}]], [[  {#1}]] },
  { [[\DeclareMathOperator*{\argmax}]], [[  {arg\,max}]] },
  { [[\DeclarePairedDelimiter{\abs}]], [[  {\lvert}]], [[  {\rvert}]] },
  { [[\newcommand{\first}{F} \newcommand{\second}]], [[  {S}]] },
  { [[\def\nested#1{]], [[  \{#1\}]], [[}]] },
  { [[\let\originaldef\def]] },
  { [[\let\originalsin\sin \newcommand{\reviewmacro}{]], 'x+y', '}' },
  { [[\let\originaldef=\def \newcommand{\reviewmacro}]], '{x+y}' },
}
for _, lines in ipairs(definitions) do
  assert(extract.extract_definitions(lines) == table.concat(lines, '\n'),
    'Definition was truncated:\n' .. table.concat(lines, '\n'))
end
assert(extract.extract_definitions({ [[\\newcommand{\fake}{F}]] }) == '',
  'An escaped declaration must not become a definition')
assert(extract.extract_definitions({ [[\newcommand{\unfinished}]], [[\begin{document}]], '$body$' })
  == [[\newcommand{\unfinished}]], 'An unfinished definition swallowed the document body')

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end
local function buffer(path, lines)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if lines then vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
  return buf
end

local paper = root .. '/paper.tex'
write(paper, [[\usepackage{macros}
\input{local/first}
\input{elsewhere/first}
\DeclareMathOperator*{\argmax}{arg\,max}
\begin{document}
]])
local buf = buffer(paper)
local preamble = extract.get_preamble(buf)
contains(preamble, [[\DeclareMathOperator*{\argmax}{arg\,max}]])

-- Missing references are dependencies too: creating one must invalidate an
-- already-warm preamble cache without editing the source buffer.
write(root .. '/macros.sty', [[\newcommand{\appeared}{A}]])
contains(extract.get_preamble(buf), [[\newcommand{\appeared}{A}]])

-- The same input name in two directories refers to two different files.
write(root .. '/local/first.tex', [[\input{second}]])
write(root .. '/local/second.tex', [[\newcommand{\localmacro}{L}]])
write(root .. '/elsewhere/first.tex', [[\input{second}]])
write(root .. '/elsewhere/second.tex', [[\newcommand{\othermacro}{O}]])
preamble = extract.get_preamble(buf)
contains(preamble, [[\newcommand{\localmacro}{L}]])
contains(preamble, [[\newcommand{\othermacro}{O}]])

-- Loading an unsaved dependency should work even before its first write.
buffer(root .. '/local/unsaved.tex', { [[\newcommand{\unsavedmacro}{U}]] })
write(root .. '/local/second.tex', [[\input{unsaved}
\newcommand{\localmacro}{L}]] )
contains(extract.get_preamble(buf), [[\newcommand{\unsavedmacro}{U}]])

vim.fn.delete(root, 'rf')
print('extract definition regressions passed')
vim.cmd('qa!')
