-- lua/latex-preview/hover.lua
--
-- Hover preview, snacks.image-backed.
--
-- The MathJax daemon (via render.lua) produces a PNG. We then hand that
-- PNG to snacks.image's placement machinery, which owns:
--   * Kitty graphics protocol transmission
--   * Unicode-placeholder layout inside a floating window
--   * Auto-close on cursor move / mode change / buffer leave
--   * Reactive resize and redraw
--
-- The implementation here is essentially a port of snacks.image.doc's
-- M.hover() (lua/snacks/image/doc.lua, ~line 369), specialized for the
-- case where we already have a rendered PNG path instead of a TeX source
-- that snacks needs to compile.

local M = {}

local config = require("latex-preview.config")
local parse = require("latex-preview.parse")
local extract = require("latex-preview.extract")
local render = require("latex-preview.render")
local targets = require("latex-preview.targets")

---@class LatexPreview.HoverState
---@field win snacks.win
---@field img snacks.image.Placement?
---@field imgs snacks.image.Placement[]?
---@field buf integer  -- the source buffer (where the cursor was)
---@field source_win integer
---@field eq LatexPreview.Equation  -- the equation that triggered the popup,
---                                 -- so we can detect when the cursor leaves it
---@field render_id integer
---@field signature string
local current = nil ---@type LatexPreview.HoverState?
local active_render_id = 0
local pending_render = nil
local autocmd_buf = nil
local refresh_timer = nil
local refresh_generation = 0
local source_keymaps = {} ---@type table<integer, table<string, table|false>>
local auto_buffers = {} ---@type table<integer, boolean>

local CLOSE_KEYS = { "q", "<Esc>" }

local function auto_group_name(buf)
  return "latex_preview_auto_hover." .. tostring(buf)
end

local function stop_refresh_timer()
  refresh_generation = refresh_generation + 1
  if not refresh_timer then return end
  refresh_timer:stop()
  refresh_timer:close()
  refresh_timer = nil
end

local function close_current()
  -- Closing also cancels the first render and any queued live update, even
  -- before there is a floating window to close.
  active_render_id = active_render_id + 1
  pending_render = nil
  autocmd_buf = nil
  stop_refresh_timer()
  if not current then return end
  if current.img then pcall(function() current.img:close() end) end
  for _, img in ipairs(current.imgs or {}) do
    pcall(function() img:close() end)
  end
  pcall(function() current.win:close() end)
  for buf, maps in pairs(source_keymaps) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, lhs in ipairs(CLOSE_KEYS) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
        local old = maps[lhs]
        if old then
          local opts = {
            buffer = buf,
            expr = old.expr == 1,
            noremap = old.noremap == 1,
            nowait = old.nowait == 1,
            script = old.script == 1,
            silent = old.silent == 1,
            desc = old.desc,
          }
          if old.callback then
            pcall(vim.keymap.set, "n", lhs, old.callback, opts)
          else
            pcall(vim.keymap.set, "n", lhs, old.rhs or "", opts)
          end
        end
      end
    end
    source_keymaps[buf] = nil
  end
  current = nil
end

local function has_preview(buf)
  return (current and current.buf == buf) or (pending_render and pending_render.buf == buf)
end

local function map_close_keys(win, source_buf)
  if not win or not win.buf or not vim.api.nvim_buf_is_valid(win.buf) then return end
  for _, lhs in ipairs(CLOSE_KEYS) do
    vim.keymap.set("n", lhs, function()
      close_current()
    end, {
      buffer = win.buf,
      nowait = true,
      silent = true,
      desc = "Close LaTeX preview",
    })
  end
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) and not source_keymaps[source_buf] then
    source_keymaps[source_buf] = {}
    for _, lhs in ipairs(CLOSE_KEYS) do
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(source_buf, "n")) do
        if map.lhs == lhs then
          source_keymaps[source_buf][lhs] = map
          break
        end
      end
      if source_keymaps[source_buf][lhs] == nil then
        source_keymaps[source_buf][lhs] = false
      end
      vim.keymap.set("n", lhs, function()
        close_current()
      end, {
        buffer = source_buf,
        nowait = true,
        silent = true,
        desc = "Close LaTeX preview",
      })
    end
  end
