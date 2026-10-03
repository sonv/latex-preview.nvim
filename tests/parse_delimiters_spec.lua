-- Run with: NVIM_LOG_FILE=/tmp/latex-preview-nvim.log nvim --headless -u NONE -i NONE -l tests/parse_delimiters_spec.lua
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local parse = require('latex-preview.parse')
local failures = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end
local function equations(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = ft or 'tex'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local result = parse.find_equations(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  return result
end
local function texts(result)
  return vim.tbl_map(function(eq) return eq.text end, result)
end
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end

-- Force the fallback independently of locally installed parser versions.
package.loaded['nvim-treesitter.parsers'] = { has_parser = function() return true end }
local get_parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function() error('parser unavailable') end

test('escaped display and environment openers', function()
  equal(texts(equations({ [[\\[literal\\] \\(literal\\) \\begin{equation}literal\\end{equation}]], [[$actual$]] })), { 'actual' })
end)
test('escaped display closers', function()
  equal(texts(equations({ [[\[ x + \\] + y \] and \(z + \\) + w\)]] })), { [[x + \\] + y]], [[z + \\) + w]] })
end)
test('escaped display dollar opener', function()
  equal(texts(equations({ [[\$$literal]], [[$$actual$$]] })), { 'actual' })
end)
test('escaped dollar within display closing run', function()
  equal(texts(equations({ [[$$x + \$$$]] })), { [[x + \$]] })
end)
test('escaped dollar at end of inline math', function()
  equal(texts(equations({ [[$x + \$$]] })), { [[x + \$]] })
end)
test('adjacent inline equations', function()
  equal(texts(equations({ [[$a$$b$]] })), { 'a', 'b' })
end)
test('environment endings must match stars', function()
  equal(texts(equations({ [[\begin{equation}x\end{equation*}]] })), {})
end)
test('environment closer can be escaped', function()
  equal(texts(equations({ [[\begin{equation}x + \\end{equation} + y\end{equation}]] })), { [[\begin{equation}x + \\end{equation} + y\end{equation}]] })
end)
test('TeX comments and escaped percent', function()
  local lines = { [=[% $hidden$ $$hidden$$ \[hidden\]]=], [[$a$ % $hidden$]], [[\% $b$]], [[\\% $hidden$]], [[$c$]] }
  local result = equations(lines)
  equal(texts(result), { 'a', 'b', 'c' })
  equal({ result[3].start_row, result[3].start_col, result[3].end_col }, { 4, 0, 3 })
end)
test('commented display closer', function()
  equal(texts(equations({ [=[\[ x % \]]=], [=[+ y \]]=] })), { [[x % \]
+ y]] })
end)
test('verbatim percent does not start a TeX comment', function()
  equal(texts(equations({ [[\verb|%| $x$]], [[\verb*+%+ $y$ % $hidden$]] })), { 'x', 'y' })
end)
test('percent may delimit verbatim text', function()
  equal(texts(equations({ [[\verb%literal% $x$]], [[\verb*%literal% $y$]] })), { 'x', 'y' })
end)
test('escaped or incomplete verbatim commands do not hide comments', function()
  equal(texts(equations({ [[\\verb|% $hidden$]], [[\verbose % $hidden$]], [[\verb|unclosed % $hidden$]], [[$x$]] })), { 'x' })
end)
test('Markdown code fences and inline code', function()
  equal(texts(equations({ '```tex', '$hidden$', '```', '`$hidden$` and $a$', '~~~', '\\[hidden\\]', '~~~~', '``$hidden`too$`` and \\(b\\)' }, 'markdown')), { 'a', 'b' })
end)
test('Markdown prose percent is not a TeX comment', function()
  equal(texts(equations({ '50% of $a$' }, 'markdown')), { 'a' })
end)
test('Markdown code spans cannot cross fences or paragraphs', function()
  equal(texts(equations({ '` unmatched', '~~~', '$hidden$', '~~~', '$a$ then ` unmatched', '', '$b$ and ` unmatched' }, 'markdown')), { 'a', 'b' })
end)
test('Markdown multiline code spans preserve row coordinates', function()
  local result = equations({ '`some code', '$hidden$` and $a$' }, 'markdown')
  equal(texts(result), { 'a' })
  equal({ result[1].start_row, result[1].start_col, result[1].end_col }, { 1, 14, 17 })
end)

-- Exercise Tree-sitter normalization without depending on a parser binary.
local query_parse = vim.treesitter.query.parse
local get_node_text = vim.treesitter.get_node_text
local captured_text = ''
local node = { range = function() return 0, 0, 0, #captured_text end }
vim.treesitter.get_parser = function()
  return { parse = function() return { { root = function() return {} end } } end }
end
vim.treesitter.query.parse = function()
  return {
    captures = { 'inline' },
    iter_captures = function()
      local done = false
      return function()
        if done then return end
        done = true
        return 1, node
      end
    end,
  }
end
vim.treesitter.get_node_text = function() return captured_text end
for _, case in ipairs({
  { [[$x + \$$]], [[x + \$]] },
  { [[$$x + \$$$]], [[x + \$]] },
  { [=[\[\(x\)\]]=], [[\(x\)]] },
}) do
  test('strip exactly one paired delimiter: ' .. case[1], function()
    captured_text = case[1]
    equal(texts(equations({ captured_text })), { case[2] })
  end)
end
vim.treesitter.get_parser = get_parser
vim.treesitter.query.parse = query_parse
vim.treesitter.get_node_text = get_node_text
if pcall(vim.treesitter.language.add, 'markdown_inline') then
  test('real Markdown Tree-sitter captures in tilde fences are excluded', function()
    equal(texts(equations({ '~~~tex', '$hidden$', '~~~', '$a$ and `\\(hidden\\)` then \\(b\\)' }, 'markdown')), { 'a', 'b' })
  end)
end
assert(#failures == 0, table.concat(failures, '\n'))
print('parse delimiter regressions passed')
vim.cmd('qa!')
