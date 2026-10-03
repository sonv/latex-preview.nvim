-- lua/latex-preview/targets.lua
--
-- Hover targets beyond "the equation under the cursor":
--   * \ref/\eqref-style commands resolve to the labeled equation.
--   * \ref/\cref-style commands resolve to labeled theorem-like blocks.
--   * \cite-style commands resolve to BibTeX entries from local .bib files.

local M = {}

local uv = vim.uv or vim.loop
local parse = require("latex-preview.parse")
local util = require("latex-preview.util")

local REF_COMMANDS = {
  ref = true,
  eqref = true,
  autoref = true,
  cref = true,
  Cref = true,
  vref = true,
  Vref = true,
}

local THEOREM_ENVS = {
  theorem = true,
  thm = true,
  lemma = true,
  lem = true,
  proposition = true,
  prop = true,
  definition = true,
  defn = true,
  defi = true,
}

local function strip_star(cmd)
  return cmd:gsub("%*$", "")
end

local function loaded_buffer(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) == path then
        return buf
      end
    end
  end
end

local function read_lines(path)
  local buf = loaded_buffer(path)
  if buf then return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
  local fd = io.open(path, "r")
  if not fd then return nil end
  local lines = {}
  for line in fd:lines() do lines[#lines + 1] = line end
  fd:close()
  return lines
end

-- Percent starts a comment in TeX source, but remains ordinary prose in
-- Markdown. Keep the prefix unchanged so command columns stay accurate.
local function source_line(buf, line)
  local ft = vim.bo[buf].filetype
  if ft ~= "tex" and ft ~= "latex" and ft ~= "plaintex" then return line end
  local comment = util.tex_comment_start(line)
  return comment and line:sub(1, comment - 1) or line
end

local function current_line_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] - 1, cursor[2]
end

local function matching_delim(str, open_pos, open_char, close_char)
  local depth = 0
  local i = open_pos
  while i <= #str do
    local c = str:sub(i, i)
    if c == open_char and not util.is_escaped(str, i) then
      depth = depth + 1
    elseif c == close_char and not util.is_escaped(str, i) then
      depth = depth - 1
      if depth == 0 then return i end
    end
    i = i + 1
  end
  return nil
end

local function skip_space(str, i)
  while i <= #str and str:sub(i, i):match("%s") do i = i + 1 end
  return i
end

local function parse_command(line, slash)
  local s, e, cmd = line:find("\\([%a]+%*?)", slash)
  if s ~= slash then return nil end
  local i = skip_space(line, e + 1)
  while line:sub(i, i) == "[" do
    local close = matching_delim(line, i, "[", "]")
    if not close then return nil end
    i = skip_space(line, close + 1)
  end
  if line:sub(i, i) ~= "{" then return nil end
  local close = matching_delim(line, i, "{", "}")
  if not close then return nil end
  return {
    start_col = s - 1,
    end_col = close,
    cmd = cmd,
    arg = line:sub(i + 1, close - 1),
    arg_start_col = i,
    arg_end_col = close - 2,
  }
end

local function command_under_cursor(buf, is_wanted)
  local row, col = current_line_cursor()
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line then return nil end
  line = source_line(buf, line)
  local pos = 1
  while true do
    local slash = line:find("\\", pos, true)
    if not slash then return nil end
    if not util.is_escaped(line, slash) then
      local cmd = parse_command(line, slash)
      if cmd and is_wanted(strip_star(cmd.cmd)) and col >= cmd.start_col and col < cmd.end_col then
        return cmd, row, col
      end
      -- Keep searching inside formatting commands such as \emph{\ref{...}},
      -- and include the byte immediately after a command's closing brace.
      pos = slash + 1
    else
      pos = slash + 1
    end
  end
end