end

---True iff the cursor in the *current* window is inside `eq`'s byte range.
---Used both to find the equation under the cursor at trigger time and to
---decide whether to keep the popup open as the cursor moves.
---@param eq LatexPreview.Equation
local function cursor_in_equation(eq)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local crow, ccol = cursor[1] - 1, cursor[2]
  local after_start = (crow > eq.start_row)
    or (crow == eq.start_row and ccol >= eq.start_col)
  local before_end = (crow < eq.end_row)
    or (crow == eq.end_row and ccol < eq.end_col)
  return after_start and before_end
end

---Return the equation under the cursor (1-based win cursor → 0-based buffer
---coordinates), or nil if none.
---@param buf integer
---@return LatexPreview.Equation?
local function equation_under_cursor(buf)
  local equations = parse.find_equations(buf)
  for _, eq in ipairs(equations) do
    if cursor_in_equation(eq) then return eq end
  end
  return nil
end

local function target_under_cursor(buf)
  local eq = equation_under_cursor(buf)
  if eq then
    return { type = "equation", source = "direct", equation = eq }
  end
  if config.options.references and config.options.references.enabled then
    local ref = targets.reference_under_cursor(buf)
    if ref then return ref end
  end
  if config.options.theorem_references and config.options.theorem_references.enabled then
    local theorem_ref = targets.theorem_reference_under_cursor(buf)
    if theorem_ref then return theorem_ref end
  end
  if (config.options.references and config.options.references.enabled)
      or (config.options.theorem_references and config.options.theorem_references.enabled) then
    local missing_ref = targets.missing_reference_under_cursor(buf)
    if missing_ref then return missing_ref end
  end
  if config.options.citations and config.options.citations.enabled then
    local cite = targets.citation_under_cursor(buf)
    if cite then return cite end
  end
  return nil
end

local function render_density(buf, display)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local key = display and "latex_preview_display_density" or "latex_preview_density"
    local value = vim.b[buf][key]
    if value == nil and display then value = vim.b[buf].latex_preview_density end
    if value ~= nil then return tonumber(value) or config.options.render.density end
  end
  return config.options.render.density
end

local function render_output_signature(pad)
  local tool = config.options.render.svg_to_png
  if tool == "auto" then
    tool = vim.fn.executable("rsvg-convert") == 1 and "rsvg" or "magick"
  end
  local width, height
  if pad then
    local ok, snacks = pcall(require, "snacks")
    local terminal = ok and snacks.image and snacks.image.terminal
    local cells = terminal and terminal.size and terminal.size()
    if cells then
      width, height = tonumber(cells.cell_width), tonumber(cells.cell_height)
      if not width or not height or width <= 0 or height <= 0 then width, height = nil, nil end
    end
  end
  return table.concat({ tostring(tool), tostring(width or ""), tostring(height or "") }, ":")
end

local function render_signature(preamble, eq, buf)
  local font_size = eq.display
    and (config.options.render.display_font_size or config.options.render.font_size)
    or config.options.render.font_size
  return table.concat({
    preamble or "",
    eq.text or "",
    eq.display and "1" or "0",
    config.get_fg(),
    tostring(font_size),
    tostring(config.options.render.display_math_style),
    tostring(config.options.render.pad_to_cells),
    tostring(render_density(buf, eq.display)),
    render_output_signature(config.options.render.pad_to_cells == true),
  }, "\n--latex-preview--\n")
end

