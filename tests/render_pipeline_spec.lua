-- nvim --headless -u NONE -i NONE -l tests/render_pipeline_spec.lua
-- Exercises real librsvg output with a deterministic SVG daemon fixture.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local uv = vim.uv or vim.loop
assert(vim.fn.executable("rsvg-convert") == 1, "rsvg-convert is required")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local cells = { cell_width = 10, cell_height = 20 }
package.loaded["snacks"] = { image = { terminal = { size = function() return cells end } } }
local daemon_calls = 0
local requests = {}
package.loaded["latex-preview.daemon"] = { render = function(req, cb)
  daemon_calls = daemon_calls + 1
  requests[#requests + 1] = req
  vim.defer_fn(function()
    cb(nil, ('<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" '
      .. 'width="13.25px" height="7.25px" viewBox="0 0 13.25 7.25">'
      .. '<rect width="13.25" height="7.25" fill="#%s"/></svg>'):format(req.color))
  end, 10)
end }
local config = require("latex-preview.config")
config.setup({ cache = true, cache_dir = root, render = {
  fg = "#ff0000", density = 300, svg_to_png = "rsvg", pad_to_cells = true,
} })
local render = require("latex-preview.render")
local process_count = 0
local real_spawn = uv.spawn
local fail_raster = false
uv.spawn = function(cmd, opts, cb)
  process_count = process_count + 1
  assert(cmd == "rsvg-convert", "cell padding must not start ImageMagick")
  if fail_raster then
    fail_raster = false
    local output
    for i, arg in ipairs(opts.args) do
      if arg == "-o" then output = opts.args[i + 1] end
    end
    local fd = assert(io.open(output, "wb"))
    fd:write("partial PNG")
    fd:close()
    vim.defer_fn(function() cb(1) end, 1)
    return { close = function() end }
  end
  return real_spawn(cmd, opts, cb)
end
local function start(req)
  local result = {}
  render.render(req, function(err, path) result.err, result.path, result.done = err, path, true end)
  return result
end
local function wait(result, expect_error)
  assert(vim.wait(3000, function() return result.done end, 1), "render timed out")
  if expect_error then
    assert(result.err ~= nil, "expected rasterizer failure")
  else
    assert(not result.err, result.err)
    assert(result.path and uv.fs_stat(result.path), "missing completed PNG")
  end
  return result.path
end
local function size(path)
  local fd = assert(io.open(path, "rb"))
  local header = fd:read(24)
  fd:close()
  assert(header:sub(1, 8) == "\137PNG\r\n\26\n", "invalid PNG")
  local function uint(at)
    local a, b, c, d = header:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return uint(17), uint(21)
end
local first = wait(start({ equation = "x" }))
local w, h = size(first)
assert(w == 50 and h == 40, ("incorrect padded dimensions: %dx%d"):format(w, h))
assert(process_count == 1, "padded render should need one process")
assert(first == wait(start({ equation = "x" })), "identical render must reuse PNG")
assert(process_count == 1 and daemon_calls == 1, "cache hit rerendered")

cells = { cell_width = 16, cell_height = 24 }
local resized = wait(start({ equation = "x" }))
w, h = size(resized)
assert(resized ~= first and w == 48 and h == 24, "cell dimensions must invalidate padded renders")

local req = { equation = "snapshot" }
local snapshot = start(req)
config.options.render.density = 96
config.options.render.fg = "#00ff00"
cells = { cell_width = 8, cell_height = 16 }
req.equation = "mutated"
local snapshot_path = wait(snapshot)
w, h = size(snapshot_path)
assert(w == 48 and h == 24, "in-flight render must keep original density and cells")
assert(requests[#requests].equation == "snapshot" and requests[#requests].color == "ff0000", "request was not snapshotted")
local changed = wait(start({ equation = "snapshot" }))
w, h = size(changed)
assert(changed ~= snapshot_path and w == 16 and h == 16, "changed settings must get their own PNG")

fail_raster = true
wait(start({ equation = "failure" }), true)
local before_retry = daemon_calls
wait(start({ equation = "failure" }))
assert(daemon_calls == before_retry + 1, "partial persistent PNG was reused after failure")
for _, path in ipairs(vim.fn.glob(root .. "/*", false, true)) do
  assert(not path:match("%.tmp$"), "staging file leaked: " .. path)
end

config.options.cache = false
local a, b = start({ equation = "a" }), start({ equation = "b" })
assert(wait(a) ~= wait(b), "simultaneous non-live renders must not overwrite one another")
local before_coalesce = daemon_calls
local c, d = start({ equation = "same" }), start({ equation = "same" })
assert(wait(c) == wait(d) and daemon_calls == before_coalesce + 1, "non-live renders must coalesce")
uv.spawn = real_spawn
vim.fn.delete(root, "rf")
print("render pipeline regressions passed")
vim.cmd("qa!")
