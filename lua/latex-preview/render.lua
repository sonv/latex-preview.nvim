-- lua/latex-preview/render.lua
--
-- Render an equation to a PNG file on disk. Pipeline:
--   (preamble, equation, display, color) hashed → reusable PNG hit?
--     yes → return existing PNG path
--     no  → daemon.render → SVG → magick/rsvg-convert → PNG → cache/temp
--
-- The cache key is a content hash of all inputs that affect the output.
-- That means editing a \newcommand in your buffer correctly invalidates,
-- and changing the foreground color (e.g. via colorscheme switch) does too.

local M = {}

local uv = vim.uv or vim.loop
local config = require("latex-preview.config")
local daemon = require("latex-preview.daemon")
local pad_warning_shown = false
local temp_cleanup_registered = false
local temp_cache_timer = nil
local pending = {}
local schedule_temp_cache_limit_check

local function temp_base_dir()
  return vim.fn.stdpath("run") .. "/latex-preview"
end

local function temp_dir()
  return temp_base_dir() .. "/" .. tostring(uv.os_getpid())
end

local function process_alive(pid)
  local ok, ret = pcall(uv.kill, pid, 0)
  return ok and (ret == 0 or ret == true)
end

local function cleanup_stale_temp_dirs()
  local base = temp_base_dir()
  if not uv.fs_stat(base) then return end
  local handle = uv.fs_scandir(base)
  if not handle then return end
  local current_pid = uv.os_getpid()
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    local pid = tonumber(name)
    if typ == "directory" and pid and pid ~= current_pid and not process_alive(pid) then
      vim.fn.delete(base .. "/" .. name, "rf")
    end
  end
end

local function temp_render_stem(name)
  return name:gsub("%.tmp$", ""):gsub("%.[^.]+$", "")
end

local function temp_cache_group(name, names)
  local image_name = name:match("^(.*)%.info$")
  if image_name then
    if names and names[image_name] then
      return temp_render_stem(image_name)
    end
    local unprefixed = image_name:match("^%x%x%x%x%x%x%x%x%-(.+)$")
    if unprefixed and names and names[unprefixed] then
      return temp_render_stem(unprefixed)
    end
    return temp_render_stem(image_name)
  end
  return temp_render_stem(name)
end