local function mixed_render_signature(preamble, target, buf)
  return table.concat({
    target.signature or table.concat(target.lines or {}, "\n"),
    vim.fn.sha256(preamble),
    tostring(render_density(buf, false)),
    tostring(render_density(buf, true)),
    tostring(config.options.render.font_size),
    tostring(config.options.render.display_font_size),
    tostring(config.options.render.display_math_style),
    tostring(config.options.render.pad_to_cells),
    config.get_fg(),
    render_output_signature(config.options.render.pad_to_cells == true),
  }, "\n--latex-preview--\n")
end

local function place_under_cursor(win, source_win)
  if vim.fn.pumvisible() == 1 then return false end
  if not win then return false end
  source_win = source_win or (current and current.source_win) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(source_win) then return false end
  local cursor = vim.api.nvim_win_get_cursor(source_win)
  local ok, screenpos = pcall(vim.fn.screenpos, source_win, cursor[1], cursor[2] + 1)
  if not ok or not screenpos or screenpos.row == 0 then return false end
  local height = tonumber(win.opts.height) or 1
  local width = tonumber(win.opts.width) or 1
  local max_row = math.max(0, vim.o.lines - height - 1)
  local max_col = math.max(0, vim.o.columns - width - 1)
  local row = screenpos.row
  if row + height > vim.o.lines - 1 then
    row = math.max(0, screenpos.row - height - 1)
  end
  win.opts.relative = "editor"
  win.opts.row = math.max(0, math.min(max_row, row))
  win.opts.col = math.max(0, math.min(max_col, screenpos.col - 1))
  if win.win and vim.api.nvim_win_is_valid(win.win) then
    pcall(function() win:update() end)
  end
  return true
end

local function show_under_cursor(win, source_win)
  if not place_under_cursor(win, source_win) then return false end
  pcall(function() win:show() end)
  return true
end

local function schedule_open(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.api.nvim_get_current_buf() ~= buf then return end
  if vim.fn.pumvisible() == 1 then return end
  if refresh_timer then
    refresh_timer:stop()
  else
    refresh_timer = assert((vim.uv or vim.loop).new_timer())
  end
  local delay = (config.options.popup or {}).live_update_delay_ms or 300
  refresh_generation = refresh_generation + 1
  local generation = refresh_generation
  refresh_timer:start(delay, 0, function()
    vim.schedule(function()
      if generation ~= refresh_generation then return end
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        M.open()
      end
    end)
  end)
end

local function schedule_current_open(buf)
  if not has_preview(buf) then return true end
  schedule_open(buf)
end

local function register_autocmds(buf)
  if autocmd_buf == buf then return end
  autocmd_buf = buf
  local group = vim.api.nvim_create_augroup("latex_preview_hover", { clear = true })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      if has_preview(buf) then close_current() end
      return true
    end,
  })
  -- When the buffer already has auto-hover attached, its CursorMoved/
  -- TextChanged/CompleteDone handlers already call M.open(). Registering
  -- them here too would fire M.open() twice per event.
  if auto_buffers[buf] then return end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if not has_preview(buf) then
        autocmd_buf = nil
        return true
      end
      if not target_under_cursor(buf) then
        close_current()
        return true
      end
      if vim.fn.pumvisible() == 1 then return end
      M.open()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.fn.pumvisible() == 1 then return end
      if schedule_current_open(buf) then
        autocmd_buf = nil
        return true
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone", "CompleteDonePre" }, {
    group = group,
    buffer = buf,
    callback = function()
      if not has_preview(buf) then return true end
      vim.schedule(function()
        if has_preview(buf) and vim.api.nvim_get_current_buf() == buf then M.open() end
      end)
    end,
  })
end

