-- Run with: nvim --headless -u NONE -l tests/parse_targets_spec.lua
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local parse = require('latex-preview.parse')
local targets = require('latex-preview.targets')
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'text'
local lines = {
  [[Before $a$ and \$literal, then $b + \$c$ after.]],
  [[$$d + e$$ and $f$]],
  [[\begin{align*}]], [[g &= h \\]], [[\end{align*}]],
  [[\[ i + j \] then \(k\)]],
  [[$x\label{first}$ and $y\label{second}$]],
  [[\ref{first}\eqref{second} outside]],
  [[\emph{\ref{second}}]],
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local equations = parse.find_equations(buf)
assert(#equations == 9, 'Expected 9 equations, got ' .. #equations)
assert(equations[1].text == 'a' and equations[1].start_col == 7 and equations[1].end_col == 10)
assert(equations[2].text == [[b + \$c]])
assert(equations[3].display and equations[3].text == 'd + e')
assert(equations[4].text == 'f' and not equations[4].display)
assert(equations[5].start_row == 2 and equations[5].end_row == 4)
assert(parse.find_equations(buf) == equations, 'Unchanged buffer should use parser cache')

vim.api.nvim_win_set_cursor(0, { 8, 11 })
assert(targets.reference_under_cursor(buf).label == 'second', 'Adjacent reference was skipped')
vim.api.nvim_win_set_cursor(0, { 8, lines[8]:find(' outside', 1, true) - 1 })
assert(targets.reference_under_cursor(buf) == nil, 'Reference extended past its closing brace')
vim.api.nvim_win_set_cursor(0, { 9, 10 })
assert(targets.reference_under_cursor(buf).label == 'second', 'Reference inside formatting command was skipped')

-- Parser availability can change while a buffer is open. A broken/unloaded
-- parser must fall back instead of aborting hover rendering.
package.loaded['nvim-treesitter.parsers'] = { has_parser = function() return true end }
local get_parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function() error('parser unavailable') end
vim.bo[buf].filetype = 'tex'
assert(#parse.find_equations(buf) == 9, 'Failed parser did not use regex fallback')
vim.treesitter.get_parser = get_parser
print('parse and target regressions passed')
vim.cmd('qa!')
