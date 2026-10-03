-- lua/latex-preview/extract.lua
--
-- Definition extractor. Walks a LaTeX buffer (and any local .sty files
-- referenced via \usepackage{name}) for "definition-shaped" commands and
-- emits a single concatenated preamble string ready to send to MathJax.
--
-- Supports: \newcommand, \renewcommand, \providecommand, \DeclareMathOperator,
-- \DeclarePairedDelimiter, \NewDocumentCommand, \RenewDocumentCommand,
-- \newenvironment, \renewenvironment, \def, \gdef, \edef, \let, \newcounter.
--
-- This is the same approach Overleaf's editor uses — a syntax-aware
-- text scan, not a full TeX parser. Failure modes:
--   * Multi-line definitions inside \makeatletter…\makeatother blocks may
--     parse incorrectly because @ becomes a letter
--   * Conditional definitions (\@ifundefined, \ifthenelse) are taken as-is
--     and will fail in MathJax
--   * \ProvidesPackage / \RequirePackage / \DeclareOption are extracted
--     too, but MathJax silently ignores them via the daemon's per-line retry

local M = {}

local uv = vim.uv or vim.loop
local config = require("latex-preview.config")
local util = require("latex-preview.util")

local function normalize_path(path)
  if not path or path == "" then return nil end
  path = vim.fn.fnamemodify(path, ":p")
  return vim.fs.normalize and vim.fs.normalize(path) or path
end

local function join_path(dir, path)
  if path:match("^/") then return normalize_path(path) end
  return normalize_path(dir .. "/" .. path)
end

local function buffer_for_path(path)
  path = normalize_path(path)
  if not path then return nil end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = normalize_path(vim.api.nvim_buf_get_name(buf))
      if name == path then return buf end
    end
  end
  return nil
end

-- Patterns that mark a line as carrying a macro/environment definition.
local DEF_PATTERNS = {
  "\\newcommand%s*[%*]?%s*[{\\]",
  "\\renewcommand%s*[%*]?%s*[{\\]",
  "\\providecommand%s*[%*]?%s*[{\\]",
  "\\DeclareRobustCommand%s*[%*]?%s*[{\\]",
  "\\DeclareMathOperator%s*[%*]?%s*{",
  "\\DeclarePairedDelimiter%s*{",
  "\\DeclarePairedDelimiterX%s*{",
  "\\newdelim%s*[{\\]",
  "\\newdelimX%s*\\",
  "\\NewDocumentCommand%s*[{\\]",
  "\\RenewDocumentCommand%s*[{\\]",
  "\\ProvideDocumentCommand%s*[{\\]",
  "\\newenvironment%s*[%*]?%s*{",
  "\\renewenvironment%s*[%*]?%s*{",
  "\\newtheorem%s*[%*]?%s*{",
  "\\def%s*\\",
  "\\gdef%s*\\",
  "\\edef%s*\\",
  "\\let%s*\\",
  "\\newcounter%s*{",
}

local function is_def_line(line)
  for _, p in ipairs(DEF_PATTERNS) do
    if line:find(p) then return true end
  end
  return false
end

---Strip line comments. Respects `\%` as a literal percent.
local function strip_comment(line)
  local i = 1
  while true do
    local p = line:find("%", i, true)
    if not p then return line end
    if not util.is_escaped(line, p) then
      return line:sub(1, p - 1)
    end
    i = p + 1
  end
end

