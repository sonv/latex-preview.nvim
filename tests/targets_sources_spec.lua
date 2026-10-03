-- nvim --headless -u NONE -i NONE -l tests/targets_sources_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local targets = vim.env.LATEX_PREVIEW_TEST_TARGETS and dofile(vim.env.LATEX_PREVIEW_TEST_TARGETS)
  or require("latex-preview.targets")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, root .. "/paper.tex")
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "tex"
local function source(lines, row, col)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { row or #lines, col or 2 })
end
local function write(name, text)
  local fd = assert(io.open(root .. "/" .. name, "w"))
  fd:write(text)
  fd:close()
end
local function text(target)
  assert(target, "missing target")
  return table.concat(target.lines or {}, "\n")
end
local failures = {}
local function check(name, test)
  local ok, err = pcall(test)
  if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end

check("reference commands in comments", function()
  source({ [[$x\label{eq}$]], [[% \ref{eq}]] }, 2, 4)
  assert(targets.reference_under_cursor(buf) == nil, "commented reference was active")
  source({ [[$x\label{eq}$]], [[\% \ref{eq}]] }, 2, 5)
  assert(targets.reference_under_cursor(buf), "escaped percent hid the reference")
end)

check("commented equation labels", function()
  source({ [[\begin{equation}]], [[x % \label{eq}]], [[\end{equation}]],
    [[\begin{equation}]], [[y \label{eq}]], [[\end{equation}]], [[\ref{eq}]] })
  assert(targets.reference_under_cursor(buf).equation.text:find("y", 1, true), "commented label won over the real label")
end)

check("verbatim percent before references and labels", function()
  for _, verb in ipairs({ [[\verb|%|]], [[\verb*+%+]] }) do
    source({ [[$x\label{eq}$]], verb .. [[ \ref{eq}]] }, 2, #verb + 2)
    assert(targets.reference_under_cursor(buf), "verbatim percent hid the reference")
    source({ [[\begin{theorem}]], "The token " .. verb .. [[ means percent. \label{thm}]],
      [[\end{theorem}]], [[\ref{thm}]] })
    assert(targets.theorem_reference_under_cursor(buf), "verbatim percent hid the theorem label")
    source({ [[$x\label{eq}$]], verb .. [[ % \ref{eq}]] }, 2, #verb + 4)
    assert(targets.reference_under_cursor(buf) == nil, "comment after verbatim was active")
  end
end)

check("commented theorem boundaries", function()
  source({ [[\begin{theorem}]], [[Statement. \label{thm}]], [[% \end{theorem}]],
    [[Still in the theorem.]], [[\end{theorem}]], [[\ref{thm}]] })
  assert(text(targets.theorem_reference_under_cursor(buf)):find("Still in the theorem.", 1, true), "comment ended theorem early")
end)

write("ignored.bib", "@article{key, title={Ignored}}")
write("refs.bib", "@article{key, title={Saved}}")
check("commented bibliography declarations", function()
  source({ [[% \bibliography{ignored}]], [[\bibliography{refs}]], [[\cite{key}]] })
  assert(text(targets.citation_under_cursor(buf)):find("Saved", 1, true), "commented bibliography was searched")
end)

check("unsaved bibliography edits", function()
  local bib = vim.fn.bufadd(root .. "/refs.bib")
  vim.fn.bufload(bib)
  vim.api.nvim_buf_set_lines(bib, 0, -1, false, { "@article{key, title={Unsaved}}" })
  source({ [[\bibliography{refs}]], [[\cite{key}]] })
  assert(text(targets.citation_under_cursor(buf)):find("Unsaved", 1, true), "citation reread stale disk contents")
end)

write("parentheses.bib", '@article(key, title={An unmatched ) in a title}, note="Another ) here", year={2026})')
check("parentheses inside bibliography fields", function()
  source({ [[\bibliography{parentheses}]], [[\cite{key}]] })
  assert(text(targets.citation_under_cursor(buf)):find("year={2026}", 1, true), "entry ended inside a field value")
end)

write("nested.bib", [[@comment{ @article{key, title={Fake}} }
@article{other, note={Example @article{key, title={Also fake}}}}
@article{key, title={Actual}}
]])
check("entry-shaped text in bibliography comments and values", function()
  source({ [[\bibliography{nested}]], [[\cite{key}]] })
  assert(text(targets.citation_under_cursor(buf)):find("Actual", 1, true), "entry found inside a comment or another entry")
end)

vim.fn.delete(root, "rf")
assert(#failures == 0, table.concat(failures, "\n"))
print("target source regressions passed")
vim.cmd("qa!")