local function split_csv(arg)
  local out = {}
  for item in arg:gmatch("[^,%s]+") do
    out[#out + 1] = item
  end
  return out
end

local function item_at_cursor(cmd, col)
  local offset = col - cmd.arg_start_col + 1
  local running = 1
  for _, item in ipairs(split_csv(cmd.arg)) do
    local s, e = cmd.arg:find(vim.pesc(item), running)
    if s and offset >= s and offset <= e then return item end
    running = (e or running) + 1
  end
  return split_csv(cmd.arg)[1]
end

local function equation_source(buf, eq)
  local lines = vim.api.nvim_buf_get_lines(buf, eq.start_row, eq.end_row + 1, false)
  if #lines == 0 then return "" end
  if #lines == 1 then
    return source_line(buf, lines[1]):sub(eq.start_col + 1, eq.end_col)
  end
  lines[1] = lines[1]:sub(eq.start_col + 1)
  lines[#lines] = lines[#lines]:sub(1, eq.end_col)
  for i, line in ipairs(lines) do lines[i] = source_line(buf, line) end
  return table.concat(lines, "\n")
end

local function reference_label_under_cursor(buf)
  local cmd, _, col = command_under_cursor(buf, function(name) return REF_COMMANDS[name] == true end)
  if not cmd then return nil end
  return item_at_cursor(cmd, col)
end

function M.reference_under_cursor(buf)
  local label = reference_label_under_cursor(buf)
  if not label then return nil end
  local label_pat = "\\label%s*{%s*" .. vim.pesc(label) .. "%s*}"
  for _, eq in ipairs(parse.find_equations(buf)) do
    if equation_source(buf, eq):find(label_pat) then
      local resolved = vim.deepcopy(eq)
      resolved.text = resolved.text:gsub("\\label%s*{[^{}]*}", "")
      return {
        type = "equation",
        source = "reference",
        label = label,
        equation = resolved,
      }
    end
  end
  return nil
end

local function theorem_env_at_line(line)
  return line:match("\\begin%s*{%s*([%a*]+)%s*}")
end

local function theorem_envs_from_preamble(lines)
  local envs = vim.deepcopy(THEOREM_ENVS)
  for _, line in ipairs(lines) do
    if line:find("\\begin{document}", 1, true) then break end
    local env, title = line:match("\\newtheorem%s*%*?%s*{%s*([%a*]+)%s*}%s*%b[]%s*{%s*([^}]*)%s*}")
    if not env then
      env, title = line:match("\\newtheorem%s*%*?%s*{%s*([%a*]+)%s*}%s*{%s*([^}]*)%s*}")
    end
    if env and title then
      local lower = title:lower()
      if lower:match("theorem") or lower:match("lemma")
          or lower:match("proposition") or lower:match("definition") then
        envs[env:gsub("%*$", "")] = true
      end
    end
    local declared = line:match("\\declaretheorem%s*%b[]%s*{%s*([%a*]+)%s*}")
      or line:match("\\declaretheorem%s*{%s*([%a*]+)%s*}")
    if declared then envs[declared:gsub("%*$", "")] = true end
  end
  return envs
end

local function theorem_end_pattern(env)
  return "\\end%s*{%s*" .. vim.pesc(env) .. "%s*}"
end

local function strip_outer_theorem_lines(lines, env)
  if #lines == 0 then return lines end
  lines = vim.deepcopy(lines)
  lines[1] = lines[1]:gsub("^%s*\\begin%s*{%s*" .. vim.pesc(env) .. "%s*}%s*%b[]%s*", "")
  lines[1] = lines[1]:gsub("^%s*\\begin%s*{%s*" .. vim.pesc(env) .. "%s*}%s*", "")
  lines[#lines] = lines[#lines]:gsub("%s*" .. theorem_end_pattern(env) .. "%s*$", "")
  while #lines > 0 and vim.trim(lines[1]) == "" do table.remove(lines, 1) end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do table.remove(lines) end
  return lines
end

function M.theorem_reference_under_cursor(buf)
  local label = reference_label_under_cursor(buf)
  if not label then return nil end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do lines[i] = source_line(buf, line) end
  local label_pat = "\\label%s*{%s*" .. vim.pesc(label) .. "%s*}"
  local theorem_envs = theorem_envs_from_preamble(lines)
  local stack = {}
  for i, line in ipairs(lines) do
    local env = theorem_env_at_line(line)
    if env and theorem_envs[env:gsub("%*$", "")] then
      stack[#stack + 1] = { env = env, start_row = i }
    end
    if line:find(label_pat) then
      local block = stack[#stack]
      if block then
        local finish = #lines
        local end_pat = theorem_end_pattern(block.env)
        for j = i, #lines do
          if lines[j]:find(end_pat) then
            finish = j
            break
          end
        end
        local body = {}
        for j = block.start_row, finish do
          body[#body + 1] = lines[j]
        end
        body = strip_outer_theorem_lines(body, block.env)
        for j, body_line in ipairs(body) do
          body[j] = body_line:gsub("\\label%s*{[^{}]*}", "")
        end
        if #body == 0 then body = { vim.trim(block.env:gsub("^%l", string.upper)) .. ": " .. label } end
        return {
          type = "mixed_text",
          source = "theorem_reference",
          label = label,
          signature = "theorem-ref:" .. label .. ":" .. vim.fn.sha256(table.concat(body, "\n")),
          lines = body,
        }
      end
    end
    local end_env = line:match("\\end%s*{%s*([%a*]+)%s*}")
    if end_env and #stack > 0 and stack[#stack].env == end_env then
      stack[#stack] = nil
    end
  end
  return nil
end

function M.missing_reference_under_cursor(buf)
  local label = reference_label_under_cursor(buf)
  if not label then return nil end
  return {
    type = "text",
    source = "reference",
    signature = "missing-ref:" .. label,
    lines = { "Reference not found: " .. label },
  }
end

local function bib_names_from_line(line)
  local names = {}
  for cmd, arg in line:gmatch("\\(bibliography)%s*{([^}]*)}") do
    if cmd then vim.list_extend(names, split_csv(arg)) end
  end
  for arg in line:gmatch("\\addbibresource%s*%b[]%s*{([^}]*)}") do
    names[#names + 1] = arg
  end
  for arg in line:gmatch("\\addbibresource%s*{([^}]*)}") do
    names[#names + 1] = arg
  end
  return names
end

local function resolve_bib_path(base, name)
  if name == "" then return nil end
  if not name:match("%.bib$") then name = name .. ".bib" end
  local candidates = {}
  if name:sub(1, 1) == "/" then
    candidates[#candidates + 1] = name
  else
    candidates[#candidates + 1] = base .. "/" .. name
    candidates[#candidates + 1] = vim.fn.getcwd() .. "/" .. name
  end
  for _, path in ipairs(candidates) do
    local stat = uv.fs_stat(path)
    if (stat and stat.type == "file") or loaded_buffer(path) then
      return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    end
  end
  return nil
end

local function bib_files(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local base = name ~= "" and vim.fs.dirname(vim.fn.fnamemodify(name, ":p")) or vim.fn.getcwd()
  local found, seen = {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, bib in ipairs(bib_names_from_line(source_line(buf, line))) do
      local path = resolve_bib_path(base, bib)
      if path and not seen[path] then
        seen[path] = true
        found[#found + 1] = path
      end
    end
  end
  return found
end

local function bib_entry_end(text, open)
  local open_char = text:sub(open, open)
  local braces = open_char == "{" and 1 or 0
  local quoted = false
  for i = open + 1, #text do
    local c = text:sub(i, i)
    if not util.is_escaped(text, i) then
      if c == "{" then
        braces = braces + 1
      elseif c == "}" and braces > 0 then
        braces = braces - 1
        if braces == 0 and open_char == "{" then return i end
      elseif c == '"' and braces == 0 then
        quoted = not quoted
      elseif c == ")" and braces == 0 and not quoted then
        return i
      end
    end
  end
end

local function find_bib_entry(path, key)
  local lines = read_lines(path)
  if not lines then return nil end
  local text = table.concat(lines, "\n")
  local pos = 1
  while true do
    local start, open, kind = text:find("@([%a]+)%s*[%({]", pos)
    if not start then return nil end
    local close = bib_entry_end(text, open)
    if not close then return nil end
    kind = kind:lower()
    -- Iterate complete records. Searching for a key globally also matches
    -- examples inside field values and entries inside @comment blocks.
    local entry_key = text:sub(open + 1, close - 1):match("^%s*([^,%s]+)%s*,")
    if kind ~= "comment" and kind ~= "preamble" and kind ~= "string" and entry_key == key then
      return text:sub(start, close)
    end
    pos = close + 1
  end
end

local function is_cite_command(name)
  return name:find("cite", 1, true) ~= nil
end

function M.citation_under_cursor(buf)
  local cmd, _, col = command_under_cursor(buf, is_cite_command)
  if not cmd then return nil end
  local key = item_at_cursor(cmd, col)
  if not key then return nil end
  for _, path in ipairs(bib_files(buf)) do
    local entry = find_bib_entry(path, key)
    if entry then
      return {
        type = "text",
        source = "citation",
        key = key,
        signature = "cite:" .. path .. ":" .. key .. ":" .. vim.fn.sha256(entry),
        lines = vim.split(entry, "\n", { plain = true }),
      }
    end
  end
  return {
    type = "text",
    source = "citation",
    key = key,
    signature = "missing-cite:" .. key,
    lines = { "Citation not found: " .. key },
  }
end

return M