local function scan_temp_cache()
  local dir = temp_dir()
  local handle = uv.fs_scandir(dir)
  if not handle then return {}, 0, 0 end
  local entries = {}
  local names = {}
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local path = dir .. "/" .. name
    local stat = uv.fs_stat(path)
    if stat then
      entries[#entries + 1] = { name = name, path = path, stat = stat }
      names[name] = true
    end
  end

  local groups = {}
  local total_files, total_bytes = 0, 0
  for _, entry in ipairs(entries) do
    local stat = entry.stat
    local key = temp_cache_group(entry.name, names)
    groups[key] = groups[key] or { files = {}, count = 0, bytes = 0, mtime = 0, nsec = 0 }
    local group = groups[key]
    local size = stat.size or 0
    local mtime = stat.mtime and stat.mtime.sec or 0
    local nsec = stat.mtime and stat.mtime.nsec or 0
    group.files[#group.files + 1] = entry.path
    group.count = group.count + 1
    group.bytes = group.bytes + size
    if mtime > group.mtime or (mtime == group.mtime and nsec > group.nsec) then
      group.mtime = mtime
      group.nsec = nsec
    end
    total_files = total_files + 1
    total_bytes = total_bytes + size
  end
  return groups, total_files, total_bytes
end

local function group_count(groups)
  local count = 0
  for _ in pairs(groups) do
    count = count + 1
  end
  return count
end

local function trim_temp_cache(max_files, max_bytes, grace_ms)
  local groups, total_files, total_bytes = scan_temp_cache()
  local total_groups = group_count(groups)
  local over_files = max_files > 0 and total_groups > max_files
  local over_bytes = max_bytes > 0 and total_bytes > max_bytes
  if not over_files and not over_bytes then return end

  local now_sec = os.time()
  local entries = {}
  local next_retry_ms = nil
  for _, group in pairs(groups) do
    local age_ms = (now_sec - group.mtime) * 1000
    if age_ms >= grace_ms then
      entries[#entries + 1] = group
    else
      local remaining = grace_ms - age_ms
      next_retry_ms = next_retry_ms and math.min(next_retry_ms, remaining) or remaining
    end
  end
  table.sort(entries, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.nsec > b.nsec
  end)
  while #entries > 0
      and ((max_files > 0 and total_groups > max_files)
        or (max_bytes > 0 and total_bytes > max_bytes)) do
    local group = table.remove(entries)
    for _, path in ipairs(group.files) do
      pcall(os.remove, path)
    end
    total_groups = total_groups - 1
    total_files = total_files - group.count
    total_bytes = total_bytes - group.bytes
  end
  if ((max_files > 0 and total_groups > max_files)
      or (max_bytes > 0 and total_bytes > max_bytes))
      and next_retry_ms then
    return math.max(1, next_retry_ms)
  end
end

local function enforce_temp_cache_limit()
  local max_files = tonumber(config.options.snacks and config.options.snacks.max_cache_files) or 0
  local max_bytes = tonumber(config.options.snacks and config.options.snacks.max_cache_bytes) or 0
  local grace_ms = tonumber(config.options.snacks and config.options.snacks.cache_grace_ms) or 0
  if max_files <= 0 and max_bytes <= 0 then return end
  local retry_ms = trim_temp_cache(max_files, max_bytes, math.max(0, grace_ms))
  if retry_ms and schedule_temp_cache_limit_check then
    schedule_temp_cache_limit_check(retry_ms)
  end
end

schedule_temp_cache_limit_check = function(delay_ms)
  local max_files = tonumber(config.options.snacks and config.options.snacks.max_cache_files) or 0
  local max_bytes = tonumber(config.options.snacks and config.options.snacks.max_cache_bytes) or 0
  if max_files <= 0 and max_bytes <= 0 then return end
  if not temp_cache_timer then temp_cache_timer = assert(uv.new_timer()) end
  temp_cache_timer:stop()
  temp_cache_timer:start(math.max(1, math.ceil(delay_ms or 250)), 0, function()
    vim.schedule(enforce_temp_cache_limit)
  end)
end

local function ensure_temp_cleanup()
  if temp_cleanup_registered then return end
  temp_cleanup_registered = true
  cleanup_stale_temp_dirs()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("latex_preview_temp_cleanup", { clear = true }),
    callback = function()
      if temp_cache_timer then
        temp_cache_timer:stop()
        temp_cache_timer:close()
        temp_cache_timer = nil
      end
      vim.fn.delete(temp_dir(), "rf")
    end,
  })
end

local function effective_font_size(req)
  if req.font_size then return req.font_size end
  if req.display then
    return config.options.render.display_font_size or config.options.render.font_size or 10
  end
  return config.options.render.font_size or 11
end

local function effective_density(req)
  local buf = req.buf
  if buf and buf ~= 0 and vim.api.nvim_buf_is_valid(buf) then
    local buffer_key = req.display and "latex_preview_display_density" or "latex_preview_density"
    local value = vim.b[buf][buffer_key]
    if value == nil and req.display then value = vim.b[buf].latex_preview_density end
    if value ~= nil then return tonumber(value) or config.options.render.density or 300 end
  end
  return tonumber(config.options.render.density) or 300
end

local function should_pad_to_cells(req)
  if req.pad_to_cells ~= nil then return req.pad_to_cells == true end
  return config.options.render.pad_to_cells == true
end

---@param req { preamble: string, equation: string, display: boolean, pad_to_cells: boolean? }
---@return string  cache key suitable for use as a filename stem
local function cache_key(req)
  local renderer_version = "raster-v9-mathjax4"
  local fg = config.get_fg()
  local font_size = effective_font_size(req)
  local density = effective_density(req)
  -- Avoid \0 separators because vim.fn.sha256 treats embedded NULs as a
  -- Blob signal and refuses string input. Newlines are safe and the
  -- collision risk is negligible for our use.
  local raw = table.concat({
    req.preamble or "",
    req.equation or "",
    req.display and "1" or "0",
    fg,
    tostring(font_size),
    tostring(config.options.render.display_math_style),
    tostring(should_pad_to_cells(req)),
    tostring(density),
    renderer_version,
  }, "\n--latex-preview--\n")
  return vim.fn.sha256(raw):sub(1, 16)
end

---Ensure the cache directory exists for this buffer.
---@param buf integer
---@return string
local function ensure_cache_dir(buf)
  local dir = config.get_cache_dir(buf)
  if not uv.fs_stat(dir) then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

---@param buf integer
---@param id integer|string?
---@return string
local function temp_stem(buf, id)
  ensure_temp_cleanup()
  local dir = temp_dir()
  if not uv.fs_stat(dir) then
    vim.fn.mkdir(dir, "p")
  end
  return dir .. "/" .. tostring(buf) .. "-" .. tostring(id or 0)
end

---Run an external process, async. Returns via cb(err, stdout).
---@param cmd string
---@param args string[]
---@param cb fun(err: string?, code: integer)
local function spawn(cmd, args, cb)
  if vim.fn.executable(cmd) == 0 then
    return cb("`" .. cmd .. "` not found in PATH", -1)
  end
  local stderr = uv.new_pipe()
  local stderr_buf = {}
  local handle
  handle = uv.spawn(cmd, {
    args = args,
    stdio = { nil, nil, stderr },
    hide = true,
  }, function(code)
    stderr:read_stop()
    stderr:close()
    if handle then handle:close() end
    vim.schedule(function()
      if code ~= 0 then
        cb(table.concat(stderr_buf, ""), code)
      else
        cb(nil, code)
      end
    end)
  end)
  if not handle then
    stderr:close()
    return cb("spawn failed: " .. cmd, -1)
  end
  stderr:read_start(function(_, data)
    if data then table.insert(stderr_buf, data) end
  end)
end

---Convert SVG file to PNG file via the configured tool.
---@param svg_path string
---@param png_path string
---@param density integer
---@param cb fun(err: string?)
local function svg_to_png(svg_path, png_path, density, cb)
  local tool = config.options.render.svg_to_png
  if tool == "auto" then
    tool = vim.fn.executable("rsvg-convert") == 1 and "rsvg" or "magick"
  end
  if tool == "rsvg" then
    -- rsvg-convert handles MathJax's SVG/currentColor output reliably.
    local zoom = density / 96
    spawn("rsvg-convert", {
      "-d", tostring(density),
      "-p", tostring(density),
      "-z", tostring(zoom),
      "-b", "transparent",
      "-o", png_path,
      svg_path,
    }, function(err) cb(err) end)
  else
    -- ImageMagick. Either `magick` (v7) or `convert` (v6) exists.
    local bin = vim.fn.executable("magick") == 1 and "magick" or "convert"
    spawn(bin, {
      "-density", tostring(density),
      "-background", "none",
      svg_path,
      "-trim",
      png_path,
    }, function(err) cb(err) end)
  end
end

---@param png_path string
---@return integer?, integer?
local function png_size(png_path)
  local fd = io.open(png_path, "rb")
  if not fd then return nil, nil end
  local header = fd:read(24)
  fd:close()
  if not header or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil, nil
  end
  local width = header:byte(17) * 16777216 + header:byte(18) * 65536
    + header:byte(19) * 256 + header:byte(20)
  local height = header:byte(21) * 16777216 + header:byte(22) * 65536
    + header:byte(23) * 256 + header:byte(24)
  return width, height
end

---@param png_path string
---@param cb fun(err: string?)
local function pad_to_cells(png_path, cb)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.image or not snacks.image.terminal then return cb(nil) end
  local term = snacks.image.terminal.size()
  if not term or not term.cell_width or not term.cell_height then return cb(nil) end

  local width, height = png_size(png_path)
  if not width or not height then return cb(nil) end
  local target_width = math.max(1, math.ceil(width / term.cell_width) * term.cell_width)
  local target_height = math.max(1, math.ceil(height / term.cell_height) * term.cell_height)
  if target_width == width and target_height == height then return cb(nil) end

  local bin = vim.fn.executable("magick") == 1 and "magick"
    or (vim.fn.executable("convert") == 1 and "convert" or nil)
  if not bin then
    if not pad_warning_shown then
      pad_warning_shown = true
      vim.notify(
        "[latex-preview] render.pad_to_cells=true but ImageMagick is not available; "
          .. "equation images may be scaled by the terminal",
        vim.log.levels.WARN
      )
    end
    return cb(nil)
  end
  -- Write to a sibling temp file first so a mid-write crash can't corrupt
  -- the cached PNG. Same directory → same filesystem → rename is atomic.
  local tmp = png_path .. ".tmp"
  spawn(bin, {
    png_path,
    "-background", "none",
    "-gravity", "center",
    "-extent", ("%dx%d"):format(target_width, target_height),
    tmp,
  }, function(err)
    if err then
      pcall(os.remove, tmp)
      return cb(err)
    end
    if not os.rename(tmp, png_path) then
      pcall(os.remove, tmp)
      return cb("pad_to_cells: rename failed")
    end
    cb(nil)
  end)
end

-- Public API ----------------------------------------------------------------

---Render an equation to a PNG. If already cached, calls cb synchronously
---with the cached path on the next tick. Otherwise dispatches to the
---daemon → rasterizer pipeline.
---
---@param req { preamble: string, equation: string, display: boolean, buf: integer?, live: boolean?, live_id: integer?, font_size: integer?, pad_to_cells: boolean? }
---@param cb fun(err: string?, png_path: string?)
function M.render(req, cb)
  -- Resolve buf eagerly to a real buffer ID. req.buf is optional for
  -- backward compatibility and for tests; when omitted we snap to the
  -- active buffer once, here, so every downstream check (buf_modified,
  -- cache_dir, temp_stem) sees the same buffer even if the user later
  -- switches windows while a render is in flight.
  local buf = req.buf
  if not buf or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  req.buf = buf
  local buf_modified = vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified
  local key = cache_key(req)
  local use_cache = config.options.cache and not buf_modified
  local use_reusable_temp = not use_cache and req.live
  local can_reuse = use_cache or use_reusable_temp
  local svg_path
  local png_path
  if use_cache then
    local dir = ensure_cache_dir(buf)
    svg_path = dir .. "/" .. key .. ".svg"
    png_path = dir .. "/" .. key .. ".png"
  else
    local stem = temp_stem(buf, use_reusable_temp and ("live-" .. key) or req.live_id)
    svg_path = stem .. ".svg"
    png_path = stem .. ".png"
  end

  if can_reuse and pending[png_path] then
    pending[png_path][#pending[png_path] + 1] = cb
    return
  end

  -- Cache hit? Check the PNG specifically — if the SVG is there but the
  -- PNG isn't, the rasterizer crashed mid-step and we want to retry.
  if can_reuse and uv.fs_stat(png_path) then
    if use_reusable_temp then schedule_temp_cache_limit_check() end
    return vim.schedule(function() cb(nil, png_path) end)
  end

  if can_reuse then
    pending[png_path] = { cb }
  end

  local function finish(err, path)
    if use_reusable_temp and not err then schedule_temp_cache_limit_check() end
    if not can_reuse then return cb(err, path) end
    local callbacks = pending[png_path] or { cb }
    pending[png_path] = nil
    for _, waiter in ipairs(callbacks) do
      waiter(err, path)
    end
  end

  -- For temp (non-cached) renders, leave no debris on the filesystem when
  -- any pipeline stage fails. For cached renders we keep partial files —
  -- a half-written SVG without a PNG signals to the next call that the
  -- rasterizer crashed and the request should be retried.
  local function cleanup_temps()
    if not use_cache then
      pcall(os.remove, svg_path)
      pcall(os.remove, png_path)
    end
  end

  local fg_hex = config.get_fg():gsub("^#", "")
  daemon.render({
    preamble = req.preamble or "",
    equation = req.equation,
    display = req.display,
    color = fg_hex,
    font_size = effective_font_size(req),
    display_math_style = config.options.render.display_math_style,
  }, function(err, svg)
    if err then cleanup_temps(); return finish(err, nil) end
    if not svg then cleanup_temps(); return finish("daemon returned no svg", nil) end
    -- Write SVG.
    local fd = io.open(svg_path, "w")
    if not fd then cleanup_temps(); return finish("cannot open " .. svg_path .. " for write", nil) end
    fd:write(svg)
    fd:close()
    -- Rasterize.
    svg_to_png(svg_path, png_path, effective_density(req), function(rerr)
      if rerr then cleanup_temps(); return finish(rerr, nil) end
      if not should_pad_to_cells(req) then return finish(nil, png_path) end
      pad_to_cells(png_path, function(perr)
        if perr then cleanup_temps(); return finish(perr, nil) end
        finish(nil, png_path)
      end)
    end)
  end)
end

---Clear the cache directory for a given buffer (defaults to current).
---Returns count of files removed. Note: with cache_dir = "aux", different
---buffers in different directories have different caches; this only
---clears the one for `buf`.
---@param buf integer? defaults to current buffer
function M.clear_cache(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local dir = config.get_cache_dir(buf)
  if not uv.fs_stat(dir) then return 0 end
  local handle = uv.fs_scandir(dir)
  if not handle then return 0 end
  local removed = 0
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    if name:match("%.svg$")
        or name:match("%.png$")
        or name:match("%.info$")
        or name:match("%.tex$")
        or name:match("%.pdf$")
        or name:match("%.log$")
        or name:match("%.aux$") then
      os.remove(dir .. "/" .. name)
      removed = removed + 1
    end
  end
  return removed
end

return M