---Automatically open/update the preview in this buffer when the cursor is
---inside a math expression.
---@param buf integer
function M.attach(buf)
  if auto_buffers[buf] then return end
  auto_buffers[buf] = true
  if has_preview(buf) then
    autocmd_buf = nil
    register_autocmds(buf)
  end
  local group = vim.api.nvim_create_augroup(auto_group_name(buf), { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.fn.pumvisible() == 1 then return end
      M.open()
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      schedule_open(buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "CompleteDone", "CompleteDonePre" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if auto_buffers[buf] and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
          M.open()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      if has_preview(buf) then close_current() end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      auto_buffers[buf] = nil
      if has_preview(buf) then close_current() end
      return true
    end,
  })

  vim.schedule(function()
    if auto_buffers[buf] and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
      M.open()
    end
  end)
end

---Stop automatically opening/updating previews in this buffer.
---@param buf integer
function M.detach(buf)
  if not auto_buffers[buf] then return end
  auto_buffers[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_name, auto_group_name(buf))
  if has_preview(buf) then close_current() else stop_refresh_timer() end
end

---Stop automatically opening/updating previews in every attached buffer.
function M.detach_all()
  local bufs = vim.tbl_keys(auto_buffers)
  for _, buf in ipairs(bufs) do
    M.detach(buf)
  end
end

---True when snacks.image is loaded and its terminal supports placeholder-
---based image placement (Kitty / WezTerm / Ghostty with the right env).
function M.is_supported()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.image then return false end
  if not snacks.image.terminal or not snacks.image.terminal.env then return false end
  local env = snacks.image.terminal.env()
  return env and env.placeholders == true
end

local function make_text_window(lines)
  local popup = config.options.popup or {}
  local max_width = popup.max_width or math.max(1, vim.o.columns - 4)
  local max_height = popup.max_height or math.max(1, vim.o.lines - 4)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(20, math.min(max_width, width + 2))
  local height = math.max(1, math.min(max_height, #lines))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return {
    buf = buf,
    win = nil,
    opts = { row = 0, col = 0, width = width, height = height },
    update = function(self)
      if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_set_config(self.win, {
          relative = "editor",
          row = self.opts.row,
          col = self.opts.col,
          width = self.opts.width,
          height = self.opts.height,
          style = "minimal",
          border = "rounded",
        })
      end
    end,
    show = function(self)
      if self.win and vim.api.nvim_win_is_valid(self.win) then return end
      self.win = vim.api.nvim_open_win(self.buf, false, {
        relative = "editor",
        row = self.opts.row,
        col = self.opts.col,
        width = self.opts.width,
        height = self.opts.height,
        style = "minimal",
        border = "rounded",
        zindex = 50,
      })
      vim.wo[self.win].wrap = false
      vim.wo[self.win].conceallevel = 2
      vim.wo[self.win].concealcursor = "nvic"
    end,
    close = function(self)
      if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
      end
      if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
      end
    end,
  }
end

local function show_image_file(buf, source_win, png_path, opts)
  opts = opts or {}
  local snacks = require("snacks")
  if config.options.snacks
      and config.options.snacks.disable_document_images
      and snacks.image
      and snacks.image.config then
    snacks.image.config.doc = snacks.image.config.doc or {}
    snacks.image.config.doc.enabled = false
    snacks.image.config.doc.inline = false
  end

  if current and current.img and current.img.img and current.img.img.src == png_path then
    current.eq = opts.eq
    current.source_win = source_win
    show_under_cursor(current.win, source_win)
    pcall(function() current.img:update() end)
    return true
  end
  close_current()

  local win = snacks.win(snacks.win.resolve(snacks.image.config.doc, "snacks_image", {
    show = false,
    enter = false,
    relative = "editor",
    row = 0,
    col = 0,
    wo = { winblend = snacks.image.terminal.env().placeholders and 0 or nil },
  }))
  win:open_buf()
  map_close_keys(win, buf)

  local updated = false
  local popup = config.options.popup or {}
  local max_width = popup.max_width or math.max(1, vim.o.columns - 4)
  local max_height = popup.max_height or math.max(1, vim.o.lines - 4)
  local placement_opts = snacks.config.merge({}, snacks.image.config.doc, {
    inline = false,
    max_width = max_width,
    max_height = max_height,
    on_update_pre = function(placement)
      placement.img.info = nil
      if not updated then
        local loc = placement:state().loc
        win.opts.width = loc.width
        win.opts.height = loc.height
        updated = show_under_cursor(win, source_win)
      end
    end,
  })

  current = {
    type = opts.type or "image",
    win = win,
    buf = buf,
    source_win = source_win,
    eq = opts.eq,
    render_id = opts.render_id,
    signature = opts.signature,
    img = snacks.image.placement.new(win.buf, png_path, placement_opts),
  }
  register_autocmds(buf)
  return true
end

local show_text_target

local function adjust_mixed_window(win, base_lines, loc)
  if not win then return end
  local popup = config.options.popup or {}
  local max_width = popup.max_width or math.max(1, vim.o.columns - 4)
  local max_height = popup.max_height or math.max(1, vim.o.lines - 4)
  if loc then
    win.opts.width = math.min(max_width, math.max(win.opts.width or 1, loc[2] + loc.width + 1))
    win.opts.height = math.min(max_height, math.max(win.opts.height or 1, loc[1] + loc.height - 1))
  else
    win.opts.height = math.min(max_height, math.max(win.opts.height or 1, base_lines))
  end
  if win.win and vim.api.nvim_win_is_valid(win.win) then
    pcall(function() win:update() end)
  end
end

local function render_math_in_text_window(source_buf, source_win, target, win, render_id)
  local eqs = parse.find_equations(win.buf)
  if #eqs == 0 then return end
  local snacks = require("snacks")
  local preamble = extract.get_preamble(source_buf)
  local signature = mixed_render_signature(preamble, target, source_buf)
  local popup = config.options.popup or {}
  local max_width = popup.max_width or math.max(1, vim.o.columns - 4)
  local max_height = popup.max_height or math.max(1, vim.o.lines - 4)
  for i, eq in ipairs(eqs) do
    -- Inline math must fit the surrounding text; display math inherits the
    -- configured cell padding. Lua's and/or idiom cannot preserve false/nil.
    local pad_to_cells
    if not eq.display then pad_to_cells = false end
    render.render({
      preamble = preamble,
      equation = eq.text,
      display = eq.display,
      buf = source_buf,
      live = true,
      live_id = render_id * 1000 + i,
      font_size = not eq.display and math.max(config.options.render.font_size or 11, 12) or nil,
      pad_to_cells = pad_to_cells,
    }, function(err, png_path)
      -- Live renders are reusable temp-cache entries owned by render.lua's
      -- per-process temp directory. Unused images are left in place so a
      -- later identical equation can reuse them until VimLeavePre cleanup.
      local function cleanup_unused() end
      if err or not png_path then return end
      if active_render_id ~= render_id then return cleanup_unused() end
      if not current or current.render_id ~= render_id or current.win ~= win then return cleanup_unused() end
      if not vim.api.nvim_buf_is_valid(win.buf) then return cleanup_unused() end
      if not vim.api.nvim_buf_is_valid(source_buf) or not vim.api.nvim_win_is_valid(source_win) then return cleanup_unused() end
      local ok_target, live_target = pcall(vim.api.nvim_win_call, source_win, function()
        if vim.api.nvim_get_current_buf() ~= source_buf then return nil end
        return target_under_cursor(source_buf)
      end)
      if not ok_target then return cleanup_unused() end
      if not live_target or live_target.signature ~= target.signature then return cleanup_unused() end
      if mixed_render_signature(extract.get_preamble(source_buf), live_target, source_buf) ~= signature then
        return cleanup_unused()
      end

      local placement_opts = snacks.config.merge({}, snacks.image.config.doc, {
        inline = true,
        pos = { eq.start_row + 1, eq.start_col },
        range = { eq.start_row + 1, eq.start_col, eq.end_row + 1, eq.end_col },
        conceal = "",
        type = "math",
        max_width = max_width,
        max_height = max_height,
        on_update_pre = function(placement)
          placement.img.info = nil
          local loc = placement:state().loc
          adjust_mixed_window(win, #(target.lines or {}), loc)
        end,
      })
      local img = snacks.image.placement.new(win.buf, png_path, placement_opts)
      current.imgs = current.imgs or {}
      current.imgs[#current.imgs + 1] = img
      adjust_mixed_window(win, #(target.lines or {}))
    end)
  end
end

local function show_mixed_text_target(buf, source_win, target)
  local preamble = extract.get_preamble(buf)
  local signature = mixed_render_signature(preamble, target, buf)
  if current and current.type == "mixed_text" and current.signature == signature then
    current.buf = buf
    current.source_win = source_win
    show_under_cursor(current.win, source_win)
    for _, img in ipairs(current.imgs or {}) do
      pcall(function() img:update() end)
    end
    map_close_keys(current.win, buf)
    register_autocmds(buf)
    return true
  end
  close_current()
  active_render_id = active_render_id + 1
  local render_id = active_render_id
  local win = make_text_window(target.lines or {})
  current = {
    type = "mixed_text",
    win = win,
    imgs = {},
    img = nil,
    buf = buf,
    source_win = source_win,
    eq = nil,
    render_id = render_id,
    signature = signature,
  }
  show_under_cursor(win, source_win)
  map_close_keys(win, buf)
  register_autocmds(buf)
  render_math_in_text_window(buf, source_win, target, win, render_id)
  return true
end

function show_text_target(buf, source_win, target)
  local signature = target.signature or table.concat(target.lines or {}, "\n")
  if current and current.type == "text" and current.signature == signature then
    current.buf = buf
    current.source_win = source_win
    show_under_cursor(current.win, source_win)
    map_close_keys(current.win, buf)
    register_autocmds(buf)
    return true
  end
  close_current()
  active_render_id = active_render_id + 1
  local win = make_text_window(target.lines or {})
  current = {
    type = "text",
    win = win,
    img = nil,
    buf = buf,
    source_win = source_win,
    eq = nil,
    render_id = active_render_id,
    signature = signature,
  }
  show_under_cursor(win, source_win)
  map_close_keys(win, buf)
  register_autocmds(buf)
  return true
end

---Show a hover preview for the math expression under the cursor.
---Returns true if a preview was triggered, false if no equation was found.
---@return boolean
function M.open()
  if vim.fn.pumvisible() == 1 then
    if current then return true end
  end
  local buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local target = target_under_cursor(buf)
  if not target then
    -- Closing here lets a caller bind hover() to a key like K and not
    -- have to remember to close on the way out — moving the cursor out
    -- of an equation auto-dismisses.
    close_current()
    return false
  end
  if target.type == "text" then
    return show_text_target(buf, source_win, target)
  end
  if target.type == "mixed_text" then
    return show_mixed_text_target(buf, source_win, target)
  end
  local eq = target.equation

  local snacks = require("snacks")
  if config.options.snacks
      and config.options.snacks.disable_document_images
      and snacks.image
      and snacks.image.config then
    snacks.image.config.doc = snacks.image.config.doc or {}
    snacks.image.config.doc.enabled = false
    snacks.image.config.doc.inline = false
  end
  -- Build the request and render. The result is a PNG path (from disk
  -- cache on a hit, via the daemon and rasterizer on a miss).
  local preamble = extract.get_preamble(buf)
  local req = {
    preamble = preamble,
    equation = eq.text,
    display = eq.display,
    buf = buf,  -- so render.lua resolves cache_dir per-buffer
    live = true,
  }
  local signature = render_signature(preamble, eq, buf)
  if current and not current.img then close_current() end
  if current and current.img and current.signature == signature then
    if pending_render then
      active_render_id = active_render_id + 1
      pending_render = nil
    end
    current.eq = eq
    current.buf = buf
    current.source_win = source_win
    show_under_cursor(current.win, source_win)
    pcall(function() current.img:update() end)
    map_close_keys(current.win, buf)
    register_autocmds(buf)
    return true
  end
  if pending_render and pending_render.signature == signature
      and pending_render.buf == buf and pending_render.source_win == source_win then
    return true
  end
  active_render_id = active_render_id + 1
  local render_id = active_render_id
  pending_render = { buf = buf, source_win = source_win, signature = signature }
  req.live_id = render_id
  if current then
    current.render_id = render_id
    current.source_win = source_win
    show_under_cursor(current.win, source_win)
  end
  register_autocmds(buf)

  render.render(req, function(err, png_path)
    -- Live renders write reusable temp-cache files in
    -- /run/latex-preview/<pid>/. If this request is superseded, leave the
    -- files in place so later identical renders can reuse them.
    local function cleanup_unused() end
    if active_render_id ~= render_id then return cleanup_unused() end
    pending_render = nil
    if current and current.render_id ~= render_id then return cleanup_unused() end
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(source_win) then return cleanup_unused() end
    if vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_get_current_win() ~= source_win then return cleanup_unused() end
    local live_target = target_under_cursor(buf)
    if not live_target or live_target.type ~= "equation" then return cleanup_unused() end
    local live_eq = live_target.equation
    if render_signature(extract.get_preamble(buf), live_eq, buf) ~= signature then return cleanup_unused() end
    if err or not png_path then
      vim.notify("[latex-preview] " .. (err or "render failed"), vim.log.levels.WARN)
      return
    end

    -- If a hover for the same image is already showing, just refresh it.
    -- Otherwise close any previous and open a new one.
    if current and current.img and current.img.img and current.img.img.src == png_path then
      current.eq = live_eq
      current.source_win = source_win
      show_under_cursor(current.win, source_win)
      pcall(function() current.img:update() end)
      return
    end
    close_current()

    -- Open a floating Snacks.win. We piggy-back on snacks's "snacks_image"
    -- style so it shares config (border, winblend, padding) with snacks's
    -- own image hover. The width/height fields are filled in via the
    -- placement's on_update_pre callback once we know the rendered size.
    local win = snacks.win(snacks.win.resolve(snacks.image.config.doc, "snacks_image", {
      show = false,
      enter = false,
      relative = "editor",
      row = 0,
      col = 0,
      wo = { winblend = snacks.image.terminal.env().placeholders and 0 or nil },
    }))
    win:open_buf()
    map_close_keys(win, buf)

    local updated = false
    local popup = config.options.popup or {}
    local max_width = popup.max_width or math.max(1, vim.o.columns - 4)
    local max_height = popup.max_height or math.max(1, vim.o.lines - 4)
    local placement_opts = snacks.config.merge({}, snacks.image.config.doc, {
      inline = false,
      max_width = max_width,
      max_height = max_height,
      on_update_pre = function(placement)
        -- Snacks normally prefers ImageMagick's identify metadata, applying
        -- DPI and terminal scale math. For generated equation PNGs we already
        -- control the exact pixel size, so use the PNG header dimensions
        -- directly; otherwise identical font-size renders can look different
        -- depending on rasterizer DPI metadata.
        placement.img.info = nil
        if not updated then
          local loc = placement:state().loc
          win.opts.width = loc.width
          win.opts.height = loc.height
          updated = show_under_cursor(win, source_win)
        end
      end,
    })

    current = {
      type = "equation",
      win = win,
      buf = buf,
      source_win = source_win,
      eq = live_eq,
      render_id = render_id,
      signature = signature,
      img = snacks.image.placement.new(win.buf, png_path, placement_opts),
    }
    register_autocmds(buf)
  end)

  return true
end

---Close the current hover, if any.
function M.close()
  close_current()
end

---True when a hover popup is visible.
function M.is_open()
  return current ~= nil
end

return M
