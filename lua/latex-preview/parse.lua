-- lua/latex-preview/parse.lua
--
-- Find math expressions in a buffer. Returns a list of {start_row,
-- end_row, text, display} entries.
--
-- Strategy:
--   * If treesitter has the `latex` parser installed (or `markdown_inline`
--     for markdown buffers), use treesitter queries — robust against `$`
--     in comments, verbatim, etc.
--   * Otherwise fall back to a regex pass that's good enough for typical
--     content. The regex path correctly handles \$, line-spanning $$...$$
--     blocks, \[ ... \] blocks, and \begin{equation} ... \end{equation}.
--
-- Coordinates are 0-indexed rows in the buffer (matches extmark API).

local M = {}

local util = require("latex-preview.util")

---@class LatexPreview.Equation
---@field start_row integer 0-indexed inclusive
---@field start_col integer 0-indexed inclusive
---@field end_row integer 0-indexed inclusive
---@field end_col integer 0-indexed exclusive
---@field text string The math content without inline/display delimiters.
---Environment delimiters are preserved for math environments that MathJax
---needs in order to interpret alignment markers such as `&` and `\\`.
---@field display boolean True for display-mode (\[, $$, \begin{equation*}, ...).

-- Treesitter path -----------------------------------------------------------

local TS_QUERIES = {
  latex = [[
    (inline_formula) @inline
    (displayed_equation) @display
    (math_environment) @display
  ]],
  markdown_inline = [[
    (latex_block) @any
  ]],
}
local ts_queries = {}

local math_delimiters = {
  { "$$", "$$", true },
  { "\\[", "\\]", true },
  { "\\(", "\\)", false },
  { "$", "$", false },
}

local function strip_math_delimiters(text)
  local stripped = vim.trim(text)
  for _, pair in ipairs(math_delimiters) do
    local opening, closing = pair[1], pair[2]
    if #stripped >= #opening + #closing
      and stripped:sub(1, #opening) == opening
      and stripped:sub(-#closing) == closing
    then
      -- Remove exactly one matching pair. Chained substitutions can remove
      -- an escaped dollar or a nested delimiter from the actual math body.
      return vim.trim(stripped:sub(#opening + 1, -#closing - 1))
    end
  end
  -- MathJax needs environment wrappers to interpret alignment syntax.
  return stripped
end

---@param buf integer
---@param lang string
---@return LatexPreview.Equation[]?
local function ts_extract(buf, lang)
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not util.has_ts_parser(ok and parsers or {}, lang) then return nil end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not ok_parser or not parser then return nil end
  local ok_parse, trees = pcall(parser.parse, parser)
  if not ok_parse then return nil end
  local tree = trees and trees[1]
  if not tree then return nil end

  local query_str = TS_QUERIES[lang]
  if not query_str then return nil end

  local query = ts_queries[lang]
  if not query then
    local ok_query
    ok_query, query = pcall(vim.treesitter.query.parse, lang, query_str)
    if not ok_query then return nil end
    ts_queries[lang] = query
  end
  local results = {}
  for id, node in query:iter_captures(tree:root(), buf) do
    local cap = query.captures[id]
    local sr, sc, er, ec = node:range()
    local text = vim.treesitter.get_node_text(node, buf) or ""
    local trimmed_text = vim.trim(text)
    local display = cap == "display"
    if cap == "any" then
      -- markdown_inline produces a `latex_block` for both inline and display.
      -- Differentiate by leading delimiter.
      display = trimmed_text:match("^%$%$")
        or trimmed_text:match("^\\%[")
        or trimmed_text:match("^\\begin")
    end
    -- Strip inline/display math delimiters. Preserve math-environment
    -- wrappers because MathJax needs them for environments such as align*.
    local stripped = strip_math_delimiters(text)
    if stripped ~= "" then
      results[#results + 1] = {
        start_row = sr, start_col = sc,
        end_row = er, end_col = ec,
        text = stripped,
        display = display and true or false,
      }
    end
  end
  return results
end

-- Regex fallback ------------------------------------------------------------

local function find_unescaped(source, delimiter, start)
  while true do
    local pos = source:find(delimiter, start, true)
    if not pos or not util.is_escaped(source, pos) then return pos end
    start = pos + 1
  end
end

-- Mask ignored text with spaces so byte offsets still refer to the buffer.
-- Keep the original source separately when extracting the math itself.
local function searchable_source(lines, ft)
  local is_tex = ft == "tex" or ft == "latex" or ft == "plaintex"
  local is_markdown = ft == "markdown" or ft == "rmd" or ft == "quarto"
  if not is_tex and not is_markdown then return table.concat(lines, "\n") end

  local searchable = {}
  local fence_char, fence_length
  for i, line in ipairs(lines) do
    if is_tex then
      local comment = util.tex_comment_start(line)
      searchable[i] = comment and (line:sub(1, comment - 1) .. string.rep(" ", #line - comment + 1)) or line
    else
      local fence, rest = line:match("^ ? ? ?([`~]+)(.*)$")
      local valid_fence = fence and #fence >= 3 and fence == string.rep(fence:sub(1, 1), #fence)
      if fence_char then
        searchable[i] = string.rep(" ", #line)
        if valid_fence and fence:sub(1, 1) == fence_char and #fence >= fence_length and rest:match("^%s*$") then
          fence_char, fence_length = nil, nil
        end
      elseif valid_fence and (fence:sub(1, 1) ~= "`" or not rest:find("`", 1, true)) then
        fence_char, fence_length = fence:sub(1, 1), #fence
        searchable[i] = string.rep(" ", #line)
      else
        searchable[i] = line
      end
    end
  end

  local source = table.concat(searchable, "\n")
  if not is_markdown or not source:find("`", 1, true) then return source end

  -- Code spans close with a backtick run of exactly the opening length.
  -- Index the next matching run once to avoid repeated scans for unmatched
  -- backticks in long Markdown buffers. Runs inside a span are skipped.
  local runs, next_length = {}, {}
  local pos, paragraph = 1, 1
  while true do
    local first, last = source:find("`+", pos)
    if not first then break end
    -- Blank lines end a paragraph. Masked fence lines also form a barrier,
    -- so a stray backtick cannot start a span across a fenced code block.
    if source:sub(pos, first - 1):find("\n[ \t]*\n") then paragraph = paragraph + 1 end
    runs[#runs + 1] = { first, last, nil, paragraph }
    pos = last + 1
  end
  local next_paragraph
  for i = #runs, 1, -1 do
    if runs[i][4] ~= next_paragraph then next_length = {} end
    local length = runs[i][2] - runs[i][1] + 1
    runs[i][3] = next_length[length]
    next_length[length] = i
    next_paragraph = runs[i][4]
  end
  local chunks, copied, i = {}, 1, 1
  while i <= #runs do
    local run = runs[i]
    if run[3] and not util.is_escaped(source, run[1]) then
      local last = runs[run[3]][2]
      chunks[#chunks + 1] = source:sub(copied, run[1] - 1)
      chunks[#chunks + 1] = source:sub(run[1], last):gsub("[^\n]", " ")
      copied, i = last + 1, run[3] + 1
    else
      i = i + 1
    end
  end
  chunks[#chunks + 1] = source:sub(copied)
  return table.concat(chunks)
end

local fallback_pairs = {}
for i = 1, 3 do
  local pair = math_delimiters[i]
  fallback_pairs[#fallback_pairs + 1] = { opening = pair[1], closing = pair[2], display = pair[3] }
end
for _, env in ipairs({ "equation", "align", "alignat", "flalign", "gather", "multline", "eqnarray" }) do
  for _, suffix in ipairs({ "", "*" }) do
    local name = env .. suffix
    fallback_pairs[#fallback_pairs + 1] = {
      opening = "\\begin{" .. name .. "}", closing = "\\end{" .. name .. "}", display = true, environment = true,
    }
  end
end

---@param buf integer
---@return LatexPreview.Equation[]
---@return fun(eq: LatexPreview.Equation): boolean visible True when a range contains no masked code/comment text.
local function regex_extract(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local original_source = table.concat(lines, "\n")
  local source = searchable_source(lines, vim.bo[buf].filetype)
  local results = {}

  -- For each match, we need to convert byte offsets back to (row, col).
  -- Build a row-start table.
  local row_starts = { 0 }
  local pos = 1
  while true do
    local nl = source:find("\n", pos, true)
    if not nl then break end
    row_starts[#row_starts + 1] = nl
    pos = nl + 1
  end
  local function byte_to_rc(byte)
    local lo, hi = 1, #row_starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if row_starts[mid] <= byte then lo = mid else hi = mid - 1 end
    end
    return lo - 1, byte - row_starts[lo]
  end

  -- Patterns ordered by specificity. Track consumed byte ranges as a
  -- sorted list of {lo, hi} intervals; overlap checks are O(log n) via
  -- binary search instead of O(range_size) via byte iteration.
  local consumed = {}
  local function not_consumed(s, e)
    local lo, hi = 1, #consumed
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local iv = consumed[mid]
      if iv[2] < s then lo = mid + 1
      elseif iv[1] > e then hi = mid - 1
      else return false end
    end
    return true
  end
  local function mark(s, e)
    consumed[#consumed + 1] = { s, e }
    local n = #consumed
    while n > 1 and consumed[n - 1][1] > s do
      consumed[n - 1], consumed[n] = consumed[n], consumed[n - 1]
      n = n - 1
    end
  end

  for _, p in ipairs(fallback_pairs) do
    local pos2 = 1
    while pos2 <= #source do
      local s = find_unescaped(source, p.opening, pos2)
      if not s then break end
      local closing = find_unescaped(source, p.closing, s + #p.opening)
      if not closing then break end
      local e = closing + #p.closing - 1
      if not_consumed(s, e) then
        local text
        if p.environment then
          text = vim.trim(original_source:sub(s, e))
        else
          text = vim.trim(original_source:sub(s + #p.opening, closing - 1))
        end
        if text ~= "" then
          local sr, sc = byte_to_rc(s - 1)
          local er, ec = byte_to_rc(e)
          results[#results + 1] = {
            start_row = sr, start_col = sc,
            end_row = er, end_col = ec,
            text = text,
            display = p.display,
          }
          mark(s, e)
        end
      end
      pos2 = e + 1
    end
  end

  -- Inline $...$. Done last because $$..$$ and \begin{...} contain $ chars
  -- that would otherwise be treated as inline math. We also need to skip
  -- escaped dollars (\$). Search directly for dollar delimiters rather than
  -- allocating a one-byte substring for every byte of prose. Find an unescaped
  -- $, look for a matching unescaped $ on the same line, and confirm the
  -- range doesn't overlap with anything already consumed.
  local i = 1
  while i <= #source do
    i = source:find("$", i, true)
    if not i then break end
    if not util.is_escaped(source, i) and not_consumed(i, i) then
      -- Find closing $ on the same line
      local j = i + 1
      local closed = nil
      while j <= #source do
        j = source:find("[$\n]", j)
        if not j then break end
        local c = source:sub(j, j)
        if c == "\n" then break end
        if c == "$" and not util.is_escaped(source, j) then
          closed = j
          break
        end
        j = j + 1
      end
      if closed and not_consumed(i, closed) then
        local body = original_source:sub(i + 1, closed - 1)
        body = vim.trim(body)
        if body ~= "" then
          local sr, sc = byte_to_rc(i - 1)
          local er, ec = byte_to_rc(closed)
          results[#results + 1] = {
            start_row = sr, start_col = sc,
            end_row = er, end_col = ec,
            text = body,
            display = false,
          }
          -- Inline matches are visited in order and skipped in full below;
          -- inserting them into the display intervals only adds quadratic
          -- table shifting for documents with interleaved inline/display math.
        end
        i = closed + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- Sort by start position so the manager can render them in document order.
  table.sort(results, function(a, b)
    if a.start_row ~= b.start_row then return a.start_row < b.start_row end
    return a.start_col < b.start_col
  end)
  local function visible(eq)
    local first = row_starts[eq.start_row + 1] + eq.start_col + 1
    local last = (row_starts[eq.end_row + 1] or #source) + eq.end_col
    return source:sub(first, last) == original_source:sub(first, last)
  end
  return results, visible
end

---@param equations LatexPreview.Equation[]
---@param candidate LatexPreview.Equation
---@return boolean
local function overlaps_any(equations, candidate)
  for _, eq in ipairs(equations) do
    local candidate_before = (candidate.end_row < eq.start_row)
      or (candidate.end_row == eq.start_row and candidate.end_col <= eq.start_col)
    local candidate_after = (candidate.start_row > eq.end_row)
      or (candidate.start_row == eq.end_row and candidate.start_col >= eq.end_col)
    if not candidate_before and not candidate_after then return true end
  end
  return false
end

---@param primary LatexPreview.Equation[]
---@param fallback LatexPreview.Equation[]
---@return LatexPreview.Equation[]
local function merge_non_overlapping(primary, fallback)
  local results = vim.deepcopy(primary)
  for _, eq in ipairs(fallback) do
    if not overlaps_any(results, eq) then
      results[#results + 1] = eq
    end
  end
  table.sort(results, function(a, b)
    if a.start_row ~= b.start_row then return a.start_row < b.start_row end
    return a.start_col < b.start_col
  end)
  return results
end

-- Public API ----------------------------------------------------------------

local cache = {}
local cache_cleanup_registered = false

local function ensure_cache_cleanup()
  if cache_cleanup_registered then return end
  cache_cleanup_registered = true
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("latex_preview_parse_cache", { clear = true }),
    callback = function(args)
      cache[args.buf] = nil
    end,
  })
end

---@param buf integer
---@return LatexPreview.Equation[]
function M.find_equations(buf)
  ensure_cache_cleanup()
  local ft = vim.bo[buf].filetype
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = cache[buf]
  if entry and entry.tick == tick and entry.ft == ft then
    return entry.value
  end

  local result
  -- Prefer treesitter for the filetypes where we have a query.
  if ft == "tex" or ft == "latex" or ft == "plaintex" then
    local r = ts_extract(buf, "latex")
    if r then result = r end
  elseif ft == "markdown" or ft == "rmd" or ft == "quarto" then
    local r = ts_extract(buf, "markdown_inline")
    local fallback, visible = regex_extract(buf)
    if r then
      -- The inline parser sees the entire buffer without the Markdown block
      -- grammar, so it can capture math in fences (notably tilde fences).
      r = vim.tbl_filter(visible, r)
      result = merge_non_overlapping(r, fallback)
    else
      result = fallback
    end
  end
  result = result or regex_extract(buf)
  cache[buf] = { tick = tick, ft = ft, value = result }
  return result
end

return M