---Walk lines and extract complete definitions. Multi-line definitions are
---tracked by brace depth.
---@param lines string[]
---@return string
function M.extract_definitions(lines)
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local raw = lines[i]
    local line = strip_comment(raw)
    -- Stop at \begin{document}; everything after is body, not preamble.
    if line:find("\\begin{document}", 1, true) then break end

    if is_def_line(line) then
      local block = { raw }
      local depth, started = 0, false
      local function update(s)
        local k = 1
        while k <= #s do
          local c = s:sub(k, k)
          if c == "\\" and k < #s then k = k + 2
          else
            if c == "{" then depth = depth + 1; started = true
            elseif c == "}" then depth = depth - 1 end
            k = k + 1
          end
        end
      end
      update(line)
      -- Single-line forms: \def\foo{...}, \let\a\b, \edef\foo{...}.
      -- These either have one brace pair on the same line (caught by the
      -- depth check below) or no braces at all (\let). For \let we bail
      -- immediately after the first line; the multi-line continuation is
      -- only for the brace-balanced forms.
      local is_brace_free_form = line:find("\\let%s*\\") and not line:find("{")
      if is_brace_free_form then
        out[#out + 1] = block[1]
        i = i + 1
        goto continue_outer
      end
      while (not started or depth > 0) and i < n do
        i = i + 1
        local more = lines[i]
        block[#block + 1] = more
        update(strip_comment(more))
      end
      out[#out + 1] = table.concat(block, "\n")
    end
    i = i + 1
    ::continue_outer::
  end
  return table.concat(out, "\n")
end

---@param line string
---@param cmd string
---@return string[]
local function braced_args_after_command(line, cmd)
  local args = {}
  local i = 1
  while true do
    local s, e = line:find("\\" .. cmd .. "%f[%A]", i)
    if not s then break end
    -- Always advance, including while the user is typing an unfinished
    -- argument such as `\\usepackage{`. Otherwise this loop never returns.
    i = e + 1
    local p = e + 1
    while line:sub(p, p):match("%s") do p = p + 1 end
    if line:sub(p, p) == "[" then
      local close = line:find("]", p + 1, true)
      if close then p = close + 1 end
      while line:sub(p, p):match("%s") do p = p + 1 end
    end
    if line:sub(p, p) == "{" then
      local depth = 0
      local j = p
      while j <= #line do
        local c = line:sub(j, j)
        if c == "\\" then
          j = j + 1
        elseif c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            args[#args + 1] = line:sub(p + 1, j - 1)
            i = j + 1
            break
          end
        end
        j = j + 1
      end
    else
      i = e + 1
    end
  end
  return args
end

---@param line string
---@return string[]
local function package_names_from_line(line)
  local names = {}
  for _, cmd in ipairs({ "usepackage", "RequirePackage" }) do
    for _, arg in ipairs(braced_args_after_command(line, cmd)) do
      for name in arg:gmatch("[^,%s]+") do
        names[#names + 1] = name
      end
    end
  end
  return names
end

---@param line string
---@return string[]
local function input_names_from_line(line)
  local names = {}
  for _, cmd in ipairs({ "input", "include", "subfile" }) do
    for _, arg in ipairs(braced_args_after_command(line, cmd)) do
      if arg ~= "" then names[#names + 1] = arg end
    end
  end
  return names
end

---Read a file as a list of lines.
local function read_lines(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local lines = {}
  for line in fd:lines() do lines[#lines + 1] = line end
  fd:close()
  return lines
end

local function lines_for_path(path)
  local buf = buffer_for_path(path)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
  end
  return read_lines(path), nil
end

---@param name string
---@return string[]
local function candidate_file_names(name)
  if name:match("%.sty$") or name:match("%.tex$") then return { name } end
  return { name .. ".sty", name .. ".tex" }
end

---@param start_dir string
---@param name string
---@param depth_cap integer
---@return string?
local function find_local_tex_file(start_dir, name, depth_cap)
  local dir, depth = start_dir, 0
  while dir and dir ~= "" and dir ~= "/" and depth < depth_cap do
    for _, fname in ipairs(candidate_file_names(name)) do
      local cand = dir .. "/" .. fname
      if uv.fs_stat(cand) then return cand end
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir, depth = parent, depth + 1
  end
  return nil
end

local function tex_root_from_magic(lines, base_dir)
  for _, raw in ipairs(lines) do
    local root = raw:match("^%s*%%%s*!%s*[Tt][Ee][Xx]%s+[Rr][Oo][Oo][Tt]%s*=%s*(.-)%s*$")
    if root and root ~= "" then
      return join_path(base_dir, root)
    end
  end
end

local function tex_root_from_vimtex(buf)
  local ok, vimtex = pcall(function() return vim.b[buf].vimtex end)
  if not ok or type(vimtex) ~= "table" then return nil end
  if type(vimtex.tex) == "string" and vimtex.tex ~= "" then
    return normalize_path(vimtex.tex)
  end
  if type(vimtex.root) == "string" and vimtex.root ~= "" and vimtex.root:match("%.tex$") then
    return normalize_path(vimtex.root)
  end
end

local function tex_arg_candidates(base_dirs, name)
  local out = {}
  local seen = {}
  for _, dir in ipairs(base_dirs) do
    for _, fname in ipairs(candidate_file_names(name)) do
      local path = join_path(dir, fname)
      if not seen[path] then
        seen[path] = true
        out[#out + 1] = path
      end
    end
  end
  return out
end

local function watch_path(watched, path)
  if not watched.seen[path] then
    watched.seen[path] = true
    watched.paths[#watched.paths + 1] = path
  end
end

local function file_reaches_child(path, child_path, root_dir, seen, watched)
  path = normalize_path(path)
  if not path or seen[path] then return false end
  seen[path] = true
  watch_path(watched, path)
  local lines = lines_for_path(path)
  if not lines then return false end
  child_path = normalize_path(child_path)
  local file_dir = vim.fs.dirname(path)
  local base_dirs = root_dir == file_dir and { root_dir } or { root_dir, file_dir }
  for _, raw in ipairs(lines) do
    local line = strip_comment(raw)
    for _, name in ipairs(input_names_from_line(line)) do
      for _, cand in ipairs(tex_arg_candidates(base_dirs, name)) do
        if cand == child_path then return true end
        watch_path(watched, cand)
        if cand:match("%.tex$") and uv.fs_stat(cand) and file_reaches_child(cand, child_path, root_dir, seen, watched) then
          return true
        end
      end
    end
  end
  return false
end

local function root_reaches_child(root_path, child_path, watched)
  local root_dir = vim.fs.dirname(root_path)
  return file_reaches_child(root_path, child_path, root_dir, {}, watched)
end

local function tex_root_from_parent_search(path, watched)
  path = normalize_path(path)
  if not path then return nil end
  local dir = vim.fs.dirname(path)
  local matches = {}
  local depth = 0
  while dir and dir ~= "" and dir ~= "/" and depth < 6 do
    -- Directory signatures notice newly added/removed possible root files.
    watch_path(watched, dir)
    local handle = uv.fs_scandir(dir)
    if handle then
      while true do
        local name, typ = uv.fs_scandir_next(handle)
        if not name then break end
        if typ == "file" and name:match("%.tex$") then
          local cand = normalize_path(dir .. "/" .. name)
          if cand ~= path then
            watch_path(watched, cand)
            local lines = lines_for_path(cand)
            if lines and table.concat(lines, "\n"):find("\\begin{document}", 1, true)
                and root_reaches_child(cand, path, watched) then
              matches[#matches + 1] = cand
            end
          end
        end
      end
    end
    if #matches == 1 then return matches[1] end
    if #matches > 1 then return nil end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir, depth = parent, depth + 1
  end
end

local function explicit_tex_root(buf, lines)
  local self_path = normalize_path(vim.api.nvim_buf_get_name(buf))
  if not self_path then return nil end
  local self_dir = vim.fs.dirname(self_path)
  return tex_root_from_magic(lines, self_dir) or tex_root_from_vimtex(buf)
end

local function scan_referenced_files(start_path, source_lines)
  if not start_path then return "", {} end
  local start_dir = vim.fs.dirname(start_path)
  local queue = {}
  for _, line in ipairs(source_lines) do
    line = strip_comment(line)
    if line:find("\\begin{document}", 1, true) then break end
    vim.list_extend(queue, package_names_from_line(line))
    vim.list_extend(queue, input_names_from_line(line))
  end
  if #queue == 0 then return "", {} end

  local seen_name, seen_file, found, file_lines = {}, {}, {}, {}
  local depth_cap = config.options.extract.sty_search_depth
  local qi = 1
  while qi <= #queue do
    local name = queue[qi]
    qi = qi + 1
    if not seen_name[name] then
      seen_name[name] = true
      local path = find_local_tex_file(start_dir, name, depth_cap)
      if path and not seen_file[path] then
        seen_file[path] = true
        found[#found + 1] = path
        local lines = lines_for_path(path)
        if lines then
          file_lines[path] = lines
          for _, line in ipairs(lines) do
            line = strip_comment(line)
            vim.list_extend(queue, package_names_from_line(line))
            vim.list_extend(queue, input_names_from_line(line))
          end
        end
      end
    end
  end
  if #found == 0 then return "", {} end

  local parts = {}
  for _, sty in ipairs(found) do
    local lines = file_lines[sty] or lines_for_path(sty)
    if lines then
      local defs = M.extract_definitions(lines)
      if defs ~= "" then
        parts[#parts + 1] = "% from " .. vim.fn.fnamemodify(sty, ":t")
        parts[#parts + 1] = defs
      end
    end
  end
  return table.concat(parts, "\n"), found
end

---Find local .sty files reachable from this buffer's directory and extract
---their definitions. The "reachability" rule: for each \usepackage{name},
---\RequirePackage{name}, or \input{name} in the buffer's preamble, look for
---matching local .sty/.tex files in the buffer's directory and parents.
---@param buf integer
---@return string
function M.scan_sty_files(buf)
  local self_path = normalize_path(vim.api.nvim_buf_get_name(buf))
  if not self_path then return "" end
  local defs = scan_referenced_files(self_path, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  return defs
end

---@param preamble string
---@return string
local function normalize_for_mathjax(preamble)
  -- MathJax supports \newcommand well, but common LaTeX declaration helpers
  -- such as \DeclareMathOperator are not themselves macro definitions in
  -- MathJax's TeX input. Convert the simple forms we can recognize.
  preamble = preamble:gsub(
    "\\DeclareMathOperator%s*%*?%s*{%s*(\\[%a@]+)%s*}%s*{([^{}\n]*)}",
    function(cmd, body)
      return "\\newcommand{" .. cmd .. "}{\\operatorname{" .. body .. "}}"
    end
  )
  preamble = preamble:gsub(
    "\\DeclarePairedDelimiter%s*{%s*(\\[%a@]+)%s*}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, left, right)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[1]{" .. open .. " #1 " .. close .. "}"
    end
  )
  preamble = preamble:gsub(
    "\\newdelim%s*{%s*(\\[%a@]+)%s*}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, left, right)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[1]{" .. open .. " #1 " .. close .. "}"
    end
  )
  preamble = preamble:gsub(
    "\\DeclarePairedDelimiterX%s*{%s*(\\[%a@]+)%s*}%s*%[(%d+)%]%s*{([^{}\n]*)}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, argc, left, right, body)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[" .. argc .. "]{" .. open .. " " .. body .. " " .. close .. "}"
    end
  )
  preamble = preamble:gsub(
    "\\newdelimX%s*(\\[%a@]+)%s*%[(%d+)%]%s*{([^{}\n]*)}%s*{([^{}\n]*)}%s*{([^{}\n]*)}",
    function(cmd, argc, left, right, body)
      local open = left == "." and "" or "\\left" .. left
      local close = right == "." and "" or "\\right" .. right
      return "\\newcommand{" .. cmd .. "}[" .. argc .. "]{" .. open .. " " .. body .. " " .. close .. "}"
    end
  )
  preamble = preamble:gsub("\\DeclareRobustCommand", "\\newcommand")
  preamble = preamble:gsub("\\ProvideDocumentCommand", "\\NewDocumentCommand")
  return preamble
end

local function file_signature(path)
  local buf = buffer_for_path(path)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return "buf:" .. tostring(buf) .. ":" .. tostring(vim.api.nvim_buf_get_changedtick(buf))
  end
  local stat = path and uv.fs_stat(path) or nil
  if not stat then return "missing:" .. tostring(path or "") end
  local mtime = stat.mtime or {}
  return table.concat({
    "file",
    path,
    tostring(stat.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ":")
end

local function dependency_signature(paths, signature)
  local parts = {}
  for _, path in ipairs(paths or {}) do
    parts[#parts + 1] = (signature or file_signature)(path)
  end
  return table.concat(parts, "\n")
end

local function normalize_combined_preamble(combined)
  if config.options.extract.rewrite_providecommand then
    combined = combined:gsub("\\providecommand", "\\newcommand")
  end
  if config.options.extract.rewrite_edef then
    combined = combined:gsub("\\edef", "\\def")
  end
  return normalize_for_mathjax(combined)
end

---Cached per-buffer extraction. The cache key includes the current buffer's
---changedtick, the resolved root source, and the scanned local dependency
---mtimes so root-aware multi-file projects invalidate when their macro
---sources change.
local cache = {}
local cache_cleanup_registered = false

local function ensure_cache_cleanup()
  if cache_cleanup_registered then return end
  cache_cleanup_registered = true
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("latex_preview_extract_cache", { clear = true }),
    callback = function(args)
      cache[args.buf] = nil
    end,
  })
end

---@param buf integer
---@return string preamble  Concatenated definitions, MathJax-normalized.
function M.get_preamble(buf)
  ensure_cache_cleanup()
  local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_path = normalize_path(vim.api.nvim_buf_get_name(buf))
  local root_hint = explicit_tex_root(buf, current_lines)
  local entry = cache[buf]
  -- The root can also appear in the resolution graph and dependency list.
  -- Inspect each source only once during this lookup.
  local signatures = {}
  local function signature(path)
    if not signatures[path] then signatures[path] = file_signature(path) end
    return signatures[path]
  end
  local watched = { paths = {}, seen = {} }
  local root_path = root_hint
  if not root_path then
    if entry and entry.current_path == current_path and entry.root_hint == root_hint
        and entry.resolution_sig == dependency_signature(entry.resolution_paths, signature) then
      root_path = entry.root_path
      watched.paths = entry.resolution_paths
    else
      root_path = tex_root_from_parent_search(current_path, watched) or current_path
    end
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local root_sig = root_path and signature(root_path) or ""
  local opts = config.options.extract
  local options_sig = table.concat({ tostring(opts.scan_sty), tostring(opts.sty_search_depth),
    tostring(opts.rewrite_providecommand), tostring(opts.rewrite_edef) }, ":")
  local sources_unchanged = entry
      and entry.current_path == current_path
      and entry.options_sig == options_sig
      and entry.root_path == root_path
      and entry.root_sig == root_sig
      and entry.dep_sig == dependency_signature(entry.deps, signature)
  if sources_unchanged and entry.tick == tick then
    entry.root_hint = root_hint
    entry.resolution_paths = watched.paths
    entry.resolution_sig = dependency_signature(watched.paths, signature)
    return entry.value
  end

  local root_defs, sty_defs, deps
  if sources_unchanged and root_path and root_path ~= current_path
      and root_sig:sub(1, 8) ~= "missing:" then
    -- Editing a chapter changes its own definitions, but does not require
    -- rereading and rescanning an unchanged root preamble or its packages.
    root_defs, sty_defs, deps = entry.root_defs, entry.sty_defs, entry.deps
  else
    local root_lines = current_lines
    if root_path and root_path ~= current_path then
      root_lines = lines_for_path(root_path) or current_lines
    end
    root_defs = M.extract_definitions(root_lines)
    sty_defs, deps = "", {}
    if config.options.extract.scan_sty then
      sty_defs, deps = scan_referenced_files(root_path or current_path, root_lines)
    end
  end

  local buf_defs = ""
  if not root_path or root_path ~= current_path then
    buf_defs = M.extract_definitions(current_lines)
  end
  local parts = {}
  if sty_defs ~= "" then parts[#parts + 1] = sty_defs end
  if root_defs ~= "" then parts[#parts + 1] = root_defs end
  if buf_defs ~= "" then parts[#parts + 1] = buf_defs end
  local combined = normalize_combined_preamble(table.concat(parts, "\n"))

  cache[buf] = {
    tick = tick,
    current_path = current_path,
    root_hint = root_hint,
    resolution_paths = watched.paths,
    resolution_sig = dependency_signature(watched.paths, signature),
    options_sig = options_sig,
    root_path = root_path,
    root_sig = root_sig,
    root_defs = root_defs,
    sty_defs = sty_defs,
    deps = deps,
    dep_sig = dependency_signature(deps, signature),
    value = combined,
  }
  return combined
end

return M
