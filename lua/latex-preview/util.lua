-- lua/latex-preview/util.lua
--
-- Shared helpers used by multiple modules.

local M = {}

---True iff the character at `idx` in `str` is preceded by an odd number
---of consecutive backslashes — i.e. it is "escaped" by an unbalanced `\`.
---`\\$` is NOT escaped (the `\\` is a literal backslash); `\$` IS escaped.
---@param str string
---@param idx integer 1-indexed character position
---@return boolean
function M.is_escaped(str, idx)
  local count = 0
  local i = idx - 1
  while i >= 1 and str:sub(i, i) == "\\" do
    count = count + 1
    i = i - 1
  end
  return count % 2 == 1
end

---Return the first TeX comment marker, skipping escaped characters and valid
---single-line \verb/\verb* spans, whose contents treat percent literally.
---@param line string
---@return integer?
function M.tex_comment_start(line)
  local pos = 1
  while pos <= #line do
    local first = line:find("[\\%%]", pos)
    if not first then return nil end
    if line:sub(first, first) == "%" then return first end

    local closing
    if line:sub(first, first + 4) == "\\verb" then
      local delimiter_pos = first + 5
      local starred = line:sub(delimiter_pos, delimiter_pos) == "*"
      if starred then delimiter_pos = delimiter_pos + 1 end
      local delimiter = line:sub(delimiter_pos, delimiter_pos)
      -- Without a star, a letter continues the control sequence name
      -- (e.g. \verbose) and therefore cannot delimit a \verb command.
      if delimiter ~= "" and not delimiter:match("%s") and (starred or not delimiter:match("%a")) then
        closing = line:find(delimiter, delimiter_pos + 1, true)
      end
    end
    -- Otherwise skip the escaped character after this backslash. Visiting
    -- backslash pairs once also handles odd/even escape parity in linear time.
    pos = closing and (closing + 1) or (first + 2)
  end
  return nil
end

---Return true if the given treesitter language parser is available.
---`parsers` is the result of `require("nvim-treesitter.parsers")`.
---@param parsers table
---@param lang string
---@return boolean
function M.has_ts_parser(parsers, lang)
  if type(parsers.has_parser) == "function" then
    local ok, found = pcall(parsers.has_parser, lang)
    if ok then return found == true end
  end
  local ts_lang = vim.treesitter and vim.treesitter.language
  if ts_lang and type(ts_lang.has_parser) == "function" then
    local ok, found = pcall(ts_lang.has_parser, lang)
    if ok then return found == true end
  end
  if ts_lang and type(ts_lang.inspect) == "function" then
    local ok, info = pcall(ts_lang.inspect, lang)
    return ok and type(info) == "table"
  end
  if ts_lang and type(ts_lang.add) == "function" then
    local ok, found = pcall(ts_lang.add, lang)
    return ok and found == true
  end
  return false
end

return M
