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

local function strip_math_delimiters(text)
  local stripped = vim.trim(text)
  stripped = stripped
    :gsub("^%$%$", ""):gsub("%$%$$", "")
    :gsub("^%$", ""):gsub("%$$", "")
    :gsub("^\\%[", ""):gsub("\\%]$", "")
    :gsub("^\\%(", ""):gsub("\\%)$", "")

  if stripped:match("^\\begin%s*{[^}]+}") then
    -- MathJax needs the environment wrapper for AMS multiline environments
    -- such as align*, gather, multline, flalign, and eqnarray. Stripping it
    -- leaves bare alignment markers (`&`, `\\`) that fail with "Misplaced &".
    return stripped
  end

  return vim.trim(stripped)
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

---@param buf integer
---@return LatexPreview.Equation[]
local function regex_extract(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local source = table.concat(lines, "\n")
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

  -- Each entry: {pattern, display, kind}
  -- kind:
  --   "delim_match"  the capture is the math text directly
  --   "env"          keep the full environment wrapper for MathJax
  local patterns = {
    -- $$...$$ display, line-spanning. The capture is the body.
    { prefix = "$$", pat = "%$%$(.-)%$%$",          display = true,  kind = "delim_match" },
    -- \[...\] display
    { prefix = "\\[", pat = "\\%[(.-)\\%]",          display = true,  kind = "delim_match" },
    -- \(...\) inline
    { prefix = "\\(", pat = "\\%((.-)\\%)",          display = false, kind = "delim_match" },
    -- Math environments with optional star. Keep the wrapper so MathJax can
    -- interpret environment-specific alignment syntax.
    { prefix = "\\begin{equation", pat = "\\begin{equation%*?}(.-)\\end{equation%*?}", display = true, kind = "env" },
    { prefix = "\\begin{align", pat = "\\begin{align%*?}(.-)\\end{align%*?}",       display = true, kind = "env" },
    { prefix = "\\begin{alignat", pat = "\\begin{alignat%*?}%s*%b{}(.-)\\end{alignat%*?}", display = true, kind = "env" },
    { prefix = "\\begin{flalign", pat = "\\begin{flalign%*?}(.-)\\end{flalign%*?}",   display = true, kind = "env" },
    { prefix = "\\begin{gather", pat = "\\begin{gather%*?}(.-)\\end{gather%*?}",     display = true, kind = "env" },
    { prefix = "\\begin{multline", pat = "\\begin{multline%*?}(.-)\\end{multline%*?}", display = true, kind = "env" },
    { prefix = "\\begin{eqnarray", pat = "\\begin{eqnarray%*?}(.-)\\end{eqnarray%*?}", display = true, kind = "env" },
  }

  for _, p in ipairs(patterns) do
    local pos2 = 1
    while pos2 <= #source do
      -- Most documents use only a few delimiter types. A literal search
      -- avoids a full Lua-pattern scan for every absent environment.
      pos2 = source:find(p.prefix, pos2, true)
      if not pos2 then break end
      local s, e, body = source:find(p.pat, pos2)
      if not s then break end
      if not_consumed(s, e) then
        local text
        if p.kind == "env" then
          text = vim.trim(source:sub(s, e))
        else
          text = vim.trim(body or "")
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
        local body = source:sub(i + 1, closed - 1)
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
  return results
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
    if r then result = merge_non_overlapping(r, regex_extract(buf)) end
  end
  result = result or regex_extract(buf)
  cache[buf] = { tick = tick, ft = ft, value = result }
  return result
end

return M
