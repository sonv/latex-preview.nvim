package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local function eq(expected, actual, message)
  assert(expected == actual, (message or "values differ") .. ": " .. vim.inspect(actual))
end

local requests, scheduled, timers = {}, {}, {}
local source = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "$x$" })
local mode, expression, display = "equation", "x", false
local cells = { cell_width = 8, cell_height = 16 }
package.loaded["latex-preview.parse"] = {
  find_equations = function(buf)
    if buf == source and mode ~= "equation" then return {} end
    return { { text = expression, display = display, start_row = 0, start_col = 0, end_row = 0, end_col = 3 } }
  end,
}
package.loaded["latex-preview.extract"] = { get_preamble = function() return "" end }
package.loaded["latex-preview.targets"] = {
  reference_under_cursor = function()
    if mode == "mixed" then return { type = "mixed_text", signature = "mixed", lines = { "$x$" } } end
    if mode == "text" then return { type = "text", signature = "text", lines = { "A reference" } } end
  end,
  missing_reference_under_cursor = function() end,
}
package.loaded["latex-preview.render"] = {
  render = function(req, cb) requests[#requests + 1] = { req = req, cb = cb } end,
  retain = function() end,
  release = function() end,
}

local placements = 0
local win_factory = { resolve = function(_, _, opts) return opts end }
setmetatable(win_factory, { __call = function(_, opts)
  return {
    opts = opts,
    open_buf = function(self) self.buf = vim.api.nvim_create_buf(false, true) end,
    show = function() end,
    update = function() end,
    close = function(self)
      if vim.api.nvim_buf_is_valid(self.buf) then vim.api.nvim_buf_delete(self.buf, { force = true }) end
    end,
  }
end })
package.loaded["snacks"] = {
  win = win_factory,
  config = { merge = function(...) return vim.tbl_deep_extend("force", ...) end },
  image = {
    config = { doc = {} },
    terminal = { env = function() return { placeholders = true } end, size = function() return cells end },
    placement = { new = function(_, path)
      placements = placements + 1
      return { img = { src = path }, close = function() end, update = function() end }
    end },
  },
}
local config = require("latex-preview.config")
config.setup({
  render = { fg = "#000000" },
  references = { enabled = true },
  theorem_references = { enabled = false },
  citations = { enabled = false },
})
local real_schedule, real_uv = vim.schedule, vim.uv
vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
vim.uv = setmetatable({ new_timer = function()
  local timer = {
    stop = function() end,
    close = function() end,
    start = function(self, _, _, callback) self.fire = callback end,
  }
  timers[#timers + 1] = timer
  return timer
end }, { __index = real_uv })
local function flush()
  while #scheduled > 0 do
    local callbacks = scheduled
    scheduled = {}
    for _, callback in ipairs(callbacks) do callback() end
  end
end
local function event(name)
  vim.api.nvim_exec_autocmds(name, { buffer = source })
end
local hover = require("latex-preview.hover")

-- Cursor/completion events during rasterization should share one request.
for _ = 1, 20 do assert(hover.open()) end
eq(1, #requests, "unchanged pending hover should issue only one render request")
hover.close()
requests[1].cb(nil, "/tmp/old.png")
eq(false, hover.is_open(), "close must cancel the initial in-flight render")
eq(0, placements)

hover.open()
local second = requests[#requests]
hover.close()
hover.open()
local third = requests[#requests]
second.cb(nil, "/tmp/old.png")
eq(false, hover.is_open(), "a cancelled result must not replace a newer request")
third.cb(nil, "/tmp/current.png")
assert(hover.is_open(), "latest render should show its image")
eq(1, placements)
hover.close()

hover.open()
local before_text = requests[#requests]
mode = "text"
hover.open()
local old_placements = placements
before_text.cb(nil, "/tmp/before-text.png")
assert(hover.is_open(), "text popup must remain open after a stale equation result")
eq(old_placements, placements, "an initial equation result must not replace a text target")
hover.close()
mode = "equation"

-- BufLeave must cancel requests before any popup has been created, including
-- leaving and returning to the exact same cursor position before completion.
hover.open()
local leaving = requests[#requests]
event("BufLeave")
leaving.cb(nil, "/tmp/left-buffer.png")
eq(false, hover.is_open(), "leaving a buffer must cancel its initial render")
hover.open()
local leaving_again = requests[#requests]
event("BufLeave")
leaving_again.cb(nil, "/tmp/left-again.png")
eq(false, hover.is_open(), "leave handlers must be reinstalled after cancelling a pending render")

-- An already-fired timer can still have a scheduled callback when closed.
hover.open()
event("TextChanged")
timers[#timers].fire()
hover.close()
local before = #requests
flush()
eq(before, #requests, "queued debounce callbacks must not reopen a closed preview")

hover.attach(source)
hover.detach(source)
flush()
eq(before, #requests, "queued attach callbacks must honor detach")

hover.attach(source)
flush()
before = #requests
event("CompleteDone")
event("TextChanged")
timers[#timers].fire()
hover.detach(source)
flush()
eq(before, #requests, "queued completion/debounce callbacks must honor detach")
requests[#requests].cb(nil, "/tmp/detached.png")
eq(false, hover.is_open(), "detaching must cancel an initial in-flight render")

-- Returning to the currently displayed equation cancels a different pending
-- request and permits that equation to be requested afresh later.
hover.open()
requests[#requests].cb(nil, "/tmp/x.png")
expression = "y"
hover.open()
local y = requests[#requests]
expression = "x"
before = #requests
hover.open()
eq(before, #requests, "returning to the visible equation should reuse its image")
y.cb(nil, "/tmp/y.png")
expression = "y"
hover.open()
eq(before + 1, #requests, "a cancelled pending signature must be requestable again")
hover.close()

config.options.render.pad_to_cells = true
hover.open()
requests[#requests].cb(nil, "/tmp/padded.png")
before = #requests
cells.cell_width = 10
hover.open()
eq(before + 1, #requests, "terminal cell dimensions must invalidate a padded equation")
requests[#requests].cb(nil, "/tmp/resized.png")
before = #requests
config.options.render.svg_to_png = "magick"
hover.open()
eq(before + 1, #requests, "rasterizer changes must invalidate the visible equation")
hover.close()

-- Switching back from an unfinished equation to mixed text rebuilds inline
-- placements rather than retaining a window whose render callbacks expired.
mode = "mixed"
hover.open()
local mixed = requests[#requests]
mode = "equation"
hover.open()
mode = "mixed"
before = #requests
hover.open()
eq(before + 1, #requests, "returning to mixed text must restore cancelled inline renders")
mixed.cb(nil, "/tmp/stale-inline.png")
local before_placements = placements
requests[#requests].cb(nil, "/tmp/inline.png")
eq(before_placements + 1, placements, "current mixed text should accept its inline image")
before = #requests
config.options.render.fg = "#ffffff"
hover.open()
eq(before + 1, #requests, "mixed images must rerender when foreground color changes")
eq(false, requests[#requests].req.pad_to_cells, "mixed inline math must disable cell padding")
before = #requests
cells.cell_height = 20
hover.open()
eq(before + 1, #requests, "terminal cell dimensions must invalidate mixed render settings")
before = #requests
config.options.render.svg_to_png = "rsvg"
hover.open()
eq(before + 1, #requests, "rasterizer changes must invalidate mixed images")
hover.close()
display = true
hover.open()
eq(nil, requests[#requests].req.pad_to_cells, "mixed display math must inherit configured cell padding")
before_placements = placements
config.options.render.density = 450
requests[#requests].cb(nil, "/tmp/outdated-mixed-density.png")
eq(before_placements, placements, "mixed results must reject settings changed while rendering")
hover.close()

-- The toggle must cancel an initial render, before there is a visible popup.
mode, display = "equation", false
local lp = require("latex-preview")
assert(lp.toggle(), "first toggle should request a preview")
local toggled = requests[#requests]
eq(false, lp.toggle(), "second toggle should cancel the pending preview")
toggled.cb(nil, "/tmp/cancelled-toggle.png")
eq(false, hover.is_open(), "a toggled-off render must not show a late popup")

dofile("plugin/latex-preview.lua")
vim.cmd("LatexPreview")
toggled = requests[#requests]
vim.cmd("LatexPreview toggle")
toggled.cb(nil, "/tmp/cancelled-command-toggle.png")
eq(false, hover.is_open(), "the command toggle must also cancel pending renders")

vim.schedule, vim.uv = real_schedule, real_uv
print("hover lifecycle regressions passed")
vim.cmd("qa!")
